import 'package:flutter/material.dart';
import '../../domain/entities/global_stats.dart';
import '../../../../core/utils/currency_formatter.dart';

class ShopsRankingWidget extends StatelessWidget {
  final List<ShopStats> shops;
  const ShopsRankingWidget({super.key, required this.shops});

  @override
  Widget build(BuildContext context) => Column(
    children: shops.asMap().entries.map((e) => ListTile(
      leading: CircleAvatar(child: Text('${e.key+1}')),
      title: Text(e.value.shopName),
      trailing: Text(CurrencyFormatter.format(e.value.totalSales), style: const TextStyle(fontWeight: FontWeight.bold)),
    )).toList(),
  );
}
