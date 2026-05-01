import 'package:flutter/material.dart';
import '../../domain/entities/global_stats.dart';

class MultiShopChartWidget extends StatelessWidget {
  final GlobalStats stats;
  const MultiShopChartWidget({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    // Placeholder — brancher fl_chart ici
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Évolution CA par boutique', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SizedBox(height: 150, child: Center(child: Text('Graphique fl_chart — à implémenter', style: const TextStyle(color: Colors.grey)))),
        ]),
      ),
    );
  }
}
