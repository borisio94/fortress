/// LES ACTIONS SUR UNE TABLE du plan de salle — jamais sur la commande.
///
/// Le contenu suit l'état : une table LIBRE n'a ni addition à réclamer ni
/// couverts à ajuster, mais elle peut être supprimée — ce qu'une table en
/// service ne peut pas (on effacerait des additions ouvertes).
///
/// Logique PURE, sortie de `_RestaurantTablesPageState._showTableActions` le
/// 26/09/2026 (lot « classes géantes ») : la page vit sous `AppScaffold`,
/// qu'on ne sait pas monter en test — ici, la règle se teste sans rien monter
/// (`test/unit/table_actions_test.dart`).
library;

import 'entities/restaurant_table.dart';

/// Une entrée du menu d'actions d'une table.
enum TableAction {
  /// Demander (ou voir) l'addition.
  bill,

  /// Comptes de la table : consulter, transférer, fusionner.
  tabs,

  /// Des places se libèrent : ajuster les couverts.
  covers,

  /// Remettre la table en statut Libre.
  release,

  /// Rendre une table réservée dont le client ne vient pas.
  cancelReservation,

  /// Retenir une table libre jusqu'à l'arrivée du client.
  reserve,

  /// Retirer la table du plan de salle.
  delete,
}

/// Les actions proposées sur [table], dans l'ordre du menu.
///
/// TROIS états, pas deux. `isFree` inclut les réservations périmées : s'en
/// tenir à `free` / `!free` proposerait une addition et un ajustement de
/// couverts sur une table simplement RETENUE, où personne n'est encore assis.
///
/// [canManageRoom] — le droit de composer le plan de salle — ne commande que
/// la suppression ; réserver reste ouvert à tout membre (un client appelle, le
/// serveur qui décroche note).
List<TableAction> tableActionsFor(
  RestaurantTable table, {
  required bool canManageRoom,
}) {
  final free = table.isFree;
  final reserved = table.hasLiveReservation;
  final inService = !free && !reserved;
  return [
    if (inService) ...[
      TableAction.bill,
      TableAction.tabs,
      TableAction.covers,
      TableAction.release,
    ],
    // RETENUE : rien à encaisser, rien à ajuster — seulement rendre la table
    // si le client ne vient pas.
    if (reserved) TableAction.cancelReservation,
    // LIBRE : réserver, ouvert à tout membre.
    if (free) TableAction.reserve,
    if (free && canManageRoom) TableAction.delete,
  ];
}
