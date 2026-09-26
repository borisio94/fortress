import 'package:flutter_riverpod/flutter_riverpod.dart';

/// En dessous de cette largeur, le volet panier occupe TOUTE la fenêtre.
///
/// Le seuil vivait en double : `restaurant_menu_page` dimensionnait le volet
/// avec, et le panier ignorait qu'il pouvait recouvrir la carte. C'est ce que
/// ce constat a révélé — un bouton « Carte » n'a de sens que là où la carte
/// est cachée, donc exactement sous ce nombre. Une seule source.
///
/// 720 et non 600 : au-dessus, le volet (320 px au moins) laisse à la carte
/// deux colonnes de plats côte à côte — MESURÉ le 26/09/2026 avec
/// `menuGridLayout` : 172 px par tuile à 720, 212 à 800, 262 à 899. La tuile
/// passe sous son plancher de 200 px entre 720 et ~780 (la grille garde ses
/// deux colonnes, plus étroites) ; elle ne tombe jamais à une seule.
///
/// ZONE 720–900 VOULUE (document de design § 8) : le shell y est déjà celui
/// du mobile (900), mais une tablette en portrait garde la carte et la
/// commande côte à côte — c'est le geste du service. Ne pas aligner ce seuil
/// sur le 900 du shell sans relire cette décision.
const double kCartPaneFullWidthBelow = 720;

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

  /// Replie le volet pour rendre la carte.
  ///
  /// Le pendant de [show], et il manquait. Replier n'était possible que par le
  /// bouton 🛒 de la barre du haut — le coin le plus éloigné du pouce — alors
  /// que sous [kCartPaneFullWidthBelow] le volet recouvre TOUTE la carte : il
  /// fallait donc y retourner entre chaque plat d'une même commande.
  void hide() {
    if (state) state = false;
  }

  /// Rouvre le volet. Appelé à l'ajout d'un article : sans ça, ajouter un plat
  /// alors que le volet est replié ne produirait RIEN à l'écran — le serveur
  /// taperait deux fois, croyant avoir manqué son geste.
  void show() {
    if (!state) state = true;
  }
}
