import 'package:flutter/material.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/permisions/app_permissions.dart';
import '../../core/storage/hive_boxes.dart';

/// Description d'un item de navigation shell.
///
/// Source unique consommée par :
///   - le bottom navigation bar mobile (4 premiers items + bouton « Plus »)
///   - le drawer « Plus » mobile (items overflow)
///   - le sidebar fixe desktop (items à plat ou repliables)
///
/// Tous les libellés viennent d'`AppLocalizations` ; aucun texte hardcodé.
/// Les routes sont calculées à partir du `shopId` courant. La visibilité
/// est filtrée via [visibleIf] qui consomme `AppPermissions(shopId)`.
///
/// Quand [children] est non-vide, l'item est un **groupe repliable** sur
/// le sidebar desktop : tap sur le parent → toggle expansion (pas de nav).
/// Tap sur un enfant → nav vers la route de l'enfant. Sur mobile, [children]
/// est ignoré — l'item garde son comportement plat (route directe).
class ShellNavItem {
  final IconData                       icon;
  final IconData                       iconSelected;
  final String  Function(AppLocalizations)  label;
  /// Libellé court alternatif utilisé uniquement par le bottom nav mobile.
  /// Si `null`, [label] est utilisé partout.
  final String  Function(AppLocalizations)? labelMobile;
  final String  Function(String shopId)     route;
  final bool    Function(AppPermissions)    visibleIf;
  /// Compteur affiché en pastille rouge sur l'icône (ex: incidents
  /// pending sur Inventaire). Renvoyer 0 pour masquer. `null` = pas de
  /// badge sur cet item.
  final int Function(String shopId)?   badge;
  /// True si l'item appartient à la rangée principale du bottom nav mobile
  /// (Dashboard, Caisse, Inventaire, Clients). Les autres vont dans le
  /// drawer « Plus ». Sur desktop, tous les items s'affichent dans le sidebar.
  final bool                           primary;
  /// Sous-éléments dépliables (sidebar desktop uniquement). Quand non-vide,
  /// l'item devient un groupe : tap parent = toggle, tap enfant = nav.
  final List<ShellNavItem>?            children;
  /// Si vrai, l'item est masqué du sidebar desktop. Permet de proposer une
  /// entrée standalone dans le drawer Plus mobile pour une fonctionnalité
  /// déjà accessible via les enfants d'un parent sur desktop (sinon on
  /// aurait un doublon visible). Cas d'usage : « Commandes caisse » est
  /// un enfant de Caisse sur desktop, mais doit aussi être atteignable
  /// depuis le drawer Plus mobile.
  final bool                           desktopHidden;
  /// Symétrique de [desktopHidden] : si vrai, l'item est masqué du
  /// drawer Plus mobile. Cas d'usage : Hub central est exposé dans la
  /// sidebar desktop (multi-boutiques pour owner) mais inutile sur le
  /// bottom nav mobile (un user mobile gère typiquement 1 boutique).
  final bool                           mobileHidden;

  const ShellNavItem({
    required this.icon,
    required this.iconSelected,
    required this.label,
    required this.route,
    required this.visibleIf,
    this.labelMobile,
    this.badge,
    this.primary = false,
    this.children,
    this.desktopHidden = false,
    this.mobileHidden  = false,
  });

  bool get hasChildren => children != null && children!.isNotEmpty;
}

/// Compte les incidents inventaire en attente (`pending` ou `in_progress`)
/// pour cette boutique — affiché en pastille sur l'item Inventaire.
int _inventoryIncidentsBadge(String shopId) {
  if (shopId.isEmpty) return 0;
  return HiveBoxes.incidentsBox.values.where((m) {
    return m['shop_id'] == shopId
        && (m['status'] == 'pending' || m['status'] == 'in_progress');
  }).length;
}

/// Tous les items de navigation, dans l'ordre d'affichage.
///
/// Les 4 premiers (`primary: true`) alimentent le bottom nav mobile en plus
/// du bouton « Plus » qui ouvre un drawer affichant les items overflow.
/// Sur desktop, le sidebar les affiche tous, repliables si `children` est
/// renseigné.
final List<ShellNavItem> kShellNavItems = [
  ShellNavItem(
    icon:         Icons.grid_view_outlined,
    iconSelected: Icons.grid_view_rounded,
    label:        (l) => l.navDashboard,
    labelMobile:  (l) => l.navAccueil,
    route:        (id) => '/shop/$id/dashboard',
    // Dashboard est l'écran d'atterrissage par défaut — toujours visible
    // pour tout membre actif. Un check de permission stricte casserait
    // l'auto-redirection après login pour les rôles minimaux.
    visibleIf:    (p) => true,
    primary:      true,
  ),
  ShellNavItem(
    icon:         Icons.shopping_cart_outlined,
    iconSelected: Icons.shopping_cart_rounded,
    label:        (l) => l.navCaisse,
    route:        (id) => '/shop/$id/caisse',
    visibleIf:    (p) => p.canAccessCaisse,
    primary:      true,
    children: [
      ShellNavItem(
        icon:         Icons.point_of_sale_outlined,
        iconSelected: Icons.point_of_sale_rounded,
        label:        (l) => l.navCaisseVente,
        route:        (id) => '/shop/$id/caisse',
        visibleIf:    (p) => p.canAccessCaisse,
      ),
      ShellNavItem(
        icon:         Icons.receipt_long_outlined,
        iconSelected: Icons.receipt_long_rounded,
        label:        (l) => l.navCaisseCommandes,
        route:        (id) => '/shop/$id/caisse/orders',
        visibleIf:    (p) => p.canAccessCaisse,
      ),
    ],
  ),
  ShellNavItem(
    icon:         Icons.inventory_2_outlined,
    iconSelected: Icons.inventory_2_rounded,
    label:        (l) => l.navInventory,
    labelMobile:  (l) => l.navStock,
    route:        (id) => '/shop/$id/inventaire',
    visibleIf:    (p) => p.canViewProducts,
    badge:        _inventoryIncidentsBadge,
    primary:      true,
    children: [
      ShellNavItem(
        icon:         Icons.inventory_2_outlined,
        iconSelected: Icons.inventory_2_rounded,
        label:        (l) => l.navInvProduits,
        route:        (id) => '/shop/$id/inventaire',
        visibleIf:    (p) => p.canViewProducts,
      ),
      ShellNavItem(
        icon:         Icons.warehouse_outlined,
        iconSelected: Icons.warehouse_rounded,
        label:        (l) => l.navInvEmplacements,
        route:        (id) => '/shop/$id/parametres/locations',
        visibleIf:    (p) => p.canViewProducts,
      ),
      // Transferts + Mouvements supprimés du menu (round 13) — accessibles
      // depuis les actions inline produit (transfert) et la page emplacements
      // (historique mouvements). Évite la confusion entre "Mouvement" et
      // "Historique".
      ShellNavItem(
        icon:         Icons.warning_amber_outlined,
        iconSelected: Icons.warning_amber_rounded,
        label:        (l) => l.navInvIncidents,
        route:        (id) => '/shop/$id/inventaire/incidents',
        visibleIf:    (p) => p.canViewProducts,
        badge:        _inventoryIncidentsBadge,
      ),
    ],
  ),
  ShellNavItem(
    icon:         Icons.person_outline_rounded,
    iconSelected: Icons.person_rounded,
    label:        (l) => l.navClients,
    route:        (id) => '/shop/$id/crm',
    visibleIf:    (p) => p.canViewClients,
    primary:      true,
  ),
  ShellNavItem(
    icon:         Icons.account_balance_wallet_outlined,
    iconSelected: Icons.account_balance_wallet_rounded,
    label:        (l) => l.navFinances,
    route:        (id) => '/shop/$id/finances',
    visibleIf:    (p) => p.canViewFinances,
  ),
  // Item « Commandes » supprimé du drawer (round 14) — les sous-pages
  // Fournisseurs / Réceptions / Retours restent accessibles via les
  // actions inline produits ou directement par leurs routes.
  ShellNavItem(
    icon:         Icons.history_outlined,
    iconSelected: Icons.history_rounded,
    label:        (l) => l.navHistorique,
    route:        (id) => '/shop/$id/historique',
    visibleIf:    (p) => p.canViewActivity,
  ),
  // Membres — desktop uniquement. Sur mobile, l'accès passe par
  // Paramètres › Gestion boutique pour alléger le drawer.
  ShellNavItem(
    icon:         Icons.group_outlined,
    iconSelected: Icons.group_rounded,
    label:        (l) => l.navMembers,
    route:        (id) => '/shop/$id/parametres/users',
    visibleIf:    (p) => p.canManageMembers,
    mobileHidden: true,
  ),
  ShellNavItem(
    icon:         Icons.settings_outlined,
    iconSelected: Icons.settings_rounded,
    label:        (l) => l.navSettings,
    // Leaf direct vers la page Paramètres — toute l'arborescence
    // (Thème/Langue/Notifications/Sécurité) est désormais organisée à
    // l'intérieur de la page parametres_page elle-même via _Section /
    // _Tile. Plus de sous-menus expandable dans la nav.
    route:        (id) => '/shop/$id/parametres',
    // Tout membre actif peut au minimum consulter son profil et changer
    // la langue depuis Paramètres ; le filtrage fin se fait dans la page.
    visibleIf:    (p) => true,
  ),
  ShellNavItem(
    icon:         Icons.hub_outlined,
    iconSelected: Icons.hub_rounded,
    label:        (l) => l.navHub,
    // Hub central est hors ShellRoute : la route est fixe (/hub) et
    // indépendante du shopId courant. Réservée aux owners qui gèrent
    // potentiellement plusieurs boutiques. `mobileHidden: true` car un
    // user mobile gère typiquement une seule boutique — Hub reste
    // accessible via la sidebar desktop.
    route:        (_) => '/hub',
    visibleIf:    (p) => p.isOwner,
    mobileHidden: true,
  ),
];

/// Items visibles dans le bottom nav principal (4 onglets fixes).
List<ShellNavItem> shellPrimaryItems(AppPermissions perms) =>
    kShellNavItems.where((i) => i.primary && i.visibleIf(perms)).toList();

/// Items visibles dans le drawer « Plus » du bottom nav mobile. Filtre
/// les items `mobileHidden: true` (présents seulement sur la sidebar
/// desktop, ex: Hub central).
///
/// **Obsolète depuis round 9** : la bottom nav mobile a été remplacée par
/// un drawer latéral complet (cf. [shellMobileDrawerItems]). Conservé
/// pour rétrocompat si jamais le bottom nav revient.
List<ShellNavItem> shellOverflowItems(AppPermissions perms) =>
    kShellNavItems
        .where((i) => !i.primary && !i.mobileHidden && i.visibleIf(perms))
        .toList();

/// Items visibles dans le drawer latéral mobile — TOUS les items
/// (primary + overflow + desktopHidden), filtrés par `mobileHidden`
/// et `visibleIf(perms)`. Ordre = ordre de déclaration de
/// [kShellNavItems]. Utilisé par `_MobileDrawer` qui remplace la
/// bottom nav.
List<ShellNavItem> shellMobileDrawerItems(AppPermissions perms) =>
    kShellNavItems
        .where((i) => !i.mobileHidden && i.visibleIf(perms))
        .toList();

/// Tous les items visibles, à plat — pour le sidebar desktop. Filtre les
/// items `desktopHidden: true` (entrées prévues pour le drawer Plus mobile
/// uniquement, dont une représentation alternative existe déjà dans le
/// sidebar via les `children` d'un autre item).
List<ShellNavItem> shellAllItems(AppPermissions perms) =>
    kShellNavItems.where((i) => i.visibleIf(perms) && !i.desktopHidden).toList();

/// Index dans [kShellNavItems] de l'item dont la route correspond à
/// [currentLocation], ou `-1` si la route active n'est pas un item shell
/// (ex: page détail produit, payment, etc.).
///
/// Inclut les routes des sous-items : si la location courante matche un
/// enfant, l'index retourné est celui de son **parent** (pour highlight).
///
/// Les routes sont testées par longueur décroissante pour que
/// `/shop/$id/inventaire/incidents` matche le sous-item Incidents
/// (route plus spécifique) plutôt que Inventaire (préfixe).
int shellSelectedIndex(String currentLocation, String shopId) {
  // (parentIndex, route) — inclut routes parents ET routes enfants.
  // Les items `desktopHidden` sont ignorés ici : ce sont des entrées
  // alternatives (drawer Plus mobile), pas le propriétaire canonique de
  // la route. Sans ce skip, `/caisse/orders` pourrait matcher l'entrée
  // mobile-only au lieu du parent Caisse, et l'onglet Caisse ne serait
  // plus highlight dans le bottom nav quand on consulte les commandes.
  final candidates = <(int, String)>[];
  for (var i = 0; i < kShellNavItems.length; i++) {
    final item = kShellNavItems[i];
    if (item.desktopHidden) continue;
    candidates.add((i, item.route(shopId)));
    if (item.children != null) {
      for (final child in item.children!) {
        candidates.add((i, child.route(shopId)));
      }
    }
  }
  candidates.sort((a, b) => b.$2.length.compareTo(a.$2.length));
  for (final (idx, route) in candidates) {
    if (currentLocation == route || currentLocation.startsWith('$route/')) {
      return idx;
    }
  }
  return -1;
}

/// Retourne l'index du sous-item actif dans `parent.children`, ou `-1` si
/// aucun n'est actif. Utilisé par la sidebar desktop pour highlighter le
/// bon enfant et auto-déplier le parent quand on est sur une route enfant.
int activeChildIndex(ShellNavItem parent, String currentLocation, String shopId) {
  if (parent.children == null) return -1;
  final indexed = List.generate(parent.children!.length, (i) => i);
  indexed.sort((a, b) => parent.children![b].route(shopId).length
      .compareTo(parent.children![a].route(shopId).length));
  for (final i in indexed) {
    final route = parent.children![i].route(shopId);
    if (currentLocation == route || currentLocation.startsWith('$route/')) {
      return i;
    }
  }
  return -1;
}
