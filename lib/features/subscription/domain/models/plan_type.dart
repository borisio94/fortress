// ─── PlanType, Feature, PlanLimits ─────────────────────────────────────────
//
// Source de vérité côté Dart : les valeurs des limites doivent correspondre
// au seed SQL `plans` (cf. supabase/hotfix_017_subscriptions.sql).
// `PlanLimits.fallback(PlanType)` sert quand la RPC n'a pas pu être appelée
// (offline, première install) — la base distante reste prioritaire.
// ───────────────────────────────────────────────────────────────────────────

/// Type d'abonnement métier. `expired` n'est pas un tier en soi : c'est
/// l'état d'un user dont le `sub_status` est expiré ou dont la date est
/// dépassée. Conservé dans l'enum pour faciliter le typage côté UI.
enum PlanType {
  trial,
  starter,
  pro,
  business,
  expired,
}

/// Feature flags premium. La présence d'une feature dans le plan courant
/// est testée par `subscriptionProvider.hasFeature(Feature)`.
enum Feature {
  multiShop,
  advancedReports,
  csvExport,
  finances,
  apiIntegration,
  // TODO: brancher l'intégration WhatsApp automatique quand l'API client
  //       sera en place. Déclaré dans l'enum pour permettre les guards
  //       dès maintenant, mais aucune feature ne le requiert pour l'instant.
  whatsappAuto,
}

/// Conversions string ↔ enum, alignées sur le SQL (`plans.name` et clés
/// JSONB `features`). Les inconnus deviennent `expired` (PlanType) ou
/// retournent null (Feature).
extension PlanTypeX on PlanType {
  /// Clé canonique utilisée côté SQL et JSON.
  String get key => switch (this) {
    PlanType.trial    => 'trial',
    PlanType.starter  => 'starter',
    PlanType.pro      => 'pro',
    PlanType.business => 'business',
    PlanType.expired  => 'expired',
  };

  /// True si le tier permet effectivement d'utiliser l'app (pas expired).
  bool get isUsable =>
      this == PlanType.trial   ||
      this == PlanType.starter ||
      this == PlanType.pro     ||
      this == PlanType.business;

  static PlanType fromString(String? s) {
    switch ((s ?? '').toLowerCase()) {
      case 'trial':                       return PlanType.trial;
      case 'starter':
      case 'normal':                      return PlanType.starter; // legacy
      case 'pro':                         return PlanType.pro;
      case 'business':                    return PlanType.business;
      default:                            return PlanType.expired;
    }
  }
}

extension FeatureX on Feature {
  String get key => switch (this) {
    Feature.multiShop        => 'multiShop',
    Feature.advancedReports  => 'advancedReports',
    Feature.csvExport        => 'csvExport',
    Feature.finances         => 'finances',
    Feature.apiIntegration   => 'apiIntegration',
    Feature.whatsappAuto     => 'whatsappAuto',
  };

  static Feature? fromString(String s) {
    for (final f in Feature.values) {
      if (f.key == s) return f;
    }
    return null;
  }
}

/// Limites quantitatives + features par tier. Utilisé en fallback offline
/// quand `get_user_plan` ne peut pas être appelée. La table `plans` côté
/// Supabase reste source de vérité.
class PlanLimits {
  final int           maxShops;
  final int           maxUsersPerShop;
  final int           maxProducts;
  final bool          offlineEnabled;
  final List<Feature> features;
  final int           trialDays;

  const PlanLimits({
    required this.maxShops,
    required this.maxUsersPerShop,
    required this.maxProducts,
    required this.offlineEnabled,
    required this.features,
    this.trialDays = 0,
  });

  /// Sentinelle pour signifier « illimité ».
  static const int unlimited = 2147483647;

  /// Limites par défaut pour chaque tier — valeurs à conserver synchrones
  /// avec le seed SQL `plans` (hotfix_017).
  // Toutes les fonctionnalités (le modèle v3 différencie par QUOTAS, pas par
  // features : Starter « accède au reste des fonctionnalités »).
  static const List<Feature> _allFeatures = [
    Feature.multiShop,
    Feature.advancedReports,
    Feature.csvExport,
    Feature.finances,
    Feature.apiIntegration,
  ];

  static const Map<PlanType, PlanLimits> _byType = {
    // Essai = quotas Business (accès max), 14 jours.
    PlanType.trial: PlanLimits(
      maxShops:        5,
      maxUsersPerShop: 4,
      maxProducts:     unlimited,
      offlineEnabled:  true,
      features:        _allFeatures,
      trialDays:       14,
    ),
    PlanType.starter: PlanLimits(
      maxShops:        1,
      maxUsersPerShop: 1,
      maxProducts:     500,
      offlineEnabled:  true,
      features:        _allFeatures,
    ),
    PlanType.pro: PlanLimits(
      maxShops:        3,
      maxUsersPerShop: 3,
      maxProducts:     1500,
      offlineEnabled:  true,
      features:        _allFeatures,
    ),
    PlanType.business: PlanLimits(
      maxShops:        5,
      maxUsersPerShop: 4,
      maxProducts:     unlimited,
      offlineEnabled:  true,
      features:        _allFeatures,
    ),
    PlanType.expired: PlanLimits(
      maxShops:        0,
      maxUsersPerShop: 0,
      maxProducts:     0,
      offlineEnabled:  false,
      features:        [],
    ),
  };

  static PlanLimits fallback(PlanType type) =>
      _byType[type] ?? _byType[PlanType.expired]!;
}
