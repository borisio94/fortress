part of 'restaurant_menu_page.dart';

// Le VOLET PANIER de la page Menu, à droite de la carte. Sorti du `build` de
// `_RestaurantMenuPageState` le 26/09/2026 (lot « classes géantes ») ; la page
// garde ce qui décide de son ouverture (panier non vide, volet non replié).
//
// Sa disposition — largeur, et s'il RECOUVRE la carte — vient de
// `cartPaneLayout` (domaine, sous test) : la largeur lit l'écran, la décision
// de recouvrir lit le CORPS de page (barre latérale déduite).

/// Le volet panier, animé en largeur : fermé, il ne prend aucune place.
class _MenuCartPane extends StatelessWidget {
  /// Déployé : le panier a des lignes et le volet n'est pas replié.
  final bool open;
  final String shopId;

  /// Largeur, et recouvrement de la carte (`layoutFor`).
  final CartPaneLayout layout;

  const _MenuCartPane({
    required this.open,
    required this.shopId,
    required this.layout,
  });

  /// La disposition du volet dans un corps de page de [bodyWidth].
  ///
  /// Seul endroit du restaurant qui lit la largeur d'ÉCRAN (garde-fou
  /// `width_threshold_guard_test`) : la LARGEUR du volet est un tiers de
  /// l'écran, une décision sur l'écran entier.
  static CartPaneLayout layoutFor(BuildContext context, double bodyWidth) =>
      cartPaneLayout(
        screenWidth: MediaQuery.of(context).size.width,
        bodyWidth: bodyWidth,
      );

  @override
  Widget build(BuildContext context) {
    // Animé en largeur : le volet glisse au lieu d'apparaître d'un
    // bloc, ce qui rend visible d'où il vient.
    // Le panier est un BLOC À PART : coins arrondis et écart avec la
    // carte, comme la maquette. L'écart est compris DANS la largeur
    // animée — ajouté à côté, il apparaîtrait d'un coup au premier
    // article pendant que le panier, lui, glisse encore.
    //
    // RECOUVRANT, il n'a ni écart ni côté : il prend le corps entier. L'écart
    // ajouté à une largeur déjà pleine le faisait déborder de la rangée.
    final gap = layout.coversMenu ? 0.0 : kCartPaneGap;
    final full = layout.width + gap;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: open ? full : 0,
      child: open
          // `ClipRect` + `OverflowBox` : pendant l'animation, la
          // largeur imposée est inférieure à la largeur finale du
          // panier. Sans ces deux-là, Flutter tenterait de comprimer
          // sa mise en page à chaque image et lèverait un débordement.
          ? ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: full,
                child: Padding(
                  padding: EdgeInsets.only(left: gap),
                  child: SizedBox(
                    width: layout.width,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: CartWidget(
                          shopId: shopId,
                          isEcommerce: true,
                          coversMenu: layout.coversMenu),
                    ),
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
