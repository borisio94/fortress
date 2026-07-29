import 'package:flutter/material.dart';
import '../../core/config/restaurant_mode.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/permisions/app_permissions.dart';
import '../../core/services/fixed_charge_service.dart';
import '../../core/services/ingredient_service.dart';
import '../../core/services/stock_item_service.dart';
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
  /// Restreint l'item à certains **secteurs de boutique** (`shops.sector`).
  /// `null` (défaut) = visible quel que soit le secteur — c'est le cas de
  /// tous les items historiques, donc aucun impact sur le mode boutique.
  ///
  /// Filtre distinct de [visibleIf] parce que ce dernier ne reçoit qu'un
  /// `AppPermissions`, qui ne porte aucune information sur la boutique.
  /// Élargir sa signature aurait touché les 20 items existants ; ce champ
  /// optionnel est additif.
  final Set<String>?                        sectorIn;
  /// Inverse de [sectorIn] : masque l'item dans ces secteurs. `null`
  /// (défaut) = visible partout. Sert à alléger le menu d'un restaurant des
  /// modules qui ne concernent que la vente e-commerce.
  final Set<String>?                        sectorNotIn;
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
  /// Groupe d'affichage dans la sidebar/drawer — les groupes sont séparés
  /// par un divider. 1 = principal · 2 = gestion · 3 = secondaire. Ignoré
  /// quand [footer] est vrai.
  final int                            group;
  /// Si vrai, l'item est rendu dans le FOOTER de la sidebar/drawer
  /// (ex: Paramètres), au-dessus de « Abonnement » + « Déconnexion ».
  final bool                           footer;

  const ShellNavItem({
    required this.icon,
    required this.iconSelected,
    required this.label,
    required this.route,
    required this.visibleIf,
    this.sectorIn,
    this.sectorNotIn,
    this.labelMobile,
    this.badge,
    this.primary = false,
    this.children,
    this.desktopHidden = false,
    this.mobileHidden  = false,
    this.group         = 1,
    this.footer        = false,
  });

  bool get hasChildren => children != null && children!.isNotEmpty;

  /// Sous-items visibles pour ce secteur.
  ///
  /// Les enfants portent leur propre [sectorNotIn] / [sectorIn] : « Menu »
  /// est un groupe dépliable (Produits · Emplacements · Incidents) en
  /// e-commerce, mais une entrée simple en restauration.
  List<ShellNavItem> childrenFor(String sector) =>
      (children ?? const <ShellNavItem>[])
          .where((c) => c.matchesSector(sector))
          .toList();

  /// True si l'item doit être rendu comme un GROUPE dépliable dans ce
  /// secteur. Un parent dont tous les enfants sont filtrés redevient une
  /// simple entrée cliquable — sans quoi on afficherait un chevron qui
  /// déplierait le vide.
  bool hasChildrenIn(String sector) => childrenFor(sector).isNotEmpty;

  /// True si l'item est visible pour ce secteur de boutique. Un item sans
  /// [sectorIn] ni [sectorNotIn] passe toujours.
  bool matchesSector(String sector) {
    if (sectorNotIn != null && sectorNotIn!.contains(sector)) return false;
    return sectorIn == null || sectorIn!.contains(sector);
  }
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

/// Compte les commandes WEB encore en attente (`source='web'` + `scheduled`)
/// pour cette boutique — badge sur l'item Caisse et le sous-item « Commandes
/// caisse » (sidebar desktop + drawer ; la bottom-nav mobile a son propre
/// compteur via newWebOrdersProvider).
int _webOrdersBadge(String shopId) {
  if (shopId.isEmpty) return 0;
  return HiveBoxes.ordersBox.values.where((m) {
    return m['shop_id'] == shopId
        && m['source'] == 'web'
        && m['status'] == 'scheduled'
        && (m['deleted_at'] == null || m['deleted_at'].toString().isEmpty);
  }).length;
}

/// Alertes des finances restaurant — pastille sur l'item « Finances » :
/// ingrédients + articles « stock » sous leur seuil, plus les charges fixes
/// à régler bientôt ou en retard.
int _restaurantFinanceBadge(String shopId) {
  if (shopId.isEmpty) return 0;
  var n = 0;
  for (final ing in IngredientService.forShop(shopId)) {
    if (ing.isLowStock) n++;
  }
  n += StockItemService.lowStock(shopId).length;
  n += FixedChargeService.dueSoon(shopId).length;
  return n;
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
  // ── Menu restaurant (carte des plats) ──────────────────────────────────
  // Placé JUSTE APRÈS le Tableau de bord (demande UX resto) : c'est l'écran
  // de travail principal du service. Route = /shop/$id/inventaire (la même
  // page RestaurantMenuPage), mais item DÉDIÉ au restaurant pour maîtriser
  // son ordre indépendamment de l'item « Inventaire » e-commerce, qui garde
  // sa place après la Caisse. Icône `inventory_2` (prouvée présente dans la
  // police bundlée) — mêmes glyphes que l'ancien item Menu.
  ShellNavItem(
    icon:         Icons.inventory_2_outlined,
    iconSelected: Icons.inventory_2_rounded,
    label:        (_) => 'Menu',
    route:        (id) => '/shop/$id/inventaire',
    visibleIf:    (p) => p.isShopAdmin && p.canViewProducts,
    sectorIn:     kRestaurantSectors,
    primary:      true,
  ),
  // ── Finances restaurant (PR-B) — hub Ingrédients / Activités / Stock ────
  // Réservé admin/owner. Pastille = alertes stock (ingrédients + articles).
  ShellNavItem(
    icon:         Icons.account_balance_wallet_outlined,
    iconSelected: Icons.account_balance_wallet_rounded,
    label:        (_) => 'Finances',
    route:        (id) => '/shop/$id/restaurant/finances',
    visibleIf:    (p) => p.isShopAdmin,
    sectorIn:     kRestaurantSectors,
    badge:        _restaurantFinanceBadge,
    primary:      true,
  ),
  ShellNavItem(
    icon:         Icons.shopping_cart_outlined,
    iconSelected: Icons.shopping_cart_rounded,
    label:        (l) => l.navCaisse,
    route:        (id) => '/shop/$id/caisse',
    visibleIf:    (p) => p.canAccessCaisse,
    // Restaurant : remplacé par « Commandes » (item dédié) — la vente au
    // comptoir passe par le plan de salle ou l'écran de commande.
    sectorNotIn:  kRestaurantSectors,
    primary:      true,
    badge:        _webOrdersBadge,
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
        badge:        _webOrdersBadge,
      ),
    ],
  ),
  // ── Module restaurant (PR-1) ───────────────────────────────────────────
  // Visible UNIQUEMENT si la boutique est un établissement de restauration
  // (`sectorIn`). En mode boutique, cet item n'existe pas — zéro impact.
  // L'onglet Caisse reste accessible en parallèle pour la vente au comptoir.
  //
  // Icône : `restaurant_rounded` sur les DEUX états. La variante `_outlined`
  // n'est utilisée nulle part dans le repo — or les glyphes Material récents
  // absents de la police bundlée s'affichent en carré vide (cf. commentaires
  // sur `contacts_*`, `send_outlined`, `account_balance_outlined` plus bas).
  ShellNavItem(
    icon:         Icons.restaurant_rounded,
    iconSelected: Icons.restaurant_rounded,
    label:        (_) => 'Service',
    labelMobile:  (_) => 'Salle',
    // L'écran de service EST le plan de salle, augmenté du volet de prise de
    // commande : le caissier n'a plus à naviguer entre les deux.
    route:        (id) => '/shop/$id/restaurant/service',
    // Les serveurs (rôle 'user') doivent pouvoir ouvrir le plan de salle :
    // on s'aligne sur la permission caisse plutôt que sur isShopAdmin.
    visibleIf:    (p) => p.canAccessCaisse,
    sectorIn:     kRestaurantSectors,
    primary:      true,
  ),
  // « Commandes » — équivalent restaurant de l'item Caisse, qui pointe
  // directement sur la liste des commandes plutôt que sur l'écran de vente.
  //
  // Cuisine (`/restaurant/cuisine`) et À emporter (`/restaurant/takeaway`)
  // ne figurent PLUS dans la navigation : le menu suit strictement la
  // maquette de référence. Les deux écrans existent toujours et restent
  // atteignables par leur route directe — voir `RouteNames.restaurantKitchen`
  // et `restaurantTakeaway`. Leurs compteurs de pastille ont été SUPPRIMÉS
  // avec les items : les réécrire fera 8 lignes le jour où ils reviennent,
  // moins coûteux que du code mort qu'on n'ose plus toucher.
  ShellNavItem(
    icon:         Icons.receipt_long_outlined,
    iconSelected: Icons.receipt_long_rounded,
    label:        (_) => 'Commandes',
    route:        (id) => '/shop/$id/caisse/orders',
    visibleIf:    (p) => p.canAccessCaisse,
    sectorIn:     kRestaurantSectors,
    badge:        _webOrdersBadge,
    primary:      true,
  ),
  ShellNavItem(
    icon:         Icons.inventory_2_outlined,
    iconSelected: Icons.inventory_2_rounded,
    label:        (l) => l.navInventory,
    labelMobile:  (l) => l.navStock,
    route:        (id) => '/shop/$id/inventaire',
    // Inventaire réservé à admin + owner (cf. demande UX). Les employés
    // (rôle 'user') ne voient pas l'item dans le drawer.
    visibleIf:    (p) => p.isShopAdmin && p.canViewProducts,
    // Restaurant : remplacé par l'item « Menu » dédié placé après le
    // Tableau de bord (même route /inventaire). En restauration cet item
    // e-commerce n'apparaît donc plus.
    sectorNotIn:  kRestaurantSectors,
    badge:        _inventoryIncidentsBadge,
    primary:      true,
    children: [
      ShellNavItem(
        icon:         Icons.inventory_2_outlined,
        iconSelected: Icons.inventory_2_rounded,
        label:        (l) => l.navInvProduits,
        route:        (id) => '/shop/$id/inventaire',
        visibleIf:    (p) => p.isShopAdmin && p.canViewProducts,
        sectorNotIn:  kRestaurantSectors,
      ),
      ShellNavItem(
        icon:         Icons.warehouse_outlined,
        iconSelected: Icons.warehouse_rounded,
        label:        (l) => l.navInvEmplacements,
        route:        (id) => '/shop/$id/parametres/locations',
        visibleIf:    (p) => p.isShopAdmin && p.canViewProducts,
        sectorNotIn:  kRestaurantSectors,
      ),
      ShellNavItem(
        icon:         Icons.warning_amber_outlined,
        iconSelected: Icons.warning_amber_rounded,
        label:        (l) => l.navInvIncidents,
        route:        (id) => '/shop/$id/inventaire/incidents',
        visibleIf:    (p) => p.isShopAdmin && p.canViewProducts,
        badge:        _inventoryIncidentsBadge,
        sectorNotIn:  kRestaurantSectors,
      ),
    ],
  ),
  // CRM — groupe regroupant la relation client. Clients en sous-item
  // (extensible : segments, relances, etc. à venir).
  ShellNavItem(
    // person_*_rounded : déjà utilisées (ancien item Clients) → présentes
    // dans la police MaterialIcons bundlée. contacts_* (récente) ne
    // s'affichait pas (codepoint absent du .otf embarqué).
    icon:         Icons.people_outline_rounded,
    iconSelected: Icons.people_rounded,
    label:        (_) => 'CRM',
    route:        (id) => '/shop/$id/crm',
    visibleIf:    (p) => p.canViewClients,
    // Menu restaurant allégé : centré vente / commande / facturation.
    sectorNotIn:  kRestaurantSectors,
    primary:      true,
    children: [
      ShellNavItem(
        icon:         Icons.person_outline_rounded,
        iconSelected: Icons.person_rounded,
        label:        (l) => l.navClients,
        route:        (id) => '/shop/$id/crm',
        visibleIf:    (p) => p.canViewClients,
      ),
      // Membres — page Membres pure (sans with_overview → pas d'onglet
      // Boutique ; l'onglet Copier a été retiré globalement → un seul
      // contenu affiché, sans TabBar). people_rounded : prouvée présente
      // (parent CRM sélectionné l'utilise), supervisor_account ne
      // s'affichait pas (codepoint absent du .otf bundlé).
      ShellNavItem(
        icon:         Icons.people_rounded,
        iconSelected: Icons.people_rounded,
        label:        (_) => 'Membres',
        route:        (id) => '/shop/$id/parametres/shop?tab=members',
        visibleIf:    (p) => p.canManageMembers,
      ),
    ],
  ),
  // Finances — groupe : chaque sous-item ouvre la page sur l'onglet
  // correspondant via `?tab=`. Page plus aérée (plus de TabBar à scanner).
  ShellNavItem(
    icon:         Icons.account_balance_wallet_outlined,
    iconSelected: Icons.account_balance_wallet_rounded,
    label:        (l) => l.navFinances,
    route:        (id) => '/shop/$id/finances',
    visibleIf:    (p) => p.canViewFinances,
    sectorNotIn:  kRestaurantSectors,
    group:        2,
    children: [
      ShellNavItem(
        icon:         Icons.trending_up_rounded,
        iconSelected: Icons.trending_up_rounded,
        label:        (_) => 'Chiffre d\'affaires',
        route:        (id) => '/shop/$id/finances?tab=revenus',
        visibleIf:    (p) => p.canViewFinances,
      ),
      ShellNavItem(
        icon:         Icons.account_balance_wallet_outlined,
        iconSelected: Icons.account_balance_wallet_rounded,
        label:        (l) => l.financesTabDepenses,
        route:        (id) => '/shop/$id/finances?tab=depenses',
        visibleIf:    (p) => p.canViewFinances,
      ),
      ShellNavItem(
        icon:         Icons.trending_down_rounded,
        iconSelected: Icons.trending_down_rounded,
        label:        (l) => l.financesTabPertes,
        route:        (id) => '/shop/$id/finances?tab=pertes',
        visibleIf:    (p) => p.canViewFinances,
      ),
      ShellNavItem(
        // account_balance_rounded : déjà utilisée (ExpenseCategory.taxes),
        // présente dans la police. Même icône pour les 2 états car
        // account_balance_outlined (variante récente) ne s'affiche pas.
        icon:         Icons.account_balance_rounded,
        iconSelected: Icons.account_balance_rounded,
        label:        (_) => 'Bénéfice net',
        route:        (id) => '/shop/$id/finances?tab=bilan',
        visibleIf:    (p) => p.canViewFinances,
      ),
    ],
  ),
  // WhatsApp — groupe : modèles de messages + campagnes marketing.
  // Déplacés depuis Paramètres pour un accès direct (owner uniquement).
  ShellNavItem(
    // send_rounded pour les 2 états : send_outlined (variante récente)
    // est absente de la police bundlée → invisible en état inactif (d'où
    // l'icône qui n'apparaissait que sélectionnée). send_rounded est
    // prouvée (bouton « Envoyer facture WhatsApp »). Distincte de
    // Messagerie (chat_bubble) pour lever la confusion.
    icon:         Icons.send_rounded,
    iconSelected: Icons.send_rounded,
    label:        (_) => 'WhatsApp et marketing',
    sectorNotIn:  kRestaurantSectors,
    route:        (id) => '/shop/$id/parametres/whatsapp-templates',
    visibleIf:    (p) => p.isOwner,
    group:        2,
    children: [
      ShellNavItem(
        icon:         Icons.chat_bubble_outline_rounded,
        iconSelected: Icons.chat_bubble_rounded,
        label:        (l) => l.waTemplatesTitle,
        route:        (id) => '/shop/$id/parametres/whatsapp-templates',
        visibleIf:    (p) => p.isOwner,
      ),
      ShellNavItem(
        // campaign_rounded : déjà utilisée (ExpenseCategory.marketing).
        icon:         Icons.campaign_rounded,
        iconSelected: Icons.campaign_rounded,
        label:        (_) => 'Campagnes marketing',
        route:        (id) => '/shop/$id/campaigns',
        visibleIf:    (p) => p.isOwner,
      ),
    ],
  ),
  // (Employés & permissions retiré : Membres est désormais un sous-item
  //  de CRM ; le reste de la config boutique reste dans Paramètres ›
  //  Paramètres de boutique.)
  // Item « Commandes » supprimé du drawer (round 14) — les sous-pages
  // Fournisseurs / Réceptions / Retours restent accessibles via les
  // actions inline produits ou directement par leurs routes.
  // (Item « Partenaires » retiré du drawer : les dépôts partenaires sont
  //  déjà listés dans Inventaire › Emplacements › Dépôts partenaires, avec
  //  leur solde affiché et un clic vers le hub partenaire unifié. La page
  //  /parametres/partner-accounts reste accessible par deeplink.)
  ShellNavItem(
    icon:         Icons.history_outlined,
    iconSelected: Icons.history_rounded,
    label:        (l) => l.navHistorique,
    route:        (id) => '/shop/$id/historique',
    visibleIf:    (p) => p.canViewActivity,
    sectorNotIn:  kRestaurantSectors,
    group:        3,
  ),
  // Messagerie — visible pour tout membre (vendeurs inclus) afin qu'ils
  // puissent ouvrir un ticket. La page filtre côté UI selon hiérarchie.
  ShellNavItem(
    icon:         Icons.chat_bubble_outline_rounded,
    iconSelected: Icons.chat_bubble_rounded,
    label:        (_) => 'Messagerie',
    route:        (id) => '/shop/$id/tickets',
    visibleIf:    (p) => p.isMember,
    group:        3,
  ),
  // ── Deux notions distinctes, deux entrées distinctes ────────────────────
  //
  // Elles se ressemblent et n'ont rien à voir. Les confondre coûte cher : on
  // cherche la paie d'une serveuse dans la page des comptes, ou on croit avoir
  // « supprimé un employé » alors qu'on a révoqué un accès.
  //
  //   * « Personnel » = les gens qui travaillent au restaurant (serveuses,
  //     cuisiniers, plongeurs). Ils n'ont PAS de compte : ils badgent avec un
  //     code à 4 chiffres. C'est là que vivent salaires, heures et avances.
  //   * « Accès à l'app » = les comptes qui se connectent à Fortress, avec
  //     leurs permissions. Beaucoup moins nombreux, et rarement touchés.
  ShellNavItem(
    icon:         Icons.badge_outlined,
    iconSelected: Icons.badge_rounded,
    label:        (_) => 'Personnel',
    route:        (id) => '/shop/$id/restaurant/personnel',
    // Salaires et avances : même exigence que la route elle-même
    // (cf. `_restaurantGuard(adminOnly: true)`).
    visibleIf:    (p) => p.isShopAdmin,
    sectorIn:     kRestaurantSectors,
    group:        3,
  ),
  ShellNavItem(
    icon:         Icons.manage_accounts_outlined,
    iconSelected: Icons.manage_accounts_rounded,
    label:        (_) => 'Accès à l\'app',
    route:        (id) => '/shop/$id/employees',
    visibleIf:    (p) => p.canManageMembers,
    sectorIn:     kRestaurantSectors,
    group:        3,
  ),
  // Membres retiré du drawer (mobile + desktop) — accessible uniquement
  // depuis Paramètres › Paramètres boutique pour éviter le doublon.
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
    footer:       true,
  ),
  ShellNavItem(
    icon:         Icons.hub_outlined,
    iconSelected: Icons.hub_rounded,
    label:        (l) => l.navHub,
    // Hub central est hors ShellRoute : la route est fixe (/hub) et
    // indépendante du shopId courant. Réservée aux owners qui gèrent
    // EFFECTIVEMENT plusieurs boutiques : masqué tant que l'owner n'a
    // qu'une seule boutique (le Hub n'a aucun intérêt en mono-boutique).
    route:        (_) => '/hub',
    visibleIf:    (p) => p.isOwner && p.isMultiStore,
    group:        3,
  ),
];

/// Items visibles dans le bottom nav principal (4 onglets fixes).
///
/// [sector] = `shops.sector` de la boutique courante ; filtre les items
/// restreints par `sectorIn`. Défaut `''` → seuls les items sans restriction
/// passent, ce qui est le comportement historique pour tous les appelants
/// qui ne fournissent pas le secteur.
List<ShellNavItem> shellPrimaryItems(AppPermissions perms,
        {String sector = ''}) =>
    kShellNavItems
        .where((i) => i.primary && i.visibleIf(perms) && i.matchesSector(sector))
        .toList();

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
List<ShellNavItem> shellMobileDrawerItems(AppPermissions perms,
        {String sector = ''}) =>
    kShellNavItems
        .where((i) =>
            !i.mobileHidden && i.visibleIf(perms) && i.matchesSector(sector))
        .toList();

/// Tous les items visibles, à plat — pour le sidebar desktop. Filtre les
/// items `desktopHidden: true` (entrées prévues pour le drawer Plus mobile
/// uniquement, dont une représentation alternative existe déjà dans le
/// sidebar via les `children` d'un autre item).
List<ShellNavItem> shellAllItems(AppPermissions perms, {String sector = ''}) =>
    kShellNavItems
        .where((i) =>
            i.visibleIf(perms) && !i.desktopHidden && i.matchesSector(sector))
        .toList();

/// Partitionne une liste d'items nav (déjà filtrée par perms/hidden) en
/// GROUPES non vides triés par `group` — pour insérer un divider entre
/// chaque groupe dans la sidebar/drawer. Les items `footer` sont exclus.
List<List<ShellNavItem>> navGroups(List<ShellNavItem> items) {
  final byGroup = <int, List<ShellNavItem>>{};
  for (final i in items) {
    if (i.footer) continue;
    (byGroup[i.group] ??= <ShellNavItem>[]).add(i);
  }
  final keys = byGroup.keys.toList()..sort();
  return [for (final k in keys) byGroup[k]!];
}

/// Items à rendre dans le FOOTER de la sidebar/drawer (ex: Paramètres),
/// extraits d'une liste déjà filtrée par perms.
List<ShellNavItem> navFooterItems(List<ShellNavItem> items) =>
    items.where((i) => i.footer).toList();

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
///
/// [sector] filtre les items qui ne concernent pas la boutique courante.
/// Indispensable quand deux items partagent une route : « Commandes »
/// (restaurant) et le sous-item « Commandes caisse » (e-commerce) pointent
/// tous deux sur `/caisse/orders`. Sans ce filtre on renvoyait l'index de
/// Caisse — un item que la sidebar restaurant n'affiche pas — et plus rien
/// n'était surligné.
int shellSelectedIndex(String currentLocation, String shopId,
    {String? tabQuery, String sector = ''}) {
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
    if (!item.matchesSector(sector)) continue;
    candidates.add((i, item.route(shopId)));
    for (final child in item.childrenFor(sector)) {
      candidates.add((i, child.route(shopId)));
    }
  }
  candidates.sort((a, b) => b.$2.length.compareTo(a.$2.length));
  for (final (idx, route) in candidates) {
    if (_routeMatches(route, currentLocation, tabQuery)) {
      return idx;
    }
  }
  return -1;
}

/// True si la route nav [route] correspond à la localisation courante.
///
/// Une route peut porter un suffixe `?tab=X` (ex. Membres
/// `/parametres/shop?tab=members`, sous-items Finances `/finances?tab=…`).
/// `GoRouterState.matchedLocation` exclut la query string, donc on compare
/// le **chemin** à [loc] et, si la route exige un onglet, on vérifie en
/// plus que [tabQuery] (lu depuis `uri.queryParameters['tab']`) l'égale.
/// Sans ce check, `/parametres/shop?tab=members` ne matchait jamais et
/// l'item Membres + son parent CRM perdaient le focus à la sélection.
bool _routeMatches(String route, String loc, String? tabQuery) {
  final uri     = Uri.parse(route);
  final path    = uri.path;
  final wantTab = uri.queryParameters['tab'];
  if (wantTab != null) {
    return loc == path && tabQuery == wantTab;
  }
  return loc == path || loc.startsWith('$path/');
}

/// Retourne l'index du sous-item actif dans `parent.children`, ou `-1` si
/// aucun n'est actif. Utilisé par la sidebar desktop pour highlighter le
/// bon enfant et auto-déplier le parent quand on est sur une route enfant.
int activeChildIndex(ShellNavItem parent, String currentLocation, String shopId,
    {String? tabQuery}) {
  if (parent.children == null) return -1;
  final indexed = List.generate(parent.children!.length, (i) => i);
  indexed.sort((a, b) => parent.children![b].route(shopId).length
      .compareTo(parent.children![a].route(shopId).length));
  for (final i in indexed) {
    final route = parent.children![i].route(shopId);
    if (_routeMatches(route, currentLocation, tabQuery)) {
      return i;
    }
  }
  return -1;
}
