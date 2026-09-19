import '../services/notification_service.dart';
import '../storage/local_storage_service.dart';

/// Module Restaurant — détection du mode d'après le **secteur** de la boutique.
///
/// Choix d'architecture : on ne crée PAS de colonne `shop_type` dédiée. Le
/// champ `shops.sector` existe depuis l'origine et porte déjà la valeur
/// `'restaurant'` ; on se contente d'étendre son jeu de valeurs applicatif
/// avec `'fastfood'` et `'mixed'`. Une seule source de vérité → impossible
/// d'avoir un `sector = 'restaurant'` qui contredirait un `shop_type`.
///
/// Le secteur est choisi à la CRÉATION (cf. [kCreationSectors]) et n'est
/// plus modifiable ensuite — ni depuis les Paramètres, ni depuis l'édition
/// de boutique, ni via `AppDatabase.updateShop` d'où le champ a été retiré.

/// Secteurs qui activent le module restaurant (plan de salle, cuisine…).
const Set<String> kRestaurantSectors = {'restaurant', 'fastfood', 'mixed'};

/// Type d'établissement proposé dans Paramètres. `key` == `shops.sector`.
///
/// `'boutique'` n'existe pas en base : la valeur historique équivalente est
/// `'retail'`, conservée telle quelle pour ne pas réécrire les boutiques
/// existantes. Les secteurs legacy non listés ici (`supermarche`,
/// `pharmacie`, `autre`) restent valides et sont affichés tels quels — le
/// sélecteur ne les propose simplement pas.
class EstablishmentType {
  final String key;
  final String label;
  final String description;

  const EstablishmentType(this.key, this.label, this.description);
}

const List<EstablishmentType> kEstablishmentTypes = [
  EstablishmentType('retail', 'Boutique',
      'Vente de produits — mode standard'),
  EstablishmentType('ecommerce', 'E-commerce',
      'Commandes en ligne et livraison'),
  EstablishmentType('restaurant', 'Restaurant / Café',
      'Service à table, plan de salle et cuisine'),
  EstablishmentType('fastfood', 'Fast-food / Street food',
      'Service rapide, commandes à emporter'),
  EstablishmentType('mixed', 'Les deux',
      'Boutique et restauration dans le même établissement'),
];

/// Types d'établissement proposés à la CRÉATION d'une boutique.
///
/// Le secteur est **définitif** : il détermine toute l'ergonomie de l'app
/// (caisse e-commerce ou service en salle) et n'est plus modifiable ensuite.
/// Basculer une boutique en exploitation d'un mode à l'autre laisserait des
/// données incohérentes — commandes rattachées à des tables sur une boutique
/// devenue e-commerce, plan de salle orphelin, historique inexploitable.
///
/// `mixed` est volontairement ABSENT : mélanger boutique et restauration
/// dans un même établissement produirait exactement l'UI hybride qu'on veut
/// éviter. Les boutiques legacy qui le portent déjà restent fonctionnelles
/// (cf. [kRestaurantSectors]), mais on n'en crée plus.
///
/// `retail`, `supermarche`, `pharmacie`, `autre` restent des valeurs valides
/// en base pour le parc existant, mais ne sont plus proposées.
const List<EstablishmentType> kCreationSectors = [
  EstablishmentType('ecommerce', 'E-commerce',
      'Vente en ligne, commandes et livraison'),
  EstablishmentType('restaurant', 'Restaurant / Café',
      'Service à table, plan de salle et cuisine'),
  EstablishmentType('fastfood', 'Fast-food / Street food',
      'Service rapide, commandes à emporter'),
];

/// Secteur par défaut d'une nouvelle boutique.
const String kDefaultSector = 'ecommerce';

/// Libellé lisible d'un secteur, y compris pour les valeurs legacy absentes
/// de [kEstablishmentTypes]. Ne renvoie jamais `null` — au pire le brut.
String establishmentLabel(String sector) {
  for (final t in kEstablishmentTypes) {
    if (t.key == sector) return t.label;
  }
  const legacy = <String, String>{
    'supermarche': 'Supermarché',
    'pharmacie'  : 'Pharmacie',
    'autre'      : 'Autre',
  };
  return legacy[sector] ?? sector;
}

/// True si ce secteur active le module restaurant.
bool isRestaurantSector(String? sector) =>
    sector != null && kRestaurantSectors.contains(sector);

/// Secteur de la boutique [shopId], lu depuis Hive (offline-first).
///
/// Lecture DÉTERMINISTE par id plutôt que via `currentShopProvider` : ce
/// dernier peut être `null` ou pointer une autre boutique pendant une
/// transition de route, ce qui ferait clignoter les onglets restaurant.
/// Même précaution que `_openCart` dans `adaptive_scaffold.dart`.
String shopSector(String shopId) {
  if (shopId.isEmpty) return '';
  return LocalStorageService.getShop(shopId)?.sector ?? '';
}

/// True si la boutique [shopId] est un établissement de restauration.
bool isRestaurantShop(String shopId) => isRestaurantSector(shopSector(shopId));

/// Route d'atterrissage par défaut d'une boutique.
///
/// Pour un RESTAURANT, c'est le Menu (carte des plats, route `/inventaire`) —
/// l'écran de travail principal du service, ouvert par défaut au lancement.
/// Pour toute autre boutique, le Tableau de bord historique. Centralisé ici
/// pour que le router (atterrissage post-login) ET le sélecteur de boutique
/// renvoient au même écran.
String shopLandingRoute(String shopId) => isRestaurantShop(shopId)
    ? '/shop/$shopId/inventaire'
    : '/shop/$shopId/dashboard';

/// True si la boutique COURANTE est un établissement de restauration.
///
/// Réservé aux endroits qui n'ont accès ni au `shopId` ni au `BuildContext`
/// — en pratique les libellés de `ShellNavItem`, dont la signature ne reçoit
/// qu'un `AppLocalizations`. Threader le secteur jusqu'aux ~11 sites de rendu
/// du menu aurait été disproportionné pour un libellé.
///
/// S'appuie sur `NotificationService.currentShopId`, déjà positionné par
/// `AdaptiveScaffold.build` AVANT le rendu de la sidebar et du drawer
/// (`setCurrentShop` y précède la construction des shells). Hors de ce
/// contexte le scope peut être null → retourne false, soit le libellé
/// e-commerce par défaut.
bool isCurrentShopRestaurant() =>
    isRestaurantShop(NotificationService.currentShopId ?? '');
