import 'package:flutter/foundation.dart';

import '../../domain/entities/global_stats.dart';
import '../../domain/usecases/get_all_shops_stats_usecase.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';

/// Implémentation offline-first du `HubRepository` : agrège les `orders` de
/// `HiveBoxes.ordersBox` boutique par boutique, sur la période demandée et
/// la période précédente (pour la tendance).
class HubRepositoryImpl implements HubRepository {
  const HubRepositoryImpl();

  @override
  Future<GlobalStats> getAllShopsStats(String period) async {
    final shops = LocalStorageService.getShopsForUser(
        LocalStorageService.getCurrentUser()?.id ?? '');
    return _aggregate(period, shops.map((s) => (s.id, s.name)).toList());
  }

  @override
  Future<GlobalStats> compareShops(List<String> shopIds, String period) async {
    final shops = LocalStorageService.getShopsForUser(
        LocalStorageService.getCurrentUser()?.id ?? '');
    final filtered = shops.where((s) => shopIds.contains(s.id))
        .map((s) => (s.id, s.name)).toList();
    return _aggregate(period, filtered);
  }

  // ── Agrégation principale ────────────────────────────────────────────────

  Future<GlobalStats> _aggregate(
      String period, List<(String, String)> shops) async {
    final now = DateTime.now();
    final current  = _rangeFor(period, now);
    final previous = _previousRange(period, current);
    final bucketCount = _bucketCount(period);
    final bucketLabels = _labelsFor(period, current);

    final orders = HiveBoxes.ordersBox.values
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();

    final shopStats = <ShopStats>[];
    double prevTotalRevenue   = 0;
    int    prevTotalTx        = 0;
    int    prevTotalClients   = 0;

    for (final (shopId, shopName) in shops) {
      final cur = _shopAgg(
          orders: orders, shopId: shopId,
          range: current, bucketCount: bucketCount);
      final prev = _shopAgg(
          orders: orders, shopId: shopId,
          range: previous, bucketCount: bucketCount);

      final growth = GlobalStats.trend(cur.revenue, prev.revenue);

      shopStats.add(ShopStats(
        shopId:           shopId,
        shopName:         shopName,
        totalSales:       cur.revenue,
        transactionCount: cur.txCount,
        averageBasket:    cur.txCount > 0 ? cur.revenue / cur.txCount : 0,
        clientCount:      cur.clientIds.length,
        growthRate:       growth,
        salesSeries:      cur.series,
      ));

      prevTotalRevenue += prev.revenue;
      prevTotalTx      += prev.txCount;
      prevTotalClients += prev.clientIds.length;
    }

    final prevAvgBasket = prevTotalTx > 0 ? prevTotalRevenue / prevTotalTx : 0.0;

    return GlobalStats(
      shopStats:                 shopStats,
      period:                    period,
      bucketLabels:              bucketLabels,
      previousTotalRevenue:      prevTotalRevenue,
      previousTotalTransactions: prevTotalTx,
      previousTotalClients:      prevTotalClients,
      previousAverageBasket:     prevAvgBasket,
    );
  }

  /// Agrégation pour un shop sur une plage donnée.
  /// Retourne (revenue, txCount, clientIds, salesSeries[bucketCount]).
  _ShopAggResult _shopAgg({
    required List<Map<String, dynamic>> orders,
    required String shopId,
    required _Range range,
    required int bucketCount,
  }) {
    double revenue = 0;
    int    txCount = 0;
    final  clientIds = <String>{};
    final  series  = List<double>.filled(bucketCount, 0);

    for (final o in orders) {
      if (o['shop_id'] != shopId) continue;
      final status = (o['status'] as String?) ?? 'completed';
      if (status != 'completed') continue;

      // Date effective : completed_at si présente, sinon created_at.
      final completedRaw = o['completed_at'];
      final createdRaw   = o['created_at'];
      final effective = _toDateTime(completedRaw)
          ?? _toDateTime(createdRaw);
      if (effective == null) continue;
      if (effective.isBefore(range.from) || effective.isAfter(range.to)) {
        continue;
      }

      final orderTotal = _orderTotal(o);
      revenue += orderTotal;
      txCount += 1;

      final clientId = o['client_id'] as String?;
      if (clientId != null && clientId.isNotEmpty) clientIds.add(clientId);

      // Bucket : index dans la fenêtre courante
      final bucket = range.bucketIndex(effective, bucketCount);
      if (bucket >= 0 && bucket < bucketCount) {
        series[bucket] += orderTotal;
      }
    }

    return _ShopAggResult(
      revenue:   revenue,
      txCount:   txCount,
      clientIds: clientIds,
      series:    series,
    );
  }

  /// Calcule le total d'un order : Σ(items) − discount_global + TVA.
  /// Frais (livraison) absorbés par la boutique → non ajoutés au CA client.
  /// Cohérent avec `dashboard_providers._loadDashData` (lignes 638-645).
  double _orderTotal(Map<String, dynamic> o) {
    final items = (o['items'] as List?) ?? [];
    double itemsTotal = 0;
    for (final raw in items) {
      if (raw is! Map) continue;
      final it = Map<String, dynamic>.from(raw);
      final qty = ((it['quantity'] ?? it['qty']) as num?)?.toInt() ?? 0;
      final unit = ((it['unit_price'] ?? it['price']) as num?)?.toDouble() ?? 0;
      final custom = (it['custom_price'] as num?)?.toDouble();
      final price = custom ?? unit;
      final discount = (it['discount'] as num?)?.toDouble() ?? 0;
      itemsTotal += price * qty * (1 - discount / 100);
    }
    final orderDiscount = (o['discount_amount'] as num?)?.toDouble() ?? 0;
    final taxRate       = (o['tax_rate']        as num?)?.toDouble() ?? 0;
    final taxableBase   = itemsTotal - orderDiscount;
    return taxableBase + (taxableBase * taxRate / 100);
  }

  static DateTime? _toDateTime(dynamic raw) {
    if (raw is String) return DateTime.tryParse(raw)?.toLocal();
    if (raw is DateTime) return raw.toLocal();
    return null;
  }

  // ── Périodes ─────────────────────────────────────────────────────────────

  /// Plage de la période courante (today/week/month/quarter/year).
  _Range _rangeFor(String period, DateTime now) {
    switch (period) {
      case 'today':
        final start = DateTime(now.year, now.month, now.day);
        return _Range(start, start.add(const Duration(days: 1)));
      case 'week':
        return _Range(
            now.subtract(const Duration(days: 6)), now);
      case 'month':
        return _Range(
            now.subtract(const Duration(days: 29)), now);
      case 'quarter':
        return _Range(
            now.subtract(const Duration(days: 89)), now);
      case 'year':
        return _Range(
            DateTime(now.year - 1, now.month, now.day), now);
      default:
        // Fallback : aujourd'hui
        final start = DateTime(now.year, now.month, now.day);
        return _Range(start, start.add(const Duration(days: 1)));
    }
  }

  /// Plage de la période **précédente** (même longueur, immédiatement avant).
  _Range _previousRange(String period, _Range current) {
    final duration = current.to.difference(current.from);
    final to = current.from;
    final from = to.subtract(duration);
    return _Range(from, to);
  }

  /// Nombre de buckets pour le graphique (granularité auto).
  int _bucketCount(String period) {
    switch (period) {
      case 'today':   return 24;  // heures
      case 'week':    return 7;   // jours
      case 'month':   return 30;  // jours
      case 'quarter': return 12;  // semaines
      case 'year':    return 12;  // mois
      default:        return 24;
    }
  }

  /// Labels des buckets (utilisés par l'axe X du graphique).
  List<String> _labelsFor(String period, _Range range) {
    switch (period) {
      case 'today':
        return List.generate(24, (i) => '${i.toString().padLeft(2, '0')}h');
      case 'week':
        const days = ['Lun','Mar','Mer','Jeu','Ven','Sam','Dim'];
        // Bucket 0 = il y a 6 jours.
        return List.generate(7, (i) {
          final d = range.from.add(Duration(days: i));
          return days[(d.weekday - 1) % 7];
        });
      case 'month':
        return List.generate(30, (i) {
          final d = range.from.add(Duration(days: i));
          return d.day.toString();
        });
      case 'quarter':
        return List.generate(12, (i) => 'S${i + 1}');
      case 'year':
        const months = ['J','F','M','A','M','J','J','A','S','O','N','D'];
        return List.generate(12, (i) {
          final m = ((range.from.month - 1 + i) % 12) + 1;
          return months[m - 1];
        });
      default:
        return List.generate(_bucketCount(period), (i) => '$i');
    }
  }
}

class _ShopAggResult {
  final double      revenue;
  final int         txCount;
  final Set<String> clientIds;
  final List<double> series;
  const _ShopAggResult({
    required this.revenue,
    required this.txCount,
    required this.clientIds,
    required this.series,
  });
}

/// Plage [from, to[ avec calcul d'index de bucket.
class _Range {
  final DateTime from, to;
  const _Range(this.from, this.to);

  /// Index du bucket auquel appartient `d`. Retourne -1 si hors plage.
  int bucketIndex(DateTime d, int bucketCount) {
    if (d.isBefore(from) || d.isAfter(to)) return -1;
    final total = to.difference(from).inMicroseconds;
    if (total <= 0) return 0;
    final pos = d.difference(from).inMicroseconds;
    final idx = (pos * bucketCount) ~/ total;
    return idx.clamp(0, bucketCount - 1);
  }
}

// Use foundation.dart pour debugPrint si besoin (gardé pour future trace)
// ignore: unused_element
void _trace(String msg) => debugPrint('[HubRepo] $msg');
