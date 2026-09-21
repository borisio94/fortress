/// ACCÈS D'UN COMPTE À SES BOUTIQUES — règles pures.
///
/// Deux questions se posaient au même état — « ce compte n'a ni membership ni
/// boutique » — dans deux fichiers, et les réponses se contredisaient :
///
///   * `SessionValidator` y voyait un COMPTE ZOMBIE et le purgeait ;
///   * le garde de `RouteNames.createShop` y voyait un NOUVEL INSCRIT et le
///     laissait créer sa première boutique.
///
/// La seconde lecture est la bonne, et la première enfermait dehors : un compte
/// créé dont la création de boutique a échoué se retrouve exactement dans cet
/// état. `register_page` prévoit pourtant le cas et propose de réessayer — il
/// suffisait de fermer l'application avant. Au redémarrage, expulsion et purge,
/// puis « Un compte avec cet email existe déjà » à la réinscription.
///
/// Les deux règles vivent désormais ici, et un test vérifie qu'elles ne se
/// contredisent plus.
library;

/// Ce compte a-t-il été RÉVOQUÉ côté serveur ?
///
/// [serverGrantsAccess] : le serveur lui reconnaît une membership ou une
/// boutique possédée. [deviceRemembersAccess] : l'appareil garde la trace d'un
/// accès — une membership ou une boutique possédée en local.
///
/// UN REFUS SERVEUR NE SUFFIT PAS. Il faut que l'appareil se souvienne d'un
/// accès que le serveur dément : c'est ça, une révocation — un employé
/// supprimé, un propriétaire dont la boutique a été effacée. Sans souvenir
/// local, le compte n'a jamais rien eu : il vient d'être créé, et l'expulser
/// avec purge est la pire réponse possible, puisqu'il ne pourra pas se
/// réinscrire sous le même e-mail.
///
/// Le serveur reste souverain quand il ACCORDE : il n'y a alors aucune
/// révocation, quoi qu'en dise l'appareil.
bool isRevokedAccount({
  required bool serverGrantsAccess,
  required bool deviceRemembersAccess,
}) =>
    !serverGrantsAccess && deviceRemembersAccess;

/// Ce compte peut-il créer une boutique ?
///
/// Un propriétaire, toujours. Un compte sans aucune membership non plus : c'est
/// un nouvel inscrit qui crée sa première boutique — sans cette branche, on
/// rejetterait le tout premier compte. Un employé invité dans la boutique de
/// quelqu'un d'autre, jamais.
bool mayCreateShop({
  required bool ownsAShop,
  required bool hasAnyMembership,
}) =>
    ownsAShop || !hasAnyMembership;
