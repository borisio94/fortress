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

  /// Liste filtrée par scope. [partnerId] null = shop-wide uniquement ;
  /// [partnerId] non null = templates rattachés à ce partenaire uniquement.
  /// Pour récupérer le set complet (shop + partenaire), appeler
  /// `listFromCache(shopId)` puis filtrer côté caller.
  List<DeliveryTemplate> listForPartner(String shopId, String? partnerId) =>
      listFromCache(shopId)
          .where((t) => t.partnerId == partnerId)
          .toList();

  /// Crée un nouveau template. Si [isDefault] est true, reset les autres
  /// défauts du même scope (`partnerId`) avant l'insert — l'index unique
  /// partiel SQL est scoped sur `COALESCE(partner_id, sentinelle)`.
  Future<DeliveryTemplate> create({
    required String shopId,
    String?         partnerId,
    required String name,
    required String body,
    bool isDefault = false,
  }) async {
    if (isDefault) {
      await _resetDefaults(shopId, partnerId: partnerId);
    }
    final row = await _db.from(_table).insert({
      'shop_id':    shopId,
      'partner_id': partnerId,
      'name':       name,
      'body':       body,
      'is_default': isDefault,
    }).select().single();

    final tpl = DeliveryTemplate.fromMap(Map<String, dynamic>.from(row));
    await HiveBoxes.deliveryTemplatesBox.put(tpl.id, tpl.toMap());
    return tpl;
  }

  /// Met à jour un template existant. Si [isDefault] passe à true, reset
  /// les autres défauts du même scope d'abord. `partnerId` est persisté
  /// (permet aussi de RE-PORTER un template du shop vers un partenaire ou
  /// inversement en éditant le scope).
  Future<DeliveryTemplate> update(DeliveryTemplate tpl) async {
    if (tpl.isDefault) {
      await _resetDefaults(tpl.shopId,
          partnerId: tpl.partnerId, exceptId: tpl.id);
    }
    final row = await _db.from(_table).update({
      'partner_id': tpl.partnerId,
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

  /// Reset is_default=false sur tous les templates du même scope
  /// (shop_id + partner_id), sauf éventuellement [exceptId].
  Future<void> _resetDefaults(String shopId,
      {String? partnerId, String? exceptId}) async {
    var query = _db.from(_table)
        .update({'is_default': false})
        .eq('shop_id', shopId)
        .eq('is_default', true);
    // Filtre scope partenaire : null = "défaut shop-wide", sinon "défaut
    // du partenaire X". On NE PEUT PAS utiliser .eq() sur null avec
    // supabase-flutter — il faut .filter('partner_id', 'is', null).
    if (partnerId == null) {
      query = query.filter('partner_id', 'is', null);
    } else {
      query = query.eq('partner_id', partnerId);
    }
    if (exceptId != null && exceptId.isNotEmpty) {
      query = query.neq('id', exceptId);
    }
    await query;
    // Met à jour Hive en miroir — même filtre par scope.
    final box = HiveBoxes.deliveryTemplatesBox;
    for (final k in box.keys.toList()) {
      final raw = box.get(k);
      if (raw is! Map) continue;
      if (raw['shop_id'] != shopId) continue;
      if (raw['partner_id'] != partnerId) continue;
      if (raw['id'] == exceptId)    continue;
      if (raw['is_default'] == true) {
        await box.put(k, {...raw, 'is_default': false});
      }
    }
  }

  /// Récupère le template par défaut d'un scope donné. Si [partnerId] est
  /// fourni, cherche le défaut spécifique à ce partenaire ; à défaut
  /// retombe sur le défaut shop-wide. Retourne null si aucun template
  /// du tout (ne devrait pas arriver vu le seed shops_seed_delivery_template).
  DeliveryTemplate? getDefault(String shopId, {String? partnerId}) {
    if (partnerId != null) {
      // 1. Défaut explicite du partenaire.
      for (final t in listForPartner(shopId, partnerId)) {
        if (t.isDefault) return t;
      }
      // 2. Tout template du partenaire (cas dégradé : pas marqué défaut).
      final partnerTpls = listForPartner(shopId, partnerId);
      if (partnerTpls.isNotEmpty) return partnerTpls.first;
    }
    // 3. Défaut shop-wide.
    for (final t in listForPartner(shopId, null)) {
      if (t.isDefault) return t;
    }
    // 4. Premier shop-wide (dégradé).
    final shopTpls = listForPartner(shopId, null);
    if (shopTpls.isNotEmpty) return shopTpls.first;
    // 5. Vraiment rien : retourne le premier de la liste globale, sinon null.
    final all = listFromCache(shopId);
    return all.isEmpty ? null : all.first;
  }

  /// Résolution du template à utiliser pour un destinataire donné.
  /// Ordre de priorité :
  ///   1. [overrideTemplateId] si fourni et trouvé (choix explicite côté UI).
  ///   2. Défaut du partenaire si [partnerId] fourni.
  ///   3. Défaut shop-wide.
  ///   4. Premier template du shop (cas dégradé).
  ///   5. null (aucun template — ne devrait pas arriver vu le seed).
  DeliveryTemplate? resolveForRecipient({
    required String  shopId,
    String?         partnerId,
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
    return getDefault(shopId, partnerId: partnerId);
  }
}
