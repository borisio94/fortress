import 'package:flutter/material.dart';

import '../../../../core/utils/currency_formatter.dart';

/// Répartition des dépenses opérationnelles par catégorie. Affiche une
/// barre de progression par catégorie (part du total) + montant et
/// pourcentage. Les clés de catégorie connues sont mappées sur un libellé
/// + icône + couleur ; les clés inconnues (labels libres de frais de
/// commande, ex. "Livraison", "Emballage") sont affichées telles quelles.
class ExpensesBreakdownWidget extends StatelessWidget {
  final Map<String, double> byCategory;
  const ExpensesBreakdownWidget({super.key, required this.byCategory});

  static ({IconData icon, Color color, String label}) _meta(String key) {
    switch (key) {
      case 'shipping':
        return (icon: Icons.local_shipping_rounded,
            color: const Color(0xFF8B5CF6), label: 'Expédition');
      case 'marketing':
        return (icon: Icons.campaign_rounded,
            color: const Color(0xFFEC4899), label: 'Marketing');
      case 'rent':
        return (icon: Icons.store_rounded,
            color: const Color(0xFF6366F1), label: 'Loyer');
      case 'salary':
        return (icon: Icons.people_rounded,
            color: const Color(0xFF0EA5E9), label: 'Salaires');
      case 'utilities':
        return (icon: Icons.bolt_rounded,
            color: const Color(0xFFF59E0B), label: 'Services');
      case 'taxes':
        return (icon: Icons.gavel_rounded,
            color: const Color(0xFFB45309), label: 'Taxes');
      case 'supplies':
        return (icon: Icons.inventory_rounded,
            color: const Color(0xFF10B981), label: 'Fournitures');
      case 'other':
        return (icon: Icons.more_horiz_rounded,
            color: const Color(0xFF6B7280), label: 'Autre');
      case 'scrapped':
        return (icon: Icons.delete_forever_rounded,
            color: const Color(0xFFEF4444), label: 'Pertes rebuts');
      case 'repair':
        return (icon: Icons.build_rounded,
            color: const Color(0xFFF97316), label: 'Réparations');
      default:
        // Frais de commande avec label libre (ex: "Livraison", "Douane")
        return (icon: Icons.receipt_long_rounded,
            color: const Color(0xFF64748B), label: key);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = byCategory.entries
        .where((e) => e.value > 0)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) return const SizedBox.shrink();

    final total = entries.fold<double>(0, (s, e) => s + e.value);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03),
            blurRadius: 5, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.pie_chart_rounded,
              size: 16, color: Color(0xFF6B7280)),
          const SizedBox(width: 8),
          const Expanded(child: Text('Dépenses par catégorie',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
          Text(CurrencyFormatter.format(total),
              style: const TextStyle(fontSize: 12,
                  fontWeight: FontWeight.w700, color: Color(0xFFEF4444))),
        ]),
        const SizedBox(height: 12),
        ...entries.map((e) {
          final pct  = total > 0 ? e.value / total : 0.0;
          final meta = _meta(e.key);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(children: [
                Icon(meta.icon, size: 14, color: meta.color),
                const SizedBox(width: 8),
                Expanded(child: Text(meta.label,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF374151)))),
                Text(CurrencyFormatter.format(e.value),
                    style: TextStyle(fontSize: 12,
                        fontWeight: FontWeight.w700, color: meta.color)),
                const SizedBox(width: 6),
                Text('${(pct * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 10,
                        color: Color(0xFF9CA3AF))),
              ]),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: pct, minHeight: 4,
                  backgroundColor: const Color(0xFFF3F4F6),
                  valueColor: AlwaysStoppedAnimation(meta.color),
                ),
              ),
            ]),
          );
        }),
      ]),
    );
  }
}
