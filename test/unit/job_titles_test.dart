import 'package:flutter_test/flutter_test.dart';

import 'package:fortress/features/hr/domain/models/employee_permission.dart';
import 'package:fortress/features/hr/domain/models/job_titles.dart';

/// Postes de l'établissement (hotfix_160) — règles pures.
///
/// Ce qui compte ici : la liste affichée ne doit ni perdre la fonction de
/// quelqu'un, ni proposer deux fois le même poste, ni laisser supprimer un
/// poste encore occupé.
void main() {
  group('JobTitles.same', () {
    test('ignore la casse et les espaces autour', () {
      expect(JobTitles.same('Serveur', ' serveur '), isTrue);
      expect(JobTitles.same('Serveur', 'Serveuse'), isFalse);
    });
  });

  group('JobTitles.merge', () {
    test('conserve l\'ordre des postes déclarés', () {
      final out = JobTitles.merge(
          ['Gérant', 'Serveur', 'Cuisinier'], const <String>[]);
      expect(out, ['Gérant', 'Serveur', 'Cuisinier']);
    });

    test('ajoute à la fin les postes portés mais non déclarés', () {
      final out = JobTitles.merge(['Serveur'], ['Serveur', 'Chawarmier']);
      expect(out, ['Serveur', 'Chawarmier']);
    });

    test('ne propose pas deux fois le même poste écrit différemment', () {
      final out = JobTitles.merge(['Serveur'], ['serveur ']);
      expect(out, ['Serveur']);
    });

    test('ignore les libellés vides', () {
      final out = JobTitles.merge(['Serveur', '  '], ['']);
      expect(out, ['Serveur']);
    });

    // Le cas qui motive la seconde source : un poste supprimé de la liste
    // alors qu'un compte le porte encore doit rester affichable, sinon
    // rouvrir sa fiche effacerait sa fonction sans que personne ne l'ait
    // décidé.
    test('un poste supprimé mais encore porté reste dans la liste', () {
      final out = JobTitles.merge(['Serveur'], ['Plongeur']);
      expect(out, contains('Plongeur'));
    });
  });

  group('JobTitles.holders', () {
    const equipe = {
      'Awa':   'Serveur',
      'Bertin': 'serveur',
      'Chantal': 'Cuisinier',
    };

    test('trouve tous les titulaires, casse comprise', () {
      expect(JobTitles.holders('Serveur', equipe), ['Awa', 'Bertin']);
    });

    test('rend une liste vide pour un poste inoccupé', () {
      expect(JobTitles.holders('Livreur', equipe), isEmpty);
    });
  });

  // Profil de droits d'un poste (hotfix_161).
  group('JobTitles.decodePerms', () {
    test('relit ce qu\'encodePerms a écrit', () {
      const perms = {
        EmployeePermission.inventoryView,
        EmployeePermission.caisseAccess,
      };
      expect(JobTitles.decodePerms(JobTitles.encodePerms(perms)), perms);
    });

    // La distinction qui compte : un poste SANS profil ne doit rien décocher
    // quand on le choisit, alors qu'un profil vide retire tout.
    test('null et chaîne vide valent « aucun profil », pas « aucun droit »',
        () {
      expect(JobTitles.decodePerms(null), isNull);
      expect(JobTitles.decodePerms('   '), isNull);
    });

    test('ignore une clé inconnue sans perdre les autres', () {
      final out = JobTitles.decodePerms(
          'inventory.view,droit.disparu.en.v9,caisse.access');
      expect(out, {
        EmployeePermission.inventoryView,
        EmployeePermission.caisseAccess,
      });
    });
  });

  group('JobTitles.permsFor', () {
    test('retrouve le profil quelle que soit la casse du libellé', () {
      final table = {'Chawarmier': 'inventory.view'};
      expect(JobTitles.permsFor(table, 'chawarmier'), 'inventory.view');
      expect(JobTitles.permsFor(table, 'Glacier'), isNull);
    });
  });

  group('JobTitles.inUseMessage', () {
    test('nomme la personne quand elle est seule', () {
      expect(JobTitles.inUseMessage(['Awa'], 'Serveur'), contains('Awa'));
    });

    test('compte les personnes au-delà d\'une', () {
      final msg = JobTitles.inUseMessage(['Awa', 'Bertin'], 'Serveur');
      expect(msg, contains('2 personnes'));
    });
  });
}
