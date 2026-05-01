import 'plan_type.dart';

// ─── Subscription model ────────────────────────────────────────────────────
//
// Représente un row de la table `subscriptions` côté Supabase, enrichi du
// `plan_type` issu de la jointure avec `plans`. Stocké en cache Hive sous la
// clé `subscription_$userId` dans `HiveBoxes.settingsBox` (Map<String,dynamic>).
//
// Pas de TypeAdapter Hive généré : le projet stocke partout via Map JSON
// pour rester sérialisable directement vers Supabase ; même convention ici.
// ───────────────────────────────────────────────────────────────────────────

class Subscription {
  final String     id;
  final String     userId;
  final String     planId;
  final PlanType   planType;
  final String     billingCycle;     // 'monthly' | 'quarterly' | 'yearly'
  final String     subStatus;        // 'active' | 'trial' | 'expired' | 'cancelled'
  final DateTime   startedAt;
  final DateTime   expiresAt;
  final DateTime?  cancelledAt;
  final double     amountPaid;
  final String?    paymentRef;
  final String?    notes;
  final String?    activatedBy;
  final bool       isAnnual;

  // Limites résolues (depuis la jointure plans). Ces champs viennent de
  // `get_user_plan` RPC ou du fallback `PlanLimits.fallback(planType)`.
  final int          maxShops;
  final int          maxUsersPerShop;
  final int          maxProducts;
  final bool         offlineEnabled;
  final List<Feature> features;

  const Subscription({
    required this.id,
    required this.userId,
    required this.planId,
    required this.planType,
    required this.billingCycle,
    required this.subStatus,
    required this.startedAt,
    required this.expiresAt,
    this.cancelledAt,
    this.amountPaid     = 0,
    this.paymentRef,
    this.notes,
    this.activatedBy,
    this.isAnnual       = false,
    required this.maxShops,
    required this.maxUsersPerShop,
    required this.maxProducts,
    required this.offlineEnabled,
    required this.features,
  });

  /// Subscription "vide" — utilisée pour un user sans abonnement actif. Tier
  /// `expired` avec limites à zéro.
  factory Subscription.empty(String userId) {
    final lim = PlanLimits.fallback(PlanType.expired);
    final now = DateTime.now();
    return Subscription(
      id:              '',
      userId:          userId,
      planId:          '',
      planType:        PlanType.expired,
      billingCycle:    'monthly',
      subStatus:       'none',
      startedAt:       now,
      expiresAt:       now,
      maxShops:        lim.maxShops,
      maxUsersPerShop: lim.maxUsersPerShop,
      maxProducts:     lim.maxProducts,
      offlineEnabled:  lim.offlineEnabled,
      features:        lim.features,
    );
  }

  /// Subscription "super admin" — tous les droits, jamais expiré.
  factory Subscription.superAdmin(String userId) {
    final lim = PlanLimits.fallback(PlanType.business);
    final now = DateTime.now();
    return Subscription(
      id:              'super-admin',
      userId:          userId,
      planId:          'super-admin',
      planType:        PlanType.business,
      billingCycle:    'yearly',
      subStatus:       'active',
      startedAt:       now,
      expiresAt:       DateTime(now.year + 100),
      maxShops:        lim.maxShops,
      maxUsersPerShop: lim.maxUsersPerShop,
      maxProducts:     lim.maxProducts,
      offlineEnabled:  true,
      features:        lim.features,
    );
  }

  /// Construction depuis le résultat de `get_user_plan(user_id)` :
  /// la RPC retourne plan_name, max_shops, max_users_per_shop, max_products,
  /// offline_enabled, features (JSONB), sub_status, expires_at, is_blocked.
  /// On combine avec [userId] (l'auth context) pour produire une Subscription
  /// minimale (sans le `id` ni `started_at` qui ne sont pas dans la RPC).
  factory Subscription.fromRpc(String userId, Map<String, dynamic> m) {
    final type = PlanTypeX.fromString(m['plan_name'] as String?);
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
    return Subscription(
      id:              '',
      userId:          userId,
      planId:          '',
      planType:        type,
      billingCycle:    'monthly',
      subStatus:       (m['sub_status'] as String?) ?? 'none',
      startedAt:       DateTime.now(),
      expiresAt:       _parseDate(m['expires_at']) ?? DateTime.now(),
      maxShops:        (m['max_shops']           as num?)?.toInt() ?? 0,
      maxUsersPerShop: (m['max_users_per_shop']  as num?)?.toInt() ?? 0,
      maxProducts:     (m['max_products']        as num?)?.toInt() ?? 0,
      offlineEnabled:  (m['offline_enabled']     as bool?) ?? false,
      features:        features,
    );
  }

  /// Construction depuis un row complet de la table `subscriptions` joint
  /// avec `plans` (utilisé par admin_subscriptions_page).
  factory Subscription.fromRow(Map<String, dynamic> m) {
    final p = (m['plans'] as Map?) ?? const {};
    final type = PlanTypeX.fromString(p['name'] as String?);
    final featuresRaw = p['features'];
    final features = <Feature>[];
    if (featuresRaw is List) {
      for (final f in featuresRaw) {
        if (f is String) {
          final feat = FeatureX.fromString(f);
          if (feat != null) features.add(feat);
        }
      }
    }
    return Subscription(
      id:              (m['id']              as String?) ?? '',
      userId:          (m['user_id']         as String?) ?? '',
      planId:          (m['plan_id']         as String?) ?? '',
      planType:        type,
      billingCycle:    (m['billing_cycle']   as String?) ?? 'monthly',
      subStatus:       (m['sub_status']      as String?) ?? 'none',
      startedAt:       _parseDate(m['started_at'])    ?? DateTime.now(),
      expiresAt:       _parseDate(m['expires_at'])    ?? DateTime.now(),
      cancelledAt:     _parseDate(m['cancelled_at']),
      amountPaid:      (m['amount_paid']     as num?)?.toDouble() ?? 0,
      paymentRef:      m['payment_ref']      as String?,
      notes:           m['notes']            as String?,
      activatedBy:     m['activated_by']     as String?,
      isAnnual:        (m['is_annual']       as bool?) ?? false,
      maxShops:        (p['max_shops']           as num?)?.toInt() ?? 0,
      maxUsersPerShop: (p['max_users_per_shop']  as num?)?.toInt() ?? 0,
      maxProducts:     (p['max_products']        as num?)?.toInt() ?? 0,
      offlineEnabled:  (p['offline_enabled']     as bool?) ?? false,
      features:        features,
    );
  }

  Map<String, dynamic> toMap() => {
    'id':                 id,
    'user_id':            userId,
    'plan_id':            planId,
    'plan_type':          planType.key,
    'billing_cycle':      billingCycle,
    'sub_status':         subStatus,
    'started_at':         startedAt.toIso8601String(),
    'expires_at':         expiresAt.toIso8601String(),
    'cancelled_at':       cancelledAt?.toIso8601String(),
    'amount_paid':        amountPaid,
    'payment_ref':        paymentRef,
    'notes':              notes,
    'activated_by':       activatedBy,
    'is_annual':          isAnnual,
    'max_shops':          maxShops,
    'max_users_per_shop': maxUsersPerShop,
    'max_products':       maxProducts,
    'offline_enabled':    offlineEnabled,
    'features':           features.map((f) => f.key).toList(),
  };

  factory Subscription.fromCacheMap(Map<String, dynamic> m) {
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
    return Subscription(
      id:              (m['id']              as String?) ?? '',
      userId:          (m['user_id']         as String?) ?? '',
      planId:          (m['plan_id']         as String?) ?? '',
      planType:        PlanTypeX.fromString(m['plan_type'] as String?),
      billingCycle:    (m['billing_cycle']   as String?) ?? 'monthly',
      subStatus:       (m['sub_status']      as String?) ?? 'none',
      startedAt:       _parseDate(m['started_at'])    ?? DateTime.now(),
      expiresAt:       _parseDate(m['expires_at'])    ?? DateTime.now(),
      cancelledAt:     _parseDate(m['cancelled_at']),
      amountPaid:      (m['amount_paid']     as num?)?.toDouble() ?? 0,
      paymentRef:      m['payment_ref']      as String?,
      notes:           m['notes']            as String?,
      activatedBy:     m['activated_by']     as String?,
      isAnnual:        (m['is_annual']       as bool?) ?? false,
      maxShops:        (m['max_shops']           as num?)?.toInt() ?? 0,
      maxUsersPerShop: (m['max_users_per_shop']  as num?)?.toInt() ?? 0,
      maxProducts:     (m['max_products']        as num?)?.toInt() ?? 0,
      offlineEnabled:  (m['offline_enabled']     as bool?) ?? false,
      features:        features,
    );
  }

  // ── Accesseurs métier ─────────────────────────────────────────────────────

  /// `active` ou `trial` non expiré.
  bool get isActive =>
      (subStatus == 'active' || subStatus == 'trial')
      && expiresAt.isAfter(DateTime.now());

  bool get isTrial => subStatus == 'trial' && isActive;

  bool get isExpired =>
      subStatus == 'expired' || expiresAt.isBefore(DateTime.now());

  bool get isCancelled => subStatus == 'cancelled';

  /// Jours restants avant expiration. Clamp [0, 9999].
  int get daysRemaining {
    final delta = expiresAt.difference(DateTime.now()).inDays;
    return delta < 0 ? 0 : (delta > 9999 ? 9999 : delta);
  }

  bool get expiresSoon => isActive && daysRemaining <= 7;

  // ── Quotas ────────────────────────────────────────────────────────────────

  bool canAddShop(int currentShopCount) =>
      isActive && currentShopCount < maxShops;

  bool canAddUser(int currentUserCount) =>
      isActive && currentUserCount < maxUsersPerShop;

  bool canAddProduct(int currentProductCount) =>
      isActive
      && (maxProducts <= 0 || currentProductCount < maxProducts);

  bool hasFeature(Feature f) => features.contains(f);

  static DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw)?.toLocal();
    return null;
  }
}
