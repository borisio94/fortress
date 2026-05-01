import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/models/plan_type.dart';

// ═════════════════════════════════════════════════════════════════════════════
// SubscriptionGuard — wrappe une action sensible derrière un feature flag.
//
// Mode `feature` : check `currentPlanProvider.hasFeature(feature)`.
// Mode `quotaShop/User/Product` : check `canAddShop/User/Product(count)`.
//
// Si la condition est remplie → affiche `child`.
// Sinon :
//   - `hideIfDenied: true`    → enfant invisible (SizedBox.shrink).
//   - `lockedChild` fourni    → affiche ce widget custom à la place.
//   - sinon                   → enfant grisé + cadenas, tap → UpgradeSheet.
// ═════════════════════════════════════════════════════════════════════════════

class SubscriptionGuard extends ConsumerWidget {
  /// Mode `feature` : la feature doit être incluse dans le plan courant.
  final Feature? feature;
  /// Mode `quota shops` : true si `child` est rendu pour une création de
  /// boutique ; on vérifie `canAddShop(quotaCurrent)`.
  final bool isQuotaShop;
  /// Mode `quota users` : `canAddUser(quotaCurrent)`.
  final bool isQuotaUser;
  /// Mode `quota products` : `canAddProduct(quotaCurrent)`.
  final bool isQuotaProduct;
  /// Compteur courant (utilisé seulement en mode quota).
  final int  quotaCurrent;

  final Widget        child;
  final Widget?       lockedChild;
  final bool          hideIfDenied;

  const SubscriptionGuard.feature({
    super.key,
    required this.feature,
    required this.child,
    this.lockedChild,
    this.hideIfDenied = false,
  })  : isQuotaShop    = false,
        isQuotaUser    = false,
        isQuotaProduct = false,
        quotaCurrent   = 0;

  const SubscriptionGuard.shopQuota({
    super.key,
    required int currentShopCount,
    required this.child,
    this.lockedChild,
    this.hideIfDenied = false,
  })  : feature        = null,
        isQuotaShop    = true,
        isQuotaUser    = false,
        isQuotaProduct = false,
        quotaCurrent   = currentShopCount;

  const SubscriptionGuard.userQuota({
    super.key,
    required int currentUserCount,
    required this.child,
    this.lockedChild,
    this.hideIfDenied = false,
  })  : feature        = null,
        isQuotaShop    = false,
        isQuotaUser    = true,
        isQuotaProduct = false,
        quotaCurrent   = currentUserCount;

  const SubscriptionGuard.productQuota({
    super.key,
    required int currentProductCount,
    required this.child,
    this.lockedChild,
    this.hideIfDenied = false,
  })  : feature        = null,
        isQuotaShop    = false,
        isQuotaUser    = false,
        isQuotaProduct = true,
        quotaCurrent   = currentProductCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(currentPlanProvider);

    // Évaluation de la condition selon le mode.
    final bool allowed;
    if (feature != null) {
      allowed = plan.hasFeature(feature!);
    } else if (isQuotaShop) {
      allowed = plan.canAddShop(quotaCurrent);
    } else if (isQuotaUser) {
      allowed = plan.canAddUser(quotaCurrent);
    } else if (isQuotaProduct) {
      allowed = plan.canAddProduct(quotaCurrent);
    } else {
      allowed = true;
    }

    if (allowed) return child;
    if (hideIfDenied) return const SizedBox.shrink();
    if (lockedChild != null) return lockedChild!;

    return _LockedDecorator(
      onTap: () {
        if (feature != null) {
          UpgradeSheet.showFeature(context, feature: feature!);
        } else {
          // Quota — déterminer le label et le plan recommandé selon le mode.
          final l = context.l10n;
          final label = isQuotaShop
              ? l.featMultiShop
              : (isQuotaUser ? l.paramEmployes : l.navInventaire);
          final maxValue = isQuotaShop
              ? plan.maxShops
              : (isQuotaUser ? plan.maxUsersPerShop : plan.maxProducts);
          UpgradeSheet.showQuota(
            context,
            label:    label,
            current:  quotaCurrent,
            max:      maxValue,
            recommended: isQuotaProduct
                ? PlanType.pro
                : (isQuotaShop ? PlanType.pro : PlanType.pro),
          );
        }
      },
      child: child,
    );
  }
}

/// Décorateur visuel : enfant grisé + cadenas, tap → UpgradeSheet.
class _LockedDecorator extends StatelessWidget {
  final Widget       child;
  final VoidCallback onTap;
  const _LockedDecorator({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(clipBehavior: Clip.none, children: [
      Opacity(opacity: 0.45, child: IgnorePointer(child: child)),
      Positioned.fill(child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Center(child: Icon(Icons.lock_rounded,
              size: 16, color: cs.onSurface.withOpacity(0.55))),
        ),
      )),
    ]);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// UpgradeSheet — bottom sheet d'incitation à l'upgrade.
//
// 3 entrées statiques :
//   - showFeature  : feature non incluse dans le plan courant
//   - showQuota    : limite quantitative atteinte
//   - showExpired  : abonnement expiré
//
// Toutes les couleurs via `Theme.of(context)` + `theme.semantic`.
// Aucun texte hardcodé — tout via context.l10n.
// ═════════════════════════════════════════════════════════════════════════════

enum _UpgradeReason { feature, quota, expired }

class UpgradeSheet extends StatelessWidget {
  final _UpgradeReason reason;
  final Feature?       feature;
  final String?        quotaLabel;
  final int?           quotaCurrent;
  final int?           quotaMax;
  final PlanType?      recommended;

  const UpgradeSheet._({
    required this.reason,
    this.feature,
    this.quotaLabel,
    this.quotaCurrent,
    this.quotaMax,
    this.recommended,
  });

  /// Sheet pour une feature non incluse dans le plan courant.
  static Future<void> showFeature(BuildContext context,
      {required Feature feature}) {
    final reco = _recommendedFor(feature);
    return _show(context, UpgradeSheet._(
      reason:      _UpgradeReason.feature,
      feature:     feature,
      recommended: reco,
    ));
  }

  /// Sheet pour un quota atteint (boutiques, produits, membres).
  static Future<void> showQuota(BuildContext context, {
    required String label,
    required int current,
    required int max,
    PlanType recommended = PlanType.pro,
  }) {
    return _show(context, UpgradeSheet._(
      reason:       _UpgradeReason.quota,
      quotaLabel:   label,
      quotaCurrent: current,
      quotaMax:     max,
      recommended:  recommended,
    ));
  }

  /// Sheet pour un abonnement expiré (mode dégradé).
  static Future<void> showExpired(BuildContext context) {
    return _show(context, const UpgradeSheet._(
      reason: _UpgradeReason.expired,
    ));
  }

  static Future<void> _show(BuildContext context, UpgradeSheet sheet) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => sheet,
    );
  }

  /// Plan minimum recommandé pour débloquer la feature.
  static PlanType _recommendedFor(Feature f) {
    switch (f) {
      case Feature.whatsappAuto:    return PlanType.starter;
      case Feature.multiShop:
      case Feature.advancedReports:
      case Feature.csvExport:
      case Feature.finances:        return PlanType.pro;
      case Feature.apiIntegration:  return PlanType.business;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;

    final accent = reason == _UpgradeReason.expired ? sem.danger : sem.warning;
    final icon = switch (reason) {
      _UpgradeReason.expired  => Icons.lock_clock_rounded,
      _UpgradeReason.quota    => Icons.dashboard_customize_rounded,
      _UpgradeReason.feature  => Icons.workspace_premium_rounded,
    };
    final title = switch (reason) {
      _UpgradeReason.feature  => l.upgradeFeatureTitle,
      _UpgradeReason.quota    => l.upgradeQuotaTitle,
      _UpgradeReason.expired  => l.upgradeExpiredTitle,
    };
    final body = switch (reason) {
      _UpgradeReason.feature  =>
        l.upgradeFeatureBody(_featureLabel(l, feature!),
            _planLabel(l, recommended ?? PlanType.pro)),
      _UpgradeReason.quota    =>
        l.upgradeQuotaBody(quotaLabel ?? '—', '${quotaCurrent ?? 0}',
            '${quotaMax ?? 0}', _planLabel(l, recommended ?? PlanType.pro)),
      _UpgradeReason.expired  => l.upgradeExpiredBody,
    };
    final cta = reason == _UpgradeReason.expired
        ? l.upgradeRenew
        : l.upgradeViewPlans;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 36, height: 4,
              decoration: BoxDecoration(
                  color: sem.borderSubtle,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 18),
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, size: 28, color: accent),
          ),
          const SizedBox(height: 14),
          Text(title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                  fontSize: 16, fontWeight: FontWeight.w800,
                  color: cs.onSurface)),
          const SizedBox(height: 8),
          Text(body,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, height: 1.5,
                  color: cs.onSurface.withOpacity(0.7))),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity, height: 46,
            child: ElevatedButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                context.push(RouteNames.subscription);
              },
              icon: const Icon(Icons.arrow_forward_rounded, size: 16),
              label: Text(cta,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l.commonCancel,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.7))),
          ),
        ]),
      ),
    );
  }

  static String _featureLabel(AppLocalizations l, Feature f) {
    switch (f) {
      case Feature.multiShop:        return l.featMultiShop;
      case Feature.advancedReports:  return l.featAdvancedReports;
      case Feature.csvExport:        return l.featCsvExport;
      case Feature.finances:         return l.featFinances;
      case Feature.apiIntegration:   return l.featApiIntegration;
      case Feature.whatsappAuto:     return l.featWhatsappAuto;
    }
  }

  static String _planLabel(AppLocalizations l, PlanType p) {
    switch (p) {
      case PlanType.trial:    return l.planTrial;
      case PlanType.starter:  return l.planStarter;
      case PlanType.pro:      return l.planPro;
      case PlanType.business: return l.planBusiness;
      case PlanType.expired:  return l.planExpired;
    }
  }
}
