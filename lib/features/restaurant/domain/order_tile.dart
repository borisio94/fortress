import '../../caisse/domain/entities/sale_item.dart';

/// CE QUE DIT UNE COMMANDE QUAND ON N'A PAS LA PLACE DE TOUT DIRE.
///
/// Deux formes du même contenu, et le nombre de tuiles qui tiennent dans une
/// largeur. Les trois vivent ici parce qu'elles se répondent : la forme courte
/// n'existe que parce que la tuile de grille est étroite, et la tuile n'est
/// étroite que parce qu'on en met plusieurs par rangée.

/// Le contenu sur UNE ligne : « 2× Ndolè, 1× Jus, Poulet DG ».
///
/// Forme LONGUE, pour la ligne dense — qui dispose d'une ligne entière au-dessus
/// de 720 px. Déplacée telle quelle depuis `_OrderCardState._contenu` le
/// 2026-09-23, sans qu'un caractère change.
String orderContentsLine(List<SaleItem> items) {
  if (items.isEmpty) return 'Aucun article';
  return items
      .map((i) => i.quantity > 1 ? '${i.quantity}× ${i.productName}' : i.productName)
      .join(', ');
}

/// Le contenu sur un DEMI-ligne : « 2× Ndolè + 3 autres ».
///
/// Forme COURTE, pour la tuile de grille, où le contenu partage sa ligne avec
/// le montant et n'en a plus que la moitié.
///
/// POURQUOI PAS LA FORME LONGUE TRONQUÉE. « 2× Ndolè, 1× Jus, 1× Poul… » coupé
/// en plein mot dit le premier plat et rien d'autre. « + 3 autres » dit le
/// premier plat ET la taille de la commande — ce que le serveur cherche quand
/// il balaie l'écran. Même largeur, strictement plus d'information.
///
/// LE COMPTE EST CELUI DES LIGNES, pas des articles : « 2× Ndolè + 3 autres »
/// annonce trois autres PLATS. Additionner les quantités ferait dire « + 7 »
/// à une commande de quatre plats, ce qui promet une carte qu'on n'a pas.
String orderContentsShort(List<SaleItem> items) {
  if (items.isEmpty) return 'Aucun article';
  final first = items.first;
  final tete = first.quantity > 1
      ? '${first.quantity}× ${first.productName}'
      : first.productName;
  final reste = items.length - 1;
  if (reste == 0) return tete;
  // Singulier à un seul reste : « + 1 autres » se lit comme un défaut.
  return reste == 1 ? '$tete + 1 autre' : '$tete + $reste autres';
}

/// LARGEUR PLANCHER D'UNE TUILE DE COMMANDE.
///
/// Mesurée sur les styles réels, pas choisie : la ligne « plat · montant · état
/// de paiement » porte 147 px de contenu FIXE — montant `bodyBold` 14 (~62 px),
/// « · non payé » `micro` (~55 px), chevron (18), écarts (12). Sous 300 px de
/// tuile — soit 269 px utiles une fois retirés le liseré de 3 et le padding de
/// 14×2 — le nom du plat descend sous 110 px et cesse de dire quoi que ce soit.
const double kOrderTileMin = 300;

/// PLAFOND DE COLONNES — valeur ARBITRAIRE, et c'est dit.
///
/// Rien n'empêche techniquement d'en mettre cinq : la formule ci-dessous les
/// calculerait, et les tuiles resteraient au-dessus du plancher dès 1590 px.
/// La borne tient à un seul argument, faible : un `Wrap` à hauteurs variables
/// — imposé par le dépliement des cartes — donne des bas de rangée d'autant
/// plus dentelés qu'il y a de colonnes, et au-delà de quatre la grille cesse de
/// se lire comme des rangées.
///
/// Si quelqu'un veut cinq colonnes un jour, ce nombre est le seul obstacle.
const int kOrderGridMaxColumns = 4;

/// COMBIEN DE TUILES TIENNENT DANS [available], par déduction.
///
/// Le seuil ne se fixe PAS en pixels d'écran. On fixe la largeur plancher d'une
/// tuile et on en déduit les colonnes — c'est ce qui garantit que le libellé le
/// plus long du module, « Envoyer en préparation » (202 px avec son icône et son
/// padding), passe à TOUTES les largeurs : quatre colonnes n'apparaissent qu'à
/// partir de 1270 px de bloc, donc avec des tuiles de 310 px, soit 279 utiles.
///
/// Des seuils en pixels laissaient cela au hasard, et le hasard a donné deux
/// colonnes de 518 px sur un écran de 1070.
int orderGridColumns(double available, {double gap = 10}) {
  if (available <= 0) return 1;
  final n = (available + gap) ~/ (kOrderTileMin + gap);
  return n.clamp(1, kOrderGridMaxColumns);
}
