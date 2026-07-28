import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../features/caisse/data/repositories/sale_local_datasource.dart';
import '../../features/caisse/domain/entities/sale.dart';

/// Un compte (addition) : les commandes ouvertes qui partagent un même
/// libellé sur une même table.
class RestaurantTab {
  /// Libellé du compte. Vide = commandes sans compte nommé, regroupées
  /// ensemble sous « Sans compte ».
  final String label;

  /// Table d'accueil, ou `null` pour un compte à emporter.
  final String? tableId;

  final List<Sale> orders;

  const RestaurantTab({
    required this.label,
    required this.tableId,
    required this.orders,
  });

  int get orderCount => orders.length;

  double get total => orders.fold<double>(0, (s, o) => s + o.total);

  /// Nombre d'articles cumulés, tous bons confondus.
  int get itemCount => orders.fold<int>(
      0, (s, o) => s + o.items.fold<int>(0, (t, i) => t + i.quantity));

  bool get isUnnamed => label.isEmpty;

  String get displayLabel => isUnnamed ? 'Sans compte' : label;
}

/// Gestion des comptes de service (plan de salle — Lot 3).
///
/// Un compte n'est PAS une entité stockée : c'est le regroupement des
/// commandes ouvertes qui partagent `tableId` + `tabLabel`. Transférer,
/// fusionner ou scinder revient donc à réécrire ces deux champs sur un lot de
/// commandes — aucune table supplémentaire, aucune migration.
///
/// La contrepartie, c'est que le libellé porte l'identité : deux tables
/// peuvent avoir chacune leur « Compte 1 ». Toute opération est donc cadrée
/// par le COUPLE (table, libellé), et un transfert vers une table qui porte
/// déjà ce libellé renomme la destination au lieu de fusionner en silence
/// (cf. [uniqueLabel]).
class RestaurantTabService {
  RestaurantTabService._();

  static final SaleLocalDatasource _ds = SaleLocalDatasource();

  /// Statuts qui sortent une commande du service en cours.
  static bool _isOpen(Sale o) =>
      !o.isDeleted &&
      o.status != SaleStatus.completed &&
      o.status != SaleStatus.cancelled;

  /// Commandes ouvertes de la boutique.
  static List<Sale> _openOrders(String shopId) {
    try {
      return _ds.getOrders(shopId).where(_isOpen).toList();
    } catch (e) {
      debugPrint('[Tab] lecture commandes err: $e');
      return const [];
    }
  }

  /// Comptes ouverts d'une table, du plus ancien au plus récent.
  ///
  /// [tableId] `null` → les comptes SANS table (plats à emporter).
  static List<RestaurantTab> tabsForTable(String shopId, String? tableId) {
    final orders = _openOrders(shopId)
        .where((o) => (o.tableId ?? '') == (tableId ?? ''))
        .toList();
    return groupByLabel(orders, tableId);
  }

  /// Regroupement PUR par libellé — testable sans Hive.
  ///
  /// Les commandes sans libellé forment un seul compte « Sans compte » plutôt
  /// qu'un compte par commande : sinon une table dont personne n'a nommé les
  /// comptes afficherait autant d'additions que de tournées.
  @visibleForTesting
  static List<RestaurantTab> groupByLabel(List<Sale> orders, String? tableId) {
    final byLabel = <String, List<Sale>>{};
    for (final o in orders) {
      byLabel.putIfAbsent(o.tabLabel?.trim() ?? '', () => []).add(o);
    }
    final tabs = <RestaurantTab>[];
    byLabel.forEach((label, list) {
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      tabs.add(RestaurantTab(label: label, tableId: tableId, orders: list));
    });
    // Les comptes nommés d'abord, puis « Sans compte » ; à égalité, le plus
    // ancien en tête (ordre d'arrivée à table).
    tabs.sort((a, b) {
      if (a.isUnnamed != b.isUnnamed) return a.isUnnamed ? 1 : -1;
      return a.orders.first.createdAt.compareTo(b.orders.first.createdAt);
    });
    return tabs;
  }

  /// Libellé libre à la destination : renvoie [label] s'il n'est pas déjà
  /// pris, sinon « label (2) », « label (3) »…
  ///
  /// Fonction PURE. Sans elle, transférer « Compte 1 » vers une table qui a
  /// déjà son « Compte 1 » fusionnerait deux additions étrangères — et le
  /// serveur ne s'en apercevrait qu'au moment de faire payer.
  @visibleForTesting
  static String uniqueLabel(String label, Set<String> taken) {
    if (label.isEmpty || !taken.contains(label)) return label;
    for (var i = 2; i < 100; i++) {
      final candidate = '$label ($i)';
      if (!taken.contains(candidate)) return candidate;
    }
    return label;
  }

  /// Transfère un compte vers une autre table (ou vers « à emporter » si
  /// [toTableId] est `null`).
  ///
  /// Retourne le libellé effectivement appliqué : il peut différer de
  /// [label] si la destination portait déjà ce nom.
  static Future<String> transferTab({
    required String shopId,
    required String? fromTableId,
    required String label,
    required String? toTableId,
  }) async {
    final source = tabsForTable(shopId, fromTableId)
        .where((t) => t.label == label.trim())
        .toList();
    if (source.isEmpty) return label;

    final taken = tabsForTable(shopId, toTableId)
        .map((t) => t.label)
        .where((l) => l.isNotEmpty)
        .toSet();
    final applied = uniqueLabel(label.trim(), taken);

    for (final order in source.first.orders) {
      await _write(order.copyWith(
        // `clearTable` est indispensable : `copyWith(tableId: null)` est un
        // no-op silencieux, la commande resterait accrochée à l'ancienne
        // table (cf. Sale.copyWith).
        tableId: toTableId,
        clearTable: toTableId == null,
        tabLabel: applied,
      ));
    }
    return applied;
  }

  /// Fusionne le compte [sourceLabel] dans [targetLabel], sur la même table.
  static Future<void> mergeTabs({
    required String shopId,
    required String? tableId,
    required String sourceLabel,
    required String targetLabel,
  }) async {
    if (sourceLabel.trim() == targetLabel.trim()) return;
    final tabs = tabsForTable(shopId, tableId);
    final source =
        tabs.where((t) => t.label == sourceLabel.trim()).toList();
    if (source.isEmpty) return;
    for (final order in source.first.orders) {
      await _write(order.copyWith(tabLabel: targetLabel.trim()));
    }
  }

  /// Déplace UNE commande vers un autre compte de la même table — la façon
  /// simple de scinder une addition : on sépare par tournée, pas par article.
  static Future<void> moveOrderToTab({
    required Sale order,
    required String label,
  }) =>
      _write(order.copyWith(tabLabel: label.trim()));

  /// Détache une commande de sa table sans rien perdre : elle reste un compte
  /// ouvert, simplement sans table. Utilisé à la libération d'une table.
  static Future<void> detachFromTable(Sale order) =>
      _write(order.copyWith(clearTable: true));

  static Future<void> _write(Sale order) async {
    try {
      await _ds.updateOrder(order);
    } catch (e) {
      debugPrint('[Tab] écriture commande ${order.id} err: $e');
    }
  }
}
