// Un compte neuf n'est pas un compte révoqué.
//
// `SessionValidator` interroge le serveur au démarrage : si le compte n'a ni
// membership ni boutique possédée, il le traite comme un COMPTE ZOMBIE —
// employé supprimé, propriétaire dont la boutique a disparu — et déclenche une
// déconnexion forcée avec purge complète de Hive et de SecureStorage.
//
// Or « ni membership ni boutique » est AUSSI l'état d'un compte qui vient
// d'être créé et dont la création de boutique a échoué. Ce cas existe et il
// est prévu : `register_page` affiche « Compte créé, mais la boutique n'a pas
// pu être créée… Réessayez ci-dessous » et renvoie vers /shop-selector/create.
// Il suffit de fermer l'application avant de réessayer.
//
// Au redémarrage, le compte est expulsé et tout est purgé. La réinscription
// échoue sur « Un compte avec cet email existe déjà ». L'utilisateur est
// enfermé DEHORS, avec un compte auth réel qu'aucun écran ne rattache plus à
// une boutique.
//
// LE MÊME ÉTAT, DEUX LECTURES CONTRAIRES. `app_router` connaît déjà la bonne :
// son garde de création de boutique autorise explicitement « 0 membership →
// nouvel inscrit qui crée sa première boutique ». Deux définitions du même état
// dans deux fichiers, et elles se contredisent.
//
// RÈGLE RETENUE : un compte est révoqué quand le serveur lui refuse l'accès ET
// que l'APPAREIL se souvient qu'il en avait un. Sans souvenir local, c'est un
// compte neuf — on le laisse entrer créer sa boutique.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/account_access_policy.dart';

void main() {
  group('Un compte neuf', () {
    test('n\'est pas révoqué, même sans accès côté serveur', () {
      // LE test rouge. Compte créé, boutique échouée, application fermée :
      // aujourd'hui il est expulsé et purgé au démarrage suivant.
      expect(
        isRevokedAccount(
            serverGrantsAccess: false, deviceRemembersAccess: false),
        isFalse,
        reason: 'un compte sans passé local vient d\'être créé',
      );
    });

    test('peut créer sa première boutique', () {
      expect(
          mayCreateShop(
              signedIn: true, ownsAShop: false, hasAnyMembership: false),
          isTrue);
    });
  });

  group('Un compte réellement révoqué', () {
    test('l\'est quand l\'appareil se souvient d\'un accès disparu', () {
      // Employé supprimé, propriétaire dont la boutique a été effacée : le
      // serveur refuse, et l'appareil garde la trace de ce qu'il avait.
      expect(
        isRevokedAccount(
            serverGrantsAccess: false, deviceRemembersAccess: true),
        isTrue,
      );
    });
  });

  group('Un compte en règle', () {
    test('n\'est jamais révoqué, que l\'appareil se souvienne ou non', () {
      for (final remembers in [true, false]) {
        expect(
          isRevokedAccount(
              serverGrantsAccess: true, deviceRemembersAccess: remembers),
          isFalse,
          reason: 'le serveur fait foi quand il accorde (local=$remembers)',
        );
      }
    });
  });

  group('Créer une boutique', () {
    test('un propriétaire le peut toujours', () {
      expect(
          mayCreateShop(
              signedIn: true, ownsAShop: true, hasAnyMembership: true),
          isTrue);
      expect(
          mayCreateShop(
              signedIn: true, ownsAShop: true, hasAnyMembership: false),
          isTrue);
    });

    test('un employé invité ailleurs ne le peut pas', () {
      expect(
          mayCreateShop(
              signedIn: true, ownsAShop: false, hasAnyMembership: true),
          isFalse);
    });

    test('UN COMPTE NON AUTHENTIFIÉ NE LE PEUT PAS', () {
      // LE test de ce lot. La règle vivait en deux exemplaires, et ils ne
      // répondaient pas pareil ici : le garde de `RouteNames.createShop`
      // rendait `null` — donc AUTORISÉ — quand `currentUser` était nul, là où
      // le bouton « Nouvelle boutique » rendait `false`.
      //
      // Rien ne disait laquelle des deux avait raison, et un commentaire
      // demandait de les tenir en miroir à la main. C'est le bouton qui avait
      // raison : un garde d'accès se ferme quand il ne sait pas.
      //
      // Le cas n'est pas théorique. Une connexion HORS LIGNE n'ouvre aucune
      // session Supabase : `currentUser` y est nul alors que l'utilisateur est
      // bel et bien entré. Le bouton lui refusait déjà la création — et elle
      // ne peut de toute façon pas aboutir, l'identifiant de boutique venant
      // du serveur.
      for (final owns in [true, false]) {
        for (final member in [true, false]) {
          expect(
              mayCreateShop(
                  signedIn: false, ownsAShop: owns, hasAnyMembership: member),
              isFalse,
              reason: 'owns=$owns member=$member');
        }
      }
    });
  });

  group('Les deux règles ne se contredisent plus', () {
    test('qui peut créer une boutique n\'est jamais traité en révoqué', () {
      // L'invariant qui ferme la classe de défaut : `app_router` et
      // `SessionValidator` lisaient le même état et n'en tiraient pas la même
      // conclusion. Un compte autorisé à créer sa boutique ne doit pas être
      // expulsé avant d'avoir pu le faire.
      for (final owns in [true, false]) {
        for (final member in [true, false]) {
          if (!mayCreateShop(
              signedIn: true, ownsAShop: owns, hasAnyMembership: member)) {
            continue;
          }
          final remembers = owns || member;
          if (remembers) continue; // il a un passé : le serveur tranche
          expect(
            isRevokedAccount(
                serverGrantsAccess: false, deviceRemembersAccess: remembers),
            isFalse,
            reason: 'owns=$owns member=$member : autorisé à créer, donc vivant',
          );
        }
      }
    });
  });
}
