/// QUI A PRIS CETTE COMMANDE.
///
/// La notion existait en entier — et inerte. `Sale.createdByUserId` est un
/// champ, il est écrit dans les quatre cartes de `sale_local_datasource`, lu
/// en retour, et porté par les DEUX chemins de synchronisation. `bill_page`
/// affiche même une ligne « Serveur ».
///
/// Elle ne s'affichait jamais, pour deux raisons qui se cumulaient :
///
///   * `RestaurantOrderService` construit ses `Sale` sans ce champ —
///     `saveTableOrder`, `saveTakeawayOrder` et `saveDeliveryOrder` ne le
///     renseignent pas. Il vaut donc toujours `null` au restaurant, et la
///     ligne, conditionnée à sa présence, ne se rend pas ;
///   * et s'il avait été rempli, `bill_page` affichait `createdByUserId` TEL
///     QUEL — un identifiant technique, illisible pour qui relit une addition.
///
/// Aucune migration : la colonne existe et voyage déjà. Il manquait l'écriture
/// et un nom.
library;

/// Le libellé à afficher pour l'auteur d'une commande, ou `null` si l'on n'a
/// rien de lisible à montrer.
///
/// JAMAIS UN IDENTIFIANT. Un UUID sur une addition n'apprend rien à personne
/// et donne l'impression d'une fuite technique. Mieux vaut ne rien afficher —
/// la ligne disparaît, exactement comme elle le faisait quand le champ était
/// vide.
///
/// L'e-mail sert de repli : une fiche de personnel peut n'avoir jamais reçu
/// de nom, et « awa@… » vaut mieux que rien pour un gérant qui cherche à qui
/// parler. On garde la partie locale, avant l'arobase : le domaine est le même
/// pour tout le monde et ne distingue personne.
String? serverLabelFor({
  required String? userId,
  String? name,
  String? email,
}) {
  if ((userId ?? '').trim().isEmpty) return null;

  final n = (name ?? '').trim();
  if (n.isNotEmpty) return n;

  final e = (email ?? '').trim();
  if (e.isEmpty) return null;
  final local = e.split('@').first.trim();
  return local.isEmpty ? null : local;
}
