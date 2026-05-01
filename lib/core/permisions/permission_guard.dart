import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../i18n/app_localizations.dart';
import '../router/route_names.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'subscription_provider.dart';
import 'app_permissions.dart';
import 'user_plan.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../storage/hive_boxes.dart';

// ─── Widget garde-fou pour les actions protégées ──────────────────────────────
// Usage :
//   PermissionGuard(
//     shopId: shopId,
//     check: (p) => p.canEditProduct,
//     child: ElevatedButton(...),
//   )

class PermissionGuard extends ConsumerWidget {
  final String           shopId;
  final bool Function(AppPermissions) check;
  final Widget           child;
  final Widget?          fallback;    // affiché si pas le droit
  final bool             hideIfDenied; // masquer plutôt que désactiver

  const PermissionGuard({
    super.key,
    required this.shopId,
    required this.check,
    required this.child,
    this.fallback,
    this.hideIfDenied = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider(shopId));
    final allowed = check(perms);

    if (allowed) return child;
    if (hideIfDenied) return const SizedBox.shrink();
    return fallback ?? const SizedBox.shrink();
  }
}

// ─── Bannière abonnement expiré ───────────────────────────────────────────────
// Couleurs via theme.semantic. Textes via context.l10n.
// À insérer dans le layout principal des shells (sous l'AppBar) pour qu'elle
// s'affiche automatiquement quand le plan passe en mode dégradé.
class SubscriptionBanner extends ConsumerWidget {
  const SubscriptionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Bannière abonnement réservée au propriétaire. Un employé ou un admin
    // n'a pas à voir l'état du plan ni le bouton "Renouveler" — son plan
    // hérite du owner via get_user_plan, mais c'est au owner de gérer la
    // souscription. On détecte "owner" par la présence d'au moins une
    // boutique dont owner_id == auth.uid() en cache local.
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid != null) {
      final isOwner = HiveBoxes.shopsBox.values.any((raw) {
        try {
          final m = Map<String, dynamic>.from(raw as Map);
          return m['owner_id'] == uid;
        } catch (_) { return false; }
      });
      if (!isOwner) return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final planAsync = ref.watch(subscriptionProvider);
    return planAsync.when(
      loading: () => const SizedBox.shrink(),
      error:   (_, __) => const SizedBox.shrink(),
      data: (plan) {
        if (plan.isBlocked) {
          return _Banner(
            color: sem.danger,
            icon:  Icons.block_rounded,
            message: l.subBannerBlocked,
          );
        }
        if (plan.isExpired) {
          return _Banner(
            color: sem.danger,
            icon:  Icons.warning_amber_rounded,
            message: l.subBannerExpired,
            action: l.upgradeRenew,
            onAction: () => _openSubscription(context),
          );
        }
        if (plan.expiresSoon) {
          return _Banner(
            color: sem.warning,
            icon:  Icons.access_time_rounded,
            message: l.subBannerExpiresSoon(plan.daysLeft),
            action: l.upgradeRenew,
            onAction: () => _openSubscription(context),
          );
        }
        if (!plan.hasPlan) {
          return _Banner(
            color: cs.primary,
            icon:  Icons.stars_rounded,
            message: l.subBannerNoPlan,
            action: l.subBannerChoose,
            onAction: () => _openSubscription(context),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  void _openSubscription(BuildContext context) {
    context.push(RouteNames.subscription);
  }
}

// ─── Mixin pratique pour les pages qui vérifient les permissions ──────────────
mixin PermissionMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  String get currentShopId;

  AppPermissions get perms =>
      ref.read(permissionsProvider(currentShopId));

  bool can(bool Function(AppPermissions) check) => check(perms);

  void requirePermission(
      bool Function(AppPermissions) check, {
        required VoidCallback onAllowed,
        String? deniedMessage,
      }) {
    if (check(perms)) {
      onAllowed();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(deniedMessage ?? 'Action non autorisée.'),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}

// ─── Composant interne ────────────────────────────────────────────────────────
class _Banner extends StatelessWidget {
  final Color   color;
  final IconData icon;
  final String  message;
  final String? action;
  final VoidCallback? onAction;
  const _Banner({required this.color, required this.icon,
    required this.message, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: color.withOpacity(0.12),
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(message,
            style: TextStyle(fontSize: 12, color: color,
                fontWeight: FontWeight.w500))),
        if (action != null && onAction != null)
          GestureDetector(
            onTap: onAction,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8)),
              child: Text(action!,
                  style: TextStyle(fontSize: 11,
                      fontWeight: FontWeight.w700, color: cs.onPrimary)),
            ),
          ),
      ]),
    );
  }
}