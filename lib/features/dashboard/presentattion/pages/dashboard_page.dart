import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../shared/widgets/kpi_card.dart' as shared_kpi;
import '../../../../shared/widgets/view_filter_chip_bar.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../../inventaire/domain/stock_at_location.dart' as stock_loc;
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../../../../core/database/app_database.dart';
import '../../../../core/services/onboarding_tour_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../data/dashboard_providers.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/document_service.dart';
import '../../../inventaire/presentation/widgets/share_catalog_dialog.dart';
import '../widgets/partner_debts_banner.dart';
import '../../../onboarding/presentation/widgets/email_confirm_banner.dart';
import '../../../onboarding/presentation/widgets/activation_checklist_card.dart';
import '../../../onboarding/presentation/widgets/j1_resume_banner.dart';
import '../../../onboarding/presentation/widgets/trial_end_banner.dart';
import '../../../onboarding/presentation/widgets/trial_status_banner.dart';
import '../../../../shared/widgets/broadcast_banner.dart';
import 'package:intl/intl.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../../../shared/widgets/offline_banner_widget.dart' show isOfflineProvider;
import '../../../../core/permisions/app_permissions.dart';


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
      if (!mounted) return;
      ref.read(dashSignalProvider.notifier).state++;
      // Tour d'onboarding 5 étapes au premier login self-service (canvas
      // Sprint 2.3). No-op si le flag `onboarding_done_<uid>` est set.
      // Délai léger pour laisser le shell finir de painter (sinon le
      // modal s'ouvre AVANT que la sidebar/drawer ait son layout — UX
      // de fond noir trop brusque).
      Future.delayed(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        final uid =
            Supabase.instance.client.auth.currentUser?.id ?? '';
        // Le tour décrit l'Inventaire et la gestion produits (écrans réservés
        // aux admins/owners). Un employé ne les voit pas → pas de tour pour
        // lui (sinon il pointe vers une nav inexistante pour son rôle).
        if (!ref.read(permissionsProvider(widget.shopId)).isShopAdmin) return;
        OnboardingTourService.showIfFirstLogin(context, uid, widget.shopId);
      });
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

  String _fmtNum(double v) => CurrencyFormatter.compact(v);

  void _showPeriodPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
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
    // Rebuild le dashboard quand la devise change (cf. CurrencyFormatter).
    // Le ValueListenableBuilder regénère tout l'arbre dès que l'utilisateur
    // sélectionne une nouvelle devise dans Paramètres.
    return ValueListenableBuilder<String>(
      valueListenable: CurrencyFormatter.notifier,
      builder: (_, __, ___) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final l = context.l10n;
    final data = ref.watch(dashDataProvider(widget.shopId));
    final perms = ref.watch(permissionsProvider(widget.shopId));
    final fr    = Localizations.localeOf(context).languageCode == 'fr';

    // Tendance du CA vs la période précédente de même durée (« hier » quand la
    // période est « Aujourd'hui »). Le calcul de la période précédente ne
    // filtre pas « mes ventes » : pour un vendeur, la comparaison serait
    // fausse → tendance masquée. Admin / propriétaire : même périmètre des
    // deux côtés.
    final sameScope = perms.isAdmin || perms.isOwner;
    final prevSales = sameScope
        ? ref.watch(financesPreviousSnapshotProvider(widget.shopId)).totalSales
        : 0.0;
    final caTrend = prevSales > 0
        ? (data.totalSales - prevSales) / prevSales * 100
        : null;
    final lowStockCount = data.lowStock.length;

    // KPIs prioritaires : CA · Ventes · Stock en alerte · Clients servis —
    // grille 2×2 sur mobile / 4 colonnes sur desktop via _PriorityKpiGrid.
    // Le bénéfice net reste dans le résumé financier plus bas.
    final shopId = widget.shopId;
    final priorityKpis = <shared_kpi.KpiData>[
      shared_kpi.KpiData(
        label: fr ? 'CA' : 'Revenue',
        value: _fmtNum(data.totalSales), unit: CurrencyFormatter.currentSymbol,
        icon: Icons.trending_up,
        color: AppColors.secondary,
        delta: caTrend == null ? ''
            : '${caTrend >= 0 ? '+' : ''}${caTrend.toStringAsFixed(0)}%',
        positive: (caTrend ?? 0) >= 0,
        subtext: caTrend == null ? ''
            : (_period == 'today'
                ? (fr ? 'vs hier' : 'vs yesterday')
                : (fr ? 'vs période préc.' : 'vs prev. period')),
        onTap: () => context.push('/shop/$shopId/finances'),
      ),
      shared_kpi.KpiData(
        label: fr ? 'Ventes' : 'Sales',
        value: data.orderCount.toString(),
        icon: Icons.receipt_long_rounded,
        color: AppColors.info,
        onTap: () => context.push('/shop/$shopId/caisse'),
      ),
      shared_kpi.KpiData(
        label: fr ? 'Stock en alerte' : 'Low stock',
        value: lowStockCount.toString(),
        icon: Icons.inventory_2_rounded,
        color: lowStockCount > 0 ? AppColors.warning : AppColors.secondary,
        // Stock réservé aux admins (même règle que le menu) : pas de lien
        // vers un écran que le compte ne peut pas ouvrir.
        onTap: (perms.isShopAdmin && perms.canViewProducts)
            ? () => context.push('/shop/$shopId/inventaire')
            : null,
      ),
      shared_kpi.KpiData(
        // Clients distincts servis sur la période (pas le total CRM).
        label: fr ? 'Clients servis' : 'Clients served',
        value: data.clientCount.toString(),
        icon: Icons.people_rounded,
        color: AppColors.warning,
        onTap: () => context.push('/shop/$shopId/crm'),
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
          value: _fmtNum(data.scrappedLoss), unit: CurrencyFormatter.currentSymbol,
          icon: Icons.delete_forever_rounded,
          color: AppColors.error,
          errorIndicator: true,
          onTap: () => context.push('/shop/$shopId/finances'),
        ),
      if (data.repairCost > 0)
        shared_kpi.KpiData(
          label: l.dashRepairCost,
          value: _fmtNum(data.repairCost), unit: CurrencyFormatter.currentSymbol,
          icon: Icons.build_rounded,
          color: AppColors.warning,
        ),
      if (data.totalLoss > 0)
        shared_kpi.KpiData(
          label: l.dashLoss,
          value: _fmtNum(data.totalLoss), unit: CurrencyFormatter.currentSymbol,
          icon: Icons.trending_down_rounded,
          color: AppColors.error,
          errorIndicator: true,
          onTap: () => context.push('/shop/$shopId/finances'),
        ),
      if (data.operatingExpenses > 0)
        shared_kpi.KpiData(
          label: l.dashExpenses,
          value: _fmtNum(data.operatingExpenses), unit: CurrencyFormatter.currentSymbol,
          icon: Icons.account_balance_wallet_rounded,
          color: AppColors.error,
          errorIndicator: true,
          onTap: () => context.push('/shop/$shopId/finances'),
        ),
      // Créances clients — solde dû sur les ventes à crédit complétées de la
      // période. Tap → liste des commandes (pour encaisser le reste).
      if (data.totalClientDebts > 0)
        shared_kpi.KpiData(
          label: 'Créances clients',
          value: _fmtNum(data.totalClientDebts),
          unit: CurrencyFormatter.currentSymbol,
          icon: Icons.account_balance_wallet_rounded,
          color: AppColors.warning,
          errorIndicator: true,
          onTap: () => context.push('/shop/$shopId/caisse/orders'),
        ),
    ];

    final curShop  = ref.watch(currentShopProvider);
    final shopName = ((curShop != null && curShop.id == shopId)
        ? curShop : LocalStorageService.getShop(shopId))?.name ?? '';
    // Même source que la puce hors-ligne de la barre du haut.
    final isOnline = !ref.watch(isOfflineProvider)
        .maybeWhen(data: (v) => v, orElse: () => false);

    return ListView(
      // Défilable même quand le contenu tient à l'écran : sans ça, le geste
      // « tirer pour actualiser » du cadre ne se déclenche pas.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        // ── 1. Identité boutique ──────────────────────────────────────────
        _ShopIdentityCard(name: shopName, isOnline: isOnline),
        const SizedBox(height: 12),

        // ── 2. Salutation + date + période (sélecteur existant déplacé) ───
        _WelcomeBar(
          periodLabel: _periodLabel(l),
          onPeriodTap: () => _showPeriodPicker(context),
        ),
        const SizedBox(height: 12),

        // ── 3. Nouvelle commande en 1 tap ─────────────────────────────────
        if (perms.canAccessCaisse) ...[
          _NewOrderButton(onTap: () => context.go('/shop/$shopId/caisse')),
          const SizedBox(height: 14),
        ],

        // ── 4. KPI Cards prioritaires (2×2 mobile / 4 cols desktop) ───────
        _PriorityKpiGrid(kpis: priorityKpis),
        const SizedBox(height: 14),

        // ── 5. Accès rapides (grille 2×2) ─────────────────────────────────
        _QuickAccessGrid(shopId: widget.shopId, perms: perms),
        const SizedBox(height: 14),

        // ── 6. Ventes récentes (5 dernières, toutes dates) ────────────────
        _RecentTxCard(transactions: data.recentTx, shopId: widget.shopId),
        const SizedBox(height: 14),

        // ── Blocs existants, inchangés, SOUS les nouveaux modules ─────────

        // ── Onboarding bannières (PR-1 / PR-2 / PR-3) ────────────────────
        // Toutes les widgets sont self-gated (SizedBox.shrink() s'ils ne
        // doivent pas s'afficher) → safe à inclure inconditionnellement.
        //   • EmailConfirmBanner : tant que email_confirmed_at est null.
        //   • TrialStatusBanner  : si plan=trial && daysLeft>2 (info doux).
        //   • TrialEndBanner     : si plan=trial && daysLeft<=2 (warning).
        //   • J1ResumeBanner     : 1×/jour si ventes hier.
        //   • ActivationChecklistCard : 4 étapes onboarding (disparaît
        //     quand tout coché).
        const EmailConfirmBanner(margin: EdgeInsets.only(bottom: 12)),
        const TrialStatusBanner(),
        const TrialEndBanner(),
        BroadcastBanner(shopId: widget.shopId),
        J1ResumeBanner(shopId: widget.shopId),
        ActivationChecklistCard(shopId: widget.shopId),
        const SizedBox(height: 12),

        // ── Sélecteur de vue (Global / Boutique seule / Par partenaire) ───
        // Le switch entre boutiques principales se fait désormais depuis le
        // Hub central (drawer → Hub). Ici c'est uniquement le filtre de
        // périmètre à l'intérieur de la boutique courante.
        ViewFilterChipBar(shopId: widget.shopId, useTabs: true),
        const SizedBox(height: 12),

        // ── Section Alertes (visible seulement si non-vide) ───────────────
        if (alertKpis.isNotEmpty) ...[
          _AlertsSection(alerts: alertKpis),
          const SizedBox(height: 14),
        ],

        // ── Bandeau "ce que vos partenaires vous doivent" (cf. hotfix_065
        // + partner_ledger). Self-hide si aucun partenaire n'a de solde
        // positif. Tap → page Comptes partenaires.
        PartnerDebtsBanner(shopId: widget.shopId),

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

        // ── Alertes stock (bloc existant, inchangé) ───────────────────────
        // Les ventes récentes, qui partageaient cette rangée, sont remontées
        // en module 6.
        _InventoryAlertsCard(alerts: data.lowStock, shopId: widget.shopId),
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
              color: theme.semantic.warning.withValues(alpha:0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(Icons.notifications_active_rounded,
                size: 14, color: theme.semantic.warning),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(l.dashAlertsTitle,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyBold.copyWith(
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

// ─── Accès rapides (grille 2×2) ──────────────────────────────────────────────

/// Accès rapides : 4 modules fréquents en 1 tap. Une carte n'apparaît que si
/// le compte a le droit correspondant (mêmes règles que le menu).
/// Sous-titres lus sur les données locales existantes (produits non
/// supprimés, clients non archivés) — aucune requête nouvelle.
class _QuickAccessGrid extends StatelessWidget {
  final String shopId;
  final AppPermissions perms;
  const _QuickAccessGrid({required this.shopId, required this.perms});

  @override
  Widget build(BuildContext context) {
    final fr = Localizations.localeOf(context).languageCode == 'fr';
    final nProducts = LocalStorageService.getProductsForShop(shopId).length;
    final nClients  = AppDatabase.getClientsForShop(shopId).length;
    String plural(int n, String one) => '$n $one${n > 1 ? 's' : ''}';
    final cards = <_QuickCard>[
      if (perms.canAccessCaisse)
        _QuickCard(icon: Icons.shopping_cart_outlined,
            label: fr ? 'Caisse' : 'Checkout',
            sublabel: fr ? 'Vente rapide' : 'Quick sale',
            color: AppColors.primary,
            onTap: () => context.go('/shop/$shopId/caisse')),
      if (perms.isShopAdmin && perms.canViewProducts)
        _QuickCard(icon: Icons.inventory_2_outlined,
            label: 'Stock',
            sublabel: plural(nProducts, fr ? 'produit' : 'product'),
            color: AppColors.secondary,
            onTap: () => context.go('/shop/$shopId/inventaire')),
      if (perms.canViewFinances)
        _QuickCard(icon: Icons.bar_chart_rounded,
            label: 'Finances',
            sublabel: fr ? 'Bilan du jour' : 'Daily summary',
            color: AppColors.warning,
            onTap: () => context.go('/shop/$shopId/finances')),
      if (perms.canViewClients)
        _QuickCard(icon: Icons.people_outline_rounded,
            label: 'Clients',
            sublabel: plural(nClients, 'client'),
            color: AppColors.info,
            onTap: () => context.go('/shop/$shopId/crm')),
    ];
    if (cards.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(fr ? 'ACCÈS RAPIDES' : 'QUICK ACCESS',
          style: AppTextStyles.captionBold.copyWith(
              color: AppColors.textSecondary, letterSpacing: 0.8)),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (_, c) {
        // 2 colonnes sur mobile, 4 sur desktop (même seuil que les KPI).
        final cols = c.maxWidth >= 600 ? 4 : 2;
        return GridView.count(
          crossAxisCount: cols,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: cols == 4 ? 2.2 : 1.8,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: cards,
        );
      }),
    ]);
  }
}

class _QuickCard extends StatelessWidget {
  final IconData icon;
  final String label, sublabel;
  final Color color;
  final VoidCallback onTap;
  const _QuickCard({required this.icon, required this.label,
      required this.sublabel, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.semantic.borderSubtle),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, color: color, size: 16),
            ),
            const Spacer(),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodySmBold
                    .copyWith(color: theme.colorScheme.onSurface)),
            Text(sublabel, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.micro
                    .copyWith(color: AppColors.textSecondary)),
          ]),
        ),
      ),
    );
  }
}

/// En-tête boutique : initiales + nom + état de connexion. La cloche et la
/// puce hors-ligne détaillée restent dans la barre du haut du shell — ce
/// point n'en est qu'un rappel discret, sans second indicateur cliquable.
class _ShopIdentityCard extends StatelessWidget {
  final String name;
  final bool   isOnline;
  const _ShopIdentityCard({required this.name, required this.isOnline});

  /// « Boutique Kamer » → « BK » ; « Shop » → « SH ».
  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
    final w = parts.first;
    return w.substring(0, w.length >= 2 ? 2 : 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final fr    = Localizations.localeOf(context).languageCode == 'fr';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.semantic.borderSubtle),
      ),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: cs.primary, borderRadius: BorderRadius.circular(10)),
          child: Text(_initials,
              style: AppTextStyles.bodyBold.copyWith(color: cs.onPrimary)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.label.copyWith(color: cs.onSurface)),
            const SizedBox(height: 2),
            Row(children: [
              Container(width: 6, height: 6,
                  decoration: BoxDecoration(shape: BoxShape.circle,
                      color: isOnline ? AppColors.secondary : AppColors.error)),
              const SizedBox(width: 4),
              Text(isOnline ? (fr ? 'En ligne' : 'Online')
                            : (fr ? 'Hors ligne' : 'Offline'),
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary)),
            ]),
          ],
        )),
      ]),
    );
  }
}

/// Salutation selon l'heure + prénom + date du jour, sur une ligne, avec le
/// sélecteur de période existant (déplacé de l'ancien en-tête, inchangé).
class _WelcomeBar extends StatelessWidget {
  final String periodLabel;
  final VoidCallback onPeriodTap;
  const _WelcomeBar({required this.periodLabel, required this.onPeriodTap});

  @override
  Widget build(BuildContext context) {
    final fr  = Localizations.localeOf(context).languageCode == 'fr';
    final now = DateTime.now();
    final h   = now.hour;
    final hello = (h >= 5 && h < 12) ? (fr ? 'Bonjour' : 'Good morning')
        : (h >= 12 && h < 18) ? (fr ? 'Bon après-midi' : 'Good afternoon')
        : (fr ? 'Bonsoir' : 'Good evening');
    // Prénom = premier mot du nom du compte (même règle que l'ancien en-tête :
    // sans nom de profil, salutation seule, sans virgule).
    final full  = LocalStorageService.getCurrentUser()?.name.trim() ?? '';
    final first = full.isEmpty ? '' : full.split(RegExp(r'\s+')).first;
    final raw   = DateFormat('EEEE d MMM y', fr ? 'fr_FR' : 'en_US').format(now);
    final date  = raw.isEmpty ? raw : raw[0].toUpperCase() + raw.substring(1);
    return Row(children: [
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(first.isEmpty ? hello : '$hello, $first',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.label
                  .copyWith(color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: 2),
          Row(children: [
            Icon(Icons.calendar_today_rounded, size: 12,
                color: AppColors.textSecondary),
            const SizedBox(width: 4),
            Flexible(child: Text(date, maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.caption
                    .copyWith(color: AppColors.textSecondary))),
          ]),
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
            border: Border.all(color: AppColors.primary.withValues(alpha:0.3)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.calendar_today_rounded, size: 12,
                color: AppColors.primary),
            const SizedBox(width: 5),
            Text(periodLabel,
                style: AppTextStyles.captionBold.copyWith(
                    color: AppColors.primary)),
            const SizedBox(width: 3),
            Icon(Icons.keyboard_arrow_down_rounded, size: 14,
                color: AppColors.primary),
          ]),
        ),
      ),
    ]);
  }
}

/// « Nouvelle commande » en 1 tap, intégré au défilement : pas de bouton
/// flottant par-dessus le contenu (celui du shell est masqué sur l'accueil).
/// Toute la rangée est cliquable.
class _NewOrderButton extends StatelessWidget {
  final VoidCallback onTap;
  const _NewOrderButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final fr    = Localizations.localeOf(context).languageCode == 'fr';
    return Material(
      color: cs.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.semantic.borderSubtle),
          ),
          child: Row(children: [
            Container(
              width: 52, height: 52,
              decoration: BoxDecoration(
                  color: cs.primary, borderRadius: BorderRadius.circular(14)),
              child: Icon(Icons.add_rounded, color: cs.onPrimary, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(fr ? 'Nouvelle commande' : 'New order',
                    style: AppTextStyles.bodyBold
                        .copyWith(color: cs.onSurface)),
                Text(fr ? '1 tap · accès direct caisse'
                        : '1 tap · straight to checkout',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textSecondary)),
              ],
            )),
            Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
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
            style: AppTextStyles.subtitleBold),
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
                color: active ? AppColors.primaryFill : AppColors.inputFill,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(p.$2,
                  style: AppTextStyles.bodyBold.copyWith(
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
                backgroundColor: AppColors.primaryFill,
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
          Text(label, style: AppTextStyles.micro),
          Text('${date.day}/${date.month}/${date.year}',
              style: AppTextStyles.bodySmBold),
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

  static String _fmt(double v) => CurrencyFormatter.compact(v);

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
        border: Border.all(color: theme.semantic.borderSubtle),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha:0.03),
            blurRadius: 4, offset: const Offset(0,2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha:0.10),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(Icons.account_balance_rounded,
                size: 15, color: AppColors.primary),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(l.dashFinancialSummary,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyBold)),
        ]),
        const SizedBox(height: 12),
        _row(l.financesCA, '+${_fmt(data.totalSales)} ${CurrencyFormatter.currentSymbol}',
            AppColors.textPrimary),
        const SizedBox(height: 4),
        // Coût incomplet → on le DIT. Sans ce signal, « Coût des produits : 0 »
        // se lit comme « je n'ai rien dépensé », alors qu'il signifie « je ne
        // sais pas ce que j'ai dépensé » — et le bénéfice juste en dessous est
        // surestimé d'autant.
        _row(l.dashProductCost, '−${_fmt(productCost)} ${CurrencyFormatter.currentSymbol}',
            AppColors.textSecondary,
            trailing: data.costlessLines > 0
                ? Tooltip(
                    message: l.dashCostUnknown(data.costlessLines),
                    triggerMode: TooltipTriggerMode.tap,
                    showDuration: const Duration(seconds: 6),
                    child: const Icon(Icons.warning_amber_rounded,
                        size: 14, color: AppColors.warning),
                  )
                : null),
        const SizedBox(height: 8),
        Divider(height: 1, color: AppColors.divider),
        const SizedBox(height: 8),
        _row(l.dashNetProfit,
            '${isPositive ? '+' : ''}${_fmt(net)} ${CurrencyFormatter.currentSymbol}',
            isPositive ? AppColors.secondary : AppColors.error,
            bold: true),
      ]),
    );
  }

  Widget _row(String label, String value, Color valueColor,
          {bool bold = false, Widget? trailing}) =>
      Row(children: [
    Expanded(child: Text(label,
        maxLines: 1, overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodySm.copyWith(
            fontSize: bold ? 12 : 10,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            color: bold ? AppColors.textPrimary : AppColors.textSecondary))),
    if (trailing != null) ...[trailing, const SizedBox(width: 6)],
    Text(value,
        maxLines: 1, overflow: TextOverflow.ellipsis,
        style: AppTextStyles.body.copyWith(fontSize: bold ? 13 : 10,
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
              style: AppTextStyles.bodyBold)),
          GestureDetector(
            onTap: onPeriodTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.primaryFill,
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
                  style: AppTextStyles.microBold.copyWith(
                      color: Colors.white),
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
                      getDrawingHorizontalLine: (_) => FlLine(
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
                            style: AppTextStyles.micro,
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
                                  style: AppTextStyles.micro),
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

  static String _compact(double v) => CurrencyFormatter.compact(v);
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
              style: AppTextStyles.captionBold.copyWith(
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
              style: AppTextStyles.captionHint,
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
                    color: medalColor.withValues(alpha:0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Text('${i + 1}',
                      style: AppTextStyles.captionBold.copyWith(
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
                          style: AppTextStyles.bodySmBold),
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
                        style: AppTextStyles.bodySmBold),
                    Text('${p.revenue.toStringAsFixed(0)} ${CurrencyFormatter.currentSymbol}',
                        style: AppTextStyles.microBold.copyWith(
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
        size: 14, color: AppColors.primary.withValues(alpha:0.6)),
  );

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url == null || url.isEmpty) return _placeholder();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(width: 30, height: 30,
        // `CachedNetworkImage` pour le cache persistant (mobile : fichiers,
        // web : IndexedDB) — la vignette restait sinon en placeholder à
        // chaque reload web. `memCacheWidth` omis sur web (décodage canvas
        // peu fiable), conservé en natif pour économiser la mémoire ×4.
        child: url.startsWith('http')
            ? CachedNetworkImage(
                imageUrl: url,
                cacheKey: url,
                memCacheWidth: kIsWeb ? null : 60,
                fit: BoxFit.cover,
                placeholder: (_, __) => _placeholder(),
                errorWidget: (_, __, ___) => _placeholder())
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

  /// Libellé lisible du moyen de paiement (valeurs réelles de PaymentMethod).
  String _paymentLabel(String m, bool fr) => switch (m) {
    'cash'        => 'Cash',
    'mobileMoney' => 'Mobile Money',
    'card'        => fr ? 'Carte' : 'Card',
    'credit'      => fr ? 'Crédit' : 'Credit',
    _             => m,
  };

  @override
  Widget build(BuildContext context) {
    final l  = context.l10n;
    final fr = Localizations.localeOf(context).languageCode == 'fr';
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
          for (var i = 0; i < transactions.length; i++) ...[
            if (i > 0)
              Divider(height: 1,
                  color: Theme.of(context).semantic.borderSubtle),
            _row(l, transactions[i], fr),
          ],
      ],
    ));
  }

  /// Une vente : avatar initiales · client + statut · articles et paiement ·
  /// montant et heure. Hauteur minimale 56 px (zone confortable au doigt).
  Widget _row(AppLocalizations l, RecentTx t, bool fr) {
    final s = _statusOf(l, t.status);
    final isLoss = t.status == 'refunded' ||
        t.status == 'cancelled' ||
        t.status == 'refused';
    final isDone = t.status == 'completed';
    // Encaissée → vert avec « + » ; annulée / remboursée → rouge ;
    // en attente → violet.
    final amountColor = isLoss
        ? AppColors.error
        : (isDone ? AppColors.secondary : AppColors.primary);
    final n = t.itemCount;
    final items = fr
        ? '$n article${n > 1 ? 's' : ''}'
        : '$n item${n > 1 ? 's' : ''}';
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          // ── Avatar initiales client ─────────────────────────
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha:0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(_initials(t.clientName),
                style: AppTextStyles.bodySmBold.copyWith(
                    color: AppColors.primary)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Nom client + badge statut
                Row(children: [
                  Flexible(child: Text(
                      t.clientName ?? l.dashUnknownClient,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySmBold)),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: s.color.withValues(alpha:0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(s.label,
                        style: AppTextStyles.microBold.copyWith(
                            color: s.color)),
                  ),
                ]),
                const SizedBox(height: 2),
                // Articles · moyen de paiement
                Text('$items · ${_paymentLabel(t.paymentMethod, fr)}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.micro),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Montant + heure
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${isDone ? '+' : ''}${CurrencyFormatter.format(t.amount)}',
                  style: AppTextStyles.bodySmBold.copyWith(
                      color: amountColor)),
              const SizedBox(height: 2),
              Text(_timeAgo(t.createdAt), style: AppTextStyles.micro),
            ],
          ),
        ]),
      ),
    );
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
                color: color.withValues(alpha:0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: color.withValues(alpha:0.35)),
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
                            style: AppTextStyles.bodySmBold),
                        Text(
                          '$stock / $threshold ${l.dashUnitsLeft}',
                          style: AppTextStyles.microSecondary,
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
                          style: AppTextStyles.microBold.copyWith(
                              color: Colors.white)),
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
                      backgroundColor: color.withValues(alpha:0.15),
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  )),
                  const SizedBox(width: 6),
                  Text('${pct.toStringAsFixed(0)}%',
                      style: AppTextStyles.microBold.copyWith(color: color)),
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
              style: AppTextStyles.captionHint),
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.semantic.borderSubtle),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha:0.03),
            blurRadius: 5, offset: const Offset(0,2))],
      ),
      child: child,
    );
  }
}

class _CardHeader extends StatelessWidget {
  final String title, action;
  final VoidCallback onAction;
  const _CardHeader({required this.title, required this.action,
    required this.onAction});
  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Text(title, style: AppTextStyles.bodyBold)),
    GestureDetector(onTap: onAction,
        child: Text(action, style: AppTextStyles.captionBold.copyWith(
            color: AppColors.primary))),
  ]);
}


// ─── Sélecteur de boutique active ────────────────────────────────────────────

// ─── Nouveaux produits (< 72h) ───────────────────────────────────────────────

class _NewProductsCard extends ConsumerWidget {
  final List<Product> products;
  final String shopId;
  const _NewProductsCard({required this.products, required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return _DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha:0.12),
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
                      style: AppTextStyles.bodyBold),
                  Text(l.dashNewProductsHint,
                      style: AppTextStyles.micro),
                ],
              ),
            ),
            if (products.isNotEmpty)
              // Bouton global "Partager (N)" — ouvre le dialog catalogue
              // pré-rempli avec tous les nouveaux produits. Le snapshot
              // de stock filtré sur la vue active (dashViewFilterProvider)
              // est embarqué dans l'URL pour que le client voie le stock
              // du périmètre choisi par le marchand.
              GestureDetector(
                onTap: () {
                  final viewFilter = ref.read(dashViewFilterProvider);
                  final locIds = stock_loc.resolveLocationIds(
                      viewFilter, shopId);
                  // Clé `pid|<idx>` après filtrage `realVariants` —
                  // alignée avec `catalogue_page._load()` pour
                  // garantir le matching côté client (les IDs de
                  // variantes peuvent diverger entre Hive local et
                  // JSONB Supabase).
                  final snapshot = <String, int>{};
                  for (final p in products) {
                    final pid = p.id;
                    if (pid == null) continue;
                    final realVariants = p.variants
                        .where((v) => v.name.trim().isNotEmpty)
                        .toList();
                    if (realVariants.length <= 1) {
                      snapshot[pid] =
                          stock_loc.stockAtLocations(p, locIds);
                    } else {
                      for (int i = 0; i < realVariants.length; i++) {
                        snapshot['$pid|$i'] = stock_loc
                            .stockForVariantAtLocations(
                                realVariants[i], locIds);
                      }
                    }
                  }
                  ShareCatalogDialog.show(context,
                      products: products, shopId: shopId,
                      preSelected: products,
                      stockSnapshot: snapshot);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha:0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.primary.withValues(alpha:0.2)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.share_rounded, size: 12,
                        color: AppColors.primary),
                    const SizedBox(width: 5),
                    Text('${l.dashShareAction} (${products.length})',
                        style: AppTextStyles.captionBold.copyWith(
                            color: AppColors.primary)),
                  ]),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          if (products.isEmpty)
            _NewProductsEmpty(message: l.dashNoNewProducts)
          else
            ...products.take(5).map((p) =>
                _NewProductRow(product: p, shopId: shopId)),
          if (products.length > 5) ...[
            const SizedBox(height: 6),
            Center(
              child: GestureDetector(
                onTap: () => context.push('/shop/$shopId/inventaire'),
                child: Text(l.dashViewAll,
                    style: AppTextStyles.captionBold.copyWith(
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
            Icon(Icons.inventory_2_outlined,
                size: 28, color: AppColors.textHint),
            const SizedBox(height: 6),
            Text(message,
                style: AppTextStyles.captionHint),
          ],
        ),
      );
}

class _NewProductRow extends ConsumerWidget {
  final Product product;
  final String  shopId;
  const _NewProductRow({required this.product, required this.shopId});

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
  Widget build(BuildContext context, WidgetRef ref) {
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
              ? Icon(Icons.inventory_2_rounded,
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
                  style: AppTextStyles.bodySmBold),
              const SizedBox(height: 1),
              Row(children: [
                // Nombre de variantes si > 1
                if (hasVariants) ...[
                  Icon(Icons.layers_outlined, size: 10,
                      color: AppColors.primary.withValues(alpha:0.7)),
                  const SizedBox(width: 3),
                  Text(l.dashVariantCount(variantCount),
                      style: AppTextStyles.microBold.copyWith(
                          color: AppColors.primary.withValues(alpha:0.8))),
                  const SizedBox(width: 6),
                  Container(width: 2, height: 2,
                      decoration: BoxDecoration(
                          color: AppColors.textHint,
                          shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                ],
                // Date ajout
                Text(
                  product.createdAt != null
                      ? _ago(context, product.createdAt!)
                      : '',
                  style: AppTextStyles.micro,
                ),
              ]),
            ],
          ),
        ),
        Text('${product.priceSellPos.toStringAsFixed(0)} ${CurrencyFormatter.currentSymbol}',
            style: AppTextStyles.bodySmBold.copyWith(
                color: AppColors.secondary)),
        const SizedBox(width: 6),
        // Bouton partager individuel — stock filtré sur la vue active du
        // dashboard (Boutique seule / Partenaire X / Globale). Sans
        // override, `_productMessage` tombe sur `product.totalStock`
        // = cumul global, pas le stock du périmètre visualisé.
        GestureDetector(
          onTap: () {
            final viewFilter = ref.read(dashViewFilterProvider);
            final locIds = stock_loc.resolveLocationIds(viewFilter, shopId);
            DocumentService.shareProduct(product,
                shopId: shopId,
                stockOverride:
                    stock_loc.stockAtLocations(product, locIds));
          },
          child: Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha:0.08),
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
