// Ce que montre la page Menu (`MenuView`) — la carte ou les plats retirés,
// filtrés par catégorie et par recherche, les comptes d'onglets et le cas
// d'écran vide. Logique sortie de la page le 26/09/2026 (lot « classes
// géantes ») : la page vit sous `AppScaffold` et ne se monte pas en test.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/inventaire/domain/entities/product.dart';
import 'package:fortress/features/restaurant/domain/menu_view.dart';

Product dish(
  String name, {
  String? category,
  String? description,
  bool active = true,
  bool draft = false,
  bool deleted = false,
}) =>
    Product(
      id: 'p_$name',
      storeId: 'shop1',
      name: name,
      categoryId: category,
      description: description,
      isActive: active,
      status: draft ? ProductStatus.draft : ProductStatus.available,
      deletedAt: deleted ? DateTime(2026) : null,
    );

List<String> names(List<Product> l) => [for (final p in l) p.name];

void main() {
  final menu = [
    dish('Ndolè', category: 'Plats', description: 'Feuilles amères, crevettes'),
    dish('Poulet DG', category: 'plats'),
    dish('Koki', category: 'Entrées'),
    dish('Bière', category: 'Boissons'),
    dish('Eru', category: 'Plats', active: false),
    dish('Brouillon', category: 'Plats', draft: true),
    dish('Supprimé', category: 'Plats', deleted: true),
    dish('Sans catégorie'),
  ];

  group('carte et plats retirés', () {
    test('la carte ne garde que les plats vendables', () {
      expect(names(const MenuView(all: []).products), isEmpty);
      expect(names(MenuView(all: menu).products),
          ['Ndolè', 'Poulet DG', 'Koki', 'Bière', 'Sans catégorie']);
    });

    test('décochés, brouillons et supprimés sont « retirés »', () {
      expect(names(MenuView(all: menu).retired),
          ['Eru', 'Brouillon', 'Supprimé']);
    });

    test('la source suit le mode', () {
      expect(MenuView(all: menu).source, hasLength(5));
      expect(names(MenuView(all: menu, showRetired: true).source),
          ['Eru', 'Brouillon', 'Supprimé']);
    });
  });

  group('catégories', () {
    test('« Plats » et « plats » font un seul onglet, trié', () {
      expect(MenuView(all: menu).categories,
          ['Boissons', 'Entrées', 'Plats']);
    });

    test('les comptes : total sous null, « plats » compté sous « Plats », '
        'sans catégorie hors onglet', () {
      expect(MenuView(all: menu).categoryCounts, {
        null: 5,
        'Plats': 2,
        'Entrées': 1,
        'Boissons': 1,
      });
    });

    test('en mode retirés, les onglets décrivent les plats retirés', () {
      final v = MenuView(all: menu, showRetired: true);
      expect(v.categories, ['Plats']);
      expect(v.categoryCounts, {null: 3, 'Plats': 3});
    });

    test('filtrer une catégorie la prend à la casse près', () {
      expect(names(MenuView(all: menu, category: 'Plats').visible),
          ['Ndolè', 'Poulet DG']);
      expect(names(MenuView(all: menu, category: 'PLATS').visible),
          ['Ndolè', 'Poulet DG']);
    });
  });

  group('recherche', () {
    test('sur le nom, sans casse, espaces rognés', () {
      expect(names(MenuView(all: menu, query: '  poulet ').visible),
          ['Poulet DG']);
    });

    test('sur la description aussi', () {
      expect(names(MenuView(all: menu, query: 'CREVETTES').visible),
          ['Ndolè']);
    });

    test('combinée à la catégorie', () {
      expect(
          MenuView(all: menu, category: 'Boissons', query: 'ndolè').visible,
          isEmpty);
    });
  });

  group('écran vide', () {
    test('aucun plat : carte vide, même avec une recherche ou une catégorie '
        'restées en mémoire', () {
      const v = MenuView(all: [], category: 'Plats', query: 'poulet');
      expect(v.isEmptyMenu, isTrue);
      expect(v.isSearching, isFalse);
      expect(v.effectiveCategory, isNull);
      expect(v.emptyKind, MenuEmptyKind.emptyMenu);
    });

    test('une recherche sans résultat', () {
      final v = MenuView(all: menu, query: 'pizza');
      expect(v.visible, isEmpty);
      expect(v.emptyKind, MenuEmptyKind.noMatch);
    });

    test('une catégorie sans plat', () {
      final v = MenuView(all: menu, category: 'Desserts');
      expect(v.visible, isEmpty);
      expect(v.effectiveCategory, 'Desserts');
      expect(v.emptyKind, MenuEmptyKind.emptyCategory);
    });

    test('tous les plats retirés : ce n’est pas une carte vide', () {
      final v = MenuView(all: [dish('Eru', active: false)]);
      expect(v.isAllRetired, isTrue);
      expect(v.emptyKind, MenuEmptyKind.allRetired);
    });

    test('mode retirés sans plat retiré', () {
      final v = MenuView(all: [dish('Koki')], showRetired: true);
      expect(v.emptyKind, MenuEmptyKind.noRetired);
      expect(v.isAllRetired, isFalse);
    });

    test('la recherche l’emporte sur le mode retirés', () {
      final v = MenuView(
          all: [dish('Eru', active: false)], showRetired: true, query: 'x');
      expect(v.emptyKind, MenuEmptyKind.noMatch);
    });
  });
}
