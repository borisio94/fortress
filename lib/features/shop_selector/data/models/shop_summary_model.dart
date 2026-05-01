import '../../domain/entities/shop_summary.dart';


class ShopSummaryModel {
  final String id;
  final String name;
    final String? logoUrl;
  final String currency;
  final String country;
  final String sector;
    final bool isActive;
    final double? todaySales;

  const ShopSummaryModel({
    required this.id,
    required this.name,
    this.logoUrl,
    required this.currency,
    required this.country,
    required this.sector,
    this.isActive = true,
    this.todaySales,
  });

}