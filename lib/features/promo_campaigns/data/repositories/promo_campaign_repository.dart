import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/storage/hive_boxes.dart';
import '../../domain/entities/promo_campaign.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PromoCampaignRepository — CRUD des campagnes marketing (cf. hotfix_068).
//
// Stratégie offline-first calquée sur les autres repositories du projet :
//   • Lecture : Hive d'abord, refresh Supabase en arrière-plan.
//   • Mutations : online uniquement (config rare, on accepte la friction).
//
// Méthodes spécifiques :
//   • [getById]            : pour la page vitrine publique
//   • [incrementSent]      : appelé après chaque wa.me ouvert (stats)
//   • [incrementView]      : appelé au mount de la vitrine (stats)
// ═════════════════════════════════════════════════════════════════════════════

class PromoCampaignRepository {
  static const _table = 'promo_campaigns';

  SupabaseClient get _db => Supabase.instance.client;

  List<PromoCampaign> listFromCache(String shopId) {
    try {
      final box = HiveBoxes.promoCampaignsBox;
      return box.values
          .map((m) => PromoCampaign.fromMap(Map<String, dynamic>.from(m)))
          .where((c) => c.shopId == shopId)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      debugPrint('[Promo] cache read error: $e');
      return const [];
    }
  }

  Future<List<PromoCampaign>> refreshFromRemote(String shopId) async {
    final rows = await _db.from(_table)
        .select()
        .eq('shop_id', shopId)
        .order('created_at', ascending: false);

    final list = (rows as List)
        .whereType<Map>()
        .map((m) => PromoCampaign.fromMap(Map<String, dynamic>.from(m)))
        .toList();

    final box = HiveBoxes.promoCampaignsBox;
    final remoteIds = list.map((c) => c.id).toSet();
    final stale = box.keys.where((k) {
      final raw = box.get(k);
      if (raw is! Map) return false;
      return raw['shop_id'] == shopId && !remoteIds.contains(raw['id']);
    }).toList();
    for (final k in stale) {
      await box.delete(k);
    }
    for (final c in list) {
      await box.put(c.id, c.toMap());
    }
    return list;
  }

  /// Récupère une campagne par ID — utilisé par la page vitrine publique.
  /// Tente Hive d'abord, fallback Supabase si absent (cas anonyme).
  Future<PromoCampaign?> getById(String campaignId) async {
    try {
      final raw = HiveBoxes.promoCampaignsBox.get(campaignId);
      if (raw is Map) {
        return PromoCampaign.fromMap(Map<String, dynamic>.from(raw));
      }
    } catch (_) {/* fallthrough */}
    try {
      final row = await _db.from(_table)
          .select().eq('id', campaignId).maybeSingle();
      if (row == null) return null;
      final c = PromoCampaign.fromMap(Map<String, dynamic>.from(row));
      await HiveBoxes.promoCampaignsBox.put(c.id, c.toMap());
      return c;
    } catch (e) {
      debugPrint('[Promo] getById error: $e');
      return null;
    }
  }

  Future<PromoCampaign> create({
    required String                   shopId,
    required PromoCampaignType        type,
    required String                   name,
    required List<PromoProductSnapshot> products,
    int?                              discountPercent,
    DateTime?                         validUntil,
    String?                           description,
  }) async {
    final row = await _db.from(_table).insert({
      'shop_id':          shopId,
      'type':             type.key,
      'name':             name,
      'products':         products.map((p) => p.toMap()).toList(),
      'discount_percent': discountPercent,
      'valid_until':      validUntil?.toIso8601String(),
      'description':      description,
    }).select().single();

    final c = PromoCampaign.fromMap(Map<String, dynamic>.from(row));
    await HiveBoxes.promoCampaignsBox.put(c.id, c.toMap());
    return c;
  }

  Future<PromoCampaign> update(PromoCampaign c) async {
    final row = await _db.from(_table).update({
      'type':             c.type.key,
      'name':             c.name,
      'products':         c.products.map((p) => p.toMap()).toList(),
      'discount_percent': c.discountPercent,
      'valid_until':      c.validUntil?.toIso8601String(),
      'description':      c.description,
      'updated_at':       DateTime.now().toUtc().toIso8601String(),
    }).eq('id', c.id).select().single();

    final updated = PromoCampaign.fromMap(Map<String, dynamic>.from(row));
    await HiveBoxes.promoCampaignsBox.put(updated.id, updated.toMap());
    return updated;
  }

  Future<void> delete(String campaignId) async {
    await _db.from(_table).delete().eq('id', campaignId);
    await HiveBoxes.promoCampaignsBox.delete(campaignId);
  }

  /// Incrément atomique de sent_count via RPC (SECURITY DEFINER).
  /// Fire-and-forget : ne bloque pas l'UX d'envoi WhatsApp.
  Future<void> incrementSent(String campaignId) async {
    try {
      await _db.rpc('increment_promo_sent',
          params: {'campaign_id': campaignId});
    } catch (e) {
      debugPrint('[Promo] increment_sent failed: $e');
    }
  }

  /// Idem pour view_count, appelé au mount de la vitrine publique.
  Future<void> incrementView(String campaignId) async {
    try {
      await _db.rpc('increment_promo_view',
          params: {'campaign_id': campaignId});
    } catch (e) {
      debugPrint('[Promo] increment_view failed: $e');
    }
  }
}
