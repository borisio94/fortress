import 'package:flutter/foundation.dart' show debugPrint;

import '../../features/dashboard/data/dashboard_providers.dart' show DashRange;
import '../storage/hive_boxes.dart';
import '../storage/local_storage_service.dart';
import 'activity_service.dart';
import 'fixed_charge_service.dart';
import 'loss_service.dart';
import 'recipe_service.dart';

/// Résultat par secteur d'activité (`restaurant_activities`).
///
/// Les charges fixes et les pertes n'y figurent pas : elles ne sont pas
/// rattachables à un secteur (un loyer ne se découpe pas entre le bar et la
/// cuisine). La ligne s'arrête donc à la MARGE BRUTE — ventes moins matières.
class SectorLine {
  /// `null` = plats non rattachés à une activité.
  final String? activityId;
  final String name;
  final double revenue;
  final double materialCost;

  /// Ventes du secteur par bucket de la période (graphique).
  final List<double> revenueSeries;

  /// Coût matières du secteur par bucket.
  final List<double> costSeries;

  const SectorLine({
    required this.activityId,
    required this.name,
    required this.revenue,
    required this.materialCost,
    required this.revenueSeries,
    required this.costSeries,
  });

  double get margin => revenue - materialCost;

  /// Marge en % du chiffre d'affaires (0 si aucune vente).
  double get marginRate => revenue <= 0 ? 0 : (margin / revenue) * 100;
}

/// Bilan financier d'une boutique de restauration sur une période.
///
/// Toutes les séries ont la même longueur (`range.buckets`) et le même
/// découpage que les libellés [labels] — l'axe du graphique est commun.
class RestaurantFinanceReport {
  final DashRange range;
  final List<String> labels;

  /// Ventes encaissées (lignes de commandes clôturées).
  final double revenue;

  /// Coût matières des plats vendus (fiche recette, ou coût matière saisi).
  final double materialCost;

  /// Charges fixes imputables à la période (FCFA).
  final int charges;

  /// Pertes déclarées sur la période (FCFA).
  final int losses;

  /// Masse salariale de la période. Toujours 0 tant que PR-D (employés +
  /// paie) n'est pas livrée : le champ existe pour que la formule du bénéfice
  /// soit complète et n'ait pas à changer le jour où la paie arrive.
  final int payroll;

  final List<double> revenueSeries;

  /// Dépenses par bucket = coût matières + charges fixes (+ paie à terme).
  final List<double> expenseSeries;

  final List<double> lossSeries;

  /// Un secteur par activité, plus « Sans secteur » si des plats non
  /// rattachés ont été vendus. Trié par chiffre d'affaires décroissant.
  final List<SectorLine> sectors;

  const RestaurantFinanceReport({
    required this.range,
    required this.labels,
    required this.revenue,
    required this.materialCost,
    required this.charges,
    required this.losses,
    required this.payroll,
    required this.revenueSeries,
    required this.expenseSeries,
    required this.lossSeries,
    required this.sectors,
  });

  /// Tout ce qui sort, hors pertes : matières + charges fixes + paie.
  double get expenses => materialCost + charges + payroll;

  /// Marge brute : ventes − matières. Ce que dégage la carte avant charges.
  double get grossMargin => revenue - materialCost;

  /// Bénéfice net = ventes − matières − charges − pertes − paie.
  double get netProfit => revenue - expenses - losses;

  /// Taux de marge brute en % du chiffre d'affaires.
  double get marginRate => revenue <= 0 ? 0 : (grossMargin / revenue) * 100;

  /// Bénéfice par bucket, déduit des trois autres séries — elles restent donc
  /// forcément cohérentes entre elles à l'écran.
  List<double> get profitSeries => [
        for (var i = 0; i < revenueSeries.length; i++)
          revenueSeries[i] - expenseSeries[i] - lossSeries[i],
      ];

  /// Rien à montrer : aucun mouvement financier sur la période.
  bool get isEmpty => revenue == 0 && expenses == 0 && losses == 0;
}

/// Moteur de reporting financier restaurant (module finances — Lot 3).
///
/// Service statique et SANS ÉTAT (décision D2) : il lit Hive et rend un
/// [RestaurantFinanceReport]. Aucun cache interne — c'est le provider Riverpod
/// qui gère la durée de vie et le rafraîchissement.
///
/// Le secteur d'une vente est DÉDUIT du produit (décision D3) : rien n'est
/// figé dans la commande, donc déplacer un plat d'activité réétiquette son
/// historique.
class RestaurantReportingService {
  RestaurantReportingService._();

  /// Libellé des ventes hors activité.
  static const String noSectorLabel = 'Sans secteur';

  /// Construit le bilan de [shopId] sur [range]. Ne lève jamais : un bilan
  /// partiel vaut mieux qu'un tableau de bord en erreur.
  static RestaurantFinanceReport build(String shopId, DashRange range) {
    final n = range.buckets;
    final labels = [for (var i = 0; i < n; i++) range.bucketLabel(i)];

    final revenueSeries = List<double>.filled(n, 0);
    final materialSeries = List<double>.filled(n, 0);
    final chargeSeries = List<double>.filled(n, 0);
    final lossSeries = List<double>.filled(n, 0);

    // Coût matières et secteur, par produit — calculés UNE fois : les lire
    // dans la boucle des commandes rescannerait la boîte des recettes à
    // chaque ligne vendue.
    final unitCost = <String, double>{};
    final sectorOf = <String, String?>{};
    try {
      for (final p in LocalStorageService.getProductsForShop(shopId)) {
        final id = p.id;
        if (id == null) continue;
        // Fiche recette si elle existe, sinon le coût matière saisi à la main
        // sur le plat (`priceBuy`) — un plat sans recette n'est pas gratuit.
        final recipe = RecipeService.recipeCost(shopId, id);
        unitCost[id] = recipe > 0 ? recipe : p.priceBuy;
        sectorOf[id] = p.activityId;
      }
    } catch (e) {
      debugPrint('[RestoReport] catalogue err: $e');
    }

    final sectorRevenue = <String, double>{};
    final sectorCost = <String, double>{};
    final sectorRevenueSeries = <String, List<double>>{};
    final sectorCostSeries = <String, List<double>>{};

    void addToSector(String key, int bucket, double rev, double cost) {
      sectorRevenue[key] = (sectorRevenue[key] ?? 0) + rev;
      sectorCost[key] = (sectorCost[key] ?? 0) + cost;
      (sectorRevenueSeries[key] ??= List<double>.filled(n, 0))[bucket] += rev;
      (sectorCostSeries[key] ??= List<double>.filled(n, 0))[bucket] += cost;
    }

    // ── Ventes encaissées ──────────────────────────────────────────────
    try {
      for (final raw in HiveBoxes.ordersBox.values) {
        final o = Map<String, dynamic>.from(raw);
        if (o['shop_id']?.toString() != shopId) continue;
        final deleted = o['deleted_at'];
        if (deleted != null && deleted.toString().isNotEmpty) continue;
        // Seules les commandes CLÔTURÉES sont du chiffre d'affaires : une
        // commande en cours n'est pas encore de l'argent encaissé.
        if (o['status']?.toString() != 'completed') continue;

        // Une commande encaissée compte le jour de son encaissement, comme
        // partout ailleurs dans les tableaux de bord.
        final rawDate = o['completed_at'] ?? o['created_at'];
        final date = rawDate == null
            ? null
            : DateTime.tryParse(rawDate.toString())?.toLocal();
        if (date == null) continue;
        if (date.isBefore(range.from) || date.isAfter(range.to)) continue;
        final b = range.bucketOf(date);

        for (final rawItem in (o['items'] as List? ?? [])) {
          if (rawItem is! Map) continue;
          final it = Map<String, dynamic>.from(rawItem);
          final qty = ((it['quantity'] ?? it['qty']) as num?)?.toDouble() ?? 0;
          if (qty <= 0) continue;
          // Même formule de ligne que le tableau de bord e-commerce : les
          // deux écrans doivent annoncer le même chiffre d'affaires.
          final unit =
              ((it['unit_price'] ?? it['price']) as num?)?.toDouble() ?? 0;
          final custom = (it['custom_price'] as num?)?.toDouble();
          final discount = (it['discount'] as num?)?.toDouble() ?? 0;
          final lineRevenue = (custom ?? unit) * qty * (1 - discount / 100);

          final pid = it['product_id']?.toString() ?? '';
          // Repli sur le prix d'achat figé dans la ligne quand le produit a
          // été supprimé du catalogue depuis la vente.
          final cost = (unitCost[pid] ??
                  (it['price_buy'] as num?)?.toDouble() ??
                  0) *
              qty;

          revenueSeries[b] += lineRevenue;
          materialSeries[b] += cost;
          addToSector(sectorOf[pid] ?? '', b, lineRevenue, cost);
        }
      }
    } catch (e) {
      debugPrint('[RestoReport] ventes err: $e');
    }

    // ── Charges fixes imputables à la période ──────────────────────────
    var charges = 0;
    try {
      for (final c in FixedChargeService.forShop(shopId)) {
        // Échéances RÉGLÉES dont la date tombe dans la période.
        for (final key in c.paidDates) {
          final d = DateTime.tryParse(key);
          if (d == null || _outside(d, range)) continue;
          charges += c.amount;
          chargeSeries[range.bucketOf(d)] += c.amount.toDouble();
        }
        // Échéance courante NON réglée tombant dans la période : elle pèse sur
        // le bénéfice même impayée, sinon un loyer en retard embellirait le
        // mois. Pas de double comptage : `markPaid` déplace `nextDueDate` et
        // `isCurrentPaid` couvre le cas « once » (échéance non déplacée).
        if (!c.isCurrentPaid && !_outside(c.nextDueDate, range)) {
          charges += c.amount;
          chargeSeries[range.bucketOf(c.nextDueDate)] += c.amount.toDouble();
        }
      }
    } catch (e) {
      debugPrint('[RestoReport] charges err: $e');
    }

    // ── Pertes déclarées (saisie manuelle + écarts d'inventaire) ───────
    var losses = 0;
    try {
      for (final l in LossService.forShop(shopId)) {
        if (_outside(l.date, range)) continue;
        losses += l.amount;
        lossSeries[range.bucketOf(l.date)] += l.amount.toDouble();
      }
    } catch (e) {
      debugPrint('[RestoReport] pertes err: $e');
    }

    // ── Secteurs ───────────────────────────────────────────────────────
    final names = <String, String>{};
    try {
      for (final a in ActivityService.forShop(shopId)) {
        names[a.id] = a.name;
      }
    } catch (e) {
      debugPrint('[RestoReport] activités err: $e');
    }

    final sectors = <SectorLine>[
      for (final key in sectorRevenue.keys)
        SectorLine(
          activityId: key.isEmpty ? null : key,
          // Une activité supprimée laisse un id orphelin sur ses plats : ses
          // ventes retombent sur « Sans secteur » plutôt que d'afficher un id.
          name: key.isEmpty ? noSectorLabel : (names[key] ?? noSectorLabel),
          revenue: sectorRevenue[key] ?? 0,
          materialCost: sectorCost[key] ?? 0,
          revenueSeries: sectorRevenueSeries[key] ?? List<double>.filled(n, 0),
          costSeries: sectorCostSeries[key] ?? List<double>.filled(n, 0),
        ),
    ]..sort((a, b) => b.revenue.compareTo(a.revenue));

    return RestaurantFinanceReport(
      range: range,
      labels: labels,
      revenue: revenueSeries.fold(0, (s, v) => s + v),
      materialCost: materialSeries.fold(0, (s, v) => s + v),
      charges: charges,
      losses: losses,
      // PR-D non livrée : aucune source de masse salariale à ce jour.
      payroll: 0,
      revenueSeries: revenueSeries,
      expenseSeries: [
        for (var i = 0; i < n; i++) materialSeries[i] + chargeSeries[i],
      ],
      lossSeries: lossSeries,
      sectors: sectors,
    );
  }

  /// Date hors de la fenêtre (bornes incluses).
  static bool _outside(DateTime d, DashRange range) =>
      d.isBefore(range.from) || d.isAfter(range.to);
}
