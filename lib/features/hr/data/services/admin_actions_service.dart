import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Type d'action sensible nécessitant l'approbation du propriétaire.
/// Aligné sur la CHECK constraint SQL `pending_admin_actions.action_type`.
enum AdminActionType {
  removeAdmin,
  demoteAdmin,
  deleteShop,
}

extension AdminActionTypeX on AdminActionType {
  String get key => switch (this) {
        AdminActionType.removeAdmin => 'remove_admin',
        AdminActionType.demoteAdmin => 'demote_admin',
        AdminActionType.deleteShop  => 'delete_shop',
      };
  String get labelFr => switch (this) {
        AdminActionType.removeAdmin =>
            'Retirer un administrateur',
        AdminActionType.demoteAdmin =>
            'Rétrograder un administrateur',
        AdminActionType.deleteShop =>
            'Supprimer la boutique',
      };

  static AdminActionType? fromKey(String? k) => switch (k) {
        'remove_admin' => AdminActionType.removeAdmin,
        'demote_admin' => AdminActionType.demoteAdmin,
        'delete_shop'  => AdminActionType.deleteShop,
        _              => null,
      };
}

/// Erreur métier renvoyée par les RPCs `pending_admin_actions`.
/// Permet à l'UI d'afficher un message FR adapté plutôt que l'erreur brute
/// PostgreSQL.
enum AdminActionError {
  ownerOffline,
  duplicatePending,
  notAdmin,
  notOwner,
  expired,
  alreadyProcessed,
  notFound,
  wrongPassword,
  unknown,
}

class AdminActionException implements Exception {
  final AdminActionError code;
  final String? raw;
  AdminActionException(this.code, {this.raw});

  String get messageFr => switch (code) {
        AdminActionError.ownerOffline =>
          'Le propriétaire est hors ligne. Réessayez quand il sera connecté.',
        AdminActionError.duplicatePending =>
          'Une demande similaire est déjà en attente.',
        AdminActionError.notAdmin =>
          'Seul un administrateur peut effectuer cette demande.',
        AdminActionError.notOwner =>
          'Seul le propriétaire peut approuver cette action.',
        AdminActionError.expired =>
          'La demande a expiré (5 minutes).',
        AdminActionError.alreadyProcessed =>
          'La demande a déjà été traitée.',
        AdminActionError.notFound =>
          'Demande introuvable.',
        AdminActionError.wrongPassword =>
          'Mot de passe incorrect.',
        AdminActionError.unknown =>
          raw ?? 'Erreur inconnue.',
      };
}

/// Service qui encapsule les appels aux RPCs `pending_admin_actions`.
class AdminActionsService {
  static final _client = Supabase.instance.client;

  /// Vérifie si le propriétaire d'une boutique est online (< 90s).
  static Future<bool> isOwnerOnline(String shopId) async {
    try {
      final r = await _client.rpc('is_owner_online',
          params: {'p_shop_id': shopId});
      return r == true;
    } catch (e) {
      debugPrint('[AdminActions] is_owner_online failed: $e');
      return false; // si la RPC échoue, on considère offline (safe default)
    }
  }

  /// Crée une demande d'approbation. Throw [AdminActionException] sur erreur
  /// métier (owner offline, doublon, etc.).
  static Future<String> request({
    required String          shopId,
    required AdminActionType type,
    String?                  targetUserId,
  }) async {
    try {
      final id = await _client.rpc('request_admin_action', params: {
        'p_shop_id':        shopId,
        'p_target_user_id': targetUserId,
        'p_action_type':    type.key,
      });
      return id as String;
    } on PostgrestException catch (e) {
      throw AdminActionException(_mapError(e.message), raw: e.message);
    }
  }

  /// Re-vérifie le mot de passe du owner via signInWithPassword puis
  /// appelle approve_admin_action.
  ///
  /// Renvoie `null` si le mot de passe est incorrect (pas d'exception
  /// pour rester silencieux côté UI ; l'appelant affiche le message).
  static Future<Map<String, dynamic>?> approve({
    required String actionId,
    required String email,
    required String password,
  }) async {
    // 1. Re-vérification mot de passe via signInWithPassword.
    //    Note : ça réémet une nouvelle session pour le même user, c'est OK.
    try {
      final res = await _client.auth.signInWithPassword(
          email: email, password: password);
      if (res.user == null) {
        throw AdminActionException(AdminActionError.wrongPassword);
      }
    } on AuthException catch (_) {
      throw AdminActionException(AdminActionError.wrongPassword);
    }

    // 2. Appel RPC approve_admin_action (trust auth.uid())
    try {
      final result = await _client.rpc('approve_admin_action',
          params: {'p_action_id': actionId});
      return result is Map<String, dynamic>
          ? result
          : Map<String, dynamic>.from(result as Map);
    } on PostgrestException catch (e) {
      throw AdminActionException(_mapError(e.message), raw: e.message);
    }
  }

  /// Owner refuse une demande. Pas de mot de passe requis (le rejet est
  /// non-destructif).
  static Future<void> reject({
    required String  actionId,
    String?          reason,
  }) async {
    try {
      await _client.rpc('reject_admin_action', params: {
        'p_action_id': actionId,
        'p_reason':    reason,
      });
    } on PostgrestException catch (e) {
      throw AdminActionException(_mapError(e.message), raw: e.message);
    }
  }

  static AdminActionError _mapError(String? msg) {
    final m = msg ?? '';
    if (m.contains('OWNER_OFFLINE')) return AdminActionError.ownerOffline;
    if (m.contains('DUPLICATE_PENDING')) return AdminActionError.duplicatePending;
    if (m.contains('NOT_ADMIN')) return AdminActionError.notAdmin;
    if (m.contains('NOT_OWNER')) return AdminActionError.notOwner;
    if (m.contains('ACTION_EXPIRED')) return AdminActionError.expired;
    if (m.contains('ACTION_ALREADY_PROCESSED'))
      return AdminActionError.alreadyProcessed;
    if (m.contains('ACTION_NOT_FOUND')) return AdminActionError.notFound;
    return AdminActionError.unknown;
  }
}
