import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PricingCompareTable — tableau comparatif synthétique des 3 plans
// (Starter / Pro / Business). Lignes hardcodées alignées sur les features
// décrites dans `_PlanCard.features` côté `pricing_page.dart` + sur les
// limites SQL `plans` (hotfix_063). À mettre à jour ensemble si une feature
// est ajoutée à un tier.
// ═════════════════════════════════════════════════════════════════════════════

class PricingCompareTable extends StatelessWidget {
  const PricingCompareTable({super.key});

  /// Lignes du tableau. Format : [label, starter, pro, business].
  /// `✓` = inclus · `—` = non inclus · valeur explicite sinon.
  static const _rows = <List<String>>[
    ['Boutiques',                       '1',     '1',     '3'],
    ['Dépôts partenaires par boutique', '1',     '3',     '3'],
    ['Employés par boutique',           '1',     '3',     '3'],
    ['Produits',                        '500',   '∞',     '∞'],
    ['Caisse offline-first',            '✓',     '✓',     '✓'],
    ['Catalogue WhatsApp',              '✓',     '✓',     '✓'],
    ['Commandes programmées',           '—',     '✓',     '✓'],
    ['Transfert livreur',               '—',     '✓',     '✓'],
    ['Rapports avancés',                '—',     '✓',     '✓'],
    ['Exports Excel',                   '—',     '✓',     '✓'],
    ['Backup automatique',              '—',     '—',     '✓'],
    ['Dashboard consolidé',             '—',     '—',     '✓'],
    ['Support',                         'Email', 'Email', 'Téléphone'],
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      color: theme.colorScheme.surfaceContainerHighest
          .withValues(alpha: 0.25),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Comparatif détaillé',
                  style: AppTextStyles.title.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurface)),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: theme.colorScheme.outline
                            .withValues(alpha: 0.15))),
                child: Column(children: [
                  _HeaderRow(theme: theme),
                  for (var i = 0; i < _rows.length; i++)
                    _DataRow(theme: theme, row: _rows[i], odd: i.isOdd),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final ThemeData theme;
  const _HeaderRow({required this.theme});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.08),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(12))),
        child: Row(children: [
          Expanded(flex: 4, child: Text('Fonctionnalité',
              style: AppTextStyles.bodySm.copyWith(
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface))),
          for (final name in ['Starter', 'Pro', 'Business'])
            Expanded(
              child: Center(
                child: Text(name,
                    style: AppTextStyles.bodySm.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary)),
              ),
            ),
        ]),
      );
}

class _DataRow extends StatelessWidget {
  final ThemeData    theme;
  final List<String> row;
  final bool         odd;
  const _DataRow(
      {required this.theme, required this.row, required this.odd});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
            color: odd
                ? theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.2)
                : null),
        child: Row(children: [
          Expanded(flex: 4, child: Text(row[0],
              style: AppTextStyles.bodySm.copyWith(
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.85)))),
          for (var i = 1; i <= 3; i++)
            Expanded(
              child: Center(
                child: Text(row[i],
                    style: AppTextStyles.bodySm.copyWith(
                        fontWeight: row[i] == '✓'
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: row[i] == '—'
                            ? theme.colorScheme.onSurface
                                .withValues(alpha: 0.35)
                            : row[i] == '✓'
                                ? AppColors.secondary
                                : theme.colorScheme.onSurface
                                    .withValues(alpha: 0.8))),
              ),
            ),
        ]),
      );
}
