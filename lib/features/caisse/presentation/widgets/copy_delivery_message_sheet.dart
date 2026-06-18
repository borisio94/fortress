import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/delivery_image_service.dart';
import '../../../../core/services/delivery_share_outcome.dart';
import '../../../../core/services/delivery_share.dart'
    if (dart.library.html) '../../../../core/services/delivery_share_web.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import '../../../parametres/presentation/providers/delivery_template_provider.dart';
import '../../domain/entities/sale.dart';
import '../../domain/entities/sale_item.dart';
import '../../domain/services/delivery_message_builder.dart';

/// Sheet « Copier le message livraison » — remplace l'ancien
/// `TransferDeliverySheet` qui essayait d'ouvrir wa.me/<phone>.
/// Le user envoie en réalité dans un groupe WhatsApp unique (wa.me ne
/// supporte pas les groupes), donc on se contente de générer le message
/// final et de le mettre dans le presse-papier. Le user colle ensuite
/// manuellement dans son groupe.
///
/// UI :
///   1. Picker partenaire (radio chips) — détermine quel template est
///      résolu + remplit les variables `{{partner_*}}`.
///   2. Champ ville d'expédition optionnel (résout `{{ville_expedition}}`).
///   3. Aperçu éditable du message rendu (variables résolues, lien court
///      `{{produits}}` généré).
///   4. Bouton « Copier le message » → clipboard + snack + fermeture.
class CopyDeliveryMessageSheet extends ConsumerStatefulWidget {
  final Sale   order;
  final String shopId;
  final String shopName;
  const CopyDeliveryMessageSheet({
    super.key,
    required this.order,
    required this.shopId,
    required this.shopName,
  });

  @override
  ConsumerState<CopyDeliveryMessageSheet> createState() =>
      _CopyDeliveryMessageSheetState();
}

class _CopyDeliveryMessageSheetState
    extends ConsumerState<CopyDeliveryMessageSheet> {
  StockLocation? _partner; // null = shop-wide
  final _senderCityCtrl = TextEditingController();
  final _messageCtrl    = TextEditingController();

  bool    _generating  = false;
  bool    _copying     = false; // copie image en cours
  bool    _copyingText = false; // copie texte en cours
  String? _error;

  // Image produits pré-générée. Ne dépend QUE de la commande/des produits
  // (plus du texte) → construite une fois à l'ouverture. Pré-build pour que
  // la COPIE presse-papier suive le clic au plus près (l'API navigateur
  // exige un geste utilisateur récent).
  Uint8List? _imageBytes;
  bool       _imageIsPng = true;

  @override
  void initState() {
    super.initState();
    // Pré-build du message ET de l'image produits au premier frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildMessage();
      _pregenerateImage();
    });
  }

  @override
  void dispose() {
    _senderCityCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  // ── Resolvers (mêmes helpers que l'ancien TransferDeliverySheet) ──────
  String? Function(SaleItem) _buildProductNameResolver() {
    final products = LocalStorageService.getProductsForShop(widget.shopId);
    final byId = {for (final p in products) p.id ?? '': p};
    return (SaleItem item) => byId[item.productId]?.name;
  }

  /// Résout le SKU pour `produits_text` (identifiant précis affiché À LA
  /// PLACE du nom). Gère les variantes : SKU de la variante commandée si
  /// présent, sinon SKU du produit parent.
  String? Function(SaleItem) _buildProductSkuResolver() {
    final products = LocalStorageService.getProductsForShop(widget.shopId);
    final byId = {for (final p in products) p.id ?? '': p};
    final variantParent = <String, String>{};
    for (final p in products) {
      final pid = p.id;
      if (pid == null) continue;
      for (final v in p.variants) {
        final vid = v.id;
        if (vid != null) variantParent[vid] = pid;
      }
    }
    return (SaleItem item) {
      final parentId = variantParent[item.productId];
      if (parentId != null) {
        final parent = byId[parentId];
        if (parent != null) {
          for (final v in parent.variants) {
            if (v.id == item.productId) {
              final s = (v.sku ?? '').trim();
              if (s.isNotEmpty) return s;
              break;
            }
          }
          return parent.sku;
        }
        return null;
      }
      return byId[item.productId]?.sku;
    };
  }

  String? _resolveClientDistrict() {
    final clientId = widget.order.clientId;
    if (clientId == null || clientId.isEmpty) return null;
    for (final c in AppDatabase.getClientsForShop(widget.shopId)) {
      if (c.id == clientId) return c.district;
    }
    return null;
  }

  void _rebuildMessage() {
    setState(() {
      _generating = true;
      _error      = null;
    });
    final repo = ref.read(deliveryTemplateRepositoryProvider);
    final tpl  = repo.resolveForRecipient(
        shopId: widget.shopId, partnerId: _partner?.id);
    if (tpl == null) {
      setState(() {
        _error      = 'Aucun modèle de livraison configuré pour cette boutique.';
        _generating = false;
      });
      return;
    }
    final msg = DeliveryMessageBuilder.build(
      template:   tpl,
      sale:       widget.order,
      shopName:   widget.shopName,
      senderCity: _senderCityCtrl.text.trim().isEmpty
          ? null : _senderCityCtrl.text.trim(),
      clientDistrict: _resolveClientDistrict(),
      partner:        _partner,
      // Produits en TEXTE (plus de lien fragile) : `productsLink` null →
      // `{{produits}}` retombe sur la liste texte. SKU prioritaire sur le nom.
      productsLink:   null,
      resolveProductName: _buildProductNameResolver(),
      resolveProductSku:  _buildProductSkuResolver(),
    );
    setState(() {
      _messageCtrl.text = msg;
      _generating       = false;
    });
  }

  /// Construit la fiche image (produits uniquement — le texte est envoyé
  /// séparément). Indépendante du template/partenaire.
  Future<({Uint8List bytes, bool isPng})?> _buildImage() async {
    final products = LocalStorageService.getProductsForShop(widget.shopId);
    return DeliveryImageService.generate(
      order:    widget.order,
      shopName: widget.shopName,
      products: products,
    );
  }

  /// Pré-génère l'image et la met en cache (silencieux : aucun snack).
  Future<void> _pregenerateImage() async {
    final res = await _buildImage();
    if (!mounted) return;
    setState(() {
      _imageBytes = res?.bytes;
      _imageIsPng = res?.isPng ?? true;
    });
  }

  String _shortRef() {
    final id = (widget.order.id ?? '').trim();
    if (id.length >= 6) return id.substring(id.length - 6).toUpperCase();
    if (id.isNotEmpty) return id.toUpperCase();
    return widget.order.createdAt.millisecondsSinceEpoch
        .toRadixString(16)
        .toUpperCase();
  }

  /// Étape 1 : copier la FICHE IMAGE (produits) dans le presse-papier →
  /// l'utilisateur la colle dans son groupe WhatsApp. Repli automatique :
  /// téléchargement de l'image (navigateur sans copie image).
  /// La feuille reste ouverte pour permettre ensuite « Copier le texte ».
  Future<void> _copyImage() async {
    if (_copying) return;
    setState(() => _copying = true);
    try {
      // Utilise l'image pré-générée si dispo (copie au plus près du clic) ;
      // sinon la construit maintenant.
      var bytes = _imageBytes;
      var isPng = _imageIsPng;
      if (bytes == null) {
        final res = await _buildImage();
        bytes = res?.bytes;
        isPng = res?.isPng ?? true;
      }
      if (bytes == null) {
        if (!mounted) return;
        AppSnack.warning(context,
            "Image indisponible. Réessaie, ou utilise « Copier le texte ».");
        return;
      }

      final filename = 'livraison-${_shortRef()}.${isPng ? 'png' : 'pdf'}';
      final outcome =
          await shareDeliveryImage(bytes, filename, isImage: isPng);
      if (!mounted) return;
      switch (outcome) {
        case DeliveryShareOutcome.copied:
          AppSnack.success(context,
              '1/2 Image copiée — colle-la dans ton groupe, '
              'puis « Copier le texte »');
        case DeliveryShareOutcome.downloaded:
          AppSnack.success(context,
              'Image téléchargée — envoie-la, puis « Copier le texte »');
        case DeliveryShareOutcome.shared:
          AppSnack.success(context,
              'Partage ouvert — puis « Copier le texte »');
        case DeliveryShareOutcome.failed:
          AppSnack.warning(context,
              "Image impossible. Utilise « Copier le texte ».");
      }
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  /// Étape 2 : copier le TEXTE du template → l'utilisateur le colle en
  /// légende sous l'image (ou en 2e message) dans son groupe WhatsApp.
  Future<void> _copyText() async {
    if (_copyingText || _messageCtrl.text.trim().isEmpty) return;
    setState(() => _copyingText = true);
    await Clipboard.setData(ClipboardData(text: _messageCtrl.text));
    if (!mounted) return;
    AppSnack.success(context,
        '2/2 Texte copié — colle-le sous l\'image dans ton groupe WhatsApp');
    setState(() => _copyingText = false);
  }

  void _onPickPartner(StockLocation? p) {
    if (_partner?.id == p?.id) return;
    setState(() {
      _partner = p;
      // Pré-remplit la ville si dispo et champ vide.
      if (p != null && _senderCityCtrl.text.trim().isEmpty) {
        final d = (p.district ?? '').trim();
        final c = (p.city     ?? '').trim();
        if (c.isNotEmpty || d.isNotEmpty) {
          _senderCityCtrl.text =
              [d, c].where((s) => s.isNotEmpty).join(', ');
        } else if ((p.address ?? '').isNotEmpty) {
          _senderCityCtrl.text = p.address!.trim();
        }
      }
    });
    _rebuildMessage();
  }

  @override
  Widget build(BuildContext context) {
    final ownerId = Supabase.instance.client.auth.currentUser?.id;
    final partners = ownerId == null
        ? const <StockLocation>[]
        : AppDatabase.getStockLocationsForOwner(ownerId)
            .where((l) =>
                l.type == StockLocationType.partner && l.isActive)
            .toList();

    return AdaptiveFormFrame(
      title: 'Copier le message livraison',
      icon: Icons.content_copy_rounded,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Partenaire ───────────────────────────────────────────
            const _SectionLabel(text: 'Partenaire livreur'),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _PartnerChip(
                label:    'Aucun (shop)',
                selected: _partner == null,
                onTap:    () => _onPickPartner(null),
              ),
              for (final p in partners)
                _PartnerChip(
                  label:    p.name,
                  selected: _partner?.id == p.id,
                  onTap:    () => _onPickPartner(p),
                ),
            ]),
            const SizedBox(height: 14),

            // ── Ville d'expédition ────────────────────────────────────
            const _SectionLabel(text: 'Ville d\'expédition'),
            const SizedBox(height: 6),
            AppField(
              controller: _senderCityCtrl,
              hint: 'Ex : Yaoundé · Bonamoussadi',
              prefixIcon: Icons.place_outlined,
              onChanged: (_) => _rebuildMessage(),
            ),
            const SizedBox(height: 14),

            // ── Aperçu éditable ───────────────────────────────────────
            const _SectionLabel(text: 'Message à coller dans WhatsApp'),
            const SizedBox(height: 6),
            TextField(
              controller: _messageCtrl,
              maxLines: null,
              minLines: 8,
              style: const TextStyle(
                  fontSize: 12, height: 1.5, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: _generating
                    ? 'Génération du message…'
                    : 'Le message apparaîtra ici',
                filled: true,
                fillColor: AppColors.inputFill,
                contentPadding: const EdgeInsets.all(12),
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
              ),
            ),
            if (_error != null) Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.error)),
            ),
            const SizedBox(height: 14),

            // ── 2 étapes : image (haut) puis texte (bas) dans le groupe ──
            // Le presse-papier ne porte qu'une chose à la fois : on copie
            // l'image, on la colle ; puis on copie le texte, on le colle en
            // légende sous l'image (ou en 2e message).
            // Étape 1 — Copier l'image (action principale).
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                onPressed: _copying ? null : _copyImage,
                icon: _copying
                    ? const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.image_rounded, size: 18),
                label: Text(_copying ? 'Préparation…' : '1. Copier l\'image',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      AppColors.primary.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Étape 2 — Copier le texte (légende sous l'image).
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                onPressed: (_generating || _copyingText
                    || _messageCtrl.text.trim().isEmpty)
                    ? null
                    : _copyText,
                icon: (_generating || _copyingText)
                    ? SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.primary))
                    : const Icon(Icons.content_copy_rounded, size: 16),
                label: const Text('2. Copier le texte',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: AppColors.primary, width: 1.4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Text(text,
        style: AppTextStyles.captionBold
            .copyWith(color: AppColors.textSecondary)),
  );
}

class _PartnerChip extends StatelessWidget {
  final String       label;
  final bool         selected;
  final VoidCallback onTap;
  const _PartnerChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary
              : AppColors.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected
                  ? AppColors.primary
                  : AppColors.primary.withValues(alpha: 0.2)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : AppColors.primary)),
      ),
    ),
  );
}
