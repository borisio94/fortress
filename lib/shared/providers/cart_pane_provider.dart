import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Volet panier de droite VISIBLE ou replié — RESTAURATION.
///
/// Le volet ne s'ouvre pas sur un état booléen seul : il apparaît quand le
/// panier contient quelque chose ET que ce drapeau est vrai. Autrement dit ce
/// provider n'est pas « le panier est ouvert », c'est « l'utilisateur ne l'a
/// pas replié ». La différence compte : un panier vide n'a rien à montrer,
/// quel que soit ce drapeau, et un booléen unique se serait fatalement
/// désynchronisé du contenu (panier vidé ailleurs, commande envoyée).
///
/// Il existe parce que le bouton 🛒 de la barre du haut doit agir sur CE
/// volet. Avant, il ouvrait une feuille modale par-dessus la carte — un second
/// panier, en double du volet déjà visible à droite.
///
/// Non persisté : replier le volet est un geste du moment (« laisse-moi voir
/// toute la carte »), pas une préférence. Il se rouvre à l'article suivant.
final cartPaneVisibleProvider =
    NotifierProvider<CartPaneVisibleNotifier, bool>(
        CartPaneVisibleNotifier.new);

class CartPaneVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;

  /// Rouvre le volet. Appelé à l'ajout d'un article : sans ça, ajouter un plat
  /// alors que le volet est replié ne produirait RIEN à l'écran — le serveur
  /// taperait deux fois, croyant avoir manqué son geste.
  void show() {
    if (!state) state = true;
  }
}
