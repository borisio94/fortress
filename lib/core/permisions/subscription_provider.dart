import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/app_database.dart';
import '../storage/local_storage_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/hr/data/providers/employees_provider.dart';
import 'user_plan.dart';
import 'app_permissions.dart';

// ─── Provider état abonnement ─────────────────────────────────────────────────

class SubscriptionNotifier extends StateNotifier<AsyncValue<UserPlan>> {
  SubscriptionNotifier() : super(const AsyncValue.loading());

  // Flag consommé par le router pour rediriger /subscription → /shop-selector
  // après une souscription réussie. Positionné uniquement sur transition
  // inactif → actif dans refresh() (pas dans load(), pour ne pas rediriger
  // au premier login d'un utilisateur déjà abonné).
  bool _justActivated = false;
  bool get justActivated => _justActivated;
  void consumeJustActivated() => _justActivated = false;

  // Charger le plan — Supabase en priorité, Hive en fallback offline
  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) {
        state = AsyncValue.data(UserPlan.empty());
        return;
      }

      // Essayer Supabase d'abord
      try {
        // 1. Vérifier is_super_admin
        final profile = await Supabase.instance.client
            .from('profiles')
            .select('is_super_admin, prof_status, blocked_at')
            .eq('id', uid)
            .maybeSingle();

        final isSuperAdmin =
            profile?['is_super_admin'] as bool? ?? false;
        if (isSuperAdmin) {
          state = AsyncValue.data(UserPlan.superAdmin());
          return;
        }

        // 2. Appeler get_user_plan()
        final result = await Supabase.instance.client
            .rpc('get_user_plan', params: {'p_user_id': uid});

        if (result == null || (result as List).isEmpty) {
          state = AsyncValue.data(UserPlan.empty());
          return;
        }

        final map = Map<String, dynamic>.from(result[0] as Map);
        state = AsyncValue.data(UserPlan.fromMap(map));
        return;
      } catch (_) {
        // Pas de réseau — fallback sur cache Hive
      }

      // Fallback offline : lire depuis Hive
      final cachedProfile =
      AppDatabase.getCachedProfile(uid);
      final isSuperAdminCached =
          cachedProfile?['is_super_admin'] as bool? ?? false;
      if (isSuperAdminCached) {
        state = AsyncValue.data(UserPlan.superAdmin());
        return;
      }

      final cachedPlan = AppDatabase.getCachedPlan(uid);
      if (cachedPlan != null) {
        state = AsyncValue.data(UserPlan.fromMap(cachedPlan));
      } else {
        state = AsyncValue.data(UserPlan.empty());
      }
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  // Réinitialiser (logout)
  void reset() {
    _justActivated = false;
    state = AsyncValue.data(UserPlan.empty());
  }

  // Mettre à jour après souscription — détecte la transition inactif → actif
  Future<void> refresh() async {
    final wasActive = state.valueOrNull?.isActive ?? false;
    await load();
    final nowActive = state.valueOrNull?.isActive ?? false;
    if (!wasActive && nowActive) _justActivated = true;
  }
}

final subscriptionProvider =
StateNotifierProvider<SubscriptionNotifier, AsyncValue<UserPlan>>(
      (ref) => SubscriptionNotifier(),
);

/// Provider dérivé qui expose le `UserPlan` courant **non-async** (état
/// `loading` ou `error` → `UserPlan.empty()`). Sert aux call sites qui
/// veulent juste tester `canAddShop(count)`, `hasFeature(f)`, etc. sans
/// avoir à manipuler `AsyncValue` à chaque fois.
///
/// Usage :
///   final plan = ref.watch(currentPlanProvider);
///   if (plan.canAddShop(myShops.length)) { ... }
final currentPlanProvider = Provider<UserPlan>((ref) {
  return ref.watch(subscriptionProvider).valueOrNull ?? UserPlan.empty();
});

// ─── Provider permissions pour une boutique donnée ───────────────────────────

final permissionsProvider = Provider.family<AppPermissions, String>(
      (ref, shopId) {
    final planAsync = ref.watch(subscriptionProvider);
    final plan = planAsync.valueOrNull ?? UserPlan.empty();

    // Lire le rôle depuis shop_memberships local (Hive)
    // Il sera renseigné lors du syncLogin
    final shopRole = ref.watch(_shopRoleProvider(shopId));

    // Permissions custom (grants + denies) depuis le JSONB shop_memberships.
    // Si null (premier load, offline, pas de membership) → AppPermissions
    // tombe sur le fallback legacy basé sur shopRole. Le format JSONB
    // accepte les `deny:perm` qui RETIRENT une permission par défaut du rôle.
    final custom = ref.watch(currentUserShopPermissionsProvider(shopId))
        .valueOrNull;

    // Détecter si l'utilisateur courant est propriétaire de la boutique.
    // Le propriétaire a TOUS les droits par définition (bypass des
    // permissions granulaires), même si sa ligne shop_memberships est
    // vide ou absente.
    final uid = Supabase.instance.client.auth.currentUser?.id;
    bool isShopOwner = false;
    if (uid != null) {
      final shop = LocalStorageService.getShop(shopId);
      if (shop != null && shop.ownerId == uid) {
        isShopOwner = true;
      }
    }

    return AppPermissions(
      plan:               plan,
      shopRole:           shopRole,
      customPermissions:  custom,
      isShopOwner:        isShopOwner,
    );
  },
);

// Provider interne : rôle dans une boutique (lu depuis Hive)
final _shopRoleProvider = Provider.family<String?, String>((ref, shopId) {
  // Sera enrichi par le ShopMembershipRepository au login
  return ref.watch(shopRolesMapProvider)[shopId];
});

/// Map shopId → role, mise à jour au login (public pour le router)
final shopRolesMapProvider =
StateProvider<Map<String, String>>((ref) => {});

// Extension pour mettre à jour les rôles après sync
extension SubscriptionProviderX on WidgetRef {
  void updateShopRoles(Map<String, String> roles) =>
      read(shopRolesMapProvider.notifier).state = roles;
}