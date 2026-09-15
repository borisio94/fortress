// Tests unitaires de la date d'achat des ingrédients (hotfix_142).
//
// Champ INFORMATIF : il ne doit rien changer au calcul du coût matières, mais
// il traverse Hive et Supabase, et une date perdue à l'aller-retour n'est
// détectable qu'en la relisant après coup — d'où le verrouillage ici.
//
// Le point sensible est le `null` : `copyWith(purchaseDate: null)` veut dire
// « inchangée » dans toute la classe. Sans `clearPurchaseDate`, une date
// effacée par l'utilisateur se réenregistrerait telle quelle.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/entities/ingredient.dart';

Ingredient _ing({DateTime? purchaseDate}) => Ingredient(
      id: 'ig_1',
      shopId: 'shop_1',
      name: 'Riz',
      unit: 'kg',
      costPerUnit: 500,
      quantity: 10,
      purchaseDate: purchaseDate,
      createdAt: DateTime(2026, 7, 1),
    );

void main() {
  group('Défaut et copyWith', () {
    test('un ingrédient créé sans date n\'en porte pas', () {
      expect(_ing().purchaseDate, isNull);
    });

    test('copyWith conserve la date', () {
      final i = _ing(purchaseDate: DateTime(2026, 7, 12));
      expect(i.copyWith(name: 'Riz parfumé').purchaseDate,
          DateTime(2026, 7, 12));
    });

    test('un null seul ne peut pas effacer la date', () {
      final i = _ing(purchaseDate: DateTime(2026, 7, 12));
      expect(i.copyWith(purchaseDate: null).purchaseDate,
          DateTime(2026, 7, 12));
    });

    test('clearPurchaseDate efface explicitement', () {
      final i = _ing(purchaseDate: DateTime(2026, 7, 12));
      expect(i.copyWith(clearPurchaseDate: true).purchaseDate, isNull);
    });
  });

  group('Aller-retour Hive / Supabase', () {
    test('la date survit à la sérialisation, sans l\'heure', () {
      // La colonne est un DATE : on ne doit pas y pousser un timestamp.
      final map = _ing(purchaseDate: DateTime(2026, 7, 12, 15, 42)).toMap();
      expect(map['purchase_date'], '2026-07-12');
      expect(Ingredient.fromMap(map).purchaseDate, DateTime(2026, 7, 12));
    });

    test('une date absente reste nulle', () {
      final map = _ing().toMap();
      expect(map['purchase_date'], isNull);
      expect(Ingredient.fromMap(map).purchaseDate, isNull);
    });

    test('un ingrédient legacy sans la clé reste sans date', () {
      // Cas RÉEL : tous les ingrédients déjà en base ont été écrits avant
      // hotfix_142 et n'ont pas la colonne.
      final legacy = _ing(purchaseDate: DateTime(2026, 7, 12)).toMap()
        ..remove('purchase_date');
      expect(Ingredient.fromMap(legacy).purchaseDate, isNull);
    });

    test('une chaîne vide se lit comme non renseignée', () {
      // Certains chemins d'écriture posent '' au lieu de null ; `DateTime.tryParse('')`
      // renverrait null de toute façon, mais le cas est verrouillé ici.
      final map = _ing().toMap()..['purchase_date'] = '';
      expect(Ingredient.fromMap(map).purchaseDate, isNull);
    });

    test('une date illisible ne fait pas planter la lecture', () {
      // Une ligne corrompue ne doit pas faire disparaître l'ingrédient de la
      // liste : `forShop` n'attrape que les exceptions, pas les mauvaises
      // valeurs silencieuses.
      final map = _ing().toMap()..['purchase_date'] = 'pas-une-date';
      expect(Ingredient.fromMap(map).purchaseDate, isNull);
    });
  });

  group('Aucun effet sur le coût', () {
    test('deux ingrédients ne différant que par la date ont le même coût', () {
      // Le champ est informatif : il ne doit pas s'immiscer dans le calcul.
      final a = _ing(purchaseDate: DateTime(2026, 7, 12));
      final b = _ing(purchaseDate: DateTime(2026, 1, 1));
      expect(a.costPerUnit, b.costPerUnit);
      expect(a.quantity, b.quantity);
      expect(a.isLowStock, b.isLowStock);
    });
  });
}
