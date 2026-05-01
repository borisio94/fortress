import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/database/app_database.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/widgets/danger_confirm_dialog.dart';
import '../../domain/entities/reception.dart';
import '../../domain/entities/stock_movement.dart';

/// Page de gestion des bons de réception.
/// Mode A : lié à une commande fournisseur (purchaseOrderId)
/// Mode B : réception directe (produits sélectionnés manuellement)
class ReceptionPage extends StatefulWidget {
  final String shopId;
  const ReceptionPage({super.key, required this.shopId});
  @override State<ReceptionPage> createState() => _ReceptionPageState();
}

class _ReceptionPageState extends State<ReceptionPage> {
  List<Reception> _receptions = [];

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
    if (table == 'receptions' || table == 'products') _load();
  }

  void _load() => setState(() {
    _receptions = HiveBoxes.receptionsBox.values
        .map((m) => Reception.fromMap(Map<String, dynamic>.from(m)))
        .where((r) => r.shopId == widget.shopId)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  });

  @override
  Widget build(BuildContext context) {
    final drafts    = _receptions.where((r) => r.status == ReceptionStatus.draft).toList();
    final validated = _receptions.where((r) => r.status == ReceptionStatus.validated).toList();

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Bons de réception',
      isRootPage: false,
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Material(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _showCreateSheet(context),
              child: const SizedBox(width: 36, height: 36,
                  child: Center(child: Icon(Icons.add_rounded,
                      color: Colors.white, size: 22))),
            ),
          ),
        ),
      ],
      body: _receptions.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.inbox_outlined, size: 48, color: Color(0xFFD1D5DB)),
              const SizedBox(height: 12),
              const Text('Aucun bon de réception',
                  style: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF))),
              const SizedBox(height: 16),
              Center(
                child: TextButton.icon(
                  onPressed: () => _showCreateSheet(context),
                  icon: const Icon(Icons.add_rounded, size: 16,
                      color: Colors.white),
                  label: const Text('Créer un bon',
                      style: TextStyle(fontSize: 12, color: Colors.white)),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                  ),
                ),
              ),
            ]))
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (drafts.isNotEmpty) ...[
                _SectionLabel('Brouillons (${drafts.length})'),
                ...drafts.map((r) => _ReceptionCard(
                    reception: r, shopId: widget.shopId,
                    onValidate: () => _validate(r),
                    onDelete: () => _delete(r))),
                const SizedBox(height: 16),
              ],
              if (validated.isNotEmpty) ...[
                _SectionLabel('Validées (${validated.length})'),
                ...validated.map((r) => _ReceptionCard(
                    reception: r, shopId: widget.shopId)),
              ],
            ]),
    );
  }

  // ── Créer un bon de réception directe ──────────────────────────────────
  void _showCreateSheet(BuildContext context) {
    final products = AppDatabase.getProductsForShop(widget.shopId);
    final selected = <String, int>{}; // productId → quantité attendue
    final user = LocalStorageService.getCurrentUser();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => DraggableScrollableSheet(
          initialChildSize: 0.75, minChildSize: 0.5, maxChildSize: 0.9,
          expand: false,
          builder: (_, sc) => Column(children: [
            // Poignée
            Center(child: Container(width: 36, height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 14),
                decoration: BoxDecoration(color: const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(2)))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Container(width: 34, height: 34,
                    decoration: BoxDecoration(
                        color: AppColors.primarySurface,
                        borderRadius: BorderRadius.circular(9)),
                    child: Icon(Icons.local_shipping_rounded,
                        size: 17, color: AppColors.primary)),
                const SizedBox(width: 10),
                const Expanded(child: Text('Nouvelle réception',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              ]),
            ),
            const Divider(height: 24),
            // Liste produits
            Expanded(child: ListView.builder(
              controller: sc,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: products.length,
              itemBuilder: (_, i) {
                final p = products[i];
                final qty = selected[p.id] ?? 0;
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: qty > 0 ? AppColors.primarySurface : const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: qty > 0
                        ? AppColors.primary.withOpacity(0.3) : const Color(0xFFE5E7EB))),
                  child: Row(children: [
                    Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.name, style: const TextStyle(fontSize: 13,
                          fontWeight: FontWeight.w600), maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      Text('Stock actuel : ${p.totalStock}',
                          style: const TextStyle(fontSize: 10,
                              color: Color(0xFF9CA3AF))),
                    ])),
                    // Contrôles quantité
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        onPressed: qty > 0 ? () => setSt(() {
                          if (qty <= 1) { selected.remove(p.id); }
                          else { selected[p.id!] = qty - 1; }
                        }) : null,
                        icon: const Icon(Icons.remove_circle_outline, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        color: AppColors.primary),
                      SizedBox(width: 28, child: Center(
                          child: Text('$qty', style: const TextStyle(fontSize: 14,
                              fontWeight: FontWeight.w700)))),
                      IconButton(
                        onPressed: () => setSt(() => selected[p.id!] = qty + 1),
                        icon: const Icon(Icons.add_circle_outline, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        color: AppColors.primary),
                    ]),
                  ]),
                );
              },
            )),
            // Bouton créer
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: SizedBox(width: double.infinity, height: 46,
                child: ElevatedButton.icon(
                  onPressed: selected.isEmpty ? null : () {
                    final items = selected.entries.map((e) {
                      final p = products.firstWhere((p) => p.id == e.key);
                      return ReceptionItem(
                        id: 'ri_${DateTime.now().microsecondsSinceEpoch}_${e.key}',
                        productId: p.id,
                        productName: p.name,
                        expectedQty: e.value,
                      );
                    }).toList();
                    final reception = Reception(
                      id: 'rec_${DateTime.now().millisecondsSinceEpoch}',
                      shopId: widget.shopId,
                      items: items,
                      createdBy: user?.name,
                      createdAt: DateTime.now(),
                    );
                    HiveBoxes.receptionsBox.put(reception.id, reception.toMap());
                    AppDatabase.notifyProductChange(widget.shopId);
                    Navigator.of(ctx).pop();
                    _load();
                    AppSnack.success(context, 'Bon de réception créé');
                  },
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text('Créer (${selected.length} produit${selected.length > 1 ? 's' : ''})'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary, foregroundColor: Colors.white,
                    elevation: 0, disabledBackgroundColor: const Color(0xFFE5E7EB),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ── Valider une réception ──────────────────────────────────────────────
  void _validate(Reception reception) {
    // Ouvrir un dialog pour saisir les quantités reçues + incidents
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ValidateSheet(
        reception: reception,
        shopId: widget.shopId,
        onValidated: _load,
      ),
    );
  }

  Future<void> _delete(Reception r) async {
    final ref = r.id.length >= 6 ? r.id.substring(r.id.length - 6) : r.id;
    final confirmed = await DangerConfirmDialog.show(
      context: context,
      title: 'Supprimer le bon de réception',
      description: 'Cette action est irréversible.',
      consequences: const [
        'Le bon disparaît définitivement de la liste.',
        'Les mouvements de stock déjà appliqués ne sont PAS annulés.',
      ],
      confirmText: ref,
      onConfirmed: () {},
    );
    if (confirmed != true || !mounted) return;
    await HiveBoxes.receptionsBox.delete(r.id);
    _load();
    if (mounted) AppSnack.success(context, 'Bon supprimé');
  }
}

// ═══ Sheet de validation ════════════════════════════════════════════════════

class _ValidateSheet extends StatefulWidget {
  final Reception reception;
  final String shopId;
  final VoidCallback onValidated;
  const _ValidateSheet({required this.reception, required this.shopId,
    required this.onValidated});
  @override State<_ValidateSheet> createState() => _ValidateSheetState();
}

class _ValidateSheetState extends State<_ValidateSheet> {
  late List<_ItemState> _items;

  @override
  void initState() {
    super.initState();
    _items = widget.reception.items.map((i) => _ItemState(
      item: i,
      receivedCtrl: TextEditingController(text: '${i.expectedQty}'),
    )).toList();
  }

  @override
  void dispose() {
    for (final i in _items) { i.receivedCtrl.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8, minChildSize: 0.5, maxChildSize: 0.95,
      expand: false,
      builder: (_, sc) => Column(children: [
        Center(child: Container(width: 36, height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 14),
            decoration: BoxDecoration(color: const Color(0xFFE5E7EB),
                borderRadius: BorderRadius.circular(2)))),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Icon(Icons.fact_check_rounded, size: 20, color: Color(0xFF3B82F6)),
            SizedBox(width: 10),
            Text('Validation de la réception',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ]),
        ),
        const Divider(height: 24),
        Expanded(child: ListView.builder(
          controller: sc,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _items.length,
          itemBuilder: (_, i) {
            final s = _items[i];
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE5E7EB))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.item.productName, style: const TextStyle(fontSize: 13,
                    fontWeight: FontWeight.w700)),
                Text('Attendu : ${s.item.expectedQty}',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
                const SizedBox(height: 8),
                _QtyField(label: 'Quantité reçue', ctrl: s.receivedCtrl,
                    color: const Color(0xFF10B981)),
                const SizedBox(height: 4),
                const Text(
                    'Les défauts se déclarent après en incident sur le produit.',
                    style: TextStyle(fontSize: 10, color: Color(0xFF9CA3AF))),
              ]),
            );
          },
        )),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: SizedBox(width: double.infinity, height: 46,
            child: ElevatedButton.icon(
              onPressed: _onValidate,
              icon: const Icon(Icons.check_circle_rounded, size: 18),
              label: const Text('Valider la réception'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            ),
          ),
        ),
      ]),
    );
  }

  void _onValidate() {
    final now = DateTime.now();
    final user = LocalStorageService.getCurrentUser();
    final updatedItems = <ReceptionItem>[];

    for (final s in _items) {
      final received = int.tryParse(s.receivedCtrl.text) ?? 0;

      updatedItems.add(ReceptionItem(
        id: s.item.id, productId: s.item.productId,
        variantId: s.item.variantId, productName: s.item.productName,
        expectedQty: s.item.expectedQty, receivedQty: received,
        status: ReceptionItemStatus.available,
      ));

      // Toute la quantité reçue entre en stock disponible.
      // Les défauts éventuels se déclarent ensuite en incident.
      if (received > 0 && s.item.productId != null) {
        _addStock(s.item.productId!, s.item.variantId, received, now, user?.name);
      }
    }

    // Mettre à jour la réception
    final validated = Reception(
      id: widget.reception.id, shopId: widget.reception.shopId,
      purchaseOrderId: widget.reception.purchaseOrderId,
      supplierId: widget.reception.supplierId,
      status: ReceptionStatus.validated,
      items: updatedItems,
      notes: widget.reception.notes,
      createdBy: widget.reception.createdBy,
      createdAt: widget.reception.createdAt,
    );
    HiveBoxes.receptionsBox.put(validated.id, validated.toMap());
    AppDatabase.notifyProductChange(widget.shopId);

    Navigator.of(context).pop();
    widget.onValidated();
    if (mounted) AppSnack.success(context, 'Réception validée — stock mis à jour');
  }

  void _addStock(String productId, String? variantId, int qty,
      DateTime now, String? userName) {
    // Mouvement de stock
    final mvt = StockMovement(
      id: 'sm_${now.microsecondsSinceEpoch}_$productId',
      shopId: widget.shopId, productId: productId,
      variantId: variantId, type: StockMovementType.entry,
      quantity: qty, createdBy: userName, createdAt: now,
    );
    HiveBoxes.stockMovementsBox.put(mvt.id, mvt.toMap());

    // Mettre à jour le stock du produit
    final products = AppDatabase.getProductsForShop(widget.shopId);
    for (final p in products) {
      if (variantId != null) {
        for (int i = 0; i < p.variants.length; i++) {
          if (p.variants[i].id == variantId || p.variants[i].id == productId) {
            final variants = List.of(p.variants);
            variants[i] = variants[i].copyWith(stockQty: variants[i].stockQty + qty);
            AppDatabase.saveProduct(p.copyWith(variants: variants));
            return;
          }
        }
      }
      if (p.id == productId) {
        if (p.variants.isNotEmpty) {
          // Ajouter au stock de la première variante principale
          final variants = List.of(p.variants);
          final mainIdx = variants.indexWhere((v) => v.isMain);
          final idx = mainIdx >= 0 ? mainIdx : 0;
          variants[idx] = variants[idx].copyWith(stockQty: variants[idx].stockQty + qty);
          AppDatabase.saveProduct(p.copyWith(variants: variants));
        } else {
          AppDatabase.saveProduct(p.copyWith(stockQty: p.stockQty + qty));
        }
        return;
      }
    }
  }

}

class _ItemState {
  final ReceptionItem item;
  final TextEditingController receivedCtrl;
  _ItemState({required this.item, required this.receivedCtrl});
}

// ═══ Widgets réutilisables ══════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: const TextStyle(fontSize: 12,
        fontWeight: FontWeight.w700, letterSpacing: 0.3, color: Color(0xFF6B7280))),
  );
}

class _ReceptionCard extends StatelessWidget {
  final Reception reception;
  final String shopId;
  final VoidCallback? onValidate;
  final VoidCallback? onDelete;
  const _ReceptionCard({required this.reception, required this.shopId,
    this.onValidate, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final isDraft = reception.status == ReceptionStatus.draft;
    final statusColor = isDraft ? const Color(0xFFF59E0B) : const Color(0xFF10B981);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03),
            blurRadius: 4, offset: const Offset(0, 2))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: statusColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6)),
            child: Text(reception.status.label,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: statusColor)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(
              '${reception.items.length} produit${reception.items.length > 1 ? 's' : ''}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
          Text(_fmtDate(reception.createdAt),
              style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF))),
        ]),
        if (reception.status == ReceptionStatus.validated) ...[
          const SizedBox(height: 6),
          Row(children: [
            _Chip('Reçu: ${reception.totalReceived}', const Color(0xFF10B981)),
            if (reception.totalDamaged > 0) ...[
              const SizedBox(width: 6),
              _Chip('Endommagé: ${reception.totalDamaged}', const Color(0xFFF59E0B)),
            ],
            if (reception.totalDefective > 0) ...[
              const SizedBox(width: 6),
              _Chip('Défectueux: ${reception.totalDefective}', const Color(0xFFEF4444)),
            ],
          ]),
        ],
        if (isDraft) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Supprimer'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                side: BorderSide(color: AppColors.error.withOpacity(0.3)),
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            )),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton.icon(
              onPressed: onValidate,
              icon: const Icon(Icons.fact_check_rounded, size: 16),
              label: const Text('Valider'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white,
                elevation: 0, padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            )),
          ]),
        ],
      ]),
    );
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _Chip extends StatelessWidget {
  final String label; final Color color;
  const _Chip(this.label, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
        color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: TextStyle(fontSize: 10,
        fontWeight: FontWeight.w600, color: color)),
  );
}

class _QtyField extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final Color color;
  const _QtyField({required this.label, required this.ctrl, required this.color});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
      const SizedBox(height: 4),
      TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          filled: true, fillColor: color.withOpacity(0.06),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: color.withOpacity(0.3))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: color.withOpacity(0.3))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: color, width: 1.5)),
        ),
      ),
    ],
  );
}
