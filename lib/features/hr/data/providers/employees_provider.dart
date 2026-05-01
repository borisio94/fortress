import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/storage/hive_boxes.dart';
import '../../domain/models/employee.dart';
import '../../domain/models/employee_permission.dart';
import '../../domain/models/member_role.dart';

// ─── Provider Riverpod : liste des employés d'une boutique ──────────────────
//
// Architecture offline-first :
//   - `build(shopId)` retourne immédiatement le cache Hive (si présent),
//     puis lance un fetch Supabase en arrière-plan qui met à jour l'état.
//   - Mutations (create / update / status / delete) → online uniquement.
//     Si offline, on lève une exception pour que la UI affiche un snackbar
//     « connexion requise » (les RPCs touchent auth.users qui ne peut être
//     muté offline).
// ───────────────────────────────────────────────────────────────────────────

class EmployeesNotifier
    extends FamilyAsyncNotifier<List<Employee>, String> {
  String _cacheKey(String shopId) => 'employees_$shopId';

  /// Lecture cache Hive — décodage des maps stockées.
  List<Employee> _readCache(String shopId) {
    try {
      final raw = HiveBoxes.settingsBox.get(_cacheKey(shopId));
      if (raw is! List) return [];
      return raw
          .whereType<Map>()
          .map((m) => Employee.fromCacheMap(Map<String, dynamic>.from(m)))
          .toList();
    } catch (e) {
      debugPrint('[Employees] cache read error: $e');
      return [];
    }
  }

  Future<void> _writeCache(String shopId, List<Employee> list) async {
    try {
      await HiveBoxes.settingsBox.put(_cacheKey(shopId),
          list.map((e) => e.toCacheMap()).toList());
    } catch (e) {
      debugPrint('[Employees] cache write error: $e');
    }
  }

  /// Fetch Supabase via RPC `list_shop_employees`. Le caller décide s'il
  /// faut persister le résultat dans le cache Hive (cf. `writeCache`).
  Future<List<Employee>> _fetchFromSupabase(String shopId,
      {bool writeCache = true}) async {
    final rows = await Supabase.instance.client
        .rpc('list_shop_employees', params: {'p_shop_id': shopId});
    if (rows is! List) return const [];
    final list = rows
        .whereType<Map>()
        .map((r) => Employee.fromRpc(shopId,
            Map<String, dynamic>.from(r)))
        .toList();
    if (writeCache) {
      await _writeCache(shopId, list);
    }
    return list;
  }

  @override
  Future<List<Employee>> build(String shopId) async {
    final cached = _readCache(shopId);
    if (cached.isNotEmpty) {
      // Background refresh : on ne touche au cache que si le résultat est
      // non-vide. Cas évité : juste après re-login, la propagation du JWT
      // peut faire échouer/vider transitoirement la RPC ; sans cette garde
      // on écraserait silencieusement le cache et l'utilisateur verrait
      // "0 employé" alors que ses données existent toujours en base.
      // L'effacement explicite après une mutation passe par refresh() qui
      // bypass cette garde.
      Future<void>.microtask(() async {
        try {
          final fresh = await _fetchFromSupabase(shopId, writeCache: false);
          if (fresh.isEmpty) return;
          if (!_listEquals(fresh, cached)) {
            await _writeCache(shopId, fresh);
            state = AsyncValue.data(fresh);
          }
        } catch (e) {
          debugPrint('[Employees] background fetch failed: $e');
        }
      });
      return cached;
    }
    // Pas de cache → on tente Supabase, sinon liste vide.
    try {
      return await _fetchFromSupabase(shopId);
    } catch (e) {
      debugPrint('[Employees] initial fetch failed: $e');
      return const [];
    }
  }

  /// Force un refresh (pull-to-refresh ou après mutation).
  Future<void> refresh() async {
    final shopId = arg;
    state = const AsyncValue.loading();
    try {
      state = AsyncValue.data(await _fetchFromSupabase(shopId));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  // ── Mutations (online seulement) ────────────────────────────────────────

  /// Crée un nouvel employé : compte Auth + profile + membership en
  /// transaction côté SQL. Throw si email déjà utilisé, password trop
  /// court, ou si l'appelant n'est pas admin/owner. Le rôle [role]
  /// (admin/user) est enregistré dès l'INSERT — si admin, le trigger
  /// SQL trg_enforce_max_admins peut throw 23514 si la limite des 3
  /// administrateurs (owner inclus) est déjà atteinte.
  Future<String> create({
    required String                  email,
    required String                  password,
    required String                  fullName,
    required Set<EmployeePermission> permissions,
    Set<EmployeePermission>          denies = const {},
    EmployeeStatus                   status = EmployeeStatus.active,
    MemberRole                       role   = MemberRole.user,
  }) async {
    final shopId = arg;
    final payload = MemberPermissions(
      grants: permissions, denies: denies,
    ).toList();
    final result = await Supabase.instance.client.rpc(
      'create_employee',
      params: {
        'p_shop_id':     shopId,
        'p_email':       email,
        'p_password':    password,
        'p_full_name':   fullName,
        'p_permissions': payload,
        'p_status':      status.key,
        'p_role':        role.key,
      },
    );
    await refresh();
    return (result is String) ? result : '';
  }

  /// Met à jour les permissions granulaires d'un employé.
  ///
  /// Les `deny:` existants sont **préservés** sauf si [denies] est fourni
  /// explicitement. Ça empêche d'effacer une permission retirée à la main
  /// (via SQL ou UI avancée) lorsqu'un admin enregistre simplement les
  /// nouvelles cases cochées du form de base.
  Future<void> updatePermissions(String userId,
      Set<EmployeePermission> permissions, {
        Set<EmployeePermission>? denies,
      }) async {
    final shopId = arg;
    // Récupérer les denies actuels si l'appelant ne les fournit pas
    Set<EmployeePermission> finalDenies;
    if (denies != null) {
      finalDenies = denies;
    } else {
      final list = state.valueOrNull;
      final existing = list?.where((e) => e.userId == userId).firstOrNull;
      finalDenies = existing?.denies ?? const {};
    }
    final payload = MemberPermissions(
      grants: permissions, denies: finalDenies,
    ).toList();
    await Supabase.instance.client.rpc(
      'update_employee_permissions',
      params: {
        'p_shop_id':     shopId,
        'p_user_id':     userId,
        'p_permissions': payload,
      },
    );
    await refresh();
  }

  /// Met à jour nom et/ou rôle (admin/user) sans toucher aux permissions.
  /// Le rôle d'un owner ne peut JAMAIS être modifié — bloqué côté Dart
  /// (UX immédiate) ET côté SQL (trigger trg_enforce_is_owner).
  Future<void> updateProfile(String userId, {
    required String       fullName,
    required MemberRole role,
  }) async {
    _guardNotOwner(userId,
        action: 'modifier le profil du propriétaire');
    final shopId = arg;
    await Supabase.instance.client.rpc(
      'update_employee_profile',
      params: {
        'p_shop_id':   shopId,
        'p_user_id':   userId,
        'p_full_name': fullName,
        'p_role':      role.key,
      },
    );
    await refresh();
  }

  /// Bascule active / suspended / archived. Le owner ne peut pas être
  /// changé (refusé côté Dart + SQL).
  Future<void> setStatus(String userId, EmployeeStatus status) async {
    _guardNotOwner(userId,
        action: 'changer le statut du propriétaire');
    final shopId = arg;
    await Supabase.instance.client.rpc(
      'set_employee_status',
      params: {
        'p_shop_id': shopId,
        'p_user_id': userId,
        'p_status':  status.key,
      },
    );
    await refresh();
  }

  /// Supprime définitivement le membership (le compte auth.users reste).
  /// Refusé côté Dart + côté SQL (trigger trg_protect_owner_delete) si
  /// userId est le owner du shop.
  Future<void> delete(String userId) async {
    _guardNotOwner(userId,
        action: 'supprimer le propriétaire');
    final shopId = arg;
    await Supabase.instance.client.rpc(
      'delete_employee',
      params: {
        'p_shop_id': shopId,
        'p_user_id': userId,
      },
    );
    await refresh();
  }

  /// Empêche toute mutation sur l'employé identifié par [userId] s'il est
  /// le propriétaire de la boutique (is_owner=true). Throw avec un message
  /// explicite si la garde est violée.
  void _guardNotOwner(String userId, {required String action}) {
    final list = state.valueOrNull;
    if (list == null) return;
    final target = list.where((e) => e.userId == userId).firstOrNull;
    if (target != null && target.isOwner) {
      throw StateError(
          'Action interdite : impossible de $action. '
          'Le propriétaire de la boutique est protégé.');
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  static bool _listEquals(List<Employee> a, List<Employee> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].userId      != b[i].userId      ||
          a[i].fullName    != b[i].fullName    ||
          a[i].status      != b[i].status      ||
          a[i].role        != b[i].role        ||
          a[i].permissions.length != b[i].permissions.length ||
          !a[i].permissions.every(b[i].permissions.contains)) {
        return false;
      }
    }
    return true;
  }
}

final employeesProvider = AsyncNotifierProvider.family<
    EmployeesNotifier, List<Employee>, String>(
  EmployeesNotifier.new,
);

// ─── Provider : permissions de l'utilisateur courant pour un shop ──────────
//
// Lit la row `shop_memberships` correspondant à `(auth.uid(), shopId)` et
// renvoie le Set<EmployeePermission> du JSONB. Cache Hive offline-first.
//
// Stratégie :
//   1. Au premier appel, lit le cache Hive (clé `my_perms_<shopId>`).
//   2. Tente un fetch Supabase (RLS autorise `user_id = auth.uid()`).
//   3. Si fetch OK → met à jour le cache + l'état du provider.
//   4. Si offline → garde le cache (peut être obsolète, accepté).
//
// Retourne :
//   - `null` si pas de membership (legacy fallback dans AppPermissions).
//   - `Set<EmployeePermission>` (peut être vide) si row trouvée.
//
// La valeur est un AsyncValue dans le provider mais lue via `valueOrNull`
// par `permissionsProvider` (synchrone) avec fallback `null` (legacy).

final currentUserShopPermissionsProvider = FutureProvider.family<
    MemberPermissions?, String>((ref, shopId) async {
  final cacheKey = 'my_perms_$shopId';
  MemberPermissions? cached;
  try {
    final raw = HiveBoxes.settingsBox.get(cacheKey);
    if (raw is List) {
      cached = MemberPermissions.fromList(raw);
    }
  } catch (_) {}

  Future<MemberPermissions?> doFetch() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      final row = await Supabase.instance.client
          .from('shop_memberships')
          .select('permissions')
          .eq('user_id', uid)
          .eq('shop_id', shopId)
          .maybeSingle();
      if (row == null) return null;
      final raw = row['permissions'];
      if (raw is! List) return MemberPermissions.empty;
      final out = MemberPermissions.fromList(raw);
      // Caching : on stocke la forme JSONB brute (avec `deny:`) pour
      // pouvoir reparser à l'identique au prochain démarrage offline.
      try {
        await HiveBoxes.settingsBox.put(cacheKey, out.toList());
      } catch (_) {}
      return out;
    } catch (e) {
      debugPrint('[Perms] fetch failed: $e');
      return cached; // fallback cache
    }
  }

  // Si on a du cache → renvoyer rapidement, refresh en arrière-plan
  if (cached != null) {
    Future<void>.microtask(() async {
      final fresh = await doFetch();
      if (fresh != null && !_membersEqual(fresh, cached!)) {
        ref.invalidateSelf();
      }
    });
    return cached;
  }
  return doFetch();
});

bool _membersEqual(MemberPermissions a, MemberPermissions b) {
  return _setEquals(a.grants, b.grants) && _setEquals(a.denies, b.denies);
}

bool _setEquals(Set<EmployeePermission> a, Set<EmployeePermission> b) {
  if (a.length != b.length) return false;
  return a.every(b.contains);
}
