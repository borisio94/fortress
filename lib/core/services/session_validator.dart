import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../storage/local_storage_service.dart';
import '../storage/secure_storage.dart';

/// Vérifie que la session courante correspond à un compte qui existe
/// vraiment côté serveur ET qui a au moins un accès métier. Détecte :
///
///   1. JWT encore valide (5 min de TTL) mais auth.users a été supprimé
///      (ex: licenciement employé via delete_employee).
///   2. Profile supprimé côté serveur sans nettoyage côté client.
///   3. **Compte zombie** : profile existe encore (delete_employee n'a pas
///      purgé l'auth) MAIS aucune `shop_memberships` ni `shops.owner_id`
///      pour cet utilisateur → il n'a aucun accès métier dans Fortress.
///      Cas typique : owner supprime un employé, l'employé tente de se
///      reconnecter avec ses anciens identifiants et tombe sur une UI
///      vide. On le déconnecte automatiquement avec un message clair.
///
/// Si la session est invalide :
///   - signOut Supabase
///   - clearAllLocalData (Hive shops, products, memberships, settings, cart)
///   - clearTokens secure storage
///
/// → l'utilisateur retombe sur l'écran de login et n'a plus accès au
/// cache local de l'ancien compte.
class SessionValidator {
  /// Doit être appelé après chaque login réussi ET au démarrage de l'app
  /// si une session est déjà active.
  ///
  /// Retourne `true` si la session est valide, `false` si elle a été
  /// invalidée (et donc l'utilisateur déconnecté + cache purgé).
  static Future<bool> validate() async {
    final supa = Supabase.instance.client;
    final user = supa.auth.currentUser;
    if (user == null) return true; // pas de session → rien à valider

    try {
      // ── 1. Profile existe-t-il ? + super-admin ?
      final profile = await supa
          .from('profiles')
          .select('id, is_super_admin')
          .eq('id', user.id)
          .maybeSingle();

      if (profile == null) {
        debugPrint('[SessionValidator] ⊘ profil supprimé côté serveur '
            '→ logout forcé + purge Hive');
        await _forceLogoutAndPurge();
        return false;
      }

      // Super-admin : accès toutes boutiques par défaut → pas besoin de
      // vérifier shop_memberships / shops.owner_id.
      final isSuperAdmin = profile['is_super_admin'] as bool? ?? false;
      if (isSuperAdmin) return true;

      // ── 2. Au moins un accès métier ? (membership OU ownership)
      //   RLS profiles_select garantit qu'on ne voit que les profils des
      //   membres de nos boutiques + le sien — donc on doit aussi compter
      //   les boutiques où on est explicitement owner pour le cas du
      //   "self-signup just-created" qui n'a pas encore de membership.
      final memberships = await supa
          .from('shop_memberships')
          .select('shop_id')
          .eq('user_id', user.id)
          .limit(1);
      if (memberships.isNotEmpty) return true;

      final ownedShops = await supa
          .from('shops')
          .select('id')
          .eq('owner_id', user.id)
          .limit(1);
      if (ownedShops.isNotEmpty) return true;

      // Aucun accès → compte zombie (employé supprimé qui tente de se
      // reconnecter, ou propriétaire dont la boutique a été supprimée).
      debugPrint('[SessionValidator] ⊘ aucun membership / ownership '
          'côté serveur → logout forcé (compte zombie)');
      await _forceLogoutAndPurge();
      return false;
    } on AuthException {
      // 401 / token invalide → user supprimé
      debugPrint('[SessionValidator] ⊘ token rejeté serveur → logout forcé');
      await _forceLogoutAndPurge();
      return false;
    } catch (e) {
      // Erreur réseau (offline) → on accepte la session, on revérifiera
      // au prochain démarrage en ligne.
      debugPrint('[SessionValidator] check offline / erreur réseau : $e');
      return true;
    }
  }

  static Future<void> _forceLogoutAndPurge() async {
    try { await Supabase.instance.client.auth.signOut(); } catch (_) {}
    await LocalStorageService.clearAllLocalData();
    await SecureStorageService.clearAll();
  }
}
