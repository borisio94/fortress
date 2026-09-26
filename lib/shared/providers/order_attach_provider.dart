/// LA TABLE ET LE COMPTE AUXQUELS LE PROCHAIN PANIER SE RATTACHE.
///
/// `null` — le cas ordinaire — signifie « nouvelle commande » : la feuille de
/// prise de commande pose ses questions comme toujours.
///
/// Non `null` quand le serveur a demandé « Ajouter des plats » depuis une
/// addition ou depuis un compte du plan de salle. La feuille saute alors les
/// quatre questions dont la réponse est déjà connue — le type de service, la
/// table, le compte, les couverts — et ne garde que l'envoi.
///
/// POURQUOI UN PROVIDER ET NON UN ARGUMENT DE ROUTE. Le geste traverse trois
/// écrans : il part de l'addition, passe par la carte où le serveur choisit ses
/// plats, et n'est consommé qu'au panier. Le faire voyager par l'URL
/// l'exposerait au rechargement de page et le laisserait dans l'historique du
/// navigateur, où un retour arrière le ferait revivre sur une addition déjà
/// encaissée.
///
/// NON PERSISTÉ, délibérément. Une intention de service ne survit pas à la
/// fermeture de l'application : la retrouver le lendemain rattacherait des
/// plats à une table libérée depuis.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// De quoi rattacher une commande, et de quoi l'annoncer à l'écran.
///
/// Le NOM de la table autant que son identifiant : le panier doit pouvoir
/// écrire « Ajout à Table 4 » sans relire Hive pour un libellé.
typedef OrderAttachTarget = ({
  String tableId,
  String tableName,
  String tabLabel,
});

final orderAttachProvider =
    NotifierProvider<OrderAttachNotifier, OrderAttachTarget?>(
        OrderAttachNotifier.new);

class OrderAttachNotifier extends Notifier<OrderAttachTarget?> {
  @override
  OrderAttachTarget? build() => null;

  /// Arme le rattachement. Appelé par « Ajouter des plats ».
  void aim({
    required String tableId,
    required String tableName,
    required String tabLabel,
  }) =>
      state = (tableId: tableId, tableName: tableName, tabLabel: tabLabel);

  /// Désarme.
  ///
  /// À appeler dès que l'intention est consommée OU abandonnée. Les deux
  /// comptent autant : un rattachement oublié enverrait la commande SUIVANTE
  /// sur une table que le serveur ne vise plus — et il ne le verrait qu'au
  /// moment où le bon sort en cuisine.
  void clear() {
    if (state != null) state = null;
  }
}
