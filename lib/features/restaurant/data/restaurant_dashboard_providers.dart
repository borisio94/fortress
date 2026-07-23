import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/hive_boxes.dart';
import '../../dashboard/data/dashboard_providers.dart';

/// Agrégats propres au service en restauration, absents de [DashData].
///
/// Volontairement séparé de `dashboard_providers.dart` : celui-ci alimente le
/// tableau de bord e-commerce, qui ne doit pas porter de calculs de salle.
class RestaurantDashData {
  /// Nombre de commandes par canal, sur la période sélectionnée.
  final int dineIn;
  final int takeaway;
  final int delivery;

  /// Commandes par jour de la semaine, index 0 = lundi … 6 = dimanche.
  final List<int> ordersByWeekday;

  /// Bons actuellement en cuisine (envoyés, pas encore prêts) — instantané,
  /// indépendant de la période : c'est un état courant, pas un historique.
  final int inKitchen;

  /// Tables actuellement occupées ou en attente d'addition.
  final int busyTables;
  final int totalTables;

  const RestaurantDashData({
    this.dineIn = 0,
    this.takeaway = 0,
    this.delivery = 0,
    this.ordersByWeekday = const [0, 0, 0, 0, 0, 0, 0],
    this.inKitchen = 0,
    this.busyTables = 0,
    this.totalTables = 0,
  });

  int get totalOrders => dineIn + takeaway + delivery;

  /// Part d'un canal en pourcentage. 0 si aucune commande — évite une
  /// division par zéro sur une boutique qui n'a encore rien vendu.
  double pctOf(int count) =>
      totalOrders == 0 ? 0 : (count / totalOrders) * 100;
}

/// Libellés courts des jours, lundi en tête (aligné sur `DateTime.weekday`).
const List<String> kWeekdayLabels = [
  'Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim',
];

/// Statuts qui retirent une commande des comptages « en cours ».
const Set<String> _kClosedStatuses = {
  'completed', 'cancelled', 'refused', 'refunded',
};

/// Agrégats restaurant pour la boutique [shopId], sur la période courante.
///
/// Écoute `dashSignalProvider` et `dashPeriodProvider` comme le tableau de
/// bord e-commerce, pour que le sélecteur de période pilote les deux d'un
/// seul geste et qu'une mutation Hive rafraîchisse l'écran.
final restaurantDashProvider =
    Provider.autoDispose.family<RestaurantDashData, String>((ref, shopId) {
  ref.watch(dashSignalProvider);
  final period = ref.watch(dashPeriodProvider);
  final custom = ref.watch(dashCustomRangeProvider);
  final range = period == DashPeriod.custom && custom != null
      ? custom
      : rangeFor(period);

  var dineIn = 0, takeaway = 0, delivery = 0;
  var inKitchen = 0;
  final byWeekday = List<int>.filled(7, 0);

  // Fenêtre glissante de 7 jours pour l'histogramme, indépendante de la
  // période choisie : « commandes par jour de la semaine » n'a de sens que
  // sur une semaine, alors que les KPI peuvent porter sur le mois ou l'année.
  final now = DateTime.now();
  final weekFrom = DateTime(now.year, now.month, now.day)
      .subtract(const Duration(days: 6));

  try {
    for (final raw in HiveBoxes.ordersBox.values) {
      if (raw['shop_id']?.toString() != shopId) continue;
      final deleted = raw['deleted_at'];
      if (deleted != null && deleted.toString().isNotEmpty) continue;

      final status = raw['status']?.toString() ?? '';

      // Date effective : une commande encaissée compte le jour de son
      // encaissement, pas celui de sa prise — sinon un service à cheval sur
      // minuit basculerait de jour.
      final rawDate = raw['completed_at'] ?? raw['created_at'];
      final date = rawDate == null
          ? null
          : DateTime.tryParse(rawDate.toString())?.toLocal();
      if (date == null) continue;

      // Bons en cuisine : état COURANT, hors période.
      if (raw['sent_to_kitchen'] == true &&
          raw['kitchen_ready'] != true &&
          !_kClosedStatuses.contains(status)) {
        inKitchen++;
      }

      if (!date.isBefore(weekFrom)) {
        byWeekday[(date.weekday - 1) % 7]++;
      }

      // Répartition par canal : sur la période, commandes encaissées
      // uniquement — mélanger les annulées fausserait les parts.
      if (date.isBefore(range.from) || date.isAfter(range.to)) continue;
      if (status != 'completed') continue;

      switch (raw['order_type']?.toString()) {
        case 'dine_in':
          dineIn++;
        case 'delivery':
          delivery++;
        default:
          // `takeaway` explicite ET valeur absente : les commandes
          // antérieures à hotfix_137 n'ont pas de canal et sont à emporter
          // par défaut, conformément au DEFAULT de la colonne.
          takeaway++;
      }
    }
  } catch (e) {
    debugPrint('[RestaurantDash] agrégation err: $e');
  }

  var busy = 0, total = 0;
  try {
    for (final raw in HiveBoxes.restaurantTablesBox.values) {
      if (raw['shop_id']?.toString() != shopId) continue;
      total++;
      final st = raw['status']?.toString();
      if (st == 'occupee' || st == 'addition') busy++;
    }
  } catch (e) {
    debugPrint('[RestaurantDash] tables err: $e');
  }

  return RestaurantDashData(
    dineIn: dineIn,
    takeaway: takeaway,
    delivery: delivery,
    ordersByWeekday: byWeekday,
    inKitchen: inKitchen,
    busyTables: busy,
    totalTables: total,
  );
});
