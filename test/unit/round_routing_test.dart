// Tests du routage des articles vers les postes de service (Lot A).
//
// Ce qui est en jeu : un article routé vers le mauvais poste ne sort jamais.
// Le bon papier part au bar pendant que le client attend son plat, et l'écran
// cuisine ne l'affiche même pas — personne ne voit l'oubli.
//
// `stationFor` lit Hive (produit → secteur) et n'est pas testable en unitaire ;
// la RÈGLE qu'il applique, elle, l'est : c'est `RoundRouting.resolve`.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/round_routing.dart';
import 'package:fortress/features/restaurant/domain/entities/restaurant_activity.dart';

/// Valeurs acceptées par le CHECK SQL de `restaurant_activities.station`
/// (hotfix_144). Une clé hors de cette liste ferait rejeter l'upsert par
/// Postgres et l'opération serait droppée après dix essais, sans bruit.
const _kSqlStations = {
  'cuisine',
  'bar',
  'chawarma',
  'glacier',
  'patisserie',
  'autre',
};

RestaurantActivity _activity({String mode = 'stock', String? station}) =>
    RestaurantActivity(
      id: 'ra_1',
      shopId: 'shop_1',
      name: 'Secteur',
      mode: mode,
      station: station,
      createdAt: DateTime(2026, 7, 28),
    );

void main() {
  group('ServiceStation ↔ SQL', () {
    test('toutes les clés émises existent côté SQL', () {
      for (final s in ServiceStation.values) {
        expect(_kSqlStations, contains(s.key),
            reason: '« ${s.key} » absente du CHECK SQL de station');
      }
    });

    test('fromKey distingue « non précisé » d\'un poste inconnu', () {
      // Les deux valent null — c'est voulu : l'appelant doit retomber sur la
      // déduction par le mode plutôt que d'inventer un poste.
      expect(ServiceStation.fromKey(null), isNull);
      expect(ServiceStation.fromKey(''), isNull);
      expect(ServiceStation.fromKey('   '), isNull);
      expect(ServiceStation.fromKey('sushi'), isNull);
    });

    test('fromKey tolère la casse et les espaces', () {
      expect(ServiceStation.fromKey(' BAR '), ServiceStation.bar);
      expect(ServiceStation.fromKey('Chawarma'), ServiceStation.chawarma);
    });

    test('fromKey retrouve chaque poste par sa clé', () {
      for (final s in ServiceStation.values) {
        expect(ServiceStation.fromKey(s.key), s);
      }
    });
  });

  group('RoundRouting.resolve', () {
    test('le poste déclaré prime sur le mode', () {
      // Tout l'intérêt de hotfix_144 : une pâtisserie est en mode recette mais
      // ne se prépare pas en cuisine. Sans cette priorité, la colonne ne
      // servirait à rien.
      expect(
          RoundRouting.resolve(
              _activity(mode: 'recipe', station: 'patisserie')),
          ServiceStation.patisserie);
      expect(
          RoundRouting.resolve(_activity(mode: 'stock', station: 'cuisine')),
          ServiceStation.cuisine);
    });

    test('sans poste déclaré, le mode décide (comportement d\'avant)', () {
      // Les boutiques déjà en service n'ont pas de `station` : elles doivent
      // continuer à router exactement comme avant.
      expect(RoundRouting.resolve(_activity(mode: 'stock')),
          ServiceStation.bar);
      expect(RoundRouting.resolve(_activity(mode: 'recipe')),
          ServiceStation.cuisine);
    });

    test('un poste inconnu retombe sur la déduction par le mode', () {
      // Cas d'un appareil qui lit une valeur écrite par une version plus
      // récente de l'app : mieux vaut router par le mode que planter.
      expect(RoundRouting.resolve(_activity(mode: 'stock', station: 'sushi')),
          ServiceStation.bar);
    });

    test('sans secteur, tout part en cuisine', () {
      // Choix assumé : un bon qui arrive en cuisine se relaie à la voix, un
      // plat parti au bar par erreur ne sort jamais.
      expect(RoundRouting.resolve(null), ServiceStation.cuisine);
    });
  });

  group('RestaurantActivity — sérialisation du poste', () {
    test('le poste survit à un aller-retour toMap/fromMap', () {
      final a = _activity(mode: 'recipe', station: 'chawarma');
      expect(RestaurantActivity.fromMap(a.toMap()).station, 'chawarma');
    });

    test('une chaîne vide est lue comme « non précisé »', () {
      // Un `station: ''` poussé vers Supabase violerait le CHECK : la
      // normalisation à la lecture empêche qu'il se propage.
      final raw = _activity().toMap()..['station'] = '';
      expect(RestaurantActivity.fromMap(raw).station, isNull);
    });

    test('un enregistrement legacy (sans le champ) reste lisible', () {
      final raw = _activity(mode: 'stock').toMap()
        ..remove('station')
        ..['schema_version'] = 1;
      final migrated = RestaurantActivity.fromMap(raw);
      expect(migrated.station, isNull);
      // Et il route toujours comme avant la migration.
      expect(RoundRouting.resolve(migrated), ServiceStation.bar);
    });

    test('clearStation détache vraiment le poste', () {
      // `copyWith(station: null)` serait un no-op silencieux (résolution par
      // `??`) : repasser une activité sur « Auto » ne marcherait pas.
      final a = _activity(station: 'bar');
      expect(a.copyWith(station: null).station, 'bar');
      expect(a.copyWith(clearStation: true).station, isNull);
    });
  });
}
