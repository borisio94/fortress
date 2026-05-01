import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../storage/local_storage_service.dart';
import '../storage/secure_storage.dart';

/// Vérifie que la session courante correspond à un compte qui existe
/// vraiment côté serveur. Détecte les cas suivants :
///
///   1. JWT encore valide (5 min de TTL) mais auth.users a été supprimé
///      (ex: licenciement employé via delete_employee).
///   2. Profile supprimé côté serveur sans nettoyage côté client.
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
      final profile = await supa
          .from('profiles')
          .select('id')
          .eq('id', user.id)
          .maybeSingle();

      if (profile == null) {
        debugPrint('[SessionValidator] ⊘ profil supprimé côté serveur '
            '→ logout forcé + purge Hive');
        await _forceLogoutAndPurge();
        return false;
      }
      return true;
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
