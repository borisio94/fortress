import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/permisions/app_permissions.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/app_switch.dart';
import 'danger_action_page.dart';
import '../../../../core/services/pin_service.dart';
import '../../../../core/widgets/owner_pin_dialog.dart';
import '../../../../core/widgets/owner_pin_setup_dialog.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/storage/secure_storage.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../../auth/domain/entities/user.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/bloc/auth_event.dart';

class ParametresPage extends ConsumerWidget {
  final String shopId;
  const ParametresPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l     = context.l10n;
    final shop  = ref.watch(currentShopProvider);
    final user  = LocalStorageService.getCurrentUser();
    final perms = ref.watch(permissionsProvider(shopId));

    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [

          // ── Header profil ─────────────────────────────────────────
          _ProfileHeader(user: user, shop: shop?.name, perms: perms),
          const SizedBox(height: 20),

          // ── Boutique ──────────────────────────────────────────────
          // Visibilité selon rôle (spec hotfix_024) :
          //   - user  : section masquée
          //   - admin : Membres + Paramètres boutique (lecture)
          //   - owner : tout
          if (perms.isShopAdmin) ...[
            _Section(
              label: l.paramBoutique,
              icon: Icons.storefront_rounded,
              color: AppColors.primary,
              tiles: [
                _Tile(
                  icon: Icons.tune_rounded,
                  label: l.paramBoutiqueSettings,
                  subtitle: perms.canEditShopInfo
                      ? l.paramBoutiqueSubtitle
                      : l.paramReadOnly,
                  color: AppColors.primary,
                  locked: !perms.canEditShopInfo,
                  onTap: () => context.push(
                      '/shop/$shopId/parametres/shop?with_overview=1'),
                ),
                // Configuration caisse → owner uniquement (config sensible)
                if (perms.isOwner)
                  _Tile(
                    icon: Icons.point_of_sale_rounded,
                    label: l.paramCaisseConfig,
                    subtitle: l.paramCaisseSubtitle,
                    color: AppColors.primary,
                    onTap: () =>
                        context.push('/shop/$shopId/parametres/caisse'),
                  ),
                // Membres : admin (peut inviter) ET owner
                if (perms.canManageMembers)
                  _Tile(
                    icon: Icons.people_rounded,
                    label: l.paramEmployes,
                    subtitle: l.paramEmployesSubtitle,
                    color: AppColors.primary,
                    onTap: () =>
                        context.push('/shop/$shopId/parametres/users'),
                  ),
                // Emplacements de stock → owner uniquement
                if (perms.isOwner)
                  _Tile(
                    icon: Icons.warehouse_rounded,
                    label: 'Emplacements de stock',
                    subtitle: 'Magasins centraux et dépôts partenaires',
                    color: AppColors.primary,
                    onTap: () =>
                        context.push('/shop/$shopId/parametres/locations'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // ── Compte (personnel) ────────────────────────────────────
          _Section(
            label: l.paramCompte,
            icon: Icons.person_rounded,
            color: const Color(0xFF0EA5E9),
            tiles: [
              _Tile(
                icon: Icons.account_circle_outlined,
                label: l.paramProfile,
                subtitle: user?.email ?? l.paramProfileSubtitle,
                color: const Color(0xFF0EA5E9),
                onTap: () => context.push('/shop/$shopId/parametres/profile'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Sécurité (owner uniquement) ───────────────────────────
          if (perms.isOwner) ...[
            _SecuritySection(shopId: shopId),
            const SizedBox(height: 12),
          ],

          // ── Préférences (personnel) ───────────────────────────────
          _Section(
            label: l.paramPreferences,
            icon: Icons.palette_outlined,
            color: const Color(0xFF8B5CF6),
            tiles: [
              _Tile(
                icon: Icons.language_rounded,
                label: l.paramLanguage,
                subtitle: l.paramLanguageSubtitle,
                color: const Color(0xFF8B5CF6),
                onTap: () => context.push('/shop/$shopId/parametres/language'),
              ),
              _Tile(
                icon: Icons.color_lens_rounded,
                label: l.paramTheme,
                subtitle: l.paramThemeSubtitle,
                color: const Color(0xFF8B5CF6),
                onTap: () => context.push('/shop/$shopId/parametres/theme'),
              ),
              _Tile(
                icon: Icons.payments_outlined,
                label: l.paramCurrency,
                subtitle: l.paramCurrencySubtitle,
                color: const Color(0xFF8B5CF6),
                onTap: () => context.push('/shop/$shopId/parametres/currency'),
              ),
              _Tile(
                icon: Icons.notifications_outlined,
                label: l.paramNotifications,
                subtitle: l.paramNotifsSubtitle,
                color: const Color(0xFF8B5CF6),
                onTap: () =>
                    context.push('/shop/$shopId/parametres/notifications'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Abonnement (owner uniquement) ─────────────────────────
          // Badge jours amber si <7j (spec round 9 prompt 4).
          if (perms.isOwner) ...[
            _SubscriptionSection(),
            const SizedBox(height: 12),
          ],

          // ── Intégrations ──────────────────────────────────────────
          _Section(
            label: l.paramIntegrations,
            icon: Icons.electrical_services_rounded,
            color: AppColors.secondary,
            tiles: [
              _Tile(
                icon: Icons.payment_rounded,
                label: l.paramPayments,
                subtitle: l.paramPaymentsSubtitle,
                color: AppColors.secondary,
                locked: !perms.canEditShopInfo,
                onTap: () => context.push('/shop/$shopId/parametres/payments'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Super Admin ───────────────────────────────────────────
          _SuperAdminSection(ref: ref),
          const SizedBox(height: 12),

          // ── Danger zone ───────────────────────────────────────────
          // Masquée par défaut (mobile + desktop). Pour révéler la
          // section, l'utilisateur doit saisir le PIN propriétaire.
          // Le déverrouillage est valable pour la session courante de
          // la page (pas persisté).
          _DangerGate(shopId: shopId, l: l, perms: perms),
        ],
      );
  }
}

// ─── Header profil ────────────────────────────────────────────────────────────

class _ProfileHeader extends StatelessWidget {
  final User? user;
  final String? shop;
  final AppPermissions perms;
  const _ProfileHeader({this.user, this.shop, required this.perms});

  ({String label, Color color})? _roleBadge() {
    if (perms.isSuperAdmin) {
      return (label: 'Super Admin', color: AppColors.warning);
    }
    if (perms.isShopAdmin) {
      return (label: 'Admin', color: AppColors.secondary);
    }
    if (perms.isShopUser) {
      return (label: 'Employé', color: const Color(0xFF0EA5E9));
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final initials = user?.name.isNotEmpty == true
        ? user!.name.trim().split(' ')
        .map((w) => w.isNotEmpty ? w[0].toUpperCase() : '')
        .take(2).join()
        : '?';
    final badge = _roleBadge();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary, AppColors.primaryLight],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        // Avatar
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.25),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withOpacity(0.4), width: 2),
          ),
          child: Center(child: Text(initials,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800,
                  color: Colors.white))),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(user?.name ?? 'Utilisateur',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                    color: Colors.white),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(user?.email ?? '',
                style: TextStyle(fontSize: 12,
                    color: Colors.white.withOpacity(0.8)),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            if (shop != null || badge != null) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (shop != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(shop!,
                          style: const TextStyle(fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w600),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: badge.color,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(badge.label,
                          style: const TextStyle(fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                    ),
                ],
              ),
            ],
          ],
        )),
      ]),
    );
  }
}

// ─── Section ──────────────────────────────────────────────────────────────────

/// Section abonnement avec badge jours restants.
/// Si <7j → badge amber visible à côté du tile « Mon abonnement ».
class _SubscriptionSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l    = context.l10n;
    final plan = ref.watch(currentPlanProvider);
    // Détermination du badge : afficher uniquement si plan a une date
    // d'expiration et qu'il reste moins de 7 jours, ou si déjà expiré.
    String? badgeText;
    Color?  badgeColor;
    if (plan.isExpired || !plan.hasPlan) {
      badgeText  = l.drawerBadgeExpired;
      badgeColor = AppColors.error;
    } else if (plan.expiresSoon) {
      badgeText  = '${plan.daysLeft}j';
      badgeColor = AppColors.warning;
    }

    return _Section(
      label: l.drawerSubscription,
      icon: Icons.workspace_premium_rounded,
      color: AppColors.warning,
      tiles: [
        _SubscriptionTile(
          plan: plan.planLabel,
          badgeText: badgeText,
          badgeColor: badgeColor,
          onTap: () => context.push(RouteNames.subscription),
        ),
      ],
    );
  }
}

/// Tile spécialisé pour l'abonnement — `_Tile` standard mais avec un
/// badge `Xj` couleur amber/danger selon état du plan, à droite avant
/// la flèche.
class _SubscriptionTile extends StatelessWidget {
  final String  plan;
  final String? badgeText;
  final Color?  badgeColor;
  final VoidCallback onTap;
  const _SubscriptionTile({
    required this.plan,
    required this.badgeText,
    required this.badgeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
                color: AppColors.warning.withOpacity(0.10),
                borderRadius: BorderRadius.circular(9)),
            child: const Icon(Icons.workspace_premium_rounded,
                size: 17, color: AppColors.warning),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l.drawerSubscription,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                Text(plan,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11,
                        color: AppColors.textHint)),
              ],
            ),
          ),
          if (badgeText != null && badgeColor != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: badgeColor!.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(badgeText!,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10,
                      fontWeight: FontWeight.w800, color: badgeColor)),
            ),
            const SizedBox(width: 6),
          ],
          Icon(Icons.chevron_right_rounded, size: 16,
              color: AppColors.textHint.withOpacity(0.6)),
        ]),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final List<Widget> tiles;
  const _Section({required this.label, required this.icon,
    required this.color, required this.tiles});

  @override
  Widget build(BuildContext context) {
    // Header uniforme mobile + desktop : icône colorée 20px + label 12px
    // (alignement avec _DangerSection / _SuperAdminSection). Évite le
    // mismatch visuel où Zone dangereuse était en 12px et les autres en
    // 9px uppercase sur mobile.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label de section
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(children: [
            Container(
              width: 20, height: 20,
              decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(5)),
              child: Icon(icon, size: 11, color: color),
            ),
            const SizedBox(width: 7),
            Text(label, style: TextStyle(fontSize: 12,
                fontWeight: FontWeight.w700, color: color,
                letterSpacing: 0.3)),
          ]),
        ),
        // Carte
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.divider),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.03),
                  blurRadius: 8, offset: const Offset(0, 2)),
            ],
          ),
          child: Column(children: [
            for (int i = 0; i < tiles.length; i++) ...[
              tiles[i],
              if (i < tiles.length - 1)
                const Divider(height: 1, indent: 56,
                    color: AppColors.inputFill),
            ],
          ]),
        ),
      ],
    );
  }
}

// ─── Tile ─────────────────────────────────────────────────────────────────────

class _Tile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  final bool locked;
  const _Tile({required this.icon, required this.label,
    required this.subtitle, required this.color, required this.onTap,
    this.locked = false});

  void _handleTap(BuildContext context) {
    HapticFeedback.selectionClick();
    if (locked) {
      final l = context.l10n;
      AppSnack.warning(context,
          '${l.permissionDenied} — ${l.permissionDeniedDetails}');
      return;
    }
    onTap();
  }

  @override
  Widget build(BuildContext context) {
    final Color titleColor =
        locked ? AppColors.textHint : AppColors.textPrimary;
    final Color iconBg = locked
        ? AppColors.inputFill
        : color.withOpacity(0.10);
    final Color iconColor = locked ? AppColors.textHint : color;
    // Tailles uniformes mobile + desktop, alignées sur la zone dangereuse :
    // icône 36, label 13, subtitle 11, chevron 16, padding vertical 11.
    return InkWell(
      onTap: () => _handleTap(context),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, size: 17, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(label,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13,
                            fontWeight: FontWeight.w600, color: titleColor)),
                  ),
                  if (locked) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.lock_outline_rounded,
                        size: 12, color: AppColors.textHint),
                  ],
                ]),
                if (subtitle.isNotEmpty)
                  Text(subtitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11,
                          color: AppColors.textHint)),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 16,
              color: AppColors.textHint.withOpacity(0.6)),
        ]),
      ),
    );
  }
}

// ─── Danger zone ─────────────────────────────────────────────────────────────

/// Verrou d'accès à la zone dangereuse.
///
/// Affiche un tile compact « Zone dangereuse — verrouillée » par défaut
/// (mobile + desktop). Au tap : exige le PIN propriétaire via
/// [OwnerPinDialog.guard]. En cas de succès, la `_DangerSection` complète
/// est révélée jusqu'à la sortie de la page (déverrouillage par session,
/// non persisté). Si aucun PIN n'est configuré, un snack invite à le
/// faire d'abord depuis la section Sécurité.
class _DangerGate extends StatefulWidget {
  final String shopId;
  final AppLocalizations l;
  final AppPermissions perms;
  const _DangerGate({
    required this.shopId,
    required this.l,
    required this.perms,
  });

  @override
  State<_DangerGate> createState() => _DangerGateState();
}

class _DangerGateState extends State<_DangerGate> {
  bool _unlocked = false;

  Future<void> _unlock() async {
    HapticFeedback.selectionClick();
    final l = widget.l;
    if (!await PinService.hasPIN()) {
      if (!mounted) return;
      AppSnack.warning(context,
          'Configurez d\'abord un code PIN dans la section Sécurité.');
      return;
    }
    if (!mounted) return;
    await OwnerPinDialog.guard(
      context: context,
      title: l.paramDangerZone,
      onConfirmed: () async {
        if (mounted) setState(() => _unlocked = true);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) {
      return _DangerSection(
        shopId: widget.shopId,
        l: widget.l,
        perms: widget.perms,
      );
    }

    final l = widget.l;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(children: [
            Container(
              width: 20, height: 20,
              decoration: BoxDecoration(
                  color: AppColors.error.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(5)),
              child: const Icon(Icons.warning_amber_rounded,
                  size: 11, color: AppColors.error),
            ),
            const SizedBox(width: 7),
            Text(l.paramDangerZone, style: const TextStyle(fontSize: 12,
                fontWeight: FontWeight.w700, color: AppColors.error,
                letterSpacing: 0.3)),
          ]),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.error.withOpacity(0.2)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.03),
                  blurRadius: 8, offset: const Offset(0, 2)),
            ],
          ),
          child: InkWell(
            onTap: _unlock,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 11),
              child: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                      color: AppColors.error.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(9)),
                  child: const Icon(Icons.lock_outline_rounded,
                      size: 17, color: AppColors.error),
                ),
                const SizedBox(width: 12),
                const Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Accéder à la zone dangereuse',
                      style: TextStyle(fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.error)),
                  Text('Saisissez votre code PIN pour déverrouiller',
                      style: TextStyle(fontSize: 11,
                          color: AppColors.textHint)),
                ])),
                Icon(Icons.chevron_right_rounded,
                    size: 16, color: AppColors.error.withOpacity(0.6)),
              ]),
            ),
          ),
        ),
      ],
    );
  }
}

/// Zone dangereuse — refonte pour éliminer les effets de bord :
///
/// * `_DangerSection` est désormais un `ConsumerWidget`. Tous les `ref.watch`
///   sont regroupés au niveau racine du `build` ; plus de `Consumer` ni de
///   `StatefulBuilder` imbriqués qui rebuildaient des sous-arbres entiers à
///   chaque changement de `currentShopProvider` ou `subscriptionProvider`.
/// * Le `BuildContext` n'est plus passé en paramètre du widget (anti-pattern
///   qui capturait un context parent potentiellement démonté). Chaque
///   handler reçoit son `BuildContext` directement depuis `build`.
/// * Le bouton one-shot « Réinit. (garder produits) » lit son flag Hive
///   via un `ValueListenableBuilder` ciblé — le reste de la section ne se
///   reconstruit pas quand le flag bascule.
/// * Toutes les confirmations destructives passent par `DangerActionPage`
///   (page plein écran 3-étapes — gère correctement le clavier mobile).
///   Plus aucun appel à `DangerCriticalConfirm` ou `DangerActionService` ici.
class _DangerSection extends ConsumerWidget {
  final String shopId;
  final AppLocalizations l;
  final AppPermissions perms;
  const _DangerSection({
    required this.shopId,
    required this.l,
    required this.perms,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shop = ref.watch(currentShopProvider);
    final shopName = shop?.name ?? '';
    final plan = ref.watch(subscriptionProvider).valueOrNull;
    final isSuperAdmin = plan?.isSuperAdmin == true;
    final showShopActions = perms.canDoFullShopEdit;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(children: [
            Container(
              width: 20, height: 20,
              decoration: BoxDecoration(
                  color: AppColors.error.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(5)),
              child: Icon(Icons.warning_amber_rounded, size: 11,
                  color: AppColors.error),
            ),
            const SizedBox(width: 7),
            Text(l.paramDangerZone, style: TextStyle(fontSize: 12,
                fontWeight: FontWeight.w700, color: AppColors.error,
                letterSpacing: 0.3)),
          ]),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.error.withOpacity(0.2)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.03),
                  blurRadius: 8, offset: const Offset(0, 2)),
            ],
          ),
          child: Column(children: [
            // ── Actions boutique (ex-onglet « Danger » de Gestion boutique) ─
            // Visibles pour : owner OU admin avec canDoFullShopEdit. La
            // suppression définitive de la boutique reste owner-only.
            if (showShopActions) ...[
              _dangerTile(
                icon: Icons.cleaning_services_rounded,
                label: 'Purger l\'historique',
                subtitle: 'Efface les logs d\'audit de cette boutique',
                onTap: () => _purgeLogs(context),
              ),
              _divider(),
              _dangerTile(
                icon: Icons.restart_alt_rounded,
                label: 'Réinitialiser cette boutique',
                subtitle: 'Efface ventes, clients, stock — produits gardés',
                onTap: () => _resetShop(context, shopName),
              ),
              // One-shot : isolé via ValueListenableBuilder pour ne pas
              // rebuild la section entière quand le flag Hive bascule.
              ValueListenableBuilder<Box>(
                valueListenable: HiveBoxes.settingsBox.listenable(
                    keys: ['_reset_keep_products_done_$shopId']),
                builder: (_, box, __) {
                  final done = box.get(
                      '_reset_keep_products_done_$shopId') == true;
                  if (done) return const SizedBox.shrink();
                  return Column(children: [
                    _divider(),
                    _dangerTile(
                      icon: Icons.refresh_rounded,
                      label: 'Réinit. (garder produits)',
                      subtitle: 'Bouton one-shot — efface tout sauf le catalogue',
                      onTap: () => _resetKeepProducts(context, shopName),
                    ),
                  ]);
                },
              ),
              if (perms.isOwner) ...[
                _divider(),
                _dangerTile(
                  icon: Icons.delete_forever_rounded,
                  label: 'Supprimer cette boutique',
                  subtitle: 'Suppression définitive — owner uniquement',
                  onTap: () => _deleteShop(context, ref, shopName),
                ),
              ],
              if (perms.isShopAdmin) _divider(),
            ],

            // Reset total du compte — réservé à l'admin boutique / super admin.
            // Différent de « Réinitialiser cette boutique » : efface toutes les
            // boutiques du compte (action globale, déconnexion forcée).
            if (perms.isShopAdmin)
              _dangerTile(
                icon: Icons.delete_sweep_rounded,
                label: l.paramReset,
                subtitle: l.paramResetHint,
                onTap: () => _resetAccount(context, ref),
              ),

            // ── Supprimer mon compte — invisible pour les super admins ─────
            if (!isSuperAdmin) ...[
              if (perms.isShopAdmin || showShopActions) _divider(),
              _dangerTile(
                icon: Icons.person_remove_rounded,
                label: 'Supprimer mon compte',
                subtitle: 'Suppression définitive de vos données',
                trailingChevron: true,
                onTap: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.white,
                  shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                  builder: (_) => const _DeleteAccountSheet(),
                ),
              ),
            ],
          ]),
        ),
      ],
    );
  }

  Widget _divider() => Divider(
      height: 1, indent: 56, color: AppColors.error.withOpacity(0.1));

  Widget _dangerTile({
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
    bool trailingChevron = false,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                  color: AppColors.error.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(icon, size: 17, color: AppColors.error),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 13,
                  fontWeight: FontWeight.w600, color: AppColors.error)),
              Text(subtitle, style: const TextStyle(
                  fontSize: 11, color: AppColors.textHint)),
            ])),
            if (trailingChevron)
              const Icon(Icons.chevron_right_rounded,
                  size: 16, color: Color(0xFFD1D5DB)),
          ]),
        ),
      );

  // ── Handlers — chaque action destructive passe par DangerActionPage ───────
  // (page plein écran 3-étapes : présentation/conséquences → switches
  // d'acknowledgment → confirmation finale avec saisie + mot de passe).

  void _purgeLogs(BuildContext ctx) {
    DangerActionPage.open(
      ctx,
      title: 'Purger l\'historique',
      icon: Icons.cleaning_services_rounded,
      description:
          'Tous les logs d\'audit de cette boutique seront supprimés '
          'définitivement côté serveur et localement.',
      consequences: const [
        'Plus aucune trace des actions passées (qui a fait quoi).',
        'Les ventes, produits et clients ne sont pas affectés.',
        'Action irréversible.',
      ],
      acknowledgments: const [
        "J'ai compris que cette action est irréversible",
        'Je confirme vouloir effacer tous les logs d\'audit',
      ],
      confirmText: 'PURGER',
      actionLabel: 'Purger définitivement',
      requirePassword: true,
      onConfirm: (sheetCtx) async {
        final n = await AppDatabase.purgeShopActivityLogs(shopId);
        if (ctx.mounted) AppSnack.success(ctx, '$n log(s) purgé(s)');
      },
    );
  }

  void _resetShop(BuildContext ctx, String shopName) {
    DangerActionPage.open(
      ctx,
      title: l.shopResetDialogTitle,
      icon: Icons.restart_alt_rounded,
      description: l.shopResetDialogBody(shopName),
      consequences: const [
        'Toutes les ventes, clients, commandes et stock seront effacés.',
        'Les produits, catégories et unités sont conservés.',
        'Action irréversible.',
      ],
      acknowledgments: const [
        "J'ai exporté les données importantes si besoin",
        'Je confirme vouloir réinitialiser cette boutique',
      ],
      confirmText: shopName,
      actionLabel: 'Réinitialiser définitivement',
      requirePassword: true,
      onConfirm: (sheetCtx) async {
        await Supabase.instance.client
            .rpc('reset_shop_data', params: {'p_shop_id': shopId});
        if (ctx.mounted) AppSnack.success(ctx, l.shopResetDone);
      },
    );
  }

  // One-shot : voir AppDatabase.resetShopKeepProducts pour le détail.
  // Le ValueListenableBuilder de la section recharge automatiquement quand
  // le flag Hive bascule — pas besoin d'un onSuccess manuel.
  void _resetKeepProducts(BuildContext ctx, String shopName) {
    DangerActionPage.open(
      ctx,
      title: 'Réinit. (garder produits)',
      icon: Icons.refresh_rounded,
      description:
          'Toutes les ventes, clients et stocks de "$shopName" seront effacés. '
          'Les produits, catégories, marques et unités restent intacts.',
      consequences: const [
        'Ventes, paiements et clients : effacés.',
        'Stock courant : remis à 0.',
        'Produits / catégories / marques : conservés.',
        'Bouton one-shot : disparaît après succès.',
        'Action irréversible.',
      ],
      acknowledgments: const [
        "J'ai compris que ce bouton ne réapparaîtra plus",
        'Je confirme vouloir réinitialiser en gardant les produits',
      ],
      confirmText: shopName,
      actionLabel: 'Réinitialiser définitivement',
      requirePassword: true,
      onConfirm: (sheetCtx) async {
        await AppDatabase.resetShopKeepProducts(shopId);
        await HiveBoxes.settingsBox
            .put('_reset_keep_products_done_$shopId', true);
        if (ctx.mounted) {
          AppSnack.success(ctx, 'Boutique réinitialisée (produits gardés)');
        }
      },
    );
  }

  void _deleteShop(BuildContext ctx, WidgetRef ref, String shopName) {
    DangerActionPage.open(
      ctx,
      title: l.shopDeleteDialogTitle,
      icon: Icons.delete_forever_rounded,
      description: l.shopDeleteTypeName(shopName),
      consequences: const [
        'Toutes les données de la boutique seront supprimées.',
        'Aucune récupération possible après confirmation.',
        'Les abonnements liés à la boutique seront annulés.',
      ],
      acknowledgments: const [
        "J'ai exporté les données importantes si besoin",
        'Je comprends que la suppression est définitive',
        'Je confirme vouloir supprimer cette boutique',
      ],
      confirmText: shopName,
      actionLabel: 'Supprimer définitivement',
      requirePassword: true,
      onConfirm: (sheetCtx) async {
        await AppDatabase.deleteShop(shopId);
        ref.read(myShopsProvider.notifier).refresh();
        // Navigation hors de la page Paramètres — utilise sheetCtx pour
        // éviter de tomber sur un context démonté.
        if (sheetCtx.mounted) sheetCtx.go('/shop-selector');
      },
    );
  }

  void _resetAccount(BuildContext ctx, WidgetRef ref) {
    final currentUser = LocalStorageService.getCurrentUser();
    final email       = currentUser?.email ?? '';
    DangerActionPage.open(
      ctx,
      title: l.paramResetConfirmTitle,
      icon: Icons.delete_sweep_rounded,
      description:
          'Cette action effacera TOUS les comptes, boutiques, produits '
          'et paramètres associés à $email.',
      consequences: const [
        'Toutes les boutiques de ce compte seront vidées sur Supabase.',
        'Le cache local Hive sera entièrement effacé.',
        'Vous serez automatiquement déconnecté.',
        'Aucune récupération possible.',
      ],
      acknowledgments: const [
        "J'ai exporté les données importantes si besoin",
        'Je comprends que toutes mes boutiques seront vidées',
        'Je confirme vouloir réinitialiser l\'application',
      ],
      confirmText: email.isEmpty ? 'RESET' : email,
      actionLabel: 'Réinitialiser définitivement',
      requirePassword: true,
      onConfirm: (sheetCtx) async {
        final sb = Supabase.instance.client;

        // 1. Collecter tous les shopIds AVANT de vider Hive
        final allShopIds = <String>{
          shopId,
          ...HiveBoxes.shopsBox.values
              .map((raw) => raw['id']?.toString())
              .whereType<String>(),
        };

        // 2. Fermer les channels Realtime AVANT toute suppression
        AppDatabase.dispose();

        // 3. Supprimer sur Supabase — RPC + fallback DELETE direct
        String? rpcError;
        for (final sid in allShopIds) {
          try {
            await sb.rpc('reset_shop_data', params: {'p_shop_id': sid});
            continue;
          } catch (e) {
            rpcError = e.toString();
            debugPrint('[Params] RPC échoué ($sid): $e — fallback DELETE');
          }
          for (final table in [
            ('orders',          'shop_id'),
            ('products',        'store_id'),
            ('categories',      'shop_id'),
            ('clients',         'store_id'),
            ('brands',          'shop_id'),
            ('units',           'shop_id'),
            ('stock_arrivals',  'shop_id'),
            ('stock_movements', 'shop_id'),
            ('incidents',       'shop_id'),
            ('receptions',      'shop_id'),
            ('purchase_orders', 'shop_id'),
            ('suppliers',       'shop_id'),
          ]) {
            try { await sb.from(table.$1).delete().eq(table.$2, sid); }
            catch (_) {}
          }
        }

        // 4. Vider le cache local Hive (toutes les boxes métier)
        await HiveBoxes.shopsBox.clear();
        await HiveBoxes.productsBox.clear();
        await HiveBoxes.membershipsBox.clear();
        await HiveBoxes.offlineQueueBox.clear();
        await HiveBoxes.ordersBox.clear();
        await HiveBoxes.clientsBox.clear();
        await HiveBoxes.salesBox.clear();
        await HiveBoxes.cartBox.clear();
        await HiveBoxes.settingsBox.clear();
        await HiveBoxes.suppliersBox.clear();
        await HiveBoxes.receptionsBox.clear();
        await HiveBoxes.incidentsBox.clear();
        await HiveBoxes.stockMovementsBox.clear();
        await HiveBoxes.purchaseOrdersBox.clear();
        await HiveBoxes.stockArrivalsBox.clear();
        AppDatabase.notifyAllChanged();
        if (currentUser != null) {
          await LocalStorageService.saveUser(currentUser);
          await LocalStorageService.setCurrentUserId(currentUser.id);
        }
        if (sheetCtx.mounted) {
          if (rpcError != null) {
            AppSnack.warning(sheetCtx,
                'Cache local vidé, mais les données Supabase '
                'n\'ont pas été supprimées : $rpcError');
          } else {
            AppSnack.success(sheetCtx, l.paramResetDone);
          }
          sheetCtx.read<AuthBloc>().add(AuthLogoutRequested());
        }
      },
    );
  }
}

// ─── Section Super Admin (visible uniquement pour is_super_admin) ─────────────

class _SuperAdminSection extends ConsumerWidget {
  final WidgetRef ref;
  const _SuperAdminSection({required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef widgetRef) {
    final planAsync = widgetRef.watch(subscriptionProvider);
    final plan = planAsync.valueOrNull;
    if (plan == null || !plan.isSuperAdmin) return const SizedBox.shrink();

    // Même structure que _Section — label externe + carte blanche avec bordure grise
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label de section (style identique aux autres sections)
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(children: [
            Container(
              width: 20, height: 20,
              decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(5)),
              child: Icon(Icons.admin_panel_settings_rounded,
                  size: 11, color: AppColors.primary),
            ),
            const SizedBox(width: 7),
            Text('Administration',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                    letterSpacing: 0.3)),
            const SizedBox(width: 8),
            // Badge Super Admin
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(20)),
              child: const Text('Super Admin',
                  style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          ]),
        ),
        // Carte — même style que les autres sections
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.divider),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2)),
            ],
          ),
          child: InkWell(
            onTap: () => context.push(RouteNames.adminPanel),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 11),
              child: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(9)),
                  child: Icon(Icons.people_alt_rounded,
                      size: 17, color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Gérer les utilisateurs',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textPrimary)),
                      Text('Abonnements, blocages, statistiques',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textHint)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    size: 16, color: AppColors.textHint),
              ]),
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Suppression de compte — bottom sheet paginé (3 étapes)
// ═══════════════════════════════════════════════════════════════════════════

const _kDeleteReasons = [
  "L'application ne correspond pas à mes besoins",
  'Trop cher',
  "Je n'utilise plus l'application",
  'Problèmes techniques récurrents',
  'Autre raison',
];

class _DeleteAccountSheet extends ConsumerStatefulWidget {
  const _DeleteAccountSheet();
  @override
  ConsumerState<_DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends ConsumerState<_DeleteAccountSheet> {
  final _pageCtrl    = PageController();
  final _otherCtrl   = TextEditingController();
  final _pwdCtrl     = TextEditingController();
  int     _page        = 0;
  String? _reason;
  bool    _exported    = false;
  bool    _acknowledged = false;
  bool    _obscure     = true;
  bool    _loading     = false;
  String? _error;
  Map<String, dynamic>? _summary; // chargé à l'entrée de l'étape 3

  @override
  void dispose() {
    _pageCtrl.dispose();
    _otherCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  bool get _canGoNext {
    if (_page == 0) {
      if (_reason == null) return false;
      if (_reason == 'Autre raison' && _otherCtrl.text.trim().isEmpty) return false;
      return true;
    }
    if (_page == 1) return _exported && _acknowledged;
    return false;
  }

  String get _finalReason =>
      _reason == 'Autre raison' ? _otherCtrl.text.trim() : (_reason ?? '');

  Future<void> _goTo(int index) async {
    if (index == 2 && _summary == null) {
      await _loadSummary();
    }
    if (!mounted) return;
    setState(() => _page = index);
    _pageCtrl.animateToPage(index,
        duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
  }

  Future<void> _loadSummary() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final res = await Supabase.instance.client
          .rpc('get_user_summary', params: {'p_user_id': uid});
      if (res is Map) {
        setState(() => _summary = Map<String, dynamic>.from(res));
      }
    } catch (e) {
      debugPrint('[DeleteAccount] summary error: $e');
    }
  }

  Future<void> _submit() async {
    if (_pwdCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Veuillez entrer votre mot de passe.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final auth  = Supabase.instance.client.auth;
      final email = auth.currentUser?.email ?? '';
      final uid   = auth.currentUser?.id;
      if (uid == null) throw Exception('Session expirée');

      // 1. Re-auth via signInWithPassword (confirme l'identité)
      await auth.signInWithPassword(email: email, password: _pwdCtrl.text.trim());

      // 2. Log côté client AVEC la raison (le RPC loggera aussi 'account_deleted')
      await ActivityLogService.log(
        action:      'account_deleted',
        targetType:  'user',
        targetId:    uid,
        targetLabel: email,
        details: {
          'reason':      _finalReason,
          'exported':    _exported,
          'self_service': true,
        },
      );

      // 3. Appel RPC — supprime toutes les données puis le compte.
      //    Le RPC RAISE en cas d'échec sur auth.users — l'exception remonte
      //    dans le catch ci-dessous et l'utilisateur voit l'erreur réelle.
      await Supabase.instance.client
          .rpc('delete_user_account', params: {'p_user_id': uid});

      // 4. Vider tout le cache local du compte supprimé pour qu'aucune
      //    donnée stale ne survive si quelqu'un se reconnecte sur l'appareil.
      await LocalStorageService.clearAllLocalData();
      await SecureStorageService.clearAll();

      if (!mounted) return;
      Navigator.of(context).pop();
      // 5. Déconnexion via AuthBloc → redirection login
      context.read<AuthBloc>().add(AuthLogoutRequested());
      AppSnack.success(context, 'Compte supprimé. À bientôt.');
    } on AuthException catch (e) {
      setState(() { _loading = false;
          _error = 'Mot de passe incorrect. ${e.message}'; });
    } catch (e) {
      setState(() { _loading = false;
          _error = 'Erreur: ${e.toString().replaceAll('Exception: ', '')}'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: FractionallySizedBox(
        heightFactor: 0.82,
        child: Column(children: [
          // ── Header ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 8),
            child: Row(children: [
              Container(width: 32, height: 32,
                  decoration: BoxDecoration(
                      color: AppColors.error.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8)),
                  child: Icon(Icons.person_remove_rounded,
                      size: 17, color: AppColors.error)),
              const SizedBox(width: 10),
              const Expanded(child: Text('Supprimer mon compte',
                  style: TextStyle(fontSize: 15,
                      fontWeight: FontWeight.w700))),
              IconButton(onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded)),
            ]),
          ),
          _StepIndicator(step: _page),
          const SizedBox(height: 8),
          Expanded(child: PageView(
            controller: _pageCtrl,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (i) => setState(() => _page = i),
            children: [
              _buildStep1(),
              _buildStep2(),
              _buildStep3(),
            ],
          )),
          // ── Footer ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(children: [
              if (_page > 0)
                Expanded(child: OutlinedButton(
                  onPressed: _loading ? null : () => _goTo(_page - 1),
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.divider),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10))),
                  child: const Text('Retour',
                      style: TextStyle(color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600)),
                )),
              if (_page > 0) const SizedBox(width: 10),
              Expanded(flex: 2, child: _page < 2
                  ? ElevatedButton(
                      onPressed: _canGoNext ? () => _goTo(_page + 1) : null,
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: AppColors.divider,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10))),
                      child: const Text('Suivant',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    )
                  : ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.error,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10))),
                      child: _loading
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Supprimer définitivement mon compte',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700)),
                    )),
            ]),
          ),
        ]),
      ),
    );
  }

  // ── Étape 1 : raison ───────────────────────────────────────────────────
  Widget _buildStep1() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    children: [
      const Text('Pourquoi souhaitez-vous partir ?',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text('Votre réponse nous aide à améliorer le produit.',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      const SizedBox(height: 12),
      for (final r in _kDeleteReasons) _ReasonTile(
        label:    r,
        selected: _reason == r,
        onTap:    () => setState(() => _reason = r),
      ),
      if (_reason == 'Autre raison') ...[
        const SizedBox(height: 8),
        TextField(
          controller: _otherCtrl,
          onChanged: (_) => setState(() {}),
          maxLines: 3,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Précisez votre raison…',
            hintStyle: const TextStyle(fontSize: 12, color: AppColors.textHint),
            contentPadding: const EdgeInsets.all(12),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.divider)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.divider)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                    color: AppColors.primary, width: 1.5)),
          ),
        ),
      ],
    ],
  );

  // ── Étape 2 : rétention ────────────────────────────────────────────────
  Widget _buildStep2() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    children: [
      const Text('Avant de continuer',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text(
          'Confirmez ces points pour passer à la dernière étape.',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      const SizedBox(height: 16),
      _SwitchRow(
        label: "J'ai exporté mes données importantes",
        value: _exported,
        onChanged: (v) => setState(() => _exported = v),
      ),
      const SizedBox(height: 12),
      _SwitchRow(
        label: 'Je confirme vouloir supprimer toutes mes boutiques et données',
        value: _acknowledged,
        onChanged: (v) => setState(() => _acknowledged = v),
      ),
    ],
  );

  // ── Étape 3 : confirmation finale ──────────────────────────────────────
  Widget _buildStep3() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    children: [
      const Text('Confirmation finale',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      if (_summary != null)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.error.withOpacity(0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.error.withOpacity(0.2)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            const Text('Vous allez supprimer :',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                    color: AppColors.error)),
            const SizedBox(height: 6),
            Text(
              '${_summary!['shops_count']     ?? 0} boutique(s), '
              '${_summary!['products_count']  ?? 0} produit(s), '
              '${_summary!['sales_count']     ?? 0} vente(s), '
              '${_summary!['clients_count']   ?? 0} client(s).',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary,
                  height: 1.5),
            ),
          ]),
        )
      else
        const Padding(padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: CircularProgressIndicator())),
      const SizedBox(height: 16),
      const Text('Mot de passe actuel',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
              color: Color(0xFF374151))),
      const SizedBox(height: 6),
      TextField(
        controller: _pwdCtrl,
        obscureText: _obscure,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Votre mot de passe',
          hintStyle: const TextStyle(fontSize: 12, color: AppColors.textHint),
          contentPadding: const EdgeInsets.symmetric(
              horizontal: 12, vertical: 12),
          suffixIcon: IconButton(
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(_obscure
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined, size: 18),
          ),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.divider)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.divider)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.error, width: 1.5)),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.error_outline_rounded, size: 14, color: AppColors.error),
          const SizedBox(width: 6),
          Expanded(child: Text(_error!,
              style: const TextStyle(fontSize: 12, color: AppColors.error))),
        ]),
      ],
    ],
  );
}

class _StepIndicator extends StatelessWidget {
  final int step;
  const _StepIndicator({required this.step});
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      for (var i = 0; i < 3; i++) ...[
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: i == step ? 24 : 6, height: 6,
          decoration: BoxDecoration(
              color: i <= step ? AppColors.error : AppColors.divider,
              borderRadius: BorderRadius.circular(3)),
        ),
        if (i < 2) const SizedBox(width: 5),
      ],
    ]);
  }
}

class _ReasonTile extends StatelessWidget {
  final String       label;
  final bool         selected;
  final VoidCallback onTap;
  const _ReasonTile({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withOpacity(0.06) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected ? AppColors.primary : AppColors.divider,
              width: selected ? 1.5 : 1),
        ),
        child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 16, height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: selected ? AppColors.primary : const Color(0xFFD1D5DB),
                  width: 2),
              color: selected ? AppColors.primary : Colors.white,
            ),
            child: selected
                ? const Icon(Icons.check_rounded, size: 10, color: Colors.white)
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label,
              style: TextStyle(fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? AppColors.primary : const Color(0xFF374151)))),
        ]),
      ),
    ),
  );
}

class _SwitchRow extends StatelessWidget {
  final String              label;
  final bool                value;
  final ValueChanged<bool> onChanged;
  const _SwitchRow({required this.label, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.divider),
    ),
    child: Row(children: [
      Expanded(child: Text(label,
          style: const TextStyle(fontSize: 13,
              color: AppColors.textPrimary, fontWeight: FontWeight.w500))),
      const SizedBox(width: 10),
      AppSwitch(value: value, onChanged: onChanged,
          activeColor: AppColors.error),
    ]),
  );
}

// ─── Section Sécurité (PIN propriétaire, owner uniquement) ────────────────────

class _SecuritySection extends StatefulWidget {
  final String shopId;
  const _SecuritySection({required this.shopId});
  @override
  State<_SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends State<_SecuritySection> {
  bool _hasPin = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final has = await PinService.hasPIN();
    if (!mounted) return;
    setState(() {
      _hasPin  = has;
      _loading = false;
    });
  }

  Future<void> _openSetup() async {
    final ok = await OwnerPinSetupDialog.show(context);
    if (ok == true) await _refresh();
  }

  Future<void> _deletePin() async {
    // Page plein écran à la place des dialogues enchaînés : sur mobile,
    // un AlertDialog contenant un TextField autofocus voit son UI poussée
    // hors écran par le clavier système. La page gère correctement le
    // resize via AppScaffold/SafeArea.
    final removed = await context.push<bool>(
        '/shop/${widget.shopId}/parametres/pin/delete');
    if (removed == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    const color = Color(0xFFEC4899);

    return _Section(
      label: l.securitySectionTitle,
      icon: Icons.shield_outlined,
      color: color,
      tiles: [
        _Tile(
          icon: Icons.pin_rounded,
          label: l.pinSetupTitle,
          subtitle: _loading
              ? l.commonLoading
              : '${l.pinSetupSubtitle} · '
                '${_hasPin ? l.pinActive : l.pinInactive}',
          color: color,
          onTap: _openSetup,
        ),
        if (_hasPin && !_loading)
          _Tile(
            icon: Icons.delete_outline_rounded,
            label: l.pinDelete,
            subtitle: l.pinDeleteWarning,
            color: AppColors.error,
            onTap: _deletePin,
          ),
      ],
    );
  }
}