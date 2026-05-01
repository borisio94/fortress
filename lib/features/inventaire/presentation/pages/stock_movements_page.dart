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
import '../../domain/entities/stock_movement.dart';
import '../../domain/entities/product.dart';

/// Page globale des mouvements de stock.
/// Si [productId] est fourni, filtre sur ce produit uniquement.
class StockMovementsPage extends StatefulWidget {
  final String shopId;
  final String? productId;
  final String? productName;
  const StockMovementsPage({super.key, required this.shopId,
    this.productId, this.productName});
  @override State<StockMovementsPage> createState() => _StockMovementsPageState();
}

class _StockMovementsPageState extends State<StockMovementsPage> {
  List<_MovementView> _movements = [];
  String _filter = 'all';

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
    if (table == 'stock_movements' || table == 'products') _load();
  }

  void _load() => setState(() {
    _movements = HiveBoxes.stockMovementsBox.values
        .map((m) => _MovementView.fromMap(
            Map<String, dynamic>.from(m as Map)))
        .where((v) => v.movement.shopId == widget.shopId &&
            (widget.productId == null
                || v.movement.productId == widget.productId))
        .toList()
      ..sort((a, b) => b.movement.createdAt.compareTo(a.movement.createdAt));
  });

  List<_MovementView> get _filtered => _filter == 'all'
      ? _movements
      : _movements.where((v) => v.movement.type.key == _filter).toList();

  @override
  Widget build(BuildContext context) {
    final title = widget.productName != null
        ? 'Mouvements — ${widget.productName}'
        : 'Mouvements de stock';

    return AppScaffold(
      shopId: widget.shopId,
      title: title,
      isRootPage: false,
      body: Column(children: [
        // Résumé
        if (_movements.isNotEmpty)
          _Summary(movements: _movements),

        // Filtres
        if (_movements.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              _FilterChip(label: 'Tous', value: 'all',
                  selected: _filter, onTap: (v) => setState(() => _filter = v)),
              ...[
                ('entry',           'Entrées'),
                ('sale',            'Ventes'),
                ('adjustment',      'Ajustements'),
                ('incident',        'Incidents'),
                ('scrapped',        'Rebuts'),
                ('return_supplier', 'Ret. fournisseur'),
                ('return_client',   'Ret. client'),
              ].map((f) => _FilterChip(label: f.$2, value: f.$1,
                  selected: _filter, onTap: (v) => setState(() => _filter = v))),
            ]),
          ),

        // Bouton ajustement manuel
        if (widget.productId != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(children: [
              const Spacer(),
              GestureDetector(
                onTap: () => _showAdjustment(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                      color: AppColors.primary, borderRadius: BorderRadius.circular(8)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.tune_rounded, size: 15, color: Colors.white),
                    SizedBox(width: 6),
                    Text('Ajustement', style: TextStyle(fontSize: 12,
                        fontWeight: FontWeight.w600, color: Colors.white)),
                  ]),
                ),
              ),
            ]),
          ),

        // Liste
        Expanded(
          child: _filtered.isEmpty
              ? const EmptyStateWidget(
                  icon: Icons.swap_vert_rounded,
                  title: 'Aucun mouvement',
                  subtitle: 'Les mouvements de stock apparaîtront ici')
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _filtered.length,
                  itemBuilder: (_, i) => _MovementCard(view: _filtered[i]),
                ),
        ),
      ]),
    );
  }

  void _showAdjustment(BuildContext context) {
    final qtyCtrl   = TextEditingController();
    final notesCtrl = TextEditingController();
    bool isPositive = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Center(child: Container(width: 36, height: 4,
                  decoration: BoxDecoration(color: AppColors.divider,
                      borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Row(children: [
                Container(width: 34, height: 34,
                    decoration: BoxDecoration(color: AppColors.primarySurface,
                        borderRadius: BorderRadius.circular(9)),
                    child: Icon(Icons.tune_rounded, size: 17,
                        color: AppColors.primary)),
                const SizedBox(width: 10),
                const Text('Ajustement de stock',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 20),
              // Direction
              Row(children: [
                Expanded(child: GestureDetector(
                  onTap: () => setSt(() => isPositive = true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: isPositive ? AppColors.secondary.withOpacity(0.1) : const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isPositive
                          ? AppColors.secondary : AppColors.divider)),
                    child: Column(children: [
                      Icon(Icons.add_circle_rounded, size: 24,
                          color: isPositive ? AppColors.secondary : const Color(0xFFD1D5DB)),
                      const SizedBox(height: 4),
                      Text('Entrée', style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isPositive ? AppColors.secondary : AppColors.textHint)),
                    ]),
                  ),
                )),
                const SizedBox(width: 10),
                Expanded(child: GestureDetector(
                  onTap: () => setSt(() => isPositive = false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: !isPositive ? AppColors.error.withOpacity(0.1) : const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: !isPositive
                          ? AppColors.error : AppColors.divider)),
                    child: Column(children: [
                      Icon(Icons.remove_circle_rounded, size: 24,
                          color: !isPositive ? AppColors.error : const Color(0xFFD1D5DB)),
                      const SizedBox(height: 4),
                      Text('Sortie', style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: !isPositive ? AppColors.error : AppColors.textHint)),
                    ]),
                  ),
                )),
              ]),
              const SizedBox(height: 16),
              TextField(
                controller: qtyCtrl,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                decoration: InputDecoration(
                  hintText: '0', labelText: 'Quantité',
                  filled: true, fillColor: const Color(0xFFF9FAFB),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.divider)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: notesCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Raison de l\'ajustement...',
                  labelText: 'Notes',
                  filled: true, fillColor: const Color(0xFFF9FAFB),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.divider)),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(width: double.infinity, height: 46,
                child: ElevatedButton.icon(
                  onPressed: () {
                    final qty = int.tryParse(qtyCtrl.text) ?? 0;
                    if (qty <= 0) return;
                    final finalQty = isPositive ? qty : -qty;
                    final user = LocalStorageService.getCurrentUser();
                    final now  = DateTime.now();
                    final mvt = StockMovement(
                      id: 'sm_${now.microsecondsSinceEpoch}_adj',
                      shopId: widget.shopId,
                      productId: widget.productId,
                      type: StockMovementType.adjustment,
                      quantity: finalQty,
                      notes: notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
                      createdBy: user?.name,
                      createdAt: now,
                    );
                    HiveBoxes.stockMovementsBox.put(mvt.id, mvt.toMap());
                    // Mettre à jour le stock du produit
                    if (widget.productId != null) {
                      final products = AppDatabase.getProductsForShop(widget.shopId);
                      final p = products.where((p) => p.id == widget.productId).firstOrNull;
                      if (p != null) {
                        if (p.variants.isNotEmpty) {
                          final variants = List.of(p.variants);
                          final idx = variants.indexWhere((v) => v.isMain);
                          final vi = idx >= 0 ? idx : 0;
                          variants[vi] = variants[vi].copyWith(
                              stockQty: (variants[vi].stockQty + finalQty).clamp(0, 999999));
                          AppDatabase.saveProduct(p.copyWith(variants: variants));
                        } else {
                          AppDatabase.saveProduct(p.copyWith(
                              stockQty: (p.stockQty + finalQty).clamp(0, 999999)));
                        }
                      }
                    }
                    Navigator.of(ctx).pop();
                    _load();
                    AppSnack.success(context, 'Ajustement enregistré');
                  },
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Enregistrer'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary, foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ═══ Résumé ═════════════════════════════════════════════════════════════════

class _Summary extends StatelessWidget {
  final List<_MovementView> movements;
  const _Summary({required this.movements});

  @override
  Widget build(BuildContext context) {
    final entries = movements.where((v) => v.movement.quantity > 0)
        .fold(0, (s, v) => s + v.movement.quantity);
    final exits   = movements.where((v) => v.movement.quantity < 0)
        .fold(0, (s, v) => s + v.movement.quantity.abs());
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider)),
      child: Row(children: [
        Expanded(child: Column(children: [
          Text('$entries', style: const TextStyle(fontSize: 16,
              fontWeight: FontWeight.w800, color: AppColors.secondary)),
          const Text('Entrées', style: TextStyle(fontSize: 10, color: AppColors.textHint)),
        ])),
        Container(width: 1, height: 28, color: AppColors.divider),
        Expanded(child: Column(children: [
          Text('$exits', style: const TextStyle(fontSize: 16,
              fontWeight: FontWeight.w800, color: AppColors.error)),
          const Text('Sorties', style: TextStyle(fontSize: 10, color: AppColors.textHint)),
        ])),
        Container(width: 1, height: 28, color: AppColors.divider),
        Expanded(child: Column(children: [
          Text('${movements.length}', style: TextStyle(fontSize: 16,
              fontWeight: FontWeight.w800, color: AppColors.primary)),
          const Text('Total mvts', style: TextStyle(fontSize: 10, color: AppColors.textHint)),
        ])),
      ]),
    );
  }
}

// ═══ Card mouvement ═════════════════════════════════════════════════════════

class _MovementCard extends StatelessWidget {
  final _MovementView view;
  const _MovementCard({required this.view});

  static const _colors = {
    StockMovementType.entry:          AppColors.secondary,
    StockMovementType.sale:           Color(0xFF3B82F6),
    StockMovementType.adjustment:     Color(0xFF8B5CF6),
    StockMovementType.incident:       AppColors.error,
    StockMovementType.repairCost:     AppColors.warning,
    StockMovementType.returnSupplier: Color(0xFFF97316),
    StockMovementType.returnClient:   AppColors.secondary,
    StockMovementType.transfer:       Color(0xFF6366F1),
    StockMovementType.scrapped:       AppColors.error,
  };

  @override
  Widget build(BuildContext context) {
    final m      = view.movement;
    final color  = _colors[m.type] ?? AppColors.textSecondary;
    final isPos  = m.quantity > 0;
    final qtyStr = isPos ? '+${m.quantity}' : '${m.quantity}';
    final subtitle = view.composedSubtitle();
    final hasSub = subtitle.isNotEmpty;
    final actor   = (m.createdBy ?? '').trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF0F0F0))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
              color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
          child: Icon(isPos ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
              size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text(m.type.label, style: TextStyle(fontSize: 12.5,
              fontWeight: FontWeight.w700, color: color)),
          if (hasSub) ...[
            const SizedBox(height: 2),
            Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11,
                    color: AppColors.textSecondary, height: 1.3)),
          ],
          const SizedBox(height: 4),
          Row(children: [
            if (actor.isNotEmpty) ...[
              const Icon(Icons.person_outline_rounded, size: 11,
                  color: AppColors.textHint),
              const SizedBox(width: 3),
              Flexible(child: Text(actor,
                  overflow: TextOverflow.ellipsis, maxLines: 1,
                  style: const TextStyle(fontSize: 10.5,
                      color: AppColors.textHint))),
              const SizedBox(width: 8),
            ],
            const Icon(Icons.access_time_rounded, size: 11,
                color: AppColors.textHint),
            const SizedBox(width: 3),
            Text(_fmtDate(m.createdAt),
                style: const TextStyle(fontSize: 10.5,
                    color: AppColors.textHint)),
          ]),
        ])),
        const SizedBox(width: 8),
        Text(qtyStr, style: TextStyle(fontSize: 16,
            fontWeight: FontWeight.w800,
            color: isPos ? AppColors.secondary : AppColors.error)),
      ]),
    );
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

// ═══ Vue enrichie (entité + map raw pour before/after, status, cause) ══════

class _MovementView {
  final StockMovement movement;
  final Map<String, dynamic> raw; // map Hive originale (avant_avail, etc.)
  const _MovementView({required this.movement, required this.raw});

  factory _MovementView.fromMap(Map<String, dynamic> m) =>
      _MovementView(movement: StockMovement.fromMap(m), raw: m);

  /// Compose une sous-ligne explicative à partir de l'entité et de la map
  /// Hive raw (qui contient before/after_available, status, cause — non
  /// présents dans l'entité).
  String composedSubtitle() {
    final parts = <String>[];
    final notes = movement.notes;
    if (notes != null && notes.trim().isNotEmpty) {
      parts.add(notes.trim());
    }

    // Stock avant → après (depuis raw)
    final bA = raw['before_available'];
    final aA = raw['after_available'];
    if (bA != null && aA != null && bA != aA) {
      parts.add('stock $bA → $aA');
    } else if (raw['before_blocked'] != null
        && raw['after_blocked'] != null
        && raw['before_blocked'] != raw['after_blocked']) {
      parts.add('bloqué ${raw['before_blocked']} → ${raw['after_blocked']}');
    }

    // Status / cause éventuel (incidents)
    final status = raw['status']?.toString();
    if (status != null && status.isNotEmpty) {
      parts.add('statut $status');
    }
    final cause = raw['cause']?.toString();
    if (cause != null && cause.isNotEmpty && cause != notes) {
      parts.add('cause $cause');
    }

    // Référence
    if ((movement.reference ?? '').isNotEmpty) {
      parts.add('réf ${movement.reference}');
    }

    // Coût unitaire
    if (movement.unitCost > 0) {
      parts.add('coût ${movement.unitCost.toStringAsFixed(0)} XAF');
    }

    return parts.join(' · ');
  }
}

// ═══ Filtre chip ════════════════════════════════════════════════════════════

class _FilterChip extends StatelessWidget {
  final String label, value, selected;
  final ValueChanged<String> onTap;
  const _FilterChip({required this.label, required this.value,
    required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final active = value == selected;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () => onTap(value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active ? AppColors.primary : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: active ? AppColors.primary : AppColors.divider)),
          child: Text(label, style: TextStyle(fontSize: 11,
              fontWeight: FontWeight.w600,
              color: active ? Colors.white : AppColors.textSecondary)),
        ),
      ),
    );
  }
}
