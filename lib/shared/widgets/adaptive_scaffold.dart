import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/permisions/app_permissions.dart';
import '../../core/permisions/permission_guard.dart';
import '../../core/permisions/subscription_provider.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_palette.dart';
import '../../core/widgets/fortress_logo.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_event.dart';
import '../../features/caisse/presentation/bloc/caisse_bloc.dart';
import '../../features/caisse/presentation/widgets/cart_widget.dart';
import '../navigation/shell_nav_items.dart';
import '../providers/current_shop_provider.dart';
import 'app_primary_button.dart';
import 'offline_banner_widget.dart';
import 'pin_lock_banner.dart';
import 'stock_nav_chips.dart';

/// Largeur minimale en logical pixels pour activer le layout desktop
/// (sidebar 200px + topbar). En dessous, on bascule sur le layout mobile
/// (bottom nav + drawer Plus) — utile quand l'utilisateur redimensionne
/// la fenêtre desktop pour qu'elle ressemble à un écran téléphone.
const double _kDesktopWidthBreakpoint = 900;

/// True si l'OS est desktop (Windows / macOS / Linux), hors web.
bool _isDesktopOS() {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

/// True si on doit afficher le layout desktop : OS desktop **et** fenêtre
/// suffisamment large. Sur OS mobile (Android/iOS) ou fenêtre desktop
/// étroite, on retombe sur le layout mobile.
bool _useDesktopLayout(BuildContext context) {
  if (!_isDesktopOS()) return false;
  return MediaQuery.of(context).size.width >= _kDesktopWidthBreakpoint;
}

/// Calcule la route parente d'une route shell : on retire le dernier
/// segment de path. Ex: `/shop/X/parametres/theme` → `/shop/X/parametres`.
/// Retourne `null` si la route ne descend pas sous `/shop/<id>/<module>`
/// (rien à remonter).
String? _shellParentRoute(String location) {
  final segments = Uri.parse(location).pathSegments;
  if (segments.length <= 3 || segments[0] != 'shop') return null;
  return '/${segments.take(segments.length - 1).join('/')}';
}

/// True si l'utilisateur peut revenir en arrière, soit via le stack
/// GoRouter (push), soit via une route parente calculable. Sans ce
/// fallback, un user qui arrive en deep-link ou via `context.go()` direct
/// ne verrait jamais le back button.
bool _canSmartBack(BuildContext context) {
  if (context.canPop()) return true;
  final loc = GoRouterState.of(context).matchedLocation;
  return _shellParentRoute(loc) != null;
}

/// Navigation arrière intelligente : pop si stack disponible, sinon
/// navigation vers la route parente calculée.
void _smartBack(BuildContext context) {
  if (context.canPop()) {
    context.pop();
    return;
  }
  final loc = GoRouterState.of(context).matchedLocation;
  final parent = _shellParentRoute(loc);
  if (parent != null) context.go(parent);
}

/// Scaffold racine pour les pages "shell" (Dashboard, Caisse, Inventaire,
/// Clients, Finances, Commandes, Membres, Paramètres).
///
/// - Sur **mobile** (Android/iOS) : AppBar + body + bottom nav 5 onglets
///   fixes. Le 5ᵉ onglet ouvre un drawer "Plus" listant les modules
///   secondaires filtrés par rôle.
/// - Sur **desktop** (Windows/Linux/macOS hors web) : sidebar fixe 200px
///   avec logo + nom boutique en tête, tous les modules à plat (filtrés
///   par rôle), breadcrumb `FORTRESS › <module>` en haut du contenu.
///
/// Les sous-pages (détail produit, paiement, formulaire d'édition…)
/// continuent d'utiliser `AppScaffold` qui gère le layout sans nav.
class AdaptiveScaffold extends ConsumerStatefulWidget {
  final String       shopId;
  final Widget       body;
  final Widget?      floatingActionButton;
  /// Actions additionnelles affichées à droite de la topbar (en plus des
  /// boutons standards panier + notifications).
  final List<Widget>? extraActions;

  const AdaptiveScaffold({
    super.key,
    required this.shopId,
    required this.body,
    this.floatingActionButton,
    this.extraActions,
  });

  @override
  ConsumerState<AdaptiveScaffold> createState() => _AdaptiveScaffoldState();
}

class _AdaptiveScaffoldState extends ConsumerState<AdaptiveScaffold> {
  @override
  void initState() {
    super.initState();
    // S'abonne au realtime Supabase pour cette boutique. Idempotent — pas
    // de unsubscribe au dispose car la nav inter-pages est continue.
    AppDatabase.subscribeToShop(widget.shopId);
  }

  @override
  void didUpdateWidget(covariant AdaptiveScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shopId != widget.shopId) {
      AppDatabase.unsubscribeFromShop(oldWidget.shopId);
      AppDatabase.subscribeToShop(widget.shopId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms        = ref.watch(permissionsProvider(widget.shopId));
    final loc          = GoRouterState.of(context).matchedLocation;
    final selectedIdx  = shellSelectedIndex(loc, widget.shopId);
    // Layout desktop ssi OS desktop + fenêtre ≥ 900px de large. Sur fenêtre
    // étroite (utilisateur qui split-screen, ou OS mobile), on bascule
    // automatiquement sur le layout mobile.
    return _useDesktopLayout(context)
        ? _DesktopShell(
            shopId:        widget.shopId,
            body:          widget.body,
            fab:           widget.floatingActionButton,
            extraActions:  widget.extraActions,
            perms:         perms,
            selectedIndex: selectedIdx,
          )
        : _MobileShell(
            shopId:        widget.shopId,
            body:          widget.body,
            fab:           widget.floatingActionButton,
            extraActions:  widget.extraActions,
            perms:         perms,
            selectedIndex: selectedIdx,
          );
  }
}

// ─── Layout mobile ────────────────────────────────────────────────────────────

class _MobileShell extends StatelessWidget {
  final String                shopId;
  final Widget                body;
  final Widget?               fab;
  final List<Widget>?         extraActions;
  final AppPermissions        perms;
  final int                   selectedIndex;

  const _MobileShell({
    required this.shopId,
    required this.body,
    required this.fab,
    required this.extraActions,
    required this.perms,
    required this.selectedIndex,
  });

  @override
  Widget build(BuildContext context) {
    final l        = context.l10n;
    final theme    = Theme.of(context);
    final loc      = GoRouterState.of(context).matchedLocation;

    // Détection du contexte breadcrumb (spec round 9, prompt 2) : si
    // selectedIndex pointe sur un parent à children ET la route active
    // matche un enfant DIFFÉRENT de la route propre du parent, on est
    // sur une sub-page « enfant ». Le titre devient alors un breadcrumb
    // « ParentLabel › ChildLabel » et un back button apparaît.
    String? breadcrumbParent;
    String? breadcrumbChild;
    if (selectedIndex >= 0 && kShellNavItems[selectedIndex].hasChildren) {
      final parent = kShellNavItems[selectedIndex];
      final childIdx = activeChildIndex(parent, loc, shopId);
      if (childIdx >= 0 &&
          parent.children![childIdx].route(shopId) != parent.route(shopId)) {
        breadcrumbParent = (parent.labelMobile ?? parent.label)(l);
        breadcrumbChild  = parent.children![childIdx].label(l);
      }
    }
    final isChildSubPage = breadcrumbChild != null;
    // Sur les routes Stock (Produits/Emplacements/Transferts/
    // Mouvements/Incidents), les chips servent de navigation — pas de
    // back button (sinon UX confuse : 2 mécanismes de nav). On force
    // ces routes à être traitées comme « root » pour le shell même si
    // GoRouter les considère comme sub-pages.
    final onStockTab = matchesStockNavRoute(loc, shopId);
    final isChildSubPageEffective = isChildSubPage && !onStockTab;
    final isSubPage = (selectedIndex < 0 || isChildSubPageEffective)
        && !onStockTab;
    // Heuristique fallback (spec round 9 prompt 4 Q1.c) : si la route
    // est un sub-page hors mapping `kShellNavItems` (ex: /crm/client/:id,
    // /parametres/profile, /inventaire/product), extraire le dernier
    // segment du path et capitaliser pour produire un titre lisible.
    String fallbackSubPageTitle() {
      final segments = Uri.parse(loc).pathSegments;
      if (segments.isEmpty) return l.hubBrand;
      final raw = segments.last;
      // UUID/id pur (>= 16 chars sans tiret = uuid sans dashes, ou tirets nombreux) → on prend l'avant-dernier segment.
      final isLikelyId = raw.length >= 12
          && (raw.contains('-') || RegExp(r'^[0-9a-f]+$').hasMatch(raw));
      final segment = (isLikelyId && segments.length >= 2)
          ? segments[segments.length - 2]
          : raw;
      // dashes → espaces, capitaliser chaque mot
      final words = segment.split('-').map((w) =>
          w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}');
      return '${l.hubBrand} › ${words.join(' ')}';
    }
    // Sur les tabs Stock, le titre reste « Stock » (label parent
    // Inventaire) — le chip actif sous la topbar montre déjà la
    // sous-page courante, pas besoin de breadcrumb dans le titre.
    final title = onStockTab
        ? (kShellNavItems[2].labelMobile ?? kShellNavItems[2].label)(l)
        : (breadcrumbChild != null
            ? '$breadcrumbParent › $breadcrumbChild'
            : (selectedIndex < 0
                ? fallbackSubPageTitle()
                : kShellNavItems[selectedIndex].label(l)));

    // Spec round 9 : sur les root pages mobile, fond AppBar = primary
    // thème + titre/icônes blancs. Sur les sub-pages (back button visible),
    // on retombe sur le style standard (surface blanche, texte sombre)
    // pour préserver le contraste lecture.
    final cs            = theme.colorScheme;
    final appBarBg      = isSubPage ? cs.surface : cs.primary;
    final appBarFg      = isSubPage ? cs.onSurface : cs.onPrimary;
    final titleStyle    = isSubPage
        ? TextStyle(fontSize: isChildSubPage ? 14 : 17,
            fontWeight: isChildSubPage ? FontWeight.w600 : FontWeight.w800,
            color: appBarFg)
        : TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: appBarFg);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      // Drawer latéral (spec round 9 prompt 5) — remplace la bottom nav.
      // Largeur 80% screen, contenu arborescent _MobileDrawer.
      drawer: _MobileDrawer(
        shopId:           shopId,
        perms:            perms,
        selectedIndex:    selectedIndex,
        currentLocation:  loc,
      ),
      appBar: AppBar(
        // Sur sub-page : back button manuel via GoRouter (Navigator
        // standard est vide car GoRouter ne push pas dessus, donc
        // `automaticallyImplyLeading` ne fonctionne pas). Root : icône
        // hamburger qui ouvre le drawer latéral.
        automaticallyImplyLeading: false,
        backgroundColor: appBarBg,
        foregroundColor: appBarFg,
        iconTheme: IconThemeData(color: appBarFg),
        actionsIconTheme: IconThemeData(color: appBarFg),
        leading: isSubPage && _canSmartBack(context)
            ? IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: l.cancel,
                onPressed: () => _smartBack(context),
              )
            : Builder(builder: (innerCtx) => IconButton(
                icon: const Icon(Icons.menu_rounded, size: 26),
                tooltip: l.navMore,
                onPressed: () => Scaffold.of(innerCtx).openDrawer(),
              )),
        title: Text(title, style: titleStyle),
        actions: [
          _CartBadgeBtn(shopId: shopId),
          const _NotifBtn(),
          if (extraActions != null) ...extraActions!,
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [
        const PinLockBanner(),
        const OfflineBanner(),
        // Owner-only — auto-hide si plan actif, fond warning/danger selon
        // l'état (cf. permission_guard.dart). Restauré ici pour reproduire
        // le comportement global qu'avait l'ancien app_scaffold.dart.
        const SubscriptionBanner(),
        // StockNavChips supprimés round 13 — doublon avec le menu drawer
        // (Inventaire → Produits / Emplacements / Incidents). La nav passe
        // désormais uniquement par le drawer pour éviter la redondance.
        Expanded(child: body),
      ]),
      floatingActionButton: fab,
      // Bottom nav supprimée (spec round 9 prompt 5) — la nav passe
      // entièrement par le drawer latéral.
    );
  }
}

/// Drawer latéral mobile (spec round 9 prompt 5) — REMPLACE l'ancienne
/// bottom nav + sheet « Plus ». Largeur ≈ 80 % screen (clamped 240..320).
///
/// Contient TOUS les items nav visibles (primary + overflow), avec
/// arborescence (parents à children dépliables, ex: Inventaire,
/// Paramètres). Header = avatar boutique 36px + nom. Footer = tile
/// abonnement (owner) + déconnexion.
///
/// Auto-déploie le parent dont une route enfant est active à l'ouverture.
/// Tap leaf → nav + ferme drawer. Tap parent à children → toggle expand.
class _MobileDrawer extends ConsumerStatefulWidget {
  final String         shopId;
  final AppPermissions perms;
  final int            selectedIndex;
  final String         currentLocation;
  const _MobileDrawer({
    required this.shopId,
    required this.perms,
    required this.selectedIndex,
    required this.currentLocation,
  });

  @override
  ConsumerState<_MobileDrawer> createState() => _MobileDrawerState();
}

class _MobileDrawerState extends ConsumerState<_MobileDrawer> {
  final Set<int> _expanded = <int>{};

  @override
  void initState() {
    super.initState();
    _ensureActiveExpanded();
  }

  @override
  void didUpdateWidget(covariant _MobileDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentLocation != widget.currentLocation
        || oldWidget.selectedIndex != widget.selectedIndex) {
      _ensureActiveExpanded();
    }
  }

  /// Auto-déplie le parent dont une route enfant est active. Idempotent.
  void _ensureActiveExpanded() {
    if (widget.selectedIndex < 0) return;
    final item = kShellNavItems[widget.selectedIndex];
    if (item.hasChildren) _expanded.add(widget.selectedIndex);
  }

  @override
  Widget build(BuildContext context) {
    final l       = context.l10n;
    final theme   = Theme.of(context);
    final palette = ref.watch(themePaletteProvider);
    final shop    = ref.watch(currentShopProvider);
    final items   = shellMobileDrawerItems(widget.perms);
    final width   = (MediaQuery.of(context).size.width * 0.8).clamp(240.0, 320.0);

    return Drawer(
      width: width,
      backgroundColor: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ── Header : avatar boutique 36px + nom ────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
            child: Row(children: [
              _DrawerShopAvatar(name: shop?.name, palette: palette),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(shop?.name ?? l.hubBrand,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface)),
                  Text(l.hubBrand,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10,
                          letterSpacing: 0.6,
                          color: theme.colorScheme.onSurface.withOpacity(0.5))),
                ],
              )),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 22),
                tooltip: l.cancel,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
          ),
          Divider(height: 1,
              color: theme.colorScheme.onSurface.withOpacity(0.08)),
          // ── Items ───────────────────────────────────────────────────
          Expanded(child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            children: [
              for (final item in items)
                if (item.hasChildren)
                  _MobileDrawerGroup(
                    parent:           item,
                    parentIndex:      kShellNavItems.indexOf(item),
                    shopId:           widget.shopId,
                    palette:          palette,
                    currentLocation:  widget.currentLocation,
                    active:           _isActive(item),
                    expanded:         _expanded.contains(kShellNavItems.indexOf(item)),
                    onToggle: () => setState(() {
                      final idx = kShellNavItems.indexOf(item);
                      if (_expanded.contains(idx)) {
                        _expanded.remove(idx);
                      } else {
                        _expanded.add(idx);
                      }
                    }),
                    onNavigate: (route) {
                      Navigator.of(context).pop();
                      context.go(route);
                    },
                  )
                else
                  _MobileDrawerLeaf(
                    item:     item,
                    shopId:   widget.shopId,
                    palette:  palette,
                    selected: _isActive(item),
                    onTap: () {
                      Navigator.of(context).pop();
                      context.go(item.route(widget.shopId));
                    },
                  ),
            ],
          )),
          // ── Footer : abonnement (owner) + déconnexion ──────────────
          Divider(height: 1,
              color: theme.colorScheme.onSurface.withOpacity(0.08)),
          if (widget.perms.isOwner)
            const _SubscriptionTile(asListTile: true),
          ListTile(
            leading: Icon(Icons.logout_rounded,
                color: theme.colorScheme.error, size: 20),
            title: Text(l.navLogout,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600)),
            onTap: () {
              Navigator.of(context).pop();
              _confirmLogout(context);
            },
          ),
        ]),
      ),
    );
  }

  bool _isActive(ShellNavItem item) {
    if (widget.selectedIndex < 0) return false;
    return identical(kShellNavItems[widget.selectedIndex], item);
  }
}

/// Avatar boutique 36px (spec mobile drawer round 9 prompt 5) — initiale
/// du nom dans un cercle teinté primary.
class _DrawerShopAvatar extends StatelessWidget {
  final String?       name;
  final ThemePalette  palette;
  const _DrawerShopAvatar({required this.name, required this.palette});

  @override
  Widget build(BuildContext context) {
    final letter = (name == null || name!.trim().isEmpty)
        ? '?'
        : name!.trim().characters.first.toUpperCase();
    return Container(
      width: 36, height: 36,
      decoration: BoxDecoration(
        color: palette.primary,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(letter,
          style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.onPrimary)),
    );
  }
}

/// Leaf du drawer mobile — un item nav simple. Densité spec : padding
/// 12×14, icône 16, label 13. Highlight si actif (primary tinted).
class _MobileDrawerLeaf extends StatelessWidget {
  final ShellNavItem item;
  final String        shopId;
  final ThemePalette  palette;
  final bool          selected;
  final VoidCallback  onTap;
  const _MobileDrawerLeaf({
    required this.item,
    required this.shopId,
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return _MobileDrawerRow(
      icon:    selected ? item.iconSelected : item.icon,
      label:   item.label(l),
      badge:   item.badge?.call(shopId) ?? 0,
      selected: selected,
      palette:  palette,
      indent:   0,
      onTap:    onTap,
    );
  }
}

/// Groupe parent dépliable + ses enfants quand `expanded`. Tap parent =
/// toggle (pas de nav). Tap enfant = nav.
class _MobileDrawerGroup extends StatelessWidget {
  final ShellNavItem  parent;
  final int           parentIndex;
  final String        shopId;
  final ThemePalette  palette;
  final String        currentLocation;
  final bool          active;
  final bool          expanded;
  final VoidCallback  onToggle;
  final void Function(String) onNavigate;
  const _MobileDrawerGroup({
    required this.parent,
    required this.parentIndex,
    required this.shopId,
    required this.palette,
    required this.currentLocation,
    required this.active,
    required this.expanded,
    required this.onToggle,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final activeChild = activeChildIndex(parent, currentLocation, shopId);
    final children = parent.children!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _MobileDrawerRow(
        icon:     active ? parent.iconSelected : parent.icon,
        label:    parent.label(l),
        badge:    parent.badge?.call(shopId) ?? 0,
        selected: active,
        palette:  palette,
        indent:   0,
        onTap:    onToggle,
        trailing: AnimatedRotation(
          duration: const Duration(milliseconds: 150),
          turns: expanded ? 0.5 : 0,
          child: Icon(Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : AppColors.textSecondary),
        ),
      ),
      if (expanded)
        for (var i = 0; i < children.length; i++)
          _MobileDrawerRow(
            icon:     i == activeChild
                ? children[i].iconSelected
                : children[i].icon,
            label:    children[i].label(l),
            badge:    children[i].badge?.call(shopId) ?? 0,
            selected: i == activeChild,
            palette:  palette,
            indent:   28,
            onTap:    () => onNavigate(children[i].route(shopId)),
          ),
    ]);
  }
}

/// Ligne unique réutilisée par leafs et children. Densité mobile :
/// padding 12×14, icône 16, label 13. Highlight = bg primarySurface +
/// border-left 3px primary + fg primary.
class _MobileDrawerRow extends StatelessWidget {
  final IconData      icon;
  final String        label;
  final int           badge;
  final bool          selected;
  final ThemePalette  palette;
  final double        indent;
  final VoidCallback  onTap;
  final Widget?       trailing;
  const _MobileDrawerRow({
    required this.icon,
    required this.label,
    required this.badge,
    required this.selected,
    required this.palette,
    required this.indent,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected
        ? theme.colorScheme.primary
        : AppColors.textSecondary;
    final bg = selected
        ? palette.primarySurface
        : Colors.transparent;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          border: Border(
              left: BorderSide(
                  color: selected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 3)),
        ),
        // Spec mobile : padding 12 vertical / 14 horizontal (vs 9/12
        // desktop). Indent 28 sur les enfants.
        padding: EdgeInsets.fromLTRB(14 + indent, 12, 14, 12),
        child: Row(children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 12),
          Expanded(child: Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: fg))),
          if (badge > 0)
            Container(
              margin: const EdgeInsets.only(left: 4),
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                borderRadius: BorderRadius.circular(10),
              ),
              constraints: const BoxConstraints(minWidth: 18),
              child: Text('$badge',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onError)),
            ),
          if (trailing != null) ...[
            const SizedBox(width: 4),
            trailing!,
          ],
        ]),
      ),
    );
  }
}

/// Tuile « Déconnexion » du footer sidebar desktop. Pour le drawer mobile,
/// le bouton est inliné dans le sheet `_showOverflowSheet`.
class _LogoutTile extends StatelessWidget {
  const _LogoutTile();

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => _confirmLogout(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Icon(Icons.logout_rounded, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 10),
          Expanded(child: Text(l.navLogout,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.error),
              overflow: TextOverflow.ellipsis)),
        ]),
      ),
    );
  }
}

/// Affiche un dialogue de confirmation de déconnexion. Si des opérations
/// offline sont en attente, on prévient l'utilisateur — sans bloquer (le
/// flush est tenté côté AppDatabase au prochain démarrage).
void _confirmLogout(BuildContext context) {
  final l       = context.l10n;
  final theme   = Theme.of(context);
  final pending = AppDatabase.pendingOpsCount;
  showDialog<void>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      icon: Icon(Icons.logout_rounded, color: theme.colorScheme.error),
      title: Text(l.navLogoutConfirmTitle),
      content: Text(
        pending > 0
            ? '$pending opération(s) en attente de synchronisation. '
              'Elles seront retentées au prochain démarrage.'
            : l.navLogoutConfirmBody,
        style: const TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogCtx).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error),
          onPressed: () {
            Navigator.of(dialogCtx).pop();
            context.read<AuthBloc>().add(AuthLogoutRequested());
          },
          child: Text(l.navLogoutConfirmBtn),
        ),
      ],
    ),
  );
}

// ─── Layout desktop ───────────────────────────────────────────────────────────

class _DesktopShell extends StatelessWidget {
  final String        shopId;
  final Widget        body;
  final Widget?       fab;
  final List<Widget>? extraActions;
  final AppPermissions perms;
  final int           selectedIndex;

  const _DesktopShell({
    required this.shopId,
    required this.body,
    required this.fab,
    required this.extraActions,
    required this.perms,
    required this.selectedIndex,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = GoRouterState.of(context).matchedLocation;
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      floatingActionButton: fab,
      body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _DesktopSidebar(
          shopId:        shopId,
          perms:         perms,
          selectedIndex: selectedIndex,
        ),
        Expanded(child: Column(children: [
          _DesktopTopbar(
            shopId:        shopId,
            selectedIndex: selectedIndex,
            extraActions:  extraActions,
          ),
          const PinLockBanner(),
          const OfflineBanner(),
          const SubscriptionBanner(),
          // StockNavChips supprimés round 13 — doublon avec la sidebar
          // (Inventaire → Produits / Emplacements / Incidents). La nav
          // passe uniquement par la sidebar pour éviter la redondance.
          Expanded(child: body),
        ])),
      ]),
    );
  }
}

class _DesktopSidebar extends ConsumerStatefulWidget {
  final String   shopId;
  final AppPermissions perms;
  final int      selectedIndex;

  const _DesktopSidebar({
    required this.shopId,
    required this.perms,
    required this.selectedIndex,
  });

  @override
  ConsumerState<_DesktopSidebar> createState() => _DesktopSidebarState();
}

class _DesktopSidebarState extends ConsumerState<_DesktopSidebar> {
  /// Indices de [kShellNavItems] dont les sous-menus sont actuellement
  /// dépliés. Initialisé pour auto-expand le parent de la route active,
  /// puis modifié par l'utilisateur via tap sur l'en-tête de groupe.
  final Set<int> _expanded = <int>{};

  @override
  void initState() {
    super.initState();
    _ensureActiveExpanded();
  }

  @override
  void didUpdateWidget(covariant _DesktopSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _ensureActiveExpanded();
    }
  }

  /// Auto-déplie le parent quand une de ses routes enfants devient active.
  /// On ne replie jamais automatiquement — l'utilisateur garde le contrôle.
  void _ensureActiveExpanded() {
    if (widget.selectedIndex < 0) return;
    final item = kShellNavItems[widget.selectedIndex];
    if (item.hasChildren) _expanded.add(widget.selectedIndex);
  }

  @override
  Widget build(BuildContext context) {
    final l       = context.l10n;
    final theme   = Theme.of(context);
    final palette = ref.watch(themePaletteProvider);
    final shop    = ref.watch(currentShopProvider);
    final items   = shellAllItems(widget.perms);
    final loc     = GoRouterState.of(context).matchedLocation;

    return Container(
      width: 190,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
            right: BorderSide(
                color: theme.colorScheme.onSurface.withOpacity(0.08),
                width: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // ── Header : logo Fortress 28px + nom boutique tronqué ─────
        // Le logo Fortress remplace l'avatar boutique pour cohérence
        // de marque — le nom boutique reste à droite pour identifier
        // le contexte courant. Avatar conservé sur drawer mobile (plus
        // d'espace).
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
          child: Row(children: [
            const FortressLogo.dark(size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(
              shop?.name ?? l.hubBrand,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface),
            )),
          ]),
        ),
        Divider(height: 1,
            color: theme.colorScheme.onSurface.withOpacity(0.08)),
        // ── Items ──────────────────────────────────────────────────
        Expanded(child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          children: [
            for (final item in items)
              if (item.hasChildren)
                _SidebarGroup(
                  parent:   item,
                  parentIndex: kShellNavItems.indexOf(item),
                  shopId:   widget.shopId,
                  active:   _isActive(item),
                  expanded: _expanded.contains(kShellNavItems.indexOf(item)),
                  currentLocation: loc,
                  palette:  palette,
                  onToggle: () => setState(() {
                    final idx = kShellNavItems.indexOf(item);
                    _expanded.contains(idx)
                        ? _expanded.remove(idx)
                        : _expanded.add(idx);
                  }),
                )
              else
                _SidebarLeafTile(
                  item:     item,
                  shopId:   widget.shopId,
                  selected: _isActive(item),
                  palette:  palette,
                ),
          ],
        )),
        // ── Footer : abonnement (owner) + déconnexion ──────────────
        Divider(height: 1,
            color: theme.colorScheme.onSurface.withOpacity(0.08)),
        if (widget.perms.isOwner) const _SubscriptionTile(),
        const _LogoutTile(),
      ]),
    );
  }

  bool _isActive(ShellNavItem item) {
    if (widget.selectedIndex < 0) return false;
    return identical(kShellNavItems[widget.selectedIndex], item);
  }
}

/// Tuile feuille du sidebar (item sans sous-menu).
class _SidebarLeafTile extends StatelessWidget {
  final ShellNavItem  item;
  final String        shopId;
  final bool          selected;
  final ThemePalette  palette;

  const _SidebarLeafTile({
    required this.item,
    required this.shopId,
    required this.selected,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return _SidebarRow(
      icon:        selected ? item.iconSelected : item.icon,
      label:       item.label(l),
      selected:    selected,
      palette:     palette,
      indent:      0,
      onTap:       selected ? null : () => context.go(item.route(shopId)),
      badgeCount:  item.badge?.call(shopId) ?? 0,
    );
  }
}

/// Groupe parent dépliable + ses enfants quand `expanded`.
class _SidebarGroup extends StatelessWidget {
  final ShellNavItem  parent;
  final int           parentIndex;
  final String        shopId;
  final bool          active;
  final bool          expanded;
  final String        currentLocation;
  final ThemePalette  palette;
  final VoidCallback  onToggle;

  const _SidebarGroup({
    required this.parent,
    required this.parentIndex,
    required this.shopId,
    required this.active,
    required this.expanded,
    required this.currentLocation,
    required this.palette,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final activeChild = activeChildIndex(parent, currentLocation, shopId);
    final visibleChildren = parent.children!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _SidebarRow(
        icon:        active ? parent.iconSelected : parent.icon,
        label:       parent.label(l),
        selected:    active,
        palette:     palette,
        indent:      0,
        onTap:       onToggle,
        badgeCount:  parent.badge?.call(shopId) ?? 0,
        trailing: AnimatedRotation(
          duration: const Duration(milliseconds: 150),
          turns: expanded ? 0.5 : 0,
          child: Icon(Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : AppColors.textSecondary),
        ),
      ),
      if (expanded)
        for (var i = 0; i < visibleChildren.length; i++)
          _SidebarRow(
            icon:        i == activeChild
                ? visibleChildren[i].iconSelected
                : visibleChildren[i].icon,
            label:       visibleChildren[i].label(l),
            selected:    i == activeChild,
            palette:     palette,
            indent:      24,
            onTap:       i == activeChild
                ? null
                : () => context.go(visibleChildren[i].route(shopId)),
            badgeCount:  visibleChildren[i].badge?.call(shopId) ?? 0,
          ),
    ]);
  }
}

/// Ligne unique réutilisée pour parents et enfants — gère le rendu
/// (border-left primary, fond primary-50, indent enfant, badge).
class _SidebarRow extends StatelessWidget {
  final IconData       icon;
  final String         label;
  final bool           selected;
  final ThemePalette   palette;
  final double         indent;
  final VoidCallback?  onTap;
  final int            badgeCount;
  final Widget?        trailing;

  const _SidebarRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.palette,
    required this.indent,
    required this.onTap,
    required this.badgeCount,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected
        ? theme.colorScheme.primary
        : AppColors.textSecondary;
    final bg = selected
        ? palette.primarySurface
        : Colors.transparent;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          border: Border(
              left: BorderSide(
                  color: selected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2)),
        ),
        padding: EdgeInsets.fromLTRB(12 + indent, 9, 12, 9),
        child: Row(children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 10),
          Expanded(child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: fg),
          )),
          if (badgeCount > 0)
            Container(
              margin: const EdgeInsets.only(left: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                borderRadius: BorderRadius.circular(10),
              ),
              constraints: const BoxConstraints(minWidth: 18),
              child: Text('$badgeCount',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onError)),
            ),
          if (trailing != null) ...[
            const SizedBox(width: 4),
            trailing!,
          ],
        ]),
      ),
    );
  }
}

class _DesktopTopbar extends StatelessWidget {
  final String        shopId;
  final int           selectedIndex;
  final List<Widget>? extraActions;

  const _DesktopTopbar({
    required this.shopId,
    required this.selectedIndex,
    required this.extraActions,
  });

  @override
  Widget build(BuildContext context) {
    final l         = context.l10n;
    final theme     = Theme.of(context);
    final isSubPage = selectedIndex < 0;
    final activeLabel = isSubPage
        ? l.hubBrand
        : kShellNavItems[selectedIndex].label(l);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
            bottom: BorderSide(
                color: theme.colorScheme.onSurface.withOpacity(0.08))),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
      child: Row(children: [
        // Sub-page : back button explicite (la sidebar reste visible mais
        // l'utilisateur a besoin d'un retour rapide). Utilise GoRouter
        // (le Navigator standard n'a pas de stack avec context.push).
        // Root : pas de leading.
        if (isSubPage && _canSmartBack(context))
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            tooltip: l.cancel,
            onPressed: () => _smartBack(context),
          )
        else
          const SizedBox(width: 12),
        // Breadcrumb FORTRESS › <module>
        Text(l.hubBrand,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: theme.colorScheme.onSurface.withOpacity(0.6))),
        if (!isSubPage) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(Icons.chevron_right_rounded,
                size: 16,
                color: theme.colorScheme.onSurface.withOpacity(0.4)),
          ),
          Text(activeLabel,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface)),
        ],
        const Spacer(),
        _CartBadgeBtn(shopId: shopId),
        const _NotifBtn(),
        if (extraActions != null) ...extraActions!,
        const SizedBox(width: 4),
      ]),
    );
  }
}

// ─── Boutons standards de la topbar ───────────────────────────────────────────

class _CartBadgeBtn extends ConsumerWidget {
  final String shopId;
  const _CartBadgeBtn({required this.shopId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return BlocBuilder<CaisseBloc, CaisseState>(
      builder: (context, state) {
        return AppIconBadge(
          icon:    Icons.shopping_cart_outlined,
          count:   state.itemCount,
          tooltip: l.cartTitle,
          onTap:   () => _openCart(context, ref),
        );
      },
    );
  }

  /// Sur mobile : ouvre le panier dans un bottom sheet (le panier vit en
  /// surimpression de la page courante — pas de nouvelle route). Sur
  /// desktop : pousse `/caisse/payment` (le panier inline est déjà visible
  /// dans CaissePage en layout large, donc le bouton sert à passer à la
  /// page de paiement complète).
  ///
  /// `isEcommerce` est lu sur le shop courant pour rester cohérent avec
  /// le rendu du `CartWidget` dans CaissePage (mode e-commerce active des
  /// champs livraison/expédition supplémentaires).
  void _openCart(BuildContext context, WidgetRef ref) {
    if (_useDesktopLayout(context)) {
      context.push('/shop/$shopId/caisse/payment');
      return;
    }
    final theme    = Theme.of(context);
    final bloc     = context.read<CaisseBloc>();
    final isEcom   = ref.read(currentShopProvider)?.sector == 'ecommerce';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => BlocProvider.value(
        value: bloc,
        child: DraggableScrollableSheet(
          initialChildSize: 0.92,
          minChildSize:     0.5,
          maxChildSize:     0.97,
          expand: false,
          builder: (_, __) => CartWidget(shopId: shopId, isEcommerce: isEcom),
        ),
      ),
    );
  }
}

class _NotifBtn extends StatelessWidget {
  const _NotifBtn();

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final theme = Theme.of(context);
    return AppIconBadge(
      icon:    Icons.notifications_outlined,
      count:   0,
      tooltip: l.notificationsTitle,
      onTap: () {
        showModalBottomSheet<void>(
          context: context,
          backgroundColor: theme.colorScheme.surface,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          builder: (_) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(2),
                  )),
              const SizedBox(height: 16),
              Text(l.notificationsTitle,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface)),
              const SizedBox(height: 32),
              Icon(Icons.notifications_off_outlined,
                  size: 40,
                  color: theme.colorScheme.onSurface.withOpacity(0.3)),
              const SizedBox(height: 12),
              Text(l.notifEmptyTitle,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withOpacity(0.7))),
              const SizedBox(height: 4),
              Text(l.notifEmptyHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withOpacity(0.5))),
              const SizedBox(height: 24),
            ]),
          ),
        );
      },
    );
  }
}

/// Tuile « Mon abonnement » (footer sidebar desktop / drawer Plus mobile).
///
/// Affiche un badge couleur dynamique selon l'état du plan owner :
///   - rouge   = plan expiré, bloqué ou inexistant
///   - orange  = expire dans ≤ 7 jours
///   - bleu    = essai en cours
///   - vert    = abonnement actif
///
/// Visible seulement pour le owner (l'employé hérite du plan via
/// `get_user_plan` mais n'a pas le bouton « Renouveler »).
///
/// `asListTile: true` → rendu plat compatible bottom sheet drawer Plus.
/// `asListTile: false` (défaut) → rendu compact pour sidebar desktop.
class _SubscriptionTile extends ConsumerWidget {
  final bool asListTile;
  const _SubscriptionTile({this.asListTile = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l     = context.l10n;
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    final plan  = ref.watch(currentPlanProvider);

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

    void open() => context.push(RouteNames.subscription);

    if (asListTile) {
      return ListTile(
        leading: Icon(Icons.workspace_premium_rounded,
            color: theme.colorScheme.onSurface.withOpacity(0.75)),
        title: Text(l.drawerSubscription),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: badgeColor.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(badgeText,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: badgeColor)),
        ),
        onTap: () {
          Navigator.maybePop(context);
          open();
        },
      );
    }

    return InkWell(
      onTap: open,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          Icon(Icons.workspace_premium_rounded,
              size: 18,
              color: theme.colorScheme.onSurface.withOpacity(0.75)),
          const SizedBox(width: 10),
          Expanded(child: Text(l.drawerSubscription,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface.withOpacity(0.85)))),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: badgeColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(badgeText,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: badgeColor)),
          ),
        ]),
      ),
    );
  }
}
