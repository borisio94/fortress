import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../core/widgets/danger_confirm_dialog.dart';
import '../../../caisse/domain/entities/sale.dart' show PaymentMethod;
import '../../domain/entities/expense.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PAGE DÉPENSES — vue centralisée de toutes les sorties d'argent de la boutique.
// Deux sources fusionnées :
//   1. Dépenses directes (table/box `expenses`) — CRUD plein.
//   2. Frais des commandes (orders.fees) — entrées "virtuelles", lecture seule,
//      tap renvoie à la caisse pour modification. Pas comptées dans la KPI
//      dashboard `operatingExpenses` (elles sont déjà intégrées au prix de
//      revient via allocation proportionnelle), mais visibles ici pour la
//      traçabilité.
// ═════════════════════════════════════════════════════════════════════════════

enum _Period { week, month, year, all }

extension _PeriodX on _Period {
  String get label => switch (this) {
    _Period.week  => '7 jours',
    _Period.month => '30 jours',
    _Period.year  => '12 mois',
    _Period.all   => 'Tout',
  };

  DateTime? get from {
    final now = DateTime.now();
    return switch (this) {
      _Period.week  => DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6)),
      _Period.month => DateTime(now.year, now.month, now.day).subtract(const Duration(days: 29)),
      _Period.year  => DateTime(now.year - 1, now.month + 1, 1),
      _Period.all   => null,
    };
  }
}

/// Ligne affichable, source unifiée pour le ListView.
/// Si [orderId] est renseigné → c'est un frais de commande (virtuel,
/// lecture seule, redirige vers la caisse au tap).
class _ExpenseRow {
  final String id;
  final double amount;
  final ExpenseCategory category;
  final String label;
  final DateTime paidAt;
  final Expense? source;    // non-null pour les dépenses directes
  final String? orderId;    // non-null pour les frais de commande

  const _ExpenseRow({
    required this.id,
    required this.amount,
    required this.category,
    required this.label,
    required this.paidAt,
    this.source,
    this.orderId,
  });

  bool get isVirtual => orderId != null;

  factory _ExpenseRow.fromExpense(Expense e) => _ExpenseRow(
    id:       e.id,
    amount:   e.amount,
    category: e.category,
    label:    e.label,
    paidAt:   e.paidAt,
    source:   e,
  );

  factory _ExpenseRow.fromOrderFee({
    required String orderId,
    required int feeIndex,
    required String feeLabel,
    required double amount,
    required DateTime paidAt,
    required String? orderLabel,
  }) => _ExpenseRow(
    id:       'fee_${orderId}_$feeIndex',
    amount:   amount,
    category: ExpenseCategory.shipping,
    label:    feeLabel.isEmpty ? 'Frais de commande' : feeLabel,
    paidAt:   paidAt,
    orderId:  orderId,
  );
}

/// Vue embarquable des dépenses — sans Scaffold, pensée pour être placée
/// dans un onglet (Finances). Expose un bouton « Ajouter » et « Rafraîchir »
/// directement dans son en-tête.
class ExpensesView extends ConsumerStatefulWidget {
  final String shopId;
  const ExpensesView({super.key, required this.shopId});
  @override
  ConsumerState<ExpensesView> createState() => _ExpensesViewState();
}

class _ExpensesViewState extends ConsumerState<ExpensesView> {
  List<_ExpenseRow> _rows = [];
  _Period _period = _Period.month;
  ExpenseCategory? _categoryFilter;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _syncInBackground();
    AppDatabase.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged(String table, String shopId) {
    if (!mounted) return;
    if (shopId != widget.shopId && shopId != '_all') return;
    // On écoute expenses ET orders (les frais de commande peuvent changer)
    if (table == 'expenses' || table == 'orders') _refresh();
  }

  void _refresh() {
    final rows = <_ExpenseRow>[];

    // Dépenses directes
    for (final e in AppDatabase.getExpensesForShop(widget.shopId)) {
      rows.add(_ExpenseRow.fromExpense(e));
    }

    // Frais des commandes — entrées virtuelles dérivées de orders.fees
    // Un frais de livraison est engagé dès qu'il est renseigné sur la
    // commande, indépendamment du statut de la vente. On exclut uniquement
    // `cancelled` et `refused` où la livraison n'a vraisemblablement pas eu
    // lieu. Le listener sur `orders` répercute automatiquement tout
    // changement de statut, ajout/suppression de frais, ou suppression.
    try {
      for (final raw in HiveBoxes.ordersBox.values) {
        final o = Map<String, dynamic>.from(raw as Map);
        if (o['shop_id'] != widget.shopId) continue;
        final status = (o['status'] as String?) ?? 'completed';
        if (status == 'cancelled' || status == 'refused') continue;
        final fees = o['fees'] as List?;
        if (fees == null || fees.isEmpty) continue;
        final orderId = o['id']?.toString();
        if (orderId == null) continue;
        // Date effective : complétion si stampée, sinon création.
        final effectiveStr = (o['completed_at'] ?? o['created_at']) as String?;
        final effectiveAt = DateTime.tryParse(effectiveStr ?? '')?.toLocal()
            ?? DateTime.now();
        final orderLabel = (o['client_name'] as String?) ?? orderId;
        for (var i = 0; i < fees.length; i++) {
          final f = fees[i];
          if (f is! Map) continue;
          final amount = (f['amount'] as num?)?.toDouble() ?? 0;
          if (amount <= 0) continue;
          rows.add(_ExpenseRow.fromOrderFee(
            orderId:    orderId,
            feeIndex:   i,
            feeLabel:   (f['label'] as String?) ?? '',
            amount:     amount,
            paidAt:     effectiveAt,
            orderLabel: orderLabel,
          ));
        }
      }
    } catch (_) {}

    rows.sort((a, b) => b.paidAt.compareTo(a.paidAt));
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  Future<void> _syncInBackground() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    await AppDatabase.syncExpenses(widget.shopId);
    if (!mounted) return;
    setState(() => _syncing = false);
    _refresh();
  }

  List<_ExpenseRow> get _filtered {
    final from = _period.from;
    return _rows.where((r) {
      if (from != null && r.paidAt.isBefore(from)) return false;
      if (_categoryFilter != null && r.category != _categoryFilter) return false;
      return true;
    }).toList();
  }

  double get _total => _filtered.fold(0.0, (s, r) => s + r.amount);
  double get _totalDirect => _filtered
      .where((r) => !r.isVirtual)
      .fold(0.0, (s, r) => s + r.amount);
  double get _totalOrderFees => _filtered
      .where((r) => r.isVirtual)
      .fold(0.0, (s, r) => s + r.amount);

  Map<ExpenseCategory, double> get _byCategory {
    final map = <ExpenseCategory, double>{};
    for (final r in _filtered) {
      map[r.category] = (map[r.category] ?? 0) + r.amount;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Column(children: [
      _KpiHeader(
        total:         _total,
        directTotal:   _totalDirect,
        feesTotal:     _totalOrderFees,
        count:         filtered.length,
        period:        _period,
      ),
      _Toolbar(
        syncing: _syncing,
        onSync: _syncing ? null : _syncInBackground,
        onAdd:  () => _showForm(null),
      ),
      _PeriodBar(current: _period,
          onChange: (p) => setState(() => _period = p)),
      if (_byCategory.isNotEmpty)
        _CategoryChips(
          byCategory: _byCategory,
          selected: _categoryFilter,
          onSelect: (c) => setState(() =>
              _categoryFilter = _categoryFilter == c ? null : c),
        ),
      Expanded(child: _body(filtered)),
    ]);
  }

  Widget _body(List<_ExpenseRow> list) {
    if (list.isEmpty) {
      return RefreshIndicator(
        onRefresh: _syncInBackground,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 24),
            EmptyStateWidget(
              icon: Icons.account_balance_wallet_outlined,
              title: 'Aucune dépense pour cette période',
              subtitle: 'Garde un œil sur tes sorties d\'argent en '
                  'enregistrant ta première dépense.',
              ctaLabel: 'Ajouter une dépense',
              onCta: () => _showForm(null),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _syncInBackground,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (_, i) => _ExpenseTile(
          row: list[i],
          onTap: () => _onTapRow(list[i]),
          onDelete: () => _confirmDelete(list[i]),
        ),
      ),
    );
  }

  void _onTapRow(_ExpenseRow row) {
    if (row.isVirtual) {
      // Frais de commande → ouvrir la commande source pour édition
      context.push('/shop/${widget.shopId}/caisse?edit=${row.orderId}');
    } else {
      _showForm(row.source);
    }
  }

  void _showForm(Expense? expense) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => ExpenseFormSheet(
        shopId: widget.shopId,
        expense: expense,
        onSaved: () {
          Navigator.of(ctx).pop();
          AppSnack.success(context,
              expense == null ? 'Dépense ajoutée' : 'Dépense modifiée');
        },
      ),
    );
  }

  Future<void> _confirmDelete(_ExpenseRow row) async {
    if (row.isVirtual) {
      AppSnack.info(context,
          'Frais de commande : modifie-le depuis la page Caisse.');
      return;
    }
    final e = row.source!;
    final ok = await DangerConfirmDialog.show(
      context: context,
      title: 'Supprimer la dépense',
      description:
          '${e.label} — ${CurrencyFormatter.format(e.amount)}',
      consequences: const [
        'L\'écriture comptable disparaît de l\'historique.',
        'Le solde de trésorerie sera recalculé.',
      ],
      confirmText: e.label,
      onConfirmed: () {},
    );
    if (ok != true || !mounted) return;
    await AppDatabase.deleteExpense(e.id, e.shopId);
    await ActivityLogService.log(
      action:      'expense_deleted',
      targetType:  'expense',
      targetId:    e.id,
      targetLabel: e.label,
      shopId:      e.shopId,
      details:     {'amount': e.amount, 'category': e.category.name},
    );
    if (mounted) AppSnack.success(context, 'Dépense supprimée');
  }
}

// ─── KPI header ─────────────────────────────────────────────────────────────

class _KpiHeader extends StatelessWidget {
  final double total;
  final double directTotal;
  final double feesTotal;
  final int count;
  final _Period period;
  const _KpiHeader({required this.total, required this.directTotal,
      required this.feesTotal, required this.count, required this.period});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: [
        AppColors.primary.withOpacity(0.9),
        AppColors.primaryLight.withOpacity(0.8),
      ]),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.account_balance_wallet_rounded,
              color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total — ${period.label}',
                style: const TextStyle(fontSize: 11, color: Colors.white70,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Text(CurrencyFormatter.format(total),
                style: const TextStyle(fontSize: 22, color: Colors.white,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text('$count ligne${count > 1 ? 's' : ''}',
                style: const TextStyle(fontSize: 10, color: Colors.white70)),
          ])),
      ]),
      if (feesTotal > 0) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded,
                color: Colors.white70, size: 13),
            const SizedBox(width: 6),
            Expanded(child: Text(
              'Direct : ${CurrencyFormatter.format(directTotal)} · '
              'Frais commandes : ${CurrencyFormatter.format(feesTotal)}',
              style: const TextStyle(fontSize: 10.5, color: Colors.white,
                  fontWeight: FontWeight.w500),
            )),
          ]),
        ),
      ],
    ]),
  );
}

// ─── Toolbar (icônes compactes alignées à droite — pattern CRM) ─────────────

class _Toolbar extends StatelessWidget {
  final bool syncing;
  final VoidCallback? onSync;
  final VoidCallback onAdd;
  const _Toolbar({required this.syncing, required this.onSync,
      required this.onAdd});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        IconButton(
          onPressed: onSync,
          tooltip: 'Rafraîchir',
          icon: syncing
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh_rounded, size: 20),
          color: AppColors.primary,
        ),
        IconButton(
          onPressed: onAdd,
          tooltip: 'Ajouter une dépense',
          icon: const Icon(Icons.add_rounded, size: 22),
          color: AppColors.primary,
        ),
      ],
    ),
  );
}

// ─── Barre de période ───────────────────────────────────────────────────────

class _PeriodBar extends StatelessWidget {
  final _Period current;
  final ValueChanged<_Period> onChange;
  const _PeriodBar({required this.current, required this.onChange});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Row(children: _Period.values.map((p) {
      final active = p == current;
      return Expanded(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onChange(p),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: active ? AppColors.primary : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: active
                  ? AppColors.primary : const Color(0xFFE5E7EB)),
            ),
            child: Text(p.label,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    color: active ? Colors.white : const Color(0xFF374151))),
          ),
        ),
      ));
    }).toList()),
  );
}

// ─── Chips par catégorie (avec montant) ─────────────────────────────────────

class _CategoryChips extends StatelessWidget {
  final Map<ExpenseCategory, double> byCategory;
  final ExpenseCategory? selected;
  final ValueChanged<ExpenseCategory> onSelect;
  const _CategoryChips({required this.byCategory,
      required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final sorted = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return SizedBox(
      height: 38,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        scrollDirection: Axis.horizontal,
        itemCount: sorted.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final e = sorted[i];
          final cat = e.key;
          final active = selected == cat;
          return InkWell(
            onTap: () => onSelect(cat),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: active ? cat.color : cat.color.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: active
                    ? cat.color : cat.color.withOpacity(0.3)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(cat.icon, size: 13,
                    color: active ? Colors.white : cat.color),
                const SizedBox(width: 5),
                Text(cat.label,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: active ? Colors.white : cat.color)),
                const SizedBox(width: 6),
                Text(CurrencyFormatter.format(e.value),
                    style: TextStyle(fontSize: 10,
                        color: active ? Colors.white70 : cat.color.withOpacity(0.8),
                        fontWeight: FontWeight.w600)),
              ]),
            ),
          );
        },
      ),
    );
  }
}

// ─── Tuile dépense ──────────────────────────────────────────────────────────

class _ExpenseTile extends StatelessWidget {
  final _ExpenseRow row;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _ExpenseTile({required this.row,
      required this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final cat = row.category;
    final tile = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE5E7EB))),
        child: Row(children: [
          Container(width: 36, height: 36,
              decoration: BoxDecoration(
                  color: cat.color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(cat.icon, size: 17, color: cat.color)),
          const SizedBox(width: 10),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(row.label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A)))),
              if (row.isVirtual) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('Commande',
                      style: TextStyle(fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF3B82F6))),
                ),
              ],
            ]),
            const SizedBox(height: 2),
            Row(children: [
              Text(cat.label,
                  style: TextStyle(fontSize: 10.5,
                      color: cat.color, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              const Text('•', style: TextStyle(fontSize: 10,
                  color: Color(0xFF9CA3AF))),
              const SizedBox(width: 6),
              Text(_fmtDate(row.paidAt),
                  style: const TextStyle(fontSize: 10.5,
                      color: Color(0xFF6B7280))),
            ]),
          ])),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(CurrencyFormatter.format(row.amount),
                  style: const TextStyle(fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFEF4444))),
              if (!row.isVirtual) ...[
                const SizedBox(height: 2),
                SizedBox(
                  height: 26,
                  child: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert_rounded,
                        size: 17, color: Color(0xFF9CA3AF)),
                    padding: EdgeInsets.zero,
                    tooltip: 'Actions',
                    onSelected: (v) {
                      if (v == 'edit')   onTap();
                      if (v == 'delete') onDelete();
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', height: 36,
                        child: Row(children: [
                          Icon(Icons.edit_outlined, size: 15,
                              color: Color(0xFF3B82F6)),
                          SizedBox(width: 8),
                          Text('Modifier',
                              style: TextStyle(fontSize: 12.5)),
                        ])),
                      const PopupMenuItem(value: 'delete', height: 36,
                        child: Row(children: [
                          Icon(Icons.delete_outline_rounded, size: 15,
                              color: Color(0xFFEF4444)),
                          SizedBox(width: 8),
                          Text('Supprimer',
                              style: TextStyle(fontSize: 12.5,
                                  color: Color(0xFFEF4444))),
                        ])),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ]),
      ),
    );

    // Swipe-to-delete uniquement pour les dépenses directes (pas les frais)
    if (row.isVirtual) return tile;
    return Dismissible(
      key: ValueKey(row.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async { onDelete(); return false; },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
            color: const Color(0xFFEF4444),
            borderRadius: BorderRadius.circular(10)),
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
      ),
      child: tile,
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year.toString().substring(2)}';
}

// ═════════════════════════════════════════════════════════════════════════════
// FORMULAIRE AJOUT/ÉDITION — bottom sheet
// ═════════════════════════════════════════════════════════════════════════════

class ExpenseFormSheet extends StatefulWidget {
  final String shopId;
  final Expense? expense;
  final VoidCallback onSaved;
  const ExpenseFormSheet({super.key, required this.shopId, this.expense,
      required this.onSaved});
  @override
  State<ExpenseFormSheet> createState() => _ExpenseFormSheetState();
}

class _ExpenseFormSheetState extends State<ExpenseFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _labelCtrl;
  late TextEditingController _amountCtrl;
  late TextEditingController _notesCtrl;
  late ExpenseCategory _category;
  late PaymentMethod _paymentMethod;
  late DateTime _paidAt;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.expense;
    _labelCtrl    = TextEditingController(text: e?.label ?? '');
    _amountCtrl   = TextEditingController(text: e?.amount.toStringAsFixed(0) ?? '');
    _notesCtrl    = TextEditingController(text: e?.notes ?? '');
    _category     = e?.category ?? ExpenseCategory.subscription;
    _paymentMethod = e?.paymentMethod ?? PaymentMethod.cash;
    _paidAt       = e?.paidAt ?? DateTime.now();
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final amount = double.tryParse(_amountCtrl.text.replaceAll(',', '.')) ?? 0;
    final isNew = widget.expense == null;
    final expense = Expense(
      id:            widget.expense?.id ?? 'exp_${DateTime.now().millisecondsSinceEpoch}',
      shopId:        widget.shopId,
      amount:        amount,
      category:      _category,
      label:         _labelCtrl.text.trim(),
      paidAt:        _paidAt,
      paymentMethod: _paymentMethod,
      notes:         _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      receiptUrl:    widget.expense?.receiptUrl,
      createdBy:     widget.expense?.createdBy,
      createdAt:     widget.expense?.createdAt ?? DateTime.now(),
    );
    await AppDatabase.saveExpense(expense);
    await ActivityLogService.log(
      action:      isNew ? 'expense_created' : 'expense_updated',
      targetType:  'expense',
      targetId:    expense.id,
      targetLabel: expense.label,
      shopId:      expense.shopId,
      details: {
        'amount':   expense.amount,
        'category': expense.category.name,
      },
    );
    if (!mounted) return;
    widget.onSaved();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _paidAt,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d != null) setState(() => _paidAt = d);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, viewInsets + 20),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 36, height: 4,
                decoration: BoxDecoration(color: const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            Text(widget.expense == null ? 'Nouvelle dépense' : 'Modifier',
                style: const TextStyle(fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A))),
            const SizedBox(height: 16),

            // Libellé
            TextFormField(
              controller: _labelCtrl,
              decoration: _dec('Libellé', 'Ex: Facebook Ads Novembre'),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Libellé requis' : null,
            ),
            const SizedBox(height: 12),

            // Montant
            TextFormField(
              controller: _amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _dec('Montant (XAF)', '0'),
              validator: (v) {
                final d = double.tryParse((v ?? '').replaceAll(',', '.'));
                if (d == null || d < 0) return 'Montant invalide';
                return null;
              },
            ),
            const SizedBox(height: 12),

            // Catégorie — grid
            const Text('Catégorie',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280))),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6,
                children: ExpenseCategory.values.map((c) {
              final active = c == _category;
              return InkWell(
                onTap: () => setState(() => _category = c),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: active ? c.color : c.color.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: active
                        ? c.color : c.color.withOpacity(0.3)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(c.icon, size: 13,
                        color: active ? Colors.white : c.color),
                    const SizedBox(width: 5),
                    Text(c.label,
                        style: TextStyle(fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: active ? Colors.white : c.color)),
                  ]),
                ),
              );
            }).toList()),
            const SizedBox(height: 14),

            // Date
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  const Icon(Icons.calendar_today_rounded,
                      size: 16, color: Color(0xFF6B7280)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(
                    'Payée le ${_paidAt.day.toString().padLeft(2, '0')}/'
                    '${_paidAt.month.toString().padLeft(2, '0')}/${_paidAt.year}',
                    style: const TextStyle(fontSize: 13,
                        color: Color(0xFF0F172A)))),
                  const Icon(Icons.chevron_right_rounded,
                      size: 16, color: Color(0xFF9CA3AF)),
                ]),
              ),
            ),
            const SizedBox(height: 12),

            // Mode paiement
            DropdownButtonFormField<PaymentMethod>(
              value: _paymentMethod,
              decoration: _dec('Mode de paiement', ''),
              items: PaymentMethod.values.map((m) => DropdownMenuItem(
                value: m,
                child: Text(_paymentLabel(m)),
              )).toList(),
              onChanged: (v) => setState(() =>
                  _paymentMethod = v ?? PaymentMethod.cash),
            ),
            const SizedBox(height: 12),

            // Notes (optionnelles)
            TextFormField(
              controller: _notesCtrl,
              maxLines: 2,
              decoration: _dec('Notes (optionnel)',
                  'Fournisseur, référence, commentaire…'),
            ),
            const SizedBox(height: 20),

            SizedBox(width: double.infinity, child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: _saving
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(widget.expense == null ? 'Enregistrer' : 'Mettre à jour',
                      style: const TextStyle(fontSize: 14,
                          fontWeight: FontWeight.w600)),
            )),
          ]),
        ),
      ),
    );
  }

  InputDecoration _dec(String label, String hint) => InputDecoration(
    labelText: label,
    hintText: hint,
    isDense: true,
    labelStyle: const TextStyle(fontSize: 12),
    hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFD1D5DB)),
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
    enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
    focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
    contentPadding: const EdgeInsets.symmetric(
        horizontal: 14, vertical: 12),
  );

  String _paymentLabel(PaymentMethod m) => switch (m) {
    PaymentMethod.cash        => 'Espèces',
    PaymentMethod.mobileMoney => 'Mobile Money',
    PaymentMethod.card        => 'Carte bancaire',
    PaymentMethod.credit      => 'Crédit',
  };
}
