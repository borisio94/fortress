import 'package:flutter/material.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/theme/app_theme.dart';
import '../../features/subscription/domain/models/plan_type.dart';

/// Modèle d'affichage des plans tarifaires — agrège la row Supabase `plans`
/// + les limites Dart `PlanLimits` pour produire un Plan unifié consommé
/// par [PlanCard].
class PlanDisplay {
  final PlanType    type;
  final String      label;
  final double      monthlyPrice;
  final double      quarterlyPrice;
  final double      yearlyPrice;
  final int         maxShops;
  final int         maxUsersPerShop;
  /// Features actives sur ce tier (= afficher avec une icône check verte).
  final Set<Feature> features;
  /// Mode offline disponible (= badge "Hors-ligne" en footer).
  final bool        offlineEnabled;
  /// Nombre de jours d'essai (= badge "Essai X jours" en footer si > 0).
  final int         trialDays;

  const PlanDisplay({
    required this.type,
    required this.label,
    required this.monthlyPrice,
    required this.quarterlyPrice,
    required this.yearlyPrice,
    required this.maxShops,
    required this.maxUsersPerShop,
    required this.features,
    required this.offlineEnabled,
    required this.trialDays,
  });

  factory PlanDisplay.fromMap(Map<String, dynamic> m) {
    final type = PlanTypeX.fromString(m['name'] as String?);
    final limits = PlanLimits.fallback(type);

    // Privilégie les valeurs SQL si présentes (table `plans` Supabase),
    // sinon fallback sur les limites Dart pour rester cohérent offline.
    int asInt(Object? v, int fallback) =>
        v is num ? v.toInt() : (v == null ? fallback : fallback);

    Set<Feature> features;
    final rawFeatures = m['features'];
    if (rawFeatures is List) {
      features = rawFeatures
          .map((e) => FeatureX.fromString(e.toString()))
          .whereType<Feature>()
          .toSet();
    } else if (rawFeatures is Map) {
      features = rawFeatures.entries
          .where((e) => e.value == true)
          .map((e) => FeatureX.fromString(e.key.toString()))
          .whereType<Feature>()
          .toSet();
    } else {
      features = limits.features.toSet();
    }

    return PlanDisplay(
      type:           type,
      label:          (m['label'] ?? m['name'] ?? '').toString(),
      monthlyPrice:   (m['price_monthly']   as num?)?.toDouble() ?? 0,
      quarterlyPrice: (m['price_quarterly'] as num?)?.toDouble() ?? 0,
      yearlyPrice:    (m['price_yearly']    as num?)?.toDouble() ?? 0,
      maxShops:        asInt(m['max_shops'],          limits.maxShops),
      maxUsersPerShop: asInt(m['max_users_per_shop'], limits.maxUsersPerShop),
      features:        features,
      offlineEnabled:  m['offline_enabled'] == true || limits.offlineEnabled,
      trialDays:       asInt(m['trial_days'], limits.trialDays),
    );
  }
}

/// Card unique utilisée pour TOUS les plans (Trial / Starter / Pro /
/// Business). Le tier est dérivé de `plan.type` et conditionne uniquement
/// le style du header (couleur de fond + icône + couleur de texte).
class PlanCard extends StatelessWidget {
  final PlanDisplay plan;
  final VoidCallback? onEdit;

  const PlanCard({super.key, required this.plan, this.onEdit});

  bool get _isFeatured => plan.type == PlanType.pro;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isFeatured
              ? theme.colorScheme.primary
              : theme.colorScheme.outline.withValues(alpha: 0.4),
          width: _isFeatured ? 1.5 : 0.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(plan: plan, onEdit: onEdit),
            _Section(child: _PriceRows(plan: plan)),
            _Divider(),
            _Section(child: _StatsRows(plan: plan)),
            _Divider(),
            _Section(child: _FeaturesList(plan: plan)),
            if (plan.offlineEnabled || plan.trialDays > 0) ...[
              _Divider(),
              _Section(child: _Footer(plan: plan)),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Helpers de style par tier ─────────────────────────────────────────────

/// Couleurs / icône du header pour chaque tier. Résolu à chaque build car
/// `colorScheme` et `palette.primarySurface` dépendent de la palette active.
class _TierStyle {
  final Color    headerBg;
  final Color    headerFg;
  final Color    headerMuted;
  final Color    iconBoxBg;
  final Color    iconColor;
  final IconData icon;
  const _TierStyle({
    required this.headerBg,
    required this.headerFg,
    required this.headerMuted,
    required this.iconBoxBg,
    required this.iconColor,
    required this.icon,
  });
}

_TierStyle _styleFor(PlanType type, BuildContext context) {
  final theme = Theme.of(context);
  final cs    = theme.colorScheme;
  final sem   = theme.semantic;
  switch (type) {
    case PlanType.trial:
    case PlanType.expired:
      return _TierStyle(
        headerBg:    cs.surfaceContainerHighest,
        headerFg:    cs.onSurfaceVariant,
        headerMuted: cs.onSurfaceVariant.withValues(alpha: 0.7),
        iconBoxBg:   sem.warning.withValues(alpha: 0.15),
        iconColor:   sem.warning,
        icon:        Icons.hourglass_empty_rounded,
      );
    case PlanType.starter:
      return _TierStyle(
        headerBg:    sem.success.withValues(alpha: 0.12),
        headerFg:    sem.success,
        headerMuted: sem.success.withValues(alpha: 0.7),
        iconBoxBg:   sem.success.withValues(alpha: 0.18),
        iconColor:   sem.success,
        icon:        Icons.star_outline_rounded,
      );
    case PlanType.pro:
      return _TierStyle(
        headerBg:    AppColors.primarySurface,
        headerFg:    cs.primary,
        headerMuted: cs.primary.withValues(alpha: 0.7),
        iconBoxBg:   cs.primary.withValues(alpha: 0.18),
        iconColor:   cs.primary,
        icon:        Icons.workspace_premium_rounded,
      );
    case PlanType.business:
      // Seules exceptions hexa autorisées par la spec — palette neutre dorée.
      return const _TierStyle(
        headerBg:    Color(0xFF1A1A2E),
        headerFg:    Colors.white,
        headerMuted: Color(0xCCFFFFFF),
        iconBoxBg:   Color(0x33C8B97A),
        iconColor:   Color(0xFFC8B97A),
        icon:        Icons.emoji_events_rounded,
      );
  }
}

// ─── Header ────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final PlanDisplay  plan;
  final VoidCallback? onEdit;
  const _Header({required this.plan, required this.onEdit});

  String _localizedName(AppLocalizations l) => switch (plan.type) {
        PlanType.trial    => l.planTrial,
        PlanType.starter  => l.planStarter,
        PlanType.pro      => l.planPro,
        PlanType.business => l.planBusiness,
        _ => plan.label,
      };

  String _localizedDesc(AppLocalizations l) => switch (plan.type) {
        PlanType.trial    => l.planTrialDesc,
        PlanType.starter  => l.planStarterDesc,
        PlanType.pro      => l.planProDesc,
        PlanType.business => l.planBusinessDesc,
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final style = _styleFor(plan.type, context);
    return Container(
      color: style.headerBg,
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: style.iconBoxBg,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(style.icon, size: 18, color: style.iconColor),
            ),
            const Spacer(),
            if (onEdit != null)
              TextButton.icon(
                onPressed: onEdit,
                style: TextButton.styleFrom(
                  foregroundColor: style.headerFg,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: Icon(Icons.edit_outlined, size: 13,
                    color: style.headerFg),
                label: Text(l.edit,
                    style: AppTextStyles.caption.copyWith(
                        fontWeight: FontWeight.w600,
                        color: style.headerFg)),
              ),
          ]),
          const SizedBox(height: 12),
          Text(_localizedName(l),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.subtitle.copyWith(
                  color: style.headerFg)),
          const SizedBox(height: 4),
          Text(_localizedDesc(l),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.caption.copyWith(
                  color: style.headerMuted)),
        ],
      ),
    );
  }
}

// ─── Section helper (padding 12/16) ────────────────────────────────────────

class _Section extends StatelessWidget {
  final Widget child;
  const _Section({required this.child});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: child,
      );
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 0.5,
      color: theme.colorScheme.outline.withValues(alpha: 0.2),
    );
  }
}

// ─── Section 2 — Prix ──────────────────────────────────────────────────────

class _PriceRows extends StatelessWidget {
  final PlanDisplay plan;
  const _PriceRows({required this.plan});

  String _format(double v) {
    if (v <= 0) return '—';
    final intPart = v.toStringAsFixed(0);
    final buf = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(' ');
      buf.write(intPart[i]);
    }
    return '${buf.toString()} XAF';
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PriceRow(label: l.planPriceMonthly,
            amount: _format(plan.monthlyPrice)),
        const SizedBox(height: 10),
        // Badges fixes selon la spec super-admin : -10% trimestriel,
        // -17% annuel (peu importe les prix saisis).
        _PriceRow(
          label: l.planPriceQuarterly,
          amount: _format(plan.quarterlyPrice),
          savingsPercent: plan.quarterlyPrice > 0 ? 10 : null,
        ),
        const SizedBox(height: 10),
        _PriceRow(
          label: l.planPriceYearly,
          amount: _format(plan.yearlyPrice),
          savingsPercent: plan.yearlyPrice > 0 ? 17 : null,
        ),
      ],
    );
  }
}

class _PriceRow extends StatelessWidget {
  final String label;
  final String amount;
  final int?   savingsPercent;
  const _PriceRow({
    required this.label,
    required this.amount,
    this.savingsPercent,
  });

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    return Row(children: [
      Expanded(
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 2,
          children: [
            Text(label,
                style: AppTextStyles.caption.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
            if (savingsPercent != null)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: sem.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(l.planSavingsBadge(savingsPercent!),
                    style: AppTextStyles.micro.copyWith(
                        fontWeight: FontWeight.w700,
                        color: sem.success)),
              ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      Text(amount,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.label.copyWith(
              color: theme.colorScheme.primary)),
    ]);
  }
}

// ─── Section 3 — Stats ─────────────────────────────────────────────────────

class _StatsRows extends StatelessWidget {
  final PlanDisplay plan;
  const _StatsRows({required this.plan});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Row(children: [
      Expanded(
        child: _StatItem(
          icon: Icons.storefront_outlined,
          text: l.planMaxShops(plan.maxShops),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: _StatItem(
          icon: Icons.people_outline_rounded,
          text: l.planMaxUsersPerShop(plan.maxUsersPerShop),
        ),
      ),
    ]);
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String   text;
  const _StatItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      Icon(icon, size: 12, color: theme.colorScheme.primary),
      const SizedBox(width: 6),
      Expanded(
        child: Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.caption.copyWith(
                color: theme.colorScheme.onSurfaceVariant)),
      ),
    ]);
  }
}

// ─── Section 4 — Fonctionnalités ──────────────────────────────────────────

/// Token symbolique pour les features qui n'existent pas dans l'enum
/// `Feature` côté Dart (cf. plan_type.dart) — résolues côté UI uniquement.
enum _ExtraFeature { supportPriority, hubCentral, base }

class _FeatureItem {
  final Object featureKey;  // Feature ou _ExtraFeature
  final String label;
  const _FeatureItem(this.featureKey, this.label);
}

class _FeaturesList extends StatelessWidget {
  final PlanDisplay plan;
  const _FeaturesList({required this.plan});

  /// 10 features dans l'ordre fixe défini par la spec.
  List<_FeatureItem> _items(AppLocalizations l) => [
        _FeatureItem(_ExtraFeature.base,        l.featCaisseLong),
        _FeatureItem(_ExtraFeature.base,        l.featInventaireLong),
        _FeatureItem(_ExtraFeature.base,        l.featClientsLong),
        _FeatureItem(Feature.advancedReports,   l.featAdvancedReports),
        _FeatureItem(Feature.csvExport,         l.featCsvExport),
        _FeatureItem(Feature.finances,          l.featFinances),
        _FeatureItem(Feature.multiShop,         l.featMultiShop),
        _FeatureItem(Feature.apiIntegration,    l.featApiIntegration),
        _FeatureItem(_ExtraFeature.supportPriority, l.featSupportPriority),
        _FeatureItem(_ExtraFeature.hubCentral,  l.featHubCentral),
      ];

  /// Décide si une feature est active sur ce plan.
  /// - `_ExtraFeature.base` : actives sur tous les tiers payants (= pas
  ///   `expired`). `trial` les a aussi (sinon l'app n'aurait aucun intérêt).
  /// - `Feature.*` : actives si la liste `plan.features` les contient.
  /// - `_ExtraFeature.supportPriority` : Pro / Business uniquement.
  /// - `_ExtraFeature.hubCentral` : Business uniquement.
  bool _isActive(Object key) {
    if (key == _ExtraFeature.base) {
      return plan.type != PlanType.expired;
    }
    if (key == _ExtraFeature.supportPriority) {
      return plan.type == PlanType.pro || plan.type == PlanType.business;
    }
    if (key == _ExtraFeature.hubCentral) {
      return plan.type == PlanType.business;
    }
    if (key is Feature) return plan.features.contains(key);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final theme = Theme.of(context);
    final items = _items(l);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l.planFeaturesTitle.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.micro.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: theme.colorScheme.onSurface
                    .withValues(alpha: 0.5))),
        const SizedBox(height: 8),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _FeatureRow(
                label: it.label, active: _isActive(it.featureKey)),
          ),
      ],
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final String label;
  final bool   active;
  const _FeatureRow({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final sem      = theme.semantic;
    final tertiary = theme.colorScheme.onSurface.withValues(alpha: 0.4);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(
        active ? Icons.check_circle_outline : Icons.cancel_outlined,
        size: 14,
        color: active ? sem.success : tertiary,
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.caption.copyWith(
                color: active ? theme.colorScheme.onSurface : tertiary)),
      ),
    ]);
  }
}

// ─── Section 5 — Footer (badges hors-ligne / essai) ────────────────────────

class _Footer extends StatelessWidget {
  final PlanDisplay plan;
  const _Footer({required this.plan});

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (plan.offlineEnabled)
          _Badge(
            icon: Icons.wifi_off_rounded,
            label: l.planOffline,
            bg:    AppColors.primarySurface,
            fg:    theme.colorScheme.primary,
          ),
        if (plan.trialDays > 0)
          _Badge(
            icon: Icons.timer_outlined,
            label: l.planTrialBadge(plan.trialDays),
            bg:    sem.warning.withValues(alpha: 0.12),
            fg:    sem.warning,
          ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    bg;
  final Color    fg;
  const _Badge({
    required this.icon,
    required this.label,
    required this.bg,
    required this.fg,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: fg)),
          ),
        ]),
      );
}
