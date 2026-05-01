import 'package:flutter/material.dart';
import '../../domain/entities/client.dart';
import '../../../../core/utils/currency_formatter.dart';

class ClientCardWidget extends StatelessWidget {
  final Client client;
  final VoidCallback onTap;
  const ClientCardWidget({super.key, required this.client, required this.onTap});

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      leading: CircleAvatar(child: Text(client.name[0].toUpperCase())),
      title: Text(client.name),
      subtitle: Text(client.phone ?? ''),
      trailing: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(CurrencyFormatter.format(client.totalSpent), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        Text('${client.totalOrders} commande${client.totalOrders > 1 ? "s" : ""}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
      onTap: onTap,
    ),
  );
}
