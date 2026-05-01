import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/kpi_card.dart' as shared_kpi;
import '../../../../shared/providers/current_shop_provider.dart';
import '../../../shop_selector/domain/entities/shop_summary.dart';
import '../../../shop_selector/presentation/bloc/shop_selector_bloc.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../data/dashboard_providers.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/document_service.dart';
import '../../../inventaire/presentation/widgets/share_catalog_dialog.dart';


// ─── Modèles mock (legacy non-KPI) ───────────────────────────────────────────

class _TxData {
  final String method, name, time, amount, status;
  final bool completed, cancelled;
  const _TxData(this.method, this.name, this.time, this.amount,
      this.status, this.completed, this.cancelled);
}

class _AlertData {
  final String name, detail;
  final bool critical;
  const _AlertData(this.name, this.detail, this.critical);
}

class _TopProduct {
  final String name, sales;
  final double delta;
  final bool positive;
  const _TopProduct(this.name, this.sales, this.delta, this.positive);
}

// ─── Page principale ──────────────────────────────────────────────────────────

class DashboardPage extends ConsumerWidget {
  final String shopId;
  const DashboardPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _DashBody(shopId: shopId);
  }
}

// ─── Corps scrollable ─────────────────────────────────────────────────────────

class _DashBody extends ConsumerStatefulWidget {
  final String shopId;
  const _DashBody({required this.shopId});
  @override
  ConsumerState<_DashBody> createState() => _DashBodyState();
}

class _DashBodyState extends ConsumerState<_DashBody> {
  String _period = 'today';
  DateTimeRange? _customRange;

  @override
  void initState() {
    super.initState();
    AppDatabase.addListener(_onDataChanged);
    // Forcer un recalcul frais depuis Hive à chaque montage du dashboard
    // (après login, retour de navigation, changement de boutique).
    // Le Provider.family cache son résultat — sans ce bump, il réutiliserait
    // l'ancien résultat même si Hive a changé entre-temps.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(dashSignalProvider.notifier).state++;
    });
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged(String table, String shopId) {
    if (!mounted) return;
    // '_all' = notification globale (reset, flush queue) → toujours rafraîchir
    if (shopId != widget.shopId && shopId != '_all') return;
    ref.read(dashSignalProvider.notifier).state++;
  }

  static const _topProducts = [
    _TopProduct('Organic Latte',   '124 unités', 18, true),
    _TopProduct('Chocolate Cake',  '84 unités',  12, true),
    _TopProduct('Avocado Toast',   '57 unités',  -5, false),
    _TopProduct('Fruit Smoothie',  '66 unités',  8,  true),
  ];

  static const _transactions = [
    _TxData('Carte bancaire', 'Emma Thompson',    '14:22', '+42.50 XAF', 'Completed', true,  false),
    _TxData('Espèces',        'Michael Rodriguez','14:05', '+18.75 XAF', 'Completed', true,  false),
    _TxData('Carte bancaire', 'Sophia Chen',      '13:48', '+35.20 XAF', 'Completed', true,  false),
  ];

  static const _alerts = [
    _AlertData('Organic Coffee Beans', '2 unités restantes', true),
    _AlertData('Almond Milk',          '5 unités restantes', false),
    _AlertData('Chocolate Syrup',      '6 unités restantes', false),
  ];

  // Données graphique par période
  List<double> get _chartData => switch (_period) {
    'yesterday' => [400, 480, 320, 560, 450, 620, 510],
    'week'      => [2100, 3200, 2800, 4100, 3600, 5200, 4300],
    'month'     => [18000, 22000, 19000, 25000, 21000, 28000, 24000],
    'year'      => [65000, 72000, 80000, 68000, 90000, 85000, 95000],
    _           => [380, 480, 340, 560, 430, 600, 510],
  };

  List<String> get _chartLabels => switch (_period) {
    'yesterday' => ['0h','4h','8h','12h','16h','20h','23h'],
    'week'      => ['Lun','Mar','Mer','Jeu','Ven','Sam','Dim'],
    'month'     => ['S1','S2','S3','S4','S5','S6','S7'],
    'year'      => ['Jan','Mar','Mai','Jul','Sep','Nov','Déc'],
    _           => ['Lun','Mar','Mer','Jeu','Ven','Sam','Dim'],
  };

  String _periodLabel(AppLocalizations l) => switch (_period) {
    'yesterday' => l.periodYesterday,
    'week'      => l.periodWeek,
    'month'     => l.periodMonth,
    'year'      => l.periodYear,
    'custom'    => _customRange != null
        ? '${_fmt(_customRange!.start)} – ${_fmt(_customRange!.end)}'
        : l.periodCustom,
    _           => l.periodToday,
  };

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}';

  String _fmtNum(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }

  void _showPeriodPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _PeriodPicker(
        current: _period,
        customRange: _customRange,
        onPeriod: (p) {
          setState(() { _period = p; _customRange = null; });
          ref.read(dashPeriodProvider.notifier).state = _toEnum(p);
          ref.read(dashCustomRangeProvider.notifier).state = null;
          Navigator.pop(context);
        },
        onCustom: (r) {
          setState(() { _period = 'custom'; _customRange = r; });
          ref.read(dashPeriodProvider.notifier).state = DashPeriod.custom;
          ref.read(dashCustomRangeProvider.notifier).state =
              DashRange(r.start, r.end);
          Navigator.pop(context);
        },
      ),
    );
  }

  DashPeriod _toEnum(String p) => switch (p) {
        'yesterday' => DashPeriod.yesterday,
        'week'      => DashPeriod.week,
        'month'     => DashPeriod.month,
        'year'      => DashPeriod.year,
        'custom'    => DashPeriod.custom,
        _           => DashPeriod.today,
      };

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final data = ref.watch(dashDataProvider(widget.shopId));

    // KPIs prioritaires — strictement les 4 demandés par la spec dashboard
    // (CA Total, Transactions, Clients, Bénéfice net) — affichés en grille
    // 2×2 sur mobile / 4 colonnes sur desktop via _PriorityKpiGrid.
    final shopId = widget.shopId;
    final priorityKpis = <shared_kpi.KpiData>[
      shared_kpi.KpiData(
        label: l.dashTotalSales,
        value: _fmtNum(data.totalSales), unit: 'XAF',
        icon: Icons.trending_up,
        color: AppColors.secondary,
        onTap: () => context.push('/shop/$shopId/finances'),
      ),
      shared_kpi.KpiData(
        label: l.dashTransactions,
        value: data.orderCount.toString(),
        icon: Icons.receipt_long_rounded,
        color: AppColors.info,
        onTap: () => context.push('/shop/$shopId/caisse'),
      ),
      shared_kpi.KpiData(
        label: l.dashCustomers,
        value: data.clientCount.toString(),
        icon: Icons.people_rounded,
        color: AppColors.warning,
        onTap: () => context.push('/shop/$shopId/crm'),
      ),
      shared_kpi.KpiData(
        label: l.dashNetProfit,
        value: _fmtNum(data.netProfit), unit: 'XAF',
        icon: Icons.account_balance_wallet_rounded,
        color: data.netProfit >= 0
            ? AppColors.primary
            : AppColors.error,
        positive: data.netProfit >= 0,
        onTap: () => context.push('/shop/$shopId/finances'),
      ),
    ];

    // Alertes — KPIs conditionnels qui signalent un état nécessitant
    // l'attention de l'owner (incidents, pertes, dépenses élevées,
    // commandes programmées en attente). Affichés dans une section
    // _AlertsSection sous les KPIs prioritaires, masquée si vide.
    final alertKpis = <shared_kpi.KpiData>[
      if (data.scheduledCount > 0)
        shared_kpi.KpiData(
          label: l.dashScheduled,
          value: data.scheduledCount.toString(),
          icon: Icons.calendar_month_rounded,
          color: AppColors.primary,
          onTap: () => context.push('/shop/$shopId/caisse/orders'),
        ),
      if (data.pendingIncidents > 0)
        shared_kpi.KpiData(
          label: l.dashIncidents,
          value: data.pendingIncidents.toString(),
          icon: Icons.warning_rounded,
          color: AppColors.warning,
          errorIndicator: true,
          onTap: () => context.push('/shop/$shopId/inventaire/incidents'),
        ),
      if (data.scrappedLoss > 0)
        shared_kpi.KpiData(
          label: l.dashScrappedLoss,
          value: _fmtNum(data.scrappedLoss), unit: 'XAF',
          icon: Icons.delete_forever_rounded,
          color: AppColors.error,
          errorIndicator: true,
          onTap: () => context.push('/shop/$shopId/finances'),
        ),
      if (data.repairCost > 0)
        shared_kpi.KpiData(
          label: l.dashRepairCost,
          value: _fmtNum(data.repairCost), unit: 'XAF',
          icon: Icons.build_rounded,
          color: AppColors.warning,
        ),
      if (data.totalLoss > 0)
        shared_kpi.KpiData(
          label: l.dashLoss,
          value: _fmtNum(data.totalLoss), unit: 'XAF',
          icon: Icons.trending_down_rounded,
          color: AppColors.error,
          errorIndicator: true,
          onTap: () => context.push('/shop/$shopId/finances'),
        ),
      if (data.operatingExpenses > 0)
        shared_kpi.KpiData(
          label: l.dashExpenses,
          value: _fmtNum(data.operatingExpenses), unit: 'XAF',
          icon: Icons.account_balance_wallet_rounded,
          color: AppColors.error,
          errorIndicator: true,
          onTap: () => context.push('/shop/$shopId/finances'),
        ),
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [

        // ── Sélecteur boutique active ──────────────────────────────────────
        _ShopSwitcherBanner(shopId: widget.shopId),
        const SizedBox(height: 12),

        // ── Header : titre + accès rapide + filtre période ────────────────
        _DashboardHeader(
          shopId: widget.shopId,
          periodLabel: _periodLabel(l),
          onPeriodTap: () => _showPeriodPicker(context),
        ),
        const SizedBox(height: 14),

        // ── KPI Cards prioritaires (2×2 mobile / 4 cols desktop) ──────────
        _PriorityKpiGrid(kpis: priorityKpis),
        const SizedBox(height: 14),

        // ── Section Alertes (visible seulement si non-vide) ───────────────
        if (alertKpis.isNotEmpty) ...[
          _AlertsSection(alerts: alertKpis),
          const SizedBox(height: 14),
        ],

        // ── Résumé financier (CA → bénéfice net + marge nette) ────────────
        _FinancialSummaryCard(data: data),
        const SizedBox(height: 14),

        // ── Graphique barres groupées + Top Produits ──────────────────────
        _TwoColWrap(
          minSecondWidth: 220,
          first: _SalesBarChart(
            sales:    data.salesSeries,
            profit:   data.profitSeries,
            expenses: data.expensesSeries,
            labels:   data.labels,
            period:   _period,
            onPeriodTap: () => _showPeriodPicker(context),
          ),
          second: _TopProductsCard(
              products: data.topProducts, shopId: widget.shopId),
          firstFlex: 3, secondFlex: 2,
        ),
        const SizedBox(height: 14),

        // ── Nouveaux produits (< 72h) — owner uniquement ──────────────
        if (ref.watch(permissionsProvider(widget.shopId)).isOwner) ...[
          _NewProductsCard(products: data.newProducts, shopId: widget.shopId),
          const SizedBox(height: 14),
        ],

        // ── Transactions + Alertes ────────────────────────────────────────
        _TwoColWrap(
          minSecondWidth: 220,
          first: _RecentTxCard(
              transactions: data.recentTx, shopId: widget.shopId),
          second: _InventoryAlertsCard(
              alerts: data.lowStock, shopId: widget.shopId),
          firstFlex: 3, secondFlex: 2,
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

// ─── Grille KPIs prioritaires (2×2 mobile / 4 cols desktop) ─────────────────
/// Strictement les 4 KPIs spec dashboard : CA Total · Transactions · Clients
/// · Bénéfice net. Layout figé pour éviter les surprises responsive : 2
/// colonnes en dessous de 600px de large, 4 colonnes au-dessus. Contraste
/// avec `KpiGrid` (shared) qui scrollait horizontalement sur mobile —
/// comportement non souhaité ici (la spec veut toujours voir les 4 cards
/// d'un coup).
class _PriorityKpiGrid extends StatelessWidget {
  final List<shared_kpi.KpiData> kpis;
  const _PriorityKpiGrid({required this.kpis});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      final isWide  = c.maxWidth >= 600;
      final cols    = isWide ? 4 : 2;
      // Aspect ratio ajusté pour que la card reste lisible sans
      // troncation : plus large sur desktop (4 cols), plus carrée sur
      // mobile (2 cols, donc plus haute par card).
      final ratio   = isWide ? 1.55 : 1.30;
      // Spec round 9 : gap 5px sur mobile (vs 10 desktop).
      final spacing = isWide ? 10.0 : 5.0;
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: kpis.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount:   cols,
          childAspectRatio: ratio,
          mainAxisSpacing:  spacing,
          crossAxisSpacing: spacing,
        ),
        itemBuilder: (_, i) => shared_kpi.KpiCard(data: kpis[i]),
      );
    });
  }
}

// ─── Section Alertes (KPIs conditionnels) ───────────────────────────────────
/// Liste les signaux nécessitant l'attention de l'owner : commandes
/// programmées en attente, incidents inventaire, pertes rebuts, coûts
/// réparation, dépenses opérationnelles, etc. Masquée si `alerts` est
/// vide (cf. _DashBodyState.build qui n'inclut pas la section quand le
/// shop n'a aucun signal d'alerte).
class _AlertsSection extends StatelessWidget {
  final List<shared_kpi.KpiData> alerts;
  const _AlertsSection({required this.alerts});

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.semantic.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 24, height: 24,
            decoration: BoxDecoration(
              color: theme.semantic.warning.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(Icons.notifications_active_rounded,
                size: 14, color: theme.semantic.warning),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(l.dashAlertsTitle,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface))),
        ]),
        const SizedBox(height: 10),
        // Wrap = grille naturelle 2 cols mobile, 3+ cols desktop, sans
        // fixer le nombre exact (le contenu décide).
        LayoutBuilder(builder: (_, c) {
          final isWide = c.maxWidth >= 600;
          final cols   = isWide ? 3 : 2;
          final w      = (c.maxWidth - 10 * (cols - 1)) / cols;
          return Wrap(spacing: 10, runSpacing: 10, children: [
            for (final k in alerts)
              SizedBox(width: w, child: shared_kpi.KpiCard(data: k)),
          ]);
        }),
      ]),
    );
  }
}

// ─── Header dashboard : titre + quick buttons + filtre ──────────────────────

class _DashboardHeader extends StatelessWidget {
  final String shopId;
  final String periodLabel;
  final VoidCallback onPeriodTap;

  const _DashboardHeader({
    required this.shopId,
    required this.periodLabel,
    required this.onPeriodTap,
  });

  @override
  Widget build(BuildContext context) {
    final l       = context.l10n;
    final theme   = Theme.of(context);
    final isMobile = MediaQuery.of(context).size.width < 600;
    // Prénom = premier mot du `name` du user courant. Avant cette fix le
    // dashboard affichait "James" en dur (placeholder oublié), ce qui
    // saluait *tous* les utilisateurs sous le même prénom. Si le profil
    // n'a pas de nom (sync pas encore terminée, fallback Supabase vide),
    // on tombe sur un message générique sans virgule.
    final fullName = LocalStorageService.getCurrentUser()?.name.trim() ?? '';
    final firstName = fullName.isEmpty
        ? ''
        : fullName.split(RegExp(r'\s+')).first;
    final greeting = firstName.isEmpty
        ? '${l.dashWelcome}.'
        : '${l.dashWelcome}, $firstName.';

    // Sur mobile : greeting 12px w500 + sous-titre "Aujourd'hui" 10px,
    // subtitle muted (spec round 9). Sur desktop : 17px w800 + sous-titre
    // long inchangé pour préserver la densité informationnelle.
    final greetSize    = isMobile ? 12.0 : 17.0;
    final greetWeight  = isMobile ? FontWeight.w500 : FontWeight.w800;
    final subSize      = isMobile ? 10.0 : 11.0;
    final subText      = isMobile ? l.periodToday : l.dashSubtitle;

    return Container(
      padding: EdgeInsets.fromLTRB(16, isMobile ? 10 : 14, 16, isMobile ? 10 : 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03),
            blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Ligne 1 : Titre + filtre période ───────────────────────
          Row(children: [
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(greeting,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: greetSize,
                        fontWeight: greetWeight,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(subText,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: subSize,
                        color: AppColors.textSecondary)),
              ],
            )),
            const SizedBox(width: 10),
            // Pill période
            GestureDetector(
              onTap: onPeriodTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.primary.withOpacity(0.3)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.calendar_today_rounded, size: 12,
                      color: AppColors.primary),
                  const SizedBox(width: 5),
                  Text(periodLabel,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                          color: AppColors.primary)),
                  const SizedBox(width: 3),
                  Icon(Icons.keyboard_arrow_down_rounded, size: 14,
                      color: AppColors.primary),
                ]),
              ),
            ),
          ]),

          SizedBox(height: isMobile ? 10 : 14),
          Divider(height: 1, color: theme.semantic.borderSubtle),
          SizedBox(height: isMobile ? 8 : 12),

          // ── Ligne 2 : Accès rapide ────────────────────────────────
          // Wrap content-sized (mobile + desktop) — chaque bouton à la
          // largeur de son contenu, padding horizontal 10 (cf. _HeaderQuickBtn).
          // Wrap retourne automatiquement à la ligne quand l'écran est étroit.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeaderQuickBtn(
                icon: Icons.point_of_sale_rounded,
                label: l.dashNewSale,
                color: AppColors.primary,
                onTap: () => context.go('/shop/$shopId/caisse'),
              ),
              _HeaderQuickBtn(
                icon: Icons.add_box_outlined,
                label: l.dashAddProduct,
                color: AppColors.secondary,
                onTap: () => context.push('/shop/$shopId/inventaire/product'),
              ),
              _HeaderQuickBtn(
                icon: Icons.person_add_rounded,
                label: l.dashAddClient,
                color: AppColors.info,
                onTap: () => context.go('/shop/$shopId/crm'),
              ),
              _HeaderQuickBtn(
                icon: Icons.bar_chart_rounded,
                label: l.dashViewReports,
                color: AppColors.warning,
                onTap: () => context.go('/shop/$shopId/finances'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderQuickBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _HeaderQuickBtn({required this.icon, required this.label,
    required this.color, required this.onTap});
  @override
  State<_HeaderQuickBtn> createState() => _HeaderQuickBtnState();
}

class _HeaderQuickBtnState extends State<_HeaderQuickBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // Padding différencié spec : 16h/8v desktop, 10h/8v mobile.
    // Boutons content-sized partout (Wrap parent, mainAxisSize.min interne)
    // — pas de SizedBox(width: infinity) ni d'Expanded, donc zéro stretch.
    final isMobile = MediaQuery.of(context).size.width < 600;
    final hPad = isMobile ? 10.0 : 16.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit:  (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 8),
          decoration: BoxDecoration(
            color: _hover
                ? widget.color.withOpacity(0.14)
                : widget.color.withOpacity(0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hover
                  ? widget.color.withOpacity(0.4)
                  : widget.color.withOpacity(0.15),
              width: 1,
            ),
          ),
          // mainAxisSize.min : le Row prend la largeur de son contenu
          // (icône + gap + label), pas plus. Combiné au Wrap parent qui
          // n'impose aucune contrainte de largeur, chaque bouton fait
          // exactement la taille de son contenu.
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 15, color: widget.color),
            const SizedBox(width: 6),
            Text(widget.label.replaceAll('\n', ' '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    color: widget.color)),
          ]),
        ),
      ),
    );
  }
}

// ─── Sélecteur de période ─────────────────────────────────────────────────────

class _PeriodPicker extends StatefulWidget {
  final String current;
  final DateTimeRange? customRange;
  final void Function(String) onPeriod;
  final void Function(DateTimeRange) onCustom;
  const _PeriodPicker({required this.current, required this.customRange,
    required this.onPeriod, required this.onCustom});
  @override State<_PeriodPicker> createState() => _PeriodPickerState();
}

class _PeriodPickerState extends State<_PeriodPicker> {
  bool _showCustom = false;
  DateTime _from = DateTime.now().subtract(const Duration(days: 7));
  DateTime _to   = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final periods = [
      ('today',     l.periodToday),
      ('yesterday', l.periodYesterday),
      ('week',      l.periodWeek),
      ('month',     l.periodMonth),
      ('year',      l.periodYear),
      ('custom',    l.periodCustom),
    ];

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 16, 20,
          MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 36, height: 4,
            decoration: BoxDecoration(color: AppColors.divider,
                borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        Text(l.periodCustomTitle,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: periods.map((p) {
          final active = widget.current == p.$1;
          return GestureDetector(
            onTap: () {
              if (p.$1 == 'custom') {
                setState(() => _showCustom = true);
              } else {
                widget.onPeriod(p.$1);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: active ? AppColors.primary : AppColors.inputFill,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(p.$2,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: active ? Colors.white : AppColors.textSecondary)),
            ),
          );
        }).toList()),

        if (_showCustom) ...[
          const SizedBox(height: 20),
          _DateRangePicker(
            from: _from, to: _to,
            onFromChanged: (d) => setState(() => _from = d),
            onToChanged:   (d) => setState(() => _to   = d),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity, height: 42,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => widget.onCustom(DateTimeRange(start: _from, end: _to)),
              child: Text(l.periodApply,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ]),
    );
  }
}

class _DateRangePicker extends StatelessWidget {
  final DateTime from, to;
  final ValueChanged<DateTime> onFromChanged, onToChanged;
  const _DateRangePicker({required this.from, required this.to,
    required this.onFromChanged, required this.onToChanged});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Row(children: [
      Expanded(child: _DateBtn(label: l.periodFrom, date: from,
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: from,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 3650)),
            );
            if (d != null) onFromChanged(d);
          })),
      const SizedBox(width: 12),
      Expanded(child: _DateBtn(label: l.periodTo, date: to,
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: to,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 3650)),
            );
            if (d != null) onToChanged(d);
          })),
    ]);
  }
}

class _DateBtn extends StatelessWidget {
  final String label;
  final DateTime date;
  final VoidCallback onTap;
  const _DateBtn({required this.label, required this.date, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(children: [
        Icon(Icons.calendar_today_outlined, size: 14, color: AppColors.primary),
        const SizedBox(width: 6),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 9, color: AppColors.textHint)),
          Text('${date.day}/${date.month}/${date.year}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
        ])),
      ]),
    ),
  );
}

// ─── Card "Résumé financier" ──────────────────────────────────────────────────
// CA − coût produits − pertes rebuts − coûts réparation − dépenses op. = net
// Barre de progression marge nette (couleur success du thème).

class _FinancialSummaryCard extends StatelessWidget {
  final DashData data;
  const _FinancialSummaryCard({required this.data});

  static String _fmt(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    // Coût produits = CA − bénéfice brut (Σ prix_revient)
    final productCost = (data.totalSales - data.totalProfit).clamp(0.0, double.infinity);
    final net = data.netProfit;
    final isPositive = net >= 0;

    // Spec round 9 : 3 lignes strictes — CA · Coût · Bénéfice. Les ex-
    // lignes scrappedLoss / repairCost / operatingExpenses + barre de
    // marge ont été retirées (inversion C3). Les détails restent
    // visibles dans la section Alertes (autres KPIs conditionnels).
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03),
            blurRadius: 4, offset: const Offset(0,2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.10),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(Icons.account_balance_rounded,
                size: 15, color: AppColors.primary),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(l.dashFinancialSummary,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary))),
        ]),
        const SizedBox(height: 12),
        _row(l.financesCA, '+${_fmt(data.totalSales)} XAF',
            AppColors.textPrimary),
        const SizedBox(height: 4),
        _row(l.dashProductCost, '−${_fmt(productCost)} XAF',
            AppColors.textSecondary),
        const SizedBox(height: 8),
        const Divider(height: 1, color: AppColors.divider),
        const SizedBox(height: 8),
        _row(l.dashNetProfit,
            '${isPositive ? '+' : ''}${_fmt(net)} XAF',
            isPositive ? AppColors.secondary : AppColors.error,
            bold: true),
      ]),
    );
  }

  Widget _row(String label, String value, Color valueColor, {bool bold = false}) =>
      Row(children: [
    Expanded(child: Text(label,
        maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: bold ? 12 : 10,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            color: bold ? AppColors.textPrimary : AppColors.textSecondary))),
    Text(value,
        maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: bold ? 13 : 10,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
            color: valueColor)),
  ]);
}

// ─── Graphique mini (barres custom) ──────────────────────────────────────────

class _SalesBarChart extends StatelessWidget {
  final List<double> sales;
  final List<double> profit;
  final List<double> expenses;
  final List<String> labels;
  final String period;
  final VoidCallback onPeriodTap;
  const _SalesBarChart({
    required this.sales,
    required this.profit,
    this.expenses = const [],
    required this.labels,
    required this.period,
    required this.onPeriodTap,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final salesColor    = AppColors.primary;     // primaire (palette active)
    final profitColor   = AppColors.secondary;   // vert "success" du thème
    final expensesColor = AppColors.error; // rouge "dépenses"
    final allValues = [...sales, ...profit, ...expenses];
    final maxVal = allValues.fold<double>(0, (m, v) => v > m ? v : m);
    final chartMax = maxVal == 0 ? 1.0 : maxVal * 1.15;

    // Détecter si la série dépenses contient au moins une valeur > 0 pour
    // décider d'afficher un 3ᵉ rod par bucket (sinon garder le look à 2 barres).
    final hasExpenses = expenses.any((v) => v > 0);

    // Largeur de chaque rod (barre) et espacement entre rods d'un groupe.
    final bucketCount = sales.length;
    final baseWidth = bucketCount > 20 ? 4.0
        : bucketCount > 10 ? 7.0
        : 10.0;
    // Réduire légèrement la largeur si on affiche 3 barres au lieu de 2
    final rodWidth = hasExpenses ? baseWidth * 0.85 : baseWidth;

    return _DashCard(child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text(l.dashSalesOverview,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary))),
          GestureDetector(
            onTap: onPeriodTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(
                  period == 'today' ? l.periodToday
                      : period == 'week' ? l.periodWeek
                      : period == 'month' ? l.periodMonth
                      : period == 'year' ? l.periodYear
                      : period == 'yesterday' ? l.periodYesterday
                      : l.periodCustom,
                  style: const TextStyle(fontSize: 10, color: Colors.white,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down_rounded,
                    size: 14, color: Colors.white),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 8),

        // Légende
        Wrap(spacing: 14, runSpacing: 6, children: [
          _LegendDot(color: salesColor,  label: l.dashChartSales),
          _LegendDot(color: profitColor, label: l.dashChartProfit),
          if (hasExpenses)
            _LegendDot(color: expensesColor, label: l.dashOperatingExpenses),
        ]),
        const SizedBox(height: 12),

        // Graphique barres groupées
        SizedBox(
          height: 180,
          child: maxVal == 0
              ? const _EmptyChart()
              : BarChart(
                  BarChartData(
                    maxY: chartMax,
                    alignment: BarChartAlignment.spaceAround,
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: chartMax / 4,
                      getDrawingHorizontalLine: (_) => const FlLine(
                        color: AppColors.inputFill,
                        strokeWidth: 1,
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 38,
                          interval: chartMax / 4,
                          getTitlesWidget: (v, _) => Text(
                            _compact(v),
                            style: const TextStyle(
                                fontSize: 9, color: AppColors.textHint),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 22,
                          interval: (labels.length / 6).ceilToDouble()
                              .clamp(1, labels.length.toDouble()),
                          getTitlesWidget: (v, _) {
                            final i = v.toInt();
                            if (i < 0 || i >= labels.length) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(labels[i],
                                  style: const TextStyle(
                                      fontSize: 9,
                                      color: AppColors.textHint)),
                            );
                          },
                        ),
                      ),
                    ),
                    barTouchData: BarTouchData(
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => AppColors.textPrimary,
                        tooltipRoundedRadius: 8,
                        tooltipPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        getTooltipItem: (group, gi, rod, ri) {
                          final name = ri == 0
                              ? l.dashChartSales
                              : ri == 1
                                  ? l.dashChartProfit
                                  : l.dashOperatingExpenses;
                          return BarTooltipItem(
                            '$name : ${_compact(rod.toY)}',
                            TextStyle(
                                color: rod.color ?? Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700),
                          );
                        },
                      ),
                    ),
                    barGroups: [
                      for (int i = 0; i < sales.length; i++)
                        BarChartGroupData(
                          x: i,
                          barsSpace: 2,
                          barRods: [
                            BarChartRodData(
                              toY: sales[i],
                              color: salesColor,
                              width: rodWidth,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3)),
                            ),
                            BarChartRodData(
                              toY: i < profit.length ? profit[i] : 0,
                              color: profitColor,
                              width: rodWidth,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3)),
                            ),
                            if (hasExpenses)
                              BarChartRodData(
                                toY: i < expenses.length ? expenses[i] : 0,
                                color: expensesColor,
                                width: rodWidth,
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(3)),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
        ),
      ],
    ));
  }

  static String _compact(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
        ],
      );
}

class _EmptyChart extends StatelessWidget {
  const _EmptyChart();
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.show_chart_rounded,
                size: 32, color: Theme.of(context).semantic.borderSubtle),
            const SizedBox(height: 6),
            Text(
              context.l10n.dashNoSalesYet,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textHint),
            ),
          ],
        ),
      );
}

// ─── Top produits ─────────────────────────────────────────────────────────────

class _TopProductsCard extends StatelessWidget {
  final List<TopProd> products;
  final String shopId;
  const _TopProductsCard({required this.products, required this.shopId});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final maxQty = products.isEmpty
        ? 1
        : products.map((p) => p.qty).reduce((a, b) => a > b ? a : b);

    return _DashCard(child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardHeader(
            title: l.dashTopProducts,
            action: l.dashViewAll,
            onAction: () => context.go('/shop/$shopId/finances')),
        const SizedBox(height: 12),
        if (products.isEmpty)
          _DashEmpty(
            icon: Icons.bar_chart_rounded,
            label: l.dashNoSalesYet,
          )
        else
          ...products.asMap().entries.map((e) {
            final i = e.key;
            final p = e.value;
            final ratio = (p.qty / maxQty).clamp(0.05, 1.0);
            // Couleurs médailles pour les 3 premiers : or / argent / bronze.
            // Au-delà : primaire du thème (palette active).
            final medalColors = [
              AppColors.warning,              // 1er — or (warning = amber)
              AppColors.textSecondary,        // 2e — argent (grey)
              Colors.brown.shade600,          // 3e — bronze (Material constant,
                                              // pas Color(0xFF…) pour respecter
                                              // la règle « zéro Color hardcodé »).
            ];
            final medalColor = i < 3 ? medalColors[i] : AppColors.primary;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                // ── Badge rang (#1, #2, …) ──────────────────────────
                Container(
                  width: 24, height: 24,
                  decoration: BoxDecoration(
                    color: medalColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Text('${i + 1}',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: medalColor)),
                ),
                const SizedBox(width: 8),
                // ── Thumbnail produit (image ou placeholder) ────────
                _TopProductThumb(imageUrl: p.imageUrl),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      const SizedBox(height: 3),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 4,
                          backgroundColor: AppColors.inputFill,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.primary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${p.qty}',
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary)),
                    Text('${p.revenue.toStringAsFixed(0)} XAF',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary)),
                  ],
                ),
              ]),
            );
          }),
      ],
    ));
  }
}

// ─── Thumbnail d'un top produit ─────────────────────────────────────────────

class _TopProductThumb extends StatelessWidget {
  final String? imageUrl;
  const _TopProductThumb({this.imageUrl});

  Widget _placeholder() => Container(
    width: 30, height: 30,
    decoration: BoxDecoration(
      color: AppColors.primarySurface,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Icon(Icons.inventory_2_rounded,
        size: 14, color: AppColors.primary.withOpacity(0.6)),
  );

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url == null || url.isEmpty) return _placeholder();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(width: 30, height: 30,
        child: url.startsWith('http')
            ? Image.network(url, fit: BoxFit.cover,
                cacheWidth: 60, errorBuilder: (_, __, ___) => _placeholder())
            : Image.file(File(url), fit: BoxFit.cover,
                cacheWidth: 60, errorBuilder: (_, __, ___) => _placeholder()),
      ),
    );
  }
}

// ─── Transactions récentes ────────────────────────────────────────────────────

class _RecentTxCard extends StatelessWidget {
  final List<RecentTx> transactions;
  final String shopId;
  const _RecentTxCard({required this.transactions, required this.shopId});

  /// 2 premières lettres du nom client (ou "—" si absent)
  String _initials(String? name) {
    final n = (name ?? '').trim();
    if (n.isEmpty) return '—';
    final parts = n.split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[1].isNotEmpty) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return n.length >= 2
        ? n.substring(0, 2).toUpperCase()
        : n[0].toUpperCase();
  }

  ({Color color, String label}) _statusOf(AppLocalizations l, String status) {
    switch (status) {
      case 'refunded':
      case 'cancelled':
      case 'refused':
        return (color: AppColors.error, label: l.dashCancelled);
      case 'pending':
      case 'processing':
      case 'scheduled':
        return (color: AppColors.warning, label: l.dashPending);
      default:
        return (color: AppColors.secondary, label: l.dashCompleted);
    }
  }

  String _timeAgo(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 60) return '${diff.inMinutes}min';
    if (diff.inHours < 24)   return '${diff.inHours}h';
    if (diff.inDays < 7)     return '${diff.inDays}j';
    return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return _DashCard(child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardHeader(title: l.dashRecentTx, action: l.dashViewAll,
            onAction: () => context.go('/shop/$shopId/finances')),
        const SizedBox(height: 8),
        if (transactions.isEmpty)
          _DashEmpty(
            icon: Icons.receipt_long_outlined,
            label: l.dashNoSalesYet,
          )
        else
          ...transactions.map((t) {
            final s = _statusOf(l, t.status);
            final isLoss = t.status == 'refunded' ||
                t.status == 'cancelled' ||
                t.status == 'refused';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                // ── Avatar initiales client ─────────────────────────
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  alignment: Alignment.center,
                  child: Text(_initials(t.clientName),
                      style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Nom client + badge statut
                      Row(children: [
                        Expanded(child: Text(
                            t.clientName ?? l.dashUnknownClient,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary))),
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: s.color.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(s.label,
                              style: TextStyle(fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: s.color)),
                        ),
                      ]),
                      // Produit principal + qty · temps écoulé
                      const SizedBox(height: 1),
                      Text(
                        t.mainProduct != null
                            ? (t.itemCount > 1
                                ? '${t.mainProduct} ×${t.mainQty} '
                                    '+${t.itemCount - 1} · ${_timeAgo(t.createdAt)}'
                                : '${t.mainProduct} ×${t.mainQty} '
                                    '· ${_timeAgo(t.createdAt)}')
                            : _timeAgo(t.createdAt),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10, color: AppColors.textHint),
                      ),
                    ],
                  ),
                ),
                // Montant à droite
                Text('${t.amount.toStringAsFixed(0)} XAF',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isLoss
                            ? AppColors.error
                            : AppColors.primary)),
              ]),
            );
          }),
      ],
    ));
  }
}

// ─── Alertes inventaire ───────────────────────────────────────────────────────

class _InventoryAlertsCard extends StatelessWidget {
  final List<Product> alerts;
  final String shopId;
  const _InventoryAlertsCard({required this.alerts, required this.shopId});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return _DashCard(child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardHeader(title: l.dashInventoryAlerts, action: l.dashManageInventory,
            onAction: () => context.go('/shop/$shopId/inventaire')),
        const SizedBox(height: 8),
        if (alerts.isEmpty)
          _DashEmpty(
            icon: Icons.check_circle_outline_rounded,
            label: l.dashStockOk,
          )
        else
          ...alerts.take(5).map((p) {
            final stock     = p.totalStock;
            final threshold = p.stockMinAlert > 0 ? p.stockMinAlert : 1;
            final ratio     = (stock / threshold).clamp(0.0, 1.0);
            final pct       = (stock / threshold * 100)
                .clamp(0.0, 999.0);
            final critical  = stock <= 0;
            final color     = critical ? AppColors.error : AppColors.warning;

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: color.withOpacity(0.35)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Icon(
                    critical
                        ? Icons.error_outline
                        : Icons.warning_amber_rounded,
                    size: 16, color: color,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                        Text(
                          '$stock / $threshold ${l.dashUnitsLeft}',
                          style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () => context.push(
                        '/shop/$shopId/inventaire/product',
                        extra: p),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(l.dashReorderNow,
                          style: const TextStyle(
                              fontSize: 9,
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                // ── Barre de progression : stock actuel / seuil ────────
                Row(children: [
                  Expanded(child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 5,
                      backgroundColor: color.withOpacity(0.15),
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  )),
                  const SizedBox(width: 6),
                  Text('${pct.toStringAsFixed(0)}%',
                      style: TextStyle(fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: color)),
                ]),
              ]),
            );
          }),
      ],
    ));
  }
}

// Composant empty state réutilisable pour les cards du dashboard
class _DashEmpty extends StatelessWidget {
  final IconData icon;
  final String label;
  const _DashEmpty({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 22),
        alignment: Alignment.center,
        child: Column(children: [
          Icon(icon, size: 28, color: AppColors.textHint),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textHint)),
        ]),
      );
}

// ─── _TwoColWrap — Row sur desktop, Column sur mobile, sans overflow ───────────

class _TwoColWrap extends StatelessWidget {
  final Widget first, second;
  final int firstFlex, secondFlex;
  /// Largeur min en dessous de laquelle on passe en colonne
  final double minSecondWidth;

  const _TwoColWrap({
    required this.first, required this.second,
    required this.firstFlex, required this.secondFlex,
    this.minSecondWidth = 200,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final total     = constraints.maxWidth;
      final totalFlex = firstFlex + secondFlex;
      final secondW   = total * secondFlex / totalFlex;

      // Passer en colonne si le second panneau serait trop petit
      if (secondW < minSecondWidth) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 14), second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: firstFlex, child: first),
          const SizedBox(width: 14),
          Expanded(flex: secondFlex, child: second),
        ],
      );
    });
  }
}

// ─── Widgets réutilisables ────────────────────────────────────────────────────

class _DashCard extends StatelessWidget {
  final Widget child;
  const _DashCard({required this.child});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.divider),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03),
          blurRadius: 5, offset: const Offset(0,2))],
    ),
    child: child,
  );
}

class _CardHeader extends StatelessWidget {
  final String title, action;
  final VoidCallback onAction;
  const _CardHeader({required this.title, required this.action,
    required this.onAction});
  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Text(title, style: const TextStyle(fontSize: 13,
        fontWeight: FontWeight.w700, color: AppColors.textPrimary))),
    GestureDetector(onTap: onAction,
        child: Text(action, style: TextStyle(fontSize: 11,
            fontWeight: FontWeight.w600, color: AppColors.primary))),
  ]);
}


// ─── Sélecteur de boutique active ────────────────────────────────────────────

// ─── Nouveaux produits (< 72h) ───────────────────────────────────────────────

class _NewProductsCard extends StatelessWidget {
  final List<Product> products;
  final String shopId;
  const _NewProductsCard({required this.products, required this.shopId});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return _DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: AppColors.secondary.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.new_releases_rounded,
                  size: 16, color: AppColors.secondary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.dashNewProducts,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  Text(l.dashNewProductsHint,
                      style: const TextStyle(
                          fontSize: 10, color: AppColors.textHint)),
                ],
              ),
            ),
            if (products.isNotEmpty)
              // Bouton global "Partager (N)" — ouvre le dialog catalogue
              // pré-rempli avec tous les nouveaux produits.
              GestureDetector(
                onTap: () => ShareCatalogDialog.show(context,
                    products: products, shopId: shopId,
                    preSelected: products),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.primary.withOpacity(0.2)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.share_rounded, size: 12,
                        color: AppColors.primary),
                    const SizedBox(width: 5),
                    Text('${l.dashShareAction} (${products.length})',
                        style: TextStyle(fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary)),
                  ]),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          if (products.isEmpty)
            _NewProductsEmpty(message: l.dashNoNewProducts)
          else
            ...products.take(5).map((p) => _NewProductRow(product: p)),
          if (products.length > 5) ...[
            const SizedBox(height: 6),
            Center(
              child: GestureDetector(
                onTap: () => context.push('/shop/$shopId/inventaire'),
                child: Text(l.dashViewAll,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NewProductsEmpty extends StatelessWidget {
  final String message;
  const _NewProductsEmpty({required this.message});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        alignment: Alignment.center,
        child: Column(
          children: [
            const Icon(Icons.inventory_2_outlined,
                size: 28, color: AppColors.textHint),
            const SizedBox(height: 6),
            Text(message,
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textHint)),
          ],
        ),
      );
}

class _NewProductRow extends StatelessWidget {
  final Product product;
  const _NewProductRow({required this.product});

  String _ago(BuildContext context, DateTime createdAt) {
    final l = context.l10n;
    final diff = DateTime.now().difference(createdAt);
    if (diff.inMinutes < 60) {
      return '${l.dashAddedAgo} ${diff.inMinutes}min';
    }
    if (diff.inHours < 24) {
      return '${l.dashAddedAgo} ${diff.inHours}h';
    }
    return '${l.dashAddedAgo} ${diff.inDays}j';
  }

  @override
  Widget build(BuildContext context) {
    final l   = context.l10n;
    final img = product.mainImageUrl;
    final variantCount = product.variants.length;
    final hasVariants  = variantCount > 1; // "1 variante" = variante de base seule
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: AppColors.inputFill,
            borderRadius: BorderRadius.circular(8),
            image: (img != null && img.isNotEmpty)
                ? DecorationImage(
                    image: NetworkImage(img), fit: BoxFit.cover)
                : null,
          ),
          child: (img == null || img.isEmpty)
              ? const Icon(Icons.inventory_2_rounded,
                  size: 16, color: AppColors.textHint)
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 1),
              Row(children: [
                // Nombre de variantes si > 1
                if (hasVariants) ...[
                  Icon(Icons.layers_outlined, size: 10,
                      color: AppColors.primary.withOpacity(0.7)),
                  const SizedBox(width: 3),
                  Text(l.dashVariantCount(variantCount),
                      style: TextStyle(fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary.withOpacity(0.8))),
                  const SizedBox(width: 6),
                  Container(width: 2, height: 2,
                      decoration: const BoxDecoration(
                          color: AppColors.textHint,
                          shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                ],
                // Date ajout
                Text(
                  product.createdAt != null
                      ? _ago(context, product.createdAt!)
                      : '',
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.textHint),
                ),
              ]),
            ],
          ),
        ),
        Text('${product.priceSellPos.toStringAsFixed(0)} XAF',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.secondary)),
        const SizedBox(width: 6),
        // Bouton partager individuel
        GestureDetector(
          onTap: () => DocumentService.shareProduct(
              product, shopId: product.storeId),
          child: Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(Icons.share_outlined, size: 14,
                color: AppColors.primary),
          ),
        ),
      ]),
    );
  }
}

class _ShopSwitcherBanner extends ConsumerStatefulWidget {
  final String shopId;
  const _ShopSwitcherBanner({required this.shopId});
  @override
  ConsumerState<_ShopSwitcherBanner> createState() => _ShopSwitcherBannerState();
}

class _ShopSwitcherBannerState extends ConsumerState<_ShopSwitcherBanner> {

  @override
  void initState() {
    super.initState();
    // Différer la modification du provider APRÈS la construction du widget tree
    Future(() => _syncOnMount());
  }

  Future<void> _syncOnMount() async {
    if (!mounted) return;

    final userId = LocalStorageService.getCurrentUser()?.id ?? '';

    // Chercher la boutique dans l'ordre : provider → myShops → Hive → Supabase
    ShopSummary? shop = ref.read(currentShopProvider)?.id == widget.shopId
        ? ref.read(currentShopProvider)
        : ref.read(myShopsProvider).where((s) => s.id == widget.shopId).firstOrNull
        ?? LocalStorageService.getShop(widget.shopId);

    // Toujours introuvable → charger depuis Supabase
    if (shop == null) {
      try {
        final loaded = await AppDatabase.getMyShops();
        if (!mounted) return;
        if (loaded.isNotEmpty) {
          ref.read(myShopsProvider.notifier)
              .setFromSupabase(loaded, userId: userId);
          shop = loaded.where((s) => s.id == widget.shopId).firstOrNull;
        }
      } catch (e) {
        debugPrint('[Dashboard] getMyShops: $e');
      }
    }

    // Toujours mettre à jour le provider (même si déjà chargé)
    // pour s'assurer que currentShopProvider.state == boutique de l'URL
    if (shop != null && mounted) {
      ref.read(currentShopProvider.notifier).setShop(shop);
      debugPrint('[Dashboard] boutique: ${shop.name}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentShop = ref.watch(currentShopProvider);
    final allShops    = ref.watch(myShopsProvider);
    final l           = context.l10n;

    // Boutique active = celle de l'URL (widget.shopId) en priorité absolue
    final activeShop =
        allShops.where((s) => s.id == widget.shopId).firstOrNull
            ?? (currentShop?.id == widget.shopId ? currentShop : null)
            ?? LocalStorageService.getShop(widget.shopId)
            ?? currentShop;

    final shopName   = activeShop?.name ?? widget.shopId;
    final sectorIcon = _sectorIcon(activeShop?.sector ?? 'retail');
    // S'assurer que la boutique courante est dans la liste
    final allShopsWithCurrent = activeShop != null && !allShops.any((s) => s.id == activeShop.id)
        ? [...allShops, activeShop]
        : allShops;
    final hasMany = allShopsWithCurrent.length > 1;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.03),
              blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: AppColors.primarySurface,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(sectorIcon, size: 18, color: AppColors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.dashActiveShop,
                style: const TextStyle(fontSize: 10, color: AppColors.textHint)),
            Text(shopName,
                style: const TextStyle(fontSize: 14,
                    fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        )),
        // Boutons — toujours visibles
        Row(mainAxisSize: MainAxisSize.min, children: [
          _ActionChip(
            icon: hasMany ? Icons.swap_horiz_rounded : Icons.store_rounded,
            label: hasMany ? l.dashChangeShop : l.dashManageShops,
            onTap: hasMany
                ? () => _showShopPicker(context, allShopsWithCurrent)
                : () => context.go(RouteNames.shopSelector),
          ),
          const SizedBox(width: 8),
          _ActionChip(
            icon: Icons.add_rounded,
            label: l.dashNewShop,
            onTap: () => context.push(RouteNames.createShop),
            primary: true,
          ),
        ]),
      ]),
    );
  }

  void _showShopPicker(BuildContext context, List<ShopSummary> shops) {
    // Source de vérité : currentShopProvider, pas l'URL
    final activeId = ref.read(currentShopProvider)?.id ?? widget.shopId;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _ShopPickerSheet(
        shops: shops,
        activeShopId: activeId,
        onSelect: (shop) {
          ref.read(currentShopProvider.notifier).setShop(shop);
          Navigator.of(ctx).pop();
          context.go('/shop/${shop.id}/dashboard');
        },
      ),
    );
  }

  IconData _sectorIcon(String sector) => switch (sector) {
    'restaurant'  => Icons.restaurant_rounded,
    'supermarche' => Icons.local_grocery_store_rounded,
    'pharmacie'   => Icons.local_pharmacy_rounded,
    _             => Icons.storefront_rounded,
  };
}

// ─── Chip d'action ────────────────────────────────────────────────────────────

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  const _ActionChip({
    required this.icon, required this.label, required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: primary ? AppColors.primary : AppColors.inputFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13,
            color: primary ? Colors.white : AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600,
                color: primary ? Colors.white : AppColors.textSecondary)),
      ]),
    ),
  );
}

// ─── Bottom sheet sélection boutique ─────────────────────────────────────────

class _ShopPickerSheet extends StatelessWidget {
  final List<ShopSummary> shops;
  final String activeShopId;
  final void Function(ShopSummary) onSelect;
  const _ShopPickerSheet({
    required this.shops, required this.activeShopId, required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Poignée
        Container(
          width: 36, height: 4,
          decoration: BoxDecoration(
            color: AppColors.divider,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 16),
        Text(context.l10n.dashChooseShop,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        const SizedBox(height: 16),
        ...shops.map((shop) {
          final isActive = shop.id == activeShopId;
          return GestureDetector(
            onTap: isActive ? null : () => onSelect(shop),
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.primarySurface
                    : AppColors.inputFill,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isActive
                      ? AppColors.primary.withOpacity(0.4)
                      : AppColors.divider,
                  width: isActive ? 1.5 : 1,
                ),
              ),
              child: Row(children: [
                Icon(Icons.storefront_rounded,
                    size: 18,
                    color: isActive
                        ? AppColors.primary
                        : AppColors.textSecondary),
                const SizedBox(width: 12),
                Expanded(child: Text(shop.name,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: isActive
                            ? FontWeight.w700 : FontWeight.w500,
                        color: isActive
                            ? AppColors.primary
                            : AppColors.textPrimary))),
                if (isActive)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(context.l10n.dashShopActive,
                        style: TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w600,
                            color: AppColors.primary)),
                  ),
              ]),
            ),
          );
        }),
      ]),
    );
  }
}