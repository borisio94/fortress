// T01 et T02 — création de boutique.
//
// Statut : SKIP volontaire — les deux invariants sont enforcés CÔTÉ
// SERVEUR PostgreSQL et ne peuvent pas être validés en pure unité Dart :
//
// T01 — owner assigné automatiquement avec is_owner=true :
//   La création d'une boutique fait `INSERT INTO shop_memberships` avec
//   role='owner' (cf. lib/core/database/app_database.dart:870-871). La
//   colonne `is_owner` est ensuite POSÉE par le trigger SQL auto-sync
//   `trg_enforce_is_owner` (supabase/hotfix_025_is_owner_column.sql:42-74)
//   qui dérive `NEW.is_owner := (NEW.role = 'owner')` à chaque INSERT/UPDATE.
//   Aucune ligne Dart ne touche à `is_owner` pendant la création — le
//   trigger fait foi. Tester cet invariant requiert une instance Postgres
//   avec le hotfix appliqué.
//
// T02 — shop_id généré en UUID valide :
//   Le shop_id vient de `gen_random_uuid()` côté Postgres
//   (cf. row['id'] dans AppDatabase.createShop:864-868). Aucun UUID n'est
//   généré côté Dart pour shops.id — la donnée arrive du serveur.
//
// Pour valider ces deux contrats, écrire un test d'intégration contre une
// instance Supabase de test (idéalement isolée par projet) qui :
//   1. Appelle createShop(...).
//   2. Vérifie que la row shop_memberships créée a is_owner=true.
//   3. Vérifie que le shop_id retourné matche la regex UUID v4.
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Création boutique', () {
    test('T01 — owner is_owner=true (côté SQL, voir hotfix_025)',
        () {}, skip: 'Trigger SQL — non testable en unité Dart pure');

    test('T02 — shop_id en UUID valide (côté Postgres gen_random_uuid)',
        () {}, skip: 'gen_random_uuid() Postgres — non testable en unité');
  });
}
