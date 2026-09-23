/// LES ONGLETS DE L'ÉCRAN COMMANDES, EN RESTAURATION.
///
/// L'écran filtrait sur `SaleStatus` : six onglets, un par statut. C'est juste
/// en e-commerce, où le statut PORTE l'avancement. En restauration, non — et
/// c'est tout l'objet de ce fichier.
///
/// LE RESTAURANT N'ÉCRIT JAMAIS `SaleStatus.processing`. Toute la chronologie
/// du service vit dans des DRAPEAUX, à l'intérieur du statut `scheduled` :
/// `sentToKitchen`, `kitchenReady`, `served`, `finished`. Le statut ne bascule
/// qu'à l'encaissement.
///
/// Conséquence : l'onglet « Programmée » contenait aussi bien une commande que
/// personne n'a envoyée en cuisine qu'un client en train de finir son dessert.
/// « En cours » et « Refusée » restaient vides toute l'année. Six onglets pour
/// deux états réellement peuplés.
///
/// ─── LA CASCADE EST CELLE DU BOUTON, PAS UNE INVENTION ───────────────────
///
/// Les rangs ci-dessous reprennent, dans l'ordre, les cinq échelons de
/// `_buildServiceProgress` (`caisse_page.dart`). Chaque onglet correspond donc
/// à UN bouton, et un seul : choisir « À servir », c'est obtenir exactement les
/// cartes dont le bouton dit « Marquer servie ».
///
/// Un onglet qui ne correspondrait à aucun bouton serait un onglet qui ment —
/// c'est le défaut d'aujourd'hui, où « Programmée » en contient cinq.
///
/// ─── EXCLUSIVE ET EXHAUSTIVE ──────────────────────────────────────────────
///
/// [serviceTabOf] rend UN rang et un seul pour toute commande. La somme des
/// compteurs égale donc le total, et c'est ce que vérifie le test. Un statut
/// ajouté demain sans rang tomberait dans le dernier — visible, pas silencieux.
///
/// AUCUN LIBELLÉ N'EMPRUNTE À `SaleStatus`. Les mots « Programmée »,
/// « En cours », « Complétée », « Annulée » et « Refusée » restent la propriété
/// des BADGES. Un onglet ne doit jamais pouvoir se lire comme un badge : c'est
/// la contradiction qu'on aurait créée en renommant à moitié.
library;

import '../../caisse/domain/entities/sale.dart';

/// Les rangs du service, dans l'ordre d'avancement.
enum ServiceTab {
  /// Tout, sans filtre. Le seul rang qui ne soit pas un état.
  toutes('Toutes'),

  /// Personne ne l'a envoyée en préparation. Une commande du catalogue web
  /// arrive ici et y reste tant qu'on ne l'acquitte pas — c'est une ALERTE,
  /// pas une étape : `_webOrdersBadge` la compte déjà à part.
  aEnvoyer('À envoyer'),

  /// La cuisine travaille. Le seul rang où le service n'a rien à faire.
  ///
  /// « préparation » et non « cuisine » : le module a tranché — un chawarma ou
  /// une glace ne passent pas par le piano.
  enPreparation('En préparation'),

  /// PRÊTE AU PASSE, PERSONNE NE L'A PRISE. La seconde alerte, et la plus
  /// coûteuse : c'est là, et seulement là, que des plats refroidissent.
  aServir('À servir'),

  /// Le service n'est pas clos — le client mange, ou la commande à emporter
  /// attend sa remise. Le rang le plus peuplé d'un service, et celui qui n'a
  /// besoin de rien.
  aTerminer('À terminer'),

  /// Le service est fait, l'argent non.
  aEncaisser('À encaisser'),

  /// Réglée.
  encaissees('Encaissées'),

  /// Les fins de course qui n'ont PAS produit de recette : annulée, refusée,
  /// remboursée.
  ///
  /// Les trois ensemble parce que deux d'entre elles ne se produisent jamais
  /// en restauration — « refusée » vient du circuit de livraison e-commerce,
  /// et l'audit du parcours a établi qu'AUCUN chemin ne produit « remboursée ».
  /// Un onglet toujours vide est un onglet qu'on cesse de lire.
  ///
  /// « Sans suite » plutôt qu'« Annulées » : le mot ne doit pas pouvoir se
  /// confondre avec le badge, et il couvre les trois sans en accuser aucune.
  sansSuite('Sans suite');

  final String label;
  const ServiceTab(this.label);

  /// Les onglets affichés, dans l'ordre. `toutes` en tête.
  static const List<ServiceTab> ordered = [
    toutes,
    aEnvoyer,
    enPreparation,
    aServir,
    aTerminer,
    aEncaisser,
    encaissees,
    sansSuite,
  ];
}

/// LE RANG D'UNE COMMANDE. Un seul, toujours.
///
/// L'ORDRE DES TESTS EST LE CONTRAT. Les deux fins de course d'abord — une
/// commande annulée ou encaissée ne se lit plus sur ses drapeaux de cuisine,
/// qui restent figés à ce qu'ils étaient. Les inverser ferait apparaître une
/// commande réglée sous « À terminer », parce que `settleAndRelease` FORCE
/// `served` et `finished` au moment d'encaisser.
///
/// Ne rend jamais [ServiceTab.toutes] : ce n'est pas un rang, c'est l'absence
/// de filtre.
ServiceTab serviceTabOf(Sale order) {
  // ── Fins de course ────────────────────────────────────────────────────
  // `refunded` est ici AUSSI, et c'est délibéré : aucun chemin de l'app ne le
  // produit aujourd'hui — l'audit du parcours l'a établi — mais l'omettre
  // ferait tomber une commande remboursée dans « À envoyer », faute de
  // drapeaux de cuisine. Un rang par défaut doit être choisi, pas subi.
  if (order.status == SaleStatus.cancelled ||
      order.status == SaleStatus.refused ||
      order.status == SaleStatus.refunded) {
    return ServiceTab.sansSuite;
  }
  if (order.status == SaleStatus.completed) return ServiceTab.encaissees;

  // ── Les cinq échelons du bouton, dans son ordre ───────────────────────
  if (!order.sentToKitchen) return ServiceTab.aEnvoyer;
  if (order.isInKitchen) return ServiceTab.enPreparation;
  // `dine_in` SEULEMENT, comme le bouton : une commande à emporter prête n'a
  // personne à qui l'apporter, elle attend qu'on la remette au client — ce qui
  // est le rang suivant, pas celui-ci.
  if (order.isWaitingService && order.isDineIn) return ServiceTab.aServir;
  if (!order.finished) return ServiceTab.aTerminer;
  return ServiceTab.aEncaisser;
}

/// Les commandes d'un onglet, dans l'ordre reçu.
List<Sale> ordersForServiceTab(ServiceTab tab, List<Sale> orders) =>
    tab == ServiceTab.toutes
        ? List<Sale>.from(orders)
        : orders.where((o) => serviceTabOf(o) == tab).toList();

/// Le compte de chaque onglet, pour les pastilles.
///
/// UNE SEULE PASSE sur la liste plutôt qu'un filtre par onglet : l'écran les
/// affiche tous en permanence, et huit parcours d'une liste de service à
/// chaque frappe dans la recherche se sentiraient.
Map<ServiceTab, int> serviceTabCounts(List<Sale> orders) {
  final counts = {for (final t in ServiceTab.ordered) t: 0};
  for (final o in orders) {
    counts[ServiceTab.toutes] = counts[ServiceTab.toutes]! + 1;
    final t = serviceTabOf(o);
    counts[t] = counts[t]! + 1;
  }
  return counts;
}
