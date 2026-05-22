class RouteNames {
  // Pages marketing publiques (sans auth)
  static const landing = '/';
  static const pricing = '/pricing';

  // Auth
  static const login = '/auth/login';
  static const register = '/auth/register';
  static const forgotPassword = '/auth/forgot-password';
  static const acceptInvite = '/accept-invite';

  // Shop selector
  static const shopSelector = '/shop-selector';
  static const createShop = '/shop-selector/create';
  static const editShop   = '/shop-selector/edit/:shopId';

  // Hub central (multi-boutiques)
  static const hub = '/hub';
  static const shopComparison = '/hub/comparison';

  // Boutique active (:shopId)
  static const dashboard = '/shop/:shopId/dashboard';
  static const caisse = '/shop/:shopId/caisse';
  static const inventaire = '/shop/:shopId/inventaire';
  static const crm = '/shop/:shopId/crm';
  static const clientDetail = '/shop/:shopId/crm/client/:clientId';
  static const finances = '/shop/:shopId/finances';
  static const historique = '/shop/:shopId/historique';
  static const parametres = '/shop/:shopId/parametres';
  static const shopSettings = '/shop/:shopId/parametres/shop';
  static const stockLocations = '/shop/:shopId/parametres/locations';
  static const stockLocationContents = '/shop/:shopId/parametres/locations/:locationId';
  static const stockTransfers = '/shop/:shopId/parametres/transfers';
  static const userProfile = '/shop/:shopId/parametres/profile';
  static const aide        = '/shop/:shopId/aide';
  static const apropos     = '/shop/:shopId/apropos';
  static const employees   = '/shop/:shopId/employees';
  static const tickets     = '/shop/:shopId/tickets';
  static const ticketDetail = '/shop/:shopId/tickets/:ticketId';
  static const languagePage = '/shop/:shopId/parametres/language';
  static const currencyPage  = '/shop/:shopId/parametres/currency';
  static const themePage     = '/shop/:shopId/parametres/theme';
  static const caisseConfigPage  = '/shop/:shopId/parametres/caisse';
  static const whatsappTemplatesPage = '/shop/:shopId/parametres/whatsapp-templates';
  static const notificationsPage = '/shop/:shopId/parametres/notifications';
  static const paymentsPage      = '/shop/:shopId/parametres/payments';
  static const pinDeletePage     = '/shop/:shopId/parametres/pin/delete';
  /// Page centralisée des exports (CSV/PDF) — une card par type.
  static const exportsPage       = '/shop/:shopId/parametres/exports';

  // Onboarding (PR-1 + PR-2) — flow nouveau utilisateur.
  /// Slides marketing 1ʳᵉ ouverture (3 cartes).
  static const onboardingSlides     = '/onboarding/slides';
  /// Choix « créer un compte » / « j'ai déjà un compte ».
  static const onboardingAuthChoice = '/onboarding/auth-choice';
  /// Inscription minimale 3 champs (nom · email · password).
  static const onboardingRegister   = '/onboarding/register';
  /// Wizard boutique 3 étapes (PR-2) — appelle CreateShopUseCase à la fin.
  static const onboardingShop       = '/onboarding/shop';
  /// Ajout produit éclair 3 champs (PR-2). Utilisé par la checklist.
  static const quickAddProduct      = '/shop/:shopId/inventaire/quick-add';

  // Super Admin
  static const adminPanel    = '/admin';
  static const subscription    = '/subscription';
  static const superAdminHome  = '/super-admin';
  static const adminSubscriptions = '/admin/subscriptions';
  /// Hub super-admin « Éléments supprimés » (commandes + produits).
  /// Onglet par défaut : Commandes.
  static const superAdminDeletedHub = '/super-admin/deleted';
  /// Hub avec onglet « Commandes » forcé (deeplink direct).
  static const superAdminDeletedOrders   = '/super-admin/deleted/orders';
  /// Hub avec onglet « Produits » forcé (deeplink direct).
  static const superAdminDeletedProducts = '/super-admin/deleted/products';
  /// Anciennes routes legacy (pré-hub) conservées comme alias pour ne
  /// pas casser d'éventuels bookmarks ou liens externes.
  static const superAdminDeletedOrdersLegacy   = '/super-admin/orders/deleted';
  static const superAdminDeletedProductsLegacy = '/super-admin/products/deleted';
  /// Super-admin PR-3 : messagerie broadcast · stats plateforme · incidents.
  static const superAdminBroadcast = '/super-admin/broadcast';
  static const superAdminStats     = '/super-admin/stats';
  static const superAdminIncidents = '/super-admin/incidents';
  /// Super-admin PR-4 : exports plateforme (CSV).
  static const superAdminExport    = '/super-admin/export';
}