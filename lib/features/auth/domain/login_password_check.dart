/// CE QUE L'ÉCRAN DE CONNEXION A LE DROIT DE REFUSER.
///
/// Une seule chose : un champ VIDE. Rien d'autre.
///
/// ─── NE REMETTEZ PAS DE CONTRÔLE DE LONGUEUR ICI ───────────────────────────
///
/// Il y en avait un — `if (v.length < 6) return errPasswordShort;` — et il a
/// été retiré délibérément le 22/09/2026. Un audit l'avait signalé comme une
/// incohérence, l'inscription exigeant huit caractères là où la connexion s'en
/// contentait de six, et proposait d'aligner la connexion sur huit.
///
/// C'EST L'INVERSE QU'IL FALLAIT FAIRE. Aligner la connexion sur la politique
/// d'inscription aurait ENFERMÉ DEHORS tout compte créé avant elle avec un mot
/// de passe plus court : le sien est valide côté serveur, il ouvre sa session
/// sans difficulté — mais l'écran refuserait de le transmettre. Un correctif
/// de sécurité qui produit un verrouillage n'est pas un correctif.
///
/// LE RAISONNEMENT, en une phrase : un écran de connexion TRANSMET, il ne juge
/// pas. Il n'a aucun moyen de savoir ce qui est acceptable — la politique peut
/// avoir changé, le compte peut venir d'un import, l'utilisateur peut être un
/// super-administrateur créé à la main. Le serveur, lui, sait. Lui laisser la
/// décision est la seule position tenable.
///
/// LA POLITIQUE N'A PAS DISPARU, elle est restée où elle sert : à
/// l'inscription (`register_page`) et au changement de mot de passe
/// (`forgot_password_page`), via `password_policy.dart`. Ce sont les deux
/// endroits où l'on CHOISIT un mot de passe. Ici, on en saisit un qui existe
/// déjà.
///
/// Un test épingle l'absence de règle de longueur. S'il tombe, c'est que
/// quelqu'un l'a rétablie — relisez ce qui précède avant de le corriger.
library;

/// L'erreur à afficher sous le champ mot de passe de la CONNEXION, ou `null`.
///
/// Les messages sont passés en paramètre plutôt que lus ici : la règle est
/// vérifiable sans construire un arbre de widgets ni charger les traductions.
String? loginPasswordError(
  String? value, {
  required String requiredMessage,
}) {
  if (value == null || value.isEmpty) return requiredMessage;
  return null;
}
