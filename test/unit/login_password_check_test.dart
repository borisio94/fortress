// L'écran de connexion refusait des mots de passe valides.
//
// `login_page` imposait six caractères minimum, l'inscription en exige huit.
// L'audit du parcours d'entrée a signalé l'incohérence et proposé d'aligner la
// connexion sur huit.
//
// C'ÉTAIT L'INVERSE QU'IL FALLAIT FAIRE. Aligner la connexion sur la politique
// d'inscription aurait enfermé dehors tout compte créé avant elle avec un mot
// de passe plus court : le sien est valide côté serveur, il ouvre sa session
// sans difficulté — mais l'écran aurait refusé de le transmettre. Un correctif
// de sécurité qui produit un verrouillage n'est pas un correctif.
//
// Un écran de connexion TRANSMET, il ne juge pas. Il n'a aucun moyen de savoir
// ce qui est acceptable : la politique peut avoir changé, le compte peut venir
// d'un import, l'utilisateur peut être un super-administrateur créé à la main.
// Le serveur sait.
//
// CES TESTS EXISTENT POUR EMPÊCHER LE RETOUR DU CONTRÔLE. Le validateur était
// écrit inline dans le widget, donc invérifiable et indéfendable — il a été
// extrait pour que la règle soit tenue par autre chose qu'un commentaire.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/auth/domain/login_password_check.dart';

const _required = 'Mot de passe requis';

String? _check(String? v) =>
    loginPasswordError(v, requiredMessage: _required);

void main() {
  group('Ce que la connexion refuse', () {
    test('un champ vide, et c\'est tout', () {
      expect(_check(null), _required);
      expect(_check(''), _required);
    });
  });

  group('Ce que la connexion NE refuse PAS', () {
    test('UN MOT DE PASSE COURT PASSE', () {
      // LE test de ce lot. Un compte créé avant la politique à huit
      // caractères doit pouvoir entrer : son mot de passe est valide côté
      // serveur, l'écran n'a pas à en juger.
      expect(_check('abc'), isNull);
    });

    test('AUCUNE LONGUEUR N\'EST REFUSÉE, d\'un caractère à cinquante', () {
      // Exhaustif à dessein. Si ce test tombe, c'est qu'une règle de longueur
      // a été rétablie — relisez l'en-tête de `login_password_check.dart`
      // avant de « corriger » quoi que ce soit.
      for (var n = 1; n <= 50; n++) {
        expect(_check('x' * n), isNull, reason: '$n caractères refusés');
      }
    });

    test('ni les espaces, ni les caractères exotiques', () {
      // On ne normalise rien non plus : un mot de passe peut légitimement
      // commencer ou finir par une espace, et le rogner ici empêcherait son
      // propriétaire d'entrer.
      expect(_check(' '), isNull);
      expect(_check('  mot de passe  '), isNull);
      expect(_check('é@#\$%^&*()'), isNull);
    });
  });
}
