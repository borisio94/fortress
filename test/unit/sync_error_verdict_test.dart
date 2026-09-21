// Un parent en retard n'est pas une écriture perdue.
//
// La file de synchronisation abandonne une opération dès qu'elle juge
// l'erreur définitive. Dix codes Postgres étaient classés ainsi, dont
// 23503 — la violation de clé étrangère.
//
// C'EST UNE ERREUR DE CLASSIFICATION. Une clé étrangère manquante dit « le
// parent n'est pas encore là », pas « cette écriture est invalide ». Le parent
// peut arriver au vidage suivant : c'est l'ordre d'envoi qui a manqué, pas la
// donnée.
//
// Le cas est devenu concret le 19/09/2026 : `stock_movements`, `receptions` et
// `incidents` sont protégées, mais leurs parents — `products`,
// `purchase_orders`, `suppliers` — ne le sont pas. Un parent abandonné laisse
// derrière lui un enfant que la base refusera toujours.
//
// L'EXCEPTION NE VAUT QUE SUR UNE TABLE PROTÉGÉE. Ailleurs, 23503 reste
// définitive : sans cette borne, on changerait le comportement de toute la file
// pour régler un cas de bord, et une op réellement invalide se rejouerait sans
// fin sur des tables que personne ne surveille.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/database/sync_error_verdict.dart';

/// Ce que PostgREST rend pour une clé étrangère non satisfaite.
const _fkError = 'PostgrestException(message: insert or update on table '
    '"stock_movements" violates foreign key constraint '
    '"stock_movements_product_id_fkey", code: 23503)';

void main() {
  group('Une clé étrangère manquante', () {
    test('laisse l\'écriture retentable sur une table protégée', () {
      // LE test rouge. Le parent `products` n'est pas protégé : s'il est
      // abandonné, le mouvement de stock qui le référence est refusé à chaque
      // envoi. L'abandonner aussi, c'est perdre le journal de stock — que
      // `reconcileShop` LIT pour reconstruire les quantités.
      expect(isDefinitiveSyncError(_fkError, 'stock_movements'), isFalse);
    });

    test('vaut aussi pour les deux autres tables partagées', () {
      expect(isDefinitiveSyncError(_fkError, 'receptions'), isFalse);
      expect(isDefinitiveSyncError(_fkError, 'incidents'), isFalse);
    });

    test('reste DÉFINITIVE sur une table non protégée', () {
      // La borne de la règle. Sans elle, toute la file se met à rejouer des
      // écritures réellement invalides, sur des tables que rien ne surveille.
      expect(isDefinitiveSyncError(_fkError, 'notifications'), isTrue);
      expect(isDefinitiveSyncError(_fkError, 'products'), isTrue);
      expect(isDefinitiveSyncError(_fkError, 'une_table_inventee'), isTrue);
    });
  });

  group('Les neuf autres codes ne bougent pas', () {
    // L'exception porte sur 23503 et sur rien d'autre. Une dérive de schéma
    // ou un droit refusé ne se résoudra jamais en réessayant, et le fait
    // d'être sur une table protégée n'y change rien : l'op y reste de toute
    // façon, c'est `survivesPermanentError` qui le décide, pas ce verdict.
    const codes = {
      '23505': 'duplicate key',
      '42501': 'permission denied',
      '42502': 'insufficient privilege',
      '23502': 'not null violation',
      '23514': 'contrainte CHECK',
      '42703': 'colonne inconnue',
      'PGRST204': 'colonne absente du cache PostgREST',
      'P0001': 'raise_exception',
      'P0002': 'no_data_found',
    };

    for (final e in codes.entries) {
      test('${e.key} (${e.value}) reste définitive, protégée ou non', () {
        final err = 'PostgrestException(code: ${e.key})';
        expect(isDefinitiveSyncError(err, 'stock_movements'), isTrue,
            reason: '${e.key} ne doit PAS profiter de l\'exception 23503');
        expect(isDefinitiveSyncError(err, 'daily_expenses'), isTrue);
        expect(isDefinitiveSyncError(err, 'notifications'), isTrue);
      });
    }
  });

  group('Ce qui n\'est aucun de ces codes', () {
    test('une panne réseau reste temporaire, partout', () {
      // Comportement d'origine, que l'extraction doit préserver.
      const net = 'SocketException: Failed host lookup';
      expect(isDefinitiveSyncError(net, 'stock_movements'), isFalse);
      expect(isDefinitiveSyncError(net, 'notifications'), isFalse);
    });
  });
}
