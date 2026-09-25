import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/services/notification_service.dart';
import '../../core/storage/hive_boxes.dart';
import '../../core/permisions/app_permissions.dart';
import '../../core/permisions/permission_guard.dart';
import '../../core/permisions/subscription_provider.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_palette.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_event.dart';
import '../../features/caisse/presentation/bloc/caisse_bloc.dart';
import '../../features/caisse/presentation/widgets/cart_widget.dart';
import '../navigation/shell_nav_items.dart';
import '../providers/current_shop_provider.dart';
import 'app_primary_button.dart';
import 'app_overflow_menu.dart';
import 'offline_banner_widget.dart';
import 'sync_status_banner.dart';
import 'order_source_badge.dart';
import 'pin_lock_banner.dart';
import 'shop_logo_avatar.dart';
import 'shop_pull_to_refresh.dart';
import '../../core/config/app_modes.dart';
import '../../core/config/restaurant_mode.dart';
import '../../features/restaurant/presentation/widgets/resto_topbar.dart';
import '../../core/storage/local_storage_service.dart';
import 'stock_nav_chips.dart';
import 'alerts/new_web_order_banner.dart';
import 'alerts/scheduled_alerts_banner_host.dart';
import '../providers/scheduled_alerts_provider.dart';
import '../providers/new_web_orders_provider.dart';
import '../navigation/page_titles.dart';
import '../../core/providers/nav_collapsed_provider.dart';
import '../providers/cart_pane_provider.dart';
import '../../features/restaurant/presentation/widgets/resto_surfaces.dart';

/// Largeur minimale en logical pixels pour activer le layout desktop
/// (sidebar fixe 190px + topbar, drawer toujours visible). En dessous,
/// on bascule sur le layout mobile (AppBar + drawer caché derrière le
/// hamburger). Critère unique = largeur de fenêtre — s'applique à toutes
/// les plateformes (web, desktop natif, mobile).
const double _kDesktopWidthBreakpoint = 900;

/// Taille des icônes de la barre latérale RÉTRACTÉE.
///
/// Nettement plus grosses que les 16 dp du mode déployé, et c'est voulu : sans
/// libellé à côté, l'icône porte à elle seule l'identité de la page. Elle ne
/// peut pas rester à la taille d'un ornement posé devant du texte.
///
/// Le mode déployé, lui, garde 16 dp — il est partagé avec l'e-commerce, dont
/// l'aspect ne doit pas bouger.
const double _kRailIconSize = 24;

/// Hauteur de la zone tappable d'une icône de la barre rétractée.
const double _kRailTapHeight = 46;

/// Largeur de la barre latérale RÉTRACTÉE : l'icône centrée dans sa zone de
/// survol, plus 12 dp de marge de chaque côté.
const double _kSidebarCollapsedWidth = 76;

/// Écart entre les blocs du shell restaurant, et marge autour d'eux. Une seule
/// valeur pour les deux : les blocs doivent être aussi détachés du bord de
/// l'écran que les uns des autres, sinon le cadrage penche.
const double _kRestoBlockGap = 10;

/// Rayon des blocs du shell restaurant.
const double _kRestoBlockRadius = 20;

/// True si la fenêtre est assez large pour le layout desktop, peu importe
/// la plateforme. Garantit qu'un Chrome desktop plein écran ou un Windows
/// natif voient la même sidebar fixe ; un mobile ou une fenêtre étroite
/// retombe sur le drawer caché.
bool _useDesktopLayout(BuildContext context) {
  return MediaQuery.of(context).size.width >= _kDesktopWidthBreakpoint;
}

/// Calcule la route parente d'une route shell : on retire le dernier
/// segment de path. Ex: `/shop/X/parametres/theme` → `/shop/X/parametres`.
/// Retourne `null` si la route ne descend pas sous `/shop/<id>/<module>`
/// (rien à remonter).
String? _shellParentRoute(String location) {
  final segments = Uri.parse(location).pathSegments;
  if (segments.length <= 3 || segments[0] != 'shop') return null;
  // Cas Membres : la page est `/shop/<id>/parametres/shop` (vue Membres,
  // sous-item de CRM). Son « parent » par trim de segment serait
  // Paramètres, ce qui est faux : on y entre depuis le drawer, pas depuis
  // Paramètres. Le retour doit ramener à l'accueil (dashboard).
  if (segments.length == 4
      && segments[2] == 'parametres'
      && segments[3] == 'shop') {
    return '/shop/${segments[1]}/dashboard';
  }
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
  /// Actions additionnelles affichées à droite de la topbar (en plus des
  /// boutons standards panier + notifications).
  final List<Widget>? extraActions;

  const AdaptiveScaffold({
    super.key,
    required this.shopId,
    required this.body,
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
    // Active les notifications in-app pour TOUT membre actif. Le filtrage
    // fin se fait côté émetteur (cf. `_emitStockNotification` et
    // `_emitOrderNotification` qui restent réservés aux admins/owners ;
    // les notifs tickets sont déjà routées par destinataire dans
    // `_emitTicketNotification`/`_emitTicketReplyNotification`).
    final notifEnabled = perms.isMember;
    final wasEnabled   = NotificationService.enabledForCurrentUser.value;
    NotificationService.enabledForCurrentUser.value = notifEnabled;
    // Pousse le shopId courant dans le scope de lecture du centre de
    // notifs. Sans ça, la cloche affichait l'inbox de TOUTES les
    // boutiques du device (cross-contamination cf. fix). Reset effectif
    // au switch de boutique : la box Hive partagée est filtrée à la
    // lecture, pas vidée (les notifs hors-shop restent en cache pour
    // un retour ultérieur).
    NotificationService.setCurrentShop(widget.shopId);
    // Sur transition false→true (premier rendu membre), rejoue les
    // alertes stock pour les produits déjà bas/épuisés. La fonction
    // gate elle-même le rôle (admin/owner uniquement) ; pour un vendeur
    // l'appel est inerte mais sans effet de bord.
    if (notifEnabled && !wasEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AppDatabase.scanStockNotifications(widget.shopId);
      });
    }
    final goState      = GoRouterState.of(context);
    final loc          = goState.matchedLocation;
    final tabQuery     = goState.uri.queryParameters['tab'];
    final selectedIdx  = shellSelectedIndex(loc, widget.shopId,
        tabQuery: tabQuery, sector: shopSector(widget.shopId));
    // Layout desktop ssi OS desktop + fenêtre ≥ 900px de large. Sur fenêtre
    // étroite (utilisateur qui split-screen, ou OS mobile), on bascule
    // automatiquement sur le layout mobile.
    final shell = _useDesktopLayout(context)
        ? _DesktopShell(
            shopId:        widget.shopId,
            body:          widget.body,
            extraActions:  widget.extraActions,
            perms:         perms,
            selectedIndex: selectedIdx,
          )
        : _MobileShell(
            shopId:        widget.shopId,
            body:          widget.body,
            extraActions:  widget.extraActions,
            perms:         perms,
            selectedIndex: selectedIdx,
          );

    // Fond photographique du mode restaurant, posé SOUS TOUT LE SHELL —
    // barre latérale et barre supérieure comprises, qui sont rendues
    // translucides plus bas. Enveloppé ici et non autour du seul corps de page
    // pour que le décor traverse l'écran d'un bord à l'autre.
    //
    // L'e-commerce n'est jamais concerné : sans ce garde, il perdrait son fond
    // de thème (cf. règle « restaurant only »).
    // Publie l'état du décor pour les widgets partagés ouverts par-dessus
    // (feuilles de formulaire, dialogues) : leur contexte est celui du
    // Navigator racine et ne peut pas remonter jusqu'à la boutique.
    restoDecorActive = isRestaurantShop(widget.shopId);
    if (!restoDecorActive) return shell;
    return RestoBackdrop(child: shell);
  }
}

// ─── Layout mobile ────────────────────────────────────────────────────────────

class _MobileShell extends StatelessWidget {
  final String                shopId;
  final Widget                body;
  final List<Widget>?         extraActions;
  final AppPermissions        perms;
  final int                   selectedIndex;

  const _MobileShell({
    required this.shopId,
    required this.body,
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
    String? breadcrumbChild;
    final navSector = shopSector(shopId);
    if (selectedIndex >= 0 &&
        kShellNavItems[selectedIndex].hasChildrenIn(navSector)) {
      final parent = kShellNavItems[selectedIndex];
      final childIdx = activeChildIndex(parent, loc, shopId,
          tabQuery: GoRouterState.of(context).uri.queryParameters['tab']);
      if (childIdx >= 0 &&
          parent.children![childIdx].route(shopId) != parent.route(shopId)) {
        breadcrumbChild = parent.children![childIdx].label(l);
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
      return words.join(' ');
    }
    // Titre = nom EXACT de la page courante. Ordre de résolution :
    //   1. Mapping explicite des routes via `titleForLocation` (le plus
    //      précis, gère les sous-pages et sous-sous-pages — cf.
    //      page_titles.dart).
    //   2. Stock tab → label "Inventaire".
    //   3. Breadcrumb child (sous-page enregistrée comme child d'un item
    //      nav).
    //   4. Item nav courant.
    //   5. Fallback dérivé du dernier segment d'URL.
    final tabQuery = extractTabQuery(context, loc);
    final explicitTitle =
        titleForLocation(location: loc, shopId: shopId, l: l,
                         tabQuery: tabQuery);
    final title = explicitTitle
        ?? (onStockTab
            // `l.navStock` et non `kShellNavItems[2]`. Cet index en dur
            // designait l'entree « Stock » du RESTAURANT, alors que
            // `onStockTab` ne vaut que sur les routes d'inventaire
            // E-COMMERCE : le titre n'etait juste que parce que les deux
            // libelles valent le meme mot. Le premier reordonnancement de la
            // liste l'aurait casse en silence — celui de ce lot l'aurait fait
            // afficher « Menu ».
            ? l.navStock
            : (breadcrumbChild != null
                ? breadcrumbChild
                : (selectedIndex < 0
                    ? fallbackSubPageTitle()
                    : kShellNavItems[selectedIndex].label(l))));

    // Spec round 9 : sur les root pages mobile, fond AppBar = primary
    // thème + titre/icônes blancs. Sur les sub-pages (back button visible),
    // on retombe sur le style standard (surface blanche, texte sombre)
    // pour préserver le contraste lecture.
    final cs            = theme.colorScheme;
    // EN RESTAURATION, LA BARRE NE SE REMPLIT PAS DE LA COULEUR DU THÈME.
    //
    // Elle prend la SURFACE, opaque — comme la barre du haut en desktop :
    //   * la couleur du thème (ambre, violet…) reste une couleur d'ACCENT
    //     — badges, bouton actif, sélection — au lieu d'être un fond. Étalée
    //     sur toute la largeur, elle ne pouvait plus rien désigner ;
    //   * OPAQUE et non plus translucide (24/09/2026) : le décor qui
    //     transparaissait dessinait une bande claire en haut de l'écran, sans
    //     rien dire ;
    //   * mobile et desktop se ressemblent sur le même écran.
    final isResto       = isRestaurantShop(shopId);
    // Restauration : opaque ET de la famille du contenu (cf.
    // `restoChromeOpaque`) — `cs.surface` était le slate des cartes en sombre.
    final appBarBg      = isResto
        ? restoChromeOpaque(context)
        : (isSubPage ? cs.surface : cs.primary);
    final appBarFg      = (isResto || isSubPage) ? cs.onSurface : cs.onPrimary;
    final titleStyle    = isSubPage
        ? (isChildSubPage
            ? AppTextStyles.label.copyWith(
                fontWeight: FontWeight.w600, color: appBarFg)
            : AppTextStyles.subtitle.copyWith(
                fontWeight: FontWeight.w800, color: appBarFg))
        : AppTextStyles.body.copyWith(
            fontWeight: FontWeight.w500, color: appBarFg);

    return Scaffold(
      // Transparent en restauration : le fond photographique est monté sous ce
      // Scaffold (cf. AdaptiveScaffold.build).
      backgroundColor: isResto
          ? Colors.transparent
          : theme.scaffoldBackgroundColor,
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
        // Sans ces trois-là, Material teinte la barre de la couleur du thème
        // et lui ajoute une ombre dès que le contenu passe dessous : la
        // surface du restaurant changerait de teinte au premier défilement.
        elevation: isResto ? 0 : null,
        scrolledUnderElevation: isResto ? 0 : null,
        surfaceTintColor: isResto ? Colors.transparent : null,
        iconTheme: IconThemeData(color: appBarFg),
        actionsIconTheme: IconThemeData(color: appBarFg),
        // Hamburger retiré : la navigation passe désormais par la bottom nav
        // (manipulation à une main). Root → pas de leading ; sous-page →
        // bouton retour. Le menu complet reste accessible via l'onglet
        // « Plus » de la bottom nav (ouvre le drawer latéral).
        leading: isSubPage && _canSmartBack(context)
            ? IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: l.cancel,
                onPressed: () => _smartBack(context),
              )
            : null,
        // PAGE RACINE DU RESTAURANT : PAS DE TITRE ICI (lot Shell, 25/09/2026).
        // Le titre vit dans le corps (`RestoSectionHeader`) : le garder ici
        // l'affichait deux fois — « Stock » puis « Stock ». Même règle que la
        // barre d'ordinateur. Les SOUS-PAGES gardent le leur, avec le retour.
        title: (isResto && !isSubPage) ? null : Text(title, style: titleStyle),
        // À GAUCHE EN RESTAURATION. Le tableau de bord, le Stock, Commandes et
        // le Menu portent leur en-tête dans le corps, à gauche : un titre
        // centré en barre du haut en était le dernier vestige, et l'isolait du
        // reste. `null` ailleurs : le thème décide, l'e-commerce ne bouge pas.
        centerTitle: isResto ? false : null,
        actions: [
          const OfflineChip(),
          _CartBadgeBtn(shopId: shopId),
          // Cloche pour TOUT MEMBRE, comme le service qu'elle affiche : les
          // notifications sont activées pour tout membre (`notifEnabled`,
          // plus haut) et celles des tickets vont à leur destinataire,
          // employés compris. (Le commentaire disait « réservée admin +
          // owner » depuis mai, contre ce code même — corrigé le 25/09/2026.)
          if (perms.isMember) _NotifBtnWithAlertHalo(dot: isResto),
          if (extraActions != null) ...extraActions!,
          // Menu « 3 points » global (Compte / Aide / À propos) — extrême
          // droite, présent sur toutes les pages shell. RESTAURANT : le menu
          // du compte, comme sur ordinateur (« Admin · <boutique> » en tête),
          // l'avatar seul pour déclencheur — le nom n'y tient pas.
          if (isResto)
            RestoAccountMenu(
                shopId: shopId, isAdmin: perms.isShopAdmin, compact: true)
          else
            AppOverflowMenu(shopId: shopId),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [
        const PinLockBanner(),
        const SyncStatusBanner(),
        // Owner-only — auto-hide si plan actif, fond warning/danger selon
        // l'état (cf. permission_guard.dart). Restauré ici pour reproduire
        // le comportement global qu'avait l'ancien app_scaffold.dart.
        const SubscriptionBanner(),
        // Banner alertes commandes programmées (sprint 2B) — affiché dès
        // qu'une alerte WARNING+ est active. Auto-hide quand la liste se
        // vide (ack via modal ou statut commande change).
        const ScheduledAlertsBannerHost(),
        // Bannière commandes web non acquittées — alertes "nouvelle
        // commande arrivée via lien catalogue". Persiste jusqu'au clic
        // sur "Vu". Distincte de ScheduledAlertsBannerHost qui escalade
        // selon la proximité de l'heure de livraison.
        const NewWebOrderBanner(),
        // StockNavChips supprimés round 13 — doublon avec le menu drawer
        // (Inventaire → Produits / Emplacements / Incidents). La nav passe
        // désormais uniquement par le drawer pour éviter la redondance.
        // Tirer vers le bas actualise la boutique, sur toutes les pages.
        Expanded(child: ShopPullToRefresh(shopId: shopId, child: body)),
      ]),
      // Bottom nav (manipulation à une main) : 4 modules principaux + onglet
      // « Plus » qui ouvre le drawer latéral pour les modules secondaires
      // (Finances, WhatsApp, Historique, Messagerie, Paramètres…). Le drawer
      // `_MobileDrawer` reste défini ci-dessus et n'est plus ouvert que par
      // « Plus ».
      bottomNavigationBar: Builder(
        builder: (navCtx) => _MobileBottomNav(
          shopId:        shopId,
          perms:         perms,
          selectedIndex: selectedIndex,
          onMore:        () => Scaffold.of(navCtx).openDrawer(),
        ),
      ),
    );
  }
}

/// Bottom navigation mobile (manipulation à une main). Affiche les items
/// `primary` visibles (Accueil, Caisse, Stock, CRM…) + un onglet « Plus »
/// qui ouvre le drawer latéral [_MobileDrawer] (modules secondaires).
///
/// L'onglet actif = item dont l'index dans [kShellNavItems] == [selectedIndex]
/// (le parent est highlighté même sur une route enfant, cf. shellSelectedIndex).
/// « Plus » est actif quand la route courante ne tombe dans aucun item primary.
class _MobileBottomNav extends ConsumerWidget {
  final String         shopId;
  final AppPermissions perms;
  final int            selectedIndex;
  final VoidCallback   onMore;
  const _MobileBottomNav({
    required this.shopId,
    required this.perms,
    required this.selectedIndex,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l        = context.l10n;
    final theme    = Theme.of(context);
    // Secteur lu DÉTERMINISTE par shopId (Hive), pas via currentShopProvider :
    // ce dernier peut être null pendant une transition de route, ce qui ferait
    // disparaître/réapparaître l'onglet restaurant à chaque navigation.
    final primaries = shellPrimaryItems(perms, sector: shopSector(shopId));
    final primaryIndices =
        primaries.map((it) => kShellNavItems.indexOf(it)).toSet();
    final moreActive = !primaryIndices.contains(selectedIndex);
    // Badge Caisse = commandes web non acquittées (provider existant, pas de
    // logique recréée).
    final webOrders =
        ref.watch(newWebOrdersProvider).valueOrNull?.length ?? 0;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
            top: BorderSide(color: theme.semantic.borderSubtle, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(children: [
            for (final item in primaries)
              _BottomNavTab(
                icon: kShellNavItems.indexOf(item) == selectedIndex
                    ? item.iconSelected
                    : item.icon,
                label: (item.labelMobile ?? item.label)(l),
                selected: kShellNavItems.indexOf(item) == selectedIndex,
                badge: item.route(shopId).endsWith('/caisse')
                    ? webOrders
                    : (item.badge?.call(shopId) ?? 0),
                onTap: () => context.go(item.route(shopId)),
              ),
            _BottomNavTab(
              icon: Icons.menu_rounded,
              label: l.navMore,
              selected: moreActive,
              badge: 0,
              onTap: onMore,
            ),
          ]),
        ),
      ),
    );
  }
}

/// Un onglet de la bottom nav mobile : icône + libellé court, teinté primary
/// quand actif, avec pastille de badge optionnelle (ex. incidents stock).
class _BottomNavTab extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final bool         selected;
  final int          badge;
  final VoidCallback onTap;
  const _BottomNavTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : AppColors.textSecondary;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(clipBehavior: Clip.none, children: [
              Icon(icon, size: 23, color: color),
              if (badge > 0)
                Positioned(
                  right: -7, top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints: const BoxConstraints(minWidth: 16),
                    child: Text('$badge',
                        textAlign: TextAlign.center,
                        style: AppTextStyles.micro.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onError)),
                  ),
                ),
            ]),
            // Label visible UNIQUEMENT sur l'onglet actif (inactif = icône
            // seule) — style demandé dans la spec.
            if (selected) ...[
              const SizedBox(height: 3),
              Text(label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: color)),
            ],
          ],
        ),
      ),
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
    if (item.hasChildrenIn(shopSector(widget.shopId))) {
      _expanded.add(widget.selectedIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l       = context.l10n;
    final theme   = Theme.of(context);
    final palette = ref.watch(themePaletteProvider);
    final shop    = ref.watch(currentShopProvider);
    final sector  = shopSector(widget.shopId);
    final items   = shellMobileDrawerItems(widget.perms, sector: sector);
    final width   = (MediaQuery.of(context).size.width * 0.8).clamp(240.0, 320.0);
    // Fond adaptatif : clair = surface ; sombre = teinte profonde derivee du
    // primary (coherent avec la sidebar desktop). Dividers teintes en sombre.
    final isDark     = theme.brightness == Brightness.dark;
    // Fond identique au contenu (scaffold) plutôt qu'une teinte dérivée
    // de la palette : le menu ne se détache plus en une bande sombre.
    final navBg      = isDark
        ? theme.scaffoldBackgroundColor
        : theme.colorScheme.surface;
    final navDivider = isDark
        ? palette.primaryLight.withValues(alpha: 0.15)
        : theme.colorScheme.onSurface.withValues(alpha: 0.08);
    // Items en groupes (séparés par dividers) + items de footer (Paramètres).
    final groups      = navGroups(items, sector: sector);
    final footerItems = navFooterItems(items);

    Widget buildNavItem(ShellNavItem item) {
      if (item.hasChildrenIn(shopSector(widget.shopId))) {
        return _MobileDrawerGroup(
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
        );
      }
      return _MobileDrawerLeaf(
        item:     item,
        shopId:   widget.shopId,
        palette:  palette,
        selected: _isActive(item),
        onTap: () {
          Navigator.of(context).pop();
          context.go(item.route(widget.shopId));
        },
      );
    }

    return Drawer(
      width: width,
      backgroundColor: navBg,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ── Header : logo boutique (fallback Fortress) + nom + actions
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  ShopLogoAvatar(
                      logoUrl: shop?.logoUrl,
                      // MONOGRAMME EN RESTAURATION SEULEMENT. L'avatar est
                      // une chrome PARTAGÉE : sans ce garde, la boutique
                      // e-commerce en production troquerait son bouclier
                      // contre deux lettres sans l'avoir demandé. Le champ est
                      // facultatif, et `null` rétablit exactement le rendu
                      // d'avant.
                      shopName: kRestaurantSectors.contains(sector)
                          ? shop?.name
                          : null,
                      size: 40),
                  const SizedBox(width: 12),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(shop?.name ?? l.hubBrand,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.label.copyWith(
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.onSurface)),
                      Text(l.hubBrand,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.micro.copyWith(
                              letterSpacing: 0.6,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.5))),
                    ],
                  )),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 22),
                    tooltip: l.cancel,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ]),
                const SizedBox(height: 10),
                _DrawerShopActions(
                  onSwitch: () {
                    Navigator.of(context).pop();
                    context.go(RouteNames.shopSelector);
                  },
                ),
              ],
            ),
          ),
          Divider(height: 1, color: navDivider),
          // ── Items groupés (G1 · G2 · G3, séparés par dividers) ───────
          Expanded(child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            children: [
              for (var gi = 0; gi < groups.length; gi++) ...[
                // Le NUMÉRO du groupe se lit sur son premier item : `groups`
                // est une liste de listes, son index n'est pas le groupe.
                if (navSectionLabel(groups[gi].first.groupFor(sector), sector)
                    case final title?)
                  _NavSectionLabel(text: title),
                for (final item in groups[gi]) buildNavItem(item),
                if (gi < groups.length - 1)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Divider(height: 0.5, color: navDivider),
                  ),
              ],
            ],
          )),
          // ── Footer : Paramètres · Abonnement (owner) · Déconnexion ───
          Divider(height: 1, color: navDivider),
          for (final item in footerItems) buildNavItem(item),
          if (widget.perms.isOwner)
            const _SubscriptionTile(asListTile: true),
          // UN FILET AVANT LA DÉCONNEXION. Elle s'alignait avec les entrées de
          // navigation, alors qu'elle ne navigue pas : elle sort. Une action
          // qui met fin à la session n'a pas à se viser du même geste que
          // celle qui ouvre un écran.
          Divider(height: 1, color: navDivider),
          ListTile(
            leading: Icon(Icons.logout_rounded,
                color: theme.colorScheme.error, size: 20),
            title: Text(l.navLogout,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600)),
            onTap: () {
              // Capturer le context du Navigator racine AVANT le pop —
              // le context du ListTile devient invalide dès que le drawer
              // se démonte, et `AppLocalizations.of(context)!` planterait
              // ensuite avec "Null check operator used on a null value".
              final rootCtx =
                  Navigator.of(context, rootNavigator: true).context;
              Navigator.of(context).pop();
              _confirmLogout(rootCtx);
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

/// Actions du header drawer : uniquement « Changer de boutique » désormais.
/// La création d'une nouvelle boutique a été déplacée vers
/// Inventaire → Emplacements → section Boutiques (carte dédiée), pour
/// regrouper toutes les actions liées à l'organisation des emplacements
/// au même endroit.
class _DrawerShopActions extends StatelessWidget {
  final VoidCallback onSwitch;
  const _DrawerShopActions({required this.onSwitch});

  @override
  Widget build(BuildContext context) {
    final uid = LocalStorageService.getCurrentUser()?.id ?? '';
    final shopsCount = uid.isEmpty
        ? 0
        : LocalStorageService.getShopsForUser(uid).length;
    final hasMultiple = shopsCount > 1;
    // Avec une seule boutique, aucune action — le bouton "Changer" n'a
    // pas de sens (rien vers quoi switch).
    if (!hasMultiple) return const SizedBox.shrink();
    return _DrawerActionBtn(
      icon: Icons.swap_horiz_rounded,
      label: 'Changer de boutique',
      onTap: onSwitch,
    );
  }
}

class _DrawerActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  /// `true` = bouton plein violet (CTA principal). `false` = outline.
  final bool filled;
  const _DrawerActionBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    final bg = filled
        ? AppColors.primary
        : Theme.of(context).colorScheme.surface;
    final fg = filled
        ? Colors.white
        : AppColors.primary;
    final borderColor = filled
        ? Colors.transparent
        : AppColors.primary.withValues(alpha: 0.40);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.captionBold.copyWith(color: fg)),
            ),
          ]),
        ),
      ),
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
    // Filtrés par SECTEUR, comme la barre latérale (lot Shell, 25/09/2026) :
    // le tiroir montrait `parent.children!` en entier. L'index actif est
    // rapporté à la liste VISIBLE — `activeChildIndex` indexe la liste
    // complète.
    final children = parent.childrenFor(shopSector(shopId));
    final activeFull = activeChildIndex(parent, currentLocation, shopId,
        tabQuery: GoRouterState.of(context).uri.queryParameters['tab']);
    final activeChild =
        activeFull < 0 ? -1 : children.indexOf(parent.children![activeFull]);
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
    final isDark = theme.brightness == Brightness.dark;
    // Cf. _SidebarRow : accent palette adaptatif, inactif lisible en sombre.
    final accent = isDark ? palette.primaryLight : palette.primary;
    final fg = selected
        ? accent
        : (isDark
            ? theme.colorScheme.onSurface.withValues(alpha: 0.62)
            : AppColors.textSecondary);
    // Plus de fond teinté sur l'item actif : la sélection se lit désormais à
    // la couleur d'accent + gras du texte/icône (cf. `fg`). Le fond reste
    // transparent dans tous les états.
    const bg = Colors.transparent;
    // Pill : container arrondi (radius 8) + padding 8×10, gap 8, icône 16,
    // label bodySm. Actif = bg accent 12 % ; hover = accent 5 %.
    return Padding(
      padding: EdgeInsets.fromLTRB(8 + indent, 1, 8, 1),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : accent.withValues(alpha: 0.05),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 8),
              Expanded(child: Text(label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySm.copyWith(
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
                      style: AppTextStyles.micro.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onError)),
                ),
              if (trailing != null) ...[
                const SizedBox(width: 4),
                trailing!,
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Tuile « Déconnexion » du footer sidebar desktop. Pour le drawer mobile,
/// le bouton est inliné dans le sheet `_showOverflowSheet`.
class _LogoutTile extends StatelessWidget {
  final bool collapsed;
  const _LogoutTile({this.collapsed = false});

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final theme = Theme.of(context);
    if (collapsed) {
      return Tooltip(
        message: l.navLogout,
        child: InkWell(
          onTap: () => _confirmLogout(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Icon(Icons.logout_rounded,
                size: _kRailIconSize, color: theme.colorScheme.error),
          ),
        ),
      );
    }
    return InkWell(
      onTap: () => _confirmLogout(context),
      // Métriques calquées sur `_SidebarRow` (icône 16, gap 8, bodySm,
      // padding gauche 18 = 8 externe + 10 interne) : sans ça le footer
      // paraissait d'un cran plus gros que les items de navigation.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        child: Row(children: [
          Icon(Icons.logout_rounded, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(child: Text(l.navLogout,
              style: AppTextStyles.bodySm.copyWith(
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
        style: AppTextStyles.body,
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
  final List<Widget>? extraActions;
  final AppPermissions perms;
  final int           selectedIndex;

  const _DesktopShell({
    required this.shopId,
    required this.body,
    required this.extraActions,
    required this.perms,
    required this.selectedIndex,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resto = isRestaurantShop(shopId);

    final sidebar = _DesktopSidebar(
      shopId:        shopId,
      perms:         perms,
      selectedIndex: selectedIndex,
    );
    final topbar = _DesktopTopbar(
      shopId:        shopId,
      selectedIndex: selectedIndex,
      extraActions:  extraActions,
      perms:         perms,
    );
    // Bandeaux d'alerte — chacun se réduit à rien quand il n'a rien à dire,
    // donc les empiler ne coûte aucune hauteur en temps normal.
    const banners = [
      PinLockBanner(),
      SyncStatusBanner(),
      SubscriptionBanner(),
      // Banner alertes commandes programmées (sprint 2B) — cf. mobile.
      ScheduledAlertsBannerHost(),
      // Bannière commandes web non acquittées — alertes "nouvelle
      // commande arrivée via lien catalogue". Persiste jusqu'au clic
      // sur "Vu". Distincte de ScheduledAlertsBannerHost qui escalade
      // selon la proximité de l'heure de livraison.
      NewWebOrderBanner(),
    ];

    // ── RESTAURATION : trois blocs détachés ─────────────────────────────
    // Barre de navigation, barre supérieure et contenu deviennent trois
    // panneaux à coins arrondis, séparés par du vide qui laisse voir le décor.
    // Ailleurs, les trois zones restent jointives : c'est le shell historique
    // de l'e-commerce, et le détacher changerait l'aspect de toutes ses pages.
    if (resto) {
      return Scaffold(
        // Transparent : le fond photographique est monté SOUS ce Scaffold,
        // un fond opaque ici le masquerait entièrement.
        backgroundColor: Colors.transparent,
        body: Padding(
          padding: const EdgeInsets.all(_kRestoBlockGap),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _RestoShellBlock(child: sidebar),
            const SizedBox(width: _kRestoBlockGap),
            Expanded(child: Column(children: [
              _RestoShellBlock(child: topbar),
              const SizedBox(height: _kRestoBlockGap),
              ...banners,
              Expanded(
                child: _RestoShellBlock(
                    fill: true,
                    child: ShopPullToRefresh(shopId: shopId, child: body)),
              ),
            ])),
          ]),
        ),
      );
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        sidebar,
        Expanded(child: Column(children: [
          topbar,
          ...banners,
          // StockNavChips supprimés round 13 — doublon avec la sidebar
          // (Inventaire → Produits / Emplacements / Incidents). La nav
          // passe uniquement par la sidebar pour éviter la redondance.
          Expanded(child: ShopPullToRefresh(shopId: shopId, child: body)),
        ])),
      ]),
    );
  }
}

/// Panneau du shell restaurant : coins arrondis, et un fond quand le contenu
/// n'en peint pas lui-même.
///
/// La barre de navigation et la barre supérieure portent déjà leur teinte
/// (`restoChromeFill`) — les envelopper d'un second fond les rendrait plus
/// opaques que voulu. Le contenu, lui, est transparent : sans `fill`, la photo
/// de salle passerait à travers la grille des plats.
class _RestoShellBlock extends StatelessWidget {
  final Widget child;
  final bool fill;

  const _RestoShellBlock({required this.child, this.fill = false});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(_kRestoBlockRadius);
    final clipped = ClipRRect(borderRadius: radius, child: child);
    if (!fill) return clipped;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: restoGlassFill(context),
        borderRadius: radius,
        border: Border.all(color: restoGlassBorder(context)),
      ),
      child: clipped,
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
    if (item.hasChildrenIn(shopSector(widget.shopId))) {
      _expanded.add(widget.selectedIndex);
    }
  }

  /// Bascule rétracté / déployé. Le choix est PERSISTÉ : sur web la page est
  /// rechargée à chaque déploiement, un état en mémoire seule obligerait à
  /// re-rétracter la barre plusieurs fois par jour.
  void _toggleCollapsed() {
    final resto = isRestaurantShop(widget.shopId);
    final current =
        navCollapsedFor(ref.read(navCollapsedProvider), isRestaurant: resto);
    ref.read(navCollapsedProvider.notifier).set(!current);
  }

  @override
  Widget build(BuildContext context) {
    final l       = context.l10n;
    final theme   = Theme.of(context);
    final palette = ref.watch(themePaletteProvider);
    final shop    = ref.watch(currentShopProvider);
    final resto   = isRestaurantShop(widget.shopId);
    final collapsed = navCollapsedFor(ref.watch(navCollapsedProvider),
        isRestaurant: resto);
    final sector  = shopSector(widget.shopId);
    final items   = shellAllItems(widget.perms, sector: sector);
    final loc     = GoRouterState.of(context).matchedLocation;
    // Fond adaptatif : clair = surface blanc cassé ; sombre = teinte profonde
    // dérivée du primary de la palette active. Dividers teintés primary en
    // sombre. Réactif : `palette` + `theme.brightness` sont watchés.
    final isDark     = theme.brightness == Brightness.dark;
    // Fond identique au contenu (scaffold) plutôt qu'une teinte dérivée
    // de la palette : le menu ne se détache plus en une bande sombre.
    //
    // En restauration, translucide : le décor doit se deviner derrière les
    // libellés de navigation. Le tiroir mobile, lui, reste opaque — un tiroir
    // translucide laisserait voir la page en dessous, illisible.
    final navBg      = isRestaurantShop(widget.shopId)
        ? restoChromeFill(context)
        : (isDark
            ? theme.scaffoldBackgroundColor
            : theme.colorScheme.surface);
    final navDivider = isDark
        ? palette.primaryLight.withValues(alpha: 0.15)
        : theme.colorScheme.onSurface.withValues(alpha: 0.08);
    // Items en groupes (séparés par dividers) + items de footer (Paramètres).
    final groups      = navGroups(items, sector: sector);
    final footerItems = navFooterItems(items);

    Widget buildNavItem(ShellNavItem item) {
      if (item.hasChildrenIn(shopSector(widget.shopId))) {
        return _SidebarGroup(
          parent:   item,
          parentIndex: kShellNavItems.indexOf(item),
          shopId:   widget.shopId,
          active:   _isActive(item),
          expanded: _expanded.contains(kShellNavItems.indexOf(item)),
          currentLocation: loc,
          palette:  palette,
          collapsed: collapsed,
          onToggle: () => setState(() {
            final idx = kShellNavItems.indexOf(item);
            _expanded.contains(idx)
                ? _expanded.remove(idx)
                : _expanded.add(idx);
          }),
        );
      }
      return _SidebarLeafTile(
        item:     item,
        shopId:   widget.shopId,
        selected: _isActive(item),
        palette:  palette,
        collapsed: collapsed,
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      // Largeur sidebar desktop : 190 → 247 (+30%) pour libellés longs
      // (« Bénéfice net », « Campagnes marketing »…) sans troncature.
      // Rétractée : 68 dp, juste la place d'une icône centrée et de son halo
      // de survol.
      width: collapsed ? _kSidebarCollapsedWidth : 247,
      decoration: BoxDecoration(
        color: navBg,
        // Le liseré droit ne sert qu'à séparer la barre du contenu quand les
        // deux se touchent. En restauration ils sont désormais deux blocs
        // détachés à coins arrondis : le liseré y dessinerait un trait qui
        // dépasse de l'arrondi.
        border: resto
            ? null
            : Border(right: BorderSide(color: navDivider, width: 0.5)),
      ),
      // Pendant l'animation de largeur, la contrainte passe par toutes les
      // valeurs entre 68 et 247. `OverflowBox` force le contenu à se mettre en
      // page à sa largeur CIBLE tout du long, et `ClipRect` coupe ce qui
      // dépasse : sans les deux, le bandeau boutique et les libellés se
      // feraient comprimer image par image et Flutter signalerait un
      // débordement à chacune.
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: collapsed ? _kSidebarCollapsedWidth : 247,
          maxWidth: collapsed ? _kSidebarCollapsedWidth : 247,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
        // ── Header : avatar boutique (logo, fallback Fortress) + nom
        //            + sous-titre Fortress + actions Nouvelle/Changer
        if (collapsed)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 14, 0, 10),
            child: Column(children: [
              // L'avatar devient l'accès « changer de boutique » : les deux
              // boutons du bloc actions ne tiennent pas dans 68 dp.
              Tooltip(
                message: shop?.name ?? l.hubBrand,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => context.go(RouteNames.shopSelector),
                  child: ShopLogoAvatar(
                      logoUrl: shop?.logoUrl,
                      // Cf. le tiroir mobile : restaurant seulement.
                      shopName: resto ? shop?.name : null,
                      size: 34),
                ),
              ),
              const SizedBox(height: 8),
              _NavCollapseBtn(collapsed: true, onTap: _toggleCollapsed),
            ]),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  ShopLogoAvatar(
                      logoUrl: shop?.logoUrl,
                      shopName: resto ? shop?.name : null,
                      size: 36),
                  const SizedBox(width: 10),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(shop?.name ?? l.hubBrand,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodyBold.copyWith(
                              color: theme.colorScheme.onSurface)),
                      Text(l.hubBrand,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.micro.copyWith(
                              letterSpacing: 0.6,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.5))),
                    ],
                  )),
                  _NavCollapseBtn(collapsed: false, onTap: _toggleCollapsed),
                ]),
                const SizedBox(height: 10),
                _DrawerShopActions(
                  onSwitch: () => context.go(RouteNames.shopSelector),
                ),
              ],
            ),
          ),
        Divider(height: 1, color: navDivider),
        // ── Items groupés (G1 · G2 · G3, séparés par dividers) ───────
        Expanded(child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          children: [
            for (var gi = 0; gi < groups.length; gi++) ...[
              // MASQUÉ EN RÉTRACTÉ : dans 68 dp, « GESTION » se coupe après
              // deux lettres. Le filet, lui, reste — il sépare toujours.
              if (!collapsed)
                if (navSectionLabel(groups[gi].first.groupFor(sector), sector)
                    case final title?)
                  _NavSectionLabel(text: title, indent: 12),
              for (final item in groups[gi]) buildNavItem(item),
              if (gi < groups.length - 1)
                Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: collapsed ? 16 : 12, vertical: 6),
                  child: Divider(height: 0.5, color: navDivider),
                ),
            ],
          ],
        )),
        // ── Footer : Paramètres · Abonnement (owner) · Déconnexion ────
        Divider(height: 1, color: navDivider),
        for (final item in footerItems) buildNavItem(item),
        // Carte d'abonnement masquée en rétracté : c'est un bloc à deux lignes
        // de texte, illisible dans 68 dp. Elle revient au déploiement, et
        // reste atteignable par Paramètres.
        if (widget.perms.isOwner && !collapsed) const _SubscriptionTile(),
        // Cf. le tiroir mobile : la déconnexion sort, elle ne navigue pas.
        Divider(height: 1, color: navDivider),
        _LogoutTile(collapsed: collapsed),
          ]),
        ),
      ),
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
  final bool          collapsed;

  const _SidebarLeafTile({
    required this.item,
    required this.shopId,
    required this.selected,
    required this.palette,
    this.collapsed = false,
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
      collapsed:   collapsed,
      onTap:       selected ? null : () => context.go(item.route(shopId)),
      badgeCount:  item.badge?.call(shopId) ?? 0,
    );
  }
}

/// Bouton de bascule rétracté / déployé de la barre de navigation.
class _NavCollapseBtn extends StatelessWidget {
  final bool collapsed;
  final VoidCallback onTap;

  const _NavCollapseBtn({required this.collapsed, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    return Tooltip(
      message: collapsed ? 'Déployer le menu' : 'Réduire le menu',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
              collapsed
                  ? Icons.keyboard_double_arrow_right_rounded
                  : Icons.keyboard_double_arrow_left_rounded,
              // Rétracté, il est seul dans la colonne d'icônes et doit s'y
              // accorder ; déployé, il n'est qu'un ornement en bout de ligne.
              size: collapsed ? 20 : 18,
              color: fg),
        ),
      ),
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
  final bool          collapsed;
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
    this.collapsed = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // Filtrés par secteur : « Menu » n'a pas de sous-items en restauration.
    final visibleChildren = parent.childrenFor(shopSector(shopId));
    // Index rapporté à la liste VISIBLE (`activeChildIndex` indexe la liste
    // complète : un enfant masqué décalait la surbrillance — 25/09/2026).
    final activeFull = activeChildIndex(parent, currentLocation, shopId,
        tabQuery: GoRouterState.of(context).uri.queryParameters['tab']);
    final activeChild = activeFull < 0
        ? -1
        : visibleChildren.indexOf(parent.children![activeFull]);

    // RÉTRACTÉ — les enfants ne peuvent pas se déplier sous l'icône : dans
    // 68 dp ils seraient une colonne d'icônes anonymes, impossible de savoir
    // à quel parent elles appartiennent. Ils sortent donc en menu contextuel,
    // titré par le nom du parent.
    if (collapsed) {
      return PopupMenuButton<int>(
        // Vide = PAS d'infobulle propre : `_SidebarRow` en pose déjà une avec
        // le même libellé, et les deux se seraient superposées.
        tooltip: '',
        position: PopupMenuPosition.under,
        onSelected: (i) => context.go(visibleChildren[i].route(shopId)),
        itemBuilder: (_) => [
          PopupMenuItem<int>(
            enabled: false,
            height: 32,
            child: Text(parent.label(l), style: AppTextStyles.captionBold),
          ),
          for (var i = 0; i < visibleChildren.length; i++)
            PopupMenuItem<int>(
              value: i,
              height: 40,
              child: Row(children: [
                Icon(
                    i == activeChild
                        ? visibleChildren[i].iconSelected
                        : visibleChildren[i].icon,
                    size: 16,
                    color: i == activeChild
                        ? Theme.of(context).colorScheme.primary
                        : null),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(visibleChildren[i].label(l),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySm.copyWith(
                          fontWeight: i == activeChild
                              ? FontWeight.w700
                              : FontWeight.w500)),
                ),
              ]),
            ),
        ],
        // `onTap: null` : c'est le PopupMenuButton parent qui reçoit le tap,
        // la ligne n'est ici qu'un habillage.
        child: _SidebarRow(
          icon:       active ? parent.iconSelected : parent.icon,
          label:      parent.label(l),
          selected:   active,
          palette:    palette,
          indent:     0,
          collapsed:  true,
          onTap:      null,
          badgeCount: parent.badge?.call(shopId) ?? 0,
        ),
      );
    }

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
  /// Rendu icône seule : le libellé passe en infobulle, le compteur devient
  /// une pastille posée sur le coin de l'icône.
  final bool           collapsed;

  const _SidebarRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.palette,
    required this.indent,
    required this.onTap,
    required this.badgeCount,
    this.trailing,
    this.collapsed = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Accent = primary de la palette active (variante claire en sombre pour
    // rester lisible sur le fond teinté profond). Inactif : gris secondaire
    // en clair, onSurface atténué en sombre (lisible sur toutes les palettes).
    final accent = isDark ? palette.primaryLight : palette.primary;
    final fg = selected
        ? accent
        : (isDark
            ? theme.colorScheme.onSurface.withValues(alpha: 0.62)
            : AppColors.textSecondary);
    // Plus de fond teinté sur l'item actif : la sélection se lit désormais à
    // la couleur d'accent + gras du texte/icône (cf. `fg`). Le fond reste
    // transparent dans tous les états.
    const bg = Colors.transparent;
    // ── RÉTRACTÉ : icône centrée, libellé en infobulle ────────────────
    // L'icône ACTIVE prend un fond teinté : sans libellé, la seule couleur du
    // glyphe ne suffisait plus à repérer la page courante d'un coup d'œil.
    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Tooltip(
          message: label,
          waitDuration: const Duration(milliseconds: 350),
          child: Material(
            color: selected ? accent.withValues(alpha: 0.14) : bg,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(10),
              hoverColor: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : accent.withValues(alpha: 0.05),
              child: SizedBox(
                height: _kRailTapHeight,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Icon(icon, size: _kRailIconSize, color: fg),
                    if (badgeCount > 0)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.error,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          constraints: const BoxConstraints(minWidth: 14),
                          child: Text(
                              badgeCount > 99 ? '99+' : '$badgeCount',
                              textAlign: TextAlign.center,
                              style: AppTextStyles.micro.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: theme.colorScheme.onError)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Pill : container arrondi (radius 8) + padding 8×10, gap 8, icône 16,
    // label bodySm. Actif = bg accent 12 % ; hover = accent 5 %. Identique
    // au drawer mobile (cohérence sidebar/drawer).
    return Padding(
      padding: EdgeInsets.fromLTRB(8 + indent, 1, 8, 1),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : accent.withValues(alpha: 0.05),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 8),
              Expanded(child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodySm.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg),
              )),
              if (badgeCount > 0)
                Container(
                  margin: const EdgeInsets.only(left: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  constraints: const BoxConstraints(minWidth: 18),
                  child: Text('$badgeCount',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.micro.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onError)),
                ),
              if (trailing != null) ...[
                const SizedBox(width: 4),
                trailing!,
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _DesktopTopbar extends StatelessWidget {
  final String         shopId;
  final int            selectedIndex;
  final List<Widget>?  extraActions;
  final AppPermissions perms;

  const _DesktopTopbar({
    required this.shopId,
    required this.selectedIndex,
    required this.extraActions,
    required this.perms,
  });

  @override
  Widget build(BuildContext context) {
    final l         = context.l10n;
    final theme     = Theme.of(context);
    final isSubPage = selectedIndex < 0;
    final activeLabel = isSubPage
        ? l.hubBrand
        : kShellNavItems[selectedIndex].label(l);
    final resto = isRestaurantShop(shopId);
    return Container(
      decoration: BoxDecoration(
        // OPAQUE, restauration comprise (24/09/2026). Translucide, le décor
        // qui transparaissait dessinait une bande claire sans rien dire. Le
        // bloc reste DÉTACHÉ du contenu : c'est le vide qui les sépare.
        // Restauration : `restoChromeOpaque` et non `colorScheme.surface`,
        // qui valait en sombre le slate des cartes (#1E293B) au-dessus d'un
        // contenu quasi noir (25/09/2026).
        color: resto ? restoChromeOpaque(context) : theme.colorScheme.surface,
        // Le liseré du bas sépare la barre du contenu quand les deux se
        // touchent. En restauration ils sont deux blocs détachés : le liseré
        // y couperait le bord arrondi d'un trait droit.
        border: resto
            ? null
            : Border(
                bottom: BorderSide(
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.08))),
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
        // ── Variante RESTAURANT sur page racine : RIEN à gauche ─────────
        // La salutation qui vivait ici est partie (24/09/2026, `RestoGreeting`
        // supprimé) : le tableau de bord porte son en-tête dans le corps, et
        // les autres écrans leur titre à gauche. Les SOUS-PAGES ne sont pas
        // concernées : retour et fil d'ariane restent, comme en e-commerce.
        //
        // La RECHERCHE a été retirée de cette barre (2026-08-07) : elle ne
        // cherchait que des PLATS, et s'affichait pourtant sur Commandes, sur
        // le Plan de salle et sur Finances, où elle n'avait rien à trouver.
        // SOUS-PAGE DU RESTAURANT : son NOM, à côté du retour (lot Shell,
        // 25/09/2026). La barre n'affichait que « FORTRESS » : la page n'était
        // nommée nulle part. Même source que le titre mobile.
        if (resto && isSubPage)
          Flexible(
            child: Text(
                titleForLocation(
                      location: GoRouterState.of(context).matchedLocation,
                      shopId: shopId,
                      l: l,
                      tabQuery:
                          GoRouterState.of(context).uri.queryParameters['tab'],
                    ) ??
                    l.hubBrand,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface)),
          )
        else if (!(resto && !isSubPage)) ...[
          // Breadcrumb FORTRESS › <module>
          Text(l.hubBrand,
              style: AppTextStyles.bodySm.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.onSurface.withValues(alpha:0.6))),
          if (!isSubPage) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.chevron_right_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurface.withValues(alpha:0.4)),
            ),
            Text(activeLabel,
                style: AppTextStyles.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface)),
          ],
        ],
        const Spacer(),
        // Pas de geste « tirer » à la souris : bouton équivalent.
        ShopRefreshButton(shopId: shopId),
        const OfflineChip(),
        _CartBadgeBtn(shopId: shopId),
        // Cloche pour TOUT MEMBRE, comme sur mobile et comme le service
        // qu'elle affiche (cf. `notifEnabled`) — c'était `isShopAdmin` ici,
        // `isMember` sur mobile, depuis mai (corrigé le 25/09/2026). En
        // restauration, un POINT ambre au lieu d'un compteur rouge.
        if (perms.isMember) _NotifBtnWithAlertHalo(dot: resto),
        if (extraActions != null) ...extraActions!,
        // RESTAURANT : le NOM ouvre le menu du compte (chevron), et le rôle y
        // descend avec la boutique — plus de ⋮ à côté. L'e-commerce garde son
        // menu 3 points, identique.
        if (resto) ...[
          const SizedBox(width: 6),
          RestoAccountMenu(shopId: shopId, isAdmin: perms.isShopAdmin),
          const SizedBox(width: 4),
        ] else ...[
          // Menu « 3 points » global (Compte / Aide / À propos) — extrême
          // droite, présent sur toutes les pages shell.
          AppOverflowMenu(shopId: shopId),
          const SizedBox(width: 4),
        ],
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
    // ── RESTAURATION : le panier est un VOLET, plus une feuille modale ──
    // La page Menu affiche le panier à demeure sur sa droite. Ouvrir en plus
    // une feuille par-dessus revenait à empiler un second panier sur le
    // premier, déjà visible. Le bouton pilote donc ce volet :
    //   * on est sur le Menu  → il le replie / le redéploie ;
    //   * on est ailleurs     → il ramène au Menu, volet ouvert, puisque
    //                           c'est le seul écran qui le porte.
    if (isRestaurantShop(shopId)) {
      final menuRoute = '/shop/$shopId/inventaire';
      final onMenu = GoRouterState.of(context).matchedLocation == menuRoute;
      final pane = ref.read(cartPaneVisibleProvider.notifier);
      if (onMenu) {
        pane.toggle();
      } else {
        pane.show();
        context.go(menuRoute);
      }
      return;
    }
    // DÉTERMINISTE par `shopId` (pas la boutique « courante » du provider qui
    // peut être null/différente à l'ouverture) → évite le bug critique où le
    // panier affichait « Encaisser » (vente immédiate, décrément stock) au lieu
    // de « Enregistrer la commande » en mode e-commerce. Fallback Hive par id.
    final cur      = ref.read(currentShopProvider);
    final shop     = (cur != null && cur.id == shopId)
        ? cur
        : LocalStorageService.getShop(shopId);
    // Mode e-commerce unique (réversible : kEcommerceOnlyMode) → panier
    // toujours « Enregistrer la commande ».
    final isEcom   = kEcommerceOnlyMode || shop?.sector == 'ecommerce';
    // Desktop POS (non e-commerce) : raccourci vers la page de paiement.
    // En e-commerce, on NE va JAMAIS sur /payment (flux Encaisser) → on ouvre
    // le panier (Enregistrer la commande), même en desktop.
    if (_useDesktopLayout(context) && !isEcom) {
      context.push('/shop/$shopId/caisse/payment');
      return;
    }
    final theme    = Theme.of(context);
    final bloc     = context.read<CaisseBloc>();
    // À partir d'ici, la boutique n'est JAMAIS un restaurant : la branche du
    // haut est sortie avant. Le traitement particulier qu'avait la feuille en
    // restauration (fond transparent, voile allégé pour laisser voir le décor)
    // a donc été retiré — il ne pouvait plus s'appliquer.
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => BlocProvider.value(
        value: bloc,
        // Auto-fermeture du sheet panier dès que la commande est
        // enregistrée — sinon l'opérateur restait sur un panier vidé,
        // ce qui prêtait à confusion (pas de feedback de succès clair).
        child: BlocListener<CaisseBloc, CaisseState>(
          listenWhen: (prev, curr) =>
              prev.orderSaved != curr.orderSaved && curr.orderSaved == true,
          listener: (_, __) {
            if (Navigator.of(sheetCtx).canPop()) {
              Navigator.of(sheetCtx).pop();
            }
          },
          child: DraggableScrollableSheet(
            initialChildSize: 0.92,
            minChildSize:     0.5,
            maxChildSize:     0.97,
            expand: false,
            // Le `shape` de la feuille ne découpe pas son contenu : avec un
            // fond transparent, le panier redeviendrait un rectangle à angles
            // droits. On le découpe donc explicitement.
            builder: (_, __) => ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
              child: CartWidget(
                shopId: shopId,
                isEcommerce: isEcom,
                // Commande de restaurant créée : elle ne passe pas par
                // `SaveOrder`, donc `orderSaved` reste faux et le listener
                // ci-dessus ne se déclenche pas. Sans ce rappel, l'opérateur
                // resterait devant un panier vidé, sans savoir si sa commande
                // est partie.
                onOrderPlaced: () {
                  if (Navigator.of(sheetCtx).canPop()) {
                    Navigator.of(sheetCtx).pop();
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wrapper Riverpod du `_NotifBtn` qui superpose un halo rouge animé
/// (pulse) quand au moins une alerte commande programmée de niveau
/// ≥ CRITICAL est active. Le halo NE DISPARAÎT PAS au clic sur la cloche
/// (qui ouvre le panel notifs in-app) — il ne disparaît que quand l'alerte
/// critique est acquittée via la modal ou que la commande change de
/// statut. Sinon on aurait un faux signal de résolution.
///
/// Pas de fusion avec le badge chiffre des notifs : badge = unread count
/// du `NotificationService`, halo = alerte commande critique. Signaux
/// distincts qui peuvent coexister.
class _NotifBtnWithAlertHalo extends ConsumerStatefulWidget {
  /// Non lues en POINT ambre plutôt qu'en compteur rouge (restauration). Le
  /// halo rouge des alertes CRITIQUES, lui, reste : une commande programmée en
  /// retard est une urgence, pas « quelque chose à voir ».
  final bool dot;

  const _NotifBtnWithAlertHalo({this.dot = false});
  @override
  ConsumerState<_NotifBtnWithAlertHalo> createState() =>
      _NotifBtnWithAlertHaloState();
}

class _NotifBtnWithAlertHaloState
    extends ConsumerState<_NotifBtnWithAlertHalo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasCritical = ref.watch(scheduledAlertsHasCriticalProvider);
    if (!hasCritical) return _NotifBtn(dot: widget.dot);
    final danger = Theme.of(context).semantic.danger;
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        AnimatedBuilder(
          animation: _pulse,
          builder: (_, __) {
            // Opacity 0.25 ↔ 0.65 + scale 1.0 ↔ 1.15 pour un pulse
            // visible sans envahissant.
            final t = _pulse.value;
            return Container(
              width:  44, height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: danger.withValues(alpha: 0.25 + 0.40 * t),
                boxShadow: [
                  BoxShadow(
                    color: danger.withValues(alpha: 0.35 * (1 - t * 0.5)),
                    blurRadius: 10 + 6 * t,
                    spreadRadius: 1 + 2 * t,
                  ),
                ],
              ),
            );
          },
        ),
        _NotifBtn(dot: widget.dot),
      ],
    );
  }
}

class _NotifBtn extends StatelessWidget {
  final bool dot;

  const _NotifBtn({this.dot = false});

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final theme = Theme.of(context);
    // Badge live — se met à jour à chaque notif émise.
    return ValueListenableBuilder<int>(
      valueListenable: NotificationService.rev,
      builder: (_, __, ___) {
        final unread = NotificationService.unreadCount();
        return AppIconBadge(
          icon:    Icons.notifications_outlined,
          count:   unread,
          dot:     dot,
          tooltip: l.notificationsTitle,
          onTap: () {
            showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              backgroundColor: theme.colorScheme.surface,
              shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
              builder: (_) => const _NotificationsSheet(),
            );
          },
        );
      },
    );
  }
}

class _NotificationsSheet extends StatelessWidget {
  const _NotificationsSheet();

  IconData _iconFor(NotifKind k) {
    switch (k) {
      case NotifKind.stockLow:        return Icons.warning_amber_rounded;
      case NotifKind.stockOut:        return Icons.remove_shopping_cart_rounded;
      case NotifKind.orderNew:        return Icons.receipt_long_rounded;
      case NotifKind.orderValidated:  return Icons.verified_rounded;
      case NotifKind.orderCompleted:  return Icons.task_alt_rounded;
      case NotifKind.orderCancelled:  return Icons.cancel_outlined;
      case NotifKind.orderRejected:   return Icons.block_rounded;
      case NotifKind.kitchenReady:    return Icons.room_service_rounded;
      case NotifKind.ticketNew:       return Icons.forum_rounded;
      case NotifKind.ticketEscalated: return Icons.upgrade_rounded;
      case NotifKind.ticketReply:     return Icons.reply_rounded;
    }
  }

  Color _colorFor(NotifKind k, ThemeData theme) {
    final sem = theme.semantic;
    switch (k) {
      case NotifKind.stockLow:        return sem.warning;
      case NotifKind.stockOut:        return theme.colorScheme.error;
      case NotifKind.orderNew:        return theme.colorScheme.primary;
      case NotifKind.orderValidated:  return sem.success;
      case NotifKind.orderCompleted:  return sem.success;
      case NotifKind.orderCancelled:  return sem.warning;
      case NotifKind.orderRejected:   return theme.colorScheme.error;
      case NotifKind.kitchenReady:    return sem.warning;
      case NotifKind.ticketNew:       return sem.info;
      case NotifKind.ticketEscalated: return sem.warning;
      case NotifKind.ticketReply:     return theme.colorScheme.primary;
    }
  }

  String _formatTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1)  return "À l'instant";
    if (diff.inMinutes < 60) return 'Il y a ${diff.inMinutes} min';
    if (diff.inHours   < 24) return 'Il y a ${diff.inHours} h';
    return 'Il y a ${diff.inDays} j';
  }

  /// Tap sur une notif → ferme le sheet puis navigue selon le type :
  ///   * ticketNew / ticketEscalated → page détail du ticket.
  ///   * ticketReply → résout d'abord ticket_id depuis le messageId.
  ///   * Autres types → pas de navigation (juste mark-as-read).
  void _handleNotifTap(BuildContext context, AppNotification n) {
    final shopId = n.shopId;
    if (shopId == null || shopId.isEmpty) return;
    String? ticketId;
    switch (n.kind) {
      case NotifKind.ticketNew:
        ticketId = n.targetId;
      case NotifKind.ticketEscalated:
        // targetId = "<ticketId>_owner" ou "<ticketId>_super"
        final t = n.targetId ?? '';
        final i = t.lastIndexOf('_');
        ticketId = i > 0 ? t.substring(0, i) : t;
      case NotifKind.ticketReply:
        // targetId = messageId → résout via la box messages.
        final raw = HiveBoxes.ticketMessagesBox.get(n.targetId);
        if (raw is Map) {
          ticketId = raw['ticket_id']?.toString();
        }
      default:
        return;
    }
    if (ticketId == null || ticketId.isEmpty) return;
    Navigator.of(context).pop(); // ferme le sheet
    context.push('/shop/$shopId/tickets/$ticketId');
  }

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, scrollCtrl) {
        return ValueListenableBuilder<int>(
          valueListenable: NotificationService.rev,
          builder: (_, __, ___) {
            final items = NotificationService.list();
            final unread = items.where((n) => !n.read).length;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
                  child: Row(children: [
                    Expanded(
                      child: Text(l.notificationsTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.subtitleBold.copyWith(
                              color: theme.colorScheme.onSurface)),
                    ),
                    if (unread > 0)
                      TextButton(
                        onPressed: () =>
                            NotificationService.markAllAsRead(),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text('Tout marquer lu',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.captionBold.copyWith(
                                color: theme.colorScheme.primary)),
                      ),
                  ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.notifications_off_outlined,
                                  size: 40,
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.3)),
                              const SizedBox(height: 12),
                              Text(l.notifEmptyTitle,
                                  style: AppTextStyles.body.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.7))),
                              const SizedBox(height: 4),
                              Text(l.notifEmptyHint,
                                  textAlign: TextAlign.center,
                                  style: AppTextStyles.caption.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.5))),
                            ],
                          ),
                        )
                      : ListView.separated(
                          controller: scrollCtrl,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: items.length,
                          separatorBuilder: (_, __) => Divider(
                              height: 1,
                              color: theme.colorScheme.outline
                                  .withValues(alpha: 0.15)),
                          itemBuilder: (_, i) {
                            final n = items[i];
                            final color = _colorFor(n.kind, theme);
                            return ListTile(
                              leading: Container(
                                width: 36, height: 36,
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                alignment: Alignment.center,
                                child: Icon(_iconFor(n.kind),
                                    size: 18, color: color),
                              ),
                              title: Row(children: [
                                Flexible(
                                  child: Text(n.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTextStyles.body.copyWith(
                                          fontWeight: n.read
                                              ? FontWeight.w500
                                              : FontWeight.w700,
                                          color: theme.colorScheme.onSurface)),
                                ),
                                // Badge canal pour les notifs orderNew issues
                                // d'une source non-pos (web / whatsapp).
                                if (n.kind == NotifKind.orderNew
                                    && n.source != null
                                    && n.source != 'pos') ...[
                                  const SizedBox(width: 6),
                                  OrderSourceBadge(source: n.source!),
                                ],
                              ]),
                              subtitle: Text(n.message,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.caption.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.7))),
                              trailing: Text(_formatTime(n.createdAt),
                                  style: AppTextStyles.micro.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.5))),
                              onTap: () {
                                NotificationService.markAsRead(n.id);
                                _handleNotifTap(context, n);
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Intitulé d'une famille du tiroir — « SERVICE », « GESTION », « ÉQUIPE ».
///
/// Onze entrées à plat se parcourent ; quatre blocs nommés se visent. Le filet
/// existait déjà entre les groupes, il ne disait simplement pas ce qu'il
/// séparait.
///
/// `micro` (10) et NON 9 : l'échelle canonique s'arrête à 10, et le palier 9 a
/// été retiré délibérément — `AppTextStyles.micro9` subsiste `@Deprecated`,
/// aliasé sur `micro`. Réintroduire un palier supprimé pour un intitulé de
/// section aurait défait cette décision en douce.
///
/// La couleur vient de `micro` elle-même (`textHint`) : c'est le ton atténué
/// demandé, et il suit déjà les huit palettes en clair comme en sombre.
class _NavSectionLabel extends StatelessWidget {
  final String text;
  final double indent;

  const _NavSectionLabel({required this.text, this.indent = 16});

  @override
  Widget build(BuildContext context) => Padding(
        // Plus d'air au-dessus qu'en dessous : l'intitulé appartient à ce qui
        // le suit, pas au filet qui le précède.
        padding: EdgeInsets.fromLTRB(indent, 10, indent, 4),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.micro.copyWith(
            letterSpacing: 1.1,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

/// « Essai · N jours restants », écrit comme on le lit.
///
/// Le dernier jour ne se compte pas : « 0 jour restant » se lit comme une
/// panne, alors que l'essai fonctionne encore jusqu'à ce soir. Et le singulier
/// est tenu — un décompte qui écrit « 1 jours » se fait relire deux fois.
String _trialLabel(int days) {
  if (days <= 0) return 'Essai · dernier jour';
  if (days == 1) return 'Essai · 1 jour restant';
  return 'Essai · $days jours restants';
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

    // ── L'ESSAI PORTE SON ÉCHÉANCE ──────────────────────────────────────
    //
    // La pastille disait « Essai » et rien d'autre : le propriétaire savait
    // qu'il était en essai, jamais combien de temps il lui restait.
    //
    // ⚠ `daysLeft` vaut ZÉRO quand `expiresAt` est nul. Un essai sans date en
    // base afficherait donc « 0 jour restant » — un mensonge alarmant sur un
    // compte qui fonctionne. On n'annonce l'échéance QUE si la date existe ;
    // sinon la pastille muette reste, et le sujet se traite ailleurs.
    //
    // La donnée est FIABLE HORS LIGNE : `expiresAt` vient de `get_user_plan`,
    // est sérialisée dans Hive par `AppDatabase._cachePlanToHive` et relue par
    // `subscription_provider` sans réseau. `daysLeft` se recalcule contre
    // `DateTime.now()` à chaque lecture — il décroît donc correctement même
    // après plusieurs jours de coupure, au lieu de rester figé.
    final trialLine = (plan.isTrial && plan.expiresAt != null)
        ? _trialLabel(plan.daysLeft)
        : null;
    // Ambre sous la semaine, bleu au-dessus : une alerte affichée dès le
    // premier jour d'un essai de quatorze n'alerte plus personne au
    // treizième. Même seuil que `expiresSoon`, qui gouverne déjà la pastille.
    final trialColor = plan.daysLeft <= 7 ? sem.warningText : sem.info;

    void open() => context.push(RouteNames.subscription);

    if (asListTile) {
      return ListTile(
        leading: Icon(Icons.workspace_premium_rounded,
            color: theme.colorScheme.onSurface.withValues(alpha:0.75)),
        title: Text(l.drawerSubscription),
        // La ligne REMPLACE la pastille, elle ne s'y ajoute pas : « Essai » en
        // pastille et « Essai · 9 jours restants » dessous diraient deux fois
        // la même chose, et la pastille dirait la moitié.
        subtitle: trialLine == null
            ? null
            : Text(trialLine,
                style: AppTextStyles.micro.copyWith(color: trialColor)),
        trailing: trialLine != null
            ? null
            : Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha:0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(badgeText,
              style: AppTextStyles.captionBold.copyWith(
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
      // Mêmes métriques que `_SidebarRow` / `_LogoutTile` — cf. commentaire
      // dans _LogoutTile : le footer doit peser exactement comme un item nav.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        child: Row(children: [
          Icon(Icons.workspace_premium_rounded,
              size: 16,
              color: theme.colorScheme.onSurface.withValues(alpha:0.75)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l.drawerSubscription,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodySm.copyWith(
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.85))),
                if (trialLine != null)
                  Text(trialLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.micro.copyWith(color: trialColor)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (trialLine == null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(badgeText,
                  style: AppTextStyles.micro.copyWith(
                      fontWeight: FontWeight.w700,
                      color: badgeColor)),
            ),
        ]),
      ),
    );
  }
}
