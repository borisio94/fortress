// Une opération bloquée se nomme par sa nature, jamais par sa table.
//
// La bannière annonçait « N vente(s)/dépense(s) bloquée(s) ». La phrase tenait
// tant que trois tables seulement étaient surveillées. Dès qu'on en protège une
// vingtaine, elle devient fausse — un pointage n'est ni une vente ni une
// dépense — et la solution évidente, nommer la table, donnerait
// « staff_penalties bloquée » à un commerçant.
//
// Sept natures couvrent tout. Une table inconnue retombe sur « Autres », jamais
// sur son nom technique : un libellé vague est préférable à un libellé
// incompréhensible.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/database/sync_op_nature.dart';

void main() {
  group('Nature d\'une table', () {
    test('une vente est une vente', () {
      expect(syncNatureOf('orders'), SyncOpNature.ventes);
      expect(syncNatureOf('sales'), SyncOpNature.ventes);
    });

    test('les deux tables de dépenses tombent dans la même nature', () {
      // C'est le piège de nommage de la section 11 : `expenses` est
      // l'e-commerce, `daily_expenses` le restaurant. Pour celui qui lit la
      // bannière, ce sont les mêmes dépenses.
      expect(syncNatureOf('expenses'), SyncOpNature.depenses);
      expect(syncNatureOf('daily_expenses'), SyncOpNature.depenses);
    });

    test('un pointage relève du personnel, pas d\'une vente', () {
      expect(syncNatureOf('time_records'), SyncOpNature.personnel);
      expect(syncNatureOf('staff_penalties'), SyncOpNature.personnel);
      expect(syncNatureOf('payroll'), SyncOpNature.personnel);
    });

    test('une table INCONNUE ne rend jamais son nom', () {
      // Le défaut du switch actuel : son `_` rend le nom brut de la table.
      final n = syncNatureOf('une_table_inventee_demain');
      expect(n, SyncOpNature.autres);
      expect(n.label, 'Autres');
      expect(n.label.contains('_'), isFalse);
    });

    test('AUCUN libellé ne ressemble à un nom de table', () {
      // Garde-fou : un libellé avec un tiret bas serait un nom technique qui a
      // fui jusqu'à l'écran.
      for (final n in SyncOpNature.values) {
        expect(n.label.contains('_'), isFalse, reason: '${n.name} : ${n.label}');
        expect(n.label.isNotEmpty, isTrue);
      }
    });

    test('aucune table n\'appartient à DEUX natures', () {
      // Sinon le comptage dépendrait de l'ordre d'itération de la map.
      final seen = <String>{};
      for (final tables in kSyncNatureTables.values) {
        for (final t in tables) {
          expect(seen.add(t), isTrue, reason: '« $t » est classée deux fois');
        }
      }
    });
  });

  group('Comptage par nature', () {
    test('regroupe et trie du plus nombreux au moins nombreux', () {
      final out = syncCountsByNature([
        'daily_expenses', 'daily_expenses', 'daily_expenses',
        'time_records', 'time_records',
        'orders',
      ]);
      expect(out.first.nature, SyncOpNature.depenses);
      expect(out.first.count, 3);
      expect(out[1].nature, SyncOpNature.personnel);
      expect(out[1].count, 2);
      expect(out.last.nature, SyncOpNature.ventes);
      expect(out.last.count, 1);
    });

    test('à égalité, l\'ordre reste stable', () {
      // Sans tri secondaire, deux natures ex æquo permuteraient à chaque
      // rafraîchissement de la bannière — qui poll toutes les 3 secondes.
      final a = syncCountsByNature(['orders', 'daily_expenses']);
      final b = syncCountsByNature(['daily_expenses', 'orders']);
      expect(a.map((e) => e.nature).toList(),
          b.map((e) => e.nature).toList());
    });

    test('une file vide ne rend rien', () {
      expect(syncCountsByNature(const []), isEmpty);
    });

    test('les tables inconnues se regroupent sous Autres', () {
      final out = syncCountsByNature(['truc', 'machin']);
      expect(out.single.nature, SyncOpNature.autres);
      expect(out.single.count, 2);
    });
  });
}
