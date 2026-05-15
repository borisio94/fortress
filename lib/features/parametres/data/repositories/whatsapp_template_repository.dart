import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/storage/hive_boxes.dart';
import '../../domain/entities/whatsapp_template.dart';

// ═════════════════════════════════════════════════════════════════════════════
// WhatsappTemplateRepository — CRUD des templates de message WhatsApp envoyés
// aux clients (cf. hotfix_067), calqué sur DeliveryTemplateRepository.
//
// Stratégie offline-first :
//   • Lecture : Hive immédiatement, refresh Supabase en arrière-plan.
//   • Mutations (create/update/delete) : online uniquement. Si offline, lève
//     une exception (templates = config rare).
//
// Unicité is_default=true PAR (shop_id, type) garantie par index unique
// partiel côté SQL. [_resetDefaults] reset les autres défauts du même type
// avant une mise à jour qui passe isDefault=true.
// ═════════════════════════════════════════════════════════════════════════════

class WhatsappTemplateRepository {
  static const _table = 'whatsapp_templates';

  SupabaseClient get _db => Supabase.instance.client;

  /// Liste les templates d'un shop depuis Hive. Tri : défaut en tête,
  /// puis par updatedAt desc.
  List<WhatsappTemplate> listFromCache(String shopId) {
    try {
      final box = HiveBoxes.whatsappTemplatesBox;
      return box.values
          .map((m) => WhatsappTemplate.fromMap(Map<String, dynamic>.from(m)))
          .where((t) => t.shopId == shopId)
          .toList()
        ..sort((a, b) {
          if (a.type != b.type) return a.type.key.compareTo(b.type.key);
          if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
          return b.updatedAt.compareTo(a.updatedAt);
        });
    } catch (e) {
      debugPrint('[WaTpl] cache read error: $e');
      return const [];
    }
  }

  /// Fetch depuis Supabase et synchronise Hive (purge des entrées stale).
  Future<List<WhatsappTemplate>> refreshFromRemote(String shopId) async {
    final rows = await _db.from(_table)
        .select()
        .eq('shop_id', shopId)
        .order('type',       ascending: true)
        .order('is_default', ascending: false)
        .order('updated_at', ascending: false);

    final list = (rows as List)
        .whereType<Map>()
        .map((m) => WhatsappTemplate.fromMap(Map<String, dynamic>.from(m)))
        .toList();

    final box = HiveBoxes.whatsappTemplatesBox;
    final remoteIds = list.map((t) => t.id).toSet();
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

  /// Crée un template. Si [isDefault] est true, reset les autres défauts du
  /// même type d'abord (index unique partiel SQL est strict).
  Future<WhatsappTemplate> create({
    required String                shopId,
    required WhatsappTemplateType  type,
    required String                name,
    required String                body,
    bool                           isDefault = false,
  }) async {
    if (isDefault) {
      await _resetDefaults(shopId, type, null);
    }
    final row = await _db.from(_table).insert({
      'shop_id':    shopId,
      'type':       type.key,
      'name':       name,
      'body':       body,
      'is_default': isDefault,
    }).select().single();

    final tpl = WhatsappTemplate.fromMap(Map<String, dynamic>.from(row));
    await HiveBoxes.whatsappTemplatesBox.put(tpl.id, tpl.toMap());
    return tpl;
  }

  Future<WhatsappTemplate> update(WhatsappTemplate tpl) async {
    if (tpl.isDefault) {
      await _resetDefaults(tpl.shopId, tpl.type, tpl.id);
    }
    final row = await _db.from(_table).update({
      'type':       tpl.type.key,
      'name':       tpl.name,
      'body':       tpl.body,
      'is_default': tpl.isDefault,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', tpl.id).select().single();

    final updated = WhatsappTemplate.fromMap(Map<String, dynamic>.from(row));
    await HiveBoxes.whatsappTemplatesBox.put(updated.id, updated.toMap());
    return updated;
  }

  Future<void> delete(String templateId) async {
    await _db.from(_table).delete().eq('id', templateId);
    await HiveBoxes.whatsappTemplatesBox.delete(templateId);
  }

  /// Reset is_default=false sur tous les templates du même (shopId, type)
  /// sauf [exceptId] si fourni.
  Future<void> _resetDefaults(
      String shopId, WhatsappTemplateType type, String? exceptId) async {
    var query = _db.from(_table)
        .update({'is_default': false})
        .eq('shop_id',    shopId)
        .eq('type',       type.key)
        .eq('is_default', true);
    if (exceptId != null && exceptId.isNotEmpty) {
      query = query.neq('id', exceptId);
    }
    await query;
    // Miroir Hive.
    final box = HiveBoxes.whatsappTemplatesBox;
    for (final k in box.keys.toList()) {
      final raw = box.get(k);
      if (raw is! Map) continue;
      if (raw['shop_id'] != shopId) continue;
      if (raw['type']    != type.key) continue;
      if (raw['id'] == exceptId)    continue;
      if (raw['is_default'] == true) {
        await box.put(k, {...raw, 'is_default': false});
      }
    }
  }

  /// Récupère le template par défaut d'un (shop, type), ou null si aucun.
  WhatsappTemplate? getDefault(String shopId, WhatsappTemplateType type) {
    final all = listFromCache(shopId).where((t) => t.type == type);
    for (final t in all) {
      if (t.isDefault) return t;
    }
    return all.isEmpty ? null : all.first;
  }

  /// Seed initial : crée un template par défaut pour chaque type s'il n'en
  /// existe encore aucun pour ce (shop, type). Idempotent.
  /// Appelé au premier accès à la page templates (et au login si besoin).
  Future<void> seedDefaultsIfMissing(String shopId) async {
    final existing = listFromCache(shopId);
    final existingTypes = existing.map((t) => t.type).toSet();
    for (final type in WhatsappTemplateType.values) {
      if (existingTypes.contains(type)) continue;
      try {
        await create(
          shopId:    shopId,
          type:      type,
          name:      type.defaultName,
          body:      type.defaultBody,
          isDefault: true,
        );
        debugPrint('[WaTpl] seed défaut créé : ${type.key}');
      } catch (e) {
        debugPrint('[WaTpl] seed ${type.key} failed: $e');
      }
    }
  }
}
