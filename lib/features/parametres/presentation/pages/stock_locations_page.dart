import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';
import '../../../../shared/widgets/blocked_delete_dialog.dart';
import '../../../../core/widgets/danger_confirm_dialog.dart';
import '../widgets/location_form_sheet.dart';

/// Gestion des emplacements de stockage du propriétaire :
/// - Boutiques (type=shop, lecture seule, auto-créées)
/// - Magasins (type=warehouse, CRUD complet)
/// - Dépôts partenaires (type=partner, CRUD complet)
class StockLocationsPage extends ConsumerStatefulWidget {
  final String shopId;
  const StockLocationsPage({super.key, required this.shopId});

  @override
  ConsumerState<StockLocationsPage> createState() => _StockLocationsPageState();
}

class _StockLocationsPageState extends ConsumerState<StockLocationsPage> {
  List<StockLocation> _locations = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    // Sync silencieuse depuis Supabase en arrière-plan
    AppDatabase.syncStockLocations().then((_) {
      if (mounted) _load();
    });
  }

  void _load() {
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    if (userId.isEmpty) {
      setState(() { _locations = []; _loading = false; });
      return;
    }
    setState(() {
      _locations = AppDatabase.getStockLocationsForOwner(userId);
      _loading = false;
    });
  }

  void _openContents(StockLocation loc) {
    context.push('/shop/${widget.shopId}/parametres/locations/${loc.id}');
  }

  Future<void> _openForm({StockLocation? existing, StockLocationType? defaultType}) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => LocationFormSheet(
        existing: existing,
        defaultType: defaultType ?? StockLocationType.warehouse,
      ),
    );
    if (result == true) {
      _load();
      if (mounted) {
        AppSnack.success(context, existing != null
            ? 'Emplacement mis à jour'
            : 'Emplacement créé');
      }
    }
  }

  Future<void> _confirmDelete(StockLocation loc) async {
    // Règle métier : bloquer si l'emplacement contient encore du stock
    // OU s'il est impliqué dans un transfert (pour préserver l'historique).
    final levels = AppDatabase.getStockLevelsForLocation(loc.id);
    final stockUnits = levels.fold<int>(0, (s, l) =>
        s + l.stockAvailable + l.stockBlocked);
    final transfers = AppDatabase.getTransfersForLocation(loc.id);

    if (stockUnits > 0 || transfers.isNotEmpty) {
      final reason = stockUnits > 0
          ? 'Cet emplacement contient encore $stockUnits unités. '
            'Transfère-les vers un autre emplacement avant de supprimer.'
          : 'Cet emplacement est impliqué dans ${transfers.length} '
            'transfert${transfers.length > 1 ? 's' : ''} '
            '(historique à préserver).';
      final choice = await showBlockedDeleteDialog(
        context,
        itemLabel: loc.name,
        reason: reason,
        archiveDescription:
            'L\'emplacement sera désactivé : il n\'apparaîtra plus dans '
            'les sélecteurs mais le stock et les transferts restent intacts.',
      );
      if (choice == BlockedDeleteChoice.archive) {
        await AppDatabase.saveStockLocation(loc.copyWith(isActive: false));
        _load();
        if (mounted) AppSnack.success(context, 'Emplacement archivé');
      }
      return;
    }

    final ok = await DangerConfirmDialog.show(
      context: context,
      title: 'Supprimer l\'emplacement de stock',
      description: 'Cet emplacement ne contient aucun stock ni historique de '
          'transferts. La suppression est définitive.',
      consequences: const [
        'L\'emplacement disparaît des sélecteurs et des statistiques.',
        'Le nom pourra être réutilisé pour un nouvel emplacement.',
      ],
      confirmText: loc.name,
      onConfirmed: () {},
    );
    if (ok != true || !mounted) return;
    await AppDatabase.deleteStockLocation(loc.id);
    _load();
    if (mounted) AppSnack.success(context, 'Emplacement supprimé');
  }

  @override
  Widget build(BuildContext context) {
    // Filet défensif : on ne liste les locations type=shop que si la
    // boutique parente existe encore en cache local. Ça évite les "boutiques
    // fantômes" si une suppression Supabase n'a pas pu purger sa location
    // (offline, RLS, etc.).
    final shops = _locations
        .where((l) => l.type == StockLocationType.shop)
        .where((l) => l.shopId != null
                   && LocalStorageService.getShop(l.shopId!) != null)
        .toList();
    final warehouses = _locations.where((l) => l.type == StockLocationType.warehouse).toList();
    final partners   = _locations.where((l) => l.type == StockLocationType.partner).toList();

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Emplacements de stock',
      isRootPage: false,
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 20),
          tooltip: 'Rafraîchir',
          onPressed: () async {
            await AppDatabase.syncStockLocations();
            _load();
          },
        ),
      ],
      body: Column(children: [
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await AppDatabase.syncStockLocations();
                _load();
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _Hint(),
                  const SizedBox(height: 16),
                  _Section(
                    title: 'Boutiques',
                    icon: Icons.storefront_rounded,
                    color: AppColors.primary,
                    subtitle: 'Créées automatiquement pour chaque boutique '
                        '— non modifiables ici',
                    locations: shops,
                    onOpen: _openContents,
                    onEdit: null,
                    onDelete: null,
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: 'Magasins',
                    icon: Icons.warehouse_rounded,
                    color: AppColors.info,
                    subtitle: 'Entrepôts centraux qui peuvent approvisionner '
                        'plusieurs boutiques',
                    locations: warehouses,
                    onOpen: _openContents,
                    onEdit: (l) => _openForm(existing: l),
                    onDelete: _confirmDelete,
                    onCreate: () => _openForm(
                        defaultType: StockLocationType.warehouse),
                    createLabel: 'Nouveau magasin',
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: 'Dépôts partenaires',
                    icon: Icons.local_shipping_rounded,
                    color: AppColors.warning,
                    subtitle: 'Sociétés de livraison ou partenaires qui '
                        'stockent quelques pièces pour accélérer les livraisons',
                    locations: partners,
                    onOpen: _openContents,
                    onEdit: (l) => _openForm(existing: l),
                    onDelete: _confirmDelete,
                    onCreate: () => _openForm(
                        defaultType: StockLocationType.partner),
                    createLabel: 'Nouveau dépôt partenaire',
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            )),
      ]),
    );
  }
}

// ─── Bandeau d'info en tête ──────────────────────────────────────────────────
class _Hint extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.primary.withOpacity(0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.primary.withOpacity(0.20)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.info_outline_rounded,
          size: 16, color: AppColors.primary),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          'Les emplacements te permettent de savoir où est physiquement ton '
          'stock : boutique, magasin central, ou dépôt partenaire. '
          'Le transfert entre emplacements arrivera dans une prochaine étape.',
          style: TextStyle(
              fontSize: 11,
              height: 1.35,
              color: AppColors.primary.withOpacity(0.9)),
        ),
      ),
    ]),
  );
}

// ─── Section d'un type ───────────────────────────────────────────────────────
class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final String subtitle;
  final List<StockLocation> locations;
  /// Ouverture (clic simple) — vers la page de contenu.
  final void Function(StockLocation)? onOpen;
  /// Édition (menu) — null = location non éditable (ex : shop).
  final void Function(StockLocation)? onEdit;
  /// Suppression (menu) — null = non supprimable.
  final void Function(StockLocation)? onDelete;
  final VoidCallback? onCreate;
  final String? createLabel;

  const _Section({
    required this.title,
    required this.icon,
    required this.color,
    required this.subtitle,
    required this.locations,
    this.onOpen,
    this.onEdit,
    this.onDelete,
    this.onCreate,
    this.createLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: color.withOpacity(0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 14, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A))),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 11,
                          color: Color(0xFF6B7280))),
                ],
              ),
            ),
            if (locations.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('${locations.length}',
                    style: TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w700, color: color)),
              ),
          ]),
          const SizedBox(height: 12),
          if (locations.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                  onCreate != null
                      ? 'Aucun $title pour le moment.'
                      : 'Aucun $title.',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF9CA3AF))),
            )
          else
            ...locations.map((l) => _LocationTile(
                  location: l,
                  color: color,
                  onTap: onOpen != null ? () => onOpen!(l) : null,
                  onEdit: onEdit != null ? () => onEdit!(l) : null,
                  onDelete: onDelete != null ? () => onDelete!(l) : null,
                )),
          if (onCreate != null) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: onCreate,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: color.withOpacity(0.3),
                      style: BorderStyle.solid,
                      width: 1),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_rounded, size: 14, color: color),
                    const SizedBox(width: 6),
                    Text(createLabel ?? 'Ajouter',
                        style: TextStyle(fontSize: 12,
                            fontWeight: FontWeight.w600, color: color)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Tuile d'un emplacement ──────────────────────────────────────────────────
class _LocationTile extends StatelessWidget {
  final StockLocation location;
  final Color color;
  /// Clic simple sur la tuile → ouverture du contenu.
  final VoidCallback? onTap;
  /// Édition via menu (three dots).
  final VoidCallback? onEdit;
  /// Suppression via menu (three dots).
  final VoidCallback? onDelete;

  const _LocationTile({
    required this.location,
    required this.color,
    this.onTap,
    this.onEdit,
    this.onDelete,
  });

  int _itemsCount() {
    // Seul le stock disponible compte pour la carte. En Phase 1, available
    // et physical sont copiés à l'identique depuis la variante, donc les
    // additionner donnait le double de la valeur réelle.
    final levels = AppDatabase.getStockLevelsForLocation(location.id);
    return levels.fold<int>(0, (s, l) => s + l.stockAvailable);
  }

  @override
  Widget build(BuildContext context) {
    final count = _itemsCount();
    final subtitle = [
      if ((location.address ?? '').isNotEmpty) location.address,
      if ((location.phone ?? '').isNotEmpty) location.phone,
    ].where((e) => e != null && e.isNotEmpty).join(' · ');

    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(location.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0F172A))),
                ),
                if (!location.isActive) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('Inactif',
                        style: TextStyle(fontSize: 9,
                            color: Color(0xFFEF4444),
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ]),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11,
                        color: Color(0xFF9CA3AF))),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('$count',
                style: TextStyle(fontSize: 14,
                    fontWeight: FontWeight.w800, color: color)),
            const Text('unités',
                style: TextStyle(fontSize: 9, color: Color(0xFF9CA3AF))),
          ],
        ),
        if (onEdit != null || onDelete != null) ...[
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded,
                size: 16, color: Color(0xFF9CA3AF)),
            padding: EdgeInsets.zero,
            onSelected: (v) {
              if (v == 'edit') onEdit?.call();
              if (v == 'delete') onDelete?.call();
            },
            itemBuilder: (_) => [
              if (onEdit != null)
                const PopupMenuItem(
                    value: 'edit',
                    child: Row(children: [
                      Icon(Icons.edit_outlined, size: 14),
                      SizedBox(width: 8), Text('Modifier'),
                    ])),
              if (onDelete != null)
                const PopupMenuItem(
                    value: 'delete',
                    child: Row(children: [
                      Icon(Icons.delete_outline_rounded, size: 14,
                          color: Color(0xFFEF4444)),
                      SizedBox(width: 8),
                      Text('Supprimer',
                          style: TextStyle(color: Color(0xFFEF4444))),
                    ])),
            ],
          ),
        ],
      ]),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: onTap != null
          ? InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: tile,
            )
          : tile,
    );
  }
}
