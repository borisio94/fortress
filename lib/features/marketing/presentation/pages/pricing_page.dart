import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../widgets/pricing_compare_table.dart';
import '../widgets/pricing_plan_cards.dart';
import '../widgets/public_footer.dart';
import '../widgets/public_top_bar.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PricingPage — page publique `/pricing`. Affiche les 3 plans payants
// (Starter / Pro / Business) avec toggle Mensuel/Annuel et un tableau
// comparatif court (10 lignes). Le plan 'trial' n'est PAS affiché ici :
// il est masqué via `is_active=false` côté SQL (hotfix_063), géré comme
// statut auto à l'inscription, pas comme tier commercial.
//
// Prix hardcodés alignés sur hotfix_063_pricing_canvas_v2.sql.
// Annuel = mensuel × 9 (≈ -25 % vs 12 mois).
// ═════════════════════════════════════════════════════════════════════════════

class PricingPage extends StatefulWidget {
  const PricingPage({super.key});
  @override
  State<PricingPage> createState() => _PricingPageState();
}

class _PricingPageState extends State<PricingPage> {
  /// `monthly` ou `yearly`. Sélecteur en haut de page.
  String _cycle = 'monthly';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Column(children: [
        const PublicTopBar(currentRoute: RouteNames.pricing),
        Expanded(
          child: SingleChildScrollView(
            child: Column(children: [
              _Header(
                  cycle: _cycle,
                  onChangeCycle: (v) => setState(() => _cycle = v)),
              PricingPlanCards(cycle: _cycle),
              const PricingCompareTable(),
              const _FinalCta(),
              const PublicFooter(),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ─── Header + toggle Mensuel / Annuel ─────────────────────────────────────

class _Header extends StatelessWidget {
  final String                 cycle;
  final ValueChanged<String>   onChangeCycle;
  const _Header({required this.cycle, required this.onChangeCycle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(children: [
            Text('Un plan pour chaque taille de commerce',
                textAlign: TextAlign.center,
                style: AppTextStyles.display.copyWith(
                    height: 1.15,
                    color: theme.colorScheme.onSurface)),
            const SizedBox(height: 12),
            Text(
                '14 jours d\'essai gratuit. Toutes les fonctionnalités. '
                'Sans carte bancaire.',
                textAlign: TextAlign.center,
                style: AppTextStyles.labelRegular.copyWith(
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.7))),
            const SizedBox(height: 24),
            _CycleToggle(cycle: cycle, onChange: onChangeCycle),
          ]),
        ),
      ),
    );
  }
}

class _CycleToggle extends StatelessWidget {
  final String                 cycle;
  final ValueChanged<String>   onChange;
  const _CycleToggle({required this.cycle, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.15))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _ToggleButton(
          label: 'Mensuel',
          active: cycle == 'monthly',
          onTap: () => onChange('monthly'),
        ),
        _ToggleButton(
          label: 'Annuel  -25 %',
          active: cycle == 'yearly',
          onTap: () => onChange('yearly'),
        ),
      ]),
    );
  }
}

class _ToggleButton extends StatelessWidget {
  final String       label;
  final bool         active;
  final VoidCallback onTap;
  const _ToggleButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(
            horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
            color: active ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(7)),
        child: Text(label,
            style: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.w700,
                color: active
                    ? Colors.white
                    : theme.colorScheme.onSurface
                        .withValues(alpha: 0.75))),
      ),
    );
  }
}

// ─── CTA final ────────────────────────────────────────────────────────────

class _FinalCta extends StatelessWidget {
  const _FinalCta();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 56),
      child: Center(
        child: Column(children: [
          Text('Prêt à digitaliser votre boutique ?',
              textAlign: TextAlign.center,
              style: AppTextStyles.display
                  .copyWith(color: theme.colorScheme.onSurface)),
          const SizedBox(height: 18),
          ElevatedButton(
            onPressed: () => context.go(RouteNames.register),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryFill,
              foregroundColor: Colors.white,
              elevation: 0,
              padding:
                  const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('Essayer 14 jours gratuit',
                style: AppTextStyles.label.copyWith(
                    fontWeight: FontWeight.w800, color: Colors.white)),
          ),
        ]),
      ),
    );
  }
}
