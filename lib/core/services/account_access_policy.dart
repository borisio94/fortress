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
///
/// LA LECTURE AUSSI VIT ICI, depuis le 21/09/2026. « Qui peut créer une
/// boutique » existait en deux exemplaires — le garde de `RouteNames.createShop`
/// et le bouton « Nouvelle boutique » — chacun relisant Hive à sa façon, avec
/// un commentaire qui demandait de les tenir en miroir à la main. Ils avaient
/// déjà divergé.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage/hive_boxes.dart';

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
///
/// [signedIn] : une session est ouverte. SANS SESSION, C'EST NON — et c'est
/// le seul point où les deux exemplaires de cette règle divergeaient. Le garde
/// de route répondait `null`, donc « autorisé » ; le bouton « Nouvelle
/// boutique » répondait `false`. Un commentaire demandait de les tenir en
/// miroir à la main, et ce miroir était déjà brisé.
///
/// C'est le bouton qui avait raison : UN GARDE D'ACCÈS SE FERME QUAND IL NE
/// SAIT PAS. Le cas n'est pas théorique — une connexion hors ligne n'ouvre
/// aucune session Supabase, `currentUser` y est nul alors que l'utilisateur
/// est entré. La création ne pourrait de toute façon pas aboutir : l'identifiant
/// de boutique vient du serveur.
bool mayCreateShop({
  required bool signedIn,
  required bool ownsAShop,
  required bool hasAnyMembership,
}) =>
    signedIn && (ownsAShop || !hasAnyMembership);

/// La même question, posée à l'état réel de l'appareil.
///
/// C'est LA seule lecture. Le garde de route et le bouton « Nouvelle boutique »
/// la partagent : un bouton qui autorise là où le garde refuse renvoie
/// l'utilisateur sur lui-même, et il le lit comme une application qui
/// n'arrive pas à charger sa boutique.
bool currentUserMayCreateShop() {
  final uid = Supabase.instance.client.auth.currentUser?.id;

  bool anyMatch(Iterable<dynamic> rows, String field) => rows.any((raw) {
        try {
          return Map<String, dynamic>.from(raw as Map)[field] == uid;
        } catch (_) {
          return false;
        }
      });

  return mayCreateShop(
    signedIn: uid != null,
    ownsAShop: anyMatch(HiveBoxes.shopsBox.values, 'owner_id'),
    hasAnyMembership: anyMatch(HiveBoxes.membershipsBox.values, 'user_id'),
  );
}
