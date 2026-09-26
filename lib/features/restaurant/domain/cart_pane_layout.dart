/// LE VOLET PANIER DU MENU : sa largeur, et s'il RECOUVRE la carte.
///
/// Deux mesures, deux questions (26/09/2026) :
///   • la LARGEUR lit l'ÉCRAN — un tiers, bornée entre [kCartPaneMinWidth] et
///     [kCartPaneMaxWidth] : aucun volet déjà côte à côte ne change de taille ;
///   • la décision de RECOUVRIR lit le CORPS de page — l'écran moins la barre
///     latérale. Elle lisait l'écran : barre latérale DÉPLIÉE (247 px), la
///     carte tombait à 2 colonnes de 138 px à 900, sous le plancher de ses
///     tuiles jusqu'à ~1 060.
///
/// Le volet recouvre la carte quand celle-ci, à côté de lui, aurait moins de
/// [kMenuBesideCartPaneMin]. En shell mobile (corps = écran), la bascule reste
/// à 720 — la zone 720–900 tranchée « voulue » (document de design § 8).
///
/// Pure et testée (`test/unit/cart_pane_layout_test.dart`).
library;

/// Largeur minimale du volet latéral : assez pour lire une ligne d'article.
const double kCartPaneMinWidth = 320;

/// Largeur maximale du volet latéral : la carte reste l'écran principal.
const double kCartPaneMaxWidth = 420;

/// Écart entre la carte et le volet latéral — deux blocs distincts, pas deux
/// moitiés d'une même surface.
const double kCartPaneGap = 10;

/// Place minimale de la carte à côté du volet : 720 − 320 − 10. C'est ce
/// qu'elle garde au seuil de la zone 720–900 (2 colonnes de 172 px), plancher
/// accepté en tranchant cette zone. Un test la lie à `kCartPaneFullWidthBelow`.
const double kMenuBesideCartPaneMin = 390;

/// Disposition du volet : recouvre-t-il la carte, et sur quelle largeur.
typedef CartPaneLayout = ({bool coversMenu, double width});

/// La disposition du volet pour un écran de [screenWidth] dont le corps de
/// page (écran moins barre latérale) fait [bodyWidth].
///
/// Recouvrant, il prend le corps ENTIER et aucun écart : ajouté, l'écart le
/// faisait déborder de la rangée.
CartPaneLayout cartPaneLayout({
  required double screenWidth,
  required double bodyWidth,
}) {
  final lateral = (screenWidth / 3)
      .clamp(kCartPaneMinWidth, kCartPaneMaxWidth)
      .toDouble();
  final menuLeft = bodyWidth - lateral - kCartPaneGap;
  if (menuLeft < kMenuBesideCartPaneMin) {
    return (coversMenu: true, width: bodyWidth);
  }
  return (coversMenu: false, width: lateral);
}
