import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/storage/hive_boxes.dart';
import '../../../core/storage/local_storage_service.dart';
import '../../../core/permisions/subscription_provider.dart';
import '../../../core/utils/order_revenue_class.dart';
import '../../inventaire/domain/entities/product.dart';
import '../../inventaire/domain/entities/stock_location.dart';
import '../../inventaire/domain/entities/stock_level.dart';
import '../../../core/services/partner_ledger_service.dart';
import '../../parametres/domain/entities/partner_ledger_entry.dart';

/// Clés de catégorie de dépense CANONIQUES (mappées à un libellé/icône par
/// ExpensesBreakdownWidget). Toute autre clé est un label libre (frais de
/// commande, catégorie de dépense personnalisée).
const _kCanonicalExpenseCats = <String>{
  'shipping', 'marketing', 'rent', 'salary', 'utilities', 'taxes',
  'supplies', 'other', 'scrapped', 'repair',
};

/// Normalise une catégorie de dépense pour éviter les doublons de casse/
/// d'espaces (« frais livraison » vs « Frais  Livraison » vs « frais
/// Livraison » apparaissaient comme 3 lignes distinctes). Les clés canoniques
/// sont préservées telles quelles ; les labels libres sont rabattus sur une
/// forme unique (trim + espaces compactés + 1ʳᵉ lettre majuscule).
String _normalizeExpenseCat(String? raw) {
  final t = (raw ?? '').trim();
  if (t.isEmpty) return 'other';
  if (_kCanonicalExpenseCats.contains(t)) return t;
  final collapsed = t.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  return collapsed[0].toUpperCase() + collapsed.substring(1);
}

/// Période affichée par le dashboard.
enum DashPeriod { today, yesterday, week, month, quarter, year, custom }

extension DashPeriodX on DashPeriod {
  String get id => name;
}

class DashRange {
  final DateTime from;
  final DateTime to;
  const DashRange(this.from, this.to);

  Duration get duration => to.difference(from);

  /// Nombre de buckets du graphique (heures, jours ou mois selon la plage).
  int get buckets {
    if (duration.inDays <= 1) return 24;   // par heure
    if (duration.inDays <= 31) return duration.inDays + 1;
    return 12;                              // par mois sur 1 an
  }

  /// Libellé compact d'un bucket.
  String bucketLabel(int i) {
    if (duration.inDays <= 1) return '${i}h';
    if (duration.inDays <= 31) {
      final d = from.add(Duration(days: i));
      return '${d.day}/${d.month}';
    }
    final m = DateTime(from.year, from.month + i, 1);
    return ['jan','fev','mar','avr','mai','jun','jui','aou','sep','oct','nov','dec'][m.month - 1];
  }

  /// Index du bucket dans lequel tombe une date.
  int bucketOf(DateTime d) {
    if (duration.inDays <= 1) {
      return d.difference(from).inHours.clamp(0, buckets - 1);
    }
    if (duration.inDays <= 31) {
      return d.difference(from).inDays.clamp(0, buckets - 1);
    }
    return (d.month - from.month + (d.year - from.year) * 12)
        .clamp(0, buckets - 1);
  }
}

DashRange rangeFor(DashPeriod p, {DateTime? customFrom, DateTime? customTo}) {
  final now = DateTime.now();
  switch (p) {
    case DashPeriod.today:
      final start = DateTime(now.year, now.month, now.day);
      return DashRange(start, start.add(const Duration(days: 1)));
    case DashPeriod.yesterday:
      final start = DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 1));
      return DashRange(start, start.add(const Duration(days: 1)));
    case DashPeriod.week:
      final start = DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 6));
      return DashRange(start, now);
    case DashPeriod.month:
      final start = DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 29));
      return DashRange(start, now);
    case DashPeriod.quarter:
      // 3 mois glissants — cohérent avec la sémantique des autres "period"
      // (fenêtre roulante terminant maintenant).
      final start = DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 89));
      return DashRange(start, now);
    case DashPeriod.year:
      final start = DateTime(now.year - 1, now.month + 1, 1);
      return DashRange(start, now);
    case DashPeriod.custom:
      return DashRange(customFrom ?? now, customTo ?? now);
  }
}

/// Résultat agrégé du dashboard pour la période courante.
class DashData {
  final double totalSales;      // chiffre d'affaires (ventes encaissées)
  final double totalProfit;     // bénéfice brut
  final double totalLoss;       // pertes (remboursements + annulations)
  final int    orderCount;
  final int    clientCount;
  final double avgTicket;
  final int    scheduledCount;  // commandes programmées (toutes périodes)

  final List<double> salesSeries;
  final List<double> profitSeries;
  final List<double> lossSeries;
  final List<double> expensesSeries; // dépenses opérationnelles par bucket
  final List<String> labels;

  final List<Product> newProducts;     // créés < 72h
  final List<TopProd> topProducts;     // meilleures ventes sur la période
  final List<Product> lowStock;        // en-dessous du seuil
  final List<RecentTx> recentTx;       // 5 dernières ventes (toutes périodes)

  // Cycle de vie produit
  final double scrappedLoss;    // pertes rebuts
  final double repairCost;      // coûts de réparation
  final int    pendingIncidents; // incidents en attente

  // Dépenses opérationnelles (hors ventes) sur la période filtrée
  final double operatingExpenses;
  // Répartition par catégorie de dépense (pour donut / breakdown)
  final Map<String, double> expensesByCategory;
  // Créances clients = solde dû sur les commandes complétées non soldées
  // (ventes à crédit). Même formule que Sale.amountDue (paid → 0).
  final double totalClientDebts;

  /// Nombre de LIGNES de commande complétées dont le coût de revient est
  /// inconnu (`baseCost == 0`).
  ///
  /// Ces lignes remontent INTÉGRALEMENT au bénéfice : `orderProfit =
  /// orderTotal − totalCost` avec un coût nul affiche une marge de 100 %.
  /// Sans ce compteur, rien ne distingue « je n'ai rien dépensé » de « je ne
  /// sais pas ce que j'ai dépensé » — le second gonfle le bénéfice en silence.
  ///
  /// ⚠ Un article dont le prix d'achat est RÉELLEMENT nul (cadeau,
  /// échantillon) est compté ici aussi : `costByProduct` écrase « 0 saisi »
  /// et « jamais saisi » dans la même valeur. Faux positif assumé — les
  /// séparer demanderait de rendre ce coût nullable.
  final int costlessLines;

  /// Bénéfice net = bénéfice brut − rebuts − réparations − dépenses opérationnelles
  double get netProfit =>
      totalProfit - scrappedLoss - repairCost - operatingExpenses;

  const DashData({
    required this.totalSales,
    required this.totalProfit,
    required this.totalLoss,
    required this.orderCount,
    required this.clientCount,
    required this.avgTicket,
    required this.scheduledCount,
    required this.salesSeries,
    required this.profitSeries,
    required this.lossSeries,
    this.expensesSeries = const [],
    required this.labels,
    required this.newProducts,
    required this.topProducts,
    required this.lowStock,
    required this.recentTx,
    this.scrappedLoss     = 0,
    this.repairCost       = 0,
    this.pendingIncidents = 0,
    this.operatingExpenses = 0,
    this.expensesByCategory = const {},
    this.totalClientDebts = 0,
    this.costlessLines = 0,
  });
}

class TopProd {
  final String name;
  final int qty;
  final double revenue;
  final String? imageUrl;
  final String? productId;
  const TopProd(this.name, this.qty, this.revenue,
      {this.imageUrl, this.productId});

  TopProd copyWith({String? name, int? qty, double? revenue,
      String? imageUrl, String? productId}) =>
      TopProd(
        name ?? this.name,
        qty ?? this.qty,
        revenue ?? this.revenue,
        imageUrl: imageUrl ?? this.imageUrl,
        productId: productId ?? this.productId,
      );
}

/// Ligne du journal des pertes (rebuts résolus).
class ScrapEntry {
  final String id;
  final String productName;
  final String? productId;
  final int quantity;
  final double unitCost;      // priceBuy + customs/unit + expenses/unit
  final double totalLoss;     // unitCost × quantity
  final DateTime resolvedAt;
  final String? createdBy;
  final String? notes;
  const ScrapEntry({
    required this.id,
    required this.productName,
    this.productId,
    required this.quantity,
    required this.unitCost,
    required this.totalLoss,
    required this.resolvedAt,
    this.createdBy,
    this.notes,
  });
}

/// Une transaction récente affichée dans la card "Transactions récentes".
class RecentTx {
  final String? id;
  final String paymentMethod;   // 'cash' | 'mobileMoney' | 'card' | 'credit'
  final String? clientName;
  final String status;          // 'completed' | 'refunded' | …
  final double amount;
  final DateTime createdAt;
  final String? mainProduct;    // produit principal (plus grosse qty de la vente)
  final int     mainQty;        // quantité du produit principal
  final int     itemCount;      // nb total de lignes (items distincts)
  const RecentTx({
    this.id,
    required this.paymentMethod,
    this.clientName,
    required this.status,
    required this.amount,
    required this.createdAt,
    this.mainProduct,
    this.mainQty = 0,
    this.itemCount = 0,
  });
}

// ─── Providers ───────────────────────────────────────────────────────────────

/// Signal incrémenté à chaque changement de données (vente, produit, etc.)
/// pour forcer le rebuild de dashDataProvider.
final dashSignalProvider = StateProvider<int>((ref) => 0);

/// Période sélectionnée par l'utilisateur (state local au dashboard).
final dashPeriodProvider =
    StateProvider<DashPeriod>((ref) => DashPeriod.today);

/// Plage personnalisée (utilisée seulement si DashPeriod.custom).
final dashCustomRangeProvider =
    StateProvider<DashRange?>((ref) => null);

/// Filtre de périmètre du dashboard de la boutique courante.
///   * `null`        → vue globale (boutique + tous ses partenaires).
///   * `'_base'`     → uniquement la `StockLocation type='shop'` de la boutique.
///   * `<location_id>` → uniquement ce partenaire (`StockLocation type='partner'`).
///
/// Les KPI et listes du dashboard observent ce provider pour filtrer leurs
/// requêtes. Reset à `null` au changement de boutique (cf. listener dans
/// `_DashViewFilter`).
final dashViewFilterProvider = StateProvider<String?>((ref) => null);

/// Vrai si une dépense (de `locationId` donné) doit être comptée dans la
/// vue `viewFilter` :
///   • viewFilter null    (Globale)   → tout
///   • viewFilter '_base' (Boutique)  → dépenses globales (null) + boutique
///   • viewFilter <id>    (Partenaire)→ strictement ce partenaire
bool expenseMatchesView(String? locationId, String? viewFilter) {
  if (viewFilter == null) return true;
  // Vue Boutique : on montre TOUTES les dépenses de la boutique — les siennes
  // (null / '_base' / id réel boutique) ET celles liées à ses partenaires
  // (livraison, stockage). Les dépenses sont déjà filtrées par `shop_id` en
  // amont, donc « tout accepter » = toutes les dépenses de CETTE boutique. Le
  // détail par partenaire reste accessible en sélectionnant ce partenaire.
  if (viewFilter == '_base') return true;
  return locationId == viewFilter;
}

/// Résout `dashViewFilterProvider` en liste d'`location_id` à considérer.
///   * filtre null → null (pas de filtre, tout passe).
///   * filtre `'_base'` → ids des `StockLocation type='shop'` du shop.
///   * filtre `<id>` → [id] (un partenaire).
List<String>? resolveLocationIdsFor(String? viewFilter, String shopId) {
  if (viewFilter == null) return null;
  if (viewFilter == '_base') {
    final ids = <String>[];
    for (final raw in HiveBoxes.stockLocationsBox.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
        if (loc.shopId == shopId
            && loc.type == StockLocationType.shop
            && loc.isActive) {
          ids.add(loc.id);
        }
      } catch (_) {/* skip */}
    }
    return ids;
  }
  return [viewFilter];
}

/// Index `order_id → partner_location_id` pour la boutique courante,
/// construit depuis le cache Hive `delivery_transfers`. Si plusieurs
/// transferts existent pour une même commande (re-routage), on garde le
/// PLUS RÉCENT (l'opération qui livre effectivement). Seuls les transferts
/// `target_type='partner'` peuplent l'index — les transferts vers employés
/// ou numéros libres n'ont pas de location pertinente.
///
/// Utilisé par les pages Commandes/Dashboard pour filtrer "commandes
/// livrées par tel partenaire".
Map<String, String> orderToPartnerLocId(String shopId) {
  final byOrder = <String, ({String locId, DateTime at})>{};
  // 1. Source primaire : table `delivery_transfers` (livraisons effectives).
  for (final raw in HiveBoxes.deliveryTransfersBox.values) {
    try {
      final m = Map<String, dynamic>.from(raw);
      if (m['shop_id']?.toString() != shopId) continue;
      if (m['target_type'] != 'partner') continue;
      final orderId = m['order_id']?.toString();
      final locId   = m['target_ref']?.toString();
      if (orderId == null || locId == null || locId.isEmpty) continue;
      final at = DateTime.tryParse(m['created_at']?.toString() ?? '')
          ?? DateTime.now();
      final cur = byOrder[orderId];
      if (cur == null || at.isAfter(cur.at)) {
        byOrder[orderId] = (locId: locId, at: at);
      }
    } catch (_) {/* skip */}
  }
  // 2. Fallback : commandes créées avec `delivery_mode = 'partner'` mais
  //    sans transfert encore enregistré. Sans ce fallback, une commande
  //    qui vient juste d'être passée en mode partner (chip partenaire)
  //    n'apparaîtrait pas dans la vue "Partenaire X" tant qu'aucun
  //    delivery_transfer n'a été créé manuellement — incohérent avec
  //    le comportement attendu par l'opérateur. La source de vérité
  //    métier est `Sale.deliveryLocationId` quand le mode est partner.
  for (final raw in HiveBoxes.ordersBox.values) {
    try {
      final m = Map<String, dynamic>.from(raw);
      if (m['shop_id']?.toString() != shopId) continue;
      if (m['delivery_mode'] != 'partner') continue;
      final orderId = m['id']?.toString();
      final locId   = m['delivery_location_id']?.toString();
      if (orderId == null || locId == null || locId.isEmpty) continue;
      // Ne pas écraser une entrée déjà posée par delivery_transfers (qui
      // est plus précise — elle reflète la livraison réelle, pas juste
      // l'intention de la vente).
      if (byOrder.containsKey(orderId)) continue;
      final at = DateTime.tryParse(m['created_at']?.toString() ?? '')
          ?? DateTime.now();
      byOrder[orderId] = (locId: locId, at: at);
    } catch (_) {/* skip */}
  }
  return byOrder.map((k, v) => MapEntry(k, v.locId));
}

/// Journal des rebuts résolus pour la boutique + période courantes.
/// Trié par date (plus récent d'abord).
final scrapJournalProvider =
    Provider.family<List<ScrapEntry>, String>((ref, shopId) {
  ref.watch(dashSignalProvider);
  final period = ref.watch(dashPeriodProvider);
  final custom = ref.watch(dashCustomRangeProvider);
  final range  = period == DashPeriod.custom && custom != null
      ? custom
      : rangeFor(period);

  // Coûts unitaires par produit/variante
  final products = LocalStorageService.getProductsForShop(shopId);
  final costByProduct = <String, double>{};
  for (final p in products) {
    if (p.id == null) continue;
    double expPerUnit = 0;
    if (p.expenses.isNotEmpty) {
      final totalExp = p.expenses.fold<double>(
          0, (sum, e) => sum + ((e['amount'] as num?)?.toDouble() ?? 0));
      final qty = p.totalStock > 0 ? p.totalStock : 1;
      expPerUnit = totalExp / qty;
    }
    final stockRef = p.totalPhysical > 0 ? p.totalPhysical : p.stockQty;
    final customsPerUnit = stockRef > 0 ? p.customsFee / stockRef : 0.0;
    costByProduct[p.id!] = p.priceBuy + customsPerUnit + expPerUnit;
    for (final v in p.variants) {
      if (v.id != null) {
        costByProduct[v.id!] = v.priceBuy + customsPerUnit + expPerUnit;
      }
    }
  }

  final entries = <ScrapEntry>[];
  for (final raw in HiveBoxes.incidentsBox.values) {
    try {
      final m = Map<String, dynamic>.from(raw);
      if (m['shop_id'] != shopId) continue;
      if (m['status'] != 'resolved') continue;
      if (m['type'] != 'scrapped') continue;
      final resolvedStr = m['resolved_at'] as String?
          ?? m['created_at'] as String?;
      if (resolvedStr == null) continue;
      final resolvedAt = DateTime.tryParse(resolvedStr);
      if (resolvedAt == null) continue;
      if (resolvedAt.isBefore(range.from) || resolvedAt.isAfter(range.to)) {
        continue;
      }
      final qty = m['quantity'] as int? ?? 0;
      final variantId = m['variant_id'] as String?;
      final productId = m['product_id'] as String?;
      final cost = costByProduct[variantId]
          ?? (productId != null ? costByProduct[productId] : null)
          ?? 0.0;
      entries.add(ScrapEntry(
        id: m['id'] as String? ?? '',
        productName: m['product_name'] as String? ?? 'Produit',
        productId: productId,
        quantity: qty,
        unitCost: cost,
        totalLoss: cost * qty,
        resolvedAt: resolvedAt,
        createdBy: m['created_by'] as String?,
        notes: m['notes'] as String?,
      ));
    } catch (_) {}
  }
  entries.sort((a, b) => b.resolvedAt.compareTo(a.resolvedAt));
  return entries;
});

/// Instantané financier léger pour comparaison (période précédente).
class FinancialSnapshot {
  final double totalSales;
  final double operatingExpenses;
  final double totalLoss;
  final double scrappedLoss;
  final double repairCost;
  final double totalProfit;
  const FinancialSnapshot({
    this.totalSales = 0,
    this.operatingExpenses = 0,
    this.totalLoss = 0,
    this.scrappedLoss = 0,
    this.repairCost = 0,
    this.totalProfit = 0,
  });

  double get netProfit =>
      totalProfit - scrappedLoss - repairCost - operatingExpenses;
}

/// Calcule les agrégats financiers pour une plage donnée, sans recalculer
/// le top produits / nouveautés / transactions récentes. Utilisé pour
/// produire l'instantané de la période précédente (comparatif).
///
/// [viewFilter] reproduit la logique de `dashDataProvider` pour que les
/// pills tendance de la page Finances soient cohérentes avec la vue
/// sélectionnée (Globale / boutique seule / partenaire spécifique).
FinancialSnapshot _computeFinancialSnapshot(String shopId, DashRange range,
    {String? viewFilter}) {
  // Coûts produits (repris tel quel de dashDataProvider)
  final products = LocalStorageService.getProductsForShop(shopId);
  final costByProduct = <String, double>{};
  for (final p in products) {
    if (p.id == null) continue;
    double expPerUnit = 0;
    if (p.expenses.isNotEmpty) {
      final totalExp = p.expenses.fold<double>(
          0, (sum, e) => sum + ((e['amount'] as num?)?.toDouble() ?? 0));
      final qty = p.totalStock > 0 ? p.totalStock : 1;
      expPerUnit = totalExp / qty;
    }
    final stockRef = p.totalPhysical > 0 ? p.totalPhysical : p.stockQty;
    final customsPerUnit = stockRef > 0 ? p.customsFee / stockRef : 0.0;
    costByProduct[p.id!] = p.priceBuy + customsPerUnit + expPerUnit;
    for (final v in p.variants) {
      if (v.id != null) {
        costByProduct[v.id!] = v.priceBuy + customsPerUnit + expPerUnit;
      }
    }
  }

  double totalSales = 0, totalLoss = 0, totalProfit = 0, operatingExpenses = 0;

  // Index partenaire pour aligner sur la vue active.
  final ordersByPartner = (viewFilter != null)
      ? orderToPartnerLocId(shopId)
      : const <String, String>{};

  for (final raw in HiveBoxes.ordersBox.values) {
    final o = Map<String, dynamic>.from(raw);
    if (o['shop_id'] != shopId) continue;
    // Filtre vue dashboard cohérent avec `dashDataProvider`.
    if (viewFilter != null) {
      final orderId = o['id']?.toString() ?? '';
      final partnerLoc = ordersByPartner[orderId];
      if (viewFilter == '_base') {
        if (partnerLoc != null) continue; // commande livrée par partenaire → skip
      } else {
        if (partnerLoc != viewFilter) continue;
      }
    }
    final createdAt = DateTime.tryParse(o['created_at']?.toString() ?? '')
        ?.toLocal();
    if (createdAt == null) continue;
    final completedAt =
        DateTime.tryParse(o['completed_at']?.toString() ?? '')?.toLocal();
    final status = (o['status'] as String?) ?? 'completed';
    final effective = status == 'completed'
        ? (completedAt ?? createdAt)
        : createdAt;
    if (effective.isBefore(range.from) || effective.isAfter(range.to)) continue;

    final items   = (o['items'] as List?) ?? [];
    final rawFees = o['fees'] as List?;
    double orderFees = 0;
    if (rawFees != null) {
      for (final f in rawFees) {
        if (f is Map) orderFees += (f['amount'] as num?)?.toDouble() ?? 0;
      }
    }

    double itemsTotal = 0;
    double totalCost  = 0;
    for (final raw in items) {
      final it  = Map<String, dynamic>.from(raw as Map);
      final qty = ((it['quantity'] ?? it['qty']) as num?)?.toInt() ?? 0;
      final unit = ((it['unit_price'] ?? it['price']) as num?)?.toDouble() ?? 0;
      final custom = (it['custom_price'] as num?)?.toDouble();
      final discount = (it['discount'] as num?)?.toDouble() ?? 0;
      final line = (custom ?? unit) * qty * (1 - discount / 100);
      itemsTotal += line;
      final pid = it['product_id'] as String?;
      final productCost = pid != null ? costByProduct[pid] : null;
      final itemBuy = (it['price_buy'] as num?)?.toDouble();
      final baseCost = productCost ?? itemBuy ?? 0.0;
      totalCost += baseCost * qty;
    }
    // MÊMES FORMULES QUE `dashDataProvider`, et c'est impératif : cet
    // instantané sert le comparatif de période. Si les deux moteurs ne
    // comptent pas pareil, le CA affiché et sa propre tendance divergent
    // sur le même écran — une incohérence d'autant plus pénible qu'elle est
    // invisible.
    final delivMode  = o['delivery_mode'] as String?;
    final delivPrice = (o['delivery_price'] as num?)?.toDouble() ?? 0;
    final delivExpense =
        (delivMode == 'partner' || delivMode == 'shipment') ? delivPrice : 0.0;
    final orderDiscount = (o['discount_amount'] as num?)?.toDouble() ?? 0;
    final taxRate       = (o['tax_rate'] as num?)?.toDouble() ?? 0;
    // Total facturé au client (cf. `Sale.total`) : articles − remise + TVA,
    // PUIS livraison et frais, qui majorent la note.
    final orderTotal    = (itemsTotal - orderDiscount) *
            (1 + taxRate / 100)
        + delivPrice + orderFees;
    // Recette − coût des marchandises. Les charges sont retranchées une
    // seule fois, par `netProfit` via `operatingExpenses`.
    final orderProfit   = orderTotal - totalCost;

    // Règle de classement : voir `classifyOrderStatus`. Elle était écrite
    // ici en toutes lettres, et une seconde fois dans le calcul de
    // tendance ; l'export des commandes, lui, ne la connaissait pas.
    final revClass    = classifyOrderStatus(status);
    final isLoss      = revClass == OrderRevenueClass.loss;
    final isCompleted = revClass == OrderRevenueClass.revenue;
    if (isLoss) {
      totalLoss += orderTotal;
    } else if (isCompleted) {
      totalSales  += orderTotal;
      totalProfit += orderProfit;
    }
    // Frais de commande : comptés uniquement sur les ventes encaissées —
    // tant que la commande n'est pas encaissée la dépense n'est pas réalisée.
    if (isCompleted && orderFees > 0) {
      operatingExpenses += orderFees;
    }
    // Livraison payée à un tiers — elle MANQUAIT ici alors que le moteur
    // principal la comptait : `operatingExpenses` n'avait donc pas la même
    // définition des deux côtés, et `netProfit` divergeait même à CA égal.
    if (isCompleted && delivExpense > 0) {
      operatingExpenses += delivExpense;
    }
  }

  // Dépenses directes
  for (final raw in HiveBoxes.expensesBox.values) {
    try {
      final m = Map<String, dynamic>.from(raw);
      if (m['shop_id'] != shopId) continue;
      final paidAt = DateTime.tryParse(m['paid_at']?.toString() ?? '')
          ?.toLocal();
      if (paidAt == null) continue;
      if (paidAt.isBefore(range.from) || paidAt.isAfter(range.to)) continue;
      if (!expenseMatchesView(
          m['location_id'] as String?, viewFilter)) continue;
      operatingExpenses += (m['amount'] as num?)?.toDouble() ?? 0;
    } catch (_) {}
  }

  // Incidents résolus (rebuts + réparations)
  double scrappedLoss = 0, repairCost = 0;
  for (final raw in HiveBoxes.incidentsBox.values) {
    try {
      final m = Map<String, dynamic>.from(raw);
      if (m['shop_id'] != shopId) continue;
      if (m['status'] != 'resolved') continue;
      final resolved = DateTime.tryParse(
              m['resolved_at']?.toString() ?? '')?.toLocal()
          ?? DateTime.tryParse(m['created_at']?.toString() ?? '')?.toLocal();
      if (resolved == null) continue;
      if (resolved.isBefore(range.from) || resolved.isAfter(range.to)) continue;
      if (m['type'] == 'scrapped') {
        final qty = m['quantity'] as int? ?? 0;
        final pid = m['product_id'] as String?;
        final cost = pid != null ? (costByProduct[pid] ?? 0) : 0.0;
        scrappedLoss += cost * qty;
      }
      repairCost += (m['repair_cost'] as num?)?.toDouble() ?? 0;
    } catch (_) {}
  }

  return FinancialSnapshot(
    totalSales:        totalSales,
    operatingExpenses: operatingExpenses,
    totalLoss:         totalLoss,
    scrappedLoss:      scrappedLoss,
    repairCost:        repairCost,
    totalProfit:       totalProfit,
  );
}

/// Snapshot de la période **précédente** (même durée, décalée avant
/// la période courante). Alimente les pills tendance de la page Finances.
final financesPreviousSnapshotProvider = Provider.autoDispose
    .family<FinancialSnapshot, String>((ref, shopId) {
  ref.watch(dashSignalProvider);
  final period = ref.watch(dashPeriodProvider);
  final custom = ref.watch(dashCustomRangeProvider);
  final viewFilter = ref.watch(dashViewFilterProvider);
  final currentRange = period == DashPeriod.custom && custom != null
      ? custom
      : rangeFor(period);
  final duration = currentRange.to.difference(currentRange.from);
  final previousRange = DashRange(
    currentRange.from.subtract(duration),
    currentRange.from,
  );
  return _computeFinancialSnapshot(shopId, previousRange,
      viewFilter: viewFilter);
});

/// Données agrégées du dashboard pour une boutique donnée et la période
/// actuellement sélectionnée.
///
/// `autoDispose` : quand le dashboard quitte l'écran et plus aucun widget ne
/// watch ce provider, le cache est libéré. Au prochain montage, le provider
/// relit Hive de zéro — plus de données stales après reset/logout.
///
/// Le `dashSignalProvider` force un rebuild live (ex: une vente arrive pendant
/// que le dashboard est visible).
final dashDataProvider =
    Provider.autoDispose.family<DashData, String>((ref, shopId) {
  ref.watch(dashSignalProvider);
  final period = ref.watch(dashPeriodProvider);
  final custom = ref.watch(dashCustomRangeProvider);
  final range = period == DashPeriod.custom && custom != null
      ? custom
      : rangeFor(period);

  // ── Produits ────────────────────────────────────────────────────────────
  final allProducts =
      LocalStorageService.getProductsForShop(shopId);
  final now = DateTime.now();
  final newProducts = allProducts
      .where((p) => !p.isDraft && p.createdAt != null &&
          now.difference(p.createdAt!).inHours < 72)
      .toList()
    ..sort((a, b) => b.createdAt!.compareTo(a.createdAt!));

  // Stock bas — résolu via `stock_levels` (multi-emplacement) selon la vue.
  //   * Globale (viewFilter null) → SOMME des stock_levels sur tous les
  //     emplacements de la boutique courante (type='shop' rattachée au shop)
  //     PLUS tous les partenaires actifs du même owner.
  //   * Boutique seule ('_base') → uniquement les locations type='shop' du shop.
  //   * Partenaire X → uniquement cette location_id.
  // Auparavant, Globale s'appuyait sur `Product.isLowStock` qui ne lit que
  // `variant.stockAvailable` (= la boutique uniquement, pas les partenaires).
  // Cette nouvelle règle assure que cliquer Globale agrège bien tous les
  // emplacements visibles par l'utilisateur.
  final viewFilter = ref.watch(dashViewFilterProvider);
  final targetLocIds = <String>{};
  if (viewFilter == null) {
    // Globale : shop locations + partenaires actifs du même owner.
    final shop = LocalStorageService.getShop(shopId);
    final ownerId = shop?.ownerId;
    for (final m in HiveBoxes.stockLocationsBox.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(m));
        if (!loc.isActive) continue;
        final isShopLoc = loc.shopId == shopId
            && loc.type == StockLocationType.shop;
        final isOwnerPartner = ownerId != null
            && loc.ownerId == ownerId
            && loc.type == StockLocationType.partner;
        if (isShopLoc || isOwnerPartner) {
          targetLocIds.add(loc.id);
        }
      } catch (_) {/* skip ligne corrompue */}
    }
  } else if (viewFilter == '_base') {
    // StockLocation type='shop' rattachée à cette boutique.
    for (final m in HiveBoxes.stockLocationsBox.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(m));
        if (loc.shopId == shopId
            && loc.type == StockLocationType.shop
            && loc.isActive) {
          targetLocIds.add(loc.id);
        }
      } catch (_) {/* skip */}
    }
  } else {
    // Partenaire ou warehouse — on prend l'id tel quel.
    targetLocIds.add(viewFilter);
  }

  // Index variant_id → {location_id: stock_available}, construit une fois.
  final stockByVariantLoc = <String, Map<String, int>>{};
  for (final m in HiveBoxes.stockLevelsBox.values) {
    try {
      final lvl = StockLevel.fromMap(Map<String, dynamic>.from(m));
      stockByVariantLoc
          .putIfAbsent(lvl.variantId, () => <String, int>{})
          [lvl.locationId] = lvl.stockAvailable;
    } catch (_) {/* skip */}
  }

  final lowStock = <Product>[];
  for (final p in allProducts) {
    // Ce KPI passe par `stock_levels`, pas par `Product.isLowStock` : la
    // garde du getter ne s'applique pas ici, il faut la répéter.
    if (p.isDraft) continue;
    int totalAtLocations = 0;
    for (final v in p.variants) {
      if (v.id == null) continue;
      final locMap = stockByVariantLoc[v.id];
      if (locMap == null) continue;
      for (final locId in targetLocIds) {
        totalAtLocations += locMap[locId] ?? 0;
      }
    }
    // Fallback : si stock_levels vide pour ce produit (pas encore migré),
    // retomber sur la règle Phase 1 (variant.stockAvailable) — mais
    // uniquement en vue Globale ou Boutique seule, pas pour un partenaire
    // (un partenaire sans stock_levels = vraiment 0, pas le stock variant).
    final usableTotal = totalAtLocations > 0 || viewFilter == null
        || viewFilter == '_base'
        ? (totalAtLocations > 0 ? totalAtLocations : p.totalStock)
        : 0;
    if (usableTotal > 0 && usableTotal <= p.stockMinAlert) {
      lowStock.add(p);
    }
  }

  // Prix de revient par variante :
  //   priceBuy(variante) + customsFee/stock(produit) + expenses/stock(produit)
  // Indexé par variant.id ET product.id pour couvrir tous les cas.
  final costByProduct  = <String, double>{};
  // Image et id produit pour l'affichage Top Produits (pas de recalcul,
  // simple lookup depuis les produits locaux).
  final imageByProduct = <String, String?>{};
  final parentIdBy     = <String, String>{}; // variant.id → product.id
  for (final p in allProducts) {
    if (p.id == null) continue;
    // Dépenses réparties sur le stock total (communes à toutes les variantes)
    double expPerUnit = 0;
    if (p.expenses.isNotEmpty) {
      final totalExp = p.expenses.fold<double>(
          0, (sum, e) => sum + ((e['amount'] as num?)?.toDouble() ?? 0));
      final qty = p.totalStock > 0 ? p.totalStock : 1;
      expPerUnit = totalExp / qty;
    }
    // Douane par unité (niveau produit)
    final customsPerUnit = p.stockQty > 0 ? p.customsFee / p.stockQty : 0.0;

    // Indexer par product.id (fallback)
    costByProduct[p.id!]  = p.priceBuy + customsPerUnit + expPerUnit;
    imageByProduct[p.id!] = p.mainImageUrl;

    // Indexer par chaque variant.id (priorité — c'est l'ID stocké dans les commandes)
    for (final v in p.variants) {
      if (v.id == null) continue;
      costByProduct[v.id!]  = v.priceBuy + customsPerUnit + expPerUnit;
      imageByProduct[v.id!] = v.imageUrl ?? p.mainImageUrl;
      parentIdBy[v.id!]     = p.id!;
    }
  }

  // ── Ventes ──────────────────────────────────────────────────────────────
  // Filtre par vendeur : un user (role !admin && !owner) ne voit que SES
  // propres ventes (created_by_user_id == auth.uid()). Les admins et le
  // owner voient toutes les ventes de la boutique.
  final perms = ref.watch(permissionsProvider(shopId));
  final myUid = Supabase.instance.client.auth.currentUser?.id;
  final restrictToOwn = !perms.isAdmin && !perms.isOwner && myUid != null;

  // Filtre commandes selon la vue dashboard :
  //   * Globale (viewFilter null) → toutes les commandes du shop.
  //   * Partenaire X → commandes ayant un transfer.target_ref==X (ou
  //                    transfer.shop_id==shopId pour les warehouses) en
  //                    consultant l'index `orderToPartnerLocId`.
  //   * Boutique seule ('_base') → commandes SANS transfer partenaire
  //                    actif (livrées par la boutique elle-même).
  final ordersByPartner = (viewFilter != null)
      ? orderToPartnerLocId(shopId)
      : const <String, String>{};

  bool keepOrderForView(Map<String, dynamic> o) {
    if (viewFilter == null) return true;            // Globale : tout
    final orderId = o['id']?.toString() ?? '';
    final partnerLoc = ordersByPartner[orderId];
    if (viewFilter == '_base') {
      // Commande livrée par la boutique = pas de transfer partenaire.
      return partnerLoc == null;
    }
    // Vue partenaire X : la commande doit pointer sur ce X.
    return partnerLoc == viewFilter;
  }

  final orders = HiveBoxes.ordersBox.values
      .map((m) => Map<String, dynamic>.from(m))
      .where((o) => o['shop_id'] == shopId)
      .where((o) => !restrictToOwn
          || o['created_by_user_id'] == myUid)
      .where(keepOrderForView)
      .toList();

  final salesSeries    = List<double>.filled(range.buckets, 0);
  final profitSeries   = List<double>.filled(range.buckets, 0);
  final lossSeries     = List<double>.filled(range.buckets, 0);
  final expensesSeries = List<double>.filled(range.buckets, 0);
  final topMap = <String, TopProd>{};
  final clientSet = <String>{};

  double totalSales = 0;
  double totalProfit = 0;
  double totalLoss = 0;
  int orderCount = 0;
  // Lignes vendues dont le coût de revient est inconnu — cf. DashData.
  // Déclaré ICI, avec les autres accumulateurs de période : `totalCost` (plus
  // bas) vit à l'intérieur de la boucle et repart à zéro à chaque commande.
  int costlessLines = 0;
  // Créances clients sur la période : solde dû des commandes complétées non
  // soldées (ventes à crédit). Même formule que Sale.amountDue.
  double totalClientDebts = 0;

  // Dépenses opérationnelles — alimentées par (1) les frais des commandes
  // complétées dans la boucle orders ci-dessous et (2) les dépenses directes
  // plus bas. Réduisent le bénéfice net.
  double operatingExpenses = 0;
  final expensesByCategory = <String, double>{};

  for (final o in orders) {
    final createdRaw = o['created_at'];
    final created = createdRaw is String
        ? DateTime.tryParse(createdRaw)?.toLocal()
        : (createdRaw is DateTime ? createdRaw.toLocal() : null);
    if (created == null) continue;

    final status = (o['status'] as String?) ?? 'completed';
    // Pour les commandes complétées, utiliser la date de complétion effective
    // (ex: commande programmée hier, encaissée aujourd'hui → comptée aujourd'hui).
    final completedRaw = o['completed_at'];
    final completedAt = completedRaw is String
        ? DateTime.tryParse(completedRaw)?.toLocal()
        : (completedRaw is DateTime ? completedRaw.toLocal() : null);
    final effective = status == 'completed' ? (completedAt ?? created) : created;
    if (effective.isBefore(range.from) || effective.isAfter(range.to)) continue;

    final bucket = range.bucketOf(effective);
    final items = (o['items'] as List?) ?? [];

    // Même règle que le moteur principal, par le même helper — c'était la
    // seconde des deux copies littérales.
    final revClass    = classifyOrderStatus(status);
    final isLoss      = revClass == OrderRevenueClass.loss;
    final isCompleted = revClass == OrderRevenueClass.revenue;

    // Frais de commande (livraison, emballage, etc.)
    final rawFees = o['fees'] as List?;
    double orderFees = 0;
    if (rawFees != null) {
      for (final f in rawFees) {
        final fm = f is Map ? f : null;
        if (fm != null) orderFees += (fm['amount'] as num?)?.toDouble() ?? 0;
      }
    }

    // Premier passage : calculer itemsTotal pour connaître la base de
    // répartition proportionnelle des frais.
    double itemsTotal = 0;
    final perItemLine = <double>[];
    for (final raw in items) {
      final it = Map<String, dynamic>.from(raw as Map);
      final qty = ((it['quantity'] ?? it['qty']) as num?)?.toInt() ?? 0;
      final unit = ((it['unit_price'] ?? it['price']) as num?)?.toDouble() ?? 0;
      final custom = (it['custom_price'] as num?)?.toDouble();
      final price = custom ?? unit;
      final discount = (it['discount'] as num?)?.toDouble() ?? 0;
      final line = price * qty * (1 - discount / 100);
      perItemLine.add(line);
      itemsTotal += line;
    }

    // Deuxième passage : coûts + top produits.
    // Les frais de commande (livraison, emballage…) ne sont PAS absorbés dans
    // le coût produit — ils sont traités comme dépenses opérationnelles
    // distinctes et comptabilisés dans la boucle fees plus bas, pour qu'ils
    // apparaissent correctement dans le graphique Dépenses.
    double totalCost = 0;
    for (var i = 0; i < items.length; i++) {
      final it = Map<String, dynamic>.from(items[i] as Map);
      final qty = ((it['quantity'] ?? it['qty']) as num?)?.toInt() ?? 0;
      final line = perItemLine[i];

      if (isCompleted) {
        final pid = it['product_id'] as String?;
        final productCost = pid != null ? costByProduct[pid] : null;
        final itemBuy = (it['price_buy'] as num?)?.toDouble();
        final baseCost = productCost ?? itemBuy ?? 0.0;
        totalCost += baseCost * qty;
        // Coût inconnu → la ligne remonte entièrement au bénéfice. On le
        // compte pour pouvoir le SIGNALER, sans altérer le calcul lui-même :
        // inventer un coût serait pire que d'afficher un chiffre incertain
        // en le disant.
        //
        // ⚠ Le repli `itemBuy` est en pratique inopérant tant que la variante
        // existe au catalogue : `costByProduct` y est peuplé
        // INCONDITIONNELLEMENT (même à 0), et `??` ne se déclenche que sur
        // `null`. L'instantané figé dans la ligne de commande ne sert donc
        // qu'aux produits supprimés — le cas courant ici est un prix d'achat
        // jamais saisi, que le commerçant peut encore corriger.
        if (baseCost == 0 && qty > 0) costlessLines += qty;

        if (pid != null) {
          final name = (it['product_name'] ?? it['name']) as String? ?? 'Produit';
          final cur = topMap[pid];
          topMap[pid] = TopProd(
            name,
            (cur?.qty ?? 0) + qty,
            (cur?.revenue ?? 0) + line,
            imageUrl:  cur?.imageUrl ?? imageByProduct[pid],
            productId: parentIdBy[pid] ?? pid,
          );
        }
      }
    }

    // Livraison : lue ICI et non plus au moment de la ventilation en
    // dépenses, parce que le total en a désormais besoin.
    final delivMode  = o['delivery_mode'] as String?;
    final delivPrice = (o['delivery_price'] as num?)?.toDouble() ?? 0;
    // Livraison payée à un tiers = charge externe. Retrait ou équipe interne =
    // recette sans charge : facturée au client, elle ne coûte rien dehors.
    final delivExpense =
        (delivMode == 'partner' || delivMode == 'shipment') ? delivPrice : 0.0;

    // TOTAL COMMANDE — la formule de `Sale.total` (sale.dart), et rien
    // d'autre : articles − remise + TVA + livraison + frais.
    //
    // Le commentaire qui tenait ici affirmait que les frais étaient
    // « ABSORBÉS par la boutique » et « PAS ajoutés au montant facturé ».
    // L'entité dit l'inverse depuis qu'ils majorent le total, et c'est elle
    // qui imprime la facture. Le tableau de bord amputait donc la recette de
    // la livraison et des frais, TOUT EN les comptant en dépenses plus bas :
    // le bénéfice était pénalisé deux fois, et la créance client (calculée
    // sur ce total) sous-évaluée d'autant.
    final orderDiscount = (o['discount_amount'] as num?)?.toDouble() ?? 0;
    final taxRate       = (o['tax_rate'] as num?)?.toDouble() ?? 0;
    final taxableBase   = itemsTotal - orderDiscount;
    final orderTax      = taxableBase * taxRate / 100;
    final orderTotal    = taxableBase + orderTax + delivPrice + orderFees;
    // Bénéfice = recette − coût des marchandises, et RIEN D'AUTRE ICI.
    //
    // Ni la remise — déjà retranchée dans `orderTotal` — ni les frais, ni la
    // livraison : `DashData.netProfit` soustrait déjà `operatingExpenses`,
    // qui contient les deux. Les retrancher ici AUSSI les compterait deux
    // fois, soit le défaut même que ce commit répare, pris à l'envers.
    //
    // Conséquence voulue : une livraison assurée en interne reste au
    // bénéfice (facturée au client, aucune charge au-dehors), tandis qu'une
    // livraison partenaire s'annule contre `operatingExpenses`.
    final orderProfit   = orderTotal - totalCost;

    if (isLoss) {
      totalLoss += orderTotal;
      lossSeries[bucket] += orderTotal;
    } else if (isCompleted) {
      totalSales += orderTotal;
      totalProfit += orderProfit;
      salesSeries[bucket] += orderTotal;
      profitSeries[bucket] += orderProfit;
      orderCount++;
      final clientId = o['client_id'] as String?;
      if (clientId != null && clientId.isNotEmpty) clientSet.add(clientId);
      // Créance = solde dû (vente à crédit). Cohérent avec Sale.amountDue :
      // payment_status 'paid' → 0, sinon (total − encaissé) borné à ≥ 0.
      // `paid_by_partner` (hotfix_175) compte comme soldé ICI : le CLIENT a
      // tout réglé, il n'a aucune dette. Ce que le partenaire doit encore
      // verser est une créance sur LUI, portée par le livre partenaire — la
      // compter en créance client la ferait apparaître deux fois, sur deux
      // écrans qui ne parlent pas de la même personne.
      final paymentStatus = (o['payment_status'] as String?) ?? 'unpaid';
      if (paymentStatus != 'paid' && paymentStatus != 'paid_by_partner') {
        final amountPaid = (o['amount_paid'] as num?)?.toDouble() ?? 0;
        totalClientDebts +=
            (orderTotal - amountPaid).clamp(0, double.infinity).toDouble();
      }
    }

    // Frais de commande → dépenses opérationnelles, ventilés par label.
    // Comptabilisés UNIQUEMENT quand la commande est `completed` :
    // tant qu'elle est programmée / en cours / annulée / remboursée, la
    // dépense n'est pas effectivement réalisée → ne pas gonfler le
    // tableau de bord avec des frais d'une vente non encaissée.
    final feesBlocked = status != 'completed';
    if (!feesBlocked && rawFees != null && orderFees > 0) {
      expensesSeries[bucket] += orderFees;
      operatingExpenses += orderFees;
      for (final f in rawFees) {
        if (f is! Map) continue;
        final amount = (f['amount'] as num?)?.toDouble() ?? 0;
        if (amount <= 0) continue;
        final label = (f['label'] as String?)?.trim();
        final cat = _normalizeExpenseCat(
            (label == null || label.isEmpty) ? 'shipping' : label);
        expensesByCategory[cat] = (expensesByCategory[cat] ?? 0) + amount;
      }
    }

    // Frais de LIVRAISON (deliveryPrice) payés à un partenaire / une agence =
    // dépense de livraison (nouveau modèle : la livraison n'est plus dans
    // `fees` mais dans `deliveryPrice`). Retrait / équipe interne = pas de coût
    // externe → non compté. Même règle « completed » que les frais.
    // `delivMode` / `delivPrice` / `delivExpense` sont lus plus haut : le
    // total de la commande en a besoin avant ce point.
    if (!feesBlocked && delivExpense > 0) {
      expensesSeries[bucket] += delivPrice;
      operatingExpenses += delivPrice;
      final cat = _normalizeExpenseCat('shipping');
      expensesByCategory[cat] = (expensesByCategory[cat] ?? 0) + delivPrice;
    }
  }

  final top = topMap.values.toList()
    ..sort((a, b) => b.revenue.compareTo(a.revenue));

  // ── Commandes programmées (toutes périodes) ──────────────────────────
  final scheduledCount =
      orders.where((o) => (o['status'] as String?) == 'scheduled').length;

  // ── Transactions récentes (5 dernières — toutes périodes confondues) ────
  final recentRaw = orders.toList()
    ..sort((a, b) {
      final da = DateTime.tryParse(a['created_at']?.toString() ?? '') ??
          DateTime(1970);
      final db = DateTime.tryParse(b['created_at']?.toString() ?? '') ??
          DateTime(1970);
      return db.compareTo(da);
    });
  final recentTx = recentRaw.take(5).map((o) {
    final items = (o['items'] as List?) ?? [];
    double subtotal = 0;
    String? mainName;
    int mainQty = 0;
    for (final raw in items) {
      final it = Map<String, dynamic>.from(raw as Map);
      final qty = ((it['quantity'] ?? it['qty']) as num?)?.toInt() ?? 0;
      final unit = ((it['unit_price'] ?? it['price']) as num?)?.toDouble() ?? 0;
      final custom = (it['custom_price'] as num?)?.toDouble();
      final price = custom ?? unit; // prix de vente effectif (panier)
      final discount = (it['discount'] as num?)?.toDouble() ?? 0;
      subtotal += price * qty * (1 - discount / 100);
      // Produit principal = ligne avec la plus grosse quantité
      if (qty > mainQty) {
        mainQty  = qty;
        mainName = (it['product_name'] ?? it['name']) as String?;
      }
    }
    // Les frais sont absorbés par la boutique : pas ajoutés au total client
    final txDiscount = (o['discount_amount'] as num?)?.toDouble() ?? 0;
    final txTaxRate  = (o['tax_rate'] as num?)?.toDouble() ?? 0;
    final taxable    = subtotal - txDiscount;
    final total      = taxable + taxable * txTaxRate / 100;
    final created = (DateTime.tryParse(o['created_at']?.toString() ?? '')
        ?.toLocal()) ?? DateTime.now();
    return RecentTx(
      id: o['id'] as String?,
      paymentMethod: (o['payment_method'] as String?) ?? 'cash',
      clientName: o['client_name'] as String?,
      status: (o['status'] as String?) ?? 'completed',
      amount: total,
      createdAt: created,
      mainProduct: mainName,
      mainQty: mainQty,
      itemCount: items.length,
    );
  }).toList();

  // ── Incidents : pertes rebuts + coûts réparation ──────────────────────
  // Incidents résolus filtrés sur la période (date de résolution, fallback
  // création). Alimentent aussi `expensesSeries` et `expensesByCategory`
  // pour apparaître dans le graphique Dépenses.
  double scrappedLoss = 0;
  double repairCost   = 0;
  int    pendingIncidents = 0;
  for (final raw in HiveBoxes.incidentsBox.values) {
    try {
      final m = Map<String, dynamic>.from(raw);
      if (m['shop_id'] != shopId) continue;
      final status = m['status'] as String? ?? 'pending';
      if (status == 'pending' || status == 'in_progress') pendingIncidents++;
      if (status != 'resolved') continue;

      // Date effective : résolution si disponible, sinon création.
      final resolvedStr = m['resolved_at']?.toString();
      final createdStr  = m['created_at']?.toString();
      final effective = DateTime.tryParse(resolvedStr ?? '')?.toLocal()
          ?? DateTime.tryParse(createdStr ?? '')?.toLocal();
      if (effective == null) continue;
      if (effective.isBefore(range.from) || effective.isAfter(range.to)) {
        continue;
      }
      final bucket = range.bucketOf(effective);

      final type = m['type'] as String? ?? '';
      if (type == 'scrapped') {
        final qty = m['quantity'] as int? ?? 0;
        final pid = m['product_id'] as String?;
        final cost = pid != null ? (costByProduct[pid] ?? 0) : 0.0;
        final loss = cost * qty;
        scrappedLoss += loss;
        if (loss > 0) {
          expensesSeries[bucket] += loss;
          expensesByCategory['scrapped'] =
              (expensesByCategory['scrapped'] ?? 0) + loss;
        }
      }
      final repair = (m['repair_cost'] as num?)?.toDouble() ?? 0;
      if (repair > 0) {
        repairCost += repair;
        expensesSeries[bucket] += repair;
        expensesByCategory['repair'] =
            (expensesByCategory['repair'] ?? 0) + repair;
      }
    } catch (_) {}
  }

  // ── Dépenses directes ─────────────────────────────────────────────────
  // S'ajoutent aux frais de commande déjà comptabilisés plus haut.
  // Filtrées sur la période via `paid_at`.
  for (final raw in HiveBoxes.expensesBox.values) {
    try {
      final m = Map<String, dynamic>.from(raw);
      if (m['shop_id'] != shopId) continue;
      final paidAt = DateTime.tryParse(m['paid_at']?.toString() ?? '')?.toLocal();
      if (paidAt == null) continue;
      if (paidAt.isBefore(range.from) || paidAt.isAfter(range.to)) continue;
      if (!expenseMatchesView(
          m['location_id'] as String?, viewFilter)) continue;
      final amount = (m['amount'] as num?)?.toDouble() ?? 0;
      operatingExpenses += amount;
      final cat = _normalizeExpenseCat(m['category'] as String?);
      expensesByCategory[cat] = (expensesByCategory[cat] ?? 0) + amount;
      // Répartir dans le bucket correspondant pour le graphique
      expensesSeries[range.bucketOf(paidAt)] += amount;
    } catch (_) {}
  }

  // ── Charges partenaire (stockage, commission…) ────────────────────────
  // Le livre partenaire est un système séparé : ses CHARGES `partnerCharge`
  // (ex. stockage) sont de vraies sorties d'argent → on les remonte en
  // dépenses. Les `deliveryOwed` ne sont PAS repris ici : la livraison est
  // déjà comptée via `order.deliveryPrice` (sinon double comptage).
  for (final e in PartnerLedgerService.entriesForShop(shopId)) {
    if (e.type != PartnerLedgerEntryType.partnerCharge) continue;
    final at = e.createdAt.toLocal();
    if (at.isBefore(range.from) || at.isAfter(range.to)) continue;
    if (!expenseMatchesView(e.partnerLocationId, viewFilter)) continue;
    final amount = e.amount.abs();
    if (amount <= 0) continue;
    operatingExpenses += amount;
    final cat = _normalizeExpenseCat(e.category?.name ?? 'other');
    expensesByCategory[cat] = (expensesByCategory[cat] ?? 0) + amount;
    expensesSeries[range.bucketOf(at)] += amount;
  }

  return DashData(
    totalSales: totalSales,
    totalProfit: totalProfit,
    totalLoss: totalLoss,
    orderCount: orderCount,
    costlessLines: costlessLines,
    clientCount: clientSet.length,
    avgTicket: orderCount > 0 ? totalSales / orderCount : 0,
    scheduledCount: scheduledCount,
    salesSeries: salesSeries,
    profitSeries: profitSeries,
    lossSeries: lossSeries,
    expensesSeries: expensesSeries,
    labels: List.generate(range.buckets, range.bucketLabel),
    newProducts: newProducts,
    topProducts: top.take(5).toList(),
    lowStock: lowStock,
    recentTx: recentTx,
    scrappedLoss: scrappedLoss,
    repairCost: repairCost,
    pendingIncidents: pendingIncidents,
    operatingExpenses: operatingExpenses,
    expensesByCategory: expensesByCategory,
    totalClientDebts: totalClientDebts,
  );
});
