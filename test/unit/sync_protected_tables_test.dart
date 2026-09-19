// Une écriture d'argent ne disparaît pas en silence.
//
// La file de synchronisation abandonne une opération dans deux cas : après dix
// tentatives, ou immédiatement sur une erreur permanente. L'op abandonnée reste
// dans Hive sur l'appareil qui l'a saisie et n'existe nulle part ailleurs.
//
// Aucune table financière du restaurant n'était protégée. La seule table
// restaurant des listes était le plan de salle — et « expenses », protégée,
// est celle de l'e-commerce : les dépenses du restaurant vivent dans
// « daily_expenses », avec sa propre boîte Hive.
//
// Trois listes commandent ce comportement, et elles avaient divergé :
// partner_ledger_entries survivait aux erreurs permanentes mais était
// supprimée après dix tentatives ; restaurant_tables survivait aux deux mais
// n'alertait jamais. Une op qui survit sans que personne ne le sache est une
// op perdue avec un délai.
//
// Règle retenue le 19/09/2026 (section 11 de la définition financière) : toute
// table qui porte de l'argent, ou qui sert à en calculer, est protégée des
// TROIS façons.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/database/sync_protected_tables.dart';

/// Les trois protections réunies — c'est le seul état acceptable pour une
/// table d'argent, et c'est ce que l'ancien code ne garantissait pour aucune.
void _expectFullyProtected(String table) {
  expect(survivesPermanentError(table), isTrue,
      reason: '« $table » serait jetée sur erreur permanente');
  expect(survivesRetryCap(table), isTrue,
      reason: '« $table » serait jetée après dix tentatives');
  expect(countsAsStuck(table), isTrue,
      reason: '« $table » survivrait sans que personne ne le sache');
}

void main() {
  group('Les dépenses du restaurant', () {
    test('une dépense quotidienne survit à une erreur permanente', () {
      // LE test rouge : daily_expenses n'est dans aucune des trois listes.
      // Un achat marché de 200 000 F saisi hors-ligne, heurtant une dérive de
      // schéma, disparaissait sans un mot.
      expect(survivesPermanentError('daily_expenses'), isTrue);
    });

    test('elle est protégée des trois façons', () {
      _expectFullyProtected('daily_expenses');
    });

    test('le piège de nommage ne trompe plus', () {
      // « expenses » est l'e-commerce, « daily_expenses » le restaurant. Les
      // deux doivent être protégées ; seule la première l'était.
      _expectFullyProtected('expenses');
      _expectFullyProtected('daily_expenses');
    });
  });

  group('Toutes les tables d\'argent', () {
    test('les seize tables financières du restaurant sont protégées', () {
      for (final t in [
        'daily_expenses', 'losses', 'payments', 'payroll', 'salary_advances',
        'time_records', 'cash_closures', 'ingredients', 'recipe_ingredients',
        'fixed_charges', 'bottle_deposits', 'stock_items', 'staff_penalties',
        'staff_absences', 'staff_contests', 'staff_ratings',
      ]) {
        _expectFullyProtected(t);
      }
    });

    test('celles tracées pendant l\'audit le sont aussi', () {
      // restaurant_activities porte la clé de ventilation sectorielle,
      // incidents crée des pertes, job_titles et staff_settings passent bien
      // par la file (_bgWrite), contrairement à ce que l'audit supposait.
      for (final t in [
        'restaurant_activities', 'incidents', 'job_titles', 'staff_settings',
        'employees',
      ]) {
        _expectFullyProtected(t);
      }
    });

    test('les deux tables PARTAGÉES avec l\'e-commerce le sont aussi', () {
      // Décision du 19/09/2026 : les exclure protégerait les boutiques d'une
      // file qui grossit, au prix de leur laisser perdre des mouvements de
      // stock en silence. hotfix_176 a montré que le scénario est réel.
      _expectFullyProtected('stock_movements');
      _expectFullyProtected('receptions');
    });
  });

  group('Les trois listes ne divergent plus', () {
    test('partner_ledger_entries est protégée des TROIS façons', () {
      // Elle survivait aux erreurs permanentes et était pourtant supprimée
      // après dix tentatives : protection à moitié effective, non documentée.
      _expectFullyProtected('partner_ledger_entries');
    });

    test('le plan de salle alerte enfin l\'utilisateur', () {
      // Protégé des deux abandons depuis hotfix_180, mais absent du compteur
      // qui alimente la bannière : il disparaissait de l'attention.
      _expectFullyProtected('restaurant_tables');
    });

    test('les trois prédicats répondent la même chose, pour TOUTE table', () {
      // C'est l'invariant qui ferme la classe de défaut : trois listes qui
      // doivent dire la même chose finissent par ne plus la dire.
      for (final t in [
        'orders', 'sales', 'expenses', 'daily_expenses', 'payroll',
        'partner_ledger_entries', 'restaurant_tables', 'stock_movements',
        'une_table_inventee_demain', 'products', 'clients',
      ]) {
        expect(survivesPermanentError(t), survivesRetryCap(t),
            reason: '« $t » : permanente ≠ plafond');
        expect(survivesRetryCap(t), countsAsStuck(t),
            reason: '« $t » : plafond ≠ alerte');
      }
    });
  });

  group('Ce qui n\'est PAS protégé', () {
    test('une table sans argent ne l\'est pas', () {
      // La file doit rester purgeable pour tout ce qui se recalcule ou se
      // resynchronise : sinon elle grossit sans raison.
      expect(survivesPermanentError('notifications'), isFalse);
      expect(survivesPermanentError('une_table_inventee_demain'), isFalse);
    });
  });
}
