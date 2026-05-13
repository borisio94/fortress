import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/link.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/services/document_service.dart';
import '../../../../core/services/url_shortener_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../crm/domain/entities/client.dart';
import '../../domain/entities/product.dart';

/// Dialog 3 étapes : produits → destinataires (clients + numéros libres) →
/// envoi WhatsApp un-par-un (anti-popup-blocker via `Link target=blank`).
///
/// • Étape 1 (clients) : sélection multi des clients avec phone + champ
///   `PhoneField` pour ajouter à la volée des numéros libres (E.164).
/// • Étape 2 (envoi) : aperçu du message + liste des destinataires avec
///   un bouton "Envoyer" par ligne. Chaque clic = un onglet `wa.me`.
///   Compteur "X/N envoyés" + bouton "Copier message + lien".
class ShareCatalogDialog extends StatefulWidget {
  static const int _maxRecipients = 30;

  final List<Product> products;
  final String shopId;
  /// Si fourni, pré-sélectionne ces produits et saute à l'étape 2.
  final List<Product>? preSelected;

  /// Snapshot de stock filtré au moment du partage (clé =
  /// `productId|variantId` si variante, sinon `productId`). Quand fourni,
  /// l'URL générée embarque ces valeurs et le catalogue public les
  /// utilise au lieu du `stock_qty` global Supabase. Permet d'envoyer
  /// le stock du périmètre actuellement visualisé par l'owner (Boutique
  /// seule, Partenaire X, ou Globale) au lieu du cumul brut. Limite
  /// assumée : valeur figée à l'instant du partage (snapshot).
  final Map<String, int>? stockSnapshot;

  const ShareCatalogDialog({
    super.key,
    required this.products,
    required this.shopId,
    this.preSelected,
    this.stockSnapshot,
  });

  static void show(BuildContext context, {
    required List<Product> products,
    required String shopId,
    List<Product>? preSelected,
    Map<String, int>? stockSnapshot,
  }) {
    showDialog(
      context: context,
      builder: (_) => ShareCatalogDialog(
        products: products,
        shopId: shopId,
        preSelected: preSelected,
        stockSnapshot: stockSnapshot,
      ),
    );
  }

  @override
  State<ShareCatalogDialog> createState() => _ShareCatalogDialogState();
}

/// Destinataire d'un envoi catalogue. Couvre clients enregistrés ET numéros
/// libres (saisis dans le PhoneField de l'étape 1).
class _Recipient {
  final String  id;       // client.id pour CRM, sinon "free:<phone>"
  final String  name;     // client.name ou label "Numéro libre"
  final String  phoneE164; // toujours en E.164 (vérifié à l'ajout)
  final bool    isFree;
  const _Recipient({
    required this.id,
    required this.name,
    required this.phoneE164,
    required this.isFree,
  });
}

class _ShareCatalogDialogState extends State<ShareCatalogDialog> {
  int _step = 0;
  final _selectedProducts = <String>{};
  final _selectedClients  = <String>{};
  /// Numéros libres ajoutés via le PhoneField (clé = E.164).
  final _freeRecipients = <_Recipient>[];
  /// IDs des destinataires déjà envoyés (état local seulement).
  final _sentIds = <String>{};

  late List<Client> _clients;
  late TextEditingController _messageCtrl;
  late TextEditingController _phoneCtrl;
  String  _phoneFull   = '';
  bool    _phoneValid  = false;
  String? _phoneError;

  /// URL publique catalogue (raccourcie si possible). Calculée au passage
  /// à l'étape 2 et mise en cache pour les clics suivants.
  String? _shareUrl;
  bool    _shareUrlShort = true;

  @override
  void initState() {
    super.initState();
    _clients = AppDatabase.getClientsForShop(widget.shopId);
    _messageCtrl = TextEditingController();
    _phoneCtrl   = TextEditingController();
    if (widget.preSelected != null) {
      for (final p in widget.preSelected!) {
        if (p.id != null) _selectedProducts.add(p.id!);
      }
      if (_selectedProducts.isNotEmpty) _step = 1;
    }
  }

  @override
  void dispose() {
    _messageCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  // ── Sélections ─────────────────────────────────────────────────────────
  List<Product> get _pickedProducts => widget.products
      .where((p) => p.id != null && _selectedProducts.contains(p.id))
      .toList();

  List<_Recipient> get _allRecipients {
    final fromCrm = _clients
        .where((c) => _selectedClients.contains(c.id)
            && c.phone != null && c.phone!.isNotEmpty)
        .map((c) => _Recipient(
              id: c.id, name: c.name,
              phoneE164: c.phone!, isFree: false))
        .toList();
    return [...fromCrm, ..._freeRecipients];
  }

  int get _totalRecipients => _allRecipients.length;

  // ── Étape 1 → 2 : génère le message + raccourcit l'URL ─────────────────
  Future<void> _goToPreview() async {
    if (_messageCtrl.text.isEmpty) {
      _messageCtrl.text = DocumentService.buildCatalogMessage(
          _pickedProducts, shopId: widget.shopId);
    }
    setState(() => _step = 2);
    // Compose l'URL catalogue (filtre par ids si sous-ensemble).
    final ids = _pickedProducts
        .map((p) => p.id).whereType<String>().toList();
    // S'assurer que les produits partagés sont visibles publiquement —
    // sans ça la RLS Supabase (`products_anon_read_visible_web`) renvoie
    // 0 rows et le destinataire voit "Les produits partagés ne sont plus
    // disponibles publiquement". Le partage = consentement implicite à
    // l'exposition publique. Idempotent, fire-and-forget.
    if (_pickedProducts.isNotEmpty) {
      AppDatabase.markProductsVisibleWeb(_pickedProducts).catchError((e) {
        debugPrint('[Share] markProductsVisibleWeb error: $e');
      });
    }
    final base = 'https://fortress-pos.web.app/#/catalogue/${widget.shopId}';
    // Build query params : `ids` (sous-ensemble produits) + `stock`
    // (snapshot filtré par location). Le snapshot n'est encodé que
    // pour les produits effectivement partagés (sélectionnés). Si
    // aucun snapshot ou tous à 0 → omis (le catalogue retombe sur le
    // cumul global persisté côté Supabase).
    final qp = <String>[];
    if (ids.isNotEmpty) qp.add('ids=${ids.join(",")}');
    final snapshot = widget.stockSnapshot;
    if (snapshot != null && snapshot.isNotEmpty) {
      final selectedIds = ids.toSet();
      final tokens = <String>[];
      for (final entry in snapshot.entries) {
        // Clé = `productId` OU `productId|variantId`. On garde
        // uniquement les entrées concernant les produits partagés.
        final productId = entry.key.split('|').first;
        if (selectedIds.isNotEmpty
            && !selectedIds.contains(productId)) continue;
        tokens.add('${entry.key}:${entry.value}');
      }
      if (tokens.isNotEmpty) qp.add('stock=${tokens.join(",")}');
    }
    final long = qp.isEmpty ? base : '$base?${qp.join("&")}';
    try {
      final shortened = await UrlShortenerService.shorten(long);
      if (mounted) setState(() {
        _shareUrl = shortened;
        _shareUrlShort = shortened != long;
      });
    } catch (_) {
      if (mounted) setState(() {
        _shareUrl = long;
        _shareUrlShort = false;
      });
    }
  }

  // ── Ajout d'un numéro libre ───────────────────────────────────────────
  void _addFreeRecipient() {
    final l = context.l10n;
    if (!_phoneValid || _phoneFull.isEmpty) {
      setState(() => _phoneError = l.catShareInvalidPhone);
      return;
    }
    if (_totalRecipients >= ShareCatalogDialog._maxRecipients) {
      setState(() => _phoneError = l.catShareMaxReached);
      return;
    }
    if (_allRecipients.any((r) => r.phoneE164 == _phoneFull)) {
      setState(() => _phoneError = l.catShareDuplicatePhone);
      return;
    }
    setState(() {
      _freeRecipients.add(_Recipient(
        id: 'free:$_phoneFull',
        name: l.catShareCustomRecipient,
        phoneE164: _phoneFull,
        isFree: true,
      ));
      _phoneCtrl.clear();
      _phoneFull   = '';
      _phoneValid  = false;
      _phoneError  = null;
    });
  }

  void _removeFree(String id) {
    setState(() => _freeRecipients.removeWhere((r) => r.id == id));
  }

  // ── Construction message final + URL pour wa.me ───────────────────────
  String get _fullMessage {
    final base = _messageCtrl.text.trim();
    final url  = _shareUrl ?? '';
    if (url.isEmpty) return base;
    return '$base\n\n$url';
  }

  /// Numéro pour wa.me : digits seuls (E.164 sans le `+`).
  String _phoneDigits(String e164) =>
      e164.replaceAll(RegExp(r'[^\d]'), '');

  Uri _buildWaUri(String e164) => Uri.parse(
      'https://wa.me/${_phoneDigits(e164)}'
      '?text=${Uri.encodeComponent(_fullMessage)}');

  Future<void> _copyMessage() async {
    final l = context.l10n;
    await Clipboard.setData(ClipboardData(text: _fullMessage));
    if (mounted) AppSnack.success(context, l.catShareCopied);
  }

  // ── Build ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(children: [
          _Header(step: _step,
              onBack: _step > 0 ? () => setState(() => _step--) : null),
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
          Expanded(child: switch (_step) {
            0 => _ProductStep(
                  products: widget.products,
                  selected: _selectedProducts,
                  onToggle: (id) => setState(() {
                    _selectedProducts.contains(id)
                        ? _selectedProducts.remove(id)
                        : _selectedProducts.add(id);
                  }),
                  onSelectAll: () => setState(() {
                    if (_selectedProducts.length == widget.products.length) {
                      _selectedProducts.clear();
                    } else {
                      _selectedProducts.addAll(widget.products
                          .map((p) => p.id).whereType<String>());
                    }
                  }),
                ),
            1 => _RecipientsStep(
                  clients: _clients,
                  selectedClients: _selectedClients,
                  freeRecipients: _freeRecipients,
                  totalSelected: _totalRecipients,
                  maxRecipients: ShareCatalogDialog._maxRecipients,
                  phoneCtrl: _phoneCtrl,
                  phoneError: _phoneError,
                  onPhoneChanged: (full, valid) {
                    _phoneFull  = full;
                    _phoneValid = valid;
                    if (_phoneError != null) {
                      setState(() => _phoneError = null);
                    }
                  },
                  onAddFree:    _addFreeRecipient,
                  onRemoveFree: _removeFree,
                  onToggleClient: (id) => setState(() {
                    _selectedClients.contains(id)
                        ? _selectedClients.remove(id)
                        : _selectedClients.add(id);
                  }),
                ),
            _ => _SendStep(
                  messageCtrl: _messageCtrl,
                  recipients: _allRecipients,
                  sentIds: _sentIds,
                  shareUrl: _shareUrl,
                  shareUrlShort: _shareUrlShort,
                  onSent: (id) => setState(() => _sentIds.add(id)),
                  onCopy: _copyMessage,
                  buildWaUri: _buildWaUri,
                ),
          }),
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
          Padding(
            padding: const EdgeInsets.all(14),
            child: switch (_step) {
              0 => _FooterBtn(
                    label: 'Suivant — ${_selectedProducts.length} produit'
                        '${_selectedProducts.length > 1 ? 's' : ''}',
                    enabled: _selectedProducts.isNotEmpty,
                    onTap: () => setState(() => _step = 1),
                  ),
              1 => _FooterBtn(
                    label: '${context.l10n.catShareTitle} — '
                        '$_totalRecipients/${ShareCatalogDialog._maxRecipients}',
                    enabled: _totalRecipients > 0,
                    onTap: _goToPreview,
                    icon: Icons.arrow_forward_rounded,
                  ),
              _ => _FooterBtn(
                    label: context.l10n.catShareCounter(
                        _sentIds.length, _totalRecipients),
                    enabled: true,
                    onTap: () => Navigator.of(context).pop(),
                    icon: Icons.check_rounded,
                    color: AppColors.secondary,
                  ),
            },
          ),
        ]),
      ),
    );
  }
}

// ═══ Header ═══════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final int step;
  final VoidCallback? onBack;
  const _Header({required this.step, this.onBack});

  static const _icons = [
    Icons.inventory_2_rounded,
    Icons.people_rounded,
    Icons.send_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final titles = [
      'Sélectionner les produits',
      l.catShareRecipients,
      l.catShareTitle,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(children: [
        if (onBack != null)
          IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(8)),
          child: Icon(_icons[step], size: 16, color: AppColors.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(titles[step],
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A))),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) => Container(
            width: i == step ? 16 : 6, height: 6,
            margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(
                color: i == step ? AppColors.primary : const Color(0xFFE5E7EB),
                borderRadius: BorderRadius.circular(3)),
          )),
        ),
      ]),
    );
  }
}

// ═══ Étape 1 — Produits ═══════════════════════════════════════════════════════

class _ProductStep extends StatelessWidget {
  final List<Product> products;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAll;
  const _ProductStep({
    required this.products,
    required this.selected,
    required this.onToggle,
    required this.onSelectAll,
  });

  @override
  Widget build(BuildContext context) {
    final allSelected = selected.length == products.length;
    return Column(children: [
      InkWell(
        onTap: onSelectAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Icon(allSelected
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 20, color: AppColors.primary),
            const SizedBox(width: 8),
            Text(allSelected ? 'Tout désélectionner' : 'Tout sélectionner',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary)),
            const Spacer(),
            Text('${selected.length}/${products.length}',
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF9CA3AF))),
          ]),
        ),
      ),
      const Divider(height: 1),
      Expanded(child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: products.length,
        itemBuilder: (_, i) {
          final p = products[i];
          final sel = p.id != null && selected.contains(p.id);
          return InkWell(
            onTap: () { if (p.id != null) onToggle(p.id!); },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              child: Row(children: [
                Icon(sel
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 20,
                    color: sel
                        ? AppColors.primary
                        : const Color(0xFFD1D5DB)),
                const SizedBox(width: 10),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                        p.priceSellPos > 0
                            ? CurrencyFormatter.format(p.priceSellPos)
                            : 'Prix non défini',
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF9CA3AF))),
                  ],
                )),
                Text('Stock: ${p.totalStock}',
                    style: const TextStyle(
                        fontSize: 10, color: Color(0xFF9CA3AF))),
              ]),
            ),
          );
        },
      )),
    ]);
  }
}

// ═══ Étape 2 — Destinataires (clients + numéros libres) ═══════════════════════

class _RecipientsStep extends StatelessWidget {
  final List<Client> clients;
  final Set<String> selectedClients;
  final List<_Recipient> freeRecipients;
  final int totalSelected;
  final int maxRecipients;
  final TextEditingController phoneCtrl;
  final String? phoneError;
  final void Function(String fullNumber, bool isValid) onPhoneChanged;
  final VoidCallback onAddFree;
  final ValueChanged<String> onRemoveFree;
  final ValueChanged<String> onToggleClient;
  const _RecipientsStep({
    required this.clients,
    required this.selectedClients,
    required this.freeRecipients,
    required this.totalSelected,
    required this.maxRecipients,
    required this.phoneCtrl,
    required this.phoneError,
    required this.onPhoneChanged,
    required this.onAddFree,
    required this.onRemoveFree,
    required this.onToggleClient,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final clientsWithPhone =
        clients.where((c) => c.phone != null && c.phone!.isNotEmpty).toList();
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        // ── Section "Autre destinataire" ─────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(l.catShareOtherNumber.toUpperCase(),
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: AppColors.textHint)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: AppField(
                controller: phoneCtrl,
                isPhone: true,
                onPhoneChanged: onPhoneChanged,
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: totalSelected >= maxRecipients ? null : onAddFree,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
              child: Text(l.catShareAddBtn,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
        if (phoneError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(phoneError!,
                style: TextStyle(
                    fontSize: 11, color: AppColors.error)),
          ),
        // Chip-list des numéros libres ajoutés.
        if (freeRecipients.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Wrap(
              spacing: 6, runSpacing: 6,
              children: [
                for (final r in freeRecipients)
                  Chip(
                    label: Text(r.phoneE164,
                        style: const TextStyle(fontSize: 11)),
                    deleteIcon:
                        const Icon(Icons.close_rounded, size: 14),
                    onDeleted: () => onRemoveFree(r.id),
                    backgroundColor: AppColors.primarySurface,
                    side: BorderSide(
                        color: AppColors.primary.withValues(alpha: 0.3)),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        const Divider(height: 1),
        // ── Section "Clients enregistrés" ─────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Row(children: [
            Expanded(
              child: Text('CLIENTS',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      color: AppColors.textHint)),
            ),
            Text('$totalSelected/$maxRecipients',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textHint)),
          ]),
        ),
        if (clientsWithPhone.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text('Aucun client avec téléphone',
                style: TextStyle(
                    fontSize: 12, color: AppColors.textHint))),
          )
        else
          for (final c in clientsWithPhone)
            _ClientRow(
              client: c,
              selected: selectedClients.contains(c.id),
              disabled: !selectedClients.contains(c.id)
                  && totalSelected >= maxRecipients,
              onToggle: () => onToggleClient(c.id),
            ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _ClientRow extends StatelessWidget {
  final Client client;
  final bool selected;
  final bool disabled;
  final VoidCallback onToggle;
  const _ClientRow({
    required this.client,
    required this.selected,
    required this.disabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.45 : 1.0,
      child: InkWell(
        onTap: disabled ? null : onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Icon(selected
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 20,
                color: selected
                    ? AppColors.primary
                    : const Color(0xFFD1D5DB)),
            const SizedBox(width: 10),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(client.name,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(client.phone ?? '',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF9CA3AF))),
              ],
            )),
          ]),
        ),
      ),
    );
  }
}

// ═══ Étape 3 — Envoi (aperçu + boutons un-par-un) ═════════════════════════════

class _SendStep extends StatelessWidget {
  final TextEditingController messageCtrl;
  final List<_Recipient> recipients;
  final Set<String> sentIds;
  final String? shareUrl;
  final bool    shareUrlShort;
  final ValueChanged<String> onSent;
  final VoidCallback onCopy;
  final Uri Function(String e164) buildWaUri;
  const _SendStep({
    required this.messageCtrl,
    required this.recipients,
    required this.sentIds,
    required this.shareUrl,
    required this.shareUrlShort,
    required this.onSent,
    required this.onCopy,
    required this.buildWaUri,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        // Aperçu message éditable.
        Text('MESSAGE',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppColors.textHint)),
        const SizedBox(height: 6),
        TextField(
          controller: messageCtrl,
          maxLines: 5,
          minLines: 3,
          style: const TextStyle(fontSize: 13, height: 1.4),
          decoration: InputDecoration(
            hintText: 'Message catalogue...',
            filled: true,
            fillColor: const Color(0xFFF9FAFB),
            isDense: true,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    const BorderSide(color: Color(0xFFE5E7EB))),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    const BorderSide(color: Color(0xFFE5E7EB))),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    BorderSide(color: AppColors.primary, width: 1.5)),
          ),
        ),
        if (shareUrl != null) ...[
          const SizedBox(height: 6),
          Row(children: [
            Icon(shareUrlShort
                    ? Icons.link_rounded
                    : Icons.link_off_rounded,
                size: 12,
                color: shareUrlShort
                    ? AppColors.secondary
                    : AppColors.warning),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                  shareUrlShort ? shareUrl! : l.catShareShortenerError,
                  style: TextStyle(
                      fontSize: 10,
                      color: shareUrlShort
                          ? AppColors.textHint
                          : AppColors.warning),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
        ],
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy_rounded, size: 14),
              label: Text(l.catShareCopyBtn,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(
                    color: AppColors.primary.withValues(alpha: 0.4)),
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Text('${l.catShareRecipients.toUpperCase()} '
                '(${recipients.length})',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: AppColors.textHint)),
          ),
          Text(l.catShareCounter(sentIds.length, recipients.length),
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: sentIds.length == recipients.length
                      && recipients.isNotEmpty
                      ? AppColors.secondary
                      : AppColors.textHint)),
        ]),
        const SizedBox(height: 6),
        for (final r in recipients)
          _RecipientRow(
            recipient: r,
            sent: sentIds.contains(r.id),
            uri: buildWaUri(r.phoneE164),
            onSent: () => onSent(r.id),
          ),
      ],
    );
  }
}

class _RecipientRow extends StatelessWidget {
  final _Recipient recipient;
  final bool sent;
  final Uri uri;
  final VoidCallback onSent;
  const _RecipientRow({
    required this.recipient,
    required this.sent,
    required this.uri,
    required this.onSent,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: sent
            ? AppColors.secondary.withValues(alpha: 0.08)
            : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: sent
              ? AppColors.secondary.withValues(alpha: 0.4)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: Row(children: [
        Icon(recipient.isFree
                ? Icons.dialpad_rounded
                : Icons.person_rounded,
            size: 14,
            color: recipient.isFree ? AppColors.warning : AppColors.primary),
        const SizedBox(width: 8),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(recipient.name,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(recipient.phoneE164,
                style: const TextStyle(
                    fontSize: 10, color: Color(0xFF9CA3AF))),
          ],
        )),
        // Bouton "Envoyer" via Link target=blank — sur web, contourne le
        // popup blocker car c'est un anchor HTML natif. Sur mobile/desktop,
        // ouvre l'app WhatsApp (deep link wa.me).
        Link(
          uri: uri,
          target: LinkTarget.blank,
          builder: (ctx, follow) => ElevatedButton.icon(
            onPressed: sent ? null : () {
              // kIsWeb : Link gère l'ouverture native via l'anchor `<a>`.
              // Native : on délègue au follow() de url_launcher.
              if (!kIsWeb && follow != null) follow();
              onSent();
            },
            icon: Icon(
                sent ? Icons.check_rounded : Icons.send_rounded,
                size: 12),
            label: Text(sent ? l.catShareSentBadge : l.catShareSendBtn,
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700)),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  sent ? AppColors.secondary : const Color(0xFF25D366),
              foregroundColor: Colors.white,
              disabledBackgroundColor:
                  AppColors.secondary.withValues(alpha: 0.6),
              disabledForegroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
              elevation: 0,
              minimumSize: const Size(0, 30),
            ),
          ),
        ),
      ]),
    );
  }
}

// ═══ Footer button ═══════════════════════════════════════════════════════════

class _FooterBtn extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Color? color;
  final IconData? icon;
  const _FooterBtn({
    required this.label,
    required this.enabled,
    required this.onTap,
    this.color,
    this.icon,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity, height: 44,
        child: ElevatedButton.icon(
          onPressed: enabled ? onTap : null,
          icon: icon != null
              ? Icon(icon, size: 16)
              : const SizedBox.shrink(),
          label: Text(label,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700)),
          style: ElevatedButton.styleFrom(
            backgroundColor: color ?? AppColors.primary,
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFFE5E7EB),
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        ),
      );
}
