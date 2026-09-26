// Tests des incidents de service (Lot E) — la correspondance incident →
// catégorie de perte.
//
// Ce qui est en jeu : le module Pertes se soustrait directement du bénéfice.
// Une catégorie hors du CHECK SQL de `losses` ferait rejeter l'upsert par
// Postgres, et l'opération serait droppée après dix essais — silencieusement.
//
// Le calcul des montants (`materialCostOf`) lit Hive et n'est pas testable en
// unitaire ; la RÈGLE qu'il applique est documentée ici pour qu'elle ne dérive
// pas :
//
//   * plat annulé / raté → COÛT MATIÈRE. Le plat n'a jamais été vendu, donc
//     jamais entré dans le chiffre d'affaires : compter son prix de vente
//     gonflerait la perte d'une marge jamais encaissée.
//   * départ sans payer → MONTANT DE L'ADDITION. La commande est clôturée
//     côté application, la perte doit l'annuler en entier — matière ET marge.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/service_incident_service.dart';

/// Catégories acceptées par le CHECK SQL de `losses`
/// (hotfix_140, étendu par hotfix_141).
const _kSqlCategories = {
  'casse',
  'reste_invendu',
  'plat_mal_fait',
  'non_paye',
  'materiel_endommage',
  'ecart_inventaire',
  'autre',
};

void main() {
  group('Incident → catégorie de perte', () {
    test('toutes les catégories émises existent côté SQL', () {
      // Le garde-fou principal : une valeur hors CHECK est rejetée par
      // Postgres et l'écriture disparaît sans bruit.
      for (final category in ServiceIncidentService.categories.values) {
        expect(_kSqlCategories, contains(category),
            reason: '« $category » absente du CHECK SQL de losses');
      }
    });

    test('une annulation après envoi est un invendu', () {
      // Le plat a été préparé puis jeté : ce n'est ni de la casse ni un plat
      // raté, c'est de la marchandise produite et non consommée.
      expect(ServiceIncidentService.categories['annulation_apres_envoi'],
          'reste_invendu');
    });

    test('un plat raté a sa propre catégorie', () {
      expect(ServiceIncidentService.categories['plat_rate'], 'plat_mal_fait');
    });

    test('un départ sans payer a sa propre catégorie', () {
      expect(
          ServiceIncidentService.categories['depart_sans_payer'], 'non_paye');
    });

    test('les trois incidents sont distincts', () {
      // Les regrouper rendrait les statistiques de pertes inexploitables :
      // on ne saurait plus si on perd par gaspillage ou par impayé.
      final values = ServiceIncidentService.categories.values.toSet();
      expect(values.length, ServiceIncidentService.categories.length);
    });
  });
}
