import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../storage/hive_boxes.dart';
import '../storage/local_storage_service.dart';
import '../storage/secure_storage.dart';
import 'account_access_policy.dart';

/// Vérifie que la session courante correspond à un compte qui existe
/// vraiment côté serveur ET qui a au moins un accès métier. Détecte :
///
///   1. JWT encore valide (5 min de TTL) mais auth.users a été supprimé
///      (ex: licenciement employé via delete_employee).
///   2. Profile supprimé côté serveur sans nettoyage côté client.
///   3. **Accès révoqué** : profile existe encore (delete_employee n'a pas
///      purgé l'auth) MAIS aucune `shop_memberships` ni `shops.owner_id`
///      côté serveur, ALORS QUE l'appareil garde la trace d'un accès.
///      Cas typique : owner supprime un employé, l'employé tente de se
///      reconnecter avec ses anciens identifiants et tombe sur une UI
///      vide. On le déconnecte automatiquement avec un message clair.
///
///      ⚠ LE SOUVENIR LOCAL EST DÉCISIF, et c'est ce qui distingue une
///      révocation d'un compte NEUF. Un compte créé dont la création de
///      boutique a échoué présente exactement le même vide côté serveur ;
///      l'expulser l'enfermerait dehors, puisqu'il ne peut plus se
///      réinscrire sous le même e-mail. Cf. `account_access_policy.dart`.
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

      // Aucun accès CÔTÉ SERVEUR. Reste à savoir ce que ça veut dire, et
      // c'est l'appareil qui le dit : garde-t-il la trace d'un accès que le
      // serveur dément ?
      //
      //   * OUI  → révocation. Employé supprimé qui tente de se reconnecter,
      //            propriétaire dont la boutique a été supprimée.
      //   * NON  → compte NEUF. Typiquement une inscription dont la création
      //            de boutique a échoué : `register_page` propose de réessayer,
      //            il suffit d'avoir fermé l'application avant. L'expulser ici
      //            l'enferme DEHORS — la réinscription échouera sur « Un compte
      //            avec cet email existe déjà », et aucun écran ne rattache
      //            plus ce compte auth à une boutique.
      //
      // `app_router` lisait déjà correctement cet état pour autoriser la
      // création de boutique. Les deux règles sont désormais au même endroit
      // (`account_access_policy.dart`) et un test vérifie qu'elles ne se
      // contredisent plus.
      final remembers = _deviceRemembersAccess(user.id);
      if (!isRevokedAccount(
          serverGrantsAccess: false, deviceRemembersAccess: remembers)) {
        debugPrint('[SessionValidator] compte sans accès mais sans passé local '
            '→ nouvel inscrit, session CONSERVÉE');
        return true;
      }
      debugPrint('[SessionValidator] ⊘ accès révoqué (l\'appareil en gardait '
          'la trace) → logout forcé');
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

  /// L'appareil garde-t-il la trace d'un accès pour [userId] ?
  ///
  /// Mêmes lectures Hive que le garde de `RouteNames.createShop`, et c'est
  /// voulu : les deux endroits doivent voir le même état, sans quoi l'un
  /// expulse celui que l'autre autorise.
  static bool _deviceRemembersAccess(String userId) {
    bool anyMatch(Iterable<dynamic> rows, String field) => rows.any((raw) {
          try {
            return Map<String, dynamic>.from(raw as Map)[field] == userId;
          } catch (_) {
            return false;
          }
        });
    try {
      return anyMatch(HiveBoxes.shopsBox.values, 'owner_id') ||
          anyMatch(HiveBoxes.membershipsBox.values, 'user_id');
    } catch (e) {
      // Hive illisible : on ne peut RIEN affirmer. On s'abstient de purger —
      // se tromper vers la conservation coûte une session de trop ; se tromper
      // vers la purge efface des écritures non envoyées.
      debugPrint('[SessionValidator] mémoire locale illisible ($e) '
          '→ pas de purge');
      return false;
    }
  }

  static Future<void> _forceLogoutAndPurge() async {
    try { await Supabase.instance.client.auth.signOut(); } catch (_) {}
    await LocalStorageService.clearAllLocalData();
    await SecureStorageService.clearAll();
  }
}
