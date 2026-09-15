import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';

/// Indication permanente "Mode essai · N jours restants" pendant la
/// durée du trial (jusqu'à J-3). Aux 2 derniers jours, [TrialEndBanner]
/// prend le relais avec un ton plus urgent (warning orange).
///
/// Self-gated → safe à inclure inconditionnellement dans le dashboard.
class TrialStatusBanner extends ConsumerWidget {
  const TrialStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(currentPlanProvider);
    if (!plan.isTrial)     return const SizedBox.shrink();
    if (plan.daysLeft <= 2) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: AppColors.primary.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(Icons.hourglass_top_rounded,
                color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Mode essai · ${plan.daysLeft} jours restants',
                    style: AppTextStyles.bodyBold),
                const SizedBox(height: 2),
                Text(
                  'Accès complet pendant 14 jours. Souscrivez à tout moment.',
                  style: AppTextStyles.bodySmSecondary,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => context.push(RouteNames.subscription),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.45)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              visualDensity: VisualDensity.compact,
              // Surcharge le minimumSize global (Size(infinity, 52)) qui
              // forcerait le bouton à prendre toute la largeur dans le Row
              // → écraserait l'Expanded(Column) à côté et le texte "Mode
              // essai..." se retrouverait wrappé caractère par caractère.
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Formules',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
