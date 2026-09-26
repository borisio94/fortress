import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/staff_member.dart';
import '../../features/restaurant/domain/entities/staff_rating.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'staff_service.dart';

/// NOTATION DU PERSONNEL (hotfix_165).
///
/// Ids `ra_` + microsecondes. Push Supabase via `bgUpsert('staff_ratings')`.
///
/// Ce service ne stocke JAMAIS de note. Il stocke des événements signés — « −2,
/// plainte de la table 4 jugée fondée » — et redéduit la note à la lecture :
/// 10 points de base, plus la somme des événements du MOIS.
///
/// La remise à 10 mensuelle ne s'écrit donc nulle part : elle découle du filtre
/// sur le mois. Aucune tâche planifiée à faire tourner le 1er, aucun compteur
/// à remettre à zéro, et rien qui puisse se désynchroniser entre deux
/// appareils.
class StaffScoreService {
  StaffScoreService._();

  static Box<Map> _box() => HiveBoxes.staffRatingsBox;

  static String _id() => 'ra_${DateTime.now().microsecondsSinceEpoch}';

  static String monthKey(DateTime d) => StaffRating.monthKey(d);

  /// Événements d'une boutique, le plus récent en tête.
  static List<StaffRating> ratings(
    String shopId, {
    String? employeeId,
    String? month,
  }) {
    try {
      final list = <StaffRating>[];
      for (final raw in _box().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final r = StaffRating.fromMap(Map<String, dynamic>.from(raw));
          if (employeeId != null && r.employeeId != employeeId) continue;
          if (month != null && r.month != month) continue;
          list.add(r);
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    } catch (e) {
      debugPrint('[Score] ratings err: $e');
      return [];
    }
  }

  /// La note d'un employé sur un mois.
  static StaffScore scoreOf(String shopId, String employeeId, String month) {
    final sum = ratings(shopId, employeeId: employeeId, month: month)
        .fold<int>(0, (s, r) => s + r.points);
    return StaffScore(sum);
  }

  /// LE CLASSEMENT DU MOIS — meilleur en tête.
  ///
  /// Ne retient que les employés ACTIFS : classer un employé archivé le ferait
  /// concourir avec ceux qui travaillent encore, et un ancien resté à 10 tout
  /// le mois de son départ trusterait la première place.
  static List<({StaffMember member, StaffScore score})> ranking(
    String shopId, {
    String? month,
  }) {
    final key = month ?? monthKey(DateTime.now());
    final out = <({StaffMember member, StaffScore score})>[];
    for (final m in StaffService.forShop(shopId, onlyActive: true)) {
      out.add((member: m, score: scoreOf(shopId, m.id, key)));
    }
    out.sort((a, b) {
      final c = StaffScore.compare(a.score, b.score);
      // À note égale, l'ordre alphabétique — sinon le classement se
      // réordonnerait à chaque rafraîchissement, sur le seul hasard de Hive.
      return c != 0
          ? c
          : a.member.fullName.toLowerCase()
              .compareTo(b.member.fullName.toLowerCase());
    });
    return out;
  }

  /// Ceux qui sont passés sous le seuil — l'alerte du tableau de bord.
  static List<({StaffMember member, StaffScore score})> toReplace(
    String shopId, {
    String? month,
  }) =>
      ranking(shopId, month: month)
          .where((e) => e.score.needsReplacement)
          .toList();

  /// Retire des points. [points] se donne POSITIF, le signe est appliqué ici —
  /// un appelant qui se tromperait de signe transformerait une sanction en
  /// récompense.
  static Future<StaffRating> penalize({
    required StaffMember member,
    required int points,
    required String reason,
    String source = StaffRating.sourceComplaint,
    DateTime? at,
  }) =>
      _record(
        member: member,
        points: -points.abs(),
        reason: reason,
        source: source,
        at: at,
      );

  /// Ajoute des points à un employé modèle.
  static Future<StaffRating> reward({
    required StaffMember member,
    required int points,
    required String reason,
    DateTime? at,
  }) =>
      _record(
        member: member,
        points: points.abs(),
        reason: reason,
        source: StaffRating.sourceBonus,
        at: at,
      );

  static Future<StaffRating> _record({
    required StaffMember member,
    required int points,
    required String reason,
    required String source,
    DateTime? at,
  }) async {
    final when = at ?? DateTime.now();
    final r = StaffRating(
      id: _id(),
      shopId: member.shopId,
      employeeId: member.id,
      employeeName: member.fullName,
      points: points,
      reason: reason.trim(),
      source: source,
      month: monthKey(when),
      createdAt: when,
    );
    final map = r.toMap();
    try {
      await _box().put(r.id, map);
    } catch (e) {
      debugPrint('[Score] put err: $e');
    }
    AppDatabase.bgUpsert('staff_ratings', map);
    AppDatabase.notifyListeners('staff_ratings', r.shopId);
    return r;
  }

  /// Annule un événement — le gérant s'est trompé, ou la plainte n'était pas
  /// fondée après vérification. La note remonte d'elle-même, puisqu'elle n'est
  /// que la somme de ce qui reste.
  static Future<void> delete(StaffRating r) async {
    try {
      await _box().delete(r.id);
    } catch (e) {
      debugPrint('[Score] delete err: $e');
    }
    AppDatabase.bgDelete('staff_ratings', val: r.id);
    AppDatabase.notifyListeners('staff_ratings', r.shopId);
  }
}
