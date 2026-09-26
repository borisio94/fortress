/// LA CAISSE E-COMMERCE : panier intégré à côté des produits, ou onglets
/// Panier / Produits.
///
/// La décision lisait l'ÉCRAN (`largeur > 800`). Barre latérale DÉPLIÉE —
/// le défaut de l'e-commerce, 247 px —, les produits tombaient à 2 colonnes
/// de 116 px à 900, sous 180 (la cible de la grille) jusqu'à ~1 100. Elle lit
/// désormais le CORPS de page (26/09/2026), comme le volet panier du Menu
/// (`restaurant/domain/cart_pane_layout.dart`).
///
/// En shell mobile (corps = écran), la bascule reste à 800 / 801 : la zone
/// 800–900 garde son panier intégré, les produits au moins 190 px par tuile.
///
/// Pure et testée (`test/unit/caisse_layout_test.dart`).
library;

/// Largeur du panier intégré.
const double kCaisseCartWidth = 380;

/// Filet entre les produits et le panier.
const double kCaisseCartDivider = 1;

/// Place minimale des produits à côté du panier : 801 − 381. C'est ce qu'ils
/// gardaient à la bascule d'origine (`écran > 800`) — 2 colonnes de 190 px.
const double kCaisseProductsBesideCartMin = 420;

/// Le panier se pose-t-il À CÔTÉ des produits, dans un corps de page de
/// [bodyWidth] ? Sinon : onglets Panier / Produits.
bool caisseCartInline(double bodyWidth) =>
    bodyWidth - kCaisseCartWidth - kCaisseCartDivider >=
    kCaisseProductsBesideCartMin;
