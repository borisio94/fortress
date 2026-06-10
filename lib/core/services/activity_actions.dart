// ═════════════════════════════════════════════════════════════════════════════
// Catalogue CENTRAL des actions auditées (source unique de vérité).
//
// Objectif : qu'AUCUNE action de la boutique ne « passe entre les filières ».
// La page Historique filtre par catégorie (Ventes / Produits / Stock / Comptes
// / Alertes / Connexions). Une action sans catégorie connue retombait sur
// 'other' → invisible dans tous les filtres sauf « Tous ». Ce fichier garantit
// que chaque action émise dans l'app a une catégorie valide.
//
// Pur Dart (aucun import Flutter) → testable en unit test
// (test/unit/activity_actions_test.dart vérifie qu'aucune action n'est 'other').
//
// RÈGLE : toute nouvelle action passée à ActivityLogService.log(action: ...)
// DOIT être ajoutée ici (dans _categories) ET dans la liste du test.
// ═════════════════════════════════════════════════════════════════════════════

/// Catégories de filtrage de l'historique (alignées sur _FilterBar).
class ActivityCategory {
  static const sale    = 'sale';     // Ventes / commandes / encaissements
  static const shop    = 'shop';     // Produits / clients / dépenses / méta
  static const stock   = 'stock';    // Mouvements de stock / réceptions
  static const account = 'account';  // Comptes / membres / abonnements
  static const alert   = 'alert';    // Actions sensibles / incidents
  static const auth    = 'auth';     // Connexions / sécurité
  static const other   = 'other';    // Non catégorisé (à éviter !)

  static const all = <String>{sale, shop, stock, account, alert, auth};
}

class ActivityActions {
  ActivityActions._();

  /// Map action → catégorie. EXHAUSTIVE : toute action émise par l'app y est.
  static const Map<String, String> _categories = {
    // ── Auth / sécurité ──────────────────────────────────────────────
    'user_login':                 ActivityCategory.auth,
    'user_signup':                ActivityCategory.auth,
    'super_admin_password_reset': ActivityCategory.auth,

    // ── Boutique ─────────────────────────────────────────────────────
    'shop_created':               ActivityCategory.shop,
    'shop_updated':               ActivityCategory.shop,
    'shop_deleted':               ActivityCategory.alert,
    'shop_reset':                 ActivityCategory.alert,
    'shop_reset_keep_products':   ActivityCategory.alert,

    // ── Produits / variantes ─────────────────────────────────────────
    'product_created':            ActivityCategory.shop,
    'product_updated':            ActivityCategory.shop,
    'product_deleted':            ActivityCategory.shop,
    'product_archived':           ActivityCategory.shop,
    'product_auto_merged':        ActivityCategory.shop,
    'product_copied_out':         ActivityCategory.shop,
    'product_copied_in':          ActivityCategory.shop,
    'stock_updated':              ActivityCategory.shop,
    'variant_created':            ActivityCategory.shop,
    'variant_updated':            ActivityCategory.shop,
    'variant_deleted':            ActivityCategory.shop,

    // ── Métadonnées (catégorie / marque / unité) ─────────────────────
    'category_created':           ActivityCategory.shop,
    'category_updated':           ActivityCategory.shop,
    'category_deleted':           ActivityCategory.shop,
    'brand_created':              ActivityCategory.shop,
    'brand_updated':              ActivityCategory.shop,
    'brand_deleted':              ActivityCategory.shop,
    'unit_created':               ActivityCategory.shop,
    'unit_updated':               ActivityCategory.shop,
    'unit_deleted':               ActivityCategory.shop,

    // ── Fournisseurs / réceptions / bons de commande ─────────────────
    'supplier_created':           ActivityCategory.shop,
    'supplier_updated':           ActivityCategory.shop,
    'supplier_deleted':           ActivityCategory.shop,
    'reception_validated':        ActivityCategory.stock,
    'purchase_order_created':     ActivityCategory.shop,
    'purchase_order_updated':     ActivityCategory.shop,
    'purchase_order_deleted':     ActivityCategory.shop,

    // ── Stock (mouvements / audit) ───────────────────────────────────
    'stock_transfer':             ActivityCategory.stock,
    'stock_transfer_out':         ActivityCategory.stock,
    'stock_transfer_in':          ActivityCategory.stock,
    'stock_arrival':              ActivityCategory.stock,
    'stock_incident':             ActivityCategory.alert,
    'stock_return_supplier':      ActivityCategory.stock,
    'stock_return_client':        ActivityCategory.stock,
    'stock_adjustment':           ActivityCategory.stock,
    'stock_adjusted':             ActivityCategory.stock,   // alias émis
    'stock_audit_run':            ActivityCategory.stock,
    'stock_audit_drift':          ActivityCategory.alert,
    'stock_audit_corrected':      ActivityCategory.stock,

    // ── Ventes / commandes ───────────────────────────────────────────
    'sale_completed':             ActivityCategory.sale,
    'sale_cancelled':             ActivityCategory.alert,
    'sale_deleted':               ActivityCategory.alert,
    'order_cancelled':            ActivityCategory.alert,
    'order_refunded':             ActivityCategory.alert,
    'order_delivered':            ActivityCategory.sale,
    'order_rescheduled':          ActivityCategory.sale,
    'order_status_changed':       ActivityCategory.sale,
    'acompte_recorded':           ActivityCategory.sale,
    'order_cancelled_by_client_from_alert': ActivityCategory.alert,

    // ── Clients ──────────────────────────────────────────────────────
    'client_created':             ActivityCategory.shop,
    'client_updated':             ActivityCategory.shop,
    'client_deleted':             ActivityCategory.shop,

    // ── Dépenses ─────────────────────────────────────────────────────
    'expense_created':            ActivityCategory.shop,
    'expense_updated':            ActivityCategory.shop,
    'expense_deleted':            ActivityCategory.shop,

    // ── Membres ──────────────────────────────────────────────────────
    'member_added':               ActivityCategory.account,
    'member_removed':             ActivityCategory.account,
    'member_role_changed':        ActivityCategory.account,
    'member_suspended':           ActivityCategory.account,
    'member_reactivated':         ActivityCategory.account,

    // ── Comptes / abonnements ────────────────────────────────────────
    'user_blocked':               ActivityCategory.alert,
    'user_unblocked':             ActivityCategory.account,
    'subscription_activated':     ActivityCategory.account,
    'subscription_cancelled':     ActivityCategory.account,
    'plan_created':               ActivityCategory.account,
    'plan_updated':               ActivityCategory.account,
    'plan_deleted':               ActivityCategory.account,
    'user_deleted':               ActivityCategory.alert,
    'account_deleted':            ActivityCategory.alert,
    'platform_reset':             ActivityCategory.alert,
    'broadcast_sent':             ActivityCategory.account,
  };

  /// Catégorie d'une action (jamais null). 'other' = non catalogué (à éviter).
  static String categoryOf(String action) =>
      _categories[action] ?? ActivityCategory.other;

  /// true si l'action est cataloguée (donc visible dans un filtre).
  static bool isKnown(String action) => _categories.containsKey(action);

  /// Toutes les actions connues (pour les tests / introspection).
  static Set<String> get known => _categories.keys.toSet();
}
