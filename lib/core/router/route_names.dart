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

  // Super Admin
  static const adminPanel    = '/admin';
  static const subscription    = '/subscription';
  static const superAdminHome  = '/super-admin';
  static const adminSubscriptions = '/admin/subscriptions';
}