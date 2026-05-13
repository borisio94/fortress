import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../bloc/caisse_bloc.dart';
import '../../domain/entities/sale.dart' show DeliveryMode;
import '../../domain/entities/sale_item.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../features/dashboard/data/dashboard_providers.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../../../shared/widgets/product_grid_card.dart';
import '../../../../shared/widgets/view_filter_chip_bar.dart';

/// Stock à afficher pour une variante selon la source active.
/// - Pas de source partenaire → stock cumulé (`variant.stockAvailable`).
/// - Source = partenaire → `stock_levels[variant_id, location_id]` ou 0.
int _stockForVariant(ProductVariant v, String? deliveryLocationId) {
  if (deliveryLocationId == null || deliveryLocationId.isEmpty) {
    return v.stockAvailable;
  }
  final id = v.id;
  if (id == null) return 0;
  final lvl = AppDatabase.getStockLevel(id, deliveryLocationId);
  return lvl?.stockAvailable ?? 0;
}

/// Stock à afficher pour un produit selon la source active.
/// - Pas de source partenaire → `product.totalStock` (cumul historique).
/// - Source = partenaire → somme des `stock_levels` des variantes à cette
///   location.
int _stockForProduct(Product p, String? deliveryLocationId) {
  if (deliveryLocationId == null || deliveryLocationId.isEmpty) {
    return p.totalStock;
  }
  if (p.variants.isEmpty) return 0; // pas de variantes → pas de stock_levels
  var total = 0;
  for (final v in p.variants) {
    total += _stockForVariant(v, deliveryLocationId);
  }
  return total;
}

/// Variante mise en avant pour l'affichage card en mode caisse, **adaptée
/// à la source active** (boutique cumul vs partenaire). Différence avec
/// `Product.featuredVariant()` : ce dernier se base sur `stockAvailable`
/// (boutique uniquement) ; ici on prend le stock partenaire si applicable
/// pour que l'image affichée et le compteur ×N soient cohérents avec la
/// situation chez ce partenaire.
///
/// Règle : variante avec le plus grand stock à la source. En cas d'égalité,
/// celle marquée `isMain` ; sinon, première par id (déterministe). Retourne
/// `null` si le produit n'a pas de variantes.
ProductVariant? _featuredVariantFor(Product p, String? deliveryLocationId) {
  if (p.variants.isEmpty) return null;
  // Mode boutique : déléguer au getter standard (gère déjà tie-breaker
  // isMain + rotation temporelle).
  if (deliveryLocationId == null || deliveryLocationId.isEmpty) {
    return p.featuredVariant();
  }
  // Mode partenaire : on RECALCULE en lisant les StockLevel partenaire,
  // car `featuredVariant()` regarde stockAvailable (= boutique).
  ProductVariant? best;
  int bestStock = -1;
  for (final v in p.variants) {
    final s = _stockForVariant(v, deliveryLocationId);
    if (s > bestStock || (s == bestStock && v.isMain && best?.isMain != true)) {
      bestStock = s;
      best = v;
    }
  }
  return best;
}

/// Tente d'ajouter [item] au panier en validant le stock disponible.
///
/// Le check final côté `caisse_bloc._validateStock` reste en place à la
/// finalisation de la vente, mais bloquer dès l'ajout évite au caissier de
/// composer un panier qu'il ne pourra pas encaisser.
///
/// Règle : `qty déjà au panier + qty demandée ≤ stockAvailable`. Sinon
/// snackbar rouge et l'item n'est pas ajouté.
///
/// Retourne `true` si l'item a été ajouté, `false` sinon.
bool _tryAddToCart(
  BuildContext ctx,
  CaisseBloc bloc,
  SaleItem item,
  int stockAvailable, {
  required String displayName,
}) {
  int existing = 0;
  for (final i in bloc.state.items) {
    if (i.productId == item.productId) {
      existing = i.quantity;
      break;
    }
  }

  void showError(String msg) {
    ScaffoldMessenger.of(ctx)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        content: Text(msg, style: const TextStyle(color: Colors.white)),
        duration: const Duration(seconds: 3),
      ));
  }

  if (stockAvailable <= 0) {
    showError('« $displayName » est en rupture de stock.');
    return false;
  }
  if (existing + item.quantity > stockAvailable) {
    showError(
      'Stock insuffisant pour « $displayName » — '
      'disponible : $stockAvailable, déjà dans le panier : $existing.',
    );
    return false;
  }

  bloc.add(AddItemToCart(item));
  return true;
}

/// Picker de produits — charge les vrais produits depuis Hive via AppDatabase.
/// Gère les variantes : si un produit a des variantes, un sous-menu s'ouvre.
class ProductPickerSheet extends StatefulWidget {
  final String shopId;
  const ProductPickerSheet({super.key, required this.shopId});

  @override
  State<ProductPickerSheet> createState() => _ProductPickerSheetState();
}

class _ProductPickerSheetState extends State<ProductPickerSheet> {
  String _query = '';
  String _filter = 'Tous'; // Tous | Stock faible | Actifs

  /// Liste filtrée. Quand [deliveryLocationId] est non null (vente livrée
  /// par un partenaire), on masque les produits absents chez ce partenaire
  /// pour rester cohérent avec la grille principale.
  List<Product> _productsFor(String? deliveryLocationId) {
    var list = AppDatabase.getProductsForShop(widget.shopId)
        .where((p) => p.isActive)
        .toList();
    if (deliveryLocationId != null && deliveryLocationId.isNotEmpty) {
      list = list
          .where((p) => _stockForProduct(p, deliveryLocationId) > 0)
          .toList();
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list.where((p) =>
          p.name.toLowerCase().contains(q) ||
          (p.sku ?? '').toLowerCase().contains(q) ||
          (p.barcode ?? '').contains(_query)).toList();
    }
    if (_filter == 'Stock faible') {
      list = list.where((p) => p.isLowStock && !p.isOutOfStock).toList();
    } else if (_filter == 'Rupture') {
      list = list.where((p) => p.isOutOfStock).toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final deliveryLocId = context.select<CaisseBloc, String?>(
        (b) => b.state.deliveryLocationId);
    final products = _productsFor(deliveryLocId);
    final all      = AppDatabase.getProductsForShop(widget.shopId).where((p) => p.isActive).toList();

    return Column(children: [
      // ── Poignée + titre ──────────────────────────────────────────────
      _SheetHeader(count: all.length),

      // ── Recherche ─────────────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: TextField(
          autofocus: false,
          onChanged: (v) => setState(() => _query = v),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Rechercher par nom, SKU, code-barres…',
            prefixIcon: const Icon(Icons.search_rounded,
                size: 18, color: Color(0xFF9CA3AF)),
            suffixIcon: _query.isNotEmpty
                ? IconButton(
              icon: const Icon(Icons.clear_rounded,
                  size: 16, color: Color(0xFF9CA3AF)),
              onPressed: () => setState(() => _query = ''),
            )
                : null,
            filled: true,
            fillColor: const Color(0xFFF3F4F6),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                BorderSide(color: AppColors.primary, width: 1.5)),
          ),
        ),
      ),

      // ── Filtres chips ─────────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _Chip('Tous',         _filter == 'Tous',         () => setState(() => _filter = 'Tous')),
            const SizedBox(width: 8),
            _Chip('Stock faible', _filter == 'Stock faible', () => setState(() => _filter = 'Stock faible')),
            const SizedBox(width: 8),
            _Chip('Rupture',      _filter == 'Rupture',      () => setState(() => _filter = 'Rupture')),
          ]),
        ),
      ),

      // ── Compteur ─────────────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: Row(children: [
          Text(
            '${products.length} produit${products.length > 1 ? 's' : ''}',
            style: const TextStyle(
                fontSize: 11, color: Color(0xFF9CA3AF),
                fontWeight: FontWeight.w500),
          ),
        ]),
      ),

      // ── Grille produits ───────────────────────────────────────────────
      // Spec round 9 : crossAxisCount 2 + gap 6 sur mobile (vs 3 et
      // gap 10 sur desktop). LayoutBuilder préféré à MediaQuery pour
      // que le panel s'adapte aussi quand le panier desktop occupe la
      // moitié droite (largeur réduite à ~50%).
      Expanded(
        child: products.isEmpty
            ? _EmptyProducts(query: _query)
            : LayoutBuilder(builder: (_, c) {
          final isCompact = c.maxWidth < 500;
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount:    isCompact ? 2 : 3,
              childAspectRatio:  isCompact ? 0.85 : 0.78,
              crossAxisSpacing:  isCompact ? 6 : 10,
              mainAxisSpacing:   isCompact ? 6 : 10,
            ),
            itemCount: products.length,
            itemBuilder: (ctx, i) => _ProductCard(
              product: products[i],
              onTap: () => _handleProductTap(ctx, products[i]),
            ),
          );
        }),
      ),
    ]);
  }

  void _handleProductTap(BuildContext context, Product product) {
    // Source de stock active (boutique vs partenaire). On l'utilise pour
    // le contrôle préliminaire avant ajout au panier — la validation finale
    // côté `caisse_bloc._validateStock` reste en place avec le même
    // `locationId`, donc cohérence garantie.
    final deliveryLocId =
        context.read<CaisseBloc>().state.deliveryLocationId;
    // Pas de variantes → ajouter directement au panier
    if (product.variants.isEmpty || product.variants.length == 1) {
      final v = product.variants.isNotEmpty ? product.variants.first : null;
      final price = v?.priceSellPos ?? product.priceSellPos;
      final id = v?.id ?? (product.id ?? product.name);
      final stock = v != null
          ? _stockForVariant(v, deliveryLocId)
          : _stockForProduct(product, deliveryLocId);
      _addToCart(
        context,
        id,
        product.name,
        price,
        priceBuy: v?.priceBuy ?? product.priceBuy,
        imageUrl: product.mainImageUrl,
        stockAvailable: stock,
      );
      return;
    }

    // Plusieurs variantes → afficher le picker de variantes
    _showVariantPicker(context, product);
  }

  void _addToCart(BuildContext ctx, String id, String name, double price,
      {double priceBuy = 0, String? imageUrl, required int stockAvailable}) {
    _tryAddToCart(
      ctx,
      ctx.read<CaisseBloc>(),
      SaleItem(
        productId:   id,
        productName: name,
        unitPrice:   price,
        priceBuy:    priceBuy,
        imageUrl:    imageUrl,
        quantity:    1,
      ),
      stockAvailable,
      displayName: name,
    );
  }

  void _showVariantPicker(BuildContext context, Product product) {
    // Capturer le navigator du picker (pas celui de GoRouter)
    final pickerNavigator = Navigator.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _VariantPickerSheet(
        product: product,
        bloc: context.read<CaisseBloc>(),
        onAdded: () {
          // Fermer le sheet variantes puis le picker principal
          // depuis le navigator capturé avant l'ouverture du sheet
          if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
          if (pickerNavigator.canPop()) pickerNavigator.pop();
        },
      ),
    );
  }
}

// ─── Header du sheet ──────────────────────────────────────────────────────────
class _SheetHeader extends StatelessWidget {
  final int count;
  const _SheetHeader({required this.count});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: 10),
      Container(
        width: 36, height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFFE5E7EB),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Row(children: [
          const Text('Ajouter des produits',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A))),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('$count en stock',
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600,
                    color: AppColors.primary)),
          ),
        ]),
      ),
    ],
  );
}

// ─── Card produit ─────────────────────────────────────────────────────────────
class _ProductCard extends StatelessWidget {
  final Product product;
  final VoidCallback onTap;
  const _ProductCard({required this.product, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final price      = _displayPrice();
    // Stock conditionnel à la source active (boutique vs partenaire).
    final deliveryLocId = context.select<CaisseBloc, String?>(
        (b) => b.state.deliveryLocationId);
    final stockAt    = _stockForProduct(product, deliveryLocId);
    final outOfStockAt = stockAt <= 0;
    final lowStockAt   = stockAt > 0 && stockAt <= product.stockMinAlert;
    final stockColor = outOfStockAt
        ? const Color(0xFFEF4444)
        : lowStockAt
        ? const Color(0xFFF59E0B)
        : AppColors.secondary;
    final hasVariants = product.variants.length > 1;
    // Bug : avant on désactivait le clic dès que le total stock était à 0,
    // ce qui empêchait d'ouvrir le sélecteur de variantes pour consulter
    // ou commander une variante encore en stock. Le contrôle stock final
    // (caisse_bloc._validateStock) bloque la vente si quantité > stock,
    // donc on peut autoriser l'ouverture sans risque.
    //
    // Règle :
    //   - Produit sans variantes (length ≤ 1) ET en rupture → click bloqué
    //   - Produit avec variantes → toujours cliquable (l'utilisateur voit
    //     l'état de chacune et choisit celle qui a du stock).
    final canTap = !outOfStockAt || hasVariants;

    return GestureDetector(
      onTap: canTap ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: outOfStockAt ? 0.4 : 1.0,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha:0.03),
                  blurRadius: 4,
                  offset: const Offset(0, 1)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Image — ratio carré 1:1 unifié, BoxFit.cover, placeholder
              // neutre (cf. ProductImageCard).
              ProductImageCard(
                imageUrl: product.mainImageUrl,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(11)),
              ),

              // Infos
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                            product.name,
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w600,
                                color: Color(0xFF0F172A)),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (hasVariants)
                          Tooltip(
                            message: '${product.variants.length} variantes',
                            child: Container(
                              width: 16, height: 16,
                              decoration: BoxDecoration(
                                color: AppColors.primarySurface,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Icon(Icons.layers_rounded,
                                  size: 10, color: AppColors.primary),
                            ),
                          ),
                      ]),
                      const SizedBox(height: 4),
                      Text(
                        price,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary),
                      ),
                      const SizedBox(height: 3),
                      // Stock badge
                      Row(children: [
                        Container(
                          width: 5, height: 5,
                          decoration: BoxDecoration(
                              color: stockColor, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          outOfStockAt
                              ? 'Rupture'
                              : '$stockAt en stock',
                          style: TextStyle(fontSize: 9, color: stockColor),
                        ),
                      ]),
                    ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _displayPrice() {
    if (product.variants.isNotEmpty) {
      final prices = product.variants
          .map((v) => v.priceSellPos)
          .where((p) => p > 0)
          .toList();
      if (prices.isEmpty) return 'N/D';
      if (prices.length == 1) return CurrencyFormatter.format(prices.first);
      prices.sort();
      if (prices.first == prices.last) {
        return CurrencyFormatter.format(prices.first);
      }
      return '${CurrencyFormatter.format(prices.first)} – ${CurrencyFormatter.format(prices.last)}';
    }
    return product.priceSellPos > 0
        ? CurrencyFormatter.format(product.priceSellPos)
        : 'N/D';
  }
}

// ─── Picker variantes ─────────────────────────────────────────────────────────
class _VariantPickerSheet extends StatelessWidget {
  final Product product;
  final CaisseBloc bloc;
  final VoidCallback onAdded;
  const _VariantPickerSheet({
    required this.product,
    required this.bloc,
    required this.onAdded,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Poignée
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFE5E7EB),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // En-tête produit
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(children: [
              ProductImageCard(
                imageUrl: product.mainImageUrl,
                width:  44,
                height: 44,
                borderRadius: BorderRadius.circular(10),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(product.name,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A))),
                    Text('${product.variants.length} variantes disponibles',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF9CA3AF))),
                  ])),
            ]),
          ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text('Choisissez une variante',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280))),
          ),
          const SizedBox(height: 8),

          // Liste variantes
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.5,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: product.variants.length,
              separatorBuilder: (_, __) =>
              const Divider(height: 1, color: Color(0xFFF3F4F6)),
              itemBuilder: (ctx, i) {
                final v = product.variants[i];
                // Stock à afficher / valider selon la source active
                // (boutique cumulée ou partenaire choisi).
                final deliveryLocId = bloc.state.deliveryLocationId;
                final stockAt = _stockForVariant(v, deliveryLocId);
                final outOfStock = stockAt <= 0;
                final lowStock   = stockAt > 0 && stockAt <= v.stockMinAlert;

                return InkWell(
                  onTap: outOfStock
                      ? null
                      : () {
                    final id = v.id ?? '${product.id}_$i';
                    final name = product.variants.length == 1
                        ? product.name
                        : '${product.name} — ${v.name}';
                    final added = _tryAddToCart(
                      ctx,
                      bloc,
                      SaleItem(
                        productId:   id,
                        productName: product.name,
                        variantName: product.variants.length > 1 ? v.name : null,
                        imageUrl:    v.imageUrl ?? product.mainImageUrl,
                        unitPrice:   v.priceSellPos,
                        priceBuy:    v.priceBuy,
                        quantity:    1,
                      ),
                      stockAt,
                      displayName: name,
                    );
                    if (added) onAdded(); // ferme variantes + picker proprement
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: Opacity(
                    opacity: outOfStock ? 0.4 : 1.0,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 4),
                      child: Row(children: [
                        // Miniature variante
                        ProductImageCard(
                          imageUrl: v.imageUrl,
                          width:  40,
                          height: 40,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        const SizedBox(width: 12),

                        // Nom + SKU
                        Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Flexible(
                                  child: Text(v.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF0F172A))),
                                ),
                                if (v.isMain) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: AppColors.primarySurface,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text('Principal',
                                        style: TextStyle(
                                            fontSize: 8,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.primary)),
                                  ),
                                ],
                              ]),
                              if (v.sku != null)
                                Text('SKU: ${v.sku}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFF9CA3AF))),
                            ])),

                        // Prix + stock
                        Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                v.priceSellPos > 0
                                    ? CurrencyFormatter.format(v.priceSellPos)
                                    : 'N/D',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.primary),
                              ),
                              const SizedBox(height: 2),
                              Row(mainAxisSize: MainAxisSize.min, children: [
                                Container(
                                  width: 5, height: 5,
                                  decoration: BoxDecoration(
                                    color: outOfStock
                                        ? const Color(0xFFEF4444)
                                        : lowStock
                                        ? const Color(0xFFF59E0B)
                                        : AppColors.secondary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  outOfStock
                                      ? 'Rupture'
                                      : '$stockAt dispo',
                                  style: TextStyle(
                                      fontSize: 9,
                                      color: outOfStock
                                          ? const Color(0xFFEF4444)
                                          : lowStock
                                          ? const Color(0xFFF59E0B)
                                          : AppColors.secondary),
                                ),
                              ]),
                            ]),

                        // Chevron
                        if (!outOfStock) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.add_circle_rounded,
                              size: 22, color: AppColors.primary),
                        ],
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widgets atomiques ────────────────────────────────────────────────────────
class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(this.label, this.selected, this.onTap);

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: selected ? AppColors.primary : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: selected ? AppColors.primary : const Color(0xFFE5E7EB)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color:
              selected ? Colors.white : const Color(0xFF6B7280))),
    ),
  );
}

class _EmptyProducts extends StatelessWidget {
  final String query;
  const _EmptyProducts({required this.query});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(
        query.isNotEmpty
            ? Icons.search_off_rounded
            : Icons.inventory_2_outlined,
        size: 48, color: const Color(0xFFD1D5DB),
      ),
      const SizedBox(height: 12),
      Text(
        query.isNotEmpty
            ? 'Aucun résultat pour "$query"'
            : 'Aucun produit actif dans cette boutique',
        style: const TextStyle(
            fontSize: 13, color: Color(0xFF6B7280)),
        textAlign: TextAlign.center,
      ),
    ]),
  );
}

// ─── Panel POS inline (utilisé dans le layout desktop/mobile actif) ───────────
/// Version compacte du picker, affichée en colonne dans le layout de vente.
/// Différente de [ProductPickerSheet] : pas de header "sheet", design orienté
/// rapidité — tuiles plus petites, barre de recherche légère, pas de filtres lourds.
class PosProductPanel extends ConsumerStatefulWidget {
  final String shopId;
  const PosProductPanel({super.key, required this.shopId});
  @override
  ConsumerState<PosProductPanel> createState() => _PosProductPanelState();
}

class _PosProductPanelState extends ConsumerState<PosProductPanel> {
  String _query = '';
  // ─── État filtres ──────────────────────────────────────────────────
  Set<String> _filterCategories = {};
  Set<String> _filterBrands     = {};
  RangeValues? _priceRange;   // null = pas de filtre
  String? _stockFilter;       // null | 'in_stock' | 'low_stock' | 'out_of_stock'
  // ─── État tri ──────────────────────────────────────────────────────
  String _sort = 'name';     // 'name' | 'price_asc' | 'price_desc' | 'stock'

  // GlobalKeys pour positionner les popups juste sous les boutons.
  final GlobalKey _filtersBtnKey = GlobalKey();
  final GlobalKey _sortBtnKey    = GlobalKey();
  // ─── Mode d'affichage : grille ou liste (persisté) ────────────────
  static const _prefViewMode = 'pos_view_mode';
  String _viewMode = 'grid';  // 'grid' | 'list'

  int get _activeFilterCount =>
      _filterCategories.length +
      _filterBrands.length +
      (_priceRange != null ? 1 : 0) +
      (_stockFilter != null ? 1 : 0);

  @override
  void initState() {
    super.initState();
    // Écouter les changements de produits (ex: setMain met à jour l'image)
    AppDatabase.addListener(_onDataChanged);
    _loadViewMode();
  }

  Future<void> _loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_prefViewMode);
    if (v != null && (v == 'grid' || v == 'list') && mounted) {
      setState(() => _viewMode = v);
    }
  }

  Future<void> _setViewMode(String v) async {
    setState(() => _viewMode = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefViewMode, v);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged(String table, String shopId) {
    if (table == 'products' && shopId == widget.shopId && mounted) {
      setState(() {}); // recharger la grille
    }
  }

  /// Liste filtrée des produits affichés dans la grille / liste POS.
  ///
  /// [deliveryLocationId] : id de la `StockLocation` partenaire active si
  /// la caisse est en mode livraison partenaire (cf. CaisseBloc). Quand
  /// non-null, on **masque les produits dont le stock à ce partenaire est
  /// nul** — la vue POS reflète alors uniquement le catalogue réellement
  /// disponible chez ce partenaire, jamais celui de la boutique de base.
  List<Product> _productsFor(String? deliveryLocationId) {
    var all = AppDatabase.getProductsForShop(widget.shopId)
        .where((p) => p.isActive)
        .toList();

    // Vue Partenaire : on n'affiche que les produits qui existent (stock > 0)
    // chez ce partenaire. Sans ce filtre, la grille contiendrait tous les
    // produits de la boutique avec un badge « Rupture » massif — bruit
    // inutile, et risque pour l'utilisateur d'ajouter au panier des produits
    // que le partenaire n'a pas.
    if (deliveryLocationId != null && deliveryLocationId.isNotEmpty) {
      all = all
          .where((p) => _stockForProduct(p, deliveryLocationId) > 0)
          .toList();
    }

    // Recherche textuelle (nom + SKU).
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      all = all.where((p) =>
          p.name.toLowerCase().contains(q) ||
          (p.sku ?? '').toLowerCase().contains(q)).toList();
    }

    // Filtre stock (Tous / En stock / Stock faible / Rupture).
    // Calcul aligné sur la source active (partenaire ou cumul).
    if (_stockFilter != null) {
      all = all.where((p) {
        final stock = _stockForProduct(p, deliveryLocationId);
        switch (_stockFilter) {
          case 'in_stock':     return stock > 0;
          case 'low_stock':    return stock > 0 && stock <= 5;
          case 'out_of_stock': return stock <= 0;
        }
        return true;
      }).toList();
    }

    // Filtres catégorie / marque (correspondance exacte si non vide).
    if (_filterCategories.isNotEmpty) {
      all = all.where((p) =>
          p.categoryId != null && _filterCategories.contains(p.categoryId))
          .toList();
    }
    if (_filterBrands.isNotEmpty) {
      all = all.where((p) =>
          p.brand != null && _filterBrands.contains(p.brand)).toList();
    }

    // Filtre fourchette de prix (sur prix de vente principal).
    if (_priceRange != null) {
      final r = _priceRange!;
      all = all.where((p) {
        final price = p.priceSellPos;
        return price >= r.start && price <= r.end;
      }).toList();
    } else {
      // r non utilisé pour l'instant — réservé à une future extension
      // (slider RangeValues dans le menu filtres).
    }

    // Tri.
    switch (_sort) {
      case 'price_asc':
        all.sort((a, b) => a.priceSellPos.compareTo(b.priceSellPos));
        break;
      case 'price_desc':
        all.sort((a, b) => b.priceSellPos.compareTo(a.priceSellPos));
        break;
      case 'stock':
        all.sort((a, b) => _stockForProduct(b, deliveryLocationId)
            .compareTo(_stockForProduct(a, deliveryLocationId)));
        break;
      case 'name':
      default:
        all.sort((a, b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return all;
  }

  @override
  Widget build(BuildContext context) {
    final l        = context.l10n;
    // ── Synchro chip ViewFilterChipBar → CaisseBloc ────────────────
    // La barre de chips (boutique / partenaire X / partenaire Y) écrit dans
    // `dashViewFilterProvider` (Riverpod). On dispatche `SetDeliveryMode`
    // pour aligner le bloc, sinon le catalogue ne change pas (PosProductPanel
    // filtre via `state.deliveryLocationId`).
    //   * Chip = id de partenaire → mode partner + locationId
    //   * Chip = '_base' (Boutique) → reset vers pickup UNIQUEMENT si on
    //     était en mode partner. Préserve les modes inHouse/shipment qui
    //     ne viennent pas des chips.
    ref.listen<String?>(dashViewFilterProvider, (prev, next) {
      final bloc = context.read<CaisseBloc>();
      if (next == null) {
        // Vue Globale : aucune vente possible (cf. principe métier
        // "toute commande doit être rattachée à un lieu"). Le bouton
        // Enregistrer est bloqué côté UI ; on n'efface PAS le mode/loc
        // pour préserver une éventuelle saisie en cours si l'opérateur
        // revient sur une vue spécifique.
      } else if (next == '_base') {
        // Boutique principale : pickup + locationId = stock_location de
        // la boutique. Permet à la page Commandes de router cette vente
        // vers la vue Boutique (et plus comme « location null » par défaut).
        final shopLoc = AppDatabase.getShopLocation(widget.shopId);
        bloc.add(SetDeliveryMode(
          mode:       DeliveryMode.pickup,
          locationId: shopLoc?.id,
        ));
      } else {
        // Partenaire X : mode partner + locationId = X.
        bloc.add(SetDeliveryMode(
          mode:       DeliveryMode.partner,
          locationId: next,
        ));
      }
    });

    // Lit la source active (boutique cumul vs partenaire) — la liste de
    // produits en dépend : on masque les produits absents chez le
    // partenaire pour éviter les ajouts panier impossibles.
    final deliveryLocId = context.select<CaisseBloc, String?>(
        (b) => b.state.deliveryLocationId);
    final products = _productsFor(deliveryLocId);
    final isCompact = MediaQuery.of(context).size.width < 900;
    final searchField = SizedBox(
      height: isCompact ? 38 : 40,
      child: TextField(
        onChanged: (v) => setState(() => _query = v),
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: l.boutiqueSearchHint,
          hintStyle: const TextStyle(fontSize: 13,
              color: AppColors.textHint),
          prefixIcon: const Icon(Icons.search_rounded,
              size: 18, color: AppColors.textHint),
          suffixIcon: _query.isNotEmpty
              ? IconButton(
            icon: const Icon(Icons.clear_rounded,
                size: 16, color: AppColors.textHint),
            onPressed: () => setState(() => _query = ''),
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
                minWidth: isCompact ? 28 : 32,
                minHeight: isCompact ? 28 : 32),
          )
              : null,
          filled: true,
          fillColor: AppColors.inputFill,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
              horizontal: isCompact ? 10 : 12,
              vertical: isCompact ? 8 : 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: AppColors.primary, width: 1.5)),
        ),
      ),
    );
    final filtersBtn = _ToolbarButton(
      key: _filtersBtnKey,
      icon: Icons.tune_rounded,
      label: l.boutiqueFilters,
      badge: _activeFilterCount,
      onTap: _openFiltersSheet,
    );
    final sortBtn = _ToolbarButton(
      key: _sortBtnKey,
      icon: Icons.sort_rounded,
      label: l.boutiqueSort,
      onTap: _openSortSheet,
    );

    return Column(children: [
      // ── Onglets « Vue » : Boutique / Partenaires (sans Globale) ──────
      // Tap → ref.listen dans CaissePage dispatche SetDeliveryMode pour
      // basculer la source de stock effective. Globale est masqué : on ne
      // peut pas vendre depuis « toutes les sources à la fois ».
      ViewFilterChipBar(
          shopId: widget.shopId, showGlobal: false, useTabs: true),

      // ── Barre recherche + filtres + tri ─────────────────────────
      // Mobile : tout sur 1 ligne pour libérer ~40px au profit de la
      // grille. Desktop : layout 2 lignes (search pleine largeur, puis
      // boutons en dessous) — comportement original Material.
      Container(
        color: Theme.of(context).colorScheme.surface,
        padding: isCompact
            ? const EdgeInsets.fromLTRB(12, 8, 12, 6)
            : const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: isCompact
            ? Row(children: [
                Expanded(child: searchField),
                const SizedBox(width: 6),
                filtersBtn,
                const SizedBox(width: 6),
                sortBtn,
              ])
            : Column(children: [
                searchField,
                const SizedBox(height: 8),
                Row(children: [
                  filtersBtn,
                  const SizedBox(width: 8),
                  sortBtn,
                ]),
              ]),
      ),

      // ── Compteur produits/variantes + toggle grille/liste ──────
      // Bandeau compact : padding minimal pour ne pas grignoter la grille.
      Container(
        color: Theme.of(context).colorScheme.surface,
        padding: const EdgeInsets.fromLTRB(14, 0, 8, 2),
        child: Row(children: [
          Expanded(child: Text(
            l.boutiqueCountLine(products.length,
                products.fold<int>(0, (s, p) => s + (p.variants.isEmpty
                    ? 1 : p.variants.length))),
            style: const TextStyle(fontSize: 10,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary),
          )),
          _ViewModeToggle(
            mode: _viewMode,
            onChanged: _setViewMode,
          ),
        ]),
      ),

      const Divider(height: 1, color: AppColors.divider),

      // ── Produits : grille OU liste selon _viewMode ───────────────
      Expanded(
        child: products.isEmpty
            ? Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_query.isNotEmpty
                  ? Icons.search_off_rounded
                  : Icons.inventory_2_outlined,
                  size: 36, color: AppColors.textHint),
              const SizedBox(height: 8),
              Text(
                _query.isNotEmpty
                    ? l.invNoResult
                    : l.inventaireEmpty,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textHint),
              ),
            ],
          ),
        )
            : _viewMode == 'list'
                ? ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 80),
                    itemCount: products.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 8),
                    itemBuilder: (_, i) => _PosProductListTile(
                      product: products[i],
                      onTap:        () => _handleTap(context, products[i]),
                      onAddVariant: (idx) => _addVariantToCart(
                          context, products[i], idx),
                    ),
                  )
                : LayoutBuilder(builder: (_, c) {
                    // Spec : mobile 2 cols, tablette 3, desktop 5+ avec
                    // auto-fit minWidth ~180 px. childAspectRatio = 0.75
                    // (3:4 portrait) — calé sur le nouveau design overlay
                    // dégradé de ProductGridCard. Les infos produit
                    // (nom/SKU/prix) flottent en blanc sur le dégradé bas
                    // de l'image, donc plus besoin de marge dédiée sous
                    // l'image comme l'ancien ratio 0.57.
                    final cols = c.maxWidth < 600
                        ? 2
                        : (c.maxWidth ~/ 180).clamp(2, 8);
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        childAspectRatio: 0.75,
                      ),
                      itemCount: products.length,
                      itemBuilder: (_, i) {
                        final p = products[i];
                        // Featured variant adaptée au mode (boutique vs
                        // partenaire) : son stock + son image + son seuil
                        // sont passés au card pour que tout matche l'image
                        // mise en avant — pas la somme totale.
                        final feat = _featuredVariantFor(p, deliveryLocId);
                        return ProductGridCard(
                          product: p,
                          stockOverride: feat != null
                              ? _stockForVariant(feat, deliveryLocId)
                              : null,
                          imageUrlOverride: feat?.imageUrl ?? p.imageUrl,
                          stockMinAlertOverride: feat?.stockMinAlert,
                          // Tap card hors pastilles → ouvre le sheet
                          // variantes (ou ajoute direct si pas de variante).
                          onTap: () => _handleTap(context, p),
                          // Tap pastille → ajout direct au panier sans sheet.
                          onVariantTap: (v) {
                            final idx = p.variants.indexOf(v);
                            if (idx >= 0) _addVariantToCart(context, p, idx);
                          },
                        );
                      },
                    );
                  }),
      ),
    ]);
  }

  void _handleTap(BuildContext context, Product product) {
    final bloc = context.read<CaisseBloc>();
    final deliveryLocId = bloc.state.deliveryLocationId;
    if (product.variants.isEmpty || product.variants.length == 1) {
      final v = product.variants.isNotEmpty ? product.variants.first : null;
      final price = v?.priceSellPos ?? product.priceSellPos;
      final id = v?.id ?? (product.id ?? product.name);
      final stock = v != null
          ? _stockForVariant(v, deliveryLocId)
          : _stockForProduct(product, deliveryLocId);
      _tryAddToCart(
        context,
        bloc,
        SaleItem(
          productId:   id,
          productName: product.name,
          unitPrice:   price,
          priceBuy:    v?.priceBuy ?? product.priceBuy,
          imageUrl:    product.mainImageUrl,
          quantity:    1,
        ),
        stock,
        displayName: product.name,
      );
      return;
    }
    // Variantes → sheet (fallback legacy ou tap sur image quand pas de chip sélectionné)
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _VariantPickerSheet(
        product: product,
        bloc: context.read<CaisseBloc>(),
        onAdded: () {
          if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
        },
      ),
    );
  }

  /// Position d'un menu juste sous le widget anchor (via sa GlobalKey).
  /// Retourne null si le RenderBox n'est pas encore monté.
  RelativeRect? _menuPositionUnder(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
    return RelativeRect.fromLTRB(
      pos.dx,
      pos.dy + box.size.height + 4,
      overlay.size.width - pos.dx - box.size.width,
      overlay.size.height - pos.dy - box.size.height,
    );
  }

  /// Popup tri positionné juste sous le bouton « Trier ».
  Future<void> _openSortSheet() async {
    final position = _menuPositionUnder(_sortBtnKey);
    if (position == null) return;
    final options = <(String, String, IconData)>[
      ('name',       'Nom (A → Z)',       Icons.sort_by_alpha_rounded),
      ('price_asc',  'Prix croissant',    Icons.arrow_upward_rounded),
      ('price_desc', 'Prix décroissant',  Icons.arrow_downward_rounded),
      ('stock',      'Stock disponible',  Icons.inventory_2_outlined),
    ];
    final selected = await showMenu<String>(
      context: context,
      position: position,
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
      items: [
        for (final o in options)
          PopupMenuItem<String>(
            value: o.$1,
            child: Row(children: [
              Icon(o.$3,
                  size: 16,
                  color: _sort == o.$1
                      ? AppColors.primary
                      : AppColors.textSecondary),
              const SizedBox(width: 10),
              Expanded(child: Text(o.$2,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: _sort == o.$1
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: _sort == o.$1
                          ? AppColors.primary
                          : AppColors.textPrimary))),
              if (_sort == o.$1)
                Icon(Icons.check_rounded,
                    size: 14, color: AppColors.primary),
            ]),
          ),
      ],
    );
    if (selected != null && mounted) {
      setState(() => _sort = selected);
    }
  }

  /// Popup filtres positionné juste sous le bouton « Filtrer ».
  /// Stock + bouton « Effacer les filtres ». Catégorie/marque sont gérées
  /// via les chips de la rangée principale (pas de doublon ici).
  Future<void> _openFiltersSheet() async {
    final position = _menuPositionUnder(_filtersBtnKey);
    if (position == null) return;
    final stockOptions = <(String?, String, IconData)>[
      (null,             'Tous',          Icons.all_inclusive_rounded),
      ('in_stock',       'En stock',      Icons.check_circle_outline_rounded),
      ('low_stock',      'Stock faible',  Icons.warning_amber_rounded),
      ('out_of_stock',   'Rupture',       Icons.remove_circle_outline_rounded),
    ];
    const _kClear = '__clear__';
    final selected = await showMenu<String>(
      context: context,
      position: position,
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
      items: [
        const PopupMenuItem<String>(
          enabled: false,
          height: 28,
          child: Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Stock',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: AppColors.textHint)),
          ),
        ),
        for (final o in stockOptions)
          PopupMenuItem<String>(
            value: 'stock:${o.$1 ?? ''}',
            child: Row(children: [
              Icon(o.$3,
                  size: 16,
                  color: _stockFilter == o.$1
                      ? AppColors.primary
                      : AppColors.textSecondary),
              const SizedBox(width: 10),
              Expanded(child: Text(o.$2,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: _stockFilter == o.$1
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: _stockFilter == o.$1
                          ? AppColors.primary
                          : AppColors.textPrimary))),
              if (_stockFilter == o.$1)
                Icon(Icons.check_rounded,
                    size: 14, color: AppColors.primary),
            ]),
          ),
        if (_activeFilterCount > 0) const PopupMenuDivider(height: 8),
        if (_activeFilterCount > 0)
          PopupMenuItem<String>(
            value: _kClear,
            child: Row(children: [
              Icon(Icons.clear_all_rounded,
                  size: 16, color: AppColors.error),
              const SizedBox(width: 10),
              Text('Effacer les filtres',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.error)),
            ]),
          ),
      ],
    );
    if (selected == null || !mounted) return;
    if (selected == _kClear) {
      setState(() {
        _filterCategories.clear();
        _filterBrands.clear();
        _priceRange = null;
        _stockFilter = null;
      });
      return;
    }
    if (selected.startsWith('stock:')) {
      final v = selected.substring('stock:'.length);
      setState(() => _stockFilter = v.isEmpty ? null : v);
    }
  }

  /// Ajout direct d'une variante sélectionnée depuis la tile (chip + "+").
  /// Bypasse le bottom sheet — l'utilisateur a déjà fait son choix.
  void _addVariantToCart(BuildContext context, Product p, int idx) {
    if (idx < 0 || idx >= p.variants.length) return;
    final v  = p.variants[idx];
    final id = v.id ?? '${p.id}_$idx';
    final name = p.variants.length == 1
        ? p.name
        : '${p.name} — ${v.name}';
    final bloc = context.read<CaisseBloc>();
    final stock = _stockForVariant(v, bloc.state.deliveryLocationId);
    _tryAddToCart(
      context,
      bloc,
      SaleItem(
        productId:   id,
        productName: name,
        unitPrice:   v.priceSellPos,
        priceBuy:    v.priceBuy,
        imageUrl:    v.imageUrl ?? p.mainImageUrl,
        quantity:    1,
      ),
      stock,
      displayName: name,
    );
  }
}

// ─── Tile liste (card horizontale pleine largeur) ────────────────────────────
class _PosProductListTile extends StatefulWidget {
  final Product                    product;
  final VoidCallback               onTap;
  final ValueChanged<int>?         onAddVariant;
  const _PosProductListTile({required this.product, required this.onTap,
      this.onAddVariant});
  @override
  State<_PosProductListTile> createState() => _PosProductListTileState();
}

class _PosProductListTileState extends State<_PosProductListTile> {
  /// `null` = aucun choix manuel → suit `Product.featuredVariant` (rotation
  /// auto sur égalité de stock). Cf. `_PosProductTileState` pour le détail.
  int? _userPickedIdx;

  int get _activeIdx {
    final v = widget.product.variants;
    if (v.isEmpty) return 0;
    if (_userPickedIdx != null && _userPickedIdx! < v.length) {
      return _userPickedIdx!;
    }
    final feat = widget.product.featuredVariant();
    if (feat != null) {
      final i = v.indexOf(feat);
      if (i >= 0) return i;
    }
    final priced = v.indexWhere((x) => x.priceSellPos > 0);
    return priced >= 0 ? priced : 0;
  }

  ProductVariant? get _sel {
    final v = widget.product.variants;
    if (v.isEmpty) return null;
    final i = _activeIdx;
    return (i >= 0 && i < v.length) ? v[i] : null;
  }

  double _price() {
    final v = _sel;
    if (v != null && v.priceSellPos > 0) return v.priceSellPos;
    final wp = widget.product.variants.where((x) => x.priceSellPos > 0);
    if (wp.isNotEmpty) return wp.first.priceSellPos;
    return widget.product.priceSellPos;
  }

  int _stock(String? deliveryLocId) {
    final v = _sel;
    if (v != null) return _stockForVariant(v, deliveryLocId);
    return _stockForProduct(widget.product, deliveryLocId);
  }

  Color _stockColor(int stock, int minAlert) {
    if (stock <= 0) return AppColors.error;
    if (stock <= minAlert) return AppColors.warning;
    return AppColors.secondary;
  }

  // _tapAdd supprimé (round 9) — bouton "+" retiré. La card entière
  // reste tappable via widget.onTap dans le GestureDetector du build.

  @override
  Widget build(BuildContext context) {
    if (_userPickedIdx == null) {
      return ValueListenableBuilder<int>(
        valueListenable: featuredRotationTicker,
        builder: (_, __, ___) => _buildRow(context),
      );
    }
    return _buildRow(context);
  }

  Widget _buildRow(BuildContext context) {
    final l          = context.l10n;
    final p          = widget.product;
    final sel        = _sel;
    final deliveryLocId = context.select<CaisseBloc, String?>(
        (b) => b.state.deliveryLocationId);
    final minAlert   = sel?.stockMinAlert ?? p.stockMinAlert;
    final stock      = _stock(deliveryLocId);
    final outOfStock = stock <= 0;
    final lowStock   = !outOfStock && stock <= minAlert;
    final price      = _price();
    final stockColor = _stockColor(stock, minAlert);
    final variants   = p.variants;
    final hasVariants = variants.length > 1;
    final indicator  = outOfStock
        ? AppColors.error : (lowStock ? AppColors.warning : null);

    return GestureDetector(
      onTap: outOfStock ? null : widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha:0.03),
                blurRadius: 4, offset: const Offset(0, 1)),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
            if (indicator != null)
              Container(width: 3, color: indicator),
            // ── Thumbnail 48×48 ─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.all(10),
              child: ProductImageCard(
                imageUrl: sel?.imageUrl ?? p.mainImageUrl,
                width:  48,
                height: 48,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            // ── Infos (nom + SKU + chips) ─────────────────────────
            Expanded(child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                Row(children: [
                  Expanded(child: Text(p.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary))),
                  if (outOfStock) ...[
                    const SizedBox(width: 4),
                    _StockBadgePill(
                        label: l.boutiqueOutOfStock,
                        color: AppColors.error),
                  ] else if (lowStock) ...[
                    const SizedBox(width: 4),
                    _StockBadgePill(
                        label: l.boutiqueLowStock,
                        color: AppColors.warning),
                  ],
                ]),
                if ((sel?.sku ?? p.sku) != null &&
                    (sel?.sku ?? p.sku)!.isNotEmpty)
                  Text(sel?.sku ?? p.sku!,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10,
                          fontFamily: 'monospace',
                          color: AppColors.textHint)),
                if (hasVariants) ...[
                  const SizedBox(height: 4),
                  _VariantChipRow(
                    variants: variants,
                    selectedIdx: _activeIdx,
                    onSelect: (i) => setState(() => _userPickedIdx = i),
                    onMore: widget.onTap,
                  ),
                ],
              ]),
            )),
            // ── Prix + stock ───────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                Text(price > 0
                        ? CurrencyFormatter.format(price)
                        : 'N/D',
                    style: const TextStyle(fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text('$stock',
                    style: TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: stockColor)),
              ]),
            ),
            // Bouton « + » end-of-row supprimé (round 9) — la card
            // entière reste tappable pour ajouter au panier (cf.
            // InkWell parent qui appelle _tapAdd).
          ]),
        ),
      ),
    );
  }
}

// ─── Toggle vue grille / liste (2 icônes, sélection exclusive) ───────────────
class _ViewModeToggle extends StatelessWidget {
  final String mode; // 'grid' | 'list'
  final ValueChanged<String> onChanged;
  const _ViewModeToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _ViewModeBtn(
          icon: Icons.grid_view_rounded,
          active: mode == 'grid',
          tooltip: l.boutiqueViewGrid,
          onTap: () => onChanged('grid'),
        ),
        _ViewModeBtn(
          icon: Icons.view_list_rounded,
          active: mode == 'list',
          tooltip: l.boutiqueViewList,
          onTap: () => onChanged('list'),
        ),
      ]),
    );
  }
}

class _ViewModeBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final String tooltip;
  const _ViewModeBtn({required this.icon, required this.active,
      required this.onTap, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: active ? [
              BoxShadow(color: Colors.black.withValues(alpha:0.05),
                  blurRadius: 4, offset: const Offset(0, 1)),
            ] : null,
          ),
          child: Icon(icon, size: 16,
              color: active ? AppColors.primary : AppColors.textSecondary),
        ),
      ),
    );
  }
}

// ─── Bouton toolbar (Filtres / Trier) avec badge compteur optionnel ──────────
class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String   label;
  final VoidCallback onTap;
  final int badge;
  const _ToolbarButton({
    super.key,
    required this.icon, required this.label, required this.onTap,
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
    final active = badge > 0;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: active
                ? AppColors.primarySurface
                : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: active ? AppColors.primary : AppColors.divider),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15,
                color: active ? AppColors.primary : AppColors.textSecondary),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: active ? AppColors.primary : AppColors.textPrimary)),
            if (badge > 0) ...[
              const SizedBox(width: 5),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$badge',
                    style: const TextStyle(fontSize: 9,
                        fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

// ─── Pill badge stock (rupture/bas) dans la zone image ───────────────────────
class _StockBadgePill extends StatelessWidget {
  final String label;
  final Color color;
  const _StockBadgePill({required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color, borderRadius: BorderRadius.circular(6),
    ),
    child: Text(label,
        style: const TextStyle(fontSize: 9,
            fontWeight: FontWeight.w800, color: Colors.white)),
  );
}

// ─── Ligne de chips variantes (max 4 + "+N") ─────────────────────────────────
class _VariantChipRow extends StatelessWidget {
  final List<ProductVariant> variants;
  final int                  selectedIdx;
  final ValueChanged<int>    onSelect;
  final VoidCallback         onMore;
  const _VariantChipRow({required this.variants, required this.selectedIdx,
      required this.onSelect, required this.onMore});

  @override
  Widget build(BuildContext context) {
    const maxVisible = 4;
    final visible = variants.take(maxVisible).toList();
    final extra   = variants.length - maxVisible;

    return SizedBox(height: 20,
      child: Row(children: [
        Expanded(child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: visible.length,
          separatorBuilder: (_, __) => const SizedBox(width: 4),
          itemBuilder: (_, i) {
            final isSel = i == selectedIdx;
            return GestureDetector(
              onTap: () => onSelect(i),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: isSel
                      ? AppColors.primarySurface
                      : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSel
                        ? AppColors.primary
                        : AppColors.divider,
                    width: isSel ? 1.2 : 1,
                  ),
                ),
                child: Center(child: Text(visible[i].name,
                    style: TextStyle(fontSize: 9,
                        fontWeight: isSel
                            ? FontWeight.w800 : FontWeight.w600,
                        color: isSel
                            ? AppColors.primary
                            : AppColors.textSecondary))),
              ),
            );
          },
        )),
        if (extra > 0) ...[
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onMore,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha:0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('+$extra',
                  style: TextStyle(fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary)),
            ),
          ),
        ],
      ]),
    );
  }
}

