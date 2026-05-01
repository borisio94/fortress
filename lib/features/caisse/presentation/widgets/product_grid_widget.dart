import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../bloc/caisse_bloc.dart';
import '../../domain/entities/sale_item.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../features/inventaire/domain/entities/product.dart';

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

  List<Product> get _products {
    final all = AppDatabase.getProductsForShop(widget.shopId)
        .where((p) => p.isActive)
        .toList();

    var list = _query.isEmpty
        ? all
        : all.where((p) =>
    p.name.toLowerCase().contains(_query.toLowerCase()) ||
        (p.sku ?? '').toLowerCase().contains(_query.toLowerCase()) ||
        (p.barcode ?? '').contains(_query)).toList();

    if (_filter == 'Stock faible') {
      list = list.where((p) => p.isLowStock && !p.isOutOfStock).toList();
    } else if (_filter == 'Rupture') {
      list = list.where((p) => p.isOutOfStock).toList();
    }

    return list;
  }

  @override
  Widget build(BuildContext context) {
    final products = _products;
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
    // Pas de variantes → ajouter directement au panier
    if (product.variants.isEmpty || product.variants.length == 1) {
      final v = product.variants.isNotEmpty ? product.variants.first : null;
      final price = v?.priceSellPos ?? product.priceSellPos;
      final id = v?.id ?? (product.id ?? product.name);
      final stock = v?.stockAvailable ?? product.totalStock;
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
    final stockColor = product.isOutOfStock
        ? const Color(0xFFEF4444)
        : product.isLowStock
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
    final canTap = !product.isOutOfStock || hasVariants;

    return GestureDetector(
      onTap: canTap ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: product.isOutOfStock ? 0.4 : 1.0,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.03),
                  blurRadius: 4,
                  offset: const Offset(0, 1)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Image / Icône — gère URL distante ET chemin local
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(11)),
                  child: _ProductImageSmart(
                    url: product.mainImageUrl,
                    fallback: _ProductIcon(),
                  ),
                ),
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
                          product.isOutOfStock
                              ? 'Rupture'
                              : '${product.totalStock} en stock',
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

class _ProductIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    color: const Color(0xFFF3F4F6),
    child: const Center(
      child: Icon(Icons.inventory_2_outlined,
          size: 28, color: Color(0xFFD1D5DB)),
    ),
  );
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
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _ProductImageSmart(
                    url: product.mainImageUrl,
                    fallback: Icon(Icons.inventory_2_outlined,
                        size: 20, color: AppColors.primary),
                  ),
                ),
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
                final outOfStock = v.stockQty <= 0;
                final lowStock   = v.stockQty > 0 &&
                    v.stockQty <= v.stockMinAlert;

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
                      v.stockAvailable,
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
                        Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3F4F6),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: _ProductImageSmart(
                              url: v.imageUrl,
                              fallback: Icon(Icons.layers_rounded,
                                  size: 18, color: AppColors.primary),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),

                        // Nom + SKU
                        Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Text(v.name,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF0F172A))),
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
                                      : '${v.stockAvailable} dispo',
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
class PosProductPanel extends StatefulWidget {
  final String shopId;
  const PosProductPanel({super.key, required this.shopId});
  @override
  State<PosProductPanel> createState() => _PosProductPanelState();
}

class _PosProductPanelState extends State<PosProductPanel> {
  String _query = '';
  // ─── État filtres (étape 5 : bottom sheet pour éditer) ─────────────
  Set<String> _filterCategories = {};
  Set<String> _filterBrands     = {};
  RangeValues? _priceRange;   // null = pas de filtre
  String? _stockFilter;       // null | 'in_stock' | 'low_stock' | 'out_of_stock'
  // ─── État tri (étape 6) ─────────────────────────────────────────────
  String _sort = 'name';     // 'name' | 'price_asc' | 'price_desc' | 'stock'
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

  List<Product> get _products {
    final all = AppDatabase.getProductsForShop(widget.shopId)
        .where((p) => p.isActive)
        .toList();
    if (_query.isEmpty) return all;
    return all.where((p) =>
    p.name.toLowerCase().contains(_query.toLowerCase()) ||
        (p.sku ?? '').toLowerCase().contains(_query.toLowerCase())).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l        = context.l10n;
    final products = _products;
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
      icon: Icons.tune_rounded,
      label: l.boutiqueFilters,
      badge: _activeFilterCount,
      onTap: _openFiltersSheet,
    );
    final sortBtn = _ToolbarButton(
      icon: Icons.sort_rounded,
      label: l.boutiqueSort,
      onTap: _openSortSheet,
    );

    return Column(children: [
      // ── Barre recherche + filtres + tri ─────────────────────────
      // Mobile : tout sur 1 ligne pour libérer ~40px au profit de la
      // grille. Desktop : layout 2 lignes (search pleine largeur, puis
      // boutons en dessous) — comportement original Material.
      Container(
        color: Colors.white,
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
        color: Colors.white,
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
                : Align(
                    alignment: Alignment.topLeft,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
                      child: Wrap(
                        alignment:   WrapAlignment.start,
                        spacing:     12,
                        runSpacing:  12,
                        children: products.map((p) => SizedBox(
                          width:  200,
                          height: 320,
                          child: _PosProductTile(
                            product: p,
                            onTap:         () => _handleTap(context, p),
                            onAddVariant:  (idx) => _addVariantToCart(
                                context, p, idx),
                          ),
                        )).toList(),
                      ),
                    ),
                  ),
      ),
    ]);
  }

  void _handleTap(BuildContext context, Product product) {
    if (product.variants.isEmpty || product.variants.length == 1) {
      final v = product.variants.isNotEmpty ? product.variants.first : null;
      final price = v?.priceSellPos ?? product.priceSellPos;
      final id = v?.id ?? (product.id ?? product.name);
      final stock = v?.stockAvailable ?? product.totalStock;
      _tryAddToCart(
        context,
        context.read<CaisseBloc>(),
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

  /// Ouvre le bottom sheet de filtres (catégorie, marque, prix, stock).
  /// Implémentation complète livrée à l'étape 5.
  void _openFiltersSheet() {
    // Placeholder — étape 5 : construira le bottom sheet et appellera setState
    // sur _filterCategories / _filterBrands / _priceRange / _stockFilter.
  }

  /// Ouvre le bottom sheet de tri. Implémentation complète livrée à l'étape 6.
  void _openSortSheet() {
    // Placeholder — étape 6 : setState sur _sort parmi les options.
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
    _tryAddToCart(
      context,
      context.read<CaisseBloc>(),
      SaleItem(
        productId:   id,
        productName: name,
        unitPrice:   v.priceSellPos,
        priceBuy:    v.priceBuy,
        imageUrl:    v.imageUrl ?? p.mainImageUrl,
        quantity:    1,
      ),
      v.stockAvailable,
      displayName: name,
    );
  }
}

// ─── Tuile POS (image carrée + corps surface) ────────────────────────────────
class _PosProductTile extends StatefulWidget {
  final Product                    product;
  final VoidCallback               onTap;         // legacy — ouvre variant picker
  final ValueChanged<int>?         onAddVariant;  // add direct depuis chip + "+"
  const _PosProductTile({required this.product, required this.onTap,
      this.onAddVariant});
  @override
  State<_PosProductTile> createState() => _PosProductTileState();
}

class _PosProductTileState extends State<_PosProductTile> {
  int? _selectedIdx;

  @override
  void initState() {
    super.initState();
    // Sélection par défaut : variante principale ou premier avec prix > 0
    final v = widget.product.variants;
    if (v.isNotEmpty) {
      final mainIdx = v.indexWhere((x) => x.isMain);
      _selectedIdx = mainIdx >= 0 ? mainIdx
          : v.indexWhere((x) => x.priceSellPos > 0);
      if (_selectedIdx! < 0) _selectedIdx = 0;
    }
  }

  ProductVariant? get _selectedVariant => _selectedIdx != null
      && _selectedIdx! < widget.product.variants.length
      ? widget.product.variants[_selectedIdx!] : null;

  double _displayPrice() {
    final v = _selectedVariant;
    if (v != null && v.priceSellPos > 0) return v.priceSellPos;
    // Fallback : premier prix variant > 0 ou prix produit
    final withPrice = widget.product.variants
        .where((x) => x.priceSellPos > 0);
    if (withPrice.isNotEmpty) return withPrice.first.priceSellPos;
    return widget.product.priceSellPos;
  }

  int _displayStock() {
    final v = _selectedVariant;
    if (v != null) return v.stockAvailable;
    return widget.product.totalStock;
  }

  double? _displayMargin() {
    final v = _selectedVariant;
    if (v != null) return v.marginPos;
    return widget.product.marginPos;
  }

  Color _stockColor(int stock, int minAlert) {
    if (stock <= 0) return AppColors.error;
    if (stock <= minAlert) return AppColors.warning;
    return AppColors.secondary;
  }

  void _tapChip(int idx) {
    setState(() => _selectedIdx = idx);
  }

  // _tapAdd supprimé (round 9) — était utilisé par le bouton "+" qui a
  // été retiré. La card entière reste tappable via widget.onTap dans le
  // GestureDetector ci-dessous.

  @override
  Widget build(BuildContext context) {
    final l          = context.l10n;
    final p          = widget.product;
    final sel        = _selectedVariant;
    final minAlert   = sel?.stockMinAlert ?? p.stockMinAlert;
    final stock      = _displayStock();
    final outOfStock = stock <= 0;
    final lowStock   = !outOfStock && stock <= minAlert;
    final price      = _displayPrice();
    final margin     = _displayMargin();
    final stockColor = _stockColor(stock, minAlert);
    final rawRating  = p.rating.clamp(0, 5);
    final stars      = rawRating > 5 ? 5 : rawRating;
    final variants   = p.variants;
    final hasVariants = variants.length > 1;

    return GestureDetector(
      // Si le produit a des variantes, on laisse cliquer même en rupture
      // pour ouvrir le sélecteur. La validation finale du stock se fait
      // dans caisse_bloc._validateStock à l'ajout au panier.
      onTap: (outOfStock && !hasVariants) ? null : widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider, width: 1),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.04),
                blurRadius: 8, offset: const Offset(0, 2)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
            // ═══ Zone image (1:1) avec badges et bouton + ═══
            AspectRatio(
              aspectRatio: 1,
              child: Stack(fit: StackFit.expand, children: [
                _ProductImageSmart(
                  url: sel?.imageUrl ?? p.mainImageUrl,
                  fallback: _PosProductIcon(),
                ),
                // Badge variantes (top-left)
                if (hasVariants)
                  Positioned(top: 8, left: 8, child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('${variants.length}v',
                        style: const TextStyle(fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Colors.white)),
                  )),
                // Badge statut stock (top-right)
                if (outOfStock)
                  Positioned(top: 8, right: 8, child: _StockBadgePill(
                      label: l.boutiqueOutOfStock, color: AppColors.error)),
                if (lowStock)
                  Positioned(top: 8, right: 8, child: _StockBadgePill(
                      label: l.boutiqueLowStock, color: AppColors.warning)),
                // Bouton « + » bottom-right supprimé (round 9) — la card
                // entière reste tappable pour ajouter au panier (cf.
                // GestureDetector/InkWell wrapping la card).
              ]),
            ),

            // ═══ Corps card (fond surface blanc) ═══
            Expanded(child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                // Étoiles + nom + SKU
                if (stars > 0) _StarRating(filled: stars, total: 5),
                if (stars > 0) const SizedBox(height: 3),
                Text(p.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                        height: 1.15)),
                if ((sel?.sku ?? p.sku) != null &&
                    (sel?.sku ?? p.sku)!.isNotEmpty)
                  Text(sel?.sku ?? p.sku!,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9,
                          fontFamily: 'monospace',
                          color: AppColors.textHint)),
                const SizedBox(height: 4),
                // Prix + stock
                Row(crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                  Expanded(child: Text(
                    price > 0
                        ? CurrencyFormatter.format(price)
                        : 'N/D',
                    style: const TextStyle(fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary),
                  )),
                  Text('$stock',
                      style: TextStyle(fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: stockColor)),
                ]),
                const SizedBox(height: 5),
                // Chips variantes (max 4 + "+N")
                if (hasVariants)
                  _VariantChipRow(
                    variants: variants,
                    selectedIdx: _selectedIdx ?? 0,
                    onSelect: _tapChip,
                    onMore: widget.onTap,
                  ),
                const Spacer(),
                // Pill marge (bottom-left)
                if (margin != null)
                  Align(alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.secondary.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text('${margin.toStringAsFixed(0)}%',
                          style: TextStyle(fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: AppColors.secondary)),
                    ),
                  ),
              ]),
            )),
          ]),
        ),
      ),
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
  int? _selectedIdx;

  @override
  void initState() {
    super.initState();
    final v = widget.product.variants;
    if (v.isNotEmpty) {
      final mainIdx = v.indexWhere((x) => x.isMain);
      _selectedIdx = mainIdx >= 0 ? mainIdx
          : v.indexWhere((x) => x.priceSellPos > 0);
      if (_selectedIdx! < 0) _selectedIdx = 0;
    }
  }

  ProductVariant? get _sel => _selectedIdx != null
      && _selectedIdx! < widget.product.variants.length
      ? widget.product.variants[_selectedIdx!] : null;

  double _price() {
    final v = _sel;
    if (v != null && v.priceSellPos > 0) return v.priceSellPos;
    final wp = widget.product.variants.where((x) => x.priceSellPos > 0);
    if (wp.isNotEmpty) return wp.first.priceSellPos;
    return widget.product.priceSellPos;
  }

  int _stock() => _sel?.stockAvailable ?? widget.product.totalStock;

  Color _stockColor(int stock, int minAlert) {
    if (stock <= 0) return AppColors.error;
    if (stock <= minAlert) return AppColors.warning;
    return AppColors.secondary;
  }

  // _tapAdd supprimé (round 9) — bouton "+" retiré. La card entière
  // reste tappable via widget.onTap dans le GestureDetector du build.

  @override
  Widget build(BuildContext context) {
    final l          = context.l10n;
    final p          = widget.product;
    final sel        = _sel;
    final minAlert   = sel?.stockMinAlert ?? p.stockMinAlert;
    final stock      = _stock();
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
            BoxShadow(color: Colors.black.withOpacity(0.03),
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
              child: SizedBox(width: 48, height: 48,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _ProductImageSmart(
                    url: sel?.imageUrl ?? p.mainImageUrl,
                    fallback: Container(
                      color: AppColors.inputFill,
                      child: const Icon(Icons.inventory_2_outlined,
                          size: 20, color: AppColors.textHint),
                    ),
                  ),
                ),
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
                    selectedIdx: _selectedIdx ?? 0,
                    onSelect: (i) => setState(() => _selectedIdx = i),
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
              BoxShadow(color: Colors.black.withOpacity(0.05),
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
                color: AppColors.primary.withOpacity(0.1),
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

// ─── Étoiles de notation ──────────────────────────────────────────────────────
class _StarRating extends StatelessWidget {
  final int filled;
  final int total;
  const _StarRating({required this.filled, this.total = 5});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: List.generate(total, (i) => Padding(
      padding: const EdgeInsets.only(right: 1.5),
      child: Icon(
        i < filled
            ? Icons.star_rounded
            : Icons.star_outline_rounded,
        size: 12,
        color: i < filled
            ? const Color(0xFFFFCC00)   // or doré
            : const Color(0xFFDDDDDD),
      ),
    )),
  );
}

class _PosProductIcon extends StatelessWidget {
  const _PosProductIcon();
  @override
  Widget build(BuildContext context) => Container(
    color: const Color(0xFFEDE9FA),
    child: Center(
      child: Icon(Icons.shopping_bag_outlined,
          size: 44, color: AppColors.primary.withOpacity(0.3)),
    ),
  );
}

/// Widget intelligent qui détecte si l'URL est :
///  - http/https → Image.network (avec error builder)
///  - chemin local (file path) → Image.file
///  - null/vide → fallback fourni
class _ProductImageSmart extends StatelessWidget {
  final String? url;
  final Widget fallback;
  const _ProductImageSmart({required this.url, required this.fallback});

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u == null || u.isEmpty) return fallback;

    if (u.startsWith('http://') || u.startsWith('https://')) {
      return Image.network(
        u,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: 400,
        loadingBuilder: (ctx, child, progress) {
          if (progress == null) return child;
          return Container(
            color: const Color(0xFFF9FAFB),
            alignment: Alignment.center,
            child: const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: Color(0xFFD1D5DB)),
            ),
          );
        },
        errorBuilder: (_, __, ___) => fallback,
      );
    }

    return Image.file(
      File(u),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}