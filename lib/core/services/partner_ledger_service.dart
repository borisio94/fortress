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

  /// Montant ENCORE À VERSER par le partenaire pour CHAQUE commande : argent
  /// encaissé par le partenaire pour le compte de la boutique (`saleCollected`)
  /// mais pas encore reversé. Calculé en UNE passe Hive (offline-first) pour
  /// l'ensemble des [orderIds] visibles.
  ///
  /// Pour chaque commande : `Σ de TOUTES ses écritures` (solde NET de la
  /// commande) — saleCollected (+), remittance (−), deliveryOwed (−),
  /// partnerCharge (−). Ainsi, ajouter une dépense/charge sur la commande
  /// (frais de livraison, course refusée…) réduit directement le montant
  /// affiché « à verser » par le partenaire.
  /// Une commande n'est retenue (clé du résultat) que si :
  ///   * ce reste NET est positif (le partenaire nous doit encore quelque
  ///     chose sur cette commande précise), ET
  ///   * le solde GLOBAL du partenaire est lui-même > 0 — s'il a déjà tout
  ///     reversé via un versement global (solde ≤ 0), plus rien n'est « en
  ///     attente », on n'affiche donc aucune commande pour lui.
  ///
  /// Résultat : `orderId → montant en attente (> 0)`. Commande absente = rien
  /// à recevoir du partenaire. Aucune donnée persistée : re-calculé en live à
  /// chaque changement ledger (Realtime + versement → notifyListeners).
  ///
  /// [since] (optionnel) : ne compte dans le NET de la commande que les
  /// écritures CRÉÉES après cette date (garde-fou « nouvelles commandes »).
  /// On se base sur la date de l'ÉCRITURE (et non de la commande) afin qu'une
  /// ancienne commande repassée en programmée puis re-finalisée — qui génère
  /// une écriture FRAÎCHE — participe bien à la logique « à verser », tandis
  /// que les commandes historiques jamais retouchées (écritures anciennes)
  /// restent exclues. Le solde GLOBAL du partenaire reste, lui, calculé sur
  /// TOUTES les écritures (cohérence comptable).
  static Map<String, double> pendingRemittanceByOrder(
      String shopId, Iterable<String> orderIds, {DateTime? since}) {
    final wanted = orderIds.where((e) => e.isNotEmpty).toSet();
    if (wanted.isEmpty) return const {};
    final outstanding  = <String, double>{}; // saleCollected(+) + remittance(−)
    final orderPartner = <String, String>{}; // commande → partenaire
    final partnerBal   = <String, double>{}; // solde GLOBAL / partenaire
    for (final e in entriesForShop(shopId)) {
      partnerBal.update(e.partnerLocationId, (v) => v + e.amount,
          ifAbsent: () => e.amount);
      final oid = e.orderId;
      if (oid == null || !wanted.contains(oid)) continue;
      // Garde-fou « nouvelles commandes » : on ignore les écritures
      // antérieures au cutoff (les commandes historiques restent exclues).
      if (since != null && !e.createdAt.isAfter(since)) continue;
      // Solde NET de la commande : on somme TOUTES ses écritures (les frais /
      // charges négatifs déduisent ce que le partenaire doit reverser).
      outstanding.update(oid, (v) => v + e.amount, ifAbsent: () => e.amount);
      orderPartner[oid] = e.partnerLocationId;
    }
    final out = <String, double>{};
    for (final entry in outstanding.entries) {
      final oid = entry.key;
      var reste = entry.value;
      if (reste <= 0.5) continue;
      final partner = orderPartner[oid];
      final bal = partner == null ? 0.0 : (partnerBal[partner] ?? 0.0);
      if (bal <= 0.5) continue; // partenaire déjà à jour globalement
      // « à verser » = montant NET de CETTE commande (sans plafonner au solde
      // global). Les charges que la boutique doit au partenaire (stockage…)
      // sont une DETTE SÉPARÉE (réglée via « Régler le partenaire ») — les
      // mélanger au versement laissait un résidu qui « remontait » (bug 07-2026).
      out[oid] = reste;
    }
    return out;
  }

  /// Enregistre le VERSEMENT REÇU du partenaire pour UNE commande : crée une
  /// entrée `remittance` négative qui solde le montant encore dû pour cette
  /// commande (cf. [pendingRemittanceByOrder]). C'est le marquage manuel
  /// « versement reçu » côté carte commande — il s'inscrit dans le livre
  /// partenaire (source unique de vérité), donc le solde Finances/partenaires
  /// reste cohérent. No-op si `amount <= 0`.
  static Future<void> markOrderRemittanceReceived({
    required String shopId,
    required String partnerLocationId,
    required String orderId,
    required double amount,
    String? note,
  }) async {
    if (amount <= 0) return;
    // Versement reçu = montant COMPLET de la commande → elle est intégralement
    // soldée, sans résidu, et ne « remonte » jamais. Les charges dues au
    // partenaire (stockage…) restent une DETTE SÉPARÉE dans le livre partenaire
    // (réglée via « Régler le partenaire », ou compensée au solde global). Ne
    // PAS re-plafonner : le plafonnement laissait un résidu jamais soldé qui
    // réapparaissait en « à verser » (bug rapporté 07-2026).
    await addEntry(
      shopId:            shopId,
      partnerLocationId: partnerLocationId,
      type:              PartnerLedgerEntryType.remittance,
      // Versement reçu → réduit ce que le partenaire doit (solde vers 0).
      amount:            -amount,
      orderId:           orderId,
      note:              note ?? 'Versement reçu du partenaire',
    );
  }

  /// Resynchronise les FRAIS de livraison déduits du versement partenaire pour
  /// UNE commande : supprime les écritures `deliveryOwed` existantes de la
  /// commande et en recrée une seule de montant -[feesTotal] (si > 0).
  /// Préserve `saleCollected` et les versements déjà enregistrés. Appelé quand
  /// on édite les frais d'une commande encaissée par le partenaire → le montant
  /// « à verser » (cf. [pendingRemittanceByOrder], net) se recalcule en direct.
  static Future<void> syncOrderDeliveryFee({
    required String shopId,
    required String partnerLocationId,
    required String orderId,
    required double feesTotal,
  }) async {
    final existing = entriesForShop(shopId)
        .where((e) => e.orderId == orderId
            && e.type == PartnerLedgerEntryType.deliveryOwed)
        .toList();
    for (final e in existing) {
      await deleteEntry(e.id, shopId);
    }
    if (feesTotal > 0) {
      await addEntry(
        shopId:            shopId,
        partnerLocationId: partnerLocationId,
        type:              PartnerLedgerEntryType.deliveryOwed,
        amount:            -feesTotal,
        orderId:           orderId,
        note:              'Frais de livraison déduits du versement',
      );
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

  /// Ancienneté EN JOURS de la plus vieille vente encaissée par le partenaire
  /// et pas encore couverte — « depuis combien de temps cet argent dort-il
  /// chez lui ? ». Clé = `partnerLocationId`. Partenaire absent de la map =
  /// rien qui vieillisse chez lui.
  ///
  /// LETTRAGE FIFO RESTREINT. On empile les `saleCollected` du plus ancien au
  /// plus récent, on impute dessus la TOTALITÉ des écritures négatives
  /// (versements reçus, frais de livraison, charges), et l'âge est celui de
  /// la première vente encore découverte.
  ///
  /// Les écritures POSITIVES qui ne sont pas des ventes — un `remittance`
  /// ÉMIS par la boutique, une `advance` — sont IGNORÉES des deux côtés :
  ///   * ni empilées : sinon régler un partenaire ferait REJAILLIR une date
  ///     fraîche, et sa vente de janvier paraîtrait dater d'hier ;
  ///   * ni comptées en crédit : de l'argent SORTI de la boutique n'éteint
  ///     pas une vente que le partenaire doit encore reverser. Les compter
  ///     inventerait une extinction qui n'a pas eu lieu.
  ///
  /// CONSÉQUENCE ASSUMÉE : un partenaire dont le solde n'est positif qu'à
  /// cause d'une avance non remboursée n'a PAS d'âge. C'est voulu — une
  /// avance consentie n'est pas un retard de reversement.
  ///
  /// Aucune donnée persistée : recalculé à chaque lecture, donc rien à
  /// migrer et aucune désynchronisation possible. Coût = une passe Hive,
  /// la même que [balancesForShop] ; les deux ne sont pas fusionnées pour
  /// ne pas toucher aux appelants existants.
  static Map<String, int> debtAgeByPartner(String shopId) {
    final sales   = <String, List<PartnerLedgerEntry>>{};
    final credits = <String, double>{};
    for (final e in entriesForShop(shopId)) {
      if (e.type == PartnerLedgerEntryType.saleCollected && e.amount > 0) {
        sales.putIfAbsent(e.partnerLocationId, () => []).add(e);
      } else if (e.amount < 0) {
        credits.update(e.partnerLocationId, (v) => v + e.amount.abs(),
            ifAbsent: () => e.amount.abs());
      }
    }
    final now = DateTime.now();
    final out = <String, int>{};
    sales.forEach((partnerId, list) {
      // `entriesForShop` trie du plus RÉCENT au plus ancien — le FIFO exige
      // l'inverse.
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      var credit = credits[partnerId] ?? 0.0;
      for (final sale in list) {
        // Tolérance 0.5 : même seuil que `pendingRemittanceByOrder`, pour
        // qu'un reliquat de centimes d'arrondi ne fasse pas vieillir une
        // vente en réalité soldée.
        if (sale.amount - credit <= 0.5) {
          credit -= sale.amount;
          if (credit < 0) credit = 0;
          continue;
        }
        // Première vente non couverte : c'est elle qui donne l'âge.
        final days = now.difference(sale.createdAt).inDays;
        if (days > 0) out[partnerId] = days;
        break;
      }
    });
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

  /// Supprime les mouvements liés à une commande.
  ///
  /// [keepReceived] (défaut false) : si true, PRÉSERVE les écritures
  /// FINANCIÈRES MANUELLES — `remittance` (versement réellement reçu du
  /// partenaire, marqué à la main) et `partnerCharge` (charge saisie, ex.
  /// course refusée). Ne purge alors que les écritures AUTO-générées à la
  /// complétion (`saleCollected`, `deliveryOwed`), qui seront recréées juste
  /// après. Indispensable pour qu'une re-complétion n'efface pas un versement
  /// déjà encaissé (sinon le bandeau « versement en attente » réapparaît).
  ///
  /// [keepReceived] = false (annulation pure d'une commande) : purge tout.
  static Future<void> removeForOrder(String shopId, String orderId,
      {bool keepReceived = false}) async {
    final box = HiveBoxes.partnerLedgerBox;
    final toDelete = <String>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      if (raw['shop_id']?.toString() != shopId) continue;
      if (raw['order_id']?.toString() != orderId) continue;
      if (keepReceived) {
        final t = raw['type']?.toString();
        // `advance` est listée par précaution : une avance est globale et
        // ne porte en principe aucun `order_id`, donc rien ne l'atteint
        // ici. Si elle venait à en porter un, une re-complétion de commande
        // effacerait un versement réellement sorti de la caisse.
        if (t == 'remittance' || t == 'partnerCharge' || t == 'advance') {
          continue;
        }
      }
      toDelete.add(key.toString());
    }
    for (final id in toDelete) {
      await deleteEntry(id, shopId);
    }
  }
}
