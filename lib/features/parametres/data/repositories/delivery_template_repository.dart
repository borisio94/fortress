import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/storage/hive_boxes.dart';
import '../../domain/entities/delivery_template.dart';

/// CRUD des templates de message WhatsApp pour le transfert de commande
/// au livreur (cf. hotfix_049).
///
/// Stratégie offline-first :
///   • **Lecture** : lit Hive immédiatement (cache key = template.id) puis
///     fetch Supabase en arrière-plan via [refreshFromRemote] et update Hive
///     si différent.
///   • **Mutations** (create/update/delete/setDefault) : online uniquement.
///     Si offline, on lève une exception (templates = config rare, on
///     accepte la friction). Hive est mis à jour APRÈS le succès Supabase.
///
/// L'unicité du `is_default=true` par shop est garantie côté SQL via un
/// index unique partiel. Côté Dart, [setDefault] reset puis update dans le
/// même try/catch.
class DeliveryTemplateRepository {
  static const _table = 'delivery_templates';

  SupabaseClient get _db => Supabase.instance.client;

  /// Liste les templates d'un shop depuis Hive (cache local).
  /// Pour rafraîchir, appeler [refreshFromRemote] séparément.
  List<DeliveryTemplate> listFromCache(String shopId) {
    try {
      final box = HiveBoxes.deliveryTemplatesBox;
      return box.values
          .map((m) => DeliveryTemplate.fromMap(Map<String, dynamic>.from(m)))
          .where((t) => t.shopId == shopId)
          .toList()
        ..sort((a, b) {
          // Le défaut en tête, puis par updated_at desc.
          if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
          return b.updatedAt.compareTo(a.updatedAt);
        });
    } catch (e) {
      debugPrint('[DeliveryTpl] cache read error: $e');
      return const [];
    }
  }

  /// Fetch depuis Supabase et synchronise Hive (purge des entrées du shop
  /// qui n'existent plus côté serveur).
  Future<List<DeliveryTemplate>> refreshFromRemote(String shopId) async {
    final rows = await _db.from(_table)
        .select()
        .eq('shop_id', shopId)
        .order('is_default', ascending: false)
        .order('updated_at', ascending: false);

    final list = (rows as List)
        .whereType<Map>()
        .map((m) => DeliveryTemplate.fromMap(Map<String, dynamic>.from(m)))
        .toList();

    final box = HiveBoxes.deliveryTemplatesBox;
    final remoteIds = list.map((t) => t.id).toSet();
    // Purge des entrées locales du shop qui n'existent plus côté distant.
    final stale = box.keys.where((k) {
      final raw = box.get(k);
      if (raw is! Map) return false;
      return raw['shop_id'] == shopId && !remoteIds.contains(raw['id']);
    }).toList();
    for (final k in stale) {
      await box.delete(k);
    }
    for (final t in list) {
      await box.put(t.id, t.toMap());
    }
    return list;
  }

  /// Crée un nouveau template. Si [isDefault] est true, reset les autres
  /// défauts du shop avant l'insert (l'index unique partiel SQL est strict).
  Future<DeliveryTemplate> create({
    required String shopId,
    required String name,
    required String body,
    bool isDefault = false,
  }) async {
    if (isDefault) {
      await _resetDefaults(shopId);
    }
    final row = await _db.from(_table).insert({
      'shop_id':    shopId,
      'name':       name,
      'body':       body,
      'is_default': isDefault,
    }).select().single();

    final tpl = DeliveryTemplate.fromMap(Map<String, dynamic>.from(row));
    await HiveBoxes.deliveryTemplatesBox.put(tpl.id, tpl.toMap());
    return tpl;
  }

  /// Met à jour un template existant. Si [isDefault] passe à true, reset les
  /// autres défauts du shop d'abord.
  Future<DeliveryTemplate> update(DeliveryTemplate tpl) async {
    if (tpl.isDefault) {
      await _resetDefaults(tpl.shopId, exceptId: tpl.id);
    }
    final row = await _db.from(_table).update({
      'name':       tpl.name,
      'body':       tpl.body,
      'is_default': tpl.isDefault,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', tpl.id).select().single();

    final updated = DeliveryTemplate.fromMap(Map<String, dynamic>.from(row));
    await HiveBoxes.deliveryTemplatesBox.put(updated.id, updated.toMap());
    return updated;
  }

  Future<void> delete(String templateId) async {
    await _db.from(_table).delete().eq('id', templateId);
    await HiveBoxes.deliveryTemplatesBox.delete(templateId);
  }

  /// Reset is_default=false sur tous les templates du shop (sauf
  /// éventuellement [exceptId]).
  Future<void> _resetDefaults(String shopId, {String? exceptId}) async {
    var query = _db.from(_table)
        .update({'is_default': false})
        .eq('shop_id', shopId)
        .eq('is_default', true);
    if (exceptId != null && exceptId.isNotEmpty) {
      query = query.neq('id', exceptId);
    }
    await query;
    // Met à jour Hive en miroir.
    final box = HiveBoxes.deliveryTemplatesBox;
    for (final k in box.keys.toList()) {
      final raw = box.get(k);
      if (raw is! Map) continue;
      if (raw['shop_id'] != shopId) continue;
      if (raw['id'] == exceptId)    continue;
      if (raw['is_default'] == true) {
        await box.put(k, {...raw, 'is_default': false});
      }
    }
  }

  /// Récupère le template par défaut d'un shop, ou null si aucun.
  DeliveryTemplate? getDefault(String shopId) {
    final all = listFromCache(shopId);
    for (final t in all) {
      if (t.isDefault) return t;
    }
    return all.isEmpty ? null : all.first;
  }

  /// Résolution du template à utiliser pour un destinataire donné.
  /// Ordre :
  ///   1. [overrideTemplateId] si fourni et trouvé.
  ///   2. Template par défaut du shop.
  ///   3. Premier template du shop (cas dégradé).
  ///   4. null (aucun template — ne devrait pas arriver vu le seed).
  DeliveryTemplate? resolveForRecipient({
    required String  shopId,
    String?         overrideTemplateId,
  }) {
    if (overrideTemplateId != null && overrideTemplateId.isNotEmpty) {
      try {
        final raw = HiveBoxes.deliveryTemplatesBox.get(overrideTemplateId);
        if (raw is Map) {
          return DeliveryTemplate.fromMap(Map<String, dynamic>.from(raw));
        }
      } catch (_) {/* fallthrough */}
    }
    return getDefault(shopId);
  }
}
