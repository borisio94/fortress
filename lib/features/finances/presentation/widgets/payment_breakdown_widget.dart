import 'package:flutter/material.dart';

import '../../../../core/utils/currency_formatter.dart';
import '../../../dashboard/data/dashboard_providers.dart';

/// Répartition du CA par mode de paiement, à partir des transactions
/// récentes filtrées (les transactions annulées/refusées/remboursées sont
/// exclues car elles n'ont pas été encaissées).
///
/// Utilise un `LinearProgressIndicator` par ligne — visuel simple,
/// pas de donut externe.
class PaymentBreakdownWidget extends StatelessWidget {
  final List<RecentTx> recentTx;
  const PaymentBreakdownWidget({super.key, required this.recentTx});

  static ({IconData icon, Color color, String label}) _meta(String m) =>
      switch (m) {
        'card' => (
            icon: Icons.credit_card_rounded,
            color: const Color(0xFF3B82F6),
            label: 'Carte bancaire'),
        'mobileMoney' => (
            icon: Icons.phone_android_rounded,
            color: const Color(0xFFF97316),
            label: 'Mobile Money'),
        'credit' => (
            icon: Icons.handshake_rounded,
            color: const Color(0xFFB45309),
            label: 'Crédit'),
        _ => (
            icon: Icons.payments_rounded,
            color: const Color(0xFF10B981),
            label: 'Espèces'),
      };

  @override
  Widget build(BuildContext context) {
    final map = <String, double>{};
    for (final tx in recentTx) {
      final isLoss = tx.status == 'refunded' ||
          tx.status == 'cancelled' ||
          tx.status == 'refused';
      if (isLoss) continue;
      map[tx.paymentMethod] = (map[tx.paymentMethod] ?? 0) + tx.amount;
    }
    if (map.isEmpty) return const SizedBox.shrink();

    final total = map.values.fold(0.0, (s, v) => s + v);
    final sorted = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

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
        const Text('Répartition paiements',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A))),
        const SizedBox(height: 12),
        ...sorted.map((e) {
          final pct = total > 0 ? e.value / total : 0.0;
          final pm  = _meta(e.key);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(children: [
                Icon(pm.icon, size: 14, color: pm.color),
                const SizedBox(width: 8),
                Expanded(child: Text(pm.label,
                    style: const TextStyle(fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF374151)))),
                Text(CurrencyFormatter.format(e.value),
                    style: TextStyle(fontSize: 12,
                        fontWeight: FontWeight.w700, color: pm.color)),
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
                  valueColor: AlwaysStoppedAnimation(pm.color),
                ),
              ),
            ]),
          );
        }),
      ]),
    );
  }
}

