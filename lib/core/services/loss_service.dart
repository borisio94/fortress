import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/loss.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';

/// Service Hive-first des déclarations de pertes (module finances — PR-C).
/// Ids `ls_` + microsecondes. Push Supabase via `bgUpsert('losses')`.
///
/// Point d'entrée UNIQUE pour toute perte : saisie manuelle (page Pertes) ET
/// perte issue d'un écart d'inventaire (réconciliation, Lot 3) passent par
/// [record] afin que les règles de catégorie et la synchro restent au même
/// endroit.
class LossService {
  LossService._();

  static Box<Map> _raw() => HiveBoxes.lossesBox;

  static String _id() => 'ls_${DateTime.now().microsecondsSinceEpoch}';

  static List<Loss> forShop(String shopId) {
    try {
      final list = <Loss>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(Loss.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      // Les plus récentes en tête.
      list.sort((a, b) => b.date.compareTo(a.date));
      return list;
    } catch (e) {
      debugPrint('[Loss] forShop err: $e');
      return [];
    }
  }

  static Loss? byId(String shopId, String id) {
    try {
      final raw = _raw().get(id);
      if (raw == null) return null;
      final l = Loss.fromMap(Map<String, dynamic>.from(raw));
      return l.shopId == shopId ? l : null;
    } catch (_) {
      return null;
    }
  }

  /// Enregistre une perte. Point d'entrée unique (saisie + réconciliation).
  static Future<Loss> record({
    required String shopId,
    required String description,
    required int amount,
    String category = 'autre',
    String origin = '',
    DateTime? date,
    String? declaredBy,
    /// Assiettes perdues — rend la perte « matière » (cf. [Loss.isMaterial]).
    List<WastedPlate> items = const [],
    /// Ingrédient manquant — rend la perte « matière » (cf. [Loss.isMaterial]).
    String? ingredientId,
  }) async {
    final l = Loss(
      id: _id(),
      shopId: shopId,
      description: description.trim(),
      amount: amount,
      category: category,
      origin: origin,
      date: date ?? DateTime.now(),
      declaredBy: declaredBy,
      items: items,
      ingredientId: ingredientId,
      createdAt: DateTime.now(),
    );
    await _put(l);
    return l;
  }

  static Future<void> update(Loss l) => _put(l);

  /// Toute écriture passe ici : c'est donc ici que la règle de rattachement
  /// est tenue, pour la saisie manuelle comme pour les écritures
  /// automatiques (incidents, réconciliation, consignes). Une perte de
  /// matière sans rattachement serait comptée deux fois par le bilan.
  static Future<void> _put(Loss l) async {
    final issue = l.attachmentIssue;
    if (issue != null) throw LossAttachmentException(issue);
    final map = l.toMap();
    try {
      await _raw().put(l.id, map);
    } catch (e) {
      debugPrint('[Loss] put Hive err: $e');
    }
    AppDatabase.bgUpsert('losses', map);
    AppDatabase.notifyListeners('losses', l.shopId);
  }

  static Future<void> delete(String id, String shopId) async {
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[Loss] delete Hive err: $e');
    }
    AppDatabase.bgDelete('losses', val: id);
    AppDatabase.notifyListeners('losses', shopId);
  }

  /// Total des pertes de la boutique sur une période (bornes incluses). Sans
  /// bornes : toutes les pertes. Utilisé par le reporting (Lot 2) et le bilan.
  static int total(String shopId, {DateTime? from, DateTime? to}) {
    var sum = 0;
    for (final l in forShop(shopId)) {
      if (from != null && l.date.isBefore(from)) continue;
      if (to != null && l.date.isAfter(to)) continue;
      sum += l.amount;
    }
    return sum;
  }
}
