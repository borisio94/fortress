import '../../features/subscription/domain/models/plan_type.dart';

// ─── Plan & statut abonnement d'un utilisateur ──────────────────────────────
//
// `UserPlan` est l'état Riverpod (`subscriptionProvider`). Pour la couche
// métier multi-plans (étape 2), voir aussi `Subscription` qui enrichit ces
// données avec id/userId/billingCycle/etc. issus directement de la table
// subscriptions. UserPlan reste la lecture rapide dérivée de la RPC
// `get_user_plan`.
//
// Compat : `PlanName.normal` est conservé en legacy et mappé vers
// `PlanType.starter` côté UI. Les nouveaux noms (`trial`, `starter`,
// `business`) viennent de la RPC après le SQL hotfix_017.

enum PlanName { trial, starter, pro, business, normal, none }

class UserPlan {
  final PlanName       plan;
  final bool           offlineEnabled;
  final int            maxShops;
  final int            maxUsersPerShop;
  final int            maxProducts;
  final List<Feature>  features;
  final String         subStatus;       // 'active' | 'trial' | 'expired' | 'cancelled' | 'none'
  final DateTime?      expiresAt;
  final bool           isBlocked;
  final bool           isSuperAdmin;

  const UserPlan({
    this.plan            = PlanName.none,
    this.offlineEnabled  = false,
    this.maxShops        = 0,
    this.maxUsersPerShop = 0,
    this.maxProducts     = 0,
    this.features        = const [],
    this.subStatus       = 'none',
    this.expiresAt,
    this.isBlocked       = false,
    this.isSuperAdmin    = false,
  });

  // Aucun abonnement (état initial)
  factory UserPlan.empty() => const UserPlan();

  // Super admin — tous les droits, toutes les features
  factory UserPlan.superAdmin() => const UserPlan(
    plan:            PlanName.business,
    offlineEnabled:  true,
    maxShops:        999,
    maxUsersPerShop: 999,
    maxProducts:     2147483647,
    features:        Feature.values,
    subStatus:       'active',
    isBlocked:       false,
    isSuperAdmin:    true,
  );

  factory UserPlan.fromMap(Map<String, dynamic> m, {bool isSuperAdmin = false}) {
    if (isSuperAdmin) return UserPlan.superAdmin();
    final planStr = (m['plan_name'] as String? ?? 'none').toLowerCase();
    final featuresRaw = m['features'];
    final features = <Feature>[];
    if (featuresRaw is List) {
      for (final f in featuresRaw) {
        if (f is String) {
          final feat = FeatureX.fromString(f);
          if (feat != null) features.add(feat);
        }
      }
    }
    return UserPlan(
      plan: switch (planStr) {
        'trial'    => PlanName.trial,
        'starter'  => PlanName.starter,
        'normal'   => PlanName.starter, // legacy
        'pro'      => PlanName.pro,
        'business' => PlanName.business,
        _          => PlanName.none,
      },
      offlineEnabled:  m['offline_enabled']     as bool?   ?? false,
      maxShops:        (m['max_shops']           as num?)?.toInt() ?? 0,
      maxUsersPerShop: (m['max_users_per_shop']  as num?)?.toInt() ?? 0,
      maxProducts:     (m['max_products']        as num?)?.toInt() ?? 0,
      features:        features,
      subStatus:       m['sub_status']           as String? ?? 'none',
      expiresAt:       m['expires_at'] != null
          ? DateTime.tryParse(m['expires_at'].toString())
          : null,
      isBlocked:       m['is_blocked']  as bool? ?? false,
      isSuperAdmin:    false,
    );
  }

  /// Sérialisation pour cache Hive (clé `user_plan_<userId>`).
  Map<String, dynamic> toMap() => {
    'plan_name':           switch (plan) {
      PlanName.trial    => 'trial',
      PlanName.starter  => 'starter',
      PlanName.normal   => 'starter',
      PlanName.pro      => 'pro',
      PlanName.business => 'business',
      PlanName.none     => 'none',
    },
    'offline_enabled':     offlineEnabled,
    'max_shops':           maxShops,
    'max_users_per_shop':  maxUsersPerShop,
    'max_products':        maxProducts,
    'features':            features.map((f) => f.key).toList(),
    'sub_status':          subStatus,
    'expires_at':          expiresAt?.toIso8601String(),
    'is_blocked':          isBlocked,
  };

  // ── Accesseurs métier ─────────────────────────────────────────────────────

  /// `active` ou `trial` non expiré, et compte non bloqué.
  bool get isActive => !isBlocked
      && (subStatus == 'active' || subStatus == 'trial')
      && (expiresAt == null || expiresAt!.isAfter(DateTime.now()));

  bool get isTrial => subStatus == 'trial' && isActive;

  bool get isExpired => subStatus == 'expired'
      || (expiresAt != null && expiresAt!.isBefore(DateTime.now()));

  bool get hasPlan => plan != PlanName.none;
  bool get isPro => plan == PlanName.pro || plan == PlanName.business
      || isSuperAdmin;
  bool get isStarter => plan == PlanName.starter || plan == PlanName.normal;
  bool get isNormal => isStarter; // alias legacy
  bool get isBusiness => plan == PlanName.business || isSuperAdmin;

  /// Tier d'abonnement résolu, `expired` si pas d'abonnement actif.
  PlanType get currentPlan {
    if (isExpired || !hasPlan) return PlanType.expired;
    return switch (plan) {
      PlanName.trial    => PlanType.trial,
      PlanName.starter  => PlanType.starter,
      PlanName.normal   => PlanType.starter,
      PlanName.pro      => PlanType.pro,
      PlanName.business => PlanType.business,
      PlanName.none     => PlanType.expired,
    };
  }

  // Jours restants avant expiration. Clamp [0, 9999].
  int get daysLeft {
    if (expiresAt == null) return isSuperAdmin ? 9999 : 0;
    return expiresAt!.difference(DateTime.now()).inDays.clamp(0, 9999);
  }
  int get daysRemaining => daysLeft;

  bool get expiresSoon => isActive && expiresAt != null && daysLeft <= 7;

  String get planLabel => switch (plan) {
    PlanName.trial    => 'Essai',
    PlanName.starter  => 'Starter',
    PlanName.normal   => 'Starter',
    PlanName.pro      => 'Pro',
    PlanName.business => 'Business',
    PlanName.none     => 'Aucun',
  };

  // ── Quotas dynamiques ─────────────────────────────────────────────────────

  /// Peut créer une boutique de plus ? Le caller fournit le compteur courant
  /// (depuis Hive ou Supabase).
  bool canAddShop(int currentShopCount) =>
      isSuperAdmin
      || (isActive && currentShopCount < maxShops);

  /// Peut ajouter un membre de plus dans une boutique ? Le caller fournit
  /// le nombre de membres actuels du shop.
  bool canAddUser(int currentUserCount) =>
      isSuperAdmin
      || (isActive && currentUserCount < maxUsersPerShop);

  /// Peut créer un produit de plus dans une boutique ? `maxProducts <= 0`
  /// désactive le quota (illimité).
  bool canAddProduct(int currentProductCount) =>
      isSuperAdmin
      || (isActive
          && (maxProducts <= 0 || currentProductCount < maxProducts));

  /// Test feature flag.
  bool hasFeature(Feature f) => isSuperAdmin || features.contains(f);

  @override
  String toString() => 'UserPlan($planLabel, $subStatus, blocked=$isBlocked, '
      'super=$isSuperAdmin, offline=$offlineEnabled, '
      'maxProducts=$maxProducts, features=${features.map((f) => f.key).toList()})';
}
