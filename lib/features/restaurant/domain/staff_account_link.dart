/// QUEL COMPTE A DÉJÀ SA FICHE DE PERSONNEL.
///
/// Le formulaire du personnel retire de la liste des comptes ceux qui ont déjà
/// leur fiche : sans ce filtre, on créerait deux fiches pour la même personne,
/// et c'est un mois de salaire coupé en deux.
///
/// Le rapprochement se faisait sur le NOM, en minuscules, faute de lien
/// stocké. Le code l'avouait : *« c'est imparfait — deux homonymes seraient
/// confondus »*.
///
/// CE QUE ÇA CASSAIT. Avec deux « Awa Ndiaye » dans l'équipe, la première
/// fiche créée faisait DISPARAÎTRE la seconde de la liste. Son compte devenait
/// inéligible, et le gérant n'avait aucun moyen de lui créer sa fiche — ni de
/// comprendre pourquoi.
///
/// `StaffMember.userId` porte désormais le lien (hotfix_182). Le nom reste un
/// REPLI, et seulement pour les fiches antérieures : on ne devine pas
/// rétroactivement à quel compte chacune correspondait.
library;

/// Le minimum qu'on ait besoin de savoir d'une fiche pour la rapprocher.
///
/// Un enregistrement plutôt que `StaffMember` entier : la règle se vérifie
/// ainsi sans Hive ni entité, et c'est elle qu'on veut épingler.
typedef StaffLink = ({String? userId, String fullName});

/// Ce compte a-t-il déjà une fiche dans cette boutique ?
///
/// DEUX PASSES, ET L'ORDRE COMPTE.
///
/// 1. Le LIEN d'abord. Une fiche qui porte un identifiant de compte ne parle
///    que de ce compte-là. C'est la seule réponse sûre, et elle tranche seule.
///
/// 2. Le NOM ensuite, et UNIQUEMENT sur les fiches sans lien. Une fiche liée à
///    quelqu'un d'autre ne doit plus bloquer un homonyme — c'est tout le
///    défaut qu'on referme. Le repli ne sert donc qu'aux fiches créées avant
///    le hotfix_182, qui n'ont pas de lien et n'en auront jamais.
///
/// À mesure que les anciennes fiches sont modifiées, elles gagnent leur lien
/// et sortent du repli d'elles-mêmes.
bool accountHasStaffRecord({
  required String userId,
  required String fullName,
  required Iterable<StaffLink> staff,
}) {
  // 1. Le lien tranche seul.
  if (staff.any((s) => s.userId != null && s.userId == userId)) return true;

  // 2. Le nom, et SEULEMENT sur les fiches qui n'ont pas de lien.
  final name = fullName.trim().toLowerCase();
  return staff.any((s) =>
      s.userId == null && s.fullName.trim().toLowerCase() == name);
}
