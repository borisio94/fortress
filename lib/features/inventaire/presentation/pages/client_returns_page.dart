import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../domain/entities/product.dart';
import '../../../../core/services/stock_service.dart';
import '../../../caisse/domain/entities/sale.dart';
import '../../../caisse/data/repositories/sale_local_datasource.dart';

class ClientReturnsPage extends StatefulWidget {
  final String shopId;
  const ClientReturnsPage({super.key, required this.shopId});
  @override State<ClientReturnsPage> createState() => _ClientReturnsPageState();
}

class _ClientReturnsPageState extends State<ClientReturnsPage> {
  List<Sale> _completedOrders = [];

  @override void initState() { super.initState(); _load(); }

  void _load() => setState(() {
    _completedOrders = SaleLocalDatasource().getOrders(widget.shopId)
        .where((o) => o.status == SaleStatus.completed)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  });

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Retours clients',
      isRootPage: false,
      body: _completedOrders.isEmpty
          ? const EmptyStateWidget(
              icon: Icons.assignment_return_outlined,
              title: 'Aucune vente complétée',
              subtitle: 'Les ventes complétées apparaîtront ici pour gérer les retours')
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _completedOrders.length,
              itemBuilder: (_, i) => _OrderReturnCard(
                order: _completedOrders[i],
                shopId: widget.shopId,
                onReturn: () => _showReturnSheet(_completedOrders[i]),
              ),
            ),
    );
  }

  void _showReturnSheet(Sale order) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ReturnSheet(
        order: order,
        shopId: widget.shopId,
        onDone: _load,
      ),
    );
  }
}

// ═══ Card commande (pour sélectionner laquelle retourner) ═══════════════════

class _OrderReturnCard extends StatelessWidget {
  final Sale order;
  final String shopId;
  final VoidCallback onReturn;
  const _OrderReturnCard({required this.order, required this.shopId,
    required this.onReturn});

  @override
  Widget build(BuildContext context) {
    final itemNames = order.items.take(3)
        .map((i) => i.productName).join(', ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider)),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(9)),
          child: Icon(Icons.receipt_long_rounded, size: 18,
              color: AppColors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(order.clientName ?? 'Client anonyme',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          Text(itemNames, style: const TextStyle(fontSize: 11,
              color: AppColors.textHint),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('${_fmtDate(order.createdAt)} · ${CurrencyFormatter.format(order.total)}',
              style: const TextStyle(fontSize: 10, color: Color(0xFFD1D5DB))),
        ])),
        GestureDetector(
          onTap: onReturn,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: AppColors.warning.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8)),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.assignment_return_rounded, size: 14,
                  color: AppColors.warning),
              SizedBox(width: 4),
              Text('Retour', style: TextStyle(fontSize: 11,
                  fontWeight: FontWeight.w600, color: AppColors.warning)),
            ]),
          ),
        ),
      ]),
    );
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
}

// ═══ Sheet de retour ════════════════════════════════════════════════════════

class _ReturnSheet extends StatefulWidget {
  final Sale order;
  final String shopId;
  final VoidCallback onDone;
  const _ReturnSheet({required this.order, required this.shopId,
    required this.onDone});
  @override State<_ReturnSheet> createState() => _ReturnSheetState();
}

class _ReturnSheetState extends State<_ReturnSheet> {
  late List<_ReturnItem> _items;

  @override
  void initState() {
    super.initState();
    _items = widget.order.items.map((i) => _ReturnItem(
      saleItem: i,
      qtyCtrl: TextEditingController(text: '0'),
    )).toList();
  }

  @override
  void dispose() {
    for (final i in _items) i.qtyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75, minChildSize: 0.5, maxChildSize: 0.95,
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
                decoration: BoxDecoration(
                    color: AppColors.warning.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(9)),
                child: const Icon(Icons.assignment_return_rounded,
                    size: 17, color: AppColors.warning)),
            const SizedBox(width: 10),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Retour client',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(widget.order.clientName ?? 'Commande ${widget.order.id}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ])),
          ]),
        ),
        const Divider(height: 24),
        // Liste des articles
        Expanded(child: ListView.builder(
          controller: sc,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _items.length,
          itemBuilder: (_, i) {
            final ri = _items[i];
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.divider)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(ri.saleItem.productName, style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                    Text('Acheté : ×${ri.saleItem.quantity} · ${CurrencyFormatter.format(ri.saleItem.subtotal)}',
                        style: const TextStyle(fontSize: 11, color: AppColors.textHint)),
                  ])),
                  SizedBox(width: 80, child: TextField(
                    controller: ri.qtyCtrl,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    decoration: InputDecoration(
                      labelText: 'Retour',
                      labelStyle: const TextStyle(fontSize: 10),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      filled: true, fillColor: const Color(0xFFFFF7ED),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Color(0xFFFDE68A))),
                    ),
                  )),
                ]),
                const SizedBox(height: 8),
                // État du retour
                Row(children: [
                  const Text('État : ', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  const SizedBox(width: 4),
                  _StatePill('Bon état', ri.isGoodCondition,
                      AppColors.secondary,
                      () => setState(() => ri.isGoodCondition = true)),
                  const SizedBox(width: 6),
                  _StatePill('Défectueux', !ri.isGoodCondition,
                      AppColors.error,
                      () => setState(() => ri.isGoodCondition = false)),
                ]),
              ]),
            );
          },
        )),
        // Bouton valider
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: SizedBox(width: double.infinity, height: 46,
            child: ElevatedButton.icon(
              onPressed: _hasReturns ? _processReturn : null,
              icon: const Icon(Icons.check_circle_rounded, size: 18),
              label: const Text('Valider le retour'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.warning,
                foregroundColor: Colors.white, elevation: 0,
                disabledBackgroundColor: AppColors.divider,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            ),
          ),
        ),
      ]),
    );
  }

  bool get _hasReturns => _items.any((i) => (int.tryParse(i.qtyCtrl.text) ?? 0) > 0);

  void _processReturn() async {
    final ds = SaleLocalDatasource();
    final products = AppDatabase.getProductsForShop(widget.shopId);

    for (final ri in _items) {
      final qty = int.tryParse(ri.qtyCtrl.text) ?? 0;
      if (qty <= 0) continue;

      // Résoudre productId et variantId
      String pid = ri.saleItem.productId;
      String vid = pid;
      for (final p in products) {
        for (final v in p.variants) {
          if (v.id == pid) { pid = p.id ?? pid; vid = v.id ?? pid; break; }
        }
      }

      if (ri.isGoodCondition) {
        await StockService.returnGood(
          shopId: widget.shopId, productId: pid, variantId: vid,
          quantity: qty, orderId: widget.order.id);
      } else {
        await StockService.returnDefective(
          shopId: widget.shopId, productId: pid, variantId: vid,
          quantity: qty, productName: ri.saleItem.productName,
          orderId: widget.order.id);
      }
    }

    ds.updateOrderStatus(widget.order.id!, SaleStatus.refunded);
    AppDatabase.notifyOrderChange(widget.shopId);

    Navigator.of(context).pop();
    widget.onDone();
    if (mounted) AppSnack.success(context, 'Retour enregistré — stock mis à jour');
  }
}

class _ReturnItem {
  final dynamic saleItem; // SaleItem
  final TextEditingController qtyCtrl;
  bool isGoodCondition = true;
  _ReturnItem({required this.saleItem, required this.qtyCtrl});
}

class _StatePill extends StatelessWidget {
  final String label;
  final bool active;
  final Color color;
  final VoidCallback onTap;
  const _StatePill(this.label, this.active, this.color, this.onTap);
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active ? color.withOpacity(0.1) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: active ? color : AppColors.divider,
            width: active ? 1.5 : 1)),
      child: Text(label, style: TextStyle(fontSize: 11,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          color: active ? color : AppColors.textHint)),
    ),
  );
}
