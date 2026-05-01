import '../../features/hr/domain/models/employee_permission.dart';
import '../../features/hr/domain/models/member_role.dart';
import '../../features/subscription/domain/models/plan_type.dart';
import 'user_plan.dart';

// ─── Gestion centralisée des permissions ─────────────────────────────────────
// Usage :
//   final p = AppPermissions(plan: userPlan, shopRole: 'admin',
//                            grainedPermissions: {…});
//   if (p.canEditProduct) { ... }
//
// Deux modes de résolution :
//   1. `grainedPermissions != null` → source de vérité, lue depuis le JSONB
//      `shop_memberships.permissions`. Chaque booléen vérifie une
//      `EmployeePermission` précise (cf. hotfix_018).
//   2. `grainedPermissions == null` → fallback legacy : chaque booléen se
//      résout depuis `shopRole` (admin/user) comme avant la migration RH.
//
// La transition est progressive : le owner et les admins existants restent
// pleinement fonctionnels via legacy ; les employés créés par RH via le
// nouveau flow s'appuient sur leurs permissions JSONB.

class AppPermissions {
  final UserPlan                 plan;
  final String?                  shopRole;   // 'owner' | 'admin' | 'user' | null
  /// Permissions explicites accordées (grants) ET retirées (denies)
  /// stockées dans `shop_memberships.permissions` (cf. spec hotfix_024).
  /// Si `null` → mode legacy : la résolution se fait via [shopRole] seul.
  final MemberPermissions?       customPermissions;
  /// True si l'utilisateur est le propriétaire (`shops.owner_id`) de la
  /// boutique courante. Le owner a TOUS les droits par définition, peu
  /// importe ce que stocke `shop_memberships.permissions`.
  final bool                     isShopOwner;

  const AppPermissions({
    required this.plan,
    this.shopRole,
    this.customPermissions,
    this.isShopOwner = false,
  });

  /// Évaluation d'une permission combinant rôle + grants + denies :
  ///
  ///   1. Owner → `true` (bypass total, immune à tout `deny:`).
  ///   2. Permission dans `denies` → `false` (deny gagne sur le défaut rôle).
  ///   3. Permission dans `grants` → `true` (ajoute au défaut rôle).
  ///   4. Sinon → fallback `legacy` (défaut du rôle de base).
  bool _grain(EmployeePermission p, {required bool legacy}) {
    if (isShopOwner) return true;
    final cp = customPermissions;
    if (cp != null) {
      if (cp.denies.contains(p)) return false;
      if (cp.grants.contains(p)) return true;
    }
    return legacy;
  }

  // Accesseurs rôle
  bool get isSuperAdmin => plan.isSuperAdmin;
  bool get isShopAdmin  => shopRole == 'admin' || shopRole == 'owner'
                          || isSuperAdmin || isShopOwner;
  bool get isShopUser   => shopRole == 'user'  || isShopAdmin;
  bool get isMember     => shopRole != null     || isSuperAdmin || isShopOwner;

  // ─── API canonique (hotfix_024) ──────────────────────────────────────────
  // Aliases lisibles + helpers spec.

  /// True si l'utilisateur est propriétaire de la boutique (= owner).
  bool get isOwner => isShopOwner || shopRole == 'owner';

  /// True si l'utilisateur est admin ou owner (hiérarchie).
  bool get isAdmin => isShopAdmin;

  /// Rôle effectif inférré : owner > admin > user > null.
  /// Utilisé par les helpers `canManage` / `requiresOwnerApproval`.
  MemberRole? get effectiveRole {
    if (isOwner)               return MemberRole.owner;
    if (shopRole == 'admin')   return MemberRole.admin;
    if (shopRole == 'user')    return MemberRole.user;
    return null;
  }

  /// Vérifie si l'utilisateur a la permission [p]. Combine :
  ///   1. owner → toujours true (bypass total)
  ///   2. permissions JSONB granulaires si dispo
  ///   3. fallback legacy basé sur shopRole
  /// Refuse aussi si la permission est owner-only et l'utilisateur n'est pas
  /// owner (cf. [requiresOwnerApproval]).
  bool canDo(EmployeePermission p) {
    if (p.isOwnerOnly && !isOwner) return false;
    return _grain(p, legacy: isShopAdmin);
  }

  /// True si l'utilisateur peut gérer (créer/modifier/supprimer) un membre
  /// du rôle [target]. Implémente la hiérarchie :
  ///   - owner gère admin et user
  ///   - admin gère user (pas d'autre admin, pas le owner)
  ///   - user ne gère personne
  /// Super admin gère tout.
  bool canManage(MemberRole target) {
    if (isSuperAdmin) return true;
    final me = effectiveRole;
    if (me == null) return false;
    return me.canManage(target);
  }

  /// True si la permission [p] requiert un owner pour être appliquée
  /// (typiquement `shop.delete` et `admin.remove`). Utile pour gater l'UI
  /// (afficher un cadenas / message "réservé au propriétaire").
  bool requiresOwnerApproval(EmployeePermission p) => p.isOwnerOnly;

  // ── Abonnement ─────────────────────────────────────────────────────────────
  bool get hasActiveSubscription => plan.isActive || isSuperAdmin;
  bool get canUseOffline         => plan.offlineEnabled || isSuperAdmin;
  bool get canAddShop            => plan.isActive && plan.maxShops > 0 || isSuperAdmin;

  // ── Inventaire ────────────────────────────────────────────────────────────
  // Lecture libre pour les membres même en mode dégradé. Les actions
  // d'écriture exigent en plus `hasActiveSubscription`.
  bool get canViewProducts  => isMember
      && _grain(EmployeePermission.inventoryView, legacy: true);
  bool get canAddProduct    => hasActiveSubscription
      && _grain(EmployeePermission.inventoryWrite, legacy: isShopAdmin);
  bool get canEditProduct   => hasActiveSubscription
      && _grain(EmployeePermission.inventoryWrite, legacy: isShopAdmin);
  bool get canDeleteProduct => hasActiveSubscription
      && _grain(EmployeePermission.inventoryDelete, legacy: isShopAdmin);
  bool get canManageStock   => hasActiveSubscription
      && _grain(EmployeePermission.inventoryStock, legacy: isShopAdmin);

  // ── Caisse ────────────────────────────────────────────────────────────────
  bool get canAccessCaisse   => isMember
      && _grain(EmployeePermission.caisseAccess, legacy: true);
  bool get canCreateOrder    => hasActiveSubscription
      && _grain(EmployeePermission.caisseSell, legacy: isMember);
  bool get canEditOrder      => hasActiveSubscription
      && _grain(EmployeePermission.caisseEditOrders, legacy: isMember);
  bool get canDeleteOrder    => hasActiveSubscription
      && _grain(EmployeePermission.caisseEditOrders, legacy: isShopAdmin);
  bool get canViewScheduled  =>
      _grain(EmployeePermission.caisseScheduled, legacy: isMember);

  /// Voir TOUTES les commandes de la boutique (vs uniquement les miennes).
  /// Sans cette permission, le caller doit filtrer par `createdByUserId`
  /// + autoriser quand même les commandes au statut `completed`
  /// (= validées par un supérieur). Owner et admin l'ont par défaut.
  bool get canViewAllOrders =>
      _grain(EmployeePermission.caisseViewAllOrders, legacy: isShopAdmin);

  // ── Clients ───────────────────────────────────────────────────────────────
  bool get canViewClients   => isMember
      && _grain(EmployeePermission.crmView, legacy: true);
  bool get canManageClients => hasActiveSubscription
      && _grain(EmployeePermission.crmWrite, legacy: isMember);
  bool get canDeleteClient  => hasActiveSubscription
      && _grain(EmployeePermission.crmDelete, legacy: isShopAdmin);

  // ── Finances ──────────────────────────────────────────────────────────────
  bool get canViewFinances    =>
      _grain(EmployeePermission.financeView, legacy: isShopAdmin);
  bool get canManageExpenses  => hasActiveSubscription
      && _grain(EmployeePermission.financeExpenses, legacy: isShopAdmin);
  bool get canExportFinances  =>
      _grain(EmployeePermission.financeExport, legacy: isShopAdmin);

  // ── Boutique ──────────────────────────────────────────────────────────────
  bool get canEditShopInfo   => hasActiveSubscription
      && _grain(EmployeePermission.shopSettings, legacy: isShopAdmin);
  bool get canManageLocations => hasActiveSubscription
      && _grain(EmployeePermission.shopLocations, legacy: isShopAdmin);
  bool get canViewActivity   =>
      _grain(EmployeePermission.shopActivity, legacy: isShopAdmin);

  /// Gestion des employés (Ressources humaines) — réservée à owner/admin
  /// et super_admin. Pas une permission granulaire (qui peut en gérer
  /// d'autres ne peut pas être un user simple).
  bool get canManageMembers => isShopAdmin && hasActiveSubscription;

  // ── Ventes spéciales (hotfix_024) ────────────────────────────────────────
  /// Annuler ou rembourser une vente déjà encaissée.
  bool get canCancelSale =>
      _grain(EmployeePermission.salesCancel, legacy: isShopAdmin);

  /// Appliquer une remise hors barème sur le panier.
  bool get canApplyDiscount =>
      _grain(EmployeePermission.salesDiscount, legacy: isShopAdmin);

  /// Inviter / créer un nouveau membre dans la boutique.
  bool get canInviteMembers =>
      _grain(EmployeePermission.membersInvite, legacy: isShopAdmin);

  // ── Permissions OWNER-ONLY (hotfix_024) ─────────────────────────────────
  /// Supprimer la boutique. Garde-fou : isOwnerOnly empêche l'admin de
  /// l'exécuter même si la permission lui était accordée par erreur.
  bool get canDeleteShop =>
      isOwner && _grain(EmployeePermission.shopDelete, legacy: true);

  /// Retirer un administrateur de la boutique.
  bool get canRemoveAdmin =>
      isOwner && _grain(EmployeePermission.adminRemove, legacy: true);

  /// Peut accéder au flow de création d'une nouvelle boutique. Par défaut
  /// owner. Le propriétaire peut déléguer cette permission à un admin précis
  /// (ex: assistant chargé d'ouvrir une succursale). Jamais accordée à un
  /// user. Distinct de `canCreateShop(count)` qui vérifie le quota du plan.
  bool get canStartCreateShop =>
      isOwner || _grain(EmployeePermission.shopCreate, legacy: false);

  /// "Admin principal" autorisé aux modifications profondes (reset, purge,
  /// suppression de boutique, suppression d'admins). Par défaut owner. Le
  /// propriétaire peut désigner UN SEUL admin par boutique avec ce pouvoir
  /// (unicité enforce côté Flutter dans EmployeeFormSheet + trigger SQL).
  bool get canDoFullShopEdit =>
      isOwner || _grain(EmployeePermission.shopFullEdit, legacy: false);

  /// Alias rétrocompatible — anciens call sites.
  bool get canViewAnalytics => canViewFinances;

  // ── Super admin ───────────────────────────────────────────────────────────
  bool get canAccessAdminPanel => isSuperAdmin;
  bool get canBlockUsers       => isSuperAdmin;
  bool get canManageAllShops   => isSuperAdmin;
  bool get canManagePlans      => isSuperAdmin;

  // ── Vérification quota ────────────────────────────────────────────────────
  bool canAddMember(int currentMemberCount) =>
      isShopAdmin && currentMemberCount < plan.maxUsersPerShop;

  // Variantes "subscription-aware" — relai vers UserPlan, qui prend en
  // compte super_admin et l'état actif. À utiliser dans les guards UI
  // (cf. SubscriptionGuard / UpgradeSheet).
  bool canCreateShop(int currentShopCount) =>
      plan.canAddShop(currentShopCount);
  bool canCreateUser(int currentUserCount) =>
      plan.canAddUser(currentUserCount);
  bool canCreateProduct(int currentProductCount) =>
      plan.canAddProduct(currentProductCount);

  /// Test feature flag — relai vers `UserPlan.hasFeature`.
  bool hasFeature(Feature f) => plan.hasFeature(f);

  // ── Raison du refus (pour les messages d'erreur) ─────────────────────────
  String? denyReason(String action) {
    if (plan.isBlocked)             return 'Votre compte est bloqué.';
    if (!hasActiveSubscription)     return 'Abonnement inactif ou expiré.';
    if (!isMember)                  return 'Vous n\'êtes pas membre de cette boutique.';
    if (!isShopAdmin) {
      const adminOnly = {
        'canAddProduct', 'canEditProduct', 'canDeleteProduct',
        'canEditShopInfo', 'canManageMembers', 'canDeleteOrder',
      };
      if (adminOnly.contains(action))
        return 'Action réservée aux administrateurs.';
    }
    return null;
  }
}
