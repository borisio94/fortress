import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/caisse/domain/entities/sale.dart' show PaymentMethod;
import '../../features/restaurant/domain/entities/payment.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

/// Un règlement EN COURS DE SAISIE : ce que le caissier annonce avoir reçu,
/// avant que le partage entre montant imputé et rendu monnaie soit calculé.
class PaymentEntry {
  final PaymentMode mode;

  /// Ce que le client a tendu / transféré.
  final int received;

  /// Référence de transaction (numéro MTN/OM, ticket carte).
  final String? reference;

  const PaymentEntry({
    required this.mode,
    required this.received,
    this.reference,
  });
}

/// Un règlement APRÈS calcul : ce qui va réellement dans l'addition et ce qui
/// repart dans la main du client.
class PaymentLine {
  final PaymentMode mode;
  final int received;

  /// Part imputée à l'addition.
  final int applied;

  /// Rendu monnaie (espèces uniquement).
  final int change;

  /// Le client a donné plus que le reste dû par un moyen qui ne rend pas la
  /// monnaie (transfert mobile, carte) — c'est une erreur de saisie à
  /// signaler, pas un encaissement à empocher.
  final bool overpaid;

  final String? reference;

  const PaymentLine({
    required this.mode,
    required this.received,
    required this.applied,
    required this.change,
    required this.overpaid,
    this.reference,
  });
}

/// Répartition d'une addition entre plusieurs règlements — le cœur arithmétique
/// de l'encaissement mixte, volontairement PUR (aucun accès Hive) pour être
/// testable : c'est ce calcul qui décide de ce que le caissier rend au client.
class PaymentSplit {
  /// Montant dû au départ.
  final int due;

  final List<PaymentLine> lines;

  const PaymentSplit({required this.due, required this.lines});

  /// Total imputé à l'addition (hors rendu).
  int get applied => lines.fold(0, (s, l) => s + l.applied);

  /// Total rendu au client.
  int get change => lines.fold(0, (s, l) => s + l.change);

  /// Reste à payer, jamais négatif : un trop-perçu est un rendu, pas une
  /// dette négative.
  int get remaining {
    final r = due - applied;
    return r < 0 ? 0 : r;
  }

  bool get isSettled => remaining == 0;

  /// Au moins une ligne non-espèces dépasse le reste dû.
  bool get hasOverpay => lines.any((l) => l.overpaid);

  /// Plusieurs modes différents = règlement mixte. Déduit, jamais stocké :
  /// une valeur « mixed » figée pourrait contredire les lignes qu'elle résume.
  bool get isMixed => lines.map((l) => l.mode).toSet().length > 1;

  /// Répartit [entries] sur [due], dans l'ordre de saisie.
  ///
  /// Chaque règlement absorbe ce qui reste dû, au plus. Le surplus devient du
  /// rendu monnaie en espèces ; par tout autre moyen il est signalé
  /// ([PaymentLine.overpaid]) au lieu d'être encaissé — on ne peut pas rendre
  /// la monnaie d'un transfert MTN.
  static PaymentSplit compute(int due, List<PaymentEntry> entries) {
    var left = due < 0 ? 0 : due;
    final lines = <PaymentLine>[];
    for (final e in entries) {
      final received = e.received < 0 ? 0 : e.received;
      final applied = received > left ? left : received;
      final surplus = received - applied;
      lines.add(PaymentLine(
        mode: e.mode,
        received: received,
        applied: applied,
        change: e.mode.allowsChange ? surplus : 0,
        overpaid: !e.mode.allowsChange && surplus > 0,
        reference: e.reference,
      ));
      left -= applied;
    }
    return PaymentSplit(due: due < 0 ? 0 : due, lines: lines);
  }

  /// Mode dominant = celui qui a encaissé le plus gros montant. Il alimente
  /// `orders.payment_method`, qui ne connaît qu'une valeur par commande.
  ///
  /// À égalité, le premier saisi gagne — arbitraire mais stable, pour qu'une
  /// addition réglée moitié-moitié n'affiche pas un mode différent à chaque
  /// relecture.
  PaymentMethod get dominantMethod {
    if (lines.isEmpty) return PaymentMethod.cash;
    final byMode = <PaymentMode, int>{};
    for (final l in lines) {
      byMode[l.mode] = (byMode[l.mode] ?? 0) + l.applied;
    }
    var best = lines.first.mode;
    var bestAmount = -1;
    for (final l in lines) {
      final total = byMode[l.mode] ?? 0;
      if (total > bestAmount) {
        best = l.mode;
        bestAmount = total;
      }
    }
    return best.generic;
  }
}

/// Service Hive-first des règlements (Lot A — hotfix_145).
/// Ids `py_` + microsecondes. Push Supabase via `bgUpsert('payments')`.
///
/// Point d'entrée UNIQUE de l'encaissement détaillé : la ventilation par mode
/// (MTN vs Orange vs espèces) et le rendu monnaie en dépendent tous les deux.
class PaymentService {
  PaymentService._();

  static Box<Map> _raw() => HiveBoxes.paymentsBox;

  static String _id() => 'py_${DateTime.now().microsecondsSinceEpoch}';

  /// Règlements d'une commande, du plus ancien au plus récent.
  static List<Payment> forOrder(String shopId, String orderId) {
    try {
      final list = <Payment>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        if (raw['order_id']?.toString() != orderId) continue;
        try {
          list.add(Payment.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return list;
    } catch (e) {
      debugPrint('[Payment] forOrder err: $e');
      return [];
    }
  }

  /// Tous les règlements de la boutique sur une période (bornes incluses).
  /// Base de la ventilation par mode du rapport de caisse.
  static List<Payment> forShop(String shopId, {DateTime? from, DateTime? to}) {
    try {
      final list = <Payment>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final p = Payment.fromMap(Map<String, dynamic>.from(raw));
          if (from != null && p.createdAt.isBefore(from)) continue;
          if (to != null && p.createdAt.isAfter(to)) continue;
          list.add(p);
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    } catch (e) {
      debugPrint('[Payment] forShop err: $e');
      return [];
    }
  }

  /// Montant déjà encaissé sur une commande, d'après ses règlements.
  static int totalPaid(String shopId, String orderId) =>
      forOrder(shopId, orderId).fold(0, (s, p) => s + p.amount);

  /// Enregistre les lignes d'un encaissement. Les lignes à montant imputé nul
  /// sont ignorées : un règlement de 0 F n'apporte rien et polluerait la
  /// ventilation.
  static Future<List<Payment>> recordSplit({
    required String shopId,
    required String orderId,
    required PaymentSplit split,
  }) async {
    final out = <Payment>[];
    for (final l in split.lines) {
      if (l.applied <= 0) continue;
      final p = Payment(
        // Microsecondes + index : deux règlements saisis dans la même
        // milliseconde ne doivent pas partager la même clé primaire.
        id: '${_id()}_${out.length}',
        shopId: shopId,
        orderId: orderId,
        method: l.mode.key,
        amount: l.applied,
        reference: l.reference,
        changeGiven: l.change,
        createdAt: DateTime.now(),
      );
      await _put(p);
      out.add(p);
    }
    return out;
  }

  static Future<void> _put(Payment p) async {
    final map = p.toMap();
    try {
      await _raw().put(p.id, map);
    } catch (e) {
      debugPrint('[Payment] put Hive err: $e');
    }
    AppDatabase.bgUpsert('payments', map);
    AppDatabase.notifyListeners('payments', p.shopId);
  }

  static Future<void> delete(String id, String shopId) async {
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[Payment] delete Hive err: $e');
    }
    AppDatabase.bgDelete('payments', val: id);
    AppDatabase.notifyListeners('payments', shopId);
  }
}
