import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';

// ─── Feature flag ─────────────────────────────────────────────────────────
const _flagKey = 'caisse_empty_dashboard_enabled';

bool isEmptyCartDashboardEnabled() {
  try {
    return HiveBoxes.settingsBox.get(_flagKey, defaultValue: true) as bool;
  } catch (_) {
    return true;
  }
}

Future<void> setEmptyCartDashboardEnabled(bool v) async {
  try {
    await HiveBoxes.settingsBox.put(_flagKey, v);
  } catch (_) {/* settings box absente : ignorer silencieusement */}
}

/// Mini-dashboard temps réel rendu à la place de l'icône triste quand le
/// panier est vide. Source de données : Hive uniquement (offline-first),
/// agrégat à chaque rebuild — bon marché car tout est en mémoire.
///
/// Listener `AppDatabase.addListener` câblé pour rebuild quand une vente
/// arrive depuis un autre appareil pendant que la page est ouverte.
class EmptyCartDashboard extends ConsumerStatefulWidget {
  final String shopId;
  const EmptyCartDashboard({super.key, required this.shopId});

  @override
  ConsumerState<EmptyCartDashboard> createState() =>
      _EmptyCartDashboardState();
}

class _EmptyCartDashboardState extends ConsumerState<EmptyCartDashboard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    AppDatabase.addListener(_onChange);
    // Re-render toutes les 60 s pour rafraîchir "il y a X min" sans
    // dépendre d'un évènement externe.
    _ticker = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onChange);
    _ticker?.cancel();
    super.dispose();
  }

  void _onChange(String table, String shopId) {
    if (!mounted) return;
    if (shopId != widget.shopId && shopId != '_all') return;
    if (table == 'orders' || table == 'products') {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final stats = _computeStats(widget.shopId);
    final l     = context.l10n;
    final user  = LocalStorageService.getCurrentUser();
    final firstName = (user?.name.split(RegExp(r'\s+')).firstOrNull
        ?? '').trim();
    // Fallback "Bonjour" sans nom si non disponible (early login, etc.).
    final greet = firstName.isEmpty
        ? l.dashboardGreeting('').trim()
        : l.dashboardGreeting(firstName);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        // 1. Header
        Text(greet,
            style: AppTextStyles.body.copyWith(
                color: cs.onSurface.withValues(alpha: 0.6))),
        const SizedBox(height: 2),
        Text(l.dashboardWishGoodSelling,
            style: AppTextStyles.subtitle.copyWith(
                fontWeight: FontWeight.w500,
                color: cs.onSurface)),
        const SizedBox(height: 14),

        // 2. Card KPI principale
        _SalesTodayCard(stats: stats),
        const SizedBox(height: 12),

        // 3. Mini-KPIs 2 colonnes
        Row(children: [
          Expanded(child: _MiniKpi(
              label: l.dashboardAvgCart,
              value: stats.salesCount > 0
                  ? CurrencyFormatter.format(
                      stats.salesToday / stats.salesCount)
                  : '—')),
          const SizedBox(width: 10),
          Expanded(child: _MiniKpi(
              label: l.dashboardLastSale,
              value: stats.lastSale == null
                  ? '—'
                  : _relativeTime(context, stats.lastSale!))),
        ]),

        // 4. Card alerte rupture (conditionnel)
        if (stats.outOfStock.isNotEmpty) ...[
          const SizedBox(height: 12),
          _OutOfStockCard(
            shopId: widget.shopId,
            count:  stats.outOfStock.length,
            names:  stats.outOfStock.take(3).toList()),
        ],

        const SizedBox(height: 16),

        // 5. Pied de page
        Container(
          padding: const EdgeInsets.only(top: 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: sem.borderSubtle)),
          ),
          child: Center(child: Text(
              l.dashboardEmptyCartHint,
              style: AppTextStyles.bodySm.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.5)))),
        ),
      ],
    );
  }
}

// ─── Card KPI principale (Ventes du jour) ──────────────────────────────────

class _SalesTodayCard extends StatelessWidget {
  final _DashStats stats;
  const _SalesTodayCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final trend = _trendVsYesterday(stats.salesToday, stats.salesYesterday);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(l.dashboardSalesToday,
              style: AppTextStyles.bodySm.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6)))),
          _TrendPill(trend: trend),
        ]),
        const SizedBox(height: 6),
        Text(CurrencyFormatter.format(stats.salesToday),
            style: AppTextStyles.display.copyWith(
                fontWeight: FontWeight.w500,
                color: cs.onSurface)),
        const SizedBox(height: 2),
        Text(l.dashboardSalesCount(stats.salesCount, stats.clientsCount),
            style: AppTextStyles.bodySm.copyWith(
                color: cs.onSurface.withValues(alpha: 0.5))),
      ]),
    );
  }
}

class _TrendPill extends StatelessWidget {
  final _Trend trend;
  const _TrendPill({required this.trend});
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final (Color bg, Color fg, String label) = switch (trend.kind) {
      _TrendKind.up    => (sem.successSurface, sem.success, '+${trend.pct} %'),
      _TrendKind.down  => (sem.dangerSurface,  sem.danger,  '${trend.pct} %'),
      _TrendKind.flat  => (sem.trackMuted,
          Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
          '='),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: AppTextStyles.captionBold.copyWith(color: fg)),
    );
  }
}

// ─── Mini-KPI ──────────────────────────────────────────────────────────────

class _MiniKpi extends StatelessWidget {
  final String label;
  final String value;
  const _MiniKpi({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: AppTextStyles.captionHint.copyWith(
                color: cs.onSurface.withValues(alpha: 0.55))),
        const SizedBox(height: 2),
        Text(value,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: AppTextStyles.label.copyWith(color: cs.onSurface)),
      ]),
    );
  }
}

// ─── Card alerte rupture ───────────────────────────────────────────────────

class _OutOfStockCard extends StatelessWidget {
  final String       shopId;
  final int          count;
  final List<String> names;
  const _OutOfStockCard({
    required this.shopId,
    required this.count,
    required this.names,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final l   = context.l10n;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => context.push('/shop/$shopId/inventaire'),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: sem.dangerSurface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text(l.dashboardOutOfStockAlert(count),
                style: AppTextStyles.caption.copyWith(color: sem.danger)),
            const SizedBox(height: 4),
            Text(names.join(', '),
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.captionHint.copyWith(
                    color: sem.danger.withValues(alpha: 0.85))),
          ]),
        ),
      ),
    );
  }
}

// ─── Helpers ───────────────────────────────────────────────────────────────

class _DashStats {
  final double    salesToday;
  final double    salesYesterday;
  final int       salesCount;
  final int       clientsCount;
  final DateTime? lastSale;
  final List<String> outOfStock;
  const _DashStats({
    required this.salesToday,
    required this.salesYesterday,
    required this.salesCount,
    required this.clientsCount,
    required this.lastSale,
    required this.outOfStock,
  });
}

enum _TrendKind { up, down, flat }
class _Trend {
  final _TrendKind kind;
  final int        pct;
  const _Trend(this.kind, this.pct);
}

_Trend _trendVsYesterday(double today, double yesterday) {
  if (yesterday <= 0) {
    return today > 0 ? const _Trend(_TrendKind.up, 100)
                     : const _Trend(_TrendKind.flat, 0);
  }
  final pct = ((today - yesterday) / yesterday * 100).round();
  if (pct > 0)  return _Trend(_TrendKind.up, pct);
  if (pct < 0)  return _Trend(_TrendKind.down, pct);
  return const _Trend(_TrendKind.flat, 0);
}

String _relativeTime(BuildContext context, DateTime t) {
  final l = context.l10n;
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1)  return l.dashboardLastSaleJustNow;
  if (d.inMinutes < 60) return l.dashboardLastSaleAgo('${d.inMinutes} min');
  if (d.inHours   < 24) return l.dashboardLastSaleAgo('${d.inHours} h');
  return l.dashboardLastSaleAgo('${d.inDays} j');
}

/// Agrégation pure depuis Hive — pas d'I/O réseau. Coût négligeable
/// (orders du shop courant filtrés en mémoire).
_DashStats _computeStats(String shopId) {
  final now = DateTime.now();
  final startOfToday     = DateTime(now.year, now.month, now.day);
  final startOfYesterday = startOfToday.subtract(const Duration(days: 1));

  double today = 0, yesterday = 0;
  var count = 0;
  final clientIds = <String>{};
  DateTime? lastSale;

  for (final raw in HiveBoxes.ordersBox.values) {
    final o = Map<String, dynamic>.from(raw);
    if (o['shop_id'] != shopId) continue;
    if (o['status'] != 'completed') continue;
    final completedAt =
        DateTime.tryParse(o['completed_at']?.toString() ?? '')?.toLocal();
    if (completedAt == null) continue;

    // Calcul du total — articles − remise + tva (frais absorbés).
    final items = (o['items'] as List?) ?? const [];
    double itemsTotal = 0;
    for (final raw in items) {
      final it = Map<String, dynamic>.from(raw as Map);
      final qty = ((it['quantity'] ?? it['qty']) as num?)?.toInt() ?? 0;
      final unit = ((it['unit_price'] ?? it['price']) as num?)?.toDouble()
          ?? 0;
      final custom = (it['custom_price'] as num?)?.toDouble();
      final price = custom ?? unit;
      final discount = (it['discount'] as num?)?.toDouble() ?? 0;
      itemsTotal += price * qty * (1 - discount / 100);
    }
    final orderDiscount = (o['discount_amount'] as num?)?.toDouble() ?? 0;
    final taxRate       = (o['tax_rate']        as num?)?.toDouble() ?? 0;
    final taxableBase   = itemsTotal - orderDiscount;
    final orderTotal    = taxableBase + taxableBase * taxRate / 100;

    if (!completedAt.isBefore(startOfToday)) {
      today += orderTotal;
      count++;
      final cid = o['client_id'] as String?;
      if (cid != null && cid.isNotEmpty) clientIds.add(cid);
      if (lastSale == null || completedAt.isAfter(lastSale)) {
        lastSale = completedAt;
      }
    } else if (!completedAt.isBefore(startOfYesterday)) {
      yesterday += orderTotal;
    }
  }

  // Produits en rupture (actifs, stock_qty == 0)
  final outOfStock = <String>[];
  for (final raw in HiveBoxes.productsBox.values) {
    final m = Map<String, dynamic>.from(raw);
    if (m['store_id'] != shopId) continue;
    if (m['is_active'] == false) continue;
    final stock = (m['stock_qty'] as num?)?.toInt() ?? 0;
    if (stock <= 0) {
      final name = (m['name'] as String?)?.trim() ?? '';
      if (name.isNotEmpty) outOfStock.add(name);
    }
  }

  return _DashStats(
    salesToday:     today,
    salesYesterday: yesterday,
    salesCount:     count,
    clientsCount:   clientIds.length,
    lastSale:       lastSale,
    outOfStock:     outOfStock,
  );
}
