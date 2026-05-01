import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/app_product_image.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';
import '../../../../features/inventaire/domain/entities/stock_transfer.dart';

/// Liste chronologique de tous les transferts du propriétaire.
/// Filtrable par emplacement (source ou destination).
class TransfersListPage extends ConsumerStatefulWidget {
  final String shopId;
  const TransfersListPage({super.key, required this.shopId});

  @override
  ConsumerState<TransfersListPage> createState() => _TransfersListPageState();
}

class _TransfersListPageState extends ConsumerState<TransfersListPage> {
  List<StockTransfer> _transfers = [];
  List<StockLocation> _locations = [];
  // variantId → URL image (variante en priorité, sinon produit) pour
  // afficher la vignette dans les lignes du détail d'un transfert.
  Map<String, String?> _imagesByVariantId = {};
  String? _filterLocationId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    // Sync silencieuse depuis Supabase
    AppDatabase.syncStockTransfers().then((_) {
      if (mounted) _load();
    });
  }

  void _load() {
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    final imgs = <String, String?>{};
    for (final s in LocalStorageService.getShopsForUser(userId)) {
      for (final p in AppDatabase.getProductsForShop(s.id)) {
        for (final v in p.variants) {
          if (v.id != null) {
            imgs[v.id!] = v.imageUrl ?? p.imageUrl;
          }
        }
      }
    }
    setState(() {
      _locations = AppDatabase.getStockLocationsForOwner(userId);
      _transfers = AppDatabase.getStockTransfersForOwner(userId);
      _imagesByVariantId = imgs;
      _loading   = false;
    });
  }

  List<StockTransfer> get _filtered {
    if (_filterLocationId == null) return _transfers;
    return _transfers.where((t) =>
        t.fromLocationId == _filterLocationId ||
        t.toLocationId   == _filterLocationId).toList();
  }

  StockLocation? _locById(String id) =>
      _locations.where((l) => l.id == id).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Historique des transferts',
      isRootPage: false,
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 20),
          tooltip: 'Rafraîchir',
          onPressed: () async {
            await AppDatabase.syncStockTransfers();
            _load();
          },
        ),
      ],
      body: Column(children: [
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (_locations.length > 1) _FilterBar(
                locations: _locations,
                value: _filterLocationId,
                onChanged: (id) => setState(() => _filterLocationId = id),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 6),
                child: Row(children: [
                  Text('${list.length} transfert${list.length > 1 ? 's' : ''}',
                      style: const TextStyle(fontSize: 11,
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w500)),
                  const Spacer(),
                  if (_filterLocationId != null)
                    TextButton.icon(
                      onPressed: () =>
                          setState(() => _filterLocationId = null),
                      icon: const Icon(Icons.clear_rounded, size: 14),
                      label: const Text('Réinitialiser',
                          style: TextStyle(fontSize: 11)),
                    ),
                ]),
              ),
              Expanded(
                child: list.isEmpty
                    ? const EmptyStateWidget(
                        icon: Icons.swap_horiz_rounded,
                        title: 'Aucun transfert',
                        subtitle: 'Les transferts que tu effectues entre '
                            'tes emplacements apparaîtront ici.',
                      )
                    : RefreshIndicator(
                        onRefresh: () async {
                          await AppDatabase.syncStockTransfers();
                          _load();
                        },
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                          itemCount: list.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (_, i) => _TransferCard(
                            transfer: list[i],
                            fromLoc: _locById(list[i].fromLocationId),
                            toLoc:   _locById(list[i].toLocationId),
                            onTap: () => _openDetails(list[i]),
                          ),
                        ),
                      ),
              ),
            ])),
      ]),
    );
  }

  void _openDetails(StockTransfer t) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _TransferDetailsSheet(
        transfer: t,
        fromLoc: _locById(t.fromLocationId),
        toLoc:   _locById(t.toLocationId),
        imagesByVariantId: _imagesByVariantId,
      ),
    );
  }
}

// ─── Barre de filtre par emplacement ────────────────────────────────────────
class _FilterBar extends StatelessWidget {
  final List<StockLocation> locations;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _FilterBar({
    required this.locations,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Row(children: [
      const Text('Emplacement :',
          style: TextStyle(fontSize: 11,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500)),
      const SizedBox(width: 8),
      Expanded(
        child: DropdownButtonFormField<String?>(
          value: value,
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Tous', style: TextStyle(fontSize: 13)),
            ),
            ...locations.map((l) => DropdownMenuItem<String?>(
                  value: l.id,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(_iconFor(l.type), size: 13,
                        color: _colorFor(l.type)),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(l.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ]),
                )),
          ],
          onChanged: onChanged,
          isDense: true,
          isExpanded: true,
          decoration: InputDecoration(
            filled: true, fillColor: const Color(0xFFF9FAFB),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 8),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.divider)),
          ),
        ),
      ),
    ]),
  );

  static IconData _iconFor(StockLocationType t) => switch (t) {
    StockLocationType.shop      => Icons.storefront_rounded,
    StockLocationType.warehouse => Icons.warehouse_rounded,
    StockLocationType.partner   => Icons.local_shipping_rounded,
  };

  static Color _colorFor(StockLocationType t) => switch (t) {
    StockLocationType.shop      => AppColors.primary,
    StockLocationType.warehouse => AppColors.info,
    StockLocationType.partner   => AppColors.warning,
  };
}

// ─── Carte de transfert (item de la liste) ──────────────────────────────────
class _TransferCard extends StatelessWidget {
  final StockTransfer transfer;
  final StockLocation? fromLoc;
  final StockLocation? toLoc;
  final VoidCallback onTap;
  const _TransferCard({
    required this.transfer,
    required this.fromLoc,
    required this.toLoc,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('d MMM yyyy · HH:mm', 'fr_FR')
        .format(transfer.createdAt);
    final lines   = transfer.lines.length;
    final units   = transfer.totalQuantity;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _LocationChip(loc: fromLoc),
              const SizedBox(width: 6),
              Icon(Icons.arrow_forward_rounded,
                  size: 14, color: AppColors.primary),
              const SizedBox(width: 6),
              Flexible(child: _LocationChip(loc: toLoc)),
              const SizedBox(width: 8),
              _StatusChip(status: transfer.status),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.schedule_rounded,
                  size: 11, color: AppColors.textHint),
              const SizedBox(width: 4),
              Text(dateStr,
                  style: const TextStyle(fontSize: 10,
                      color: AppColors.textHint)),
              const Spacer(),
              Text('$lines ligne${lines > 1 ? 's' : ''} · $units unités',
                  style: const TextStyle(fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
            ]),
            if ((transfer.notes ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(transfer.notes!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: AppColors.textSecondary)),
            ],
          ],
        ),
      ),
    );
  }
}

class _LocationChip extends StatelessWidget {
  final StockLocation? loc;
  const _LocationChip({required this.loc});

  @override
  Widget build(BuildContext context) {
    if (loc == null) {
      return const Text('Emplacement supprimé',
          style: TextStyle(fontSize: 11, color: AppColors.textHint,
              fontStyle: FontStyle.italic));
    }
    final color = switch (loc!.type) {
      StockLocationType.shop      => AppColors.primary,
      StockLocationType.warehouse => AppColors.info,
      StockLocationType.partner   => AppColors.warning,
    };
    final icon = switch (loc!.type) {
      StockLocationType.shop      => Icons.storefront_rounded,
      StockLocationType.warehouse => Icons.warehouse_rounded,
      StockLocationType.partner   => Icons.local_shipping_rounded,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: Text(loc!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11,
                  fontWeight: FontWeight.w600, color: color)),
        ),
      ]),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final StockTransferStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      StockTransferStatus.draft     =>
          (AppColors.textHint, 'Brouillon'),
      StockTransferStatus.shipped   =>
          (AppColors.info, 'Expédié'),
      StockTransferStatus.received  =>
          (AppColors.secondary, 'Reçu'),
      StockTransferStatus.cancelled =>
          (AppColors.error, 'Annulé'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 9,
              fontWeight: FontWeight.w700, color: color)),
    );
  }
}

// ─── Sheet de détails d'un transfert ────────────────────────────────────────
class _TransferDetailsSheet extends StatelessWidget {
  final StockTransfer transfer;
  final StockLocation? fromLoc;
  final StockLocation? toLoc;
  final Map<String, String?> imagesByVariantId;
  const _TransferDetailsSheet({
    required this.transfer,
    required this.fromLoc,
    required this.toLoc,
    required this.imagesByVariantId,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('d MMMM yyyy à HH:mm', 'fr_FR')
        .format(transfer.createdAt);
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.80),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: Container(width: 36, height: 4,
                decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 12),
            Row(children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.swap_horiz_rounded,
                    size: 16, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Détails du transfert',
                    style: TextStyle(fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
              ),
              _StatusChip(status: transfer.status),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _LocationChip(loc: fromLoc)),
              const SizedBox(width: 6),
              Icon(Icons.arrow_forward_rounded,
                  size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              Expanded(child: _LocationChip(loc: toLoc)),
            ]),
            const SizedBox(height: 10),
            Text(dateStr,
                style: const TextStyle(fontSize: 11,
                    color: AppColors.textHint)),
            if ((transfer.createdBy ?? '').isNotEmpty)
              Text('Par ${transfer.createdBy}',
                  style: const TextStyle(fontSize: 11,
                      color: AppColors.textHint)),
            if ((transfer.notes ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF9FAFB),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Text(transfer.notes!,
                    style: const TextStyle(fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: AppColors.textSecondary)),
              ),
            ],
            const SizedBox(height: 16),
            const Text('Lignes',
                style: TextStyle(fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: transfer.lines.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Color(0xFFF0F0F0)),
                itemBuilder: (_, i) {
                  final l = transfer.lines[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      AppProductImage(
                        imageUrl: imagesByVariantId[l.variantId],
                        width: 36, height: 36,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.productName ?? '—',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary)),
                            if ((l.variantName ?? '').isNotEmpty)
                              Text(l.variantName!,
                                  style: const TextStyle(fontSize: 11,
                                      color: AppColors.textHint)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.10),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('× ${l.quantity}',
                            style: TextStyle(fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primary)),
                      ),
                    ]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
