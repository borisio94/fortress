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

  /// Archive un set de logs via le RPC `archive_activity_logs` (cf.
  /// hotfix_060). Le RPC :
  ///  - Vérifie que l'appelant est super-admin OR propriétaire des shops
  ///    de tous les logs visés.
  ///  - Marque `is_archived=true` + métadonnées (archived_by/at/reason).
  ///  - Logue un événement d'audit `activity_logs_archived` (succès) ou
  ///    `activity_logs_archive_attempt_unauthorized` (refusé).
  ///
  /// Retourne le nombre de logs effectivement archivés. Throw si non
  /// autorisé (l'audit du refus est posé côté serveur avant l'erreur).
  static Future<int> archiveLogs(List<String> ids, {String? reason}) async {
    if (ids.isEmpty) return 0;
    final res = await Supabase.instance.client.rpc(
      'archive_activity_logs',
      params: {'p_log_ids': ids, 'p_reason': reason},
    );
    if (res is Map) return (res['archived'] as num?)?.toInt() ?? 0;
    return 0;
  }

  /// Supprime DÉFINITIVEMENT un set de logs via le RPC
  /// `delete_activity_logs` (cf. hotfix_060). Mêmes règles d'autorisation
  /// + audit que `archiveLogs`. À utiliser avec extrême prudence —
  /// l'archivage est généralement préférable.
  static Future<int> deleteLogs(List<String> ids, {String? reason}) async {
    if (ids.isEmpty) return 0;
    final res = await Supabase.instance.client.rpc(
      'delete_activity_logs',
      params: {'p_log_ids': ids, 'p_reason': reason},
    );
    if (res is Map) return (res['deleted'] as num?)?.toInt() ?? 0;
    return 0;
  }
}
