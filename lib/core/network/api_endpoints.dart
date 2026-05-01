class ApiEndpoints {
  static const String baseUrl = 'https://api.posapp.com/v1';

  // ── Auth ──────────────────────────────────────────────────────────
  static const String login          = '/auth/login';
  static const String register       = '/auth/register';
  static const String refresh        = '/auth/refresh';
  static const String logout         = '/auth/logout';
  static const String forgotPassword = '/auth/forgot-password';

  // ── Shops ─────────────────────────────────────────────────────────
  static const String shops       = '/shops';
  static const String shopMembers = '/shops/{id}/members';
  static String shopById(String id)    => '/shops/$id';
  static String shopStats(String id)   => '/shops/$id/stats';

  // ── Hub central ───────────────────────────────────────────────────
  static const String hubStats      = '/hub/stats';
  static const String hubComparison = '/hub/comparison';

  // ── Produits ──────────────────────────────────────────────────────
  static String products(String shopId)                   => '/shops/$shopId/products';
  static String productById(String shopId, String id)     => '/shops/$shopId/products/$id';
  static String productStock(String shopId, String id)    => '/shops/$shopId/products/$id/stock';

  // ── Ventes ────────────────────────────────────────────────────────
  static String sales(String shopId)                      => '/shops/$shopId/sales';
  static String saleById(String shopId, String id)        => '/shops/$shopId/sales/$id';

  // ── Clients ───────────────────────────────────────────────────────
  static String clients(String shopId)                    => '/shops/$shopId/clients';
  static String clientById(String shopId, String id)      => '/shops/$shopId/clients/$id';

  // ── Rapports ──────────────────────────────────────────────────────
  static String dailyReport(String shopId)                => '/shops/$shopId/reports/daily';
  static String topProducts(String shopId)                => '/shops/$shopId/reports/top-products';
}
