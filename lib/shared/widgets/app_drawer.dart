import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/database/app_database.dart';
import '../../core/permisions/subscription_provider.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_theme.dart';
import '../../core/i18n/app_localizations.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_event.dart';
import '../../features/auth/domain/entities/user.dart';
import '../../features/hr/domain/models/member_role.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';
import '../../core/storage/local_storage_service.dart';
import '../../core/storage/hive_boxes.dart';
import '../providers/current_shop_provider.dart';
import '../../core/widgets/fortress_logo.dart';
import 'app_confirm_dialog.dart';
import 'app_snack.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Modèle de navigation
// ─────────────────────────────────────────────────────────────────────────────

class _NavDef {
  final IconData icon;
  final String Function(AppLocalizations) label;
  final String Function(String) route;
  final bool Function(String) isActive;
  const _NavDef({required this.icon, required this.label,
    required this.route, required this.isActive});
}

final _navItems = [
  _NavDef(icon: Icons.dashboard_rounded,    label: (l) => l.navDashboard,
      route: (id) => '/shop/$id/dashboard', isActive: (c) => c.contains('/dashboard')),
  _NavDef(icon: Icons.storefront_rounded,   label: (l) => l.navBoutique,
      route: (id) => '/shop/$id/caisse',    isActive: (c) => c.contains('/caisse')),
  _NavDef(icon: Icons.inventory_2_outlined, label: (l) => l.navInventaire,
      route: (id) => '/shop/$id/inventaire',isActive: (c) => c.contains('/inventaire')),
  _NavDef(icon: Icons.people_outline_rounded, label: (l) => l.navClients,
      route: (id) => '/shop/$id/crm',       isActive: (c) => c.contains('/crm')),
  _NavDef(icon: Icons.account_balance_rounded, label: (l) => l.navFinances,
      route: (id) => '/shop/$id/finances',  isActive: (c) => c.contains('/finances')),
  _NavDef(icon: Icons.history_rounded,      label: (l) => l.navHistorique,
      route: (id) => '/shop/$id/historique',
      isActive: (c) => c.contains('/historique')),
];

// Section secondaire — vide pour l'instant (Hub central est passé côté admin).
final _secondaryItems = <_NavDef>[];

// Items réservés aux admins/super admins
// Note : "Gestion boutique" retiré du drawer — ses fonctionnalités sont
// désormais accessibles via le tile "Paramètres boutique" de la page
// Paramètres (membres, copier, danger zone). "Ressources humaines" est
// fusionné dans la même section. Les routes /shop/$id/parametres/shop,
// /parametres/users et /employees restent actives pour les liens internes.
final _adminItems = [
  _NavDef(icon: Icons.hub_rounded, label: (l) => l.navHub,
      route: (_) => RouteNames.hub,
      isActive: (c) => c.startsWith('/hub')),
];

bool _canAccess(_NavDef n, String shopId, UserRole? role) {
  // Si le rôle n'est pas encore chargé (memberships manquants),
  // afficher tous les items — le filtrage sera réappliqué au prochain rebuild
  if (role == null) return true;
  if (n.route(shopId).contains('/finances')) return role.canViewReports;
  if (n.route(shopId).contains('/crm')) return role.canManageShop;
  if (n.route(shopId).contains('/inventaire')) return role.canManageInventory;
  // Données financières & audit : admin/propriétaire uniquement
  if (n.route(shopId).contains('/historique')) return role == UserRole.admin;
  return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// BUG 1 FIX — Row overflow à 24px de contrainte :
// Cause : en mode compact (64px), Padding(horizontal: 12) laisse 64-24=40px,
//         puis InkWell ajoute encore des offsets → le Row n'a que 24px.
//         Le Row(mainAxisSize:max) essaie de prendre toute la largeur → overflow.
// Solution : en mode !expanded, ne pas utiliser Row du tout — juste Center(Icon).
//            En mode expanded, le Row a assez d'espace (220-16=204px).
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Drawer mobile — toujours expanded=true
// ─────────────────────────────────────────────────────────────────────────────

class AppDrawer extends ConsumerWidget {
  final String shopId;
  const AppDrawer({super.key, required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Lire la boutique depuis le provider OU depuis Hive si le provider est null
    final shopFromProvider = ref.watch(currentShopProvider);
    final shop = shopFromProvider ?? LocalStorageService.getShop(shopId);
    final current = GoRouterState.of(context).matchedLocation;
    final l       = context.l10n;

    // Source de vérité unique : permissionsProvider (MemberRole canonique).
    final perms = ref.watch(permissionsProvider(shopId));
    final memberRole = perms.effectiveRole;
    final isOwner = perms.isOwner;
    UserRole? userRole = isOwner || memberRole == MemberRole.admin
        ? UserRole.admin
        : memberRole == MemberRole.user
            ? UserRole.cashier
            : LocalStorageService.getCurrentUser()?.roleIn(shopId);
    final isAdmin = perms.isShopAdmin;

    return Drawer(
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(),
      child: Column(children: [
        _DrawerHeader(shop: shop, expanded: true,
            isOwner: isOwner, memberRole: memberRole),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            children: [
              // Navigation principale — filtrée selon le rôle
              ..._navItems
                  .where((n) => _canAccess(n, shopId, userRole))
                  .map((n) {
                // Badge incidents en attente sur l'item Inventaire
                int badge = 0;
                if (n.route(shopId).contains('/inventaire')) {
                  badge = HiveBoxes.incidentsBox.values.where((m) {
                    final map = m is Map ? m : null;
                    return map != null
                        && map['shop_id'] == shopId
                        && (map['status'] == 'pending' || map['status'] == 'in_progress');
                  }).length;
                }
                return _NavTile(
                  nav: n, shopId: shopId, current: current, expanded: true,
                  badge: badge,
                  onTap: () { Navigator.of(context).pop(); context.go(n.route(shopId)); },
                );
              }),
              if (_secondaryItems.isNotEmpty) ...[
                const _Divider(),
                ..._secondaryItems.map((n) => _NavTile(
                  nav: n, shopId: shopId, current: current, expanded: true,
                  accent: AppColors.primaryLight,
                  onTap: () { Navigator.of(context).pop(); context.go(n.route(shopId)); },
                )),
              ],
              // Section admin — visible uniquement pour les admins/propriétaires
              if (isAdmin) ...[
                const _Divider(),
                _SectionLabel(context.l10n.navAdmin),
                ..._adminItems.map((n) => _NavTile(
                  nav: n, shopId: shopId, current: current, expanded: true,
                  accent: const Color(0xFFEF4444),
                  onTap: () { Navigator.of(context).pop(); context.go(n.route(shopId)); },
                )),
              ],
              if (isOwner) ...[
                const _Divider(),
                _SubscriptionTile(expanded: true, onTap: () {
                  Navigator.of(context).pop();
                  context.push(RouteNames.subscription);
                }),
              ],
            ],
          ),
        ),
        _Footer(shopId: shopId, expanded: true, isMobile: true),
      ]),
    );
  }

}

// ─────────────────────────────────────────────────────────────────────────────
// Rail desktop
// ─────────────────────────────────────────────────────────────────────────────

class AppDrawerRail extends ConsumerWidget {
  final String shopId;
  final bool expanded;
  final VoidCallback onToggle;

  const AppDrawerRail({
    super.key, required this.shopId,
    required this.expanded, required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shopFromProvider = ref.watch(currentShopProvider);
    final shop = shopFromProvider ?? LocalStorageService.getShop(shopId);
    final current = GoRouterState.of(context).matchedLocation;
    final currentUser = LocalStorageService.getCurrentUser();
    // Source de vérité unique : permissionsProvider (MemberRole canonique).
    // Ne pas s'appuyer sur le legacy User.roleIn() qui mappe 'user'→cashier.
    final perms = ref.watch(permissionsProvider(shopId));
    final memberRole = perms.effectiveRole;
    final isOwner = perms.isOwner;
    // Conserve la variable userRole (UserRole) pour les passages legacy
    // côté items du drawer ; elle reste correcte pour admin/owner.
    UserRole? userRole = isOwner || memberRole == MemberRole.admin
        ? UserRole.admin
        : memberRole == MemberRole.user
            ? UserRole.cashier
            : currentUser?.roleIn(shopId);
    final isAdmin = perms.isShopAdmin;

    return Container(
      color: Colors.white,
      child: Column(children: [
        _DrawerHeader(shop: shop, expanded: expanded,
            isOwner: isOwner, memberRole: memberRole),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(
                expanded ? 8 : 6, 8, expanded ? 8 : 6, 0),
            children: [
              ..._navItems
                  .where((n) => _canAccess(n, shopId, userRole))
                  .map((n) {
                int badge = 0;
                if (n.route(shopId).contains('/inventaire')) {
                  badge = HiveBoxes.incidentsBox.values.where((m) {
                    final map = m is Map ? m : null;
                    return map != null
                        && map['shop_id'] == shopId
                        && (map['status'] == 'pending' || map['status'] == 'in_progress');
                  }).length;
                }
                return _NavTile(
                  nav: n, shopId: shopId, current: current,
                  expanded: expanded, badge: badge,
                  onTap: () => context.go(n.route(shopId)),
                );
              }),
              if (_secondaryItems.isNotEmpty) ...[
                const _Divider(),
                ..._secondaryItems.map((n) => _NavTile(
                  nav: n, shopId: shopId, current: current,
                  expanded: expanded, accent: AppColors.primaryLight,
                  onTap: () => context.go(n.route(shopId)),
                )),
              ],
              if (isAdmin) ...[
                const _Divider(),
                if (expanded) _SectionLabel(context.l10n.navAdmin),
                ..._adminItems.map((n) => _NavTile(
                  nav: n, shopId: shopId, current: current,
                  expanded: expanded,
                  accent: const Color(0xFFEF4444),
                  onTap: () => context.go(n.route(shopId)),
                )),
              ],
              if (isOwner) ...[
                const _Divider(),
                _SubscriptionTile(
                  expanded: expanded,
                  onTap: () => context.push(RouteNames.subscription),
                ),
              ],
            ],
          ),
        ),
        _Footer(shopId: shopId, expanded: expanded, isMobile: false),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Header
// ─────────────────────────────────────────────────────────────────────────────

class _DrawerHeader extends StatelessWidget {
  final ShopSummary? shop;
  final bool expanded;
  final bool isOwner;
  /// Rôle canonique (`MemberRole`) — owner/admin/user. Source de vérité
  /// pour le label affiché. Préféré au legacy `UserRole`.
  final MemberRole? memberRole;
  const _DrawerHeader({required this.shop, required this.expanded,
    this.isOwner = false, this.memberRole});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final useCompact = !expanded || constraints.maxWidth < 140;
      return _build(ctx, useCompact);
    });
  }

  Widget _build(BuildContext context, bool useCompact) {
    final topPad = MediaQuery.of(context).padding.top;

    // Mode compact : logo + icône secteur seuls, centrés
    if (useCompact) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.only(top: topPad + 16, bottom: 16),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(
              bottom: BorderSide(color: Color(0xFFF0F0F0), width: 1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const FortressLogo.dark(size: 32),
            if (shop != null) ...[
              const SizedBox(height: 10),
              Tooltip(
                message: shop!.name,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(_icon(shop!.sector),
                      color: AppColors.primary, size: 14),
                ),
              ),
            ],
          ],
        ),
      );
    }

    // Mode expanded : logo + carte boutique avec avatar, rôle et métadonnées
    // Couleur + label dérivés de MemberRole (source de vérité). Le `isOwner`
    // est redondant avec memberRole==owner mais on le garde pour le cas où
    // l'utilisateur est owner par `shops.owner_id` sans ligne shop_memberships.
    final isAdminRole = memberRole == MemberRole.admin;
    final roleColor = (isOwner || memberRole == MemberRole.owner)
        ? AppColors.primary
        : isAdminRole
            ? AppColors.secondary
            : AppColors.textSecondary;
    final roleLabel = (isOwner || memberRole == MemberRole.owner)
        ? context.l10n.roleOwner
        : (memberRole?.labelFr ?? '');

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(12, topPad + 14, 12, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
            bottom: BorderSide(color: Color(0xFFF0F0F0), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4),
            child: FortressLogo.dark(size: 32),
          ),
          if (shop != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.primary.withOpacity(0.06),
                    AppColors.primaryLight.withOpacity(0.04),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: AppColors.primary.withOpacity(0.12)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    // Avatar boutique — fond primary pastel, icône secteur
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: AppColors.primary.withOpacity(0.2)),
                      ),
                      child: Icon(_icon(shop!.sector),
                          color: AppColors.primary, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(shop!.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A))),
                          const SizedBox(height: 2),
                          Text(_sectorLabel(shop!.sector),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF6B7280))),
                        ],
                      ),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  // Wrap (au lieu de Row) — quand la largeur du rail est
                  // courte (panel collapsed/medium), le badge rôle passe à
                  // la ligne au lieu d'overflow.
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _Chip(
                        icon: Text(_flag(shop!.country),
                            style: const TextStyle(fontSize: 11)),
                        label: shop!.currency,
                      ),
                      if (memberRole != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: roleColor,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(roleLabel,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.3)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _sectorLabel(String s) => switch (s) {
        'restaurant'  => 'Restaurant',
        'supermarche' => 'Supermarché',
        'pharmacie'   => 'Pharmacie',
        'boutique'    => 'Boutique',
        _ => 'Commerce',
      };

  IconData _icon(String s) => switch (s) {
    'restaurant'  => Icons.restaurant_rounded,
    'supermarche' => Icons.local_grocery_store_rounded,
    'pharmacie'   => Icons.local_pharmacy_rounded,
    _ => Icons.storefront_rounded,
  };

  String _flag(String iso) {
    const f = {'CM':'🇨🇲','SN':'🇸🇳','CI':'🇨🇮','NG':'🇳🇬','GH':'🇬🇭',
      'MA':'🇲🇦','FR':'🇫🇷','BE':'🇧🇪','US':'🇺🇸','GB':'🇬🇧'};
    return f[iso] ?? '🏳';
  }
}

class _Chip extends StatelessWidget {
  final Widget icon;
  final String label;
  const _Chip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          icon,
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF374151))),
        ]),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Item de navigation — CLEF DU FIX OVERFLOW
// En mode !expanded : Center(Icon) uniquement, ZERO Row
// En mode  expanded : Row avec Flexible sur le texte
// ─────────────────────────────────────────────────────────────────────────────

class _NavTile extends StatelessWidget {
  final _NavDef nav;
  final String shopId, current;
  final bool expanded;
  final Color? accent;
  final VoidCallback onTap;
  final int badge;

  const _NavTile({
    required this.nav, required this.shopId, required this.current,
    required this.expanded, required this.onTap, this.accent,
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;
    final active = nav.isActive(current);
    final color  = accent ?? AppColors.primary;
    final label  = nav.label(l);

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: active ? color.withOpacity(0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Tooltip(
        message: expanded ? '' : label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          // LayoutBuilder garantit la bonne contrainte AVANT de choisir le layout
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              // Pendant l'animation du rail (64→220px en 220ms), la
              // largeur passe par toutes les valeurs intermédiaires.
              // À <140px, le mode étendu n'a pas la place pour icône+texte+
              // badges → on bascule en compact tant que la place manque.
              final useCompact = !expanded || constraints.maxWidth < 140;
              if (useCompact) {
                return SizedBox(
                  height: 40,
                  child: Center(
                    child: Icon(nav.icon, size: 22,
                        color: active ? color : const Color(0xFF6B7280)),
                  ),
                );
              }
              // Mode étendu — Row avec texte
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Icon(nav.icon, size: 20,
                        color: active ? color : const Color(0xFF6B7280)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(label,
                          overflow: TextOverflow.ellipsis, maxLines: 1,
                          style: TextStyle(fontSize: 13,
                              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                              color: active ? color : const Color(0xFF374151))),
                    ),
                    if (badge > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                            color: const Color(0xFFEF4444),
                            borderRadius: BorderRadius.circular(8)),
                        child: Text('$badge', style: const TextStyle(fontSize: 9,
                            fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                    ],
                    if (active) ...[
                      const SizedBox(width: 4),
                      Container(width: 3, height: 16,
                          decoration: BoxDecoration(color: color,
                              borderRadius: BorderRadius.circular(2))),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.symmetric(vertical: 6),
          child: Divider(color: Color(0xFFF0F0F0), thickness: 1));
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
    child: Text(text, style: const TextStyle(
        fontSize: 10, fontWeight: FontWeight.w700,
        color: Color(0xFF9CA3AF), letterSpacing: 0.5)),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Footer
// ─────────────────────────────────────────────────────────────────────────────

class _Footer extends ConsumerWidget {
  final String shopId;
  final bool expanded;
  final bool isMobile;
  const _Footer({required this.shopId, required this.expanded,
    required this.isMobile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = GoRouterState.of(context).matchedLocation;

    return Padding(
      padding: EdgeInsets.fromLTRB(
          expanded ? 8 : 6, 0, expanded ? 8 : 6, 16),
      child: Column(children: [
        const Divider(color: Color(0xFFF0F0F0), thickness: 1),
        const SizedBox(height: 4),
        _NavTile(
          nav: _NavDef(
            icon: Icons.settings_outlined,
            label: (l) => l.navParametres,
            route: (id) => '/shop/$id/parametres',
            isActive: (c) => c.contains('/parametres'),
          ),
          shopId: shopId, current: current, expanded: expanded,
          onTap: () {
            if (isMobile) Navigator.of(context).pop();
            context.go('/shop/$shopId/parametres');
          },
        ),
        const SizedBox(height: 2),
        _LogoutTile(expanded: expanded, isMobile: isMobile),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bouton déconnexion — même logique que _NavTile (pas de Row en compact)
// BUG 2 FIX — Navigator.pop(context) null en desktop → conditionnel sur isMobile
// ─────────────────────────────────────────────────────────────────────────────

class _LogoutTile extends ConsumerWidget {
  final bool expanded;
  final bool isMobile;
  const _LogoutTile({required this.expanded, required this.isMobile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;

    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
      child: Tooltip(
        message: expanded ? '' : l.navLogout,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _confirm(context, ref, l),
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final useCompact = !expanded || constraints.maxWidth < 140;
              if (useCompact) {
                return const SizedBox(
                  height: 40,
                  child: Center(child: Icon(Icons.logout_rounded,
                      size: 22, color: Color(0xFFEF4444))),
                );
              }
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    const Icon(Icons.logout_rounded, size: 20,
                        color: Color(0xFFEF4444)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(l.navLogout,
                        overflow: TextOverflow.ellipsis, maxLines: 1,
                        style: const TextStyle(fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFFEF4444)))),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _confirm(BuildContext context, WidgetRef ref, AppLocalizations l) {
    final pending = AppDatabase.pendingOpsCount;

    // Ops en attente hors ligne → avertir avant déconnexion
    if (pending > 0) {
      _showSyncBeforeLogout(context, ref, l, pending);
      return;
    }

    // Aucune op en attente → déconnexion directe
    AppConfirmDialog.show(
      context: context,
      icon: Icons.logout_rounded,
      iconColor: AppColors.error,
      title: l.navLogoutConfirmTitle,
      body: Text(l.navLogoutConfirmBody,
          style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
      cancelLabel: l.cancel,
      confirmLabel: l.navLogoutConfirmBtn,
      confirmColor: AppColors.error,
      onConfirm: () => context.read<AuthBloc>().add(AuthLogoutRequested()),
    );
  }

  void _showSyncBeforeLogout(BuildContext context, WidgetRef ref,
      AppLocalizations l, int pending) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _SyncBeforeLogoutSheet(pending: pending),
    );
  }
}

// ─── Sheet : synchroniser avant déconnexion ──────────────────────────────────

class _SyncBeforeLogoutSheet extends ConsumerStatefulWidget {
  final int pending;
  const _SyncBeforeLogoutSheet({required this.pending});
  @override
  ConsumerState<_SyncBeforeLogoutSheet> createState() =>
      _SyncBeforeLogoutSheetState();
}

class _SyncBeforeLogoutSheetState
    extends ConsumerState<_SyncBeforeLogoutSheet> {
  bool _syncing = false;
  bool _done    = false;

  Future<void> _syncAndLogout() async {
    setState(() => _syncing = true);
    try {
      await AppDatabase.flushOfflineQueue();
      if (mounted) setState(() => _done = true);
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) {
        Navigator.of(context).pop();
        context.read<AuthBloc>().add(AuthLogoutRequested());
      }
    } catch (_) {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _logoutAnyway() {
    Navigator.of(context).pop();
    context.read<AuthBloc>().add(AuthLogoutRequested());
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Poignée
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFE5E7EB),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // Icône
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B).withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.sync_problem_rounded,
                color: Color(0xFFF59E0B), size: 26),
          ),
          const SizedBox(height: 14),

          // Titre
          Text(
            l.logoutSyncTitle,
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),

          // Description
          Text(
            l.logoutSyncDescription(widget.pending),
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 13, color: Color(0xFF6B7280), height: 1.5),
          ),
          const SizedBox(height: 24),

          // Bouton sync + logout
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (_syncing || _done) ? null : _syncAndLogout,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              icon: _syncing
                  ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                  : _done
                  ? const Icon(Icons.check_rounded)
                  : const Icon(Icons.sync_rounded),
              label: Text(
                _syncing
                    ? l.syncInProgress
                    : _done
                    ? l.syncDone
                    : l.logoutSyncBtn,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Bouton déconnecter quand même
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: _syncing ? null : _logoutAnyway,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.error,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: Text(
                l.logoutAnyway,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tile « Mon abonnement » avec badge plan dynamique.
// Couleur du badge : danger=expiré, warning=<7j, success=actif, info=trial.
// ─────────────────────────────────────────────────────────────────────────────
class _SubscriptionTile extends ConsumerWidget {
  final bool         expanded;
  final VoidCallback onTap;
  const _SubscriptionTile({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final plan  = ref.watch(currentPlanProvider);

    // Couleur + label du badge selon l'état du plan.
    final Color  badgeColor;
    final String badgeText;
    if (plan.isBlocked || plan.isExpired || !plan.hasPlan) {
      badgeColor = sem.danger;
      badgeText  = l.drawerBadgeExpired;
    } else if (plan.expiresSoon) {
      badgeColor = sem.warning;
      badgeText  = '${plan.daysLeft}j';
    } else if (plan.isTrial) {
      badgeColor = sem.info;
      badgeText  = l.planTrial;
    } else {
      badgeColor = sem.success;
      badgeText  = plan.planLabel;
    }

    Widget compact() => Center(
        child: Stack(clipBehavior: Clip.none, children: [
          Icon(Icons.workspace_premium_rounded,
              size: 22, color: cs.onSurface.withOpacity(0.75)),
          Positioned(
            right: -4, top: -4,
            child: Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                color: badgeColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ]));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final useCompact = !expanded || constraints.maxWidth < 140;
              return Container(
                padding: EdgeInsets.symmetric(
                    horizontal: useCompact ? 8 : 12, vertical: 10),
                child: useCompact
                    ? compact()
                    : Row(children: [
                        Icon(Icons.workspace_premium_rounded,
                            size: 18, color: cs.onSurface.withOpacity(0.75)),
                        const SizedBox(width: 12),
                        Expanded(child: Text(l.drawerSubscription,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface))),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: badgeColor.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(badgeText,
                              style: TextStyle(fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: badgeColor)),
                        ),
                      ]),
              );
            },
          ),
        ),
      ),
    );
  }
}