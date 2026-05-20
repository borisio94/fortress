import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../data/onboarding_prefs.dart';

/// Bannière dashboard « Votre essai expire dans 2 jours » (point 10
/// de l'onboarding spec — partie J+12).
///
/// Affichée tant que :
///   • Le plan courant est en `trial` (`UserPlan.isTrial`).
///   • Il reste 1 ou 2 jours (`daysLeft <= 2`).
///   • L'utilisateur n'a pas fermé la bannière manuellement (flag
///     SharedPreferences user-scoped).
///
/// Bouton CTA « Souscrire » → `/subscription`. Bouton croix → dismiss.
/// Le but est un rappel doux, pas un paywall. Le verrou réel est dans
/// `app_router` (cf. CAS 2 — pas d'abonnement actif → /subscription).
class TrialEndBanner extends ConsumerStatefulWidget {
  const TrialEndBanner({super.key});

  @override
  ConsumerState<TrialEndBanner> createState() => _TrialEndBannerState();
}

class _TrialEndBannerState extends ConsumerState<TrialEndBanner> {
  bool? _dismissed;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final uid = Supabase.instance.client.auth.currentUser?.id ?? '';
    final d   = await OnboardingPrefs.isTrialEndBannerDismissed(uid);
    if (!mounted) return;
    setState(() => _dismissed = d);
  }

  Future<void> _dismiss() async {
    final uid = Supabase.instance.client.auth.currentUser?.id ?? '';
    await OnboardingPrefs.dismissTrialEndBanner(uid);
    if (!mounted) return;
    setState(() => _dismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed == null) return const SizedBox.shrink();
    if (_dismissed!)        return const SizedBox.shrink();

    final plan = ref.watch(currentPlanProvider);
    if (!plan.isTrial)   return const SizedBox.shrink();
    if (plan.daysLeft > 2) return const SizedBox.shrink();
    if (plan.daysLeft < 0) return const SizedBox.shrink();

    final daysLabel = plan.daysLeft <= 0
        ? 'aujourd\'hui'
        : plan.daysLeft == 1
            ? 'demain'
            : 'dans 2 jours';

    return Container(
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.20),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.timer_outlined,
                color: AppColors.warning, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Essai terminé $daysLabel',
                  style: AppTextStyles.bodyBold,
                ),
                const SizedBox(height: 2),
                const Text(
                  'Vos données restent en sécurité. Souscrivez pour '
                  'continuer à vendre.',
                  style: AppTextStyles.bodySmSecondary,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Plus tard',
                icon: const Icon(Icons.close_rounded,
                    color: AppColors.textSecondary, size: 18),
                onPressed: _dismiss,
                visualDensity: VisualDensity.compact,
              ),
              ElevatedButton(
                onPressed: () => context.push(RouteNames.subscription),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.warning,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Souscrire',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
