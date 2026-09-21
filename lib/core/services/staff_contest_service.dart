import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/staff_contest.dart';
import '../../features/restaurant/domain/entities/staff_member.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import '../utils/date_window.dart';

/// PRIMES SPÉCIALES — concours à durée déterminée (hotfix_165).
///
/// Ids `co_` + microsecondes. Push Supabase via `bgUpsert('staff_contests')`.
///
/// La prime se verse À CÔTÉ du salaire : elle n'entre dans aucune fiche de
/// paie, ne compte pas dans la masse salariale du mois, et n'est retenue nulle
/// part. C'est ce qui la garde exceptionnelle — fondue dans le salaire, elle
/// deviendrait un acquis que l'employé réclamerait le mois suivant.
///
/// Elle sort tout de même du TIROIR quand elle est versée en espèces : la
/// clôture de caisse doit la déduire (cf. [cashOut]), sans quoi elle
/// apparaîtrait le soir comme un manquant.
class StaffContestService {
  StaffContestService._();

  static Box<Map> _box() => HiveBoxes.staffContestsBox;

  static String _id() => 'co_${DateTime.now().microsecondsSinceEpoch}';

  /// Tous les concours de la boutique, le plus récemment terminé en tête.
  static List<StaffContest> forShop(String shopId) {
    try {
      final list = <StaffContest>[];
      for (final raw in _box().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(StaffContest.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => b.endDate.compareTo(a.endDate));
      return list;
    } catch (e) {
      debugPrint('[Contest] forShop err: $e');
      return [];
    }
  }

  /// Les concours qui DEMANDENT quelque chose au gérant : en cours (pour
  /// qu'il les annonce), terminés sans vainqueur, ou gagnés sans versement.
  /// C'est ce qui alimente la pastille du tableau de bord.
  static List<StaffContest> needingAttention(String shopId, {DateTime? now}) {
    final at = now ?? DateTime.now();
    return forShop(shopId).where((c) {
      final s = c.stateAt(at);
      return s == ContestState.toAward || s == ContestState.awarded;
    }).toList();
  }

  static Future<StaffContest> save(StaffContest c) async {
    await _put(c);
    return c;
  }

  static Future<StaffContest> create({
    required String shopId,
    required String title,
    required DateTime startDate,
    required DateTime endDate,
    String conditions = '',
    int prize = 0,
  }) async {
    final c = StaffContest(
      id: _id(),
      shopId: shopId,
      title: title.trim(),
      conditions: conditions.trim(),
      prize: prize,
      startDate: startDate,
      // Une fin antérieure au début donnerait un concours déjà terminé le jour
      // de son annonce : on la ramène au départ plutôt que de refuser.
      endDate: endDate.isBefore(startDate) ? startDate : endDate,
      createdAt: DateTime.now(),
    );
    return save(c);
  }

  /// Désigne le vainqueur. Le nom est FIGÉ : le palmarès doit rester lisible
  /// même si la fiche de l'employé disparaît un an plus tard.
  static Future<StaffContest> award(
      StaffContest c, StaffMember winner) async {
    final next = c.copyWith(
      winnerId: winner.id,
      winnerName: winner.fullName,
      awardedAt: DateTime.now(),
    );
    return save(next);
  }

  /// Retire le vainqueur — le gérant s'est trompé de personne. Efface aussi le
  /// versement : la prime a été remise à quelqu'un qui n'aurait pas dû la
  /// recevoir, et laisser la trace d'un paiement fausserait la caisse.
  static Future<StaffContest> clearWinner(StaffContest c) =>
      save(c.copyWith(clearWinner: true));

  static Future<StaffContest> markPaid(StaffContest c,
          {bool paidCash = true}) =>
      save(c.copyWith(paidAt: DateTime.now(), paidCash: paidCash));

  static Future<void> delete(StaffContest c) async {
    try {
      await _box().delete(c.id);
    } catch (e) {
      debugPrint('[Contest] delete err: $e');
    }
    AppDatabase.bgDelete('staff_contests', val: c.id);
    AppDatabase.notifyListeners('staff_contests', c.shopId);
  }

  /// Espèces sorties du tiroir pour des primes spéciales sur une période.
  static int cashOut(String shopId, {DateTime? from, DateTime? to}) {
    var total = 0;
    for (final c in forShop(shopId)) {
      final paidAt = c.paidAt;
      if (paidAt == null || !c.paidCash) continue;
      if (!withinOptionalBounds(paidAt, from: from, to: to)) continue;
      total += c.prize;
    }
    return total;
  }

  static Future<void> _put(StaffContest c) async {
    final map = c.toMap();
    try {
      await _box().put(c.id, map);
    } catch (e) {
      debugPrint('[Contest] put err: $e');
    }
    AppDatabase.bgUpsert('staff_contests', map);
    AppDatabase.notifyListeners('staff_contests', c.shopId);
  }
}
