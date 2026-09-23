// Le tiroir de navigation, regroupé en familles — et l'e-commerce intact.
//
// Onze entrées à plat se parcourent ; elles ne se visent pas. Quatre blocs
// nommés — SERVICE, GESTION, ÉQUIPE, puis le reste — rendent le tiroir visable
// pour un serveur qui l'ouvre trente fois par service.
//
// LE TEST QUI COMPTE LE PLUS EST LE TROISIÈME. `sectorGroups` est un champ
// additif : un item qui ne le porte pas garde `group`, donc l'e-commerce ne
// bouge pas PAR CONSTRUCTION. C'est cette propriété qui est vérifiée ici, et
// c'est elle qui autorise à regrouper un secteur sans toucher l'autre.
//
// Même famille que `shell_nav_role_test` : on lit la liste déclarative, sans
// Hive ni widget.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/config/restaurant_mode.dart';
import 'package:fortress/core/utils/shop_monogram.dart';
import 'package:fortress/shared/navigation/shell_nav_items.dart';

/// Les entrées visibles dans ce secteur, dans l'ordre de déclaration.
List<ShellNavItem> _for(String sector) =>
    kShellNavItems.where((i) => i.matchesSector(sector)).toList();

/// Les routes d'un groupe, dans l'ordre où le tiroir les rendra.
List<String> _routesOfGroup(String sector, int group) => [
      for (final i in _for(sector))
        if (!i.footer && i.groupFor(sector) == group) i.route('s1'),
    ];

void main() {
  group('La messagerie sort du restaurant', () {
    ShellNavItem messagerie() => kShellNavItems
        .firstWhere((i) => i.route('s1') == '/shop/s1/tickets');

    test('ABSENTE en restauration', () {
      // Personne n'ouvre de ticket depuis une salle. L'entrée encombrait un
      // tiroir que le service parcourt à la main, entre deux tables.
      for (final s in kRestaurantSectors) {
        expect(messagerie().matchesSector(s), isFalse,
            reason: 'Messagerie visible dans le secteur « $s »');
      }
    });

    test('PRÉSENTE en e-commerce', () {
      expect(messagerie().matchesSector('ecommerce'), isTrue);
    });

    test('la route, elle, reste joignable', () {
      // Le masquage est COSMÉTIQUE, comme pour les neuf entrées e-commerce
      // déjà masquées en restauration : aucun garde de secteur au routeur.
      // C'est dit ici pour que personne ne prenne ce lot pour une fermeture.
      expect(messagerie().route('s1'), '/shop/s1/tickets');
    });
  });

  group('SERVICE passe en tête, dans son ordre', () {
    test('Plan de salle · Menu · Commandes, et rien d\'autre', () {
      // L'ORDRE N'EST PAS ALPHABÉTIQUE, c'est celui du service : la salle, la
      // carte, les commandes. `navGroups` trie par NUMÉRO de groupe et
      // conserve l'ordre de déclaration à l'intérieur — cet ordre se joue donc
      // dans `kShellNavItems`, et nulle part ailleurs.
      //
      // Ce test empêche qu'un ajout futur remette le tableau de bord en tête.
      expect(_routesOfGroup('restaurant', 1), [
        '/shop/s1/restaurant/tables',
        '/shop/s1/inventaire',
        '/shop/s1/caisse/orders',
      ]);
    });

    test('GESTION vient ensuite, tableau de bord d\'abord', () {
      expect(_routesOfGroup('restaurant', 2), [
        '/shop/s1/dashboard',
        '/shop/s1/restaurant/stock',
        '/shop/s1/restaurant/finances',
      ]);
    });

    test('ÉQUIPE ferme la marche', () {
      expect(_routesOfGroup('restaurant', 3), [
        '/shop/s1/restaurant/personnel',
        '/shop/s1/employees',
      ]);
    });

    test('les trois familles portent un intitulé, la quatrième non', () {
      expect(navSectionLabel(1, 'restaurant'), 'SERVICE');
      expect(navSectionLabel(2, 'restaurant'), 'GESTION');
      expect(navSectionLabel(3, 'restaurant'), 'ÉQUIPE');
      // Le groupe 4 ne porte que le Hub central : une entrée seule n'a pas
      // besoin d'un titre de famille.
      expect(navSectionLabel(4, 'restaurant'), isNull);
    });

    test('les trois secteurs de restauration sont couverts', () {
      // `kRestaurantSectors` en compte trois. N'en couvrir qu'un rangerait un
      // fast-food comme une boutique.
      for (final s in kRestaurantSectors) {
        expect(navSectionLabel(1, s), 'SERVICE', reason: 'secteur « $s »');
      }
    });
  });

  group('L\'E-COMMERCE NE BOUGE PAS', () {
    test('le tableau de bord reste en groupe 1', () {
      // LE test de ce lot. Le tableau de bord est PARTAGÉ : il passe en
      // GESTION au restaurant sans quitter la tête en e-commerce. Si
      // `sectorGroups` cessait d'être additif, c'est ici que ça se verrait.
      final dash = kShellNavItems
          .firstWhere((i) => i.route('s1') == '/shop/s1/dashboard');
      expect(dash.groupFor('ecommerce'), 1);
      expect(dash.groupFor('restaurant'), 2);
      // Et le champ brut, celui que lisent les appelants sans secteur.
      expect(dash.group, 1);
    });

    test('aucun intitulé de famille en e-commerce', () {
      // Les familles décrivent un restaurant. « SERVICE » au-dessus de la
      // Caisse d'une boutique serait un contresens.
      for (var g = 1; g <= 5; g++) {
        expect(navSectionLabel(g, 'ecommerce'), isNull);
        expect(navSectionLabel(g, 'retail'), isNull);
      }
    });

    test('sans secteur, tout item retombe sur son groupe brut', () {
      // Le défaut `sector: ''` de `navGroups` rend le comportement d'origine.
      for (final i in kShellNavItems) {
        expect(i.groupFor(''), i.group,
            reason: 'un item dévie de `group` pour le secteur vide');
      }
    });

    test('l\'ordre des entrées e-commerce est inchangé', () {
      // Les trois entrées déplacées en tête portent `sectorIn:
      // kRestaurantSectors` : elles sont filtrées avant le tri, donc l'ordre
      // relatif des entrées e-commerce entre elles ne change pas.
      final ecom = _for('ecommerce').map((i) => i.route('s1')).toList();
      expect(ecom.indexOf('/shop/s1/dashboard'), 0);
      expect(ecom.indexOf('/shop/s1/caisse'),
          lessThan(ecom.indexOf('/shop/s1/inventaire')));
      expect(ecom.indexOf('/shop/s1/inventaire'),
          lessThan(ecom.indexOf('/shop/s1/crm')));
    });
  });

  group('Le monogramme de la boutique', () {
    test('un nom simple donne son initiale', () {
      expect(shopMonogram('Fortress'), 'F');
    });

    test('deux mots donnent deux lettres', () {
      expect(shopMonogram('Chez Awa'), 'CA');
      expect(shopMonogram('Mr original base'), 'MO');
    });

    test('LE BOUCLIER RESTE LE REPLI quand le nom ne donne rien', () {
      // La règle validée : un monogramme sans lettres serait pire que le
      // pictogramme générique. `null` = on retombe sur le logo Fortress.
      expect(shopMonogram(null), isNull);
      expect(shopMonogram(''), isNull);
      expect(shopMonogram('   '), isNull);
      expect(shopMonogram('★ ☆ ★'), isNull);
    });

    test('la ponctuation est ignorée, pas la lettre qui suit', () {
      expect(shopMonogram('★ Resto ★'), 'R');
      expect(shopMonogram('«Awa»'), 'A');
    });

    test('un chiffre initial compte — les enseignes en portent', () {
      expect(shopMonogram('24/7 Shop'), '2S');
    });

    test('les accents comptent comme des lettres', () {
      expect(shopMonogram('Éléphant'), 'É');
    });
  });
}
