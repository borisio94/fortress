import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/storage/hive_boxes.dart';
import '../domain/entities/shop_ticket.dart';

/// Repository tickets v1 — texte seul, mono-shop, sans escalade côté
/// service (l'escalade arrive en 4B). Cache offline-first via Hive ;
/// les RLS Supabase couvrent l'accès.
class TicketRepository {
  static SupabaseClient get _db => Supabase.instance.client;

  // ── Sync ────────────────────────────────────────────────────────────────

  /// Pull les tickets de la shop dans Hive. Idempotent.
  Future<void> syncTickets(String shopId) async {
    try {
      final rows = await _db
          .from('shop_tickets')
          .select()
          .eq('shop_id', shopId)
          .order('created_at', ascending: false);
      final box = HiveBoxes.shopTicketsBox;
      // On purge les tickets locaux de cette shop avant de re-écrire (évite
      // les fantômes après suppression côté serveur ; on garde les autres
      // shops intactes).
      final keysToPurge = <dynamic>[];
      for (final k in box.keys) {
        final v = box.get(k);
        if (v is Map && v['shop_id'] == shopId) keysToPurge.add(k);
      }
      for (final k in keysToPurge) {
        box.delete(k);
      }
      for (final r in rows as List) {
        final m = Map<String, dynamic>.from(r as Map);
        await box.put(m['id'], m);
      }
      debugPrint('[Tickets] sync $shopId → ${rows.length} tickets');
    } catch (e) {
      debugPrint('[Tickets] sync $shopId error: $e');
    }
  }

  /// Pull les messages d'un ticket dans Hive.
  Future<void> syncMessages(String ticketId) async {
    try {
      final rows = await _db
          .from('shop_ticket_messages')
          .select()
          .eq('ticket_id', ticketId)
          .order('created_at', ascending: true);
      final box = HiveBoxes.ticketMessagesBox;
      // Purge ciblée — uniquement les messages de ce ticket.
      final keysToPurge = <dynamic>[];
      for (final k in box.keys) {
        final v = box.get(k);
        if (v is Map && v['ticket_id'] == ticketId) keysToPurge.add(k);
      }
      for (final k in keysToPurge) {
        box.delete(k);
      }
      for (final r in rows as List) {
        final m = Map<String, dynamic>.from(r as Map);
        await box.put(m['id'], m);
      }
    } catch (e) {
      debugPrint('[Tickets] syncMessages $ticketId error: $e');
    }
  }

  // ── Lecture locale ──────────────────────────────────────────────────────

  /// Tickets de la shop, plus récent d'abord.
  List<ShopTicket> getTickets(String shopId) {
    final out = <ShopTicket>[];
    for (final raw in HiveBoxes.shopTicketsBox.values) {
      try {
        final t = ShopTicket.fromMap(Map<String, dynamic>.from(raw));
        if (t.shopId == shopId) out.add(t);
      } catch (_) {/* skip */}
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  /// Messages d'un ticket triés du plus ancien au plus récent.
  List<ShopTicketMessage> getMessages(String ticketId) {
    final out = <ShopTicketMessage>[];
    for (final raw in HiveBoxes.ticketMessagesBox.values) {
      try {
        final m = ShopTicketMessage.fromMap(Map<String, dynamic>.from(raw));
        if (m.ticketId == ticketId) out.add(m);
      } catch (_) {/* skip */}
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  // ── Écriture ────────────────────────────────────────────────────────────

  /// Crée un ticket sur la shop. Le caller fournit `subject`/`category`
  /// /`priority`. `opened_by` est dérivé de `auth.uid()`.
  Future<ShopTicket?> createTicket({
    required String shopId,
    required String subject,
    String? category,
    TicketPriority priority = TicketPriority.normal,
  }) async {
    final user = _db.auth.currentUser;
    if (user == null) return null;
    final id = 'ticket_${DateTime.now().millisecondsSinceEpoch}_'
        '${user.id.substring(0, 6)}';
    final now = DateTime.now().toUtc();
    final row = <String, dynamic>{
      'id':            id,
      'shop_id':       shopId,
      'opened_by':     user.id,
      'current_level': TicketLevel.admin.key,
      'category':      category,
      'subject':       subject.trim(),
      'status':        TicketStatus.open.key,
      'priority':      priority.key,
      'created_at':    now.toIso8601String(),
      'updated_at':    now.toIso8601String(),
      'resolved_at':   null,
    };
    try {
      await _db.from('shop_tickets').insert(row);
      await HiveBoxes.shopTicketsBox.put(id, row);
      return ShopTicket.fromMap(row);
    } catch (e) {
      debugPrint('[Tickets] createTicket error: $e');
      return null;
    }
  }

  /// Marque un ticket comme résolu. Côté SQL le trigger met `updated_at`.
  Future<bool> resolveTicket(String ticketId) async {
    try {
      final now = DateTime.now().toUtc();
      await _db.from('shop_tickets').update({
        'status':      TicketStatus.resolved.key,
        'resolved_at': now.toIso8601String(),
      }).eq('id', ticketId);
      // Mise à jour locale optimiste.
      final raw = HiveBoxes.shopTicketsBox.get(ticketId);
      if (raw is Map) {
        final m = Map<String, dynamic>.from(raw)
          ..['status']      = TicketStatus.resolved.key
          ..['resolved_at'] = now.toIso8601String()
          ..['updated_at']  = now.toIso8601String();
        await HiveBoxes.shopTicketsBox.put(ticketId, m);
      }
      return true;
    } catch (e) {
      debugPrint('[Tickets] resolveTicket error: $e');
      return false;
    }
  }

  /// Escalade un ticket au niveau supérieur via la RPC SQL `escalate_ticket`.
  /// Retourne le nouveau `current_level` ou `null` si échec.
  /// La RPC valide les permissions : admin/owner pour admin→owner ; owner
  /// pour owner→super_admin.
  Future<String?> escalateTicket({
    required String ticketId,
    String? reason,
  }) async {
    try {
      final res = await _db.rpc('escalate_ticket', params: {
        'p_ticket_id': ticketId,
        'p_reason':    reason,
      });
      // La RPC renvoie le nouveau level (text).
      final newLevel = res?.toString();
      if (newLevel != null && newLevel.isNotEmpty) {
        // Mise à jour locale optimiste.
        final raw = HiveBoxes.shopTicketsBox.get(ticketId);
        if (raw is Map) {
          final m = Map<String, dynamic>.from(raw)
            ..['current_level'] = newLevel
            ..['updated_at']    = DateTime.now().toUtc().toIso8601String();
          await HiveBoxes.shopTicketsBox.put(ticketId, m);
        }
      }
      return newLevel;
    } catch (e) {
      debugPrint('[Tickets] escalateTicket error: $e');
      return null;
    }
  }

  /// Ajoute un message au ticket.
  Future<ShopTicketMessage?> postMessage({
    required String ticketId,
    required String body,
  }) async {
    final user = _db.auth.currentUser;
    if (user == null) return null;
    final id = 'tmsg_${DateTime.now().millisecondsSinceEpoch}_'
        '${user.id.substring(0, 6)}';
    final now = DateTime.now().toUtc();
    final row = <String, dynamic>{
      'id':         id,
      'ticket_id':  ticketId,
      'author_id':  user.id,
      'body':       body.trim(),
      'created_at': now.toIso8601String(),
    };
    try {
      await _db.from('shop_ticket_messages').insert(row);
      await HiveBoxes.ticketMessagesBox.put(id, row);
      return ShopTicketMessage.fromMap(row);
    } catch (e) {
      debugPrint('[Tickets] postMessage error: $e');
      return null;
    }
  }
}
