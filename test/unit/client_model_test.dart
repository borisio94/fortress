// Tests unitaires purs de ClientModel — sérialisation is_archived (hotfix_016).
//
// Vérifie que `isArchived` survit aux 4 conversions (fromMap/toMap,
// fromEntity/toEntity) et que les anciens enregistrements Hive sans la
// colonne sont relus en `false` (migration rétroactive tolérante).
// Aucun Hive ni Supabase : ClientModel est du Dart pur.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/crm/data/models/client_model.dart';
import 'package:fortress/features/crm/domain/entities/client.dart';

void main() {
  group('ClientModel — is_archived (hotfix_016)', () {
    test('fromMap : ancien enregistrement SANS is_archived → false', () {
      final m = ClientModel.fromMap({
        'id': 'c1',
        'store_id': 'shop1',
        'name': 'Ancien Client',
        'created_at': '2024-01-01T00:00:00.000Z',
        // pas de clé is_archived (legacy)
      });
      expect(m.isArchived, isFalse);
    });

    test('fromMap : is_archived = true est lu', () {
      final m = ClientModel.fromMap({
        'id': 'c2',
        'store_id': 'shop1',
        'name': 'Client Archivé',
        'created_at': '2024-01-01T00:00:00.000Z',
        'is_archived': true,
      });
      expect(m.isArchived, isTrue);
    });

    test('fromMap : is_archived = null → false', () {
      final m = ClientModel.fromMap({
        'id': 'c3',
        'store_id': 'shop1',
        'name': 'Client Null',
        'created_at': '2024-01-01T00:00:00.000Z',
        'is_archived': null,
      });
      expect(m.isArchived, isFalse);
    });

    test('toMap : écrit toujours is_archived', () {
      const m = ClientModel(
        id: 'c4',
        storeId: 'shop1',
        name: 'X',
        createdAt: '2024-01-01T00:00:00.000Z',
        isArchived: true,
      );
      final map = m.toMap();
      expect(map.containsKey('is_archived'), isTrue);
      expect(map['is_archived'], isTrue);
    });

    test('round-trip Map : true → toMap → fromMap conserve la valeur', () {
      const original = ClientModel(
        id: 'c5',
        storeId: 'shop1',
        name: 'RoundTrip',
        createdAt: '2024-01-01T00:00:00.000Z',
        isArchived: true,
      );
      final back = ClientModel.fromMap(original.toMap());
      expect(back.isArchived, isTrue);
    });

    test('round-trip Entity : isArchived conservé fromEntity/toEntity', () {
      final entity = Client(
        id: 'c6',
        storeId: 'shop1',
        name: 'EntityRoundTrip',
        createdAt: DateTime.parse('2024-01-01T00:00:00.000Z'),
        isArchived: true,
      );
      final back = ClientModel.fromEntity(entity).toEntity();
      expect(back.isArchived, isTrue);
    });

    test('défaut : un client neuf n\'est pas archivé', () {
      const m = ClientModel(
        id: 'c7',
        storeId: 'shop1',
        name: 'Neuf',
        createdAt: '2024-01-01T00:00:00.000Z',
      );
      expect(m.isArchived, isFalse);
    });
  });
}
