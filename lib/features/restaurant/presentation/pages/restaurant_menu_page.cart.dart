part of 'restaurant_menu_page.dart';

// Le VOLET PANIER de la page Menu, à droite de la carte. Sorti du `build` de
// `_RestaurantMenuPageState` le 26/09/2026 (lot « classes géantes ») ; la page
// garde ce qui décide de son ouverture (panier non vide, volet non replié).

/// Le volet panier, animé en largeur : fermé, il ne prend aucune place.
class _MenuCartPane extends StatelessWidget {
  /// Déployé : le panier a des lignes et le volet n'est pas replié.
  final bool open;
  final String shopId;

  const _MenuCartPane({required this.open, required this.shopId});

  /// Écart entre la carte et le volet panier — les deux sont des blocs
  /// distincts, pas deux moitiés d'une même surface.
  static const double _kCartGap = 10;

  /// Largeur du volet : assez pour lire une ligne d'article, jamais plus du
  /// tiers de l'écran — la carte doit rester l'écran principal.
  static double _width(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    // Le seuil est partagé avec le panier, qui doit savoir s'il recouvre la
    // carte pour proposer d'y revenir. Voir `kCartPaneFullWidthBelow`.
    return w < kCartPaneFullWidthBelow ? w : (w / 3).clamp(320.0, 420.0);
  }

  @override
  Widget build(BuildContext context) {
    // Animé en largeur : le volet glisse au lieu d'apparaître d'un
    // bloc, ce qui rend visible d'où il vient.
    // Le panier est un BLOC À PART : coins arrondis et écart avec la
    // carte, comme la maquette. L'écart est compris DANS la largeur
    // animée — ajouté à côté, il apparaîtrait d'un coup au premier
    // article pendant que le panier, lui, glisse encore.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: open ? _width(context) + _kCartGap : 0,
      child: open
          // `ClipRect` + `OverflowBox` : pendant l'animation, la
          // largeur imposée est inférieure à la largeur finale du
          // panier. Sans ces deux-là, Flutter tenterait de comprimer
          // sa mise en page à chaque image et lèverait un débordement.
          ? ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: _width(context) + _kCartGap,
                child: Padding(
                  padding: const EdgeInsets.only(left: _kCartGap),
                  child: SizedBox(
                    width: _width(context),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: CartWidget(
                          shopId: shopId, isEcommerce: true),
                    ),
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
