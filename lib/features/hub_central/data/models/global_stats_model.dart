import '../../domain/entities/global_stats.dart';

class GlobalStatsModel extends GlobalStats {
  const GlobalStatsModel({required super.shopStats, required super.period});

  factory GlobalStatsModel.fromJson(Map<String, dynamic> json) {
    return GlobalStatsModel(
      period: json['period'],
      shopStats: (json['shops'] as List).map((s) => ShopStats(
        shopId: s['id'], shopName: s['name'], totalSales: (s['total_sales'] as num).toDouble(),
        transactionCount: s['transaction_count'], averageBasket: (s['average_basket'] as num).toDouble(),
        clientCount: s['client_count'], growthRate: (s['growth_rate'] as num?)?.toDouble() ?? 0,
      )).toList(),
    );
  }
}
