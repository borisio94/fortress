import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/restaurant_table.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'restaurant_tab_service.dart';
import 'restaurant_order_service.dart';

/// Service Hive-first du plan de salle. Toute mutation est :
///   1. écrite IMMÉDIATEMENT dans Hive (offline-first),
///   2. poussée en arrière-plan vers Supabase (file offline si hors ligne),
///   3. notifiée aux listeners `AppDatabase` pour rafraîchir l'UI.
///
/// Les ids sont générés CÔTÉ CLIENT (`rt_` + microsecondes) pour qu'une table
/// créée hors ligne soit immédiatement utilisable et que Hive ↔ Supabase
/// partagent la même clé (convention delivery_zones / partner_ledger_entries).
class RestaurantTableService {
  RestaurantTableService._();

  static Box<Map> _raw() => HiveBoxes.restaurantTablesBox;

  static String _tableId() => 'rt_${DateTime.now().microsecondsSinceEpoch}';

  /// Tables VIVANTES de la boutique, triées par numéro croissant.
  ///
  /// Les tables supprimées sont écartées ici, et nulle part ailleurs : c'est le
  /// point de passage de tout le plan de salle.
  static List<RestaurantTable> tablesForShop(String shopId) {
    try {
      final list = <RestaurantTable>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final t = RestaurantTable.fromMap(Map<String, dynamic>.from(raw));
          // Supprimée : la ligne survit (hotfix_180) mais quitte le plan de
          // salle. Le passthrough la réécrit à chaque resync — c'est ici, et
          // seulement ici, qu'elle est écartée.
          if (t.isDeleted) continue;
          list.add(t);
        } catch (_) {/* ligne corrompue : ignorée, pas de crash de la page */}
      }
      list.sort((a, b) => a.number.compareTo(b.number));
      return list;
    } catch (e) {
      debugPrint('[Restaurant] tablesForShop err: $e');
      return [];
    }
  }

  /// CAPACITÉ DE LA SALLE : places totales, occupées et libres.
  ///
  /// « Places » et non « tables » : une table de huit à moitié occupée n'est
  /// ni libre ni pleine, et compter les tables masquerait justement les
  /// chaises encore disponibles — celles qu'on cherche quand des clients
  /// entrent.
  static ({int total, int seated, int free}) seating(String shopId) =>
      computeSeating(tablesForShop(shopId));

  /// Part PURE de [seating] — testable sans Hive.
  ///
  /// Une table occupée dont les couverts ne sont pas renseignés est comptée
  /// PLEINE. C'est la même hypothèse que la feuille de prise de commande, et
  /// c'est la prudente : annoncer des places qui n'existent pas ferait entrer
  /// des clients qu'on ne pourrait pas asseoir.
  @visibleForTesting
  static ({int total, int seated, int free}) computeSeating(
      List<RestaurantTable> tables) {
    var total = 0;
    var seated = 0;
    for (final t in tables) {
      total += t.capacity;
      if (t.isFree) continue;
      final c = t.covers ?? t.capacity;
      seated += c > t.capacity ? t.capacity : c;
    }
    final free = total - seated;
    return (total: total, seated: seated, free: free < 0 ? 0 : free);
  }

  /// Table par identifiant, SUPPRIMÉES COMPRISES.
  ///
  /// Volontairement non filtré : c'est par là qu'une commande de l'historique
  /// retrouve le nom de la table qu'elle a occupée. Les écrans de service, eux,
  /// passent par `tablesForShop`, qui écarte les supprimées.
  static RestaurantTable? tableById(String id) {
    try {
      final raw = _raw().get(id);
      if (raw == null) return null;
      return RestaurantTable.fromMap(Map<String, dynamic>.from(raw));
    } catch (e) {
      debugPrint('[Restaurant] tableById err: $e');
      return null;
    }
  }

  /// Premier numéro de table libre pour cette boutique.
  ///
  /// Comble les trous : après suppression de T2 dans T1·T2·T3, la prochaine
  /// création reprend le 2 plutôt que de partir à 4. Évite aussi la violation
  /// de l'index unique `(shop_id, number)` quand on recrée après suppression.
  static int nextNumber(String shopId) {
    final used = tablesForShop(shopId).map((t) => t.number).toSet();
    var n = 1;
    while (used.contains(n)) {
      n++;
    }
    return n;
  }

  static Future<RestaurantTable> addTable({
    required String shopId,
    required String name,
    int capacity = 4,
    int? number,
  }) async {
    final table = RestaurantTable(
      id: _tableId(),
      shopId: shopId,
      number: number ?? nextNumber(shopId),
      name: name.trim(),
      capacity: capacity,
      createdAt: DateTime.now(),
    );
    await _persist(table);
    return table;
  }

  /// Écrit une table (création OU mise à jour). Hive d'abord, puis push.
  static Future<void> save(RestaurantTable table) => _persist(table);

  static Future<void> _persist(RestaurantTable table) async {
    final map = table.toMap();
    try {
      await _raw().put(table.id, map);
    } catch (e) {
      debugPrint('[Restaurant] save Hive err: $e');
    }
    AppDatabase.bgUpsert('restaurant_tables', map);
    AppDatabase.notifyListeners('restaurant_tables', table.shopId);
  }

  /// Ouvre le service sur une table libre : statut `occupee`, couverts posés
  /// et horodatage d'ouverture (base du calcul de durée de repas en PR-3).
  static Future<RestaurantTable> openService({
    required RestaurantTable table,
    required int covers,
  }) async {
    final opened = table.copyWith(
      status: RestaurantTableStatus.occupee,
      covers: covers,
      openedAt: DateTime.now(),
    );
    await _persist(opened);
    return opened;
  }

  /// Libère la table SI plus aucun compte n'y est ouvert.
  ///
  /// À appeler après toute opération qui retire une commande d'une table :
  /// encaissement, transfert de compte, départ sans payer, annulation d'une
  /// tournée. Sans ça, une table dont le dernier compte est parti restait
  /// « occupée » alors que plus personne n'y est assis — et il fallait la
  /// libérer à la main pour pouvoir y placer le client suivant.
  ///
  /// N'est JAMAIS appelée à l'aveugle sur tout le plan de salle : une table
  /// qu'on vient d'ouvrir n'a légitimement aucune commande (les clients
  /// consultent la carte). La libérer reviendrait à la rendre disponible sous
  /// les fesses des clients.
  ///
  /// Retourne la table libérée, ou `null` si elle avait encore un compte.
  static Future<RestaurantTable?> releaseIfEmpty(RestaurantTable table) async {
    if (table.isFree) return null;
    if (RestaurantOrderService.openOrdersFor(table).isNotEmpty) return null;
    return release(table);
  }

  /// Ajuste le nombre de couverts d'un service en cours — des convives sont
  /// partis, ou d'autres se sont ajoutés.
  ///
  /// La table RESTE occupée : ce sont des sièges qui se libèrent, pas la table.
  /// C'est ce qui permet de placer deux clients sur une table de six déjà
  /// entamée, cas courant quand on partage les grandes tables.
  ///
  /// Borné entre 1 et la capacité : zéro couvert n'est pas un service (c'est
  /// une table à libérer), et on ne peut pas asseoir plus de monde que de
  /// places.
  static Future<RestaurantTable> updateCovers(
      RestaurantTable table, int covers) async {
    final capped = covers < 1
        ? 1
        : (covers > table.capacity ? table.capacity : covers);
    final updated = table.copyWith(covers: capped);
    await _persist(updated);
    return updated;
  }

  /// Libère la table : remet tout le contexte de service à null ET détache
  /// les commandes encore ouvertes.
  ///
  /// `currentOrderId` est explicitement remis à null — sans ça, la table
  /// rouvrirait sur la commande du service précédent au prochain client.
  ///
  /// Le DÉTACHEMENT est indispensable depuis que le plan de salle déduit le
  /// statut des commandes ouvertes : sans lui, une table libérée qui porte
  /// encore un compte non soldé repassait aussitôt en « occupée » et devenait
  /// impossible à libérer. Les commandes ne sont pas supprimées — elles
  /// deviennent des comptes sans table, toujours encaissables.
  static Future<RestaurantTable> release(RestaurantTable table) async {
    for (final order in RestaurantOrderService.openOrdersFor(table)) {
      await RestaurantTabService.detachFromTable(order);
    }
    final freed = table.copyWith(
      status: RestaurantTableStatus.libre,
      covers: null,
      currentOrderId: null,
      openedAt: null,
      reservationTime: null,
      reservationName: null,
    );
    await _persist(freed);
    return freed;
  }

  /// Bascule la table en statut `addition` (le client demande l'addition).
  static Future<RestaurantTable> requestBill(RestaurantTable table) async {
    final billed = table.copyWith(status: RestaurantTableStatus.addition);
    await _persist(billed);
    return billed;
  }

  /// Pose une réservation sur une table (statut `reservee`).
  static Future<RestaurantTable> reserve({
    required RestaurantTable table,
    required DateTime at,
    required String name,
    int? covers,
  }) async {
    final reserved = table.copyWith(
      status: RestaurantTableStatus.reservee,
      reservationTime: at,
      reservationName: name.trim(),
      covers: covers,
    );
    await _persist(reserved);
    return reserved;
  }

  /// Retire une table du plan de salle — SUPPRESSION DOUCE.
  ///
  /// La ligne n'est pas effacée : elle est marquée `deleted_at` et disparaît de
  /// `tablesForShop`. Une table est référencée par `orders.table_id` sur tout
  /// l'historique des commandes qu'elle a servies, et la suppression dure ne se
  /// rattrapait pas — `box.delete` en local, `DELETE` en base, sans tombstone.
  ///
  /// Le numéro redevient attribuable immédiatement : l'index unique est
  /// partiel depuis hotfix_180 (`WHERE deleted_at IS NULL`), et `nextNumber`
  /// ne compte que les tables vivantes.
  ///
  /// Renvoie `false` si la table est introuvable en local — l'appelant ne doit
  /// alors pas annoncer une suppression qui n'a pas eu lieu.
  static Future<bool> deleteTable(String id, String shopId) async {
    final table = tableById(id);
    if (table == null) {
      debugPrint('[Restaurant] deleteTable: table $id introuvable');
      return false;
    }
    await _persist(table.copyWith(deletedAt: DateTime.now()));
    return true;
  }
}
