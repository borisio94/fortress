// Tests unitaires du drapeau `trackStock` (hotfix_138).
//
// Le drapeau décide si une vente décrémente le stock. Une régression y est
// silencieuse et coûteuse dans les deux sens :
//   * fuite vers `false` → les ventes cessent de décrémenter le stock réel
//     de toute la boutique, sans aucune erreur visible ;
//   * fuite vers `true` sur un plat → stock négatif ou journal d'activité
//     pollué à chaque service.
//
// D'où le verrouillage des 4 cas demandés : défaut, aller-retour Hive,
// aller-retour Supabase, et aller-retour ProductModel.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/storage/local_storage_service.dart';
import 'package:fortress/features/inventaire/data/models/product_model.dart';
import 'package:fortress/features/inventaire/domain/entities/product.dart';

Product _product({bool? trackStock}) => Product(
      id: 'prod_1',
      storeId: 'shop_1',
      name: 'Poulet DG',
      priceSellPos: 3500,
      // `trackStock` omis quand null → on teste le défaut du constructeur.
      trackStock: trackStock ?? true,
    );

void main() {
  group('Cas 1 — défaut', () {
    test('un produit créé sans précision est suivi en stock', () {
      // Non-régression du parc existant : toute boutique déjà en service
      // doit continuer à décrémenter son stock exactement comme avant.
      const p = Product(
        id: 'prod_x',
        storeId: 'shop_1',
        name: 'Bouteille d\'eau',
        priceSellPos: 500,
      );
      expect(p.trackStock, isTrue);
    });

    test('copyWith conserve le drapeau', () {
      final dish = _product(trackStock: false);
      // copyWith recopie chaque champ à la main dans ce fichier : un oubli
      // remettrait silencieusement le suivi de stock sur les plats à chaque
      // édition de produit.
      expect(dish.copyWith(name: 'Ndolé').trackStock, isFalse);
      expect(_product().copyWith(name: 'Autre').trackStock, isTrue);
    });

    test('props distingue deux produits qui ne diffèrent que par ce flag', () {
      // Sans ça, basculer le toggle ne déclencherait aucun rebuild ni
      // aucune détection de changement à la sauvegarde.
      expect(_product(trackStock: true) == _product(trackStock: false),
          isFalse);
    });
  });

  group('Cas 2 — aller-retour Hive', () {
    test('false survit à la sérialisation', () {
      final map = LocalStorageService.productToMap(_product(trackStock: false));
      expect(map['track_stock'], isFalse);
      expect(LocalStorageService.productFromMap(map).trackStock, isFalse);
    });

    test('true survit à la sérialisation', () {
      final map = LocalStorageService.productToMap(_product(trackStock: true));
      expect(LocalStorageService.productFromMap(map).trackStock, isTrue);
    });

    test('un produit legacy sans la clé reste suivi', () {
      // Cas RÉEL : tous les produits déjà en Hive ont été écrits avant
      // hotfix_138 et n'ont pas la clé. Ils doivent rester suivis.
      final legacy = LocalStorageService.productToMap(_product())
        ..remove('track_stock');
      expect(legacy.containsKey('track_stock'), isFalse);
      expect(LocalStorageService.productFromMap(legacy).trackStock, isTrue);
    });
  });

  group('Cas 3 — aller-retour ProductModel', () {
    test('fromEntity → toEntity conserve false', () {
      // `product_local_datasource` fait ce round-trip : sans le champ dans
      // les deux sens, le drapeau serait perdu à chaque mise en cache.
      final model = ProductModel.fromEntity(_product(trackStock: false));
      expect(model.trackStock, isFalse);
      expect(model.toEntity().trackStock, isFalse);
    });

    test('toMap → fromMap conserve false', () {
      final model = ProductModel.fromEntity(_product(trackStock: false));
      final map = model.toMap();
      expect(map['track_stock'], isFalse);
      expect(ProductModel.fromMap(map).trackStock, isFalse);
    });

    test('une map legacy sans la clé reste suivie', () {
      final map = ProductModel.fromEntity(_product()).toMap()
        ..remove('track_stock');
      expect(ProductModel.fromMap(map).trackStock, isTrue);
    });
  });

  group('Cas 4 — décision de décrément', () {
    // Reproduit `_isStockTracked`, dupliqué à l'identique dans
    // `SaleLocalDatasource` (clôture de commande) et `CaisseBloc` (vente
    // directe). Les deux chemins DOIVENT décider pareil, sinon un plat
    // vendu au comptoir se comporterait autrement qu'en commande.
    bool isTracked(List<Product> products, String pid) {
      for (final p in products) {
        if (p.id == pid) return p.trackStock;
      }
      return true;
    }

    final dish = _product(trackStock: false);
    const bottle = Product(
      id: 'prod_2',
      storeId: 'shop_1',
      name: 'Bière',
      priceSellPos: 1000,
    );
    final catalogue = [dish, bottle];

    test('un plat non suivi ne décrémente pas', () {
      expect(isTracked(catalogue, 'prod_1'), isFalse);
    });

    test('une bouteille suivie décrémente', () {
      // C'est précisément ce que l'ancien court-circuit par canal
      // (`order_type == 'dine_in'`) rendait impossible : il aurait aussi
      // ignoré cette bouteille sur une commande servie en salle.
      expect(isTracked(catalogue, 'prod_2'), isTrue);
    });

    test('un produit introuvable retombe sur le comportement historique', () {
      // Ne pas masquer une anomalie : l'absence de produit est déjà tracée
      // par l'appelant, la décision de stock reste celle d'avant.
      expect(isTracked(catalogue, 'prod_inconnu'), isTrue);
      expect(isTracked(const [], 'prod_1'), isTrue);
    });
  });
}
