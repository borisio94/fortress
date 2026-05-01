import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../core/widgets/danger_confirm_dialog.dart';
import '../../domain/entities/purchase_order.dart';
import '../../domain/entities/supplier.dart';
import '../../domain/entities/product.dart';
import '../../domain/entities/reception.dart';

class PurchaseOrdersPage extends StatefulWidget {
  final String shopId;
  const PurchaseOrdersPage({super.key, required this.shopId});
  @override State<PurchaseOrdersPage> createState() => _PurchaseOrdersPageState();
}

class _PurchaseOrdersPageState extends State<PurchaseOrdersPage> {
  List<PurchaseOrder> _orders = [];
  List<Supplier> _suppliers = [];

  @override
  void initState() {
    super.initState();
    _load();
    AppDatabase.addListener(_onDbChanged);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDbChanged);
    super.dispose();
  }

  void _onDbChanged(String table, String shopId) {
    if (!mounted) return;
    if (shopId != widget.shopId && shopId != '_all') return;
    if (table == 'purchase_orders' || table == 'suppliers') _load();
  }

  void _load() => setState(() {
    _orders = HiveBoxes.purchaseOrdersBox.values
        .map((m) => PurchaseOrder.fromMap(Map<String, dynamic>.from(m)))
        .where((o) => o.shopId == widget.shopId)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _suppliers = HiveBoxes.suppliersBox.values
        .map((m) => Supplier.fromMap(Map<String, dynamic>.from(m)))
        .where((s) => s.shopId == widget.shopId && s.isActive)
        .toList();
  });

  String _supplierName(String? id) =>
      _suppliers.where((s) => s.id == id).firstOrNull?.name ?? '—';

  @override
  Widget build(BuildContext context) {
    return _orders.isEmpty
          ? EmptyStateWidget(
              icon: Icons.shopping_bag_outlined,
              title: 'Aucune commande',
              subtitle: 'Créez une commande fournisseur pour approvisionner votre stock',
              ctaLabel: 'Créer une commande',
              onCta: () => _showCreateSheet(context),
            )
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(children: [
                  // Accès fournisseurs
                  GestureDetector(
                    onTap: () => context.push('/shop/${widget.shopId}/inventaire/suppliers'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                          color: Colors.white, borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.divider)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.local_shipping_rounded, size: 15,
                            color: AppColors.primary),
                        const SizedBox(width: 6),
                        Text('Fournisseurs (${_suppliers.length})',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                                color: AppColors.primary)),
                      ]),
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _showCreateSheet(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                          color: AppColors.primary, borderRadius: BorderRadius.circular(8)),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.add_rounded, size: 15, color: Colors.white),
                        SizedBox(width: 6),
                        Text('Nouvelle commande', style: TextStyle(fontSize: 12,
                            fontWeight: FontWeight.w600, color: Colors.white)),
                      ]),
                    ),
                  ),
                ]),
              ),
              Expanded(child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _orders.length,
                itemBuilder: (_, i) => _POCard(
                  order: _orders[i],
                  supplierName: _supplierName(_orders[i].supplierId),
                  onStatusChange: (s) => _updateStatus(_orders[i], s),
                  onReceive: () => _createReception(_orders[i]),
                  onDelete: () => _delete(_orders[i]),
                ),
              )),
            ]);
  }

  void _showCreateSheet(BuildContext context) {
    final products = AppDatabase.getProductsForShop(widget.shopId);
    String? selectedSupplier;
    final items = <String, _NewItem>{}; // productId → qty + price

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => DraggableScrollableSheet(
          initialChildSize: 0.8, minChildSize: 0.5, maxChildSize: 0.95,
          expand: false,
          builder: (_, sc) => Column(children: [
            Center(child: Container(width: 36, height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 14),
                decoration: BoxDecoration(color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2)))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Container(width: 34, height: 34,
                    decoration: BoxDecoration(color: AppColors.primarySurface,
                        borderRadius: BorderRadius.circular(9)),
                    child: Icon(Icons.shopping_bag_rounded,
                        size: 17, color: AppColors.primary)),
                const SizedBox(width: 10),
                const Expanded(child: Text('Nouvelle commande fournisseur',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              ]),
            ),
            const SizedBox(height: 12),
            // Sélection fournisseur
            if (_suppliers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: DropdownButtonFormField<String>(
                  value: selectedSupplier,
                  decoration: InputDecoration(
                    labelText: 'Fournisseur', isDense: true,
                    filled: true, fillColor: const Color(0xFFF9FAFB),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppColors.divider)),
                  ),
                  items: _suppliers.map((s) => DropdownMenuItem(
                      value: s.id, child: Text(s.name,
                          style: const TextStyle(fontSize: 13)))).toList(),
                  onChanged: (v) => setSt(() => selectedSupplier = v),
                ),
              ),
            const Divider(height: 20),
            // Produits
            Expanded(child: ListView.builder(
              controller: sc,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: products.length,
              itemBuilder: (_, i) {
                final p = products[i];
                final item = items[p.id];
                final qty = item?.qty ?? 0;
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: qty > 0 ? AppColors.primarySurface : const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: qty > 0
                        ? AppColors.primary.withOpacity(0.3) : AppColors.divider)),
                  child: Row(children: [
                    Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.name, style: const TextStyle(fontSize: 13,
                          fontWeight: FontWeight.w600), maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      Text('Achat : ${CurrencyFormatter.format(p.priceBuy)} · Stock : ${p.totalStock}',
                          style: const TextStyle(fontSize: 10, color: AppColors.textHint)),
                    ])),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        onPressed: qty > 0 ? () => setSt(() {
                          if (qty <= 1) items.remove(p.id);
                          else items[p.id!] = _NewItem(qty - 1, p.priceBuy);
                        }) : null,
                        icon: const Icon(Icons.remove_circle_outline, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        color: AppColors.primary),
                      SizedBox(width: 28, child: Center(child: Text('$qty',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)))),
                      IconButton(
                        onPressed: () => setSt(() =>
                            items[p.id!] = _NewItem(qty + 1, p.priceBuy)),
                        icon: const Icon(Icons.add_circle_outline, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        color: AppColors.primary),
                    ]),
                  ]),
                );
              },
            )),
            // Total + bouton
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(children: [
                if (items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      const Text('Total estimé',
                          style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                      Text(CurrencyFormatter.format(
                          items.values.fold(0.0, (s, i) => s + i.qty * i.price)),
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800,
                              color: AppColors.primary)),
                    ]),
                  ),
                SizedBox(width: double.infinity, height: 46,
                  child: ElevatedButton.icon(
                    onPressed: items.isEmpty ? null : () {
                      final user = LocalStorageService.getCurrentUser();
                      final now = DateTime.now();
                      final poItems = items.entries.map((e) {
                        final p = products.firstWhere((p) => p.id == e.key);
                        return POItem(
                          id: 'poi_${now.microsecondsSinceEpoch}_${e.key}',
                          productId: p.id, productName: p.name,
                          quantity: e.value.qty, unitPrice: e.value.price,
                        );
                      }).toList();
                      final po = PurchaseOrder(
                        id: 'po_${now.millisecondsSinceEpoch}',
                        shopId: widget.shopId,
                        supplierId: selectedSupplier,
                        items: poItems,
                        createdBy: user?.name,
                        createdAt: now, updatedAt: now,
                      );
                      HiveBoxes.purchaseOrdersBox.put(po.id, po.toMap());
                      Navigator.of(ctx).pop();
                      _load();
                      AppSnack.success(context, 'Commande créée');
                    },
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: Text('Créer (${items.length} produit${items.length > 1 ? 's' : ''})'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary, foregroundColor: Colors.white,
                      elevation: 0, disabledBackgroundColor: AppColors.divider,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  void _updateStatus(PurchaseOrder po, POStatus newStatus) {
    final updated = PurchaseOrder(
      id: po.id, shopId: po.shopId, supplierId: po.supplierId,
      status: newStatus, items: po.items, notes: po.notes,
      expectedAt: po.expectedAt, totalAmount: po.totalAmount,
      createdBy: po.createdBy, createdAt: po.createdAt,
      updatedAt: DateTime.now(),
    );
    HiveBoxes.purchaseOrdersBox.put(updated.id, updated.toMap());
    _load();
  }

  void _createReception(PurchaseOrder po) {
    final now = DateTime.now();
    final user = LocalStorageService.getCurrentUser();
    final reception = Reception(
      id: 'rec_${now.millisecondsSinceEpoch}',
      shopId: widget.shopId,
      purchaseOrderId: po.id,
      supplierId: po.supplierId,
      items: po.items.map((i) => ReceptionItem(
        id: 'ri_${now.microsecondsSinceEpoch}_${i.id}',
        productId: i.productId, variantId: i.variantId,
        productName: i.productName, expectedQty: i.quantity,
      )).toList(),
      createdBy: user?.name, createdAt: now,
    );
    HiveBoxes.receptionsBox.put(reception.id, reception.toMap());
    _updateStatus(po, POStatus.received);
    context.push('/shop/${widget.shopId}/inventaire/receptions');
    AppSnack.success(context, 'Bon de réception créé — validez la réception');
  }

  Future<void> _delete(PurchaseOrder po) async {
    final ref = po.id.length >= 6 ? po.id.substring(po.id.length - 6) : po.id;
    final confirmed = await DangerConfirmDialog.show(
      context: context,
      title: 'Supprimer la commande fournisseur',
      description: 'Cette action est irréversible.',
      consequences: const [
        'La commande disparaît définitivement.',
        'Les bons de réception associés ne pourront plus être rattachés.',
      ],
      confirmText: ref,
      onConfirmed: () {},
    );
    if (confirmed != true || !mounted) return;
    await HiveBoxes.purchaseOrdersBox.delete(po.id);
    _load();
    if (mounted) AppSnack.success(context, 'Commande supprimée');
  }
}

class _NewItem {
  final int qty;
  final double price;
  const _NewItem(this.qty, this.price);
}

// ═══ Card commande ══════════════════════════════════════════════════════════

class _POCard extends StatelessWidget {
  final PurchaseOrder order;
  final String supplierName;
  final void Function(POStatus) onStatusChange;
  final VoidCallback onReceive;
  final VoidCallback onDelete;
  const _POCard({required this.order, required this.supplierName,
    required this.onStatusChange, required this.onReceive,
    required this.onDelete});

  static const _statusColors = {
    POStatus.draft:     AppColors.textHint,
    POStatus.sent:      Color(0xFF3B82F6),
    POStatus.confirmed: Color(0xFF8B5CF6),
    POStatus.inTransit: AppColors.warning,
    POStatus.received:  AppColors.secondary,
    POStatus.cancelled: AppColors.error,
  };

  @override
  Widget build(BuildContext context) {
    final color = _statusColors[order.status] ?? AppColors.textHint;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6)),
            child: Text(order.status.label, style: TextStyle(fontSize: 10,
                fontWeight: FontWeight.w700, color: color)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(supplierName, style: const TextStyle(fontSize: 12,
              fontWeight: FontWeight.w600, color: Color(0xFF374151)),
              overflow: TextOverflow.ellipsis)),
          Text(CurrencyFormatter.format(order.computedTotal),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800,
                  color: AppColors.primary)),
        ]),
        const SizedBox(height: 6),
        Text('${order.items.length} produit${order.items.length > 1 ? 's' : ''} · '
            '${_fmtDate(order.createdAt)}',
            style: const TextStyle(fontSize: 11, color: AppColors.textHint)),
        // Actions
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (order.status == POStatus.draft) ...[
            _SmallBtn('Envoyer', Icons.send_rounded, const Color(0xFF3B82F6),
                () => onStatusChange(POStatus.sent)),
            _SmallBtn('Supprimer', Icons.delete_outline, AppColors.error, onDelete),
          ],
          if (order.status == POStatus.sent)
            _SmallBtn('Confirmer', Icons.check_rounded, const Color(0xFF8B5CF6),
                () => onStatusChange(POStatus.confirmed)),
          if (order.status == POStatus.confirmed)
            _SmallBtn('En transit', Icons.local_shipping_rounded,
                AppColors.warning, () => onStatusChange(POStatus.inTransit)),
          if (order.status.canReceive)
            _SmallBtn('Réceptionner', Icons.inventory_rounded,
                AppColors.secondary, onReceive),
          if (order.status != POStatus.received && order.status != POStatus.cancelled)
            _SmallBtn('Annuler', Icons.close_rounded, AppColors.textHint,
                () => onStatusChange(POStatus.cancelled)),
        ]),
      ]),
    );
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

class _SmallBtn extends StatelessWidget {
  final String label; final IconData icon; final Color color;
  final VoidCallback onTap;
  const _SmallBtn(this.label, this.icon, this.color, this.onTap);
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.25))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10,
            fontWeight: FontWeight.w600, color: color)),
      ]),
    ),
  );
}
