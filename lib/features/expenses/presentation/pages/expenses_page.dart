import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../core/services/partner_ledger_service.dart';
import '../../../parametres/domain/entities/partner_ledger_entry.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../dashboard/data/dashboard_providers.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../../caisse/domain/entities/sale.dart' show PaymentMethod;
import '../../../caisse/data/repositories/sale_local_datasource.dart';
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
  final int? feeIndex;      // index du frais dans orders.fees (frais cmd)
  /// Emplacement rattaché (cf. dashViewFilterProvider) :
  ///   null = global, '_base' = boutique, <id> = partenaire.
  /// Dépense directe → Expense.locationId. Frais de commande →
  /// deliveryLocationId de la commande (partenaire-livreur) si présent.
  final String? locationId;
  /// Non-null pour une CHARGE du livre partenaire (stockage, commission…),
  /// gérée dans Finances → Partenaires (pas une dépense « directe »).
  final String? ledgerEntryId;

  const _ExpenseRow({
    required this.id,
    required this.amount,
    required this.category,
    required this.label,
    required this.paidAt,
    this.source,
    this.orderId,
    this.feeIndex,
    this.locationId,
    this.ledgerEntryId,
  });

  bool get isVirtual => orderId != null;
  bool get isPartnerCharge => ledgerEntryId != null;

  factory _ExpenseRow.fromPartnerCharge({
    required String entryId,
    required double amount,
    required ExpenseCategory category,
    required String label,
    required DateTime paidAt,
    required String? partnerLocationId,
  }) => _ExpenseRow(
    id:           'pcharge_$entryId',
    amount:       amount,
    category:     category,
    label:        label,
    paidAt:       paidAt,
    ledgerEntryId: entryId,
    locationId:   partnerLocationId,
  );

  factory _ExpenseRow.fromExpense(Expense e) => _ExpenseRow(
    id:       e.id,
    amount:   e.amount,
    category: e.category,
    label:    e.label,
    paidAt:   e.paidAt,
    source:   e,
    locationId: e.locationId,
  );

  factory _ExpenseRow.fromOrderFee({
    required String orderId,
    required int feeIndex,
    required String feeLabel,
    required double amount,
    required DateTime paidAt,
    required String? orderLabel,
    String? deliveryLocationId,
  }) => _ExpenseRow(
    id:       'fee_${orderId}_$feeIndex',
    amount:   amount,
    category: ExpenseCategory.shipping,
    label:    feeLabel.isEmpty ? 'Frais de commande' : feeLabel,
    paidAt:   paidAt,
    orderId:  orderId,
    feeIndex: feeIndex,
    locationId: deliveryLocationId,
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
        final o = Map<String, dynamic>.from(raw);
        if (o['shop_id'] != widget.shopId) continue;
        final status = (o['status'] as String?) ?? 'completed';
        if (status == 'cancelled' || status == 'refused') continue;
        final orderId = o['id']?.toString();
        if (orderId == null) continue;
        // Date effective : complétion si stampée, sinon création.
        final effectiveStr = (o['completed_at'] ?? o['created_at']) as String?;
        final effectiveAt = DateTime.tryParse(effectiveStr ?? '')?.toLocal()
            ?? DateTime.now();
        final orderLabel = (o['client_name'] as String?) ?? orderId;
        final deliveryLocId = o['delivery_location_id'] as String?;

        // Frais de LIVRAISON (nouveau modèle) : `deliveryPrice` payé à un
        // partenaire / une agence = dépense de livraison réelle. (Retrait et
        // livraison par l'équipe interne = pas de coût externe → non compté.)
        final mode = o['delivery_mode'] as String?;
        final deliveryPrice = (o['delivery_price'] as num?)?.toDouble() ?? 0;
        if (deliveryPrice > 0 && (mode == 'partner' || mode == 'shipment')) {
          rows.add(_ExpenseRow.fromOrderFee(
            orderId:    orderId,
            feeIndex:   -1, // marqueur : deliveryPrice (pas un index de fees[])
            feeLabel:   'Frais de livraison',
            amount:     deliveryPrice,
            paidAt:     effectiveAt,
            orderLabel: orderLabel,
            deliveryLocationId: deliveryLocId,
          ));
        }

        // Autres frais engagés sur la commande (emballage…).
        final fees = o['fees'] as List?;
        if (fees == null || fees.isEmpty) continue;
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
            deliveryLocationId: deliveryLocId,
          ));
        }
      }
    } catch (_) {}

    // Charges du LIVRE PARTENAIRE (stockage, commission…) — vraies sorties
    // d'argent, gérées dans Finances → Partenaires. On NE reprend PAS
    // `deliveryOwed` (la livraison est déjà comptée via `deliveryPrice`).
    try {
      for (final e in PartnerLedgerService.entriesForShop(widget.shopId)) {
        if (e.type != PartnerLedgerEntryType.partnerCharge) continue;
        final amount = e.amount.abs();
        if (amount <= 0) continue;
        rows.add(_ExpenseRow.fromPartnerCharge(
          entryId:  e.id,
          amount:   amount,
          category: _chargeToExpenseCategory(e.category),
          label:    (e.note != null && e.note!.trim().isNotEmpty)
              ? e.note!.trim()
              : (e.category?.labelFr ?? 'Charge partenaire'),
          paidAt:   e.createdAt.toLocal(),
          partnerLocationId: e.partnerLocationId,
        ));
      }
    } catch (_) {}

    rows.sort((a, b) => b.paidAt.compareTo(a.paidAt));
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  /// Mappe une sous-catégorie de charge partenaire vers une [ExpenseCategory].
  ExpenseCategory _chargeToExpenseCategory(PartnerChargeCategory? c) {
    switch (c) {
      case PartnerChargeCategory.storage:        return ExpenseCategory.storage;
      case PartnerChargeCategory.failedDelivery: return ExpenseCategory.shipping;
      default:                                   return ExpenseCategory.other;
    }
  }

  Future<void> _syncInBackground() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    await AppDatabase.syncExpenses(widget.shopId);
    if (!mounted) return;
    setState(() => _syncing = false);
    _refresh();
  }

  /// Filtre emplacement (cf. dashViewFilterProvider) :
  ///   • null    (Globale) → toutes les dépenses
  ///   • '_base' (Boutique) → locationId == '_base' OU null (les charges
  ///     globales sont supportées par la boutique de base)
  ///   • <id>    (Partenaire) → locationId == <id> strictement
  bool _matchesLocationView(_ExpenseRow r, String? view) {
    if (view == null) return true;
    // Vue Boutique : toutes les dépenses de la boutique — les siennes ET celles
    // liées à ses partenaires (livraison, stockage). Le détail par partenaire
    // reste accessible en sélectionnant ce partenaire.
    if (view == '_base') return true;
    return r.locationId == view;
  }

  List<_ExpenseRow> get _filtered {
    final from = _period.from;
    final view = ref.read(dashViewFilterProvider);
    return _rows.where((r) {
      if (from != null && r.paidAt.isBefore(from)) return false;
      if (_categoryFilter != null && r.category != _categoryFilter) return false;
      if (!_matchesLocationView(r, view)) return false;
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
    // watch (pas read) pour rebuild quand l'utilisateur change la vue.
    ref.watch(dashViewFilterProvider);
    final filtered = _filtered;
    // Un SEUL ListView scrollable (en-têtes + liste) pour que l'onglet
    // Dépenses défile d'un bloc comme Revenus/Pertes/Bilan, au lieu d'un
    // header fixe + liste scrollable séparée.
    return RefreshIndicator(
      onRefresh: _syncInBackground,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 90),
        children: [
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
          // Filtre emplacement piloté globalement par la page Finances
          // (ViewFilterChipBar au niveau _FinancesBody).
          _PeriodBar(current: _period,
              onChange: (p) => setState(() => _period = p)),
          if (_byCategory.isNotEmpty)
            _CategoryChips(
              byCategory: _byCategory,
              selected: _categoryFilter,
              onSelect: (c) => setState(() =>
                  _categoryFilter = _categoryFilter == c ? null : c),
            ),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: EmptyStateWidget(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Aucune dépense pour cette période',
                subtitle: 'Garde un œil sur tes sorties d\'argent en '
                    'enregistrant ta première dépense.',
                ctaLabel: 'Ajouter une dépense',
                onCta: () => _showForm(null),
              ),
            )
          else
            for (var i = 0; i < filtered.length; i++)
              Padding(
                padding: EdgeInsets.fromLTRB(
                    12, i == 0 ? 8 : 6, 12, 0),
                child: _ExpenseTile(
                  row: filtered[i],
                  onTap: () => _onTapRow(filtered[i]),
                  onDelete: () => _confirmDelete(filtered[i]),
                ),
              ),
        ],
      ),
    );
  }

  void _onTapRow(_ExpenseRow row) {
    if (row.isPartnerCharge) {
      // Charge du livre partenaire → gérée dans Finances → Partenaires.
      AppSnack.success(context,
          'Charge partenaire — modifiable dans Finances → Partenaires.');
      return;
    }
    if (row.isVirtual) {
      // Frais de commande → ouvrir la commande source pour édition
      context.push('/shop/${widget.shopId}/caisse?edit=${row.orderId}');
    } else {
      _showForm(row.source);
    }
  }

  void _showForm(Expense? expense) {
    showFormSheet(
      context: context,
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
    // Charge du livre partenaire (stockage…) : on supprime l'écriture dans le
    // livre partenaire (source de vérité). Le solde du partenaire se recalcule.
    if (row.isPartnerCharge) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Supprimer cette charge partenaire ?'),
          content: Text(
              '${row.label} — ${CurrencyFormatter.format(row.amount)}\n\n'
              'L\'écriture sera retirée du livre partenaire et le solde du '
              'partenaire recalculé.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Annuler')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444)),
                child: const Text('Supprimer')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await PartnerLedgerService.deleteEntry(row.ledgerEntryId!, widget.shopId);
      if (mounted) AppSnack.success(context, 'Charge supprimée');
      return;
    }
    // Frais de commande (virtuel) : on supprime l'entrée correspondante
    // dans `orders.fees` de la commande source. La ligne disparaît au
    // prochain _refresh (listener `orders`).
    if (row.isVirtual) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Supprimer ce frais de commande ?'),
          content: Text(
              '${row.label} — ${CurrencyFormatter.format(row.amount)}\n\n'
              'Le frais sera retiré de la commande. Le prix de revient '
              'de la commande sera recalculé en conséquence.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Annuler')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444)),
                child: const Text('Supprimer')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      final orderId  = row.orderId;
      final feeIndex = row.feeIndex;
      if (orderId == null || feeIndex == null) return;
      if (feeIndex < 0) {
        // Ligne « frais de livraison » (deliveryPrice) → retirer la livraison.
        await SaleLocalDatasource().setDeliveryPrice(orderId, 0);
      } else {
        await SaleLocalDatasource().deleteOrderFee(orderId, feeIndex);
      }
      await ActivityLogService.log(
        action:      'order_fee_deleted',
        targetType:  'order',
        targetId:    orderId,
        targetLabel: row.label,
        shopId:      widget.shopId,
        details:     {'amount': row.amount, 'fee_index': feeIndex},
      );
      if (mounted) AppSnack.success(context, 'Frais supprimé');
      return;
    }
    final e = row.source!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer la dépense ?'),
        content: Text(
            '${e.label} — ${CurrencyFormatter.format(e.amount)}\n\n'
            'L\'écriture disparaît de l\'historique et le solde de '
            'trésorerie sera recalculé.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFEF4444)),
              child: const Text('Supprimer')),
        ],
      ),
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
        AppColors.primary.withValues(alpha:0.9),
        AppColors.primaryLight.withValues(alpha:0.8),
      ]),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
              color: Colors.white.withValues(alpha:0.15),
              borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.account_balance_wallet_rounded,
              color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total — ${period.label}',
                style: AppTextStyles.caption.copyWith(color: Colors.white70)),
            const SizedBox(height: 2),
            Text(CurrencyFormatter.format(total),
                style: AppTextStyles.display.copyWith(color: Colors.white)),
            const SizedBox(height: 2),
            Text('$count ligne${count > 1 ? 's' : ''}',
                style: AppTextStyles.micro.copyWith(color: Colors.white70)),
          ])),
      ]),
      if (feesTotal > 0) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha:0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded,
                color: Colors.white70, size: 13),
            const SizedBox(width: 6),
            Expanded(child: Text(
              'Direct : ${CurrencyFormatter.format(directTotal)} · '
              'Frais commandes : ${CurrencyFormatter.format(feesTotal)}',
              style: AppTextStyles.micro.copyWith(color: Colors.white),
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
              color: active
                  ? AppColors.primary
                  : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: active
                  ? AppColors.primary
                  : Theme.of(context).semantic.borderSubtle),
            ),
            child: Text(p.label,
                textAlign: TextAlign.center,
                style: AppTextStyles.captionBold.copyWith(
                    color: active ? Colors.white : AppColors.onSurface)),
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
                color: active ? cat.color : cat.color.withValues(alpha:0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: active
                    ? cat.color : cat.color.withValues(alpha:0.3)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(cat.icon, size: 13,
                    color: active ? Colors.white : cat.color),
                const SizedBox(width: 5),
                Text(cat.label,
                    style: AppTextStyles.captionBold.copyWith(
                        color: active ? Colors.white : cat.color)),
                const SizedBox(width: 6),
                Text(CurrencyFormatter.format(e.value),
                    style: AppTextStyles.microBold.copyWith(
                        color: active ? Colors.white70 : cat.color.withValues(alpha:0.8))),
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
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: Theme.of(context).semantic.borderSubtle)),
        child: Row(children: [
          Container(width: 36, height: 36,
              decoration: BoxDecoration(
                  color: cat.color.withValues(alpha:0.12),
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(cat.icon, size: 17, color: cat.color)),
          const SizedBox(width: 10),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(row.label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyBold.copyWith(
                      color: AppColors.onSurface))),
              if (row.isVirtual) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6).withValues(alpha:0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('Commande',
                      style: AppTextStyles.microBold.copyWith(
                          color: const Color(0xFF3B82F6))),
                ),
              ],
            ]),
            const SizedBox(height: 2),
            Row(children: [
              Text(cat.label,
                  style: AppTextStyles.microBold.copyWith(color: cat.color)),
              const SizedBox(width: 6),
              Text('•', style: AppTextStyles.micro.copyWith(
                  color: AppColors.textHint)),
              const SizedBox(width: 6),
              Text(_fmtDate(row.paidAt),
                  style: AppTextStyles.microSecondary),
            ]),
          ])),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(CurrencyFormatter.format(row.amount),
                  style: AppTextStyles.label.copyWith(
                      color: const Color(0xFFEF4444))),
              ...[
                const SizedBox(height: 6),
                InkWell(
                  onTap: onDelete,
                  borderRadius: BorderRadius.circular(7),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withValues(alpha:0.10),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min,
                        children: [
                      const Icon(Icons.delete_outline_rounded, size: 14,
                          color: Color(0xFFEF4444)),
                      const SizedBox(width: 4),
                      Text('Supprimer',
                          style: AppTextStyles.captionBold.copyWith(
                              color: const Color(0xFFEF4444))),
                    ]),
                  ),
                ),
              ],
            ],
          ),
        ]),
      ),
    );

    // Swipe-to-delete pour toutes les lignes (dépenses directes ET frais
    // de commande — la confirmation distingue les deux cas).
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
  /// null = dépense globale, '_base' = boutique, <id> = partenaire.
  String? _locationId;
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
    _locationId   = e?.locationId;
  }

  /// Partenaires actifs de la boutique (StockLocation type='partner').
  List<StockLocation> _partners() {
    final shop = LocalStorageService.getShop(widget.shopId);
    final ownerId = shop?.ownerId;
    if (ownerId == null) return const [];
    final out = <StockLocation>[];
    for (final raw in HiveBoxes.stockLocationsBox.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
        if (loc.ownerId == ownerId
            && loc.type == StockLocationType.partner
            && loc.isActive) {
          out.add(loc);
        }
      } catch (_) {/* ligne corrompue ignorée */}
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
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
      locationId:    _locationId,
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
    return Form(
      key: _formKey,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        FormSheetHeader(
          title: widget.expense == null ? 'Nouvelle dépense' : 'Modifier',
          icon: widget.expense == null
              ? Icons.add_card_outlined
              : Icons.edit_outlined,
        ),
        Flexible(child: Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, viewInsets + 20),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start, children: [

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
              decoration: _dec('Montant (${CurrencyFormatter.currentSymbol})', '0'),
              validator: (v) {
                final d = double.tryParse((v ?? '').replaceAll(',', '.'));
                if (d == null || d < 0) return 'Montant invalide';
                return null;
              },
            ),
            const SizedBox(height: 12),

            // Catégorie — grid
            Text('Catégorie',
                style: AppTextStyles.captionBold),
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
                    color: active ? c.color : c.color.withValues(alpha:0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: active
                        ? c.color : c.color.withValues(alpha:0.3)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(c.icon, size: 13,
                        color: active ? Colors.white : c.color),
                    const SizedBox(width: 5),
                    Text(c.label,
                        style: AppTextStyles.captionBold.copyWith(
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
                  border: Border.all(
                      color: Theme.of(context).semantic.borderSubtle),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  Icon(Icons.calendar_today_rounded,
                      size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(
                    'Payée le ${_paidAt.day.toString().padLeft(2, '0')}/'
                    '${_paidAt.month.toString().padLeft(2, '0')}/${_paidAt.year}',
                    style: AppTextStyles.body.copyWith(
                        color: AppColors.onSurface))),
                  Icon(Icons.chevron_right_rounded,
                      size: 16, color: AppColors.textHint),
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

            // Emplacement rattaché : Global / Boutique / Partenaire.
            // Permet d'imputer la charge au bon périmètre et de filtrer
            // les finances ensuite (cf. dashViewFilterProvider).
            DropdownButtonFormField<String?>(
              value: _locationId,
              decoration: _dec('Rattachée à', ''),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Globale (toute la boutique)'),
                ),
                const DropdownMenuItem<String?>(
                  value: '_base',
                  child: Text('Boutique'),
                ),
                for (final p in _partners())
                  DropdownMenuItem<String?>(
                    value: p.id,
                    child: Text(p.name),
                  ),
              ],
              onChanged: (v) => setState(() => _locationId = v),
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
                      style: AppTextStyles.label.copyWith(
                          color: Colors.white)),
            )),
            ]),
          ),
        )),
      ]),
    );
  }

  InputDecoration _dec(String label, String hint) => InputDecoration(
    labelText: label,
    hintText: hint,
    isDense: true,
    labelStyle: AppTextStyles.bodySm,
    hintStyle: AppTextStyles.bodySm.copyWith(
        color: AppColors.textHint),
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.divider)),
    enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.divider)),
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
