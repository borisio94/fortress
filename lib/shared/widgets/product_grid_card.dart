import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../features/inventaire/domain/entities/product.dart';
import 'product_image_card.dart';

// ─── Constantes overlay statut ──────────────────────────────────────────────
// Constantes universelles : la pastille statut a un fond blanc semi-opaque
// (overlay sémantique indépendant de la palette). Le texte utilise les
// valeurs LIGHT théoriques car le fond reste clair en permanence, même en
// dark mode (l'overlay blanc 92 % reste lisible sur image foncée ou claire).
// C'est la SEULE exception au "pas de hex hardcodé palette", justifiée par
// la nature « overlay » du composant — il n'a pas à suivre le theme.
const Color _kStatusDangerText  = Color(0xFF991B1B); // red-800
const Color _kStatusWarningText = Color(0xFF92400E); // amber-800
const Color _kStatusSuccessText = Color(0xFF065F46); // emerald-800

/// Card produit unifiée — design « bandeau bas plein » :
/// image plein cadre 3:4 + bandeau noir opaque 70 % en bas + overlays
/// flottants. Le bandeau opaque (vs ancien dégradé) garantit la lisibilité
/// maximale du texte produit quel que soit le rendu de l'image en
/// dessous (claire / foncée / dorée / contraste fort indifférent).
///
/// Présentation pure, **zéro logique métier**. Cinq overlays sur l'image :
///   1. Pastille statut (haut-gauche) : disponible / stock bas / rupture.
///   2. Pastille quantité ×N (haut-droite) : brand@92 % si stock>0, noir@70 %
///      en rupture. Shift à top:44 si `selectable` (place pour checkbox).
///   3. Checkbox sélection (haut-droite) si `selectable` : feedback rond
///      blanc → brand cochée. Bord violet brand 2 px autour de la card
///      quand `selected`.
///   4. Rangée pastilles variantes (bas avec offset 60) si `showVariantsRow`.
///   5. Bandeau texte produit (bas) : Container `Colors.black@0.7` avec
///      nom 13 px blanc + SKU 10 px white@0.7 mono + prix 15 px blanc +
///      symbole 9 px white@0.7. Hauteur AUTO calée sur le contenu.
///
/// Image en rupture : opacity 1.0 — c'est le statut + la pastille qty noire
/// qui signalent, pas la désaturation. Le marchand doit pouvoir reconnaître
/// visuellement le produit pour proposer une alternative.
class ProductGridCard extends StatelessWidget {
  final Product product;

  /// Tap principal hors overlays. Ignoré quand `selectable=true` (le tap
  /// déclenche alors `onSelectionChanged`).
  final VoidCallback? onTap;

  /// Tap sur une pastille variante. `null` = pastilles décoratives.
  final void Function(ProductVariant)? onVariantTap;

  /// Texte d'overlay survol (desktop). Non rendu en v1, conservé pour API.
  // ignore: unused_element_parameter
  final String? actionLabel;

  /// Affiche/masque pastille statut + pastille ×N. Le catalogue public
  /// sans gestion de stock peut le masquer.
  final bool showStockBadge;

  /// Variante actuellement mise en évidence dans la rangée variantes
  /// (border blanche 2 px). Conservé pour compat.
  final ProductVariant? selectedVariant;

  /// Si fourni, utilisé pour la pastille ×N + statut à la place de
  /// `product.totalStock` — utile en caisse pour n'afficher que le stock
  /// de la variante mise en avant (= celle dont l'image est montrée).
  final int? stockOverride;

  /// Si fourni, image principale forcée (sinon `product.mainImageUrl`).
  /// Utile en mode partenaire où la featured variant peut différer.
  final String? imageUrlOverride;

  /// Si fourni, seuil de stock bas remplaçant `product.stockMinAlert`.
  /// Pertinent quand `stockOverride` représente le stock d'UNE variante.
  final int? stockMinAlertOverride;

  /// Affiche la rangée pastilles variantes (bas, offset 60).
  final bool showVariantsRow;

  /// Affiche le SKU sous le nom dans le bandeau bas. Défaut `false` :
  /// les surfaces principales (caisse mode wide, catalogue public)
  /// n'en ont pas besoin (caissiers reconnaissent par l'image, clients
  /// finaux ne cherchent pas par SKU). Garde la card aérée — le SKU
  /// occupe une ligne 10 px + un gap 2 px = ~25 % du bandeau total.
  final bool showSku;

  /// Mode sélection (catalogue partage avec multi-sélection). Activé
  /// par le caller pendant un `selectMode`. Le tap principal change
  /// alors l'état au lieu d'appeler `onTap`. La pastille ×N est
  /// déplacée à `top: 44` pour libérer le coin top-right à la checkbox.
  final bool selectable;

  /// État coché — pilote la border brand 2 px + le visuel checkbox.
  final bool selected;

  /// Callback de changement d'état sélection. Reçoit le **nouveau** état.
  final ValueChanged<bool>? onSelectionChanged;

  const ProductGridCard({
    super.key,
    required this.product,
    this.onTap,
    this.onVariantTap,
    this.actionLabel,
    this.showStockBadge = true,
    this.selectedVariant,
    this.stockOverride,
    this.imageUrlOverride,
    this.stockMinAlertOverride,
    this.showVariantsRow = false,
    this.showSku = false,
    this.selectable = false,
    this.selected = false,
    this.onSelectionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    final l     = context.l10n;

    // Calcul état stock (logique identique à l'ancienne version).
    final isOverride = stockOverride != null;
    final stock      = stockOverride ?? product.totalStock;
    final minAlert   = stockMinAlertOverride ?? product.stockMinAlert;
    final anyVariantOut = product.variants.any((v) => v.isOutOfStock);
    final outOfStock = isOverride
        ? stock <= 0
        : (stock <= 0
            || (product.variants.isNotEmpty && anyVariantOut));
    final lowStock = !outOfStock
        && (isOverride
            ? (stock > 0 && stock <= minAlert)
            : (product.isLowStock
                || (product.variants.isEmpty
                    && stock > 0 && stock <= minAlert)));

    // Tap : `selectable=true` → toggle sélection. Sinon `onTap` standard.
    // Stock=0 reste sélectionnable (un marchand doit pouvoir partager un
    // produit en rupture pour précommande/réservation).
    VoidCallback? handleTap;
    if (selectable && onSelectionChanged != null) {
      handleTap = () => onSelectionChanged!(!selected);
    } else if (onTap != null) {
      handleTap = onTap;
    }

    // Border brand 2px quand sélectionné. Le radius reste 12.
    final borderRadius = BorderRadius.circular(12);
    final card = AspectRatio(
      aspectRatio: 3 / 4,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          border: selected
              ? Border.all(color: sem.brand, width: 2)
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(fit: StackFit.expand, children: [

          // ① Image plein cadre
          ProductImageCard(
            imageUrl: imageUrlOverride ?? product.mainImageUrl,
            fillParent: true,
          ),

          // ③ Pastille statut (top-left) — masquée si !showStockBadge.
          if (showStockBadge)
            Positioned(
              top: 8, left: 8,
              child: _StatusPill(out: outOfStock, low: lowStock, l: l),
            ),

          // ④ Pastille quantité ×N (top-right). Si checkbox sélection
          //    présente, on shift de 36 px sous elle.
          if (showStockBadge)
            Positioned(
              top: selectable ? 44 : 8,
              right: 8,
              child: _QtyPill(
                  stock: stock, out: outOfStock, brand: sem.brand),
            ),

          // ⑤ Checkbox sélection (top-right top-prioritaire).
          if (selectable)
            Positioned(
              top: 8, right: 8,
              child: _SelectionCheckbox(
                  selected: selected, brand: sem.brand),
            ),

          // ⑥ Rangée pastilles variantes (offset 60 du bas pour respirer
          //    au-dessus du bloc texte).
          if (showVariantsRow && product.variants.length > 1)
            Positioned(
              bottom: 60, left: 12, right: 12,
              child: _VariantsRow(
                variants: product.variants,
                selected: selectedVariant,
                onTap:    onVariantTap,
              ),
            ),

          // ⑦ Bandeau bas plein opaque (overlay noir 70 %) — remplace
          //    l'ancien dégradé pour garantir la lisibilité du texte
          //    produit dans tous les cas (image claire / foncée / dorée
          //    indifférent). Hauteur AUTO calée sur le contenu.
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: IgnorePointer(
              child: Container(
                color: Colors.black.withValues(alpha: 0.7),
                padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
                child: _BottomTextBlock(
                    product: product, l: l, showSku: showSku),
              ),
            ),
          ),
        ]),
      ),
    );

    if (handleTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: handleTap,
        borderRadius: borderRadius,
        child: card,
      ),
    );
  }
}

// ─── Overlays ───────────────────────────────────────────────────────────────

class _StatusPill extends StatelessWidget {
  final bool out;
  final bool low;
  final AppLocalizations l;
  const _StatusPill({required this.out, required this.low, required this.l});

  @override
  Widget build(BuildContext context) {
    final (Color color, String label) = out
        ? (_kStatusDangerText,  l.productStockBadgeRupture)
        : low
            ? (_kStatusWarningText, l.productStockBadgeLow)
            : (_kStatusSuccessText, l.productStockBadgeAvailable);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 5, height: 5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w500,
                color: color, letterSpacing: 0.2)),
      ]),
    );
  }
}

class _QtyPill extends StatelessWidget {
  final int  stock;
  final bool out;
  final Color brand;
  const _QtyPill({
    required this.stock, required this.out, required this.brand});

  @override
  Widget build(BuildContext context) {
    // Rupture : pastille noire neutre. Sinon brand@92% pour ancrer la
    // card dans la palette boutique (suit la palette dynamique user).
    final bg = out
        ? Colors.black.withValues(alpha: 0.7)
        : brand.withValues(alpha: 0.92);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text('×$stock',
          style: const TextStyle(
              fontSize: 10, fontWeight: FontWeight.w500,
              color: Colors.white)),
    );
  }
}

class _SelectionCheckbox extends StatelessWidget {
  final bool selected;
  final Color brand;
  const _SelectionCheckbox({required this.selected, required this.brand});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28, height: 28,
      decoration: BoxDecoration(
        color: selected ? brand : Colors.white.withValues(alpha: 0.92),
        shape: BoxShape.circle,
        border: Border.all(
          color: selected
              ? brand
              : Colors.black.withValues(alpha: 0.15),
          width: 1.5,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
          : null,
    );
  }
}

class _BottomTextBlock extends StatelessWidget {
  final Product product;
  final AppLocalizations l;
  final bool showSku;
  const _BottomTextBlock({
    required this.product,
    required this.l,
    required this.showSku,
  });

  @override
  Widget build(BuildContext context) {
    final featSku = product.featuredVariant()?.sku;
    final sku = (featSku != null && featSku.isNotEmpty)
        ? featSku : product.sku;
    final discount = _activeDiscount(context, product);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(child: Text(product.name,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500,
                    color: Colors.white))),
            if (discount != null) ...[
              const SizedBox(width: 6),
              _DiscountBadge(label: discount),
            ],
          ]),
          if (showSku && sku != null && sku.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(sku,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withValues(alpha: 0.7),
                    fontFamily: 'monospace')),
          ],
          const SizedBox(height: 4),
          _priceLine(product),
        ]);
  }
}

// ─── Prix : nombre w500 15px + symbole w400 9px white@0.7 ───────────────────

Widget _priceLine(Product p) {
  final feat = p.featuredVariant()
      ?? (p.variants.isNotEmpty ? p.variants.first : null);
  final base = feat?.priceSellPos ?? p.priceSellPos;
  if (base <= 0) {
    return const Text('N/D',
        style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w500,
            color: Colors.white));
  }
  final symbol = CurrencyFormatter.currentSymbol;
  String stripSymbol(String s) =>
      s.replaceAll(symbol, '').trim();

  final fullPromo = p.variants.isNotEmpty
      && p.variants.every(_isPromoActive);
  if (fullPromo && feat != null && feat.promoPrice != null) {
    final basePart  = stripSymbol(CurrencyFormatter.format(base));
    final promoPart = stripSymbol(CurrencyFormatter.format(feat.promoPrice!));
    final muted = Colors.white.withValues(alpha: 0.6);
    return Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(basePart,
              style: TextStyle(
                  fontSize: 10, color: muted,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: muted)),
          const SizedBox(width: 6),
          _PriceText(numberPart: promoPart, symbol: symbol),
        ]);
  }
  return _PriceText(
      numberPart: stripSymbol(CurrencyFormatter.format(base)),
      symbol: symbol);
}

class _PriceText extends StatelessWidget {
  final String numberPart;
  final String symbol;
  const _PriceText({required this.numberPart, required this.symbol});
  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(children: [
        TextSpan(text: numberPart,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w500,
                color: Colors.white)),
        const TextSpan(text: ' '),
        TextSpan(text: symbol,
            style: TextStyle(
                fontSize: 9, fontWeight: FontWeight.w400,
                color: Colors.white.withValues(alpha: 0.7))),
      ]),
    );
  }
}

class _DiscountBadge extends StatelessWidget {
  final String label;
  const _DiscountBadge({required this.label});
  @override
  Widget build(BuildContext context) {
    // Sur dégradé sombre : badge vert successText (universel, lisible).
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _kStatusSuccessText,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: const TextStyle(
              fontSize: 10, fontWeight: FontWeight.w500,
              color: Colors.white)),
    );
  }
}

// ─── Rangée variantes (max 4 + compteur "+N") ──────────────────────────────

class _VariantsRow extends StatelessWidget {
  final List<ProductVariant> variants;
  final ProductVariant? selected;
  final void Function(ProductVariant)? onTap;
  const _VariantsRow({
    required this.variants, this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    final shown = variants.take(4).toList();
    final extra = variants.length - shown.length;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final v in shown)
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: GestureDetector(
            onTap: onTap != null ? () => onTap!(v) : null,
            child: Container(
              width: 14, height: 14,
              decoration: BoxDecoration(
                color: _hashColor(v.name),
                shape: BoxShape.circle,
                border: v == selected
                    ? Border.all(color: Colors.white, width: 2)
                    : null,
              ),
            ),
          ),
        ),
      if (extra > 0)
        Text('+$extra',
            style: TextStyle(
                fontSize: 10,
                color: Colors.white.withValues(alpha: 0.85),
                fontWeight: FontWeight.w500)),
    ]);
  }
}

// Palette de fallback pour les variantes sans `color` (champ futur).
// Hash stable du nom → couleur cohérente d'un build à l'autre.
Color _hashColor(String s) {
  const palette = [
    Color(0xFF6C3FC7), Color(0xFFEF4444), Color(0xFFF59E0B),
    Color(0xFF10B981), Color(0xFF3B82F6), Color(0xFFEC4899),
    Color(0xFF8B5CF6), Color(0xFF14B8A6),
  ];
  final h = s.codeUnits.fold<int>(
      0, (acc, c) => (acc * 31 + c) & 0x7fffffff);
  return palette[h % palette.length];
}

// ─── Promo helpers ──────────────────────────────────────────────────────────

bool _isPromoActive(ProductVariant v) {
  if (!v.promoEnabled || v.promoPrice == null) return false;
  final now = DateTime.now();
  final s = v.promoStart;
  final e = v.promoEnd;
  if (s != null && now.isBefore(s)) return false;
  if (e != null && now.isAfter(e))  return false;
  return v.promoPrice! < v.priceSellPos;
}

/// Label remise : `−X %` si toutes variantes en promo (X = pct max),
/// `productPromoBadge` i18n si promo partielle, `null` sinon.
String? _activeDiscount(BuildContext context, Product p) {
  if (p.variants.isEmpty) return null;
  final actives = p.variants.where(_isPromoActive).toList();
  if (actives.isEmpty) return null;
  if (actives.length < p.variants.length) {
    return context.l10n.productPromoBadge;
  }
  var maxPct = 0;
  for (final v in actives) {
    final pct = ((v.priceSellPos - v.promoPrice!) / v.priceSellPos * 100)
        .round();
    if (pct > maxPct) maxPct = pct;
  }
  return '−$maxPct %';
}
