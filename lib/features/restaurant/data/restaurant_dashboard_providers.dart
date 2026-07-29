import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/ingredient_service.dart';
import '../../../core/services/restaurant_reporting_service.dart';
import '../../../core/services/stock_item_service.dart';
import '../../../core/storage/hive_boxes.dart';
import '../../dashboard/data/dashboard_providers.dart';

/// Agrégats propres au service en restauration, absents de [DashData].
///
/// Volontairement séparé de `dashboard_providers.dart` : celui-ci alimente le
/// tableau de bord e-commerce, qui ne doit pas porter de calculs de salle.
/// Une commande encore ouverte, prête à afficher dans le tableau de bord.
class OpenOrderLine {
  final String orderId;

  /// « Table 5 », « Emporter #4821 », « Livraison #4821 ».
  final String label;

  /// « En préparation », « Prêt », « En livraison », « Programmée »…
  final String statusLabel;

  /// Étape de service, pour la couleur de la puce : 0 = à traiter,
  /// 1 = en préparation, 2 = prêt / en route.
  final int stage;

  const OpenOrderLine({
    required this.orderId,
    required this.label,
    required this.statusLabel,
    required this.stage,
  });
}

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

  /// Commandes encore ouvertes — état COURANT, hors période : une commande de
  /// la veille non clôturée reste à traiter aujourd'hui.
  final int openCount;

  /// Les plus récentes de ces commandes, pour la liste du tableau de bord.
  final List<OpenOrderLine> openOrders;

  /// Ingrédients + articles de stock au niveau ou sous leur seuil.
  final int lowStockCount;

  const RestaurantDashData({
    this.dineIn = 0,
    this.takeaway = 0,
    this.delivery = 0,
    this.ordersByWeekday = const [0, 0, 0, 0, 0, 0, 0],
    this.inKitchen = 0,
    this.busyTables = 0,
    this.totalTables = 0,
    this.openCount = 0,
    this.openOrders = const [],
    this.lowStockCount = 0,
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

/// Bilan financier restaurant (module finances — Lot 3) : ventes, coût
/// matières, charges, pertes, bénéfice, séries du graphique et résumé par
/// secteur, sur la période courante.
///
/// Même dépendances que [restaurantDashProvider] : un seul sélecteur de
/// période pilote toute la page, et toute mutation Hive (vente encaissée,
/// perte déclarée, charge réglée) rafraîchit le bilan.
final restaurantFinanceProvider =
    Provider.autoDispose.family<RestaurantFinanceReport, String>((ref, shopId) {
  ref.watch(dashSignalProvider);
  final period = ref.watch(dashPeriodProvider);
  final custom = ref.watch(dashCustomRangeProvider);
  final range = period == DashPeriod.custom && custom != null
      ? custom
      : rangeFor(period);
  return RestaurantReportingService.build(shopId, range);
});

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
  var openCount = 0;
  final byWeekday = List<int>.filled(7, 0);

  // Commandes ouvertes collectées avec leur date, pour ne garder que les plus
  // récentes après le parcours (les plus anciennes sont rarement actionnables).
  final open = <({DateTime at, OpenOrderLine line})>[];

  // Nom de table par id — résolu une fois, la liste des tables est courte.
  final tableNames = <String, String>{};
  try {
    for (final raw in HiveBoxes.restaurantTablesBox.values) {
      if (raw['shop_id']?.toString() != shopId) continue;
      final id = raw['id']?.toString();
      if (id == null) continue;
      final name = (raw['name'] ?? '').toString().trim();
      final number = (raw['number'] as num?)?.toInt();
      tableNames[id] =
          name.isNotEmpty ? name : (number == null ? 'Table' : 'Table $number');
    }
  } catch (e) {
    debugPrint('[RestaurantDash] noms de tables err: $e');
  }

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

      // Commandes encore ouvertes : également un état COURANT, indépendant de
      // la période sélectionnée.
      if (!_kClosedStatuses.contains(status)) {
        openCount++;
        final orderId = raw['id']?.toString() ?? '';
        final type = raw['order_type']?.toString();
        final tableId = raw['table_id']?.toString();
        final short = orderId.length <= 4
            ? orderId
            : orderId.substring(orderId.length - 4);
        final label = switch (type) {
          'dine_in' => tableNames[tableId] ?? 'Salle',
          'delivery' => 'Livraison #$short',
          _ => 'Emporter #$short',
        };
        // L'avancement se lit sur les drapeaux de cuisine, pas sur le statut :
        // c'est eux que le service met à jour bon par bon.
        final (String statusLabel, int stage) = raw['kitchen_ready'] == true
            ? (type == 'delivery' ? ('En livraison', 2) : ('Prêt', 2))
            : raw['sent_to_kitchen'] == true
                ? ('En préparation', 1)
                : (status == 'scheduled' ? ('Programmée', 0) : ('À envoyer', 0));
        open.add((
          at: date,
          line: OpenOrderLine(
            orderId: orderId,
            label: label,
            statusLabel: statusLabel,
            stage: stage,
          ),
        ));
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

  // Stock bas : ingrédients + fournitures, même règle que le
  // badge de navigation (un seul chiffre pour l'utilisateur).
  var lowStock = 0;
  try {
    lowStock = IngredientService.forShop(shopId).where((i) => i.isLowStock).length +
        StockItemService.lowStock(shopId).length;
  } catch (e) {
    debugPrint('[RestaurantDash] stock bas err: $e');
  }

  // Les plus récentes en tête, cinq au plus : la carte doit rester lisible.
  open.sort((a, b) => b.at.compareTo(a.at));

  return RestaurantDashData(
    dineIn: dineIn,
    takeaway: takeaway,
    delivery: delivery,
    ordersByWeekday: byWeekday,
    inKitchen: inKitchen,
    busyTables: busy,
    totalTables: total,
    openCount: openCount,
    openOrders: [for (final o in open.take(5)) o.line],
    lowStockCount: lowStock,
  );
});
