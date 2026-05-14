import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/parametres/domain/entities/partner_ledger_entry.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

/// Service Hive-first pour le livre de comptes partenaires.
///
/// Toute mutation est :
///   1. écrite IMMÉDIATEMENT dans Hive (offline-first),
///   2. notifiée aux listeners (`AppDatabase`) pour rafraîchissement UI,
///   3. poussée en arrière-plan vers Supabase (file `offline_queue` si KO).
class PartnerLedgerService {
  PartnerLedgerService._();

  static String _newId() {
    return 'ple_${DateTime.now().microsecondsSinceEpoch}';
  }

  /// Écrit un mouvement et le pousse vers Supabase.
  /// `createdAt` (optionnel) : antidatage pour numériser un versement passé
  /// (canvas "tout antidater"). Si null, fallback `DateTime.now()`.
  /// Retourne l'entrée créée pour usage immédiat (ex: notification UI).
  static Future<PartnerLedgerEntry> addEntry({
    required String shopId,
    required String partnerLocationId,
    required PartnerLedgerEntryType type,
    required double amount,
    String? orderId,
    String? note,
    DateTime? createdAt,
  }) async {
    final entry = PartnerLedgerEntry(
      id: _newId(),
      shopId: shopId,
      partnerLocationId: partnerLocationId,
      orderId: orderId,
      type: type,
      amount: amount,
      createdAt: createdAt ?? DateTime.now(),
      note: note,
      createdByUserId: Supabase.instance.client.auth.currentUser?.id,
    );
    final map = entry.toMap();
    try {
      await HiveBoxes.partnerLedgerBox.put(entry.id, map);
    } catch (e) {
      debugPrint('[PartnerLedger] Hive put error: $e');
    }
    AppDatabase.bgInsert('partner_ledger_entries', map);
    AppDatabase.notifyListeners('partner_ledger_entries', shopId);
    return entry;
  }

  /// Tous les mouvements de la boutique, triés du plus récent au plus
  /// ancien. Filtre optionnel par partenaire.
  static List<PartnerLedgerEntry> entriesForShop(
      String shopId, {String? partnerLocationId}) {
    try {
      final box = HiveBoxes.partnerLedgerBox;
      final list = <PartnerLedgerEntry>[];
      for (final raw in box.values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        if (partnerLocationId != null
            && raw['partner_location_id']?.toString() != partnerLocationId) {
          continue;
        }
        try {
          list.add(PartnerLedgerEntry.fromMap(
              Map<String, dynamic>.from(raw)));
        } catch (_) {}
      }
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    } catch (e) {
      debugPrint('[PartnerLedger] entriesForShop err: $e');
      return [];
    }
  }

  /// Solde courant d'un partenaire = SUM(amount).
  /// > 0 : le partenaire doit ce montant à la boutique.
  /// < 0 : la boutique doit ce montant au partenaire.
  static double balanceForPartner(String shopId, String partnerLocationId) {
    final entries = entriesForShop(shopId,
        partnerLocationId: partnerLocationId);
    var sum = 0.0;
    for (final e in entries) { sum += e.amount; }
    return sum;
  }

  /// Map partnerLocationId → solde, pour la liste "Comptes partenaires".
  /// Ne renvoie que les partenaires ayant au moins un mouvement.
  static Map<String, double> balancesForShop(String shopId) {
    final entries = entriesForShop(shopId);
    final out = <String, double>{};
    for (final e in entries) {
      out.update(e.partnerLocationId, (v) => v + e.amount,
          ifAbsent: () => e.amount);
    }
    return out;
  }

  /// Supprime un mouvement (utile pour annuler un versement saisi par
  /// erreur). N'a PAS d'effet en cascade : pour annuler une commande, il
  /// faut chercher toutes les entries avec cet `orderId`.
  static Future<void> deleteEntry(String entryId, String shopId) async {
    try {
      await HiveBoxes.partnerLedgerBox.delete(entryId);
    } catch (e) {
      debugPrint('[PartnerLedger] Hive delete error: $e');
    }
    AppDatabase.bgDelete('partner_ledger_entries', val: entryId);
    AppDatabase.notifyListeners('partner_ledger_entries', shopId);
  }

  /// Supprime tous les mouvements liés à une commande (utile en cas
  /// d'annulation après completion).
  static Future<void> removeForOrder(String shopId, String orderId) async {
    final box = HiveBoxes.partnerLedgerBox;
    final toDelete = <String>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      if (raw['shop_id']?.toString() != shopId) continue;
      if (raw['order_id']?.toString() != orderId) continue;
      toDelete.add(key.toString());
    }
    for (final id in toDelete) {
      await deleteEntry(id, shopId);
    }
  }
}
