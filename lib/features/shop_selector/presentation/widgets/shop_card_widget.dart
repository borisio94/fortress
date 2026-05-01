import 'package:flutter/material.dart';
import '../../domain/entities/shop_summary.dart';
import '../../../../core/utils/currency_formatter.dart';

class ShopCardWidget extends StatelessWidget {
  final ShopSummary shop;
  final VoidCallback onTap;
  const ShopCardWidget({super.key, required this.shop, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(shop.name[0].toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        title: Text(shop.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${shop.sector} · ${shop.currency}'),
        trailing: shop.todaySales != null
            ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(CurrencyFormatter.format(shop.todaySales!, currency: shop.currency), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                const Text('aujourd\'hui', style: TextStyle(fontSize: 11)),
              ])
            : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
