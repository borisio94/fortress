import 'package:supabase_flutter/supabase_flutter.dart';
import '../database/app_database.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Service de journalisation d'actions — insère dans activity_logs.
// Passe par AppDatabase.bgInsert → offline-queue au besoin. Un log manqué en
// mode hors-ligne est rejoué automatiquement au retour online.
// Actions métier : user_login, shop_created, sale_completed,
// product_created|updated|deleted, user_blocked|unblocked,
// subscription_activated|cancelled, user_deleted, account_deleted,
// shop_reset, platform_reset, …
// ═══════════════════════════════════════════════════════════════════════════

class ActivityLogService {
  static Future<void> log({
    required String action,
    String?              targetType,
    String?              targetId,
    String?              targetLabel,
    String?              shopId,
    Map<String, dynamic>? details,
  }) async {
    final auth = Supabase.instance.client.auth.currentUser;
    AppDatabase.bgInsert('activity_logs', {
      'actor_id':     auth?.id,
      'actor_email':  auth?.email,
      'action':       action,
      'target_type':  targetType,
      'target_id':    targetId,
      'target_label': targetLabel,
      'shop_id':      shopId,
      'details':      details,
      'created_at':   DateTime.now().toUtc().toIso8601String(),
    });
  }
}
