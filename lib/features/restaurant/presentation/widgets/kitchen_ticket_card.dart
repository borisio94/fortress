import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../features/caisse/domain/entities/sale.dart';

/// Ancienneté d'un bon de cuisine.
///
/// Seuils issus de la spec : vert < 8 min · orange ≥ 8 min · rouge ≥ 15 min.
enum KitchenUrgency { fresh, warning, late }

extension KitchenUrgencyX on KitchenUrgency {
  static KitchenUrgency fromElapsed(Duration d) {
    if (d.inMinutes >= 15) return KitchenUrgency.late;
    if (d.inMinutes >= 8) return KitchenUrgency.warning;
    return KitchenUrgency.fresh;
  }

  Color color(AppSemanticColors s) => switch (this) {
        KitchenUrgency.fresh   => s.success,
        KitchenUrgency.warning => s.warning,
        KitchenUrgency.late    => s.danger,
      };

  Color surface(AppSemanticColors s) => switch (this) {
        KitchenUrgency.fresh   => s.successSurface,
        KitchenUrgency.warning => s.warningSurface,
        KitchenUrgency.late    => s.dangerSurface,
      };
}

/// Ticket de cuisine : table, minuteur, articles et action « prête ».
class KitchenTicketCard extends StatelessWidget {
  final Sale order;
  final String tableLabel;

  /// Index des articles cochés (aide au dressage, non persistée).
  final Set<int> checked;

  final ValueChanged<int> onToggleItem;
  final VoidCallback onReady;

  const KitchenTicketCard({
    super.key,
    required this.order,
    required this.tableLabel,
    required this.checked,
    required this.onToggleItem,
    required this.onReady,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.semantic;

    final elapsed = DateTime.now().difference(order.createdAt);
    final urgency = KitchenUrgencyX.fromElapsed(elapsed);
    final accent = urgency.color(semantic);

    final allChecked =
        order.items.isNotEmpty && checked.length >= order.items.length;

    return Container(
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── En-tête : table + minuteur ──────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: urgency.surface(semantic),
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(10)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tableLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.subtitleBold.copyWith(color: accent),
                  ),
                ),
                Icon(Icons.access_time_rounded, size: 15, color: accent),
                const SizedBox(width: 4),
                Text(DurationFormatter.compact(elapsed),
                    style: AppTextStyles.bodySmBold.copyWith(color: accent)),
              ],
            ),
          ),
          if (order.covers != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text('${order.covers} couverts',
                  style: AppTextStyles.captionHint),
            ),
          // ── Articles ────────────────────────────────────────────────
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              itemCount: order.items.length,
              itemBuilder: (_, i) {
                final item = order.items[i];
                final isChecked = checked.contains(i);
                final options = item.modifiersLabel;
                return InkWell(
                  onTap: () => onToggleItem(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          isChecked
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 18,
                          color: isChecked
                              ? semantic.success
                              : theme.colorScheme.onSurface
                                  .withValues(alpha: 0.35),
                        ),
                        const SizedBox(width: 8),
                        Text('${item.quantity}×',
                            style: AppTextStyles.bodyBold
                                .copyWith(color: accent)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.productName,
                                style: AppTextStyles.body.copyWith(
                                  color: theme.colorScheme.onSurface,
                                  // Barré une fois dressé : le cuisinier
                                  // voit d'un coup d'œil ce qui reste.
                                  decoration: isChecked
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                              if (options.isNotEmpty)
                                Text(options,
                                    style: AppTextStyles.caption
                                        .copyWith(color: semantic.warning)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          // ── Action ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onReady,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(
                    allChecked ? 'Prête — servir' : 'Commande prête'),
                style: FilledButton.styleFrom(
                  backgroundColor: semantic.success,
                  // Hauteur explicite : le thème global impose un
                  // minimumSize infini qui casserait la mise en page.
                  minimumSize: const Size(0, 44),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
