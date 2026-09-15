import 'package:flutter/foundation.dart' show debugPrint;

import '../../features/dashboard/data/dashboard_providers.dart' show DashRange;
import '../../features/restaurant/domain/entities/loss.dart';
import '../storage/hive_boxes.dart';
import '../storage/local_storage_service.dart';
import 'activity_service.dart';
import 'daily_expense_service.dart';
import 'fixed_charge_service.dart';
import 'dish_cost_service.dart';
import 'loss_service.dart';
import 'staff_service.dart';

/// Une perte de la période et la valeur que le bilan lui retient.
class LossLine {
  final Loss loss;

  /// Valeur retenue (FCFA) — celle qui entre dans le total.
  final double value;

  const LossLine({required this.loss, required this.value});

  /// Valeur RECALCULÉE sur la période (perte de matière) plutôt que montant
  /// saisi. Dans ce cas, `loss.amount` n'est qu'une estimation de déclaration :
  /// à afficher comme telle, jamais à sommer.
  bool get isRecalculated => loss.isMaterial;
}

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

  /// FOOD COST THÉORIQUE : coût matières des plats vendus, déduit des fiches
  /// recettes (ou du coût matière saisi sur le plat). C'est ce que les ventes
  /// AURAIENT dû consommer.
  final double materialCost;

  /// FOOD COST RÉEL : les achats de matières premières de la période
  /// (`daily_expenses`, catégorie « achat marché »). C'est ce qui est
  /// réellement sorti de la caisse pour acheter la marchandise.
  final int realFoodCost;

  /// Dépenses quotidiennes HORS matières : gaz, électricité, transport,
  /// entretien, extras journaliers.
  final int operatingCost;

  /// Charges fixes imputables à la période (FCFA).
  final int charges;

  /// Pertes de la période (FCFA) : matière perdue RECALCULÉE sur la période
  /// (assiettes au coût unitaire de la période, manques d'inventaire
  /// plafonnés) + pertes non rattachées à leur montant saisi.
  final int losses;

  /// Part des [losses] qui est de la MATIÈRE ACHETÉE : elle est déjà dans les
  /// achats réels ([realFoodCost]) et doit en être retirée quand le bilan
  /// retient le réel, sinon elle serait comptée deux fois.
  final double purchasedMaterialLosses;

  /// Les pertes de la période, chacune avec sa valeur retenue. [losses] en
  /// est la somme arrondie : c'est la SEULE source de la page Pertes.
  final List<LossLine> lossLines;

  /// Masse salariale nette de la période (fiches de paie du mois, Lot D).
  final int payroll;

  final List<double> revenueSeries;

  /// Dépenses par bucket = coût matières + charges fixes (+ paie à terme).
  final List<double> expenseSeries;

  final List<double> lossSeries;

  /// Un secteur par activité, plus « Sans secteur » si des plats non
  /// rattachés ont été vendus. Trié par chiffre d'affaires décroissant.
  final List<SectorLine> sectors;

  /// Seuils camerounais du food cost (spec) : au-delà de 35 %, la carte ne
  /// dégage plus assez pour couvrir les charges.
  static const double foodCostGood = 30;
  static const double foodCostWarning = 35;

  /// Lecture du food cost : `good` (< 30 %) · `warning` (30–35 %) · `bad`
  /// (> 35 %). `null` si aucune vente — un taux sans chiffre d'affaires ne
  /// veut rien dire.
  String? get foodCostLevel {
    if (revenue <= 0 || foodCost <= 0) return null;
    final rate = foodCostRate;
    if (rate < foodCostGood) return 'good';
    if (rate <= foodCostWarning) return 'warning';
    return 'bad';
  }

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
    this.realFoodCost = 0,
    this.operatingCost = 0,
    this.purchasedMaterialLosses = 0,
    this.lossLines = const [],
  });

  /// Achats de matières MOINS la matière perdue qu'ils contiennent — la
  /// matière réellement passée dans les assiettes vendues. Voie (b) : food
  /// cost + pertes = achats.
  double get netRealFoodCost {
    final v = realFoodCost - purchasedMaterialLosses;
    return v > 0 ? v : 0;
  }

  /// Part MINIMALE du coût théorique que les achats saisis doivent couvrir
  /// pour que le bilan bascule sur le réel.
  ///
  /// Sans ce garde-fou, une SEULE dépense de 500 F saisie dans un mois où les
  /// ventes ont consommé 300 000 F de matières faisait basculer tout le bilan
  /// sur le réel : le coût matières tombait à 500 F et le bénéfice affiché
  /// explosait. Le défaut se déclenchait précisément quand quelqu'un
  /// commençait à saisir ses achats sans aller au bout — le pire moment.
  static const double realFoodCostCoverage = 0.5;

  /// La saisie des achats est-elle assez complète pour porter le bilan ?
  ///
  /// Oui si aucun coût théorique n'est calculable (pas de fiches recettes :
  /// le réel est alors la seule mesure disponible), ou si les achats couvrent
  /// au moins [realFoodCostCoverage] du théorique.
  bool get usesRealFoodCost =>
      netRealFoodCost > 0 &&
      (materialCost <= 0 ||
          netRealFoodCost >= materialCost * realFoodCostCoverage);

  /// Des achats ont été saisis, mais trop peu pour être crédibles face à ce que
  /// les ventes ont consommé. Le bilan reste sur le théorique et l'écran doit
  /// le dire — sinon le gérant croit ses achats pris en compte.
  bool get partialFoodCostEntry => netRealFoodCost > 0 && !usesRealFoodCost;

  /// Coût des matières retenu pour le bénéfice : le réel s'il est saisi, le
  /// théorique sinon.
  ///
  /// PAS LES DEUX — c'est le piège de ce module : additionner le coût des
  /// recettes ET les achats du marché déduirait la matière deux fois et
  /// afficherait une perte à un restaurant rentable.
  ///
  /// Le réel est pris NET de la matière perdue : celle-ci figure déjà dans
  /// [losses].
  double get foodCost => usesRealFoodCost ? netRealFoodCost : materialCost;

  /// Tout ce qui sort, hors pertes : matières + exploitation + charges fixes
  /// + paie.
  double get expenses => foodCost + operatingCost + charges + payroll;

  /// Marge brute : ventes − matières. Ce que dégage la carte avant charges.
  double get grossMargin => revenue - materialCost;

  /// Bénéfice net = ventes − matières − exploitation − charges − pertes − paie.
  double get netProfit => revenue - expenses - losses;

  /// Taux de marge brute en % du chiffre d'affaires.
  double get marginRate => revenue <= 0 ? 0 : (grossMargin / revenue) * 100;

  /// FOOD COST % théorique — coût des recettes rapporté aux ventes.
  double get theoreticalFoodCostRate =>
      revenue <= 0 ? 0 : (materialCost / revenue) * 100;

  /// FOOD COST % réel — achats de matières rapportés aux ventes.
  double get realFoodCostRate =>
      revenue <= 0 ? 0 : (netRealFoodCost / revenue) * 100;

  /// Le taux à afficher en premier : le réel dès qu'il existe.
  double get foodCostRate =>
      usesRealFoodCost ? realFoodCostRate : theoreticalFoodCostRate;

  /// Écart entre achats réels et consommation théorique.
  ///
  /// POSITIF = on a acheté plus que ce que les ventes ont consommé. Sur un
  /// mois entier, c'est le signal du gaspillage, du vol ou d'une fiche recette
  /// fausse — l'indicateur que ce module existe pour donner. Sur quelques
  /// jours, ça peut n'être qu'un stock constitué d'avance.
  double get foodCostGap =>
      usesRealFoodCost ? netRealFoodCost - materialCost : 0;

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

    // Secteur par produit — lu UNE fois : le chercher dans la boucle des
    // commandes rescannerait le catalogue à chaque ligne vendue.
    final sectorOf = <String, String?>{};
    final catalogCost = <String, double>{};
    try {
      for (final p in LocalStorageService.getProductsForShop(shopId)) {
        final id = p.id;
        if (id == null) continue;
        sectorOf[id] = p.activityId;
        catalogCost[id] = p.priceBuy;
      }
    } catch (e) {
      debugPrint('[RestoReport] catalogue err: $e');
    }

    final sectorRevenue = <String, double>{};
    final sectorRevenueSeries = <String, List<double>>{};

    // ── Ventes encaissées — PASSE UNIQUE ───────────────────────────────
    //
    // Le chiffre d'affaires se calcule ligne par ligne, mais PAS le coût :
    // celui-ci dépend de la répartition des achats, qui a elle-même besoin du
    // total vendu de la période. On ne peut donc pas tout faire dans le même
    // geste — mais on peut ne PARCOURIR les commandes qu'une seule fois, en
    // mémorisant les quantités vendues par produit et par bucket. Le coût est
    // chiffré juste après, sur ce décompte.
    final soldByProduct = <String, double>{};
    final soldByProductBucket = <String, List<double>>{};
    // Prix d'achat figé dans la ligne : le seul repli quand le produit a été
    // supprimé du catalogue depuis la vente.
    final frozenCost = <String, double>{};

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

        final items = [
          for (final rawItem in (o['items'] as List? ?? []))
            if (rawItem is Map) Map<String, dynamic>.from(rawItem),
        ];

        // CHIFFRE D'AFFAIRES DE LA COMMANDE — `Sale.total` sur le périmètre
        // de ce qui est VENDU : articles − remise de l'addition (+ TVA).
        //
        // Hors CA, à dessein :
        //   * les FRAIS (`fees`) : au restaurant ce sont des consignes, des
        //     cautions rendues au client — pas un produit. Leur remboursement
        //     est exclu du bilan (`ExpenseKind.isCharge`) : exclues des deux
        //     côtés, elles se neutralisent ;
        //   * la LIVRAISON : aucune ligne du bilan ne porte le coût du livreur.
        //     Entrer la recette sans la charge gonflerait le bénéfice (dette
        //     notée, audit des marges 2026-09-15).
        //
        // La TVA suit `Sale.total` mais reste à 0 côté restaurant : chemin
        // inerte tant qu'aucun taux n'est saisi.
        var itemsTotal = 0.0;
        for (final it in items) {
          itemsTotal += _grossLine(it);
        }
        final orderDiscount = (o['discount_amount'] as num?)?.toDouble() ?? 0;
        final taxRate = (o['tax_rate'] as num?)?.toDouble() ?? 0;
        // La remise de l'addition est VENTILÉE au prorata des lignes : chaque
        // ligne porte sa part, donc la somme des secteurs égale le CA.
        final orderFactor = itemsTotal <= 0
            ? 0.0
            : (itemsTotal - orderDiscount) * (1 + taxRate / 100) / itemsTotal;

        for (final it in items) {
          final qty = ((it['quantity'] ?? it['qty']) as num?)?.toDouble() ?? 0;
          if (qty <= 0) continue;
          final lineRevenue = _grossLine(it) * orderFactor;

          final pid = it['product_id']?.toString() ?? '';
          final key = sectorOf[pid] ?? '';

          revenueSeries[b] += lineRevenue;
          sectorRevenue[key] = (sectorRevenue[key] ?? 0) + lineRevenue;
          (sectorRevenueSeries[key] ??=
              List<double>.filled(n, 0))[b] += lineRevenue;

          soldByProduct[pid] = (soldByProduct[pid] ?? 0) + qty;
          (soldByProductBucket[pid] ??= List<double>.filled(n, 0))[b] += qty;
          final frozen = (it['price_buy'] as num?)?.toDouble();
          if (frozen != null && !frozenCost.containsKey(pid)) {
            frozenCost[pid] = frozen;
          }

          // ACCOMPAGNEMENTS — l'option adossée à un plat a été cuisinée autant
          // de fois que la ligne vendue. Son coût s'ajoute donc au coût
          // matières, alors que son PRIX est déjà compris dans le chiffre
          // d'affaires de la ligne (`priceWithModifiers` l'y a matérialisé) :
          // le compter en recette une seconde fois le doublerait.
          //
          // Le secteur suit l'accompagnement lui-même. Donnez à vos sauces et
          // à vos viandes le MÊME secteur qu'au plat qu'elles accompagnent,
          // sans quoi leur coût pèsera sur un secteur dont la recette est
          // enregistrée ailleurs.
          for (final rawMod in (it['modifiers'] as List? ?? [])) {
            if (rawMod is! Map) continue;
            final mid = rawMod['product_id']?.toString() ?? '';
            if (mid.isEmpty) continue;
            soldByProduct[mid] = (soldByProduct[mid] ?? 0) + qty;
            (soldByProductBucket[mid] ??= List<double>.filled(n, 0))[b] += qty;
          }
        }
      }
    } catch (e) {
      debugPrint('[RestoReport] ventes err: $e');
    }

    // ── Coût matières, à partir du décompte ci-dessus ───────────────────
    // La répartition réutilise les ventes déjà comptées : aucun second
    // balayage de la boîte des commandes.
    // Façade : la méthode active (répartition ou fiche technique) est choisie
    // par la boutique, le reporting n'a pas à la connaître.
    //
    // Les pertes de MATIÈRE sont lues AVANT : la répartition en a besoin
    // (voie b — la matière perdue est retirée de l'assiette, pas ajoutée).
    final periodLosses = <Loss>[];
    final wastedByProduct = <String, double>{};
    final withdrawalRequests = <String, int>{};
    try {
      for (final l in LossService.forShop(shopId)) {
        if (_outside(l.date, range)) continue;
        periodLosses.add(l);
        // Une charge ne touche pas à l'assiette, même si une donnée hors
        // règle lui porte des assiettes ou un ingrédient.
        if (!l.isMaterial) continue;
        for (final p in l.items) {
          wastedByProduct[p.productId] =
              (wastedByProduct[p.productId] ?? 0) + p.quantity;
        }
        final ig = _withdrawnIngredientOf(l);
        if (ig != null) {
          withdrawalRequests[ig] = (withdrawalRequests[ig] ?? 0) + l.amount;
        }
      }
    } catch (e) {
      debugPrint('[RestoReport] pertes err: $e');
    }

    final allocation = DishCostService.forSales(shopId,
        from: range.from,
        to: range.to,
        soldByProduct: soldByProduct,
        wastedByProduct: wastedByProduct,
        withdrawnByIngredient: withdrawalRequests);

    // Coût d'UNE assiette : réparti si le plat porte des ingrédients achetés
    // sur la période, sinon le coût matière saisi à la main sur le plat
    // (`priceBuy`), sinon le prix d'achat figé dans la ligne — un plat sans
    // ingrédient coché n'est pas gratuit pour autant. Même règle pour une
    // assiette vendue et une assiette perdue.
    double unitCostOf(String pid) {
      final allocated = allocation.forProduct(pid);
      return allocated > 0
          ? allocated
          : (catalogCost[pid] ?? frozenCost[pid] ?? 0);
    }

    final sectorCost = <String, double>{};
    final sectorCostSeries = <String, List<double>>{};

    for (final entry in soldByProductBucket.entries) {
      final pid = entry.key;
      final unitCost = unitCostOf(pid);
      if (unitCost <= 0) continue;

      final key = sectorOf[pid] ?? '';
      final costSeries = sectorCostSeries[key] ??= List<double>.filled(n, 0);
      for (var i = 0; i < n; i++) {
        final qty = entry.value[i];
        if (qty <= 0) continue;
        final cost = qty * unitCost;
        materialSeries[i] += cost;
        costSeries[i] += cost;
        sectorCost[key] = (sectorCost[key] ?? 0) + cost;
      }
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

    // ── Pertes de la période, valorisées UNE PAR UNE ───────────────────
    // Chaque perte reçoit sa valeur ici, et nulle part ailleurs : la page
    // Pertes affiche ces lignes-là, le total du bilan en est la somme. Un
    // seul calcul, donc un seul total (décision A1).
    //
    // Perte de MATIÈRE : le montant saisi à la déclaration n'est qu'une
    // estimation — la matière perdue vaut ce que la répartition de CETTE
    // période lui impute. Perte NON rattachée : une charge, à son montant.
    final lossLines = <LossLine>[];
    var lossTotal = 0.0;
    // Matière perdue qui figure dans les achats — à retirer du réel.
    var purchasedMaterialLosses = 0.0;
    final purchasedLossSeries = List<double>.filled(n, 0);

    for (final l in periodLosses) {
      final lb = range.bucketOf(l.date);
      var value = 0.0;
      var purchased = 0.0;

      if (!l.isMaterial) {
        value = l.amount.toDouble();
      } else {
        for (final p in l.items) {
          final cost = p.quantity * unitCostOf(p.productId);
          if (cost <= 0) continue;
          value += cost;
          if (allocation.forProduct(p.productId) > 0) {
            purchased += cost;
          }
          // ⚠ Assiette chiffrée HORS ingrédients (`priceBuy` saisi à la main,
          // typiquement une boisson) : elle n'est PAS retirée des achats
          // réels, faute de savoir si elle y figure. En mode achats réels, si
          // cette boisson a été achetée en « Achat marché », sa perte est
          // comptée deux fois. Cas connu et accepté (audit des marges, lot 1)
          // — ne pas « corriger » sans décision.
        }
        final ig = _withdrawnIngredientOf(l);
        if (ig != null) {
          // Montant PLAFONNÉ aux achats de la période, partagé entre les
          // manques du même ingrédient au prorata de ce qu'ils déclaraient.
          final requested = withdrawalRequests[ig] ?? 0;
          final withdrawn = allocation.withdrawnByIngredient[ig] ?? 0;
          if (requested > 0 && withdrawn > 0) {
            final share = withdrawn * l.amount / requested;
            value += share;
            purchased += share;
          }
        }
      }

      lossLines.add(LossLine(loss: l, value: value));
      lossTotal += value;
      lossSeries[lb] += value;
      purchasedMaterialLosses += purchased;
      purchasedLossSeries[lb] += purchased;
    }

    final losses = lossTotal.round();

    // ── Dépenses quotidiennes (Lot E) ──────────────────────────────────
    // Elles sont datées au JOUR et entrent dans la série des dépenses au même
    // titre que les charges : c'est de l'argent réellement sorti.
    var realFoodCost = 0;
    var operatingCost = 0;
    final dailySeries = List<double>.filled(n, 0);
    try {
      for (final e in DailyExpenseService.forShop(shopId)) {
        if (_outside(e.expenseDate, range)) continue;
        if (e.isFoodCost) {
          realFoodCost += e.amount;
        } else if (e.isCharge) {
          operatingCost += e.amount;
        } else {
          // Remboursement de consigne : sortie de caisse, PAS une charge. Le
          // client récupère l'argent qu'il avait versé — l'imputer au bénéfice
          // ferait payer au restaurant une somme qui ne lui a jamais appartenu.
          continue;
        }
        dailySeries[range.bucketOf(e.expenseDate)] += e.amount.toDouble();
      }
    } catch (e) {
      debugPrint('[RestoReport] dépenses err: $e');
    }

    // ── Masse salariale (Lot D) ────────────────────────────────────────
    // Fiches de paie des mois COUVERTS par la période. Une paie est mensuelle :
    // l'imputer au jour le jour n'aurait aucun sens, elle est rattachée au
    // bucket de la fin de son mois.
    var payroll = 0;
    final payrollSeries = List<double>.filled(n, 0);
    try {
      for (final month in _monthsIn(range)) {
        final amount = StaffService.payrollTotal(shopId, month);
        if (amount <= 0) continue;
        payroll += amount;
        // Dernier jour du mois, ramené dans la fenêtre : sur une période à
        // cheval, la paie doit tomber dans un bucket qui existe.
        final parts = month.split('-');
        final endOfMonth =
            DateTime(int.parse(parts[0]), int.parse(parts[1]) + 1, 0);
        final at = endOfMonth.isAfter(range.to) ? range.to : endOfMonth;
        payrollSeries[range.bucketOf(at)] += amount.toDouble();
      }
    } catch (e) {
      debugPrint('[RestoReport] paie err: $e');
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

    // La série des dépenses suit la même règle que le total : matières
    // RÉELLES si elles sont saisies, théoriques sinon. Sans ça, la courbe
    // raconterait autre chose que le bénéfice affiché juste à côté.
    final useReal = realFoodCost > 0;

    return RestaurantFinanceReport(
      range: range,
      labels: labels,
      revenue: revenueSeries.fold(0, (s, v) => s + v),
      materialCost: materialSeries.fold(0, (s, v) => s + v),
      realFoodCost: realFoodCost,
      purchasedMaterialLosses: purchasedMaterialLosses,
      operatingCost: operatingCost,
      charges: charges,
      losses: losses,
      lossLines: lossLines,
      payroll: payroll,
      revenueSeries: revenueSeries,
      expenseSeries: [
        for (var i = 0; i < n; i++)
          // En réel, la matière perdue sort des achats : elle est déjà dans
          // la série des pertes.
          (useReal
                  ? dailySeries[i] - purchasedLossSeries[i]
                  : materialSeries[i] + dailySeries[i]) +
              chargeSeries[i] +
              payrollSeries[i],
      ],
      lossSeries: lossSeries,
      sectors: sectors,
    );
  }

  /// Ingrédient dont un manque est retiré des achats, `null` sinon. Une
  /// fourniture (`si_…`) n'est pas répartie sur les plats : elle ne retire
  /// rien.
  static String? _withdrawnIngredientOf(Loss l) {
    final ig = l.ingredientId;
    if (ig == null || !ig.startsWith('ig_') || l.amount <= 0) return null;
    return ig;
  }

  /// Montant d'une ligne AVANT remise de l'addition — même formule de ligne
  /// que `SaleItem.subtotal` et que le tableau de bord e-commerce.
  static double _grossLine(Map<String, dynamic> it) {
    final qty = ((it['quantity'] ?? it['qty']) as num?)?.toDouble() ?? 0;
    if (qty <= 0) return 0;
    final unit = ((it['unit_price'] ?? it['price']) as num?)?.toDouble() ?? 0;
    final custom = (it['custom_price'] as num?)?.toDouble();
    final discount = (it['discount'] as num?)?.toDouble() ?? 0;
    return (custom ?? unit) * qty * (1 - discount / 100);
  }

  /// Mois `YYYY-MM` couverts par la période, du plus ancien au plus récent.
  static List<String> _monthsIn(DashRange range) {
    final out = <String>[];
    var cursor = DateTime(range.from.year, range.from.month);
    final last = DateTime(range.to.year, range.to.month);
    // Borne de sécurité : une plage aberrante ne doit pas boucler sans fin.
    while (!cursor.isAfter(last) && out.length < 120) {
      out.add('${cursor.year.toString().padLeft(4, '0')}-'
          '${cursor.month.toString().padLeft(2, '0')}');
      cursor = DateTime(cursor.year, cursor.month + 1);
    }
    return out;
  }

  /// Date hors de la fenêtre (bornes incluses).
  static bool _outside(DateTime d, DashRange range) =>
      d.isBefore(range.from) || d.isAfter(range.to);
}
