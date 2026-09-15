import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/short_link_service.dart';
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

/// Sheet « Copier le message livraison ».
/// Le user envoie en réalité dans un groupe WhatsApp unique (wa.me ne supporte
/// pas les groupes), donc on génère le message final et on le met dans le
/// presse-papier. Le user colle ensuite manuellement dans son groupe.
///
/// Le message inclut un **lien vitrine** vers la mini-fiche produits de la
/// commande (images + quantités à livrer, `mode=delivery`) via la variable
/// `{{produits}}` / `{{produits_link}}`. Ce lien pointe sur la page statique
/// `catalogue.html` (rapide/robuste), d'où sa réintégration (l'ancienne
/// version Flutter était trop lente → on était repassé au texte).
///
/// UI :
///   1. Picker partenaire (radio chips) — détermine quel template est résolu
///      + remplit les variables `{{partner_*}}`.
///   2. Champ ville d'expédition optionnel (résout `{{ville_expedition}}`).
///   3. Aperçu éditable du message rendu (lien court `{{produits}}` généré).
///   4. Bouton « Copier le message » → clipboard + snack.
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

  bool    _generating = false;
  bool    _copying    = false;
  String? _error;

  /// Lien court vers la mini-vitrine produits de la commande. Ne dépend que
  /// de la commande → généré UNE fois à l'ouverture, réutilisé à chaque
  /// re-rendu (changement de partenaire / ville) sans nouvel appel réseau.
  String? _productsLink;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _senderCityCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  /// Génère le lien vitrine (une fois) puis rend le message.
  Future<void> _init() async {
    setState(() => _generating = true);
    _productsLink = await _buildProductsLink();
    if (!mounted) return;
    _rebuildMessage();
  }

  /// Lien court vers la fiche produits de la commande (images + quantités,
  /// `mode=delivery`). Pointe sur `catalogue.html` (statique, robuste).
  /// Repli sur l'URL longue si le raccourcisseur échoue ; null en cas
  /// d'erreur → `{{produits}}` retombe alors sur la liste texte.
  Future<String?> _buildProductsLink() async {
    try {
      final origin = Uri.base.origin.startsWith('http')
          ? Uri.base.origin
          : 'https://fortress-pos.web.app';
      final products = LocalStorageService.getProductsForShop(widget.shopId);
      final longUrl = DeliveryMessageBuilder.buildCatalogueLongUrl(
        webBase: origin,
        shopId:  widget.shopId,
        sale:    widget.order,
        products: products,
      );
      final short = await ShortLinkService.createShortLink(
        longUrl:   longUrl,
        linkType:  'catalogue',
        expiresIn: const Duration(days: 90),
      );
      return short ?? longUrl;
    } catch (_) {
      return null;
    }
  }

  // ── Resolvers ──────────────────────────────────────────────────────────
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
      // Lien vitrine robuste réintégré : `{{produits}}`/`{{produits_link}}`
      // s'y résolvent (images + quantités). Null → repli liste texte.
      productsLink:   _productsLink,
      resolveProductName: _buildProductNameResolver(),
      resolveProductSku:  _buildProductSkuResolver(),
    );
    setState(() {
      _messageCtrl.text = msg;
      _error            = null;
      _generating       = false;
    });
  }

  /// Copie le message (avec le lien vitrine) → l'utilisateur le colle dans
  /// son groupe WhatsApp.
  Future<void> _copyMessage() async {
    if (_copying || _messageCtrl.text.trim().isEmpty) return;
    setState(() => _copying = true);
    await Clipboard.setData(ClipboardData(text: _messageCtrl.text));
    if (!mounted) return;
    AppSnack.success(context,
        'Message copié — colle-le dans ton groupe WhatsApp');
    setState(() => _copying = false);
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

            // ── Copier le message (avec le lien vitrine) ──────────────
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                onPressed: (_generating || _copying
                    || _messageCtrl.text.trim().isEmpty)
                    ? null
                    : _copyMessage,
                icon: (_generating || _copying)
                    ? const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.content_copy_rounded, size: 18),
                label: Text(
                    _generating ? 'Génération…' : 'Copier le message',
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
