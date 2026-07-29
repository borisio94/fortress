import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/caisse/data/repositories/sale_local_datasource.dart';
import '../../features/caisse/domain/entities/sale.dart';
import '../../features/restaurant/domain/entities/cash_closure.dart';
import '../../features/restaurant/domain/entities/payment.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'daily_expense_service.dart';
import 'staff_service.dart';
import 'payment_service.dart';

/// Clôture de caisse aveugle — rapports X et Z (Lot C — hotfix_147).
///
/// Ids `cc_` + microsecondes. Push Supabase via `bgUpsert('cash_closures')`.
///
/// Le total attendu ne doit JAMAIS être affiché avant que le caissier ait
/// validé son comptage : c'est la seule chose qui rend un manquant visible.
/// L'UI appelle donc [systemCash] APRÈS la saisie, jamais avant.
class CashClosureService {
  CashClosureService._();

  static final SaleLocalDatasource _ds = SaleLocalDatasource();

  static Box<Map> _raw() => HiveBoxes.cashClosuresBox;

  static String _id() => 'cc_${DateTime.now().microsecondsSinceEpoch}';

  /// Clé Hive du fond de caisse, par boutique (préférence locale : le fond est
  /// une habitude de la caisse, pas une donnée à synchroniser).
  static String _floatKey(String shopId) => 'cash_float_$shopId';

  /// Fond de caisse de la boutique (0 par défaut).
  ///
  /// Lu D'ABORD sur la dernière clôture enregistrée, qui est SYNCHRONISÉE :
  /// sans ça, la tablette de salle (fond 20 000) et le téléphone du gérant
  /// (fond 0) calculaient deux totaux attendus différents pour la même caisse,
  /// et l'un des deux annonçait un écart de 20 000 F.
  ///
  /// La préférence locale ne sert plus que de valeur de démarrage, avant la
  /// toute première clôture — et de mémoire de saisie sur l'appareil qui l'a
  /// renseignée.
  static int openingFloat(String shopId) {
    for (final c in forShop(shopId)) {
      if (c.openingFloat > 0) return c.openingFloat;
    }
    return localFloat(shopId);
  }

  /// Valeur saisie sur CET appareil (préférence locale).
  static int localFloat(String shopId) {
    try {
      final v = HiveBoxes.settingsBox.get(_floatKey(shopId));
      return (v as num?)?.toInt() ?? 0;
    } catch (e) {
      debugPrint('[Closure] lecture fond err: $e');
      return 0;
    }
  }

  static Future<void> setOpeningFloat(String shopId, int amount) async {
    try {
      await HiveBoxes.settingsBox
          .put(_floatKey(shopId), amount < 0 ? 0 : amount);
    } catch (e) {
      debugPrint('[Closure] écriture fond err: $e');
    }
  }

  /// Toutes les clôtures de la boutique, la plus récente en tête.
  static List<CashClosure> forShop(String shopId) {
    try {
      final list = <CashClosure>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(CashClosure.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => b.closedAt.compareTo(a.closedAt));
      return list;
    } catch (e) {
      debugPrint('[Closure] forShop err: $e');
      return [];
    }
  }

  /// Dernière clôture de journée, ou `null` s'il n'y en a jamais eu.
  static CashClosure? lastZ(String shopId) {
    for (final c in forShop(shopId)) {
      if (c.isZ) return c;
    }
    return null;
  }

  /// Début de la période courante : la fin de la dernière clôture Z, ou minuit
  /// si la boutique n'en a jamais fait.
  ///
  /// Le repli sur minuit est important : sans lui, la première clôture d'une
  /// boutique agrégerait TOUT son historique d'encaissements et afficherait un
  /// manquant de plusieurs millions.
  static DateTime periodStart(String shopId) {
    final z = lastZ(shopId);
    if (z != null) return z.closedAt;
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// Espèces attendues dans le tiroir pour la période courante.
  static int systemCash(String shopId, {DateTime? from, DateTime? to}) {
    final start = from ?? periodStart(shopId);
    final end = to ?? DateTime.now();
    try {
      final payments = PaymentService.forShop(shopId, from: start, to: end);
      final orders = _ds
          .getOrders(shopId)
          .where((o) => !o.isDeleted)
          .where((o) => o.status == SaleStatus.completed)
          .where((o) {
            final at = _settledAt(o);
            return !at.isBefore(start) && !at.isAfter(end);
          })
          .toList();
      return computeSystemCash(
        openingFloat: openingFloat(shopId),
        payments: payments,
        orders: orders,
        // TOUTES les sorties d'espèces de la période : dépenses du jour
        // (achat au marché…), avances sur salaire versées du tiroir, salaires
        // payés en liquide, et remboursements de consigne — ces derniers
        // arrivent en dépenses via la catégorie `consigne_rendue`.
        //
        // Chacune de ces sorties, non déduite, apparaissait le soir comme un
        // manquant imputé au caissier.
        cashOut: DailyExpenseService.cashOut(shopId, from: start, to: end) +
            StaffService.cashOut(shopId, from: start, to: end),
      );
    } catch (e) {
      debugPrint('[Closure] systemCash err: $e');
      return openingFloat(shopId);
    }
  }

  /// Moment où l'argent est entré en caisse.
  ///
  /// `Sale` ne porte pas `completedAt` — la date de clôture n'existe que dans
  /// la map brute. La lire ici est indispensable : une table ouverte hier et
  /// réglée ce matin appartient à la caisse de CE MATIN. Se rabattre sur
  /// `createdAt` la rangerait dans une période déjà clôturée, et l'argent
  /// compté ce soir apparaîtrait en excédent.
  static DateTime _settledAt(Sale order) {
    try {
      final raw = HiveBoxes.ordersBox.get(order.id ?? '');
      final at = raw?['completed_at'];
      if (at != null && at.toString().isNotEmpty) {
        final parsed = DateTime.tryParse(at.toString())?.toLocal();
        if (parsed != null) return parsed;
      }
    } catch (_) {/* box indisponible : repli sur la création */}
    return order.createdAt;
  }

  /// LE calcul du total attendu, isolé de Hive pour être testable.
  ///
  /// Deux sources d'encaissement coexistent, et c'est le piège de ce module :
  ///   * les règlements détaillés (`payments`, Lot A) — service en salle et
  ///     comptoir. Seule la part `cash` entre dans le tiroir ; `amount` est
  ///     déjà net du rendu monnaie ;
  ///   * les commandes encaissées par l'écran Caisse, qui n'écrivent PAS de
  ///     ligne de règlement et ne portent qu'une méthode globale.
  ///
  /// Une commande qui a des règlements est donc EXCLUE du second comptage :
  /// sans cette exclusion, une addition réglée moitié espèces moitié MTN
  /// serait comptée une fois pour sa part espèces, puis une seconde fois pour
  /// son total — et la caisse afficherait un excédent qui n'existe pas.
  ///
  /// [cashOut] est ce qui est SORTI du tiroir sur la période (achats au marché
  /// et autres dépenses réglées en espèces).
  @visibleForTesting
  static int computeSystemCash({
    required int openingFloat,
    required List<Payment> payments,
    required List<Sale> orders,
    int cashOut = 0,
  }) {
    var total = openingFloat - cashOut;
    final covered = <String>{};
    for (final p in payments) {
      covered.add(p.orderId);
      if (p.mode == PaymentMode.cash) total += p.amount;
    }
    for (final o in orders) {
      final id = o.id ?? '';
      if (id.isNotEmpty && covered.contains(id)) continue;
      if (o.paymentMethod != PaymentMethod.cash) continue;
      // Une commande soldée a pu être marquée payée sans que `amountPaid` soit
      // peuplé (commandes antérieures au suivi de paiement) : son total est
      // alors ce qui est entré en caisse.
      final cash = o.isFullyPaid ? o.total : o.amountPaid;
      total += cash.round();
    }
    return total;
  }

  /// Enregistre un comptage. [declaredCash] est ce que le caissier a compté,
  /// [systemAmount] ce que le système attendait — l'appelant le calcule APRÈS
  /// la saisie, jamais avant.
  static Future<CashClosure> record({
    required String shopId,
    required int declaredCash,
    required int systemAmount,
    required bool isZ,
    DateTime? periodFrom,
    String? cashierId,
    String? cashierName,
    String? note,
  }) async {
    final c = CashClosure(
      id: _id(),
      shopId: shopId,
      cashierId: cashierId,
      cashierName: cashierName,
      closureType: isZ ? 'Z' : 'X',
      declaredCash: declaredCash,
      systemCash: systemAmount,
      variance: CashClosure.varianceOf(declaredCash, systemAmount),
      openingFloat: openingFloat(shopId),
      periodStart: periodFrom ?? periodStart(shopId),
      note: note,
      closedAt: DateTime.now(),
    );
    await _put(c);
    return c;
  }

  static Future<void> _put(CashClosure c) async {
    final map = c.toMap();
    try {
      await _raw().put(c.id, map);
    } catch (e) {
      debugPrint('[Closure] put Hive err: $e');
    }
    AppDatabase.bgUpsert('cash_closures', map);
    AppDatabase.notifyListeners('cash_closures', c.shopId);
  }
}
