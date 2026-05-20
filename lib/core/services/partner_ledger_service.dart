import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/parametres/domain/entities/partner_ledger_entry.dart';
import '../../features/parametres/domain/entities/partner_debt_info.dart';
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
    PartnerChargeCategory? category,
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
      category: category,
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
    // Marqueur d'écho : protège cette entrée de la purge passthrough tant
    // que le push n'est pas confirmé (corrige le solde qui revient en web).
    await AppDatabase.markLocalLedgerWrite(entry.id);
    // Upsert (et non insert) → idempotent : un rejeu offline / echo
    // realtime ne casse pas sur 23505. Combiné au garde-fou anti-purge
    // côté AppDatabase, le solde ne peut plus revenir en arrière.
    AppDatabase.bgUpsert('partner_ledger_entries', map);
    AppDatabase.notifyListeners('partner_ledger_entries', shopId);
    return entry;
  }

  /// Modifie une entrée existante (montant / note / date / catégorie).
  /// Le `type` et les ids restent figés (cohérence comptable). Réécrit
  /// la ligne Hive puis upsert Supabase (même `id` → écrase proprement).
  static Future<PartnerLedgerEntry> updateEntry({
    required String entryId,
    required String shopId,
    required double amount,
    String? note,
    DateTime? createdAt,
    PartnerChargeCategory? category,
  }) async {
    final box = HiveBoxes.partnerLedgerBox;
    final raw = box.get(entryId);
    if (raw == null) {
      throw StateError('Entrée introuvable: $entryId');
    }
    final current = PartnerLedgerEntry.fromMap(Map<String, dynamic>.from(raw));
    final updated = PartnerLedgerEntry(
      id:                current.id,
      shopId:            current.shopId,
      partnerLocationId: current.partnerLocationId,
      orderId:           current.orderId,
      type:              current.type,
      category:          current.type == PartnerLedgerEntryType.partnerCharge
                            ? (category ?? current.category)
                            : current.category,
      amount:            amount,
      createdAt:         createdAt ?? current.createdAt,
      note:              note,
      createdByUserId:   current.createdByUserId,
    );
    final map = updated.toMap();
    try {
      await box.put(updated.id, map);
    } catch (e) {
      debugPrint('[PartnerLedger] Hive update error: $e');
    }
    await AppDatabase.markLocalLedgerWrite(updated.id);
    AppDatabase.bgUpsert('partner_ledger_entries', map);
    AppDatabase.notifyListeners('partner_ledger_entries', shopId);
    return updated;
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
        // Suppression douce : on ignore les entrées marquées supprimées
        // (filtrées des soldes ET de l'historique).
        if (raw['deleted_at'] != null
            && raw['deleted_at'].toString().isNotEmpty) {
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

  /// Dette partenaire PAR COMMANDE, calculée en UNE SEULE passe Hive
  /// (offline-first) pour l'ensemble des [orderIds] visibles — jamais un
  /// scan par commande. Clé du résultat = `orderId`. Une commande absente
  /// de la map = aucune entrée ledger (pas de dette / pas de partenaire).
  ///
  /// Pour chaque commande :
  ///   * dette brute = Σ |amount| des entrées négatives (deliveryOwed /
  ///     partnerCharge),
  ///   * offsets     = Σ amount des entrées positives liées à la même
  ///     commande (saleCollected / remittance),
  ///   * `isCompensated` = **soit** le solde GLOBAL du partenaire ≥ 0
  ///     (partenaire à jour : aucune dette nette → on masque toutes ses
  ///     bannières, y compris si la commande est soldée par les ventes
  ///     d'AUTRES commandes du même partenaire) **soit** les offsets de
  ///     la commande couvrent déjà sa dette.
  ///
  /// Convention solde (cf. [PartnerLedgerEntry]) : `solde = SUM(amount)`
  ///   > 0 partenaire doit à la boutique · < 0 boutique doit · = 0 à jour.
  ///
  /// Un seul parcours Hive (offline-first) ; re-calculé en live à chaque
  /// changement ledger (Realtime + versement → notifyListeners). Aucune
  /// donnée persistée : rien à migrer, pas de désynchro possible.
  static Map<String, PartnerDebtInfo> debtByOrder(
      String shopId, Iterable<String> orderIds) {
    final wanted = orderIds.where((e) => e.isNotEmpty).toSet();
    if (wanted.isEmpty) return const {};
    final neg          = <String, double>{}; // dette brute / commande
    final pos          = <String, double>{}; // offsets / commande
    final orderPartner = <String, String>{}; // commande → partenaire
    final partnerBal   = <String, double>{}; // solde GLOBAL / partenaire
    // entriesForShop = un seul parcours du box Hive, déjà filtré
    // soft-delete. On agrège tout ici en une passe.
    for (final e in entriesForShop(shopId)) {
      // Solde global du partenaire (TOUTES ses entrées, pas seulement
      // les commandes visibles) — clé de la compensation par solde.
      partnerBal.update(e.partnerLocationId, (v) => v + e.amount,
          ifAbsent: () => e.amount);
      final oid = e.orderId;
      if (oid == null || !wanted.contains(oid)) continue;
      orderPartner[oid] = e.partnerLocationId;
      if (e.amount < 0) {
        neg.update(oid, (v) => v + e.amount.abs(),
            ifAbsent: () => e.amount.abs());
      } else if (e.amount > 0) {
        pos.update(oid, (v) => v + e.amount, ifAbsent: () => e.amount);
      }
    }
    final out = <String, PartnerDebtInfo>{};
    for (final entry in neg.entries) {
      final oid     = entry.key;
      final debt    = entry.value;
      final offset  = pos[oid] ?? 0;
      final partner = orderPartner[oid];
      final balance = partner == null ? 0.0 : (partnerBal[partner] ?? 0.0);
      out[oid] = PartnerDebtInfo(
        amount:        debt,
        // Partenaire à jour globalement OU dette de la commande déjà
        // couverte par ses propres encaissements/versements.
        isCompensated: balance >= 0 || offset >= debt,
      );
    }
    return out;
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
    // SUPPRESSION DOUCE (soft-delete) : on ne fait PAS un DELETE serveur
    // (un DELETE serait annulé par le re-push d'un autre appareil qui a
    // encore la ligne → résurrection). On marque `deleted_at` et on
    // UPSERT : la suppression devient une donnée qui converge partout
    // (idempotente au re-push, propagée par realtime UPDATE).
    final box = HiveBoxes.partnerLedgerBox;
    final raw = box.get(entryId);
    Map<String, dynamic> map;
    if (raw != null) {
      map = Map<String, dynamic>.from(raw);
    } else {
      // Pas en local : on pousse quand même un marqueur minimal pour
      // que le serveur enregistre la suppression.
      map = {'id': entryId, 'shop_id': shopId};
    }
    map['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    // Tombstone local (sécurité de la fenêtre in-flight + anti-echo).
    await AppDatabase.markLedgerDeletionPending(entryId);
    try {
      // Retire de l'affichage local immédiatement.
      await box.delete(entryId);
    } catch (e) {
      debugPrint('[PartnerLedger] Hive delete error: $e');
    }
    AppDatabase.bgUpsert('partner_ledger_entries', map);
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
