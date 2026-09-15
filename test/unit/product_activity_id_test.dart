// Tests unitaires du secteur restaurant `activityId` (hotfix_141).
//
// Le champ rattache un plat à une activité connexe (`restaurant_activities`)
// et sert de clé au reporting par secteur. Il traverse QUATRE mappings écrits
// à la main (Hive, ProductModel, Supabase aller, Supabase retour) : un oubli
// dans un seul d'entre eux perd le rattachement en silence — le plat se
// retrouve « sans secteur » au prochain écho realtime, et son chiffre
// d'affaires disparaît du bilan de son activité sans aucune erreur visible.
//
// Vérifie aussi que l'e-commerce reste intact : un produit sans secteur doit
// rester `null` partout, y compris sur les produits legacy sans la clé.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/storage/local_storage_service.dart';
import 'package:fortress/features/inventaire/data/models/product_model.dart';
import 'package:fortress/features/inventaire/domain/entities/product.dart';

Product _dish({String? activityId}) => Product(
      id: 'prod_1',
      storeId: 'shop_1',
      name: 'Chawarma poulet',
      priceSellPos: 2000,
      activityId: activityId,
    );

void main() {
  group('Cas 1 — défaut et copyWith', () {
    test('un produit créé sans secteur n\'est rattaché à rien', () {
      // Non-régression e-commerce : aucune boutique existante ne doit se
      // retrouver avec un secteur inventé.
      const p = Product(id: 'prod_x', storeId: 'shop_1', name: 'Écouteurs');
      expect(p.activityId, isNull);
    });

    test('copyWith conserve le secteur', () {
      // copyWith recopie chaque champ à la main : un oubli détacherait le
      // plat de son secteur à chaque édition.
      expect(_dish(activityId: 'ra_1').copyWith(name: 'Autre').activityId,
          'ra_1');
    });

    test('copyWith ne peut pas détacher par un simple null', () {
      // `null` signifie « inchangé » dans tout le copyWith de Product.
      expect(_dish(activityId: 'ra_1').copyWith(activityId: null).activityId,
          'ra_1');
    });

    test('clearActivity détache explicitement', () {
      expect(_dish(activityId: 'ra_1').copyWith(clearActivity: true).activityId,
          isNull);
    });

    test('props distingue deux plats de secteurs différents', () {
      // Sans ça, changer le secteur ne déclencherait aucun rebuild ni aucune
      // détection de changement à la sauvegarde.
      expect(_dish(activityId: 'ra_1') == _dish(activityId: 'ra_2'), isFalse);
      expect(_dish(activityId: 'ra_1') == _dish(), isFalse);
    });
  });

  group('Cas 2 — aller-retour Hive', () {
    test('le secteur survit à la sérialisation', () {
      final map = LocalStorageService.productToMap(_dish(activityId: 'ra_1'));
      expect(map['activity_id'], 'ra_1');
      expect(LocalStorageService.productFromMap(map).activityId, 'ra_1');
    });

    test('l\'absence de secteur reste nulle', () {
      final map = LocalStorageService.productToMap(_dish());
      expect(LocalStorageService.productFromMap(map).activityId, isNull);
    });

    test('un produit legacy sans la clé reste non rattaché', () {
      // Cas RÉEL : tous les produits déjà en Hive ont été écrits avant
      // hotfix_141 et n'ont pas la clé.
      final legacy = LocalStorageService.productToMap(_dish())
        ..remove('activity_id');
      expect(legacy.containsKey('activity_id'), isFalse);
      expect(LocalStorageService.productFromMap(legacy).activityId, isNull);
    });
  });

  group('Cas 3 — aller-retour ProductModel', () {
    test('fromEntity → toEntity conserve le secteur', () {
      // `product_local_datasource` fait ce round-trip : sans le champ dans
      // les deux sens, le rattachement serait perdu à chaque mise en cache.
      final model = ProductModel.fromEntity(_dish(activityId: 'ra_1'));
      expect(model.activityId, 'ra_1');
      expect(model.toEntity().activityId, 'ra_1');
    });

    test('toMap → fromMap conserve le secteur', () {
      final map = ProductModel.fromEntity(_dish(activityId: 'ra_1')).toMap();
      expect(map['activity_id'], 'ra_1');
      expect(ProductModel.fromMap(map).activityId, 'ra_1');
    });

    test('une map legacy sans la clé reste non rattachée', () {
      final map = ProductModel.fromEntity(_dish()).toMap()
        ..remove('activity_id');
      expect(ProductModel.fromMap(map).activityId, isNull);
    });
  });

  group('Cas 4 — déduction du secteur d\'une vente', () {
    // D3 : le secteur n'est PAS figé dans la commande, il se déduit du
    // produit à l'affichage. Ce comportement est la base du reporting par
    // secteur (Lot 3) — il doit rester explicite et testé.
    String? sectorOf(List<Product> catalogue, String pid) {
      for (final p in catalogue) {
        if (p.id == pid) return p.activityId;
      }
      return null;
    }

    final chawarma = _dish(activityId: 'ra_chawarma');
    const glace = Product(
      id: 'prod_2',
      storeId: 'shop_1',
      name: 'Glace vanille',
      activityId: 'ra_glace',
    );
    const plat = Product(id: 'prod_3', storeId: 'shop_1', name: 'Ndolé');
    final catalogue = [chawarma, glace, plat];

    test('chaque plat rend le secteur de son activité', () {
      expect(sectorOf(catalogue, 'prod_1'), 'ra_chawarma');
      expect(sectorOf(catalogue, 'prod_2'), 'ra_glace');
    });

    test('un plat non rattaché n\'a pas de secteur', () {
      // Il devra tomber dans « Sans secteur » au bilan, jamais dans un
      // secteur arbitraire.
      expect(sectorOf(catalogue, 'prod_3'), isNull);
    });

    test('un produit supprimé du catalogue n\'invente pas de secteur', () {
      expect(sectorOf(catalogue, 'prod_inconnu'), isNull);
      expect(sectorOf(const [], 'prod_1'), isNull);
    });
  });
}
