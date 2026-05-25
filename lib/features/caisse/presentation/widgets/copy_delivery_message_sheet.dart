import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/short_link_service.dart';
import '../../../../core/services/url_shortener_service.dart';
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

  /// Cache du lien court : 1 seule génération par ouverture du sheet.
  String? _cachedLink;
  bool    _generating  = false;
  bool    _copying     = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Pré-build du message au premier frame (sans partenaire — utilise
    // le template défaut shop). Async — UI affichera un spinner.
    WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildMessage());
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

  String? _resolveClientDistrict() {
    final clientId = widget.order.clientId;
    if (clientId == null || clientId.isEmpty) return null;
    for (final c in AppDatabase.getClientsForShop(widget.shopId)) {
      if (c.id == clientId) return c.district;
    }
    return null;
  }

  Future<String> _ensureLink() async {
    if (_cachedLink != null) return _cachedLink!;
    final webBase = kIsWeb
        ? Uri.base.origin
        : 'https://fortress-pos.web.app';
    final long = DeliveryMessageBuilder.buildCatalogueLongUrl(
        webBase: webBase, shopId: widget.shopId, sale: widget.order);
    try {
      final maison = await ShortLinkService.createShortLink(
        longUrl:   long,
        linkType:  'delivery',
        expiresIn: const Duration(days: 30),
      );
      _cachedLink = maison ?? await UrlShortenerService.shorten(long);
    } catch (_) {
      _cachedLink = long;
    }
    return _cachedLink!;
  }

  Future<void> _rebuildMessage() async {
    setState(() {
      _generating = true;
      _error      = null;
    });
    final repo = ref.read(deliveryTemplateRepositoryProvider);
    final tpl  = repo.resolveForRecipient(
        shopId: widget.shopId, partnerId: _partner?.id);
    if (tpl == null) {
      if (!mounted) return;
      setState(() {
        _error      = 'Aucun modèle de livraison configuré pour cette boutique.';
        _generating = false;
      });
      return;
    }
    final link = await _ensureLink();
    if (!mounted) return;
    final msg = DeliveryMessageBuilder.build(
      template:   tpl,
      sale:       widget.order,
      shopName:   widget.shopName,
      senderCity: _senderCityCtrl.text.trim().isEmpty
          ? null : _senderCityCtrl.text.trim(),
      clientDistrict: _resolveClientDistrict(),
      partner:        _partner,
      productsLink:   link,
      resolveProductName: _buildProductNameResolver(),
    );
    if (!mounted) return;
    setState(() {
      _messageCtrl.text = msg;
      _generating       = false;
    });
  }

  Future<void> _copy() async {
    if (_messageCtrl.text.trim().isEmpty) return;
    setState(() => _copying = true);
    await Clipboard.setData(ClipboardData(text: _messageCtrl.text));
    if (!mounted) return;
    AppSnack.success(context,
        'Message copié — colle-le dans ton groupe WhatsApp');
    Navigator.of(context).pop(true);
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
                fillColor: const Color(0xFFF9FAFB),
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

            // ── CTA Copier ────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed: (_generating || _copying
                    || _messageCtrl.text.trim().isEmpty)
                    ? null
                    : _copy,
                icon: (_generating || _copying)
                    ? const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.content_copy_rounded, size: 16),
                label: const Text('Copier le message',
                    style: TextStyle(
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
