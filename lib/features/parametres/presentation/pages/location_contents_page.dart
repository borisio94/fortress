import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../widgets/transfer_form_sheet.dart';
import '../../../../shared/widgets/form_sheet.dart';

/// Résout le nom d'un emplacement depuis Hive (pour le titre du wrapper).
String stockLocationNameOf(String id) {
  try {
    final raw = HiveBoxes.stockLocationsBox.get(id);
    if (raw == null) return 'Emplacement';
    return StockLocation.fromMap(Map<String, dynamic>.from(raw)).name;
  } catch (_) { return 'Emplacement'; }
}

/// Vue (SANS chrome de navigation) listant les produits/variantes présents à
/// un emplacement. Embarquée comme onglet « Stock déposé » du hub partenaire
/// ([PartnerHubDetailPage]) ou enveloppée par [LocationContentsPage] pour un
/// accès plein écran depuis la page Emplacements.
///
/// Comportement :
/// - Si la location est type `shop` → on lit directement les variantes des
///   produits de la boutique (source de vérité Phase 1).
/// - Si la location est type `warehouse` ou `partner` → on lit les StockLevel
///   de cette location et on joint avec les Product/Variant correspondants.
class LocationContentsView extends ConsumerStatefulWidget {
  final String shopId;       // shop courante (pour le transfert)
  final String locationId;   // location à afficher
  const LocationContentsView({
    super.key, required this.shopId, required this.locationId,
  });

  @override
  ConsumerState<LocationContentsView> createState() =>
      _LocationContentsViewState();
}

class _LocationContentsViewState extends ConsumerState<LocationContentsView> {
  StockLocation? _location;
  List<_LocationItem> _items = [];
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    final allLocs = AppDatabase.getStockLocationsForOwner(userId);
    final loc = allLocs.where((l) => l.id == widget.locationId).firstOrNull;
    if (loc == null) {
      setState(() { _location = null; _items = []; _loading = false; });
      return;
    }

    final items = <_LocationItem>[];
    if (loc.type == StockLocationType.shop && loc.shopId != null) {
      // Source = table normalisée `stock_levels` (cohérent avec
      // InventairePage._stockAtLocations). Les transferts et ajustements
      // n'écrivent QUE dans stock_levels — lire directement `variant.stock*`
      // ferait remonter une valeur figée et incohérente avec l'inventaire
      // global. Fallback variant.* si stock_levels pas encore peuplé pour
      // cette variante (produit fraîchement créé, jamais transféré).
      final products = AppDatabase.getProductsForShop(loc.shopId!);
      for (final p in products) {
        for (final v in p.variants) {
          final vid = v.id;
          final lvl = vid != null
              ? AppDatabase.getStockLevel(vid, loc.id)
              : null;
          items.add(_LocationItem(
            productName: p.name,
            variantName: v.name,
            sku:         v.sku,
            available:   lvl?.stockAvailable ?? v.stockAvailable,
            physical:    lvl?.stockPhysical  ?? v.stockPhysical,
            blocked:     lvl?.stockBlocked   ?? v.stockBlocked,
            ordered:     lvl?.stockOrdered   ?? v.stockOrdered,
            imageUrl:    v.imageUrl ?? p.imageUrl,
          ));
        }
      }
    } else {
      // Warehouse/partner : lire les StockLevel et joindre les variantes.
      final levels = AppDatabase.getStockLevelsForLocation(loc.id);
      // Indexer tous les produits du owner (toutes boutiques confondues)
      // pour résoudre variantId → Product/Variant en un seul balayage.
      final productsById = <String, _VariantRef>{};
      final allShops = LocalStorageService.getShopsForUser(userId);
      for (final s in allShops) {
        for (final p in AppDatabase.getProductsForShop(s.id)) {
          for (final v in p.variants) {
            if (v.id != null) {
              productsById[v.id!] = _VariantRef(p, v);
            }
          }
        }
      }
      for (final lvl in levels) {
        final ref = productsById[lvl.variantId];
        if (ref == null) continue;
        items.add(_LocationItem(
          productName: ref.product.name,
          variantName: ref.variant.name,
          sku:         ref.variant.sku,
          available:   lvl.stockAvailable,
          physical:    lvl.stockPhysical,
          blocked:     lvl.stockBlocked,
          ordered:     lvl.stockOrdered,
          imageUrl:    ref.variant.imageUrl ?? ref.product.imageUrl,
        ));
      }
    }

    items.sort((a, b) =>
        a.productName.toLowerCase().compareTo(b.productName.toLowerCase()));

    setState(() {
      _location = loc;
      _items = items;
      _loading = false;
    });
  }

  List<_LocationItem> get _filtered {
    if (_query.trim().isEmpty) return _items;
    final q = _query.trim().toLowerCase();
    return _items.where((i) =>
      i.productName.toLowerCase().contains(q) ||
      i.variantName.toLowerCase().contains(q) ||
      (i.sku ?? '').toLowerCase().contains(q)
    ).toList();
  }

  int get _totalUnits =>
      _items.fold(0, (s, i) => s + i.available);

  Future<void> _openTransfer() async {
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    if (userId.isEmpty) return;
    final done = await showFormSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => TransferFormSheet(
        ownerId: userId,
        presetSourceId: widget.locationId,
      ),
    );
    if (done == true) {
      _load();
      if (mounted) AppSnack.success(context, 'Transfert exécuté');
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      floatingActionButton: _location != null && _totalUnits > 0
          ? FloatingActionButton.extended(
              onPressed: _openTransfer,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: Text('Transférer',
                  style: AppTextStyles.bodyBold.copyWith(
                      color: Colors.white)),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _location == null
              ? const _MissingLocation()
              : Column(children: [
                  _Header(
                      location: _location!,
                      items: _items.length,
                      totalUnits: _totalUnits),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: TextField(
                      onChanged: (v) => setState(() => _query = v),
                      style: AppTextStyles.body,
                      decoration: InputDecoration(
                        hintText: 'Rechercher un produit, SKU…',
                        hintStyle: AppTextStyles.bodySm.copyWith(
                            color: const Color(0xFFBBBBBB)),
                        prefixIcon: Icon(Icons.search_rounded, size: 18,
                            color: AppColors.textHint),
                        filled: true, fillColor: AppColors.inputFill,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 11),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide:
                                BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: list.isEmpty
                        ? EmptyStateWidget(
                            icon: Icons.inventory_2_outlined,
                            title: _query.isEmpty
                                ? 'Cet emplacement est vide'
                                : 'Aucun résultat',
                            subtitle: _query.isEmpty
                                ? 'Aucun produit n\'est actuellement stocké '
                                  'ici. Utilisez un transfert pour y amener '
                                  'du stock (bientôt disponible).'
                                : 'Essayez un autre terme de recherche.',
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            itemCount: list.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 6),
                            itemBuilder: (_, i) =>
                                _ItemTile(item: list[i]),
                          ),
                  ),
                ]),
    );
  }
}

/// Page plein écran autonome (route `/parametres/locations/:locationId`) —
/// enveloppe [LocationContentsView] dans le chrome de navigation boutique.
/// Utilisée pour les emplacements boutique/magasin depuis la page
/// Emplacements ; les dépôts partenaires passent désormais par le hub
/// partenaire ([PartnerHubDetailPage], onglet Stock).
class LocationContentsPage extends StatelessWidget {
  final String shopId;
  final String locationId;
  const LocationContentsPage({
    super.key, required this.shopId, required this.locationId,
  });
  @override
  Widget build(BuildContext context) => AppScaffold(
        shopId: shopId,
        title: stockLocationNameOf(locationId),
        isRootPage: false,
        body: LocationContentsView(shopId: shopId, locationId: locationId),
      );
}

class _VariantRef {
  final Product product;
  final ProductVariant variant;
  _VariantRef(this.product, this.variant);
}

class _LocationItem {
  final String productName;
  final String variantName;
  final String? sku;
  final int available, physical, blocked, ordered;
  final String? imageUrl;
  const _LocationItem({
    required this.productName, required this.variantName, this.sku,
    required this.available, required this.physical,
    required this.blocked, required this.ordered, this.imageUrl,
  });
}

// ─── En-tête (type + stats) ──────────────────────────────────────────────────
class _Header extends StatelessWidget {
  final StockLocation location;
  final int items;
  final int totalUnits;
  const _Header({
    required this.location,
    required this.items, required this.totalUnits,
  });

  Color get _color => switch (location.type) {
    StockLocationType.shop      => AppColors.primary,
    StockLocationType.warehouse => AppColors.info,
    StockLocationType.partner   => AppColors.warning,
  };

  IconData get _icon => switch (location.type) {
    StockLocationType.shop      => Icons.storefront_rounded,
    StockLocationType.warehouse => Icons.warehouse_rounded,
    StockLocationType.partner   => Icons.local_shipping_rounded,
  };

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _color.withValues(alpha:0.08),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _color.withValues(alpha:0.22)),
    ),
    child: Row(children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _color.withValues(alpha:0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(_icon, size: 20, color: _color),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(location.name,
                style: AppTextStyles.label),
            const SizedBox(height: 2),
            Text(location.type.labelFr,
                style: AppTextStyles.caption.copyWith(color: _color)),
          ],
        ),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('$totalUnits',
              style: AppTextStyles.title.copyWith(color: _color)),
          Text('$items référence${items > 1 ? 's' : ''}',
              style: AppTextStyles.micro.copyWith(
                  color: AppColors.textHint)),
        ],
      ),
    ]),
  );
}

class _ItemTile extends StatelessWidget {
  final _LocationItem item;
  const _ItemTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final lowStock = item.available > 0 && item.available <= 2;
    final empty    = item.available == 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: Row(children: [
        ProductImageCard(
          imageUrl: item.imageUrl,
          width: 36, height: 36,
          borderRadius: BorderRadius.circular(8),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.productName,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyBold),
              const SizedBox(height: 2),
              Text([
                item.variantName,
                if ((item.sku ?? '').isNotEmpty) 'SKU ${item.sku}',
              ].join(' · '),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption.copyWith(
                      color: AppColors.textHint)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${item.available}',
                style: AppTextStyles.label.copyWith(
                    color: empty
                        ? const Color(0xFFEF4444)
                        : lowStock
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFF10B981))),
            Text('dispo',
                style: AppTextStyles.micro.copyWith(
                    color: AppColors.textHint)),
          ],
        ),
        if (item.blocked > 0) ...[
          const SizedBox(width: 8),
          Column(children: [
            Text('${item.blocked}',
                style: AppTextStyles.bodySmBold.copyWith(
                    color: const Color(0xFFEF4444))),
            Text('bloq', style: AppTextStyles.micro.copyWith(
                color: AppColors.textHint)),
          ]),
        ],
      ]),
    );
  }
}

class _MissingLocation extends StatelessWidget {
  const _MissingLocation();
  @override
  Widget build(BuildContext context) =>
      const EmptyStateWidget(
        icon: Icons.location_off_outlined,
        title: 'Emplacement introuvable',
        subtitle: 'Il a peut-être été supprimé.',
      );
}
