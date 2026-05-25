import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/link.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../hr/data/providers/employees_provider.dart';
import '../../../hr/domain/models/employee.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import '../../../parametres/presentation/providers/delivery_template_provider.dart';
import '../../domain/entities/sale.dart';
import '../../domain/entities/sale_item.dart';
import '../../domain/services/delivery_message_builder.dart';

/// Sheet de transfert d'une commande "scheduled" → "processing" via WhatsApp.
/// Étape 1 : choix du destinataire (partenaires / employés / numéro libre).
/// Étape 2 : aperçu éditable du message + envoi via Link target=blank.
class TransferDeliverySheet extends ConsumerStatefulWidget {
  final Sale   order;
  final String shopId;
  final String shopName;
  const TransferDeliverySheet({
    super.key,
    required this.order,
    required this.shopId,
    required this.shopName,
  });

  @override
  ConsumerState<TransferDeliverySheet> createState() =>
      _TransferDeliverySheetState();
}

/// Description générique du destinataire choisi (utilisée pour la RPC).
/// Au moins un de [phoneE164] / [groupUrl] est non-vide. Si [groupUrl] est
/// fourni, le sheet bascule en mode "groupe" (copie + ouverture du lien).
class _SelectedTarget {
  final String  kind;        // 'partner' | 'employee' | 'free'
  final String? ref;         // location.id, user_id, ou null
  final String  name;
  final String  phoneE164;   // E.164 si mode 1-à-1, vide si mode groupe
  final String  groupUrl;    // chat.whatsapp.com/<code> si mode groupe
  final String? templateId;
  const _SelectedTarget({
    required this.kind,
    this.ref,
    required this.name,
    this.phoneE164 = '',
    this.groupUrl  = '',
    this.templateId,
  });

  bool get isGroup => groupUrl.isNotEmpty;
}

class _TransferDeliverySheetState
    extends ConsumerState<TransferDeliverySheet> {
  int _step = 0;
  _SelectedTarget? _target;

  // Numéro saisi pour un employé sans téléphone (option c).
  final Map<String, TextEditingController> _employeePhoneCtrls = {};
  final Map<String, String> _employeePhoneFull = {};
  final Map<String, bool>   _employeePhoneValid = {};

  // Numéro libre (section "Autre destinataire").
  final _freeNameCtrl  = TextEditingController();
  final _freePhoneCtrl = TextEditingController();
  String _freePhoneFull  = '';
  bool   _freePhoneValid = false;

  /// Ville d'expédition : ville du destinataire choisi. Pré-remplie avec
  /// l'adresse du partenaire si dispo, sinon vide. L'utilisateur peut
  /// l'éditer manuellement avant l'aperçu. Résout {{ville_expedition}}.
  final _senderCityCtrl = TextEditingController();

  // Aperçu / message
  final _messageCtrl = TextEditingController();
  bool _editing = false;
  bool _sending = false;
  /// True pendant le téléchargement et le partage des images via le
  /// sélecteur d'app natif (mode groupe — cf. _shareImages).
  bool _sharingImages = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _employeePhoneCtrls.values) {
      c.dispose();
    }
    _freeNameCtrl.dispose();
    _freePhoneCtrl.dispose();
    _senderCityCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  /// Construit le callback qui retourne `Product.name` (nom principal
  /// défini lors de l'enregistrement, à côté de catégorie/marque) pour
  /// un SaleItem donné. Match par `productId` dans Hive.
  String? Function(SaleItem) _buildProductNameResolver() {
    final products = LocalStorageService.getProductsForShop(widget.shopId);
    final byId = {for (final p in products) p.id ?? '': p};
    return (SaleItem item) {
      final p = byId[item.productId];
      return p?.name;
    };
  }

  /// Récupère le quartier du client lié à la commande (`Client.district`)
  /// via Hive. Pour les commandes web, c'est la source de vérité car
  /// `sale.deliveryAddress` reste vide (l'adresse a été stockée dans
  /// `clients` lors de l'upsert RPC, cf. hotfix_047).
  String? _resolveClientDistrict() {
    final clientId = widget.order.clientId;
    if (clientId == null || clientId.isEmpty) return null;
    final clients = AppDatabase.getClientsForShop(widget.shopId);
    for (final c in clients) {
      if (c.id == clientId) return c.district;
    }
    return null;
  }

  /// Si le destinataire actuel est un partenaire, retrouve la
  /// `StockLocation` complète via Hive. Sert à 2 endroits :
  ///   • passer `partnerId` à `resolveForRecipient` (priorité au défaut
  ///     du partenaire dans la chaîne de résolution — hotfix_093)
  ///   • passer l'objet partenaire au builder pour résoudre les variables
  ///     `{{partner_*}}` au rendu.
  StockLocation? _resolvePartnerLocation() {
    if (_target?.kind != 'partner') return null;
    final ownerId = Supabase.instance.client.auth.currentUser?.id;
    if (ownerId == null) return null;
    final partners = AppDatabase.getStockLocationsForOwner(ownerId);
    for (final p in partners) {
      if (p.id == _target!.ref) return p;
    }
    return null;
  }

  // ── Step 0 → Step 1 : compose le message depuis le template ───────────
  void _goToPreview() {
    if (_target == null) return;
    final repo    = ref.read(deliveryTemplateRepositoryProvider);
    final partner = _resolvePartnerLocation();
    final tpl     = repo.resolveForRecipient(
        shopId: widget.shopId,
        partnerId: partner?.id,
        overrideTemplateId: _target!.templateId);
    if (tpl == null) {
      setState(() => _error = context.l10n.deliveryNoTemplate);
      return;
    }
    final msg = DeliveryMessageBuilder.build(
        template: tpl,
        sale: widget.order,
        shopName: widget.shopName,
        senderCity: _senderCityCtrl.text.trim().isEmpty
            ? null
            : _senderCityCtrl.text.trim(),
        clientDistrict: _resolveClientDistrict(),
        partner: partner,
        resolveProductName: _buildProductNameResolver());
    _messageCtrl.text = msg;
    setState(() {
      _step    = 1;
      _editing = false;
      _error   = null;
    });
  }

  /// Ré-applique le template (annule l'édition manuelle).
  void _resetMessage() {
    if (_target == null) return;
    final repo    = ref.read(deliveryTemplateRepositoryProvider);
    final partner = _resolvePartnerLocation();
    final tpl     = repo.resolveForRecipient(
        shopId: widget.shopId,
        partnerId: partner?.id,
        overrideTemplateId: _target!.templateId);
    if (tpl == null) return;
    _messageCtrl.text = DeliveryMessageBuilder.build(
        template: tpl,
        sale: widget.order,
        shopName: widget.shopName,
        senderCity: _senderCityCtrl.text.trim().isEmpty
            ? null
            : _senderCityCtrl.text.trim(),
        clientDistrict: _resolveClientDistrict(),
        partner: partner,
        resolveProductName: _buildProductNameResolver());
    setState(() => _editing = false);
  }

  Uri _buildWaUri() {
    final digits = _target!.phoneE164.replaceAll(RegExp(r'[^\d]'), '');
    return Uri.parse('https://wa.me/$digits'
        '?text=${Uri.encodeComponent(_messageCtrl.text)}');
  }

  /// Persiste le transfert via la RPC (atomique : status=processing +
  /// audit dans delivery_transfers). Retourne true si OK.
  Future<bool> _persistTransfer() async {
    if (_target == null) return false;
    setState(() { _sending = true; _error = null; });
    try {
      final db  = Supabase.instance.client;
      final partner = _resolvePartnerLocation();
      final tpl = ref.read(deliveryTemplateRepositoryProvider)
          .resolveForRecipient(
              shopId: widget.shopId,
              partnerId: partner?.id,
              overrideTemplateId: _target!.templateId);
      await db.rpc('transfer_order_to_delivery', params: {
        'p_order_id':         widget.order.id,
        'p_target_type':      _target!.kind,
        'p_target_ref':       _target!.ref,
        'p_target_name':      _target!.name,
        'p_target_phone':     _target!.phoneE164.isEmpty
                                  ? null : _target!.phoneE164,
        'p_template_id':      tpl?.id,
        'p_message_snapshot': _messageCtrl.text,
        'p_target_group_url': _target!.groupUrl.isEmpty
                                  ? null : _target!.groupUrl,
      });
      return true;
    } catch (e) {
      if (mounted) {
        final msg = e.toString();
        setState(() => _error = msg.contains('delivery_transfer_forbidden')
            ? context.l10n.deliveryTransferForbidden
            : msg);
      }
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Télécharge les images des produits de la commande et les partage
  /// via le sélecteur d'app natif. L'utilisateur choisit WhatsApp (puis
  /// le groupe) pour les envoyer. Sur web, `share_plus` délègue à
  /// `navigator.share` (Web Share API Level 2) — supporté par Chrome
  /// Android et Safari iOS, dégradé sinon.
  Future<void> _shareImages() async {
    final urls = widget.order.items
        .map((it) => (it.imageUrl ?? '').trim())
        .where((u) => u.isNotEmpty)
        .toSet()
        .toList();
    if (urls.isEmpty) return;
    setState(() => _sharingImages = true);
    try {
      final files = <XFile>[];
      for (var i = 0; i < urls.length; i++) {
        try {
          final res = await http.get(Uri.parse(urls[i]))
              .timeout(const Duration(seconds: 12));
          if (res.statusCode != 200) continue;
          final ext = _extFromContentType(res.headers['content-type']);
          files.add(XFile.fromData(
            res.bodyBytes,
            name: 'produit_${i + 1}.$ext',
            mimeType: res.headers['content-type'] ?? 'image/jpeg',
          ));
        } catch (e) {
          debugPrint('[Transfer] image dl error ($i): $e');
        }
      }
      if (files.isEmpty) {
        if (mounted) {
          AppSnack.error(context,
              'Impossible de télécharger les images. Réessaie ou télécharge-les manuellement.');
        }
        return;
      }
      // Le texte du message est inclus comme légende — l'utilisateur
      // peut l'effacer si l'app destination ne le supporte pas avec
      // les images.
      await Share.shareXFiles(files, text: _messageCtrl.text);
    } finally {
      if (mounted) setState(() => _sharingImages = false);
    }
  }

  String _extFromContentType(String? ct) {
    if (ct == null) return 'jpg';
    if (ct.contains('png')) return 'png';
    if (ct.contains('webp')) return 'webp';
    if (ct.contains('gif')) return 'gif';
    return 'jpg';
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // PopScope intercepte le back natif (gesture iOS / bouton Android) :
    // si on est à l'étape 1, on revient à l'étape 0 au lieu de fermer la
    // page. Sur desktop, le X du FormSheetHeader ferme directement (pas
    // de back gesture, donc pas d'effet).
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step > 0) {
          setState(() => _step = 0);
        }
      },
      child: AdaptiveFormFrame(
        title: l.deliveryTransferTitle,
        subtitle: _step == 0
            ? l.deliveryTargetSection
            : l.deliveryPreviewTitle,
        icon: Icons.local_shipping_rounded,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Step indicator + back inter-étapes (sans fermer la page).
            if (_step > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _step = 0),
                    icon: const Icon(Icons.arrow_back_rounded, size: 14),
                    label: Text(l.deliveryTargetSection,
                        style: AppTextStyles.bodySm),
                  ),
                ),
              ),
            // Contenu de l'étape.
            _step == 0 ? _buildTargetStep(null) : _buildPreviewStep(null),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Text(_error!,
                    style: AppTextStyles.captionHint
                        .copyWith(color: AppColors.error)),
              ),
            Divider(
                height: 1, color: Theme.of(context).semantic.borderSubtle),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: _step == 0
                    ? _buildTargetFooter()
                    : _buildPreviewFooter(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Step 0 — Sélection destinataire ───────────────────────────────────
  Widget _buildTargetStep(ScrollController? sc) {
    final l = context.l10n;
    final ownerId = Supabase.instance.client.auth.currentUser?.id;
    final partners = ownerId == null
        ? const <StockLocation>[]
        : AppDatabase.getStockLocationsForOwner(ownerId)
            .where((loc) => loc.type == StockLocationType.partner
                && loc.isActive
                // Au moins un canal de contact (phone ou groupe).
                && ((loc.phone ?? '').isNotEmpty
                    || (loc.whatsappGroupUrl ?? '').isNotEmpty))
            .toList();
    final asyncEmployees = ref.watch(employeesProvider(widget.shopId));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        // ── Ville d'expédition (variable {{ville_expedition}}) ──────
        // Pré-remplie automatiquement depuis l'adresse du partenaire
        // sélectionné, modifiable manuellement.
        const _SectionHeader(label: 'Ville d\'expédition'),
        const SizedBox(height: 6),
        AppField(
          controller: _senderCityCtrl,
          hint: 'Ex : Yaoundé · Bonamoussadi',
          prefixIcon: Icons.place_outlined,
        ),
        const SizedBox(height: 16),
        // ── Section partenaires ───────────────────────────────────────
        if (partners.isNotEmpty) ...[
          _SectionHeader(label: l.deliveryTargetPartners),
          for (final p in partners)
            _PartnerRow(
              location: p,
              selected: _target?.kind == 'partner' && _target?.ref == p.id,
              onTap: () => setState(() {
                final group = (p.whatsappGroupUrl ?? '').trim();
                _target = _SelectedTarget(
                  kind: 'partner',
                  ref:  p.id,
                  name: p.name,
                  phoneE164: group.isNotEmpty
                      ? ''
                      : (p.phone ?? '').trim(),
                  groupUrl:  group,
                  templateId: p.deliveryTemplateId,
                );
                // Pré-remplit la ville d'expédition avec city/district
                // du partenaire (cf. hotfix_051). Fallback sur address legacy.
                if (_senderCityCtrl.text.trim().isEmpty) {
                  final c = (p.city ?? '').trim();
                  final d = (p.district ?? '').trim();
                  if (c.isNotEmpty || d.isNotEmpty) {
                    _senderCityCtrl.text =
                        [d, c].where((s) => s.isNotEmpty).join(', ');
                  } else {
                    _senderCityCtrl.text = (p.address ?? '').trim();
                  }
                }
              }),
            ),
          const SizedBox(height: 16),
        ],
        // ── Section employés ──────────────────────────────────────────
        _SectionHeader(label: l.deliveryTargetEmployees),
        asyncEmployees.when(
          loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child:
                  CircularProgressIndicator(strokeWidth: 2))),
          error: (e, _) => Padding(
              padding: const EdgeInsets.all(12),
              child: Text(e.toString(),
                  style: AppTextStyles.captionHint
                      .copyWith(color: AppColors.error))),
          data: (list) => Column(children: [
            for (final e in list)
              _EmployeeRow(
                employee: e,
                selected: _target?.kind == 'employee'
                    && _target?.ref == e.userId,
                phoneCtrl: _employeePhoneCtrls.putIfAbsent(
                    e.userId, () => TextEditingController()),
                onTap: () => setState(() {
                  _target = _SelectedTarget(
                    kind: 'employee', ref: e.userId, name: e.fullName,
                    phoneE164: _employeePhoneFull[e.userId] ?? '',
                  );
                }),
                onPhoneChanged: (full, valid) {
                  _employeePhoneFull[e.userId]  = full;
                  _employeePhoneValid[e.userId] = valid;
                  if (_target?.kind == 'employee'
                      && _target?.ref == e.userId) {
                    setState(() {
                      _target = _SelectedTarget(
                        kind: 'employee', ref: e.userId,
                        name: e.fullName, phoneE164: full,
                      );
                    });
                  } else {
                    setState(() {});
                  }
                },
              ),
          ]),
        ),
        const SizedBox(height: 16),
        // ── Section numéro libre ──────────────────────────────────────
        _SectionHeader(label: l.deliveryTargetFree),
        const SizedBox(height: 6),
        AppField(
          controller: _freeNameCtrl,
          hint: l.deliveryTargetNameHint,
          prefixIcon: Icons.person_outline_rounded,
          onChanged: (_) => _refreshFreeTarget(),
        ),
        const SizedBox(height: 8),
        AppField(
          controller: _freePhoneCtrl,
          isPhone: true,
          onPhoneChanged: (full, valid) {
            _freePhoneFull  = full;
            _freePhoneValid = valid;
            _refreshFreeTarget();
          },
        ),
      ],
      ),
    );
  }

  void _refreshFreeTarget() {
    final name = _freeNameCtrl.text.trim();
    if (name.isEmpty || !_freePhoneValid) {
      if (_target?.kind == 'free') {
        setState(() => _target = null);
      }
      return;
    }
    setState(() {
      _target = _SelectedTarget(
        kind: 'free', name: name, phoneE164: _freePhoneFull,
      );
    });
  }

  Widget _buildTargetFooter() {
    final l = context.l10n;
    final canNext = _target != null
        && (_target!.phoneE164.isNotEmpty || _target!.groupUrl.isNotEmpty);
    return SizedBox(
      width: double.infinity, height: 44,
      child: ElevatedButton.icon(
        onPressed: canNext ? _goToPreview : null,
        icon: const Icon(Icons.arrow_forward_rounded, size: 16),
        label: Text(l.deliveryPreviewTitle,
            style: AppTextStyles.bodyBold
                .copyWith(color: Colors.white)),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFFE5E7EB),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
          elevation: 0,
        ),
      ),
    );
  }

  // ── Step 1 — Aperçu + envoi ───────────────────────────────────────────
  Widget _buildPreviewStep(ScrollController? sc) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        Row(children: [
          Expanded(child: Text(
              '${_target!.name} · '
              '${_target!.isGroup ? "Groupe WhatsApp" : _target!.phoneE164}',
              style: AppTextStyles.bodySmBold)),
          TextButton.icon(
            onPressed: _sending
                ? null
                : () => setState(() => _editing = !_editing),
            icon: Icon(_editing
                    ? Icons.check_rounded
                    : Icons.edit_rounded,
                size: 14),
            label: Text(_editing ? l.commonSave : l.deliveryPreviewEditBtn,
                style: AppTextStyles.captionHint
                    .copyWith(color: AppColors.primary)),
            style: TextButton.styleFrom(
                foregroundColor: AppColors.primary),
          ),
          if (_editing)
            TextButton.icon(
              onPressed: _sending ? null : _resetMessage,
              icon: const Icon(Icons.refresh_rounded, size: 14),
              label: Text(l.deliveryPreviewResetBtn,
                  style: AppTextStyles.captionHint
                      .copyWith(color: AppColors.warning)),
              style: TextButton.styleFrom(
                  foregroundColor: AppColors.warning),
            ),
        ]),
        const SizedBox(height: 6),
        if (_editing)
          TextField(
            controller: _messageCtrl,
            maxLines: null, minLines: 10,
            style: const TextStyle(
                fontSize: 12, height: 1.5, fontFamily: 'monospace'),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFFF9FAFB),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                      color: Theme.of(context).semantic.borderSubtle)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                      color: Theme.of(context).semantic.borderSubtle)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                      color: AppColors.primary, width: 1.5)),
              contentPadding: const EdgeInsets.all(12),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: Theme.of(context).semantic.borderSubtle),
            ),
            child: Text(_messageCtrl.text,
                style: const TextStyle(
                    fontSize: 12, height: 1.5, fontFamily: 'monospace')),
          ),
      ],
      ),
    );
  }

  Widget _buildPreviewFooter() {
    if (_target == null) return const SizedBox.shrink();
    return _target!.isGroup
        ? _buildGroupFooter()
        : _buildDirectFooter();
  }

  /// Mode 1-à-1 : un seul bouton WhatsApp qui ouvre wa.me/<phone>?text=...
  Widget _buildDirectFooter() {
    final l = context.l10n;
    final uri = _buildWaUri();
    return Link(
      uri: uri,
      target: LinkTarget.blank,
      builder: (ctx, follow) => SizedBox(
        width: double.infinity, height: 44,
        child: ElevatedButton.icon(
          onPressed: _sending
              ? null
              : () async {
                  final ok = await _persistTransfer();
                  if (!ok) return;
                  if (!kIsWeb && follow != null) follow();
                  if (mounted) {
                    Navigator.of(context).pop(true);
                    AppSnack.success(context, l.deliverySent);
                  }
                },
          icon: _sending
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.send_rounded, size: 16),
          label: Text(l.deliverySendBtn,
              style: AppTextStyles.bodyBold
                  .copyWith(color: Colors.white)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF25D366),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFFE5E7EB),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            elevation: 0,
          ),
        ),
      ),
    );
  }

  /// Mode groupe : 2 boutons côte-à-côte. WhatsApp ne supporte pas le
  /// deep-link `text=` sur les groupes → workflow semi-manuel : on copie
  /// le message dans le presse-papiers et on ouvre le lien d'invitation
  /// au groupe ; l'utilisateur fait Ctrl+V dans le groupe.
  Widget _buildGroupFooter() {
    final l = context.l10n;
    final uri = Uri.parse(_target!.groupUrl);
    final hasImages = widget.order.items
        .any((it) => (it.imageUrl ?? '').isNotEmpty);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        // Bouton "Copier"
        Expanded(
          child: SizedBox(
            height: 44,
            child: OutlinedButton.icon(
              onPressed: _sending
                  ? null
                  : () async {
                      await Clipboard.setData(
                          ClipboardData(text: _messageCtrl.text));
                      if (mounted) {
                        AppSnack.success(context, l.deliveryCopied);
                      }
                    },
              icon: const Icon(Icons.copy_rounded, size: 14),
              label: Text(l.deliveryCopyMsgBtn,
                  style: AppTextStyles.bodySmBold
                      .copyWith(color: AppColors.primary)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Bouton "Ouvrir le groupe + persister le transfert"
        Expanded(
          child: Link(
            uri: uri,
            target: LinkTarget.blank,
            builder: (ctx, follow) => SizedBox(
              height: 44,
              child: ElevatedButton.icon(
                onPressed: _sending
                    ? null
                    : () async {
                        // Copie automatique pour éviter une étape manquée.
                        await Clipboard.setData(
                            ClipboardData(text: _messageCtrl.text));
                        final ok = await _persistTransfer();
                        if (!ok) return;
                        if (!kIsWeb && follow != null) follow();
                        if (mounted) {
                          Navigator.of(context).pop(true);
                          AppSnack.success(context, l.deliverySent);
                        }
                      },
                icon: _sending
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.group_rounded, size: 14),
                label: Text(l.deliveryOpenGroupBtn,
                    style: AppTextStyles.bodySmBold
                        .copyWith(color: Colors.white)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFE5E7EB),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ),
          ),
        ),
      ]),
      // Bouton "Partager les images" — uniquement si la commande contient
      // au moins un produit avec image. Ouvre le sélecteur d'app natif
      // (share_plus) pour envoyer les fichiers vers WhatsApp groupe.
      if (hasImages) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 40,
          child: OutlinedButton.icon(
            onPressed: _sharingImages ? null : _shareImages,
            icon: _sharingImages
                ? const SizedBox(
                    width: 12, height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.8))
                : const Icon(Icons.image_outlined, size: 14),
            label: Text(_sharingImages
                    ? 'Préparation des images…'
                    : 'Partager les images',
                style: AppTextStyles.captionBold
                    .copyWith(color: AppColors.warning)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.warning,
              side: BorderSide(color: AppColors.warning),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      ],
    ]);
  }
}

// ═══ Sous-widgets ═════════════════════════════════════════════════════════════

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(label.toUpperCase(),
            style: AppTextStyles.microBold.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppColors.textHint)),
      );
}

class _PartnerRow extends StatelessWidget {
  final StockLocation location;
  final bool          selected;
  final VoidCallback  onTap;
  const _PartnerRow({
    required this.location,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.08)
              : const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? AppColors.primary
                : Theme.of(context).semantic.borderSubtle,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Icon(
              (location.whatsappGroupUrl ?? '').isNotEmpty
                  ? Icons.group_rounded
                  : Icons.store_rounded,
              size: 14, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(location.name,
                  style: AppTextStyles.bodySmBold),
              Text(
                  (location.whatsappGroupUrl ?? '').isNotEmpty
                      ? location.whatsappGroupUrl!
                      : (location.phone ?? ''),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.micro
                      .copyWith(color: const Color(0xFF9CA3AF))),
            ],
          )),
          if (selected)
            Icon(Icons.check_circle_rounded,
                size: 16, color: AppColors.primary),
        ]),
      ),
    );
  }
}

class _EmployeeRow extends StatelessWidget {
  final Employee                  employee;
  final bool                      selected;
  final TextEditingController     phoneCtrl;
  final VoidCallback              onTap;
  final void Function(String, bool) onPhoneChanged;
  const _EmployeeRow({
    required this.employee,
    required this.selected,
    required this.phoneCtrl,
    required this.onTap,
    required this.onPhoneChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.primary.withValues(alpha: 0.08)
            : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected
              ? AppColors.primary
              : Theme.of(context).semantic.borderSubtle,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Column(children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 8),
            child: Row(children: [
              Icon(Icons.person_rounded,
                  size: 14, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(employee.fullName,
                      style: AppTextStyles.bodySmBold),
                  Text(employee.email,
                      style: AppTextStyles.micro
                          .copyWith(color: const Color(0xFF9CA3AF))),
                ],
              )),
              if (selected)
                Icon(Icons.check_circle_rounded,
                    size: 16, color: AppColors.primary),
            ]),
          ),
        ),
        // PhoneField inline si l'employé est sélectionné (pas de phone
        // sur profiles → on demande au moment du transfert).
        if (selected)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: AppField(
              controller: phoneCtrl,
              isPhone: true,
              onPhoneChanged: onPhoneChanged,
            ),
          ),
      ]),
    );
  }
}
