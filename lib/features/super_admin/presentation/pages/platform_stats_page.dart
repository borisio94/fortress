import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_scaffold.dart';

/// SA-6 — Page super-admin de statistiques plateforme.
///
/// Affiche les indicateurs globaux de la plateforme Fortress :
/// chiffre d'affaires des abonnements, répartition des boutiques par état,
/// volume de ventes (jour / semaine / mois) et le top 5 des boutiques.
///
/// Toutes les données proviennent de [AppDatabase.getPlatformStats].
class PlatformStatsPage extends StatefulWidget {
  final String shopId;
  const PlatformStatsPage({super.key, this.shopId = ''});

  @override
  State<PlatformStatsPage> createState() => _PlatformStatsPageState();
}

class _PlatformStatsPageState extends State<PlatformStatsPage> {
  // Future re-créé à chaque pull-to-refresh pour forcer le FutureBuilder
  // à rejouer la requête.
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = AppDatabase.getPlatformStats();
  }

  Future<void> _refresh() async {
    final f = AppDatabase.getPlatformStats();
    setState(() => _future = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Statistiques',
      isRootPage: false,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<Map<String, dynamic>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const _CenteredScroll(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 64),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            if (snapshot.hasError) {
              return _CenteredScroll(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline_rounded,
                          color: AppColors.error, size: 40),
                      SizedBox(height: 12),
                      Text(
                        'Impossible de charger les statistiques.',
                        textAlign: TextAlign.center,
                        style: AppTextStyles.bodySecondary,
                      ),
                    ],
                  ),
                ),
              );
            }

            final data = snapshot.data ?? const <String, dynamic>{};
            return _buildContent(context, data);
          },
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, Map<String, dynamic> data) {
    final revenue = (data['revenue'] as num?)?.toDouble() ?? 0.0;
    final shopsActive = (data['shopsActive'] as num?)?.toInt() ?? 0;
    final shopsSuspended = (data['shopsSuspended'] as num?)?.toInt() ?? 0;
    final shopsTrial = (data['shopsTrial'] as num?)?.toInt() ?? 0;
    final salesToday = (data['salesToday'] as num?)?.toInt() ?? 0;
    final salesWeek = (data['salesWeek'] as num?)?.toInt() ?? 0;
    final salesMonth = (data['salesMonth'] as num?)?.toInt() ?? 0;
    final topShops = (data['topShops'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];

    return ListView(
      // physics always-scrollable : indispensable pour que le pull-to-refresh
      // fonctionne même quand le contenu ne remplit pas l'écran.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        _RevenueCard(revenue: revenue),
        const SizedBox(height: 16),
        const Text('Boutiques', style: AppTextStyles.subtitleBold),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _KpiCard(
                label: 'Actives',
                value: '$shopsActive',
                accent: AppColors.secondary,
                icon: Icons.check_circle_outline_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _KpiCard(
                label: 'Suspendues',
                value: '$shopsSuspended',
                accent: AppColors.error,
                icon: Icons.pause_circle_outline_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _KpiCard(
                label: 'En essai',
                value: '$shopsTrial',
                accent: AppColors.info,
                icon: Icons.hourglass_empty_rounded,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text('Ventes', style: AppTextStyles.subtitleBold),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _KpiCard(
                label: "Aujourd'hui",
                value: '$salesToday',
                accent: AppColors.primary,
                icon: Icons.today_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _KpiCard(
                label: 'Cette semaine',
                value: '$salesWeek',
                accent: AppColors.primary,
                icon: Icons.date_range_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _KpiCard(
                label: 'Ce mois',
                value: '$salesMonth',
                accent: AppColors.primary,
                icon: Icons.calendar_month_rounded,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text('Top 5 boutiques', style: AppTextStyles.subtitleBold),
        const SizedBox(height: 10),
        _TopShopsCard(topShops: topShops),
      ],
    );
  }
}

/// Wrapper scrollable pour conserver le pull-to-refresh dans les états
/// loading / erreur (contenu centré).
class _CenteredScroll extends StatelessWidget {
  final Widget child;
  const _CenteredScroll({required this.child});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [Center(child: child)],
    );
  }
}

/// Grande card mettant en avant le CA total des abonnements.
class _RevenueCard extends StatelessWidget {
  final double revenue;
  const _RevenueCard({required this.revenue});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.semantic.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.payments_outlined,
                    color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Text('CA total abonnements',
                  style: AppTextStyles.bodySecondary),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            CurrencyFormatter.format(revenue),
            style: AppTextStyles.display,
          ),
        ],
      ),
    );
  }
}

/// Card KPI compacte : icône colorée, valeur et libellé.
class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;
  final IconData icon;
  const _KpiCard({
    required this.label,
    required this.value,
    required this.accent,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.semantic.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accent, size: 20),
          const SizedBox(height: 10),
          Text(value, style: AppTextStyles.title.copyWith(color: accent)),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.caption,
          ),
        ],
      ),
    );
  }
}

/// Liste des 5 meilleures boutiques par nombre de commandes.
class _TopShopsCard extends StatelessWidget {
  final List<Map<String, dynamic>> topShops;
  const _TopShopsCard({required this.topShops});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.semantic.borderSubtle),
      ),
      child: topShops.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text('Aucune boutique',
                    style: AppTextStyles.bodySecondary),
              ),
            )
          : Column(
              children: [
                for (var i = 0; i < topShops.length; i++)
                  _TopShopRow(
                    rank: i + 1,
                    name: (topShops[i]['name'] as String?) ?? '—',
                    count: (topShops[i]['count'] as num?)?.toInt() ?? 0,
                    showDivider: i < topShops.length - 1,
                  ),
              ],
            ),
    );
  }
}

class _TopShopRow extends StatelessWidget {
  final int rank;
  final String name;
  final int count;
  final bool showDivider;
  const _TopShopRow({
    required this.rank,
    required this.name,
    required this.count,
    required this.showDivider,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: showDivider
            ? Border(
                bottom: BorderSide(color: theme.semantic.borderSubtle),
              )
            : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              shape: BoxShape.circle,
            ),
            child: Text('$rank',
                style: AppTextStyles.captionBold
                    .copyWith(color: AppColors.primary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.label,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$count cmd',
              style: AppTextStyles.captionBold
                  .copyWith(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}
