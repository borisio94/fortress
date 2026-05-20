import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/plan_card.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../subscription/domain/models/plan_type.dart';

/// Page super admin — vue d'ensemble des 4 plans tarifaires
/// (Essai / Starter / Pro / Business). Layout responsive : grille 2
/// colonnes sur desktop, liste verticale sur mobile.
class PlansPage extends StatefulWidget {
  final String shopId;
  const PlansPage({super.key, this.shopId = ''});

  @override
  State<PlansPage> createState() => _PlansPageState();
}

class _PlansPageState extends State<PlansPage> {
  late Future<List<PlanDisplay>> _future;

  /// Ordre d'affichage des cards (Trial en 1er, Business en dernier).
  static const _orderedTiers = [
    PlanType.trial,
    PlanType.starter,
    PlanType.pro,
    PlanType.business,
  ];

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<PlanDisplay>> _load() async {
    final db = Supabase.instance.client;
    final rows = await db
        .from('plans')
        .select('id, name, label, price_monthly, price_quarterly, '
            'price_yearly, is_active')
        .eq('is_active', true);

    final byType = <PlanType, PlanDisplay>{};
    for (final raw in (rows as List)) {
      final m = Map<String, dynamic>.from(raw as Map);
      final p = PlanDisplay.fromMap(m);
      byType[p.type] = p;
    }
    return [
      for (final t in _orderedTiers)
        if (byType.containsKey(t)) byType[t]!,
    ];
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  void _openEditFor(PlanDisplay plan) {
    AppSnack.info(context,
        'Édition du plan "${plan.label}" — disponible sur la page Abonnements.');
  }

  void _openAddPlan() {
    AppSnack.info(context,
        'Ajout d\'un plan — à brancher sur l\'API admin.');
  }

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final theme = Theme.of(context);
    return AppScaffold(
      shopId: widget.shopId,
      title: l.planTitle,
      isRootPage: false,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<PlanDisplay>>(
          future: _future,
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return ListView(children: [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text('${snap.error}',
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySm),
                  ),
                ),
              ]);
            }
            final plans = snap.data ?? const [];

            return LayoutBuilder(builder: (_, c) {
              // Desktop ≥ 700 → grille 2 colonnes ; mobile → liste.
              final isWide = c.maxWidth > 700;
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  // Header : titre + bouton "+ Ajouter un plan"
                  Row(children: [
                    Expanded(
                      child: Text(l.planTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.title.copyWith(
                              fontWeight: FontWeight.w800,
                              color: theme.colorScheme.onSurface)),
                    ),
                    ElevatedButton.icon(
                      onPressed: _openAddPlan,
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: Text(l.planAddNew,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodySmBold),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 16),

                  // Cards : grille 2 colonnes (desktop) ou liste (mobile)
                  if (isWide)
                    _DesktopGrid(
                      plans: plans,
                      onEdit: _openEditFor,
                    )
                  else
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < plans.length; i++) ...[
                          if (i > 0) const SizedBox(height: 12),
                          PlanCard(
                            plan: plans[i],
                            onEdit: () => _openEditFor(plans[i]),
                          ),
                        ],
                      ],
                    ),
                ],
              );
            });
          },
        ),
      ),
    );
  }
}

/// Grille 2 colonnes (desktop) — paire les cards 2 par 2 dans des Row
/// à hauteur intrinsèque pour aligner verticalement.
class _DesktopGrid extends StatelessWidget {
  final List<PlanDisplay>     plans;
  final void Function(PlanDisplay) onEdit;
  const _DesktopGrid({required this.plans, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (int i = 0; i < plans.length; i += 2) {
      final left  = plans[i];
      final right = i + 1 < plans.length ? plans[i + 1] : null;
      rows.add(
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: PlanCard(
                plan: left,
                onEdit: () => onEdit(left),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: right == null
                  ? const SizedBox()
                  : PlanCard(
                      plan: right,
                      onEdit: () => onEdit(right),
                    ),
            ),
          ]),
        ),
      );
      if (i + 2 < plans.length) rows.add(const SizedBox(height: 12));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }
}
