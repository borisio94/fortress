/// LE LISERÉ D'ÉTAT — un trait vertical sur le bord gauche d'une carte, à la
/// couleur de son état (26/09/2026).
///
/// ─── LA RÈGLE : CONTOUR NON, LISERÉ OUI, SOUS DEUX CONDITIONS ─────────────
///
/// • Un CONTOUR entoure la carte et la sépare du fond : INTERDIT. Le fond,
///   l'espace et la typographie font ce travail.
/// • Un LISERÉ ne fait pas le tour et ne sépare rien : il porte une
///   information d'état sur un seul côté. PERMIS quand
///     1. l'état est l'information principale de la carte, ET
///     2. un libellé écrit l'état à côté — la couleur ne porte jamais
///        l'information seule.
///
/// Ne retirer JAMAIS le libellé en croyant alléger : plusieurs couleurs
/// d'état sont sous 3:1 sur leur carte (cf. `ServiceTabVisuals.stripeColor`),
/// et le liseré, seul, ne dirait plus rien à qui distingue mal les teintes.
///
/// ─── UNE SEULE ÉPAISSEUR ──────────────────────────────────────────────────
///
/// 4 px partout : le Plan de salle l'avait, la liste des commandes était à 3,
/// la grille n'en avait pas. Deux épaisseurs pour la même grammaire, apparues
/// sans que personne ne le décide — c'est ce que cette constante empêche.
library;

/// Épaisseur du liseré d'état, partout où il apparaît.
const double kStateStripeWidth = 4;
