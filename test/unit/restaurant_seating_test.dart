import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/restaurant_table_service.dart';
import 'package:fortress/features/restaurant/domain/entities/restaurant_table.dart';

/// Capacité de la salle, en PLACES.
///
/// Ce que ces tests protègent : le fait qu'une table à moitié occupée compte
/// pour ce qu'elle est. Compter les TABLES — libre ou occupée — masquerait les
/// chaises encore disponibles, et c'est précisément ce qu'on regarde quand des
/// clients se présentent à l'entrée.
void main() {
  RestaurantTable table({
    required int capacity,
    RestaurantTableStatus status = RestaurantTableStatus.libre,
    int? covers,
    DateTime? reservationTime,
  }) =>
      RestaurantTable(
        id: 'rt_$capacity${status.name}${covers ?? ''}',
        shopId: 'shop_1',
        number: 1,
        name: 'T',
        capacity: capacity,
        status: status,
        covers: covers,
        reservationTime: reservationTime,
        createdAt: DateTime.utc(2026, 8, 6),
      );

  // Réservation encore VIVANTE : l'heure n'est pas atteinte.
  final soon = DateTime.now().add(const Duration(hours: 1));

  // Réservation dont la courtoisie est ÉCOULÉE — la table est libre.
  final longGone =
      DateTime.now().subtract(RestaurantTable.reservationGrace * 2);

  group('RestaurantTableService.computeSeating', () {
    test('salle vide : tout est libre', () {
      final r = RestaurantTableService.computeSeating([
        table(capacity: 4),
        table(capacity: 8),
      ]);
      expect(r.total, 12);
      expect(r.seated, 0);
      expect(r.free, 12);
    });

    test('une table à MOITIÉ occupée laisse ses places restantes', () {
      // Le cas signalé : 8 places, 5 convives → 3 encore disponibles.
      final r = RestaurantTableService.computeSeating([
        table(
            capacity: 8,
            status: RestaurantTableStatus.occupee,
            covers: 5),
      ]);
      expect(r.total, 8);
      expect(r.seated, 5);
      expect(r.free, 3);
    });

    test('occupée SANS couverts renseignés → comptée pleine', () {
      // Hypothèse prudente : annoncer des places qui n'existent pas ferait
      // entrer des clients qu'on ne pourrait pas asseoir.
      final r = RestaurantTableService.computeSeating([
        table(capacity: 6, status: RestaurantTableStatus.occupee),
      ]);
      expect(r.seated, 6);
      expect(r.free, 0);
    });

    test('une table en ADDITION reste occupée', () {
      // Les clients n'ont pas quitté la table parce qu'ils ont demandé
      // l'addition — leurs places ne sont pas encore libres.
      final r = RestaurantTableService.computeSeating([
        table(
            capacity: 4,
            status: RestaurantTableStatus.addition,
            covers: 2),
      ]);
      expect(r.seated, 2);
      expect(r.free, 2);
    });

    test('des couverts au-delà de la capacité ne rendent pas le libre négatif',
        () {
      // Donnée incohérente (saisie manuelle, table rétrécie après coup) : on
      // plafonne plutôt que d'afficher « −3 places libres ».
      final r = RestaurantTableService.computeSeating([
        table(
            capacity: 4,
            status: RestaurantTableStatus.occupee,
            covers: 7),
      ]);
      expect(r.seated, 4);
      expect(r.free, 0);
    });

    test('mélange réaliste : total, assis et libres restent cohérents', () {
      final r = RestaurantTableService.computeSeating([
        table(capacity: 4),
        table(
            capacity: 8,
            status: RestaurantTableStatus.occupee,
            covers: 5),
        table(capacity: 2, status: RestaurantTableStatus.occupee, covers: 2),
        table(
            capacity: 6,
            status: RestaurantTableStatus.reservee,
            reservationTime: soon),
      ]);
      expect(r.total, 20);
      // 5 + 2 + 6 (retenue, sans couverts → comptée pleine)
      expect(r.seated, 13);
      expect(r.free, 7);
      // Invariant : rien ne se perd entre les trois nombres.
      expect(r.seated + r.free, r.total);
    });

    test('une réservation périmée rend ses places à la salle', () {
      // Règle de T5 : la courtoisie écoulée, la table redevient libre SANS
      // qu'aucune écriture n'ait eu lieu. C'est la lecture qui l'annule.
      final r = RestaurantTableService.computeSeating([
        table(
            capacity: 6,
            status: RestaurantTableStatus.reservee,
            reservationTime: longGone),
      ]);
      expect(r.seated, 0);
      expect(r.free, 6);
    });

    test('une réservation SANS heure ne tient pas la table', () {
      // Donnée incohérente (saisie directe en base, version future) : sans
      // cette tolérance, aucune heure ne pouvant être dépassée, la table
      // serait retenue POUR TOUJOURS.
      final r = RestaurantTableService.computeSeating([
        table(capacity: 4, status: RestaurantTableStatus.reservee),
      ]);
      expect(r.seated, 0);
      expect(r.free, 4);
    });

    test('aucune table : tout est à zéro, pas de division ni de négatif', () {
      final r = RestaurantTableService.computeSeating(const []);
      expect(r.total, 0);
      expect(r.seated, 0);
      expect(r.free, 0);
    });
  });
}
