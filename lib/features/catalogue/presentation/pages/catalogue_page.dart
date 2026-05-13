import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/link.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/autocomplete_text_field.dart';
import '../../../../shared/widgets/product_grid_card.dart';
import '../../../inventaire/domain/entities/product.dart';

/// Catalogue public d'une boutique — accessible sans authentification via
/// `/catalogue/:shopId` avec query params optionnels :
///   - `cat=<categorie>` : filtre par catégorie initiale
///   - `ids=<id1,id2,...>` : restreint à certains produits
///
/// Chaque **variante** est affichée comme une card distincte avec sa
/// propre image / prix / stock. L'utilisateur peut :
///   - Commander un item directement → ouvre wa.me
///   - Activer le mode sélection multi → cocher plusieurs items → FAB
///     "Commander la sélection" envoie un message wa.me unique avec la
///     liste détaillée.
class CataloguePage extends StatefulWidget {
  final String        shopId;
  final String?       initialCategory;
  final List<String>? productIds;

  /// Snapshot de stock filtré au moment du partage. Clé = `productId`
  /// (produit sans variante) ou `productId|variantId` (variante). Quand
  /// fourni, on l'utilise au lieu du `stock_qty`/`stock_available` global
  /// retourné par Supabase — permet d'afficher au client le stock du
  /// périmètre actuellement visualisé par le marchand au moment du
  /// partage (Boutique seule, Partenaire X, Globale). Snapshot figé,
  /// pas refresh temps réel. Null = comportement historique (cumul).
  final Map<String, int>? stockOverride;

  const CataloguePage({
    super.key,
    required this.shopId,
    this.initialCategory,
    this.productIds,
    this.stockOverride,
  });

  @override
  State<CataloguePage> createState() => _CataloguePageState();
}

class _CataloguePageState extends State<CataloguePage> {
  late Future<_CatalogueData> _future;
  String? _category;
  bool _selectMode = false;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory;
    _future = _load();
  }

  Future<_CatalogueData> _load() async {
    final db = Supabase.instance.client;
    final shopRow = await db
        .from('shops').select('id,name,phone')
        .eq('id', widget.shopId).maybeSingle();
    if (shopRow == null) {
      throw Exception(
          'Boutique introuvable ou non publique.\n\n'
          'Vérifiez que la migration `hotfix_045_catalogue_public.sql` '
          'a été appliquée côté Supabase et que la boutique est active.');
    }
    final ids = widget.productIds;
    final hasExplicitIds = ids != null && ids.isNotEmpty;
    // Quand le partage WhatsApp inclut une liste d'`ids` précise, l'owner
    // a explicitement consenti à exposer ces produits — on bypass alors
    // le filtre `is_visible_web` (qui sert à masquer le reste du catalogue
    // de la boutique au visiteur générique). On garde `is_active=true`
    // pour ne pas exposer un produit archivé / supprimé.
    var query = db
        .from('products')
        .select(
            'id,name,sku,price_sell_pos,stock_qty,image_url,'
            'category_id,brand,is_visible_web,is_active,variants')
        .eq('store_id', widget.shopId)
        .eq('is_active', true);
    if (!hasExplicitIds) {
      query = query.eq('is_visible_web', true);
    }
    if (hasExplicitIds) {
      query = query.inFilter('id', ids);
    }
    final rows = await query.order('name');
    final products = (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    // Flatten produit + variantes en items (1 card par variante). Try/catch
    // par produit pour ne pas tout crasher si un seul produit a un format
    // de variantes inattendu — le reste s'affiche quand même.
    final items = <_CatalogueItem>[];
    for (final p in products) {
      try {
        final base = (p['name'] as String?) ?? '';
        final variantsRaw = p['variants'];
        final variants = variantsRaw is List ? variantsRaw : const [];
        // On filtre les "fausses" variantes (sans nom ou vides) pour décider
        // si afficher 1 card produit ou N cards variantes.
        final realVariants = variants.where((v) {
          if (v is! Map) return false;
          final n = (v['name'] as String?)?.trim();
          return n != null && n.isNotEmpty;
        }).toList();

        final override = widget.stockOverride;
        if (realVariants.length <= 1) {
          final pid = p['id'] as String;
          // Si snapshot fourni → priorité au stock du périmètre choisi
          // par le marchand au moment du partage. Sinon → stock_qty
          // global Supabase (cumul historique toutes locations).
          final snapStock = override?[pid];
          items.add(_CatalogueItem(
            productId:       pid,
            variantId:       null,
            name:            base,
            baseProductName: base,
            variantName:     null,
            sku:             p['sku'] as String?,
            price:           (p['price_sell_pos'] as num?)?.toDouble() ?? 0,
            stock:           snapStock
                ?? (p['stock_qty'] as num?)?.toInt() ?? 0,
            imageUrl:        p['image_url'] as String?,
            categoryId:      p['category_id'] as String?,
          ));
        } else {
          final pid = p['id'] as String;
          // Clé snapshot = `productId|<idx>` où idx = position dans
          // `realVariants` (= post-filtre name non vide). Aligné avec
          // `_buildStockSnapshot` côté inventaire/dashboard pour que
          // le matching survive aux divergences d'ID variants entre
          // Hive local et JSONB Supabase.
          for (int idx = 0; idx < realVariants.length; idx++) {
            final v = Map<String, dynamic>.from(realVariants[idx] as Map);
            final variantName = (v['name'] as String).trim();
            final vid = v['id']?.toString() ?? variantName;
            final snapStock = override?['$pid|$idx'];
            items.add(_CatalogueItem(
              productId:       pid,
              variantId:       vid,
              name:            '$base — $variantName',
              baseProductName: base,
              variantName:     variantName,
              sku:             (v['sku'] as String?) ?? (p['sku'] as String?),
              price: (v['price_sell_pos'] as num?)?.toDouble()
                  ?? (p['price_sell_pos'] as num?)?.toDouble() ?? 0,
              stock: snapStock
                  ?? ((v['stock_available'] ?? v['stock_qty']) as num?)
                      ?.toInt()
                  ?? 0,
              imageUrl: (v['image_url'] as String?) ??
                  p['image_url'] as String?,
              categoryId: p['category_id'] as String?,
            ));
          }
        }
      } catch (e) {
        debugPrint('[Catalogue] erreur parsing produit ${p['id']}: $e');
      }
    }

    debugPrint('[Catalogue] shop=${widget.shopId} '
        'produits=${products.length} items=${items.length} '
        '(ids=${ids?.length ?? 'all'}, cat=${widget.initialCategory ?? 'all'})');

    final categories = items
        .map((i) => i.categoryId?.trim())
        .whereType<String>()
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    return _CatalogueData(
      shop: _ShopHeaderData(
        name:  shopRow['name'] as String? ?? '',
        phone: shopRow['phone'] as String?,
      ),
      items:      items,
      categories: categories,
    );
  }

  /// Liste des items sélectionnés ET disponibles (stock > 0). Les items
  /// en rupture sont exclus à l'envoi pour éviter qu'un client commande
  /// un produit indisponible.
  List<_CatalogueItem> _selectedAvailable(_CatalogueData data) =>
      data.items
          .where((it) => _selected.contains(it.key) && it.stock > 0)
          .toList();

  /// URI `wa.me/<phone>?text=<msg>` pour commander la sélection courante.
  /// Exclut les items en rupture de stock.
  Uri _buildBatchOrderUri(_CatalogueData data) {
    final shopName = data.shop.name;
    final selectedItems = _selectedAvailable(data);
    final buf = StringBuffer()
      ..write('Bonjour ')
      ..write(shopName.isEmpty ? '' : '$shopName, ')
      ..writeln('je souhaite commander :')
      ..writeln();
    var total = 0.0;
    for (final it in selectedItems) {
      buf.writeln('• ${it.name} — ${it.price.toStringAsFixed(0)} XAF');
      total += it.price;
    }
    buf
      ..writeln()
      ..writeln('Total estimé : ${total.toStringAsFixed(0)} XAF');
    return _waUri(data.shop.phone, buf.toString());
  }

  Uri _waUri(String? phone, String message) {
    final p = (phone ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    final encoded = Uri.encodeComponent(message);
    return Uri.parse(p.isEmpty
        ? 'https://wa.me/?text=$encoded'
        : 'https://wa.me/$p?text=$encoded');
  }

  /// Ouvre le sheet "Passer commande" pour finaliser un achat directement
  /// dans la page web (sans repasser par WhatsApp). À la confirmation,
  /// appelle la RPC `place_public_order` qui insert un row dans `orders`
  /// — le marchand connecté reçoit la notif in-app via Realtime.
  Future<void> _placeOrder(_CatalogueData data,
      List<_CatalogueItem> items) async {
    if (items.isEmpty) return;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _PlaceOrderSheet(
        shopId: widget.shopId,
        shopName: data.shop.name,
        items: items,
      ),
    );
    if (ok == true && mounted) {
      // Reset sélection après commande validée.
      setState(() {
        _selectMode = false;
        _selected.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.secondary,
          content: const Text(
              '✓ Commande envoyée — la boutique vous recontactera.',
              style: TextStyle(color: Colors.white)),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  /// Toggle la sélection d'un item. Si le mode sélection n'est pas encore
  /// activé, l'active automatiquement (UX naturelle : taper sur une card
  /// suffit pour entrer dans le mode sélection avec cette card cochée).
  void _toggleSelect(String key) {
    setState(() {
      if (!_selectMode) _selectMode = true;
      if (_selected.contains(key)) {
        _selected.remove(key);
      } else {
        _selected.add(key);
      }
    });
  }

  /// Projette un `_CatalogueItem` (déjà déplié — 1 item = 1 variante) sur
  /// l'entité `Product` attendue par `ProductGridCard`. Le Product fake
  /// a `variants: const []` car la grille catalogue affiche déjà chaque
  /// variante comme une card distincte (pas de `_VariantsRow` à rendre).
  /// `item.name` est utilisé tel quel — déjà concaténé "Produit — Variante"
  /// dans la construction de `_CatalogueItem` (cf. `_load`).
  Product _itemToProduct(_CatalogueItem item) => Product(
        id:            item.productId,
        name:          item.name,
        sku:           item.sku,
        priceSellPos:  item.price,
        stockQty:      item.stock,
        stockMinAlert: 1,
        imageUrl:      item.imageUrl,
      );

  Future<void> _openFiltersSheet(_CatalogueData data) async {
    final result = await showModalBottomSheet<_FiltersResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _FiltersSheet(
        categories:      data.categories,
        currentCategory: _category,
      ),
    );
    if (result != null) {
      setState(() => _category = result.category);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: FutureBuilder<_CatalogueData>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${snap.error}',
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, color: theme.colorScheme.error)),
              ),
            );
          }
          final data = snap.data!;
          final filtered = _category == null
              ? data.items
              : data.items.where((it) => it.categoryId == _category).toList();
          // Layout : contenu défilable + bandeau de validation FIXÉ en bas
          // (hors scroll, toujours visible). Avant on utilisait un
          // `Positioned` dans un `Stack` qui pouvait être rendu invisible
          // selon la fenêtre.
          return SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: LayoutBuilder(builder: (_, c) {
                    final isWide = c.maxWidth >= 700;
                    final cols   = isWide ? 3 : 2;
                    // Ratio 3:4 unifié — `ProductGridCard` (design overlay
                    // dégradé) impose lui-même un AspectRatio interne, on
                    // garde le delegate aligné pour éviter une double
                    // contrainte conflictuelle.
                    const aspect = 0.75;
                    return CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                            child: _Header(shopName: data.shop.name)),
                        const SliverToBoxAdapter(child: _OrderHint()),
                        SliverToBoxAdapter(
                          child: _Toolbar(
                            activeCategory:  _category,
                            onOpenFilters:   () => _openFiltersSheet(data),
                            selectMode:      _selectMode,
                            selectedCount:   _selected.length,
                            onToggleSelect:  () => setState(() {
                              _selectMode = !_selectMode;
                              if (!_selectMode) _selected.clear();
                            }),
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 8)),
                        if (filtered.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: _Empty(
                              isFiltered: data.items.isNotEmpty &&
                                  filtered.isEmpty,
                              hasIdsFilter: widget.productIds != null,
                            ),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            sliver: SliverGrid(
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: cols,
                                mainAxisSpacing: 16,
                                crossAxisSpacing: 16,
                                childAspectRatio: aspect,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (_, i) {
                                  final item = filtered[i];
                                  final selected =
                                      _selected.contains(item.key);
                                  // Le tap déclenche `_toggleSelect` peu
                                  // importe le mode : la méthode active
                                  // automatiquement `_selectMode` si elle
                                  // est appelée pour la 1re fois. On peut
                                  // donc câbler `onTap` et
                                  // `onSelectionChanged` à la même
                                  // callback sans risque.
                                  return ProductGridCard(
                                    product: _itemToProduct(item),
                                    imageUrlOverride: item.imageUrl,
                                    stockOverride:    item.stock,
                                    stockMinAlertOverride: 1,
                                    selectable:       _selectMode,
                                    selected:         selected,
                                    onSelectionChanged: (_) =>
                                        _toggleSelect(item.key),
                                    onTap: () =>
                                        _toggleSelect(item.key),
                                  );
                                },
                                childCount: filtered.length,
                              ),
                            ),
                          ),
                      ],
                    );
                  }),
                ),
                // Bandeau "Commander" fixé en bas — TOUJOURS visible si
                // sélection ≥ 1, peu importe la taille de la fenêtre.
                if (_selectMode && _selected.isNotEmpty)
                  _BatchOrderBar(
                    count:           _selected.length,
                    availableCount:  _selectedAvailable(data).length,
                    waOrderUri:      _buildBatchOrderUri(data),
                    onPlaceOrder:    () => _placeOrder(
                      data,
                      _selectedAvailable(data),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─── Modèles ───────────────────────────────────────────────────────────────

class _CatalogueItem {
  final String  productId;
  final String? variantId;
  final String  name;
  final String  baseProductName;
  final String? variantName;
  final String? sku;
  final double  price;
  final int     stock;
  final String? imageUrl;
  final String? categoryId;

  const _CatalogueItem({
    required this.productId,
    required this.variantId,
    required this.name,
    required this.baseProductName,
    required this.variantName,
    required this.sku,
    required this.price,
    required this.stock,
    required this.imageUrl,
    required this.categoryId,
  });

  String get key => variantId == null ? productId : '$productId|$variantId';
}

class _ShopHeaderData {
  final String name;
  final String? phone;
  const _ShopHeaderData({required this.name, this.phone});
}

class _CatalogueData {
  final _ShopHeaderData       shop;
  final List<_CatalogueItem>  items;
  final List<String>          categories;
  const _CatalogueData({
    required this.shop,
    required this.items,
    required this.categories,
  });
}

// ─── Header ────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final String shopName;
  const _Header({required this.shopName});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary, AppColors.primaryLight],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            const FortressLogo.dark(size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(shopName.isEmpty ? l.hubBrand : shopName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                  Text(l.catalogueTagline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.85))),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 14),
          Text(l.catalogueTitle,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onPrimary
                      .withValues(alpha: 0.9))),
        ],
      ),
    );
  }
}

// ─── Bandeau d'aide commande ───────────────────────────────────────────────
//
// Indique au client public qu'il peut sélectionner des produits puis passer
// commande. Affiché juste sous le header, avant la toolbar — visible dès
// l'ouverture de la page partagée par WhatsApp.

class _OrderHint extends StatelessWidget {
  const _OrderHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Row(children: [
        Icon(Icons.touch_app_rounded,
            size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Cliquez sur un produit pour le sélectionner et commander '
            'directement.',
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface
                    .withValues(alpha: 0.85)),
          ),
        ),
      ]),
    );
  }
}

// ─── Toolbar (bouton Filtres + mode sélection) ─────────────────────────────

class _Toolbar extends StatelessWidget {
  final String?     activeCategory;
  final VoidCallback onOpenFilters;
  final bool         selectMode;
  final int          selectedCount;
  final VoidCallback onToggleSelect;
  const _Toolbar({
    required this.activeCategory,
    required this.onOpenFilters,
    required this.selectMode,
    required this.selectedCount,
    required this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(children: [
        // Bouton Filtres
        OutlinedButton.icon(
          onPressed: onOpenFilters,
          icon: Icon(Icons.tune_rounded,
              size: 16, color: theme.colorScheme.primary),
          label: Text(
            activeCategory == null
                ? 'Filtrer'
                : 'Filtre : $activeCategory',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary),
          ),
          style: OutlinedButton.styleFrom(
            side: BorderSide(
                color: activeCategory != null
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline.withValues(alpha: 0.5)),
            backgroundColor: activeCategory != null
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            visualDensity: VisualDensity.compact,
          ),
        ),
        const Spacer(),
        // Toggle mode sélection
        TextButton.icon(
          onPressed: onToggleSelect,
          icon: Icon(
              selectMode
                  ? Icons.close_rounded
                  : Icons.checklist_rounded,
              size: 16,
              color: selectMode
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary),
          label: Text(
            selectMode
                ? (selectedCount == 0
                    ? 'Annuler'
                    : '$selectedCount sélectionné${selectedCount > 1 ? 's' : ''}')
                : 'Sélectionner',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selectMode
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary),
          ),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            visualDensity: VisualDensity.compact,
          ),
        ),
      ]),
    );
  }
}

// ─── Filters bottom sheet ──────────────────────────────────────────────────

class _FiltersResult {
  final String? category;
  const _FiltersResult({this.category});
}

class _FiltersSheet extends StatefulWidget {
  final List<String> categories;
  final String?      currentCategory;
  const _FiltersSheet({
    required this.categories,
    required this.currentCategory,
  });

  @override
  State<_FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends State<_FiltersSheet> {
  String? _category;

  @override
  void initState() {
    super.initState();
    _category = widget.currentCategory;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l     = context.l10n;
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize:     0.3,
      maxChildSize:     0.9,
      expand: false,
      builder: (_, sc) => Column(children: [
        Container(
          margin: const EdgeInsets.only(top: 10),
          width: 36, height: 4,
          decoration: BoxDecoration(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          child: Row(children: [
            Expanded(
              child: Text('Filtrer le catalogue',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurface)),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 36, height: 36,
                alignment: Alignment.center,
                child: Icon(Icons.close_rounded,
                    size: 22,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
              ),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            controller: sc,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              const SizedBox(height: 6),
              Text('Catégorie',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.6))),
              const SizedBox(height: 6),
              RadioListTile<String?>(
                value:      null,
                groupValue: _category,
                onChanged:  (v) => setState(() => _category = v),
                title:      Text(l.catalogueCategoryAll),
                dense:      true,
                contentPadding: EdgeInsets.zero,
              ),
              for (final c in widget.categories)
                RadioListTile<String?>(
                  value:      c,
                  groupValue: _category,
                  onChanged:  (v) => setState(() => _category = v),
                  title:      Text(c,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  dense:      true,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context)
                      .pop(const _FiltersResult(category: null)),
                  child: const Text('Réinitialiser'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context)
                      .pop(_FiltersResult(category: _category)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  child: const Text('Appliquer',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ─── Sheet "Passer commande" (formulaire client) ──────────────────────────

class _PlaceOrderSheet extends StatefulWidget {
  final String shopId;
  final String shopName;
  final List<_CatalogueItem> items;
  const _PlaceOrderSheet({
    required this.shopId,
    required this.shopName,
    required this.items,
  });

  @override
  State<_PlaceOrderSheet> createState() => _PlaceOrderSheetState();
}

class _PlaceOrderSheetState extends State<_PlaceOrderSheet> {
  final _formKey      = GlobalKey<FormState>();
  final _nameCtrl     = TextEditingController();
  final _phoneCtrl    = TextEditingController();
  final _cityCtrl     = TextEditingController();
  final _districtCtrl = TextEditingController();
  String  _phoneFull  = '';
  bool    _phoneValid = false;
  // Date de livraison souhaitée (optionnelle). Sélectionnée via les
  // pickers Material natifs — pattern identique à `delivery_details_sheet`.
  DateTime? _deliveryDate;
  bool _submitting = false;
  String? _error;

  Future<void> _pickDeliveryDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _deliveryDate ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      locale: const Locale('fr', 'FR'),
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_deliveryDate
          ?? DateTime(picked.year, picked.month, picked.day, 14)),
    );
    if (!mounted) return;
    setState(() => _deliveryDate = DateTime(
        picked.year, picked.month, picked.day,
        time?.hour ?? 14, time?.minute ?? 0));
  }

  String _formatDeliveryDate(DateTime d) {
    const days = ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'];
    const months = ['jan', 'fév', 'mar', 'avr', 'mai', 'juin',
                    'juil', 'août', 'sep', 'oct', 'nov', 'déc'];
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]} · $h:$m';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _cityCtrl.dispose();
    _districtCtrl.dispose();
    super.dispose();
  }

  double get _total =>
      widget.items.fold<double>(0, (s, it) => s + it.price);

  // Validateurs réutilisés du formulaire client de l'app (clients_page.dart).
  String? _validateName(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Le nom est requis';
    if (s.length < 2) return 'Minimum 2 caractères';
    if (s.length > 80) return 'Maximum 80 caractères';
    if (!RegExp(r"^[a-zA-ZÀ-ÿ\s\-\']+$").hasMatch(s)) {
      return 'Lettres et espaces uniquement';
    }
    return null;
  }

  String? _validateCity(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'La ville est requise';
    if (s.length < 2) return 'Minimum 2 caractères';
    return null;
  }

  String? _validateDistrict(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Le quartier est requis';
    if (s.length < 2) return 'Minimum 2 caractères';
    return null;
  }

  Future<void> _submit() async {
    final formOk = _formKey.currentState?.validate() ?? false;
    if (!formOk) {
      setState(() => _error = 'Vérifiez les champs en rouge.');
      return;
    }
    if (!_phoneValid) {
      setState(() => _error = 'Numéro de téléphone invalide.');
      return;
    }
    setState(() { _submitting = true; _error = null; });
    try {
      final db = Supabase.instance.client;
      final itemsJson = widget.items.map((it) => {
        'product_id':  it.productId,
        'variant_id':  it.variantId,
        'name':        it.name,
        'sku':         it.sku,
        'quantity':    1,
        'unit_price':  it.price,
      }).toList();
      final city     = _cityCtrl.text.trim();
      final district = _districtCtrl.text.trim();
      // Signature hotfix_048 : on passe city/district séparés + date de
      // livraison optionnelle. La RPC fait l'upsert client et stocke
      // `scheduled_at` pour que la commande apparaisse dans la liste
      // marchand comme une commande normale (avec bouton "modifier").
      final orderId = await db.rpc('place_public_order', params: {
        'p_shop_id':         widget.shopId,
        'p_items':           itemsJson,
        'p_client_name':     _nameCtrl.text.trim(),
        'p_client_phone':    _phoneFull.isNotEmpty ? _phoneFull : _phoneCtrl.text.trim(),
        'p_client_city':     city.isEmpty ? null : city,
        'p_client_district': district.isEmpty ? null : district,
        'p_notes':           null,
        'p_scheduled_at':    _deliveryDate?.toUtc().toIso8601String(),
      });
      debugPrint('[Catalogue] commande créée : $orderId');
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      debugPrint('[Catalogue] place_public_order error: $e');
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Erreur lors de l\'envoi : ${e.toString()}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets),
        child: DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize:     0.5,
          maxChildSize:     0.95,
          expand: false,
          builder: (_, sc) => Column(children: [
            // Drag handle + header
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.shopping_bag_outlined,
                      size: 18, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Passer commande',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: theme.colorScheme.onSurface)),
                      Text(widget.shopName.isEmpty
                              ? 'Boutique en ligne'
                              : 'Vers ${widget.shopName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.6))),
                    ],
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: Container(
                    width: 36, height: 36,
                    alignment: Alignment.center,
                    child: Icon(Icons.close_rounded,
                        size: 22,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.7)),
                  ),
                ),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: sc,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  // Récap items
                  Text('Votre commande (${widget.items.length} produit${widget.items.length > 1 ? 's' : ''})',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6))),
                  const SizedBox(height: 8),
                  for (final it in widget.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        Expanded(
                          child: Text(it.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12)),
                        ),
                        const SizedBox(width: 10),
                        Text('${it.price.toStringAsFixed(0)} XAF',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.primary)),
                      ]),
                    ),
                  const Divider(height: 20),
                  Row(children: [
                    const Expanded(
                      child: Text('Total estimé',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700)),
                    ),
                    Text('${_total.toStringAsFixed(0)} XAF',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.primary)),
                  ]),
                  const SizedBox(height: 18),
                  // Form
                  Text('Vos coordonnées',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6))),
                  const SizedBox(height: 8),
                  Form(
                    key: _formKey,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const AppFieldLabel('Nom complet', required: true),
                        AppField(
                          controller: _nameCtrl,
                          hint: 'Ex : Jean Mballa',
                          prefixIcon: Icons.person_outline_rounded,
                          validator: _validateName,
                        ),
                        const SizedBox(height: 10),
                        PhoneField(
                          controller: _phoneCtrl,
                          label: 'Téléphone',
                          required: true,
                          onChanged: (full, valid) {
                            _phoneFull = full;
                            _phoneValid = valid;
                          },
                        ),
                        const SizedBox(height: 10),
                        AutocompleteTextField(
                          controller: _cityCtrl,
                          label: 'Ville',
                          hint: 'Ex : Yaoundé',
                          prefixIcon: Icons.location_city_outlined,
                          required: true,
                          suggestions: const [
                            'Douala', 'Yaoundé', 'Bafoussam', 'Bamenda',
                            'Garoua', 'Maroua', 'Ngaoundéré', 'Bertoua',
                            'Ebolowa', 'Kribi', 'Limbé', 'Buea',
                          ],
                          validator: _validateCity,
                        ),
                        const SizedBox(height: 10),
                        AutocompleteTextField(
                          controller: _districtCtrl,
                          label: 'Quartier',
                          hint: 'Ex : Bastos',
                          prefixIcon: Icons.maps_home_work_outlined,
                          required: true,
                          suggestions: const [],
                          validator: _validateDistrict,
                        ),
                        const SizedBox(height: 14),
                        // Date de livraison souhaitée (optionnelle).
                        Text('Date de livraison souhaitée',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.6))),
                        const SizedBox(height: 6),
                        InkWell(
                          onTap: _pickDeliveryDate,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF9FAFB),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: _deliveryDate != null
                                      ? theme.colorScheme.primary
                                          .withValues(alpha: 0.5)
                                      : const Color(0xFFE5E7EB)),
                            ),
                            child: Row(children: [
                              Icon(Icons.event_rounded,
                                  size: 16,
                                  color: _deliveryDate != null
                                      ? theme.colorScheme.primary
                                      : const Color(0xFFAAAAAA)),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _deliveryDate != null
                                      ? _formatDeliveryDate(_deliveryDate!)
                                      : 'Choisir une date (optionnel)',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: _deliveryDate != null
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: _deliveryDate != null
                                          ? const Color(0xFF1A1D2E)
                                          : const Color(0xFFBBBBBB)),
                                ),
                              ),
                              if (_deliveryDate != null)
                                InkWell(
                                  onTap: () => setState(
                                      () => _deliveryDate = null),
                                  borderRadius: BorderRadius.circular(12),
                                  child: const Padding(
                                    padding: EdgeInsets.all(2),
                                    child: Icon(Icons.close_rounded,
                                        size: 16,
                                        color: Color(0xFF9CA3AF)),
                                  ),
                                ),
                            ]),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      Icon(Icons.error_outline,
                          size: 14, color: theme.colorScheme.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_error!,
                            style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.error)),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submitting ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Confirmer la commande',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}


class _Empty extends StatelessWidget {
  final bool isFiltered;
  final bool hasIdsFilter;
  const _Empty({this.isFiltered = false, this.hasIdsFilter = false});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    String message;
    if (hasIdsFilter) {
      message = 'Les produits partagés ne sont plus disponibles publiquement.\n'
          'Contactez la boutique pour plus d\'informations.';
    } else if (isFiltered) {
      message = 'Aucun produit dans cette catégorie.\n'
          'Essayez de réinitialiser les filtres.';
    } else {
      message = l.catalogueEmpty;
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined,
                size: 48,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.7))),
          ],
        ),
      ),
    );
  }
}

// ─── Bandeau "Commander la sélection" (FAB-like) ───────────────────────────

class _BatchOrderBar extends StatelessWidget {
  final int          count;
  final int          availableCount;
  final Uri          waOrderUri;
  final VoidCallback onPlaceOrder;
  const _BatchOrderBar({
    required this.count,
    required this.availableCount,
    required this.waOrderUri,
    required this.onPlaceOrder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.15)),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Icon(Icons.shopping_cart_outlined,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    '$count produit${count > 1 ? 's' : ''} sélectionné${count > 1 ? 's' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface)),
              ),
            ]),
            // Avertissement : certains items sélectionnés sont en rupture
            // et seront automatiquement exclus de la commande.
            if (availableCount < count) ...[
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.warning_amber_rounded,
                    size: 13, color: theme.semantic.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      '${count - availableCount} en rupture exclu${count - availableCount > 1 ? 's' : ''} — '
                      '$availableCount sera${availableCount > 1 ? 'ont' : ''} envoyé${availableCount > 1 ? 's' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          color: theme.semantic.warning)),
                ),
              ]),
            ],
            const SizedBox(height: 10),
            // Bouton primaire : passer commande dans l'app (formulaire +
            // RPC vers Supabase + notif marchand). Plein largeur.
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: availableCount == 0 ? null : onPlaceOrder,
                icon: const Icon(Icons.shopping_bag_outlined, size: 18),
                label: Text(
                    availableCount == 0
                        ? 'Aucun produit disponible'
                        : 'Passer commande',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // Bouton secondaire : ouvrir WhatsApp directement avec la liste
            // (alternative pour discuter, pas de commande créée).
            SizedBox(
              width: double.infinity,
              child: Link(
                uri:    waOrderUri,
                target: LinkTarget.blank,
                builder: (ctx, followLink) => TextButton.icon(
                  onPressed: followLink,
                  icon: Icon(Icons.chat_outlined,
                      size: 16, color: theme.colorScheme.primary),
                  label: Text('Discuter via WhatsApp à la place',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
