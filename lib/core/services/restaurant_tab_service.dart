import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../features/caisse/data/repositories/sale_local_datasource.dart';
import '../../features/caisse/domain/entities/sale.dart';

/// Une commande nommée (addition) : les commandes ouvertes qui partagent un même
/// libellé sur une même table.
class RestaurantTab {
  /// Libellé de la commande. Vide = commandes sans nom, regroupées ensemble
  /// sous « Sans nom ».
  final String label;

  /// Table d'accueil, ou `null` pour une commande à emporter.
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

  String get displayLabel => isUnnamed ? 'Sans nom' : label;

  /// Bons PRÊTS que personne n'a encore apportés au client.
  List<Sale> get waitingService =>
      orders.where((o) => o.isWaitingService).toList();

  /// La cuisine a fini sur au moins un bon de cette commande.
  bool get isWaitingService => waitingService.isNotEmpty;
}

/// Gestion des commandes nommées d'une table (plan de salle — Lot 3).
///
/// Une commande nommée n'est PAS une entité stockée : c'est le regroupement des
/// commandes ouvertes qui partagent `tableId` + `tabLabel`. Transférer,
/// fusionner ou scinder revient donc à réécrire ces deux champs sur un lot de
/// commandes — aucune table supplémentaire, aucune migration.
///
/// La contrepartie, c'est que le libellé porte l'identité : deux tables
/// peuvent avoir chacune leur « Commande 1 ». Toute opération est donc cadrée
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

  /// Commandes ouvertes d'une table, de la plus ancienne à la plus récente.
  ///
  /// [tableId] `null` → les commandes SANS table (plats à emporter).
  static List<RestaurantTab> tabsForTable(String shopId, String? tableId) {
    final orders = _openOrders(shopId)
        .where((o) => (o.tableId ?? '') == (tableId ?? ''))
        .toList();
    return groupByLabel(orders, tableId);
  }

  /// PREMIER NOM LIBRE pour une nouvelle commande sur cette table.
  ///
  /// Le nom ne peut PAS être déduit du nombre de commandes existantes : une
  /// commande ouverte à l'écran mais dont rien n'a encore été enregistré
  /// n'existe pas côté données. Compter les commandes persistées proposait
  /// donc « Commande 2 » une fois de plus à chaque tentative, et choisir un
  /// nom déjà pris rouvre la commande existante au lieu d'en créer une — d'où
  /// l'impression de ne jamais pouvoir dépasser deux.
  ///
  /// [alsoTaken] permet d'exclure en plus la commande en cours d'ouverture,
  /// que l'appelant seul connaît.
  static String nextFreeLabel(
    String shopId,
    String? tableId, {
    Iterable<String> alsoTaken = const [],
  }) {
    final taken = <String>{
      for (final t in tabsForTable(shopId, tableId)) t.label.trim(),
      for (final l in alsoTaken) l.trim(),
    }..removeWhere((l) => l.isEmpty);
    // Borne haute : une table à 99 commandes ouvertes relève de la donnée
    // corrompue, pas du service. On rend quand même un nom plutôt que de
    // boucler sans fin.
    for (var n = 1; n <= 99; n++) {
      final candidate = 'Commande $n';
      if (!taken.contains(candidate)) return candidate;
    }
    return 'Commande ${DateTime.now().millisecondsSinceEpoch % 1000}';
  }

  /// Regroupement PUR par libellé — testable sans Hive.
  ///
  /// Les commandes sans libellé forment un seul groupe « Sans nom » plutôt
  /// qu'un groupe par bon : sinon une table dont personne n'a nommé ses
  /// commandes afficherait autant d'additions que de tournées.
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
    // Les commandes nommées d'abord, puis « Sans nom » ; à égalité, la plus
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
  /// Fonction PURE. Sans elle, transférer « Commande 1 » vers une table qui a
  /// déjà sa « Commande 1 » fusionnerait deux additions étrangères — et le
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

  /// Transfère une commande vers une autre table (ou vers « à emporter » si
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

  /// Fusionne la commande [sourceLabel] dans [targetLabel], sur la même table.
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
