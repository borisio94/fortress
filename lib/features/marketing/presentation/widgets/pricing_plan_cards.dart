import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PricingPlanCards — 3 cards plans (Starter / Pro highlighted / Business)
// rendues en row sur desktop ≥900 px, column sur mobile. Prix dépendent du
// `cycle` ('monthly' ou 'yearly'). Données alignées sur les limites SQL
// `plans` (hotfix_063) et la card subscription_page.dart authentifiée.
// ═════════════════════════════════════════════════════════════════════════════

class PricingPlanCards extends StatelessWidget {
  final String cycle;
  const PricingPlanCards({super.key, required this.cycle});

  static const _plans = <_PlanData>[
    _PlanData(
      name: 'Starter',
      tagline: 'Pour commencer',
      monthly: 3500,
      yearly:  31500,
      features: [
        '1 boutique',
        '1 dépôt partenaire',
        '1 employé',
        'Caisse offline-first',
        'Catalogue WhatsApp',
        'Support email',
      ],
    ),
    _PlanData(
      name: 'Pro',
      tagline: 'Le plus populaire',
      monthly: 8500,
      yearly:  76500,
      highlight: true,
      features: [
        '1 boutique',
        '3 dépôts partenaires',
        '3 employés',
        'Tout Starter',
        'Commandes programmées',
        'Transfert livreur',
        'Rapports avancés',
        'Exports Excel',
      ],
    ),
    _PlanData(
      name: 'Business',
      tagline: 'Multi-boutiques',
      monthly: 18000,
      yearly:  162000,
      features: [
        '3 boutiques',
        '3 dépôts partenaires/boutique',
        '3 employés/boutique',
        'Tout Pro',
        'Backup automatique',
        'Dashboard consolidé',
        'Onboarding personnalisé',
        'Support téléphone',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: isWide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < _plans.length; i++) ...[
                      Expanded(
                          child: _PlanCard(plan: _plans[i], cycle: cycle)),
                      if (i < _plans.length - 1) const SizedBox(width: 16),
                    ],
                  ],
                )
              : Column(
                  children: [
                    for (final p in _plans) ...[
                      _PlanCard(plan: p, cycle: cycle),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class _PlanData {
  final String name;
  final String tagline;
  final int    monthly;
  final int    yearly;
  final List<String> features;
  final bool   highlight;
  const _PlanData({
    required this.name,
    required this.tagline,
    required this.monthly,
    required this.yearly,
    required this.features,
    this.highlight = false,
  });
}

class _PlanCard extends StatelessWidget {
  final _PlanData plan;
  final String    cycle;
  const _PlanCard({required this.plan, required this.cycle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fmt   = NumberFormat('#,###', 'fr_FR');
    final price = cycle == 'yearly' ? plan.yearly : plan.monthly;
    final per   = cycle == 'yearly' ? '/an' : '/mois';
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: plan.highlight
                ? AppColors.primary
                : theme.colorScheme.outline.withValues(alpha: 0.18),
            width: plan.highlight ? 2 : 1),
        boxShadow: plan.highlight
            ? [
                BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    blurRadius: 18,
                    offset: const Offset(0, 6)),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (plan.highlight)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: AppColors.primaryFill,
                  borderRadius: BorderRadius.circular(4)),
              child: Text('POPULAIRE',
                  style: AppTextStyles.micro.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: Colors.white)),
            )
          else
            const SizedBox(height: 22),
          const SizedBox(height: 10),
          Text(plan.name,
              style: AppTextStyles.title.copyWith(
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface)),
          Text(plan.tagline,
              style: AppTextStyles.bodySm.copyWith(
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.6))),
          const SizedBox(height: 16),
          Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(fmt.format(price),
                    style: AppTextStyles.display
                        .copyWith(color: theme.colorScheme.onSurface)),
                const SizedBox(width: 4),
                Text('FCFA',
                    style: AppTextStyles.body.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.7))),
                const SizedBox(width: 4),
                Text(per,
                    style: AppTextStyles.body.copyWith(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.55))),
              ]),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => context.go(RouteNames.register),
              style: ElevatedButton.styleFrom(
                backgroundColor: plan.highlight
                    ? AppColors.primary
                    : theme.colorScheme.surface,
                foregroundColor:
                    plan.highlight ? Colors.white : AppColors.primary,
                side: plan.highlight
                    ? null
                    : BorderSide(
                        color: AppColors.primary.withValues(alpha: 0.5)),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: Text('Commencer 14j gratuit',
                  style: AppTextStyles.body.copyWith(
                      fontWeight: FontWeight.w800,
                      color: plan.highlight
                          ? Colors.white
                          : AppColors.primary)),
            ),
          ),
          const SizedBox(height: 18),
          for (final f in plan.features)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                Icon(Icons.check_rounded,
                    size: 16, color: AppColors.secondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(f,
                      style: AppTextStyles.body.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.85))),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}
