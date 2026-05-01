import 'package:equatable/equatable.dart';

class ShopStats extends Equatable {
  final String shopId;
  final String shopName;
  final double totalSales;
  final int    transactionCount;
  final double averageBasket;
  final int    clientCount;
  /// % vs période précédente (positif = hausse). 0 si pas de baseline.
  final double growthRate;
  /// CA par bucket pour le graphique barres groupées (taille = `bucketLabels`).
  final List<double> salesSeries;

  const ShopStats({
    required this.shopId,
    required this.shopName,
    required this.totalSales,
    required this.transactionCount,
    required this.averageBasket,
    required this.clientCount,
    this.growthRate  = 0,
    this.salesSeries = const [],
  });

  @override
  List<Object> get props =>
      [shopId, totalSales, transactionCount, clientCount, growthRate];
}

class GlobalStats extends Equatable {
  final List<ShopStats> shopStats;
  final String          period;
  /// Labels des buckets (ex: ['00h','01h',...] ou ['Lun','Mar',...]).
  final List<String>    bucketLabels;
  /// Métriques de la période **précédente** — utilisées pour calculer la
  /// tendance globale dans les KPI cards.
  final double previousTotalRevenue;
  final int    previousTotalTransactions;
  final int    previousTotalClients;
  final double previousAverageBasket;

  const GlobalStats({
    required this.shopStats,
    required this.period,
    this.bucketLabels              = const [],
    this.previousTotalRevenue      = 0,
    this.previousTotalTransactions = 0,
    this.previousTotalClients      = 0,
    this.previousAverageBasket     = 0,
  });

  double get totalRevenue =>
      shopStats.fold(0, (s, sh) => s + sh.totalSales);
  int get totalTransactions =>
      shopStats.fold(0, (s, sh) => s + sh.transactionCount);
  int get totalClients =>
      shopStats.fold(0, (s, sh) => s + sh.clientCount);
  double get averageBasket =>
      totalTransactions > 0 ? totalRevenue / totalTransactions : 0;
  ShopStats? get topShop => shopStats.isEmpty
      ? null
      : shopStats.reduce((a, b) => a.totalSales > b.totalSales ? a : b);

  /// Tendance % entre `current` et `previous` ; 0 si baseline nulle.
  static double trend(double current, double previous) {
    if (previous <= 0) return current > 0 ? 100 : 0;
    return ((current - previous) / previous) * 100;
  }

  double get revenueTrend         => trend(totalRevenue,      previousTotalRevenue);
  double get transactionsTrend    =>
      trend(totalTransactions.toDouble(), previousTotalTransactions.toDouble());
  double get clientsTrend         =>
      trend(totalClients.toDouble(),      previousTotalClients.toDouble());
  double get averageBasketTrend   => trend(averageBasket,     previousAverageBasket);

  @override
  List<Object> get props => [shopStats, period, bucketLabels];
}
