import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/admin_actions_service.dart';

/// Représente une demande d'action en attente, lue depuis la table
/// `pending_admin_actions`. Le owner consomme cette liste pour afficher
/// le banner d'approbation.
class PendingAction {
  final String          id;
  final String          shopId;
  final String          requesterId;
  final String?         targetUserId;
  final AdminActionType type;
  final DateTime        createdAt;
  final DateTime        expiresAt;

  const PendingAction({
    required this.id,
    required this.shopId,
    required this.requesterId,
    required this.targetUserId,
    required this.type,
    required this.createdAt,
    required this.expiresAt,
  });

  factory PendingAction.fromMap(Map<String, dynamic> m) => PendingAction(
        id:           m['id'] as String,
        shopId:       (m['shop_id'] ?? '').toString(),
        requesterId:  (m['requester_id'] ?? '').toString(),
        targetUserId: m['target_user_id'] as String?,
        type:         AdminActionTypeX.fromKey(m['action_type'] as String?)
                      ?? AdminActionType.removeAdmin,
        createdAt:    DateTime.parse(m['created_at'] as String),
        expiresAt:    DateTime.parse(m['expires_at'] as String),
      );

  Duration get remaining =>
      expiresAt.difference(DateTime.now());

  bool get isExpired => remaining.isNegative;
}

/// Stream provider qui expose les actions en attente pour la boutique
/// donnée. S'abonne au Realtime Postgres + refresh toutes les 30s pour
/// catcher les expirations sans event Realtime.
final pendingActionsProvider =
    StreamProvider.family<List<PendingAction>, String>((ref, shopId) {
  final controller = StreamController<List<PendingAction>>();
  final client = Supabase.instance.client;

  Future<void> fetch() async {
    try {
      final rows = await client
          .from('pending_admin_actions')
          .select()
          .eq('shop_id', shopId)
          .eq('status', 'pending')
          .gt('expires_at', DateTime.now().toIso8601String());
      final list = (rows as List)
          .map((r) => PendingAction.fromMap(Map<String, dynamic>.from(r)))
          .where((a) => !a.isExpired)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (!controller.isClosed) controller.add(list);
    } catch (e) {
      debugPrint('[PendingActions] fetch failed: $e');
      if (!controller.isClosed) controller.add(const []);
    }
  }

  // Premier fetch
  fetch();

  // Realtime : reçoit les INSERT/UPDATE sur la table filtrée par shop
  final channel = client
      .channel('pending_actions_$shopId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'pending_admin_actions',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'shop_id',
          value: shopId,
        ),
        callback: (_) => fetch(),
      )
      .subscribe();

  // Refresh périodique pour catcher les expirations (Realtime ne déclenche
  // pas d'event sur changement de status='expired' s'il est fait par cron).
  final timer = Timer.periodic(const Duration(seconds: 30), (_) => fetch());

  ref.onDispose(() {
    timer.cancel();
    client.removeChannel(channel);
    controller.close();
  });

  return controller.stream;
});
