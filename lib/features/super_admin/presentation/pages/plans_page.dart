import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../widgets/plan_form_sheet.dart';

/// Page super admin — gestion CRUD des plans tarifaires (SA-2).
/// Liste TOUS les plans (actifs + inactifs, ordonnés par `sort_order`) à
/// partir de la table `plans`. Création / édition via `PlanFormSheet`
/// (RPC `upsert_plan`, réservée super-admin).
class PlansPage extends StatefulWidget {
  final String shopId;
  const PlansPage({super.key, this.shopId = ''});

  @override
  State<PlansPage> createState() => _PlansPageState();
}

class _PlansPageState extends State<PlansPage> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await Supabase.instance.client
        .from('plans')
        .select()
        .order('is_active', ascending: false)
        .order('sort_order');
    return [
      for (final r in (rows as List)) Map<String, dynamic>.from(r as Map),
    ];
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _openForm({Map<String, dynamic>? plan}) async {
    final saved = await showFormSheet<bool>(
      context: context,
      builder: (_) => PlanFormSheet(existing: plan),
    );
    if (saved == true) _refresh();
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
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return ListView(children: [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(child: Text('${snap.error}',
                      maxLines: 4, overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySm)),
                ),
              ]);
            }
            final plans = snap.data ?? const [];
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                Row(children: [
                  Expanded(
                    child: Text(l.planTitle,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.title.copyWith(
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurface)),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => _openForm(),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: Text(l.planAddNew,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
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
                for (final p in plans) ...[
                  _PlanRow(plan: p, onEdit: () => _openForm(plan: p)),
                  const SizedBox(height: 10),
                ],
                if (plans.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(child: Text('Aucun plan',
                        style: AppTextStyles.bodySmSecondary)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PlanRow extends StatelessWidget {
  final Map<String, dynamic> plan;
  final VoidCallback onEdit;
  const _PlanRow({required this.plan, required this.onEdit});

  String _fmt(dynamic v) =>
      CurrencyFormatter.format((v as num?)?.toDouble() ?? 0);

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final active = plan['is_active'] as bool? ?? true;
    final feats  = ((plan['features'] as List?) ?? const [])
        .map((e) => e.toString()).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: active
            ? theme.semantic.borderSubtle
            : AppColors.error.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(plan['label']?.toString() ?? plan['name']?.toString() ?? '—',
              style: AppTextStyles.bodyBold)),
          if (!active)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(5)),
              child: Text('Inactif', style: AppTextStyles.microBold
                  .copyWith(color: AppColors.error)),
            ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: AppColors.primary,
            tooltip: 'Modifier',
            onPressed: onEdit,
          ),
        ]),
        Text('${_fmt(plan['price_monthly'])} /mois · '
            '${_fmt(plan['price_yearly'])} /an',
            style: AppTextStyles.caption),
        const SizedBox(height: 4),
        Text('Produits : ${plan['max_products'] ?? '—'} · '
            'Membres : ${plan['max_users_per_shop'] ?? '—'} · '
            'Boutiques : ${plan['max_shops'] ?? '—'}',
            style: AppTextStyles.micro.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
        if (feats.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final f in feats)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(f, style: AppTextStyles.micro
                    .copyWith(color: AppColors.primary)),
              ),
          ]),
        ],
      ]),
    );
  }
}
