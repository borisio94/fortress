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
/// 480 depuis la refonte de la carte (25/09/2026) — elle valait 300. La tuile
/// porte désormais sa ligne 3 ENTIÈRE sur une seule rangée : contenu · montant
/// + état de paiement · bouton d'action. Mesuré sur la métrique d'Inter : le
/// FIXE de cette rangée fait ~250 px avec les libellés COURTS du bouton
/// (« Envoyer », « Prête »… — ~370 px avec « Envoyer en préparation », d'où
/// les libellés courts). À 480 px de tuile, il reste ~200 px au contenu,
/// soit ~25 caractères : le nom d'un plat se lit.
const double kOrderTileMin = 480;

/// PLAFOND DE COLONNES : DEUX (décision du 25/09/2026).
///
/// Trois colonnes apparaîtraient vers 1920 px d'écran et ramèneraient la tuile
/// à ~530 px — le même problème de troncature que la refonte vient de régler.
/// Deux colonnes larges valent mieux que trois serrées.
const int kOrderGridMaxColumns = 2;

/// COMBIEN DE TUILES TIENNENT DANS [available], par déduction.
///
/// Le seuil ne se fixe PAS en pixels d'écran. On fixe la largeur plancher d'une
/// tuile et on en déduit les colonnes — c'est ce qui garantit que la ligne 3
/// de la tuile (contenu · montant · bouton) passe à TOUTES les largeurs : deux
/// colonnes n'apparaissent qu'à partir de ~970 px de bloc, donc avec des
/// tuiles d'au moins 480 px.
///
/// Des seuils en pixels laissaient cela au hasard, et le hasard avait donné
/// deux colonnes de 518 px sur un écran de 1070.
int orderGridColumns(double available, {double gap = 10}) {
  if (available <= 0) return 1;
  final n = (available + gap) ~/ (kOrderTileMin + gap);
  return n.clamp(1, kOrderGridMaxColumns);
}

/// LARGEUR SOUS LAQUELLE LA LISTE DENSE PASSE SUR DEUX LIGNES.
///
/// Déduite de ses colonnes, pas d'une largeur d'écran (cf. le document de
/// design, § 8 : une décision de disposition lit le CONTENEUR) : temps 42,
/// table 68, état 112, montant 96, action 78, chevron 18, six écarts de 8 —
/// 462 px de FIXE — plus 160 px de contenu, sous lesquels la colonne du milieu
/// ne dit plus rien.
const double kOrderListRowMin = 42 + 68 + 112 + 96 + 78 + 18 + 6 * 8 + 160;
