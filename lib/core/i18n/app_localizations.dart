import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;
}

class AppLocalizations {
  final Locale locale;
  const AppLocalizations(this.locale);

  static AppLocalizations? of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations);

  static const LocalizationsDelegate<AppLocalizations> delegate =
  _AppLocalizationsDelegate();

  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = [
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  static const List<Locale> supportedLocales = [Locale('fr'), Locale('en')];

  bool get _isFr => locale.languageCode == 'fr';

  // ── App ──────────────────────────────────────────────────────────────────
  String get appName     => 'Fortress';
  String get appTagline  => _isFr ? 'Votre POS intelligent' : 'Your smart POS';

  // ── Auth — Login ─────────────────────────────────────────────────────────
  String get loginTitle        => _isFr ? 'Bon retour 👋'                 : 'Welcome back 👋';
  String get loginSubtitle     => _isFr ? 'Connectez-vous à votre espace' : 'Sign in to your workspace';
  String get loginEmail        => _isFr ? 'Adresse email'                 : 'Email address';
  String get loginEmailHint    => _isFr ? 'exemple@email.com'             : 'example@email.com';
  String get loginPassword     => _isFr ? 'Mot de passe'                  : 'Password';
  String get loginPasswordHint => '••••••••';
  String get loginForgot       => _isFr ? 'Mot de passe oublié ?'         : 'Forgot password?';
  String get loginButton       => _isFr ? 'Se connecter'                  : 'Sign in';
  String get loginOrWith       => _isFr ? 'Ou se connecter avec'          : 'Or sign in with';
  String get loginNoAccount    => _isFr ? 'Pas encore de compte ? '       : "Don't have an account? ";
  String get loginCreate       => _isFr ? 'Créer un compte'               : 'Create one';

  // ── Auth — Validation ────────────────────────────────────────────────────
  String get errEmailRequired    => _isFr ? 'Email requis'                             : 'Email required';
  String get errEmailInvalid     => _isFr ? 'Email invalide'                           : 'Invalid email';
  String get errPasswordRequired => _isFr ? 'Mot de passe requis'                      : 'Password required';
  String get errPasswordShort    => _isFr ? 'Minimum 6 caractères'                     : 'Minimum 6 characters';
  String get errPasswordMin8     => _isFr ? 'Minimum 8 caractères'                     : 'Minimum 8 characters';
  String get errPasswordUppercase => _isFr ? '1 majuscule minimum'                     : '1 uppercase letter required';
  String get errPasswordDigit    => _isFr ? '1 chiffre minimum'                        : '1 digit required';
  String get errPasswordMismatch => _isFr ? 'Les mots de passe ne correspondent pas'   : 'Passwords do not match';
  String get errNameTooShort     => _isFr ? 'Au moins 3 caractères requis'             : 'At least 3 characters required';
  String get errNameLettersOnly  => _isFr ? 'Lettres uniquement'                       : 'Letters only';

  // ── Auth — Panel gauche ──────────────────────────────────────────────────
  String get panelTagline  => _isFr ? 'Gérez votre commerce\nsans effort.' : 'Manage your business\neffortlessly.';
  String get panelSubtitle => _isFr ? 'Ventes · Stocks · CRM · Analytics'  : 'Sales · Stock · CRM · Analytics';

  // ── Auth — Social ────────────────────────────────────────────────────────
  String get socialGoogle => 'Google';
  String get socialApple  => 'Apple';

  // ── Auth — Register ──────────────────────────────────────────────────────
  String get registerTitle         => _isFr ? 'Créer un compte'               : 'Create an account';
  String get registerName          => _isFr ? 'Nom complet'                   : 'Full name';
  String get registerNameHint      => _isFr ? 'Jean Dupont'                   : 'John Doe';
  String get registerPhone         => _isFr ? 'Téléphone'                     : 'Phone';
  String get registerButton        => _isFr ? 'Créer mon compte'              : 'Create my account';
  String get registerHasAccount    => _isFr ? 'Déjà un compte ? '             : 'Already have an account? ';
  String get registerAlreadyAccount => registerHasAccount;
  String get registerSignIn        => _isFr ? 'Se connecter'                  : 'Sign in';
  String get registerConfirmPass   => _isFr ? 'Confirmer le mot de passe'     : 'Confirm password';
  String get registerEmail         => _isFr ? 'Adresse email'                 : 'Email address';

  // ── Auth — Forgot ────────────────────────────────────────────────────────
  String get forgotTitle    => _isFr ? 'Mot de passe oublié'                     : 'Forgot password';
  String get forgotSubtitle => _isFr ? 'Entrez votre email pour recevoir un lien.' : 'Enter your email to receive a reset link.';
  String get forgotButton   => _isFr ? 'Envoyer'                                 : 'Send';
  String get forgotSuccess  => _isFr ? 'Email de réinitialisation envoyé'        : 'Reset email sent';

  // ── Features ─────────────────────────────────────────────────────────────
  String get featureCaisse    => _isFr ? 'Caisse'    : 'Checkout';
  String get featureStock     => 'Stock';
  String get featureCrm       => 'CRM';
  String get featureAnalytics => 'Analytics';

  // ── Navigation drawer ────────────────────────────────────────────────────
  String get navDashboard  => _isFr ? 'Tableau de bord'  : 'Dashboard';
  String get navBoutique   => _isFr ? 'Boutique'         : 'Shop';
  String get navCaisse     => _isFr ? 'Caisse'           : 'Cash register';
  String get navInventaire => _isFr ? 'Inventaire'       : 'Inventory';
  String get navClients    => _isFr ? 'Clients'          : 'Customers';
  String get navFinances   => _isFr ? 'Finances'         : 'Finances';
  String get navParametres      => _isFr ? 'Paramètres'         : 'Settings';
  String get navGestionBoutique => _isFr ? 'Gestion boutique'   : 'Shop management';
  String get navGestionUsers    => _isFr ? 'Gestion utilisateurs': 'User management';
  String get navHistorique      => _isFr ? 'Historique'         : 'Activity log';
  String get navAdmin           => _isFr ? 'Administration'      : 'Administration';
  // ── Navigation adaptative (bottom nav mobile + sidebar desktop) ─────────
  // Clés en anglais utilisées par AdaptiveScaffold + shell_nav_items. Elles
  // doublonnent volontairement navInventaire / navParametres : la nouvelle
  // nav utilise un nommage unifié `nav<Module>` (anglais), sans toucher aux
  // anciennes clés pour ne rien casser ailleurs.
  String get navInventory  => _isFr ? 'Inventaire'  : 'Inventory';
  String get navOrders     => _isFr ? 'Commandes'   : 'Orders';
  String get navMembers    => _isFr ? 'Membres'     : 'Members';
  String get navSettings   => _isFr ? 'Paramètres'  : 'Settings';
  String get navMore       => _isFr ? 'Plus'        : 'More';
  // Libellés courts utilisés UNIQUEMENT dans le bottom nav mobile pour
  // densifier l'affichage 5 onglets. Les libellés longs (« Tableau de bord »,
  // « Inventaire ») restent utilisés sur le sidebar desktop.
  String get navAccueil    => _isFr ? 'Accueil'     : 'Home';
  String get navStock      => 'Stock';
  // Sous-menus dépliables du sidebar desktop. Les routes existent toutes —
  // ces clés ne servent qu'à étiqueter les feuilles de l'arborescence.
  String get navInvProduits      => _isFr ? 'Produits'      : 'Products';
  String get navInvEmplacements  => _isFr ? 'Emplacements'  : 'Locations';
  String get navInvTransferts    => _isFr ? 'Transferts'    : 'Transfers';
  String get navInvMouvements    => _isFr ? 'Mouvements'    : 'Movements';
  String get navInvIncidents     => _isFr ? 'Incidents'     : 'Incidents';
  String get navOrdSuppliers     => _isFr ? 'Fournisseurs'  : 'Suppliers';
  String get navOrdReceptions    => _isFr ? 'Réceptions'    : 'Receptions';
  String get navOrdReturns       => _isFr ? 'Retours'       : 'Returns';
  String get navSetTheme         => _isFr ? 'Thème'         : 'Theme';
  String get navSetLanguage      => _isFr ? 'Langue'        : 'Language';
  String get navSetNotifications => 'Notifications';
  String get navSetSecurity      => _isFr ? 'Sécurité'      : 'Security';
  // Sous-menus Caisse — sidebar desktop (Caisse → Vente / Commandes) +
  // entrée standalone "Commandes caisse" dans le drawer Plus mobile.
  String get navCaisseVente      => _isFr ? 'Vente'           : 'Sale';
  String get navCaisseCommandes  => _isFr ? 'Commandes caisse': 'Sale orders';
  // ── Membres (onglet ShopSettingsPage) ──────────────────────────────────
  String get shopMembersAddNew     => _isFr ? '+ Nouveau membre' : '+ New member';
  String get shopStatTotal         => _isFr ? 'Total'            : 'Total';
  String get shopStatActive        => _isFr ? 'Actifs'           : 'Active';
  String get shopStatAdmins        => _isFr ? 'Admins'           : 'Admins';
  String get shopSectionOwner      => _isFr ? 'Propriétaire'     : 'Owner';
  String get shopSectionAdmins     => _isFr ? 'Administrateurs'  : 'Administrators';
  String get shopSectionStaff      => _isFr ? 'Personnel'        : 'Staff';
  String get shopSectionStaffEmpty => _isFr
      ? 'Aucun membre du personnel pour le moment.'
      : 'No staff members yet.';
  // ── Dashboard — KPIs alertes & section dédiée ──────────────────────────
  String get dashAlertsTitle  => _isFr ? 'Alertes'      : 'Alerts';
  String get dashScheduled    => _isFr ? 'Programmées'  : 'Scheduled';
  String get dashIncidents    => _isFr ? 'Incidents'    : 'Incidents';
  String get dashExpenses     => _isFr ? 'Dépenses'     : 'Expenses';
  // ── Notifications (état vide du sheet) ─────────────────────────────────
  String get notifEmptyTitle => _isFr
      ? 'Aucune notification' : 'No notifications';
  String get notifEmptyHint  => _isFr
      ? 'Les alertes liées à vos ventes et à votre stock\napparaîtront ici.'
      : 'Alerts about your sales and stock will appear here.';
  String get historiqueRefresh   => _isFr ? 'Rafraîchir'         : 'Refresh';
  String get historiqueRetry     => _isFr ? 'Réessayer'          : 'Retry';
  String get historiqueEmpty     => _isFr ? 'Aucune action journalisée.'        : 'No logged actions yet.';
  String get historiqueLoadError => _isFr ? 'Impossible de charger l\'historique.' : 'Unable to load activity log.';
  String get roleOwner          => _isFr ? 'Propriétaire'        : 'Owner';
  String get navHub        => _isFr ? 'Hub central'      : 'Central Hub';
  String get shopSelector  => _isFr ? 'Mes boutiques'    : 'My shops';
  String get navLogout     => _isFr ? 'Déconnexion'      : 'Sign out';
  String get navLogoutConfirmTitle   => _isFr ? 'Déconnexion'                    : 'Sign out';
  String get navLogoutConfirmBody    => _isFr ? 'Voulez-vous vraiment vous déconnecter ?' : 'Are you sure you want to sign out?';
  String get navLogoutConfirmBtn     => _isFr ? 'Déconnecter'                    : 'Sign out';
  String get cancel                  => _isFr ? 'Annuler'                        : 'Cancel';

  // ── Dashboard ────────────────────────────────────────────────────────────
  String get dashActiveShop     => _isFr ? 'Boutique active'    : 'Active shop';
  String get dashChangeShop     => _isFr ? 'Changer'            : 'Switch';
  String get dashNewShop        => _isFr ? 'Nouvelle'           : 'New';
  String get dashChooseShop     => _isFr ? 'Choisir une boutique': 'Choose a shop';
  String get dashShopActive     => _isFr ? 'Active'             : 'Active';
  String get dashManageShops    => _isFr ? 'Boutiques'          : 'Shops';
  String get dashTitle          => _isFr ? 'Tableau de bord'           : 'Dashboard';
  String get dashOverview       => _isFr ? 'Vue d\'ensemble'           : 'Overview';
  String get dashTodaySales     => _isFr ? 'Ventes du jour'            : 'Today\'s sales';
  String get dashTotalOrders    => _isFr ? 'Commandes'                 : 'Orders';
  String get dashAvgBasket      => _isFr ? 'Panier moyen'              : 'Avg. basket';
  String get dashTotalClients   => _isFr ? 'Clients actifs'            : 'Active clients';
  String get dashRevenue        => _isFr ? 'Chiffre d\'affaires'       : 'Revenue';
  String get dashRecentSales    => _isFr ? 'Ventes récentes'           : 'Recent sales';
  String get dashTopProducts    => _isFr ? 'Top produits'              : 'Top products';
  String get dashQuickAccess    => _isFr ? 'Accès rapide'              : 'Quick access';
  String get dashThisWeek       => _isFr ? 'Semaine'                   : 'Week';
  String get dashThisMonth      => _isFr ? 'Mois'                      : 'Month';
  String get dashSeeAll         => _isFr ? 'Voir tout'                 : 'See all';
  String get dashNewSale        => _isFr ? 'Nouvelle\nvente'           : 'New\nsale';
  String get dashAddProduct     => _isFr ? 'Ajouter\nproduit'          : 'Add\nproduct';
  String get dashAddClient      => _isFr ? 'Ajouter\nclient'           : 'Add\nclient';
  String get dashViewReports    => _isFr ? 'Voir\nfinances'            : 'View\nfinances';
  String get dashOrderStatus    => _isFr ? 'Statut'                    : 'Status';
  String get dashStatusDelivered => _isFr ? 'Livré'                   : 'Delivered';
  String get dashStatusPending  => _isFr ? 'En attente'               : 'Pending';
  String get dashStatusCancelled => _isFr ? 'Annulé'                  : 'Cancelled';
  String get dashPerformance    => _isFr ? 'Performance hebdomadaire'  : 'Weekly performance';
  String get dashOrders         => _isFr ? 'Référence'                 : 'Reference';

  // ── Boutique (ex-Caisse) ──────────────────────────────────────────────────
  String get boutiqueTitle      => _isFr ? 'Boutique'                  : 'Shop';
  String get boutiqueOrders     => _isFr ? 'Commandes'                 : 'Orders';
  String get boutiqueNewOrder   => _isFr ? 'Nouvelle commande'         : 'New order';
  String get boutiqueProducts   => _isFr ? 'Produits'                  : 'Products';
  String get boutiqueCart       => _isFr ? 'Panier'                    : 'Cart';
  String get boutiqueEmpty      => _isFr ? 'Aucune commande pour le moment' : 'No orders yet';
  String get boutiqueEmptyHint  => _isFr ? 'Créez votre première commande' : 'Create your first order';
  String get boutiquePay        => _isFr ? 'Encaisser'                 : 'Checkout';
  String get boutiqueTotal      => 'Total';

  // ── Inventaire ────────────────────────────────────────────────────────────
  String get inventaireTitle    => _isFr ? 'Inventaire'                : 'Inventory';
  String get inventaireEmpty    => _isFr ? 'Aucun produit'             : 'No products';
  String get inventaireEmptyHint => _isFr ? 'Ajoutez votre premier produit' : 'Add your first product';
  String get inventaireAdd      => _isFr ? 'Ajouter un produit'        : 'Add product';
  String get inventaireSearch   => _isFr ? 'Rechercher un produit...'  : 'Search product...';
  String get inventaireStock    => _isFr ? 'Stock'                     : 'Stock';
  String get inventairePrice    => _isFr ? 'Prix'                      : 'Price';
  String get inventaireName     => _isFr ? 'Nom du produit'            : 'Product name';
  String get inventaireNameHint => _isFr ? 'Ex: Coca-Cola 33cl'        : 'E.g. Coca-Cola 33cl';
  String get inventaireSave     => _isFr ? 'Enregistrer'               : 'Save';

  // ── CRM ───────────────────────────────────────────────────────────────────
  String get crmTitle           => _isFr ? 'Clients & CRM'             : 'Customers & CRM';
  String get crmEmpty           => _isFr ? 'Aucun client'              : 'No customers';
  String get crmEmptyHint       => _isFr ? 'Ajoutez votre premier client' : 'Add your first customer';
  String get crmAdd             => _isFr ? 'Ajouter un client'         : 'Add customer';
  String get crmSearch          => _isFr ? 'Rechercher un client...'   : 'Search customer...';
  String get crmVisits          => _isFr ? 'visites'                   : 'visits';
  String get crmTotalPurchases  => _isFr ? 'Total achats'              : 'Total purchases';
  String get crmSendNotif       => _isFr ? 'Envoyer notification'      : 'Send notification';
  String get crmMessage         => _isFr ? 'Message WhatsApp'          : 'WhatsApp message';
  String get crmSend            => _isFr ? 'Envoyer via WhatsApp'      : 'Send via WhatsApp';
  String get crmMessageHint     => _isFr ? 'Votre message...'          : 'Your message...';

  // ── Finances (ex-Rapports) ────────────────────────────────────────────────
  String get financesTitle        => _isFr ? 'Finances'                 : 'Finances';
  String get financesCA           => _isFr ? 'CA Total'                 : 'Total revenue';
  String get financesTransactions => _isFr ? 'Transactions'             : 'Transactions';
  String get financesPanier       => _isFr ? 'Panier moy.'              : 'Avg. basket';
  // KPI cards (page principale)
  String get financesKpiSales     => _isFr ? 'Chiffre d\'affaires'      : 'Revenue';
  String get financesKpiExpenses  => _isFr ? 'Dépenses'                 : 'Expenses';
  String get financesKpiLosses    => _isFr ? 'Pertes'                   : 'Losses';
  String get financesKpiNet       => _isFr ? 'Bénéfice net'             : 'Net profit';
  String get financesVsPrevious   => _isFr ? 'vs période précédente'    : 'vs previous period';
  String get financesSubTransactions => _isFr ? '%d transactions'        : '%d transactions';
  String get financesSubEntries      => _isFr ? '%d entrées'             : '%d entries';
  String get financesSubIncidents    => _isFr ? '%d incidents'           : '%d incidents';
  // Onglets
  String get financesTabRevenus   => _isFr ? 'Revenus'                  : 'Revenue';
  String get financesTabDepenses  => _isFr ? 'Dépenses'                 : 'Expenses';
  String get financesTabPertes    => _isFr ? 'Pertes'                   : 'Losses';
  String get financesTabBilan     => _isFr ? 'Bilan'                    : 'Balance';
  // Lignes du bilan
  String get financesBilanCA          => _isFr ? 'Chiffre d\'affaires'      : 'Revenue';
  String get financesBilanProductCost => _isFr ? 'Coût des produits'        : 'Product cost';
  String get financesBilanScrapped    => _isFr ? 'Pertes rebuts'            : 'Scrapped loss';
  String get financesBilanRepair      => _isFr ? 'Coûts de réparation'      : 'Repair cost';
  String get financesBilanExpenses    => _isFr ? 'Dépenses opérationnelles' : 'Operating expenses';
  String get financesBilanNet         => _isFr ? 'Bénéfice net'             : 'Net profit';
  // Divers
  String get financesEmptyNoData  => _isFr ? 'Aucune donnée sur la période' : 'No data for this period';
  String get financesAddExpense   => _isFr ? 'Ajouter une dépense'     : 'Add expense';
  String get financesRefresh      => _isFr ? 'Rafraîchir'              : 'Refresh';

  // ── Paramètres ────────────────────────────────────────────────────────────
  String get parametresTitle    => _isFr ? 'Paramètres'                : 'Settings';
  String get paramBoutique      => _isFr ? 'Boutique'                  : 'Shop';
  String get paramBoutiqueSettings => _isFr ? 'Paramètres boutique'    : 'Shop settings';
  String get paramCaisseConfig  => _isFr ? 'Configuration caisse'      : 'Checkout config';
  String get paramCompte        => _isFr ? 'Compte'                    : 'Account';
  String get paramProfile       => _isFr ? 'Profil utilisateur'        : 'User profile';
  String get paramEmployes      => _isFr ? 'Employés & permissions'    : 'Employees & permissions';
  String get paramPreferences   => _isFr ? 'Préférences'               : 'Preferences';
  String get paramLanguage      => _isFr ? 'Langue'                    : 'Language';
  String get paramCurrency      => _isFr ? 'Monnaie & format'          : 'Currency & format';
  String get paramNotifications => _isFr ? 'Notifications'             : 'Notifications';
  String get paramIntegrations  => _isFr ? 'Intégrations'              : 'Integrations';
  String get paramWhatsApp      => 'WhatsApp Business';
  String get paramPayments      => _isFr ? 'Modes de paiement'         : 'Payment methods';
  String get paramSession       => _isFr ? 'Session'                   : 'Session';

  // ── Plans / abonnement ────────────────────────────────────────────────────
  String get planTrial          => _isFr ? 'Essai'      : 'Trial';
  String get planStarter        => _isFr ? 'Starter'    : 'Starter';
  String get planPro            => _isFr ? 'Pro'        : 'Pro';
  String get planBusiness       => _isFr ? 'Business'   : 'Business';
  String get planExpired        => _isFr ? 'Expiré'     : 'Expired';

  String get featMultiShop        => _isFr
      ? 'Gestion multi-boutiques'              : 'Multi-shop management';
  String get featAdvancedReports  => _isFr
      ? 'Rapports avancés'                      : 'Advanced reports';
  String get featCsvExport        => _isFr
      ? 'Export CSV'                             : 'CSV export';
  String get featFinances         => _isFr
      ? 'Module finances'                        : 'Finances module';
  String get featApiIntegration   => _isFr
      ? 'Intégration API'                        : 'API integration';
  String get featWhatsappAuto     => _isFr
      ? 'WhatsApp automatique'                   : 'WhatsApp automation';

  // ── Upgrade Sheet ─────────────────────────────────────────────────────────
  String get upgradeFeatureTitle => _isFr
      ? 'Fonctionnalité premium'                : 'Premium feature';
  String upgradeFeatureBody(String feature, String plan) => _isFr
      ? '$feature n\'est pas inclus dans votre forfait actuel. '
        'Passez à $plan pour y accéder.'
      : '$feature is not included in your current plan. '
        'Upgrade to $plan to unlock it.';

  String get upgradeQuotaTitle  => _isFr
      ? 'Limite atteinte'                        : 'Limit reached';
  String upgradeQuotaBody(String label, String current, String max,
      String plan) => _isFr
      ? 'Vous avez atteint votre quota de $label ($current / $max). '
        'Passez à $plan pour continuer.'
      : 'You have reached your $label quota ($current / $max). '
        'Upgrade to $plan to continue.';

  String get upgradeExpiredTitle => _isFr
      ? 'Abonnement expiré'                      : 'Subscription expired';
  String get upgradeExpiredBody  => _isFr
      ? 'Votre abonnement n\'est plus actif. '
        'Renouvelez pour reprendre vos opérations.'
      : 'Your subscription is no longer active. '
        'Renew to resume operations.';

  String get upgradeViewPlans   => _isFr
      ? 'Voir les forfaits'                      : 'View plans';
  String get upgradeRenew       => _isFr
      ? 'Renouveler'                              : 'Renew';

  // ── Subscription page ─────────────────────────────────────────────────────
  String get subTitle           => _isFr ? 'Abonnement'        : 'Subscription';
  String get subCurrentStatus   => _isFr ? 'Statut actuel'     : 'Current status';
  String get subActiveUntil     => _isFr ? 'Actif jusqu\'au'   : 'Active until';
  String get subTrialUntil      => _isFr ? 'Essai jusqu\'au'   : 'Trial until';
  String get subExpiredOn       => _isFr ? 'Expiré le'         : 'Expired on';
  String get subCancelled       => _isFr ? 'Annulé'            : 'Cancelled';
  String get subDaysLeft        => _isFr ? 'jours restants'    : 'days left';
  String get subDayLeft         => _isFr ? 'jour restant'      : 'day left';
  String get subBillingCycle    => _isFr ? 'Cycle de paiement' : 'Billing cycle';
  String get subBillMonthly     => _isFr ? 'Mensuel'           : 'Monthly';
  String get subBillQuarterly   => _isFr ? 'Trimestriel'       : 'Quarterly';
  String get subBillYearly      => _isFr ? 'Annuel'            : 'Yearly';
  String get subSavingsQuarterly=> _isFr ? 'Économisez 10%'    : 'Save 10%';
  String get subSavingsYearly   => _isFr ? 'Économisez 17%'    : 'Save 17%';
  String get subAvailablePlans  => _isFr ? 'Forfaits disponibles' : 'Available plans';
  String get subPerMonth        => _isFr ? '/mois'  : '/mo';
  String get subPerQuarter      => _isFr ? '/trim.' : '/qtr';
  String get subPerYear         => _isFr ? '/an'    : '/yr';
  String get subCtaActivate     => _isFr
      ? 'Demander l\'activation' : 'Request activation';
  String get subActivationHint  => _isFr
      ? 'Activation manuelle par notre équipe — paiement Mobile Money. '
        'Cliquez sur le bouton ci-dessous, le message WhatsApp est pré-rempli.'
      : 'Manual activation by our team — Mobile Money payment. '
        'Tap the button below — the WhatsApp message is pre-filled.';
  String subWaMessage(String plan, String cycle, String userId,
      String userEmail) => _isFr
      ? 'Bonjour, je souhaite activer le forfait $plan ($cycle) sur Fortress.\n'
        'User ID : $userId\nEmail : $userEmail'
      : 'Hello, I want to activate the $plan plan ($cycle) on Fortress.\n'
        'User ID: $userId\nEmail: $userEmail';
  String get subWaUnavailable   => _isFr
      ? 'Numéro WhatsApp pas encore configuré. '
        'Contactez le support pour finaliser l\'activation.'
      : 'WhatsApp number not configured yet. '
        'Please contact support to finalize the activation.';

  // Limites par plan (résumé en card)
  String subMaxShops(int n) => _isFr
      ? (n >= 999 ? 'Boutiques illimitées' : '$n boutique${n > 1 ? 's' : ''}')
      : (n >= 999 ? 'Unlimited shops'      : '$n shop${n > 1 ? 's' : ''}');
  String subMaxUsers(int n) => _isFr
      ? (n >= 999 ? 'Utilisateurs illimités' : '$n utilisateur${n > 1 ? 's' : ''}')
      : (n >= 999 ? 'Unlimited users'        : '$n user${n > 1 ? 's' : ''}');
  String subMaxProducts(int n) => _isFr
      ? (n >= 2147483647
          ? 'Produits illimités'
          : '$n produit${n > 1 ? 's' : ''}')
      : (n >= 2147483647
          ? 'Unlimited products'
          : '$n product${n > 1 ? 's' : ''}');
  String get subOfflineYes => _isFr ? 'Mode hors-ligne' : 'Offline mode';

  // Card forfait — actions
  String get subChoosePlan       => _isFr ? 'Choisir'     : 'Choose';
  String get subCurrentPlanBadge => _isFr ? 'Plan actuel' : 'Current plan';
  String get subPopularBadge     => _isFr ? 'Populaire'   : 'Popular';
  String subSavingsAnnual(int pct) => _isFr
      ? 'Économisez $pct%' : 'Save $pct%';
  String get subYearlyShort      => _isFr ? '/an'   : '/yr';
  String get subMonthlyShort     => _isFr ? '/mois' : '/mo';

  // Section 3 — contact admin
  String get subContactAdminTitle => _isFr
      ? 'Activation manuelle' : 'Manual activation';
  String get subContactAdminBody => _isFr
      ? 'Pour activer votre forfait, contactez l\'administrateur.'
      : 'To activate your plan, contact the administrator.';
  String subPlanSelected(String plan) => _isFr
      ? '$plan sélectionné. Contactez l\'administrateur pour activer.'
      : '$plan selected. Contact the administrator to activate.';

  // Barre de progression statut
  String subDaysOverTotal(int left, int total) => _isFr
      ? '$left j restants sur $total' : '$left d left of $total';

  // ── Ressources humaines (HR) ─────────────────────────────────────────────
  String get navResourcesHumaines => _isFr
      ? 'Ressources humaines' : 'Human resources';
  String get hrTitle           => _isFr ? 'Ressources humaines' : 'Human resources';
  String get hrEmployees       => _isFr ? 'Employés'            : 'Employees';
  String get hrNewEmployee     => _isFr ? 'Nouvel employé'      : 'New employee';
  String get hrEditEmployee    => _isFr ? 'Modifier l\'employé' : 'Edit employee';
  String get hrSearchHint      => _isFr
      ? 'Rechercher par nom ou email' : 'Search by name or email';
  String get hrFilterAll       => _isFr ? 'Tous'         : 'All';
  String get hrFilterActive    => _isFr ? 'Actifs'       : 'Active';
  String get hrFilterSuspended => _isFr ? 'Suspendus'    : 'Suspended';
  String get hrFilterArchived  => _isFr ? 'Archivés'     : 'Archived';

  String get hrStatusActive    => _isFr ? 'Actif'        : 'Active';
  String get hrStatusSuspended => _isFr ? 'Suspendu'     : 'Suspended';
  String get hrStatusArchived  => _isFr ? 'Archivé'      : 'Archived';
  String get hrRoleAdmin       => _isFr ? 'Administrateur' : 'Administrator';
  String get hrRoleUser        => _isFr ? 'Employé'      : 'Employee';
  String get hrRoleCustom      => _isFr ? 'Personnalisé' : 'Custom';
  String get hrBadgeOwner      => _isFr ? 'Propriétaire' : 'Owner';

  // Form fields
  String get hrFieldFullName   => _isFr ? 'Nom complet'       : 'Full name';
  String get hrFieldEmail      => _isFr ? 'Adresse email'     : 'Email address';
  String get hrFieldPassword   => _isFr ? 'Mot de passe'      : 'Password';
  String get hrFieldPasswordConfirm => _isFr
      ? 'Confirmer le mot de passe' : 'Confirm password';
  String get hrFieldRole       => _isFr ? 'Rôle'              : 'Role';
  String get hrFieldStatus     => _isFr ? 'Statut'            : 'Status';
  String get hrFieldPermissions => _isFr ? 'Autorisations'    : 'Permissions';

  // Validation
  String get hrErrFullName     => _isFr ? 'Nom requis'        : 'Name required';
  String get hrErrEmail        => _isFr ? 'Email invalide'    : 'Invalid email';
  String get hrErrPassword     => _isFr
      ? 'Min 6 caractères' : 'Min 6 characters';
  String get hrErrPasswordMatch => _isFr
      ? 'Les mots de passe ne correspondent pas'
      : 'Passwords do not match';

  // Permissions — labels par enum value
  String get permInventoryView    => _isFr ? 'Voir les produits'
      : 'View products';
  String get permInventoryWrite   => _isFr ? 'Ajouter / modifier des produits'
      : 'Add / edit products';
  String get permInventoryDelete  => _isFr ? 'Supprimer des produits'
      : 'Delete products';
  String get permInventoryStock   => _isFr ? 'Gérer le stock (réceptions, transferts)'
      : 'Manage stock (receipts, transfers)';
  String get permCaisseAccess     => _isFr ? 'Accéder à la caisse'
      : 'Access cash register';
  String get permCaisseSell       => _isFr ? 'Encaisser des ventes'
      : 'Process sales';
  String get permCaisseEditOrders => _isFr ? 'Modifier / annuler des ventes'
      : 'Edit / cancel orders';
  String get permCaisseScheduled  => _isFr ? 'Accéder aux commandes programmées'
      : 'Access scheduled orders';
  String get permCaisseViewAllOrders => _isFr
      ? 'Voir toutes les commandes (sinon uniquement les siennes)'
      : 'View all orders (otherwise only own)';
  String get permCrmView          => _isFr ? 'Voir les clients' : 'View clients';
  String get permCrmWrite         => _isFr ? 'Ajouter / modifier des clients'
      : 'Add / edit clients';
  String get permCrmDelete        => _isFr ? 'Supprimer des clients'
      : 'Delete clients';
  String get permFinanceView      => _isFr ? 'Voir les rapports financiers'
      : 'View financial reports';
  String get permFinanceExpenses  => _isFr ? 'Gérer les dépenses' : 'Manage expenses';
  String get permFinanceExport    => _isFr ? 'Exporter les données' : 'Export data';
  String get permShopSettings     => _isFr ? 'Modifier les paramètres boutique'
      : 'Edit shop settings';
  String get permShopLocations    => _isFr ? 'Gérer les emplacements de stock'
      : 'Manage stock locations';
  String get permShopActivity     => _isFr ? 'Voir l\'historique d\'activité'
      : 'View activity log';
  // Permissions ajoutées par hotfix_024
  String get permSalesCancel      => _isFr ? 'Annuler / rembourser une vente'
      : 'Cancel / refund a sale';
  String get permSalesDiscount    => _isFr ? 'Appliquer une remise hors barème'
      : 'Apply custom discount';
  String get permMembersInvite    => _isFr ? 'Inviter de nouveaux membres'
      : 'Invite new members';
  String get permShopDelete       => _isFr ? 'Supprimer la boutique (propriétaire)'
      : 'Delete the shop (owner only)';
  String get permAdminRemove      => _isFr ? 'Retirer un administrateur (propriétaire)'
      : 'Remove an administrator (owner only)';
  String get permShopCreate       => _isFr
      ? 'Créer une nouvelle boutique (déléguée par le propriétaire)'
      : 'Create a new shop (delegated by owner)';
  String get permShopFullEdit     => _isFr
      ? 'Admin principal — modifications profondes (reset, purge, suppression)'
      : 'Lead admin — deep edits (reset, purge, deletion)';
  String get hrFullEditAlreadyAssigned => _isFr
      ? 'Un autre admin de cette boutique a déjà la permission "admin '
        'principal". Retire-la-lui d\'abord avant de l\'attribuer ici.'
      : 'Another admin already has the "lead admin" permission for this '
        'shop. Remove it from them first before assigning it here.';

  // Groupes
  String get permGroupInventory   => _isFr ? 'Inventaire' : 'Inventory';
  String get permGroupCaisse      => _isFr ? 'Caisse / Ventes' : 'Cash register / Sales';
  String get permGroupCrm         => _isFr ? 'Clients' : 'Customers';
  String get permGroupFinance     => _isFr ? 'Finances' : 'Finance';
  String get permGroupShop        => _isFr ? 'Boutique' : 'Shop';

  // Presets
  String get hrPresetTitle      => _isFr ? 'Préréglages' : 'Presets';
  String get hrPresetFull       => _isFr ? 'Tout cocher' : 'Check all';
  String get hrPresetEmployee   => _isFr ? 'Employé'     : 'Employee';
  String get hrPresetCashier    => _isFr ? 'Caissier'    : 'Cashier';
  String get hrPresetStock      => _isFr ? 'Gestion stock' : 'Stock manager';
  String get hrPresetAccountant => _isFr ? 'Comptable'   : 'Accountant';
  String get hrPresetAdmin      => _isFr ? 'Admin'       : 'Admin';
  String get hrPresetClear      => _isFr ? 'Tout décocher' : 'Uncheck all';

  // Actions
  String get hrActionSuspend    => _isFr ? 'Suspendre'   : 'Suspend';
  String get hrActionReactivate => _isFr ? 'Réactiver'   : 'Reactivate';
  String get hrActionArchive    => _isFr ? 'Archiver'    : 'Archive';
  String get hrActionDelete     => _isFr ? 'Supprimer définitivement'
      : 'Delete permanently';
  String get hrActionEdit       => _isFr ? 'Modifier'    : 'Edit';
  String get hrActionCreate     => _isFr ? 'Créer un personnel' : 'Create staff member';
  String get hrActionSave       => _isFr ? 'Enregistrer' : 'Save';

  // Messages
  String get hrCreated          => _isFr ? 'Employé créé' : 'Employee created';
  String get hrUpdated          => _isFr ? 'Employé mis à jour'
      : 'Employee updated';
  String get hrDeleted          => _isFr ? 'Employé supprimé'
      : 'Employee deleted';
  String get hrEmptyTitle       => _isFr ? 'Aucun employé' : 'No employees';
  String get hrEmptyHint        => _isFr
      ? 'Commencez par créer votre premier employé.'
      : 'Start by creating your first employee.';
  String get hrAccessDenied     => _isFr
      ? 'Réservé aux administrateurs de la boutique.'
      : 'Reserved to shop administrators.';
  String hrPermCount(int n, int total) => _isFr
      ? '$n / $total autorisations' : '$n / $total permissions';
  String get hrConfirmDelete    => _isFr
      ? 'Supprimer définitivement cet employé ?'
      : 'Permanently delete this employee?';
  String get hrConfirmDeleteHint=> _isFr
      ? 'Le compte de l\'employé est conservé mais il n\'aura plus accès à cette boutique. Action irréversible.'
      : 'The employee account is kept but loses access to this shop. Irreversible.';
  String get hrOnlineRequired   => _isFr
      ? 'Connexion Internet requise pour cette action.'
      : 'Internet connection required for this action.';

  // ── Bannière subscription (mode dégradé) ──────────────────────────────────
  String get subBannerBlocked  => _isFr
      ? 'Compte bloqué. Contactez le support.'
      : 'Account blocked. Contact support.';
  String get subBannerExpired  => _isFr
      ? 'Abonnement expiré. Renouvelez pour continuer.'
      : 'Subscription expired. Renew to continue.';
  String subBannerExpiresSoon(int days) => _isFr
      ? 'Abonnement expire dans $days jour${days > 1 ? 's' : ''}.'
      : 'Subscription expires in $days day${days > 1 ? 's' : ''}.';
  String get subBannerNoPlan   => _isFr
      ? 'Aucun abonnement actif.'
      : 'No active subscription.';
  String get subBannerChoose   => _isFr ? 'Choisir un plan' : 'Choose a plan';

  // ── Drawer item ───────────────────────────────────────────────────────────
  String get drawerSubscription => _isFr ? 'Mon abonnement' : 'My subscription';
  String get drawerBadgeExpired => _isFr ? 'Expiré' : 'Expired';

  // ── Admin subscriptions panel ─────────────────────────────────────────────
  String get adminSubsTitle      => _isFr ? 'Abonnements' : 'Subscriptions';
  String get adminSubsAll        => _isFr ? 'Tous'      : 'All';
  String get adminSubsTrial      => _isFr ? 'Essai'     : 'Trial';
  String get adminSubsActive     => _isFr ? 'Actifs'    : 'Active';
  String get adminSubsExpired    => _isFr ? 'Expirés'   : 'Expired';
  String get adminSubsSearch     => _isFr ? 'Rechercher' : 'Search';
  String get adminSubsActivate   => _isFr ? 'Activer'    : 'Activate';
  String get adminSubsRenew      => _isFr ? 'Renouveler' : 'Renew';
  String get adminSubsTotalUsers => _isFr ? 'Clients'    : 'Customers';
  String get adminSubsTotalActive=> _isFr ? 'Actifs'     : 'Active';
  String get adminSubsTotalExpired=> _isFr ? 'Expirés'   : 'Expired';
  String get adminSubsRevenueMonth=> _isFr ? 'Revenus mensuels' : 'Monthly revenue';
  String get adminSubsSheetTitle => _isFr
      ? 'Activer un abonnement' : 'Activate a subscription';
  String get adminSubsPlan       => _isFr ? 'Forfait' : 'Plan';
  String get adminSubsCycle      => _isFr ? 'Cycle'   : 'Cycle';
  String get adminSubsStartDate  => _isFr ? 'Date de début' : 'Start date';
  String get adminSubsNote       => _isFr ? 'Note interne' : 'Internal note';
  String get adminSubsConfirm    => _isFr ? 'Confirmer'    : 'Confirm';
  String get adminSubsActivated  => _isFr
      ? 'Abonnement activé.' : 'Subscription activated.';
  String get adminSubsAccessDenied => _isFr
      ? 'Accès réservé au super administrateur.'
      : 'Reserved to super administrators.';

  // ── Hub ───────────────────────────────────────────────────────────────────
  String get hubTitle           => _isFr ? 'Hub central'               : 'Central Hub';
  String get hubCompare         => _isFr ? 'Comparer'                  : 'Compare';
  String get hubAllShops        => _isFr ? 'Toutes boutiques'          : 'All shops';
  String get hubBack            => _isFr ? 'Mes boutiques'             : 'My shops';
  String get hubAvgBasket       => _isFr ? 'Panier moyen'              : 'Avg. basket';
  String get hubUniqueClients   => _isFr ? 'Clients uniques'           : 'Unique clients';
  String get hubRevenueBreakdown => _isFr ? 'Répartition CA'            : 'Revenue breakdown';
  String get hubMyShops         => _isFr ? 'Mes boutiques'             : 'My shops';
  String get hubNewShop         => _isFr ? 'Nouvelle boutique'         : 'New shop';
  String get hubBadgeBest       => _isFr ? 'Meilleure'                 : 'Best';
  String get hubBadgeDown       => _isFr ? 'En baisse'                 : 'Down';
  String get hubShareOfRevenue  => _isFr ? 'Part du CA'                : 'Revenue share';
  String hubTransactionsCount(int n) => _isFr
      ? '$n transaction${n > 1 ? 's' : ''}'
      : '$n transaction${n > 1 ? 's' : ''}';
  String get hubBrand           => 'FORTRESS';
  String get hubNotifications   => _isFr ? 'Notifications' : 'Notifications';
  String get hubRevenueByShop   => _isFr ? 'CA par boutique' : 'Revenue by shop';
  String get hubRevenueShare    => _isFr ? 'Répartition du CA' : 'Revenue share';
  String get hubSingleShopHint  => _isFr
      ? 'Une seule boutique active — aucune répartition à afficher.'
      : 'Only one active shop — nothing to break down.';
  String get hubNoData          => _isFr
      ? 'Aucune donnée pour cette période.'
      : 'No data for this period.';
  String get hubBucketHour      => _isFr ? 'h' : 'h';
  String get hubBucketDay       => _isFr ? 'j' : 'd';
  String get hubBucketWeek      => _isFr ? 'S' : 'W';
  String get hubBucketMonth     => _isFr ? 'M' : 'M';

  // ── Commun ────────────────────────────────────────────────────────────────
  String get total         => 'Total';
  String get save          => _isFr ? 'Enregistrer' : 'Save';
  String get search        => _isFr ? 'Rechercher...' : 'Search...';
  String get noData        => _isFr ? 'Aucune donnée' : 'No data';
  String get loading       => _isFr ? 'Chargement...' : 'Loading...';
  String get offlineMode   => _isFr ? 'Mode hors-ligne — données synchronisées dès le retour' : 'Offline mode — data will sync when back online';
  String get periodToday   => _isFr ? "Aujourd'hui"  : 'Today';
  String get periodWeek    => _isFr ? 'Semaine'      : 'Week';
  String get periodMonth   => _isFr ? 'Mois'         : 'Month';
  String get periodQuarter => _isFr ? 'Trimestre'    : 'Quarter';
  String get periodYear        => _isFr ? 'Année'           : 'Year';
  String get periodYesterday   => _isFr ? 'Hier'            : 'Yesterday';
  String get periodCustom      => _isFr ? 'Personnalisé'    : 'Custom';
  String get periodCustomTitle => _isFr ? 'Choisir la période' : 'Choose period';
  String get periodFrom        => _isFr ? 'Du'              : 'From';
  String get periodTo          => _isFr ? 'Au'              : 'To';
  String get periodApply       => _isFr ? 'Appliquer'       : 'Apply';

  // ── AppBar badges ───────────────────────────────────────────────────────────
  String get notificationsTitle => _isFr ? 'Notifications'  : 'Notifications';
  String get cartTitle          => _isFr ? 'Panier'         : 'Cart';
  String get noNotifications    => _isFr ? 'Aucune notification' : 'No notifications';

  // ── Dashboard ────────────────────────────────────────────────────────────────
  String get dashWelcome        => _isFr ? 'Bon retour'        : 'Welcome back';
  String get dashSubtitle       => _isFr ? 'Voici ce qui se passe aujourd\'hui.' : 'Here\'s what\'s happening today.';
  String get dashSalesOverview  => _isFr ? 'Aperçu des ventes' : 'Sales Overview';
  String get dashChartSales     => _isFr ? 'Ventes'            : 'Sales';
  String get dashChartProfit    => _isFr ? 'Bénéfices'         : 'Profit';
  String get dashChartLoss      => _isFr ? 'Pertes'            : 'Loss';
  String get dashNoSalesYet     => _isFr ? 'Pas encore de vente sur cette période' : 'No sales yet for this period';
  String get dashStockOk        => _isFr ? 'Tous les stocks sont à niveau'    : 'All stock levels are good';
  String get dashNewProducts    => _isFr ? 'Nouveaux produits' : 'New products';
  String get dashNewProductsHint => _isFr ? 'Ajoutés dans les 72 dernières heures' : 'Added in the last 72 hours';
  String get dashNoNewProducts  => _isFr ? 'Aucun nouveau produit récent' : 'No recent new products';
  String get dashAddedAgo       => _isFr ? 'Ajouté' : 'Added';
  String get dashLoss           => _isFr ? 'Pertes' : 'Loss';
  String get dashProfit         => _isFr ? 'Bénéfices' : 'Profit';
  String get dashRecentTx       => _isFr ? 'Transactions récentes' : 'Recent Transactions';
  String get dashInventoryAlerts => _isFr ? 'Alertes stock' : 'Inventory Alerts';
  String get dashManageInventory => _isFr ? 'Gérer' : 'Manage';
  String get dashReorderNow     => _isFr ? 'Commander' : 'Reorder';
  String get dashCriticalStock  => _isFr ? 'Critique' : 'Critical';
  String get dashLowStock       => _isFr ? 'Faible' : 'Low';
  String get dashUnitsLeft      => _isFr ? 'unités restantes' : 'units left';
  String get dashViewAll        => _isFr ? 'Tout voir' : 'View All';
  String get dashTotalSales     => _isFr ? 'Total Ventes' : 'Total Sales';
  String get dashTransactions   => _isFr ? 'Transactions' : 'Transactions';
  String get dashCustomers      => _isFr ? 'Clients' : 'Customers';
  String get dashAvgSale        => _isFr ? 'Vente moy.' : 'Avg. Sale';
  String get dashBenefit        => _isFr ? 'Bénéfices'  : 'Benefits';
  String get dashFromYesterday  => _isFr ? 'vs hier' : 'from yesterday';
  String get dashFromLastPeriod => _isFr ? 'vs période préc.' : 'from last period';
  String get dashCompleted      => _isFr ? 'Complété' : 'Completed';
  String get dashPending        => _isFr ? 'En cours' : 'Pending';
  String get dashCancelled      => _isFr ? 'Annulé' : 'Cancelled';
  String get dashFinancialSummary => _isFr ? 'Résumé financier'      : 'Financial summary';
  String get dashProductCost      => _isFr ? 'Coût des produits'     : 'Product cost';
  String get dashScrappedLoss     => _isFr ? 'Pertes rebuts'         : 'Scrap losses';
  String get dashRepairCost       => _isFr ? 'Coûts réparation'      : 'Repair costs';
  String get dashOperatingExpenses => _isFr ? 'Dépenses opérationnelles' : 'Operating expenses';
  String get dashNetProfit        => _isFr ? 'Bénéfice net'          : 'Net profit';
  String get dashNetMarginHint    => _isFr ? 'Marge nette sur le CA' : 'Net margin on revenue';
  String get dashShareAction      => _isFr ? 'Partager'           : 'Share';
  String dashVariantCount(int n)  => _isFr
      ? '$n variante${n > 1 ? 's' : ''}'
      : '$n variant${n > 1 ? 's' : ''}';
  String get dashUnknownClient    => _isFr ? 'Client anonyme'        : 'Unknown client';
  // ── Boutique (Caisse) v2 ──────────────────────────────────────────────────
  String get boutiqueOutOfStock => _isFr ? 'Rupture'                 : 'Out of stock';
  String get boutiqueLowStock   => _isFr ? 'Stock bas'               : 'Low stock';
  String get boutiqueInStock    => _isFr ? 'en stock'                : 'in stock';
  String get boutiqueSearchHint => _isFr ? 'Rechercher un produit…'  : 'Search a product…';
  String get boutiqueFilters    => _isFr ? 'Filtres'                 : 'Filters';
  String get boutiqueSort       => _isFr ? 'Trier'                   : 'Sort';
  String boutiqueCountLine(int p, int v) => _isFr
      ? '$p produit${p > 1 ? 's' : ''} · $v variante${v > 1 ? 's' : ''}'
      : '$p product${p > 1 ? 's' : ''} · $v variant${v > 1 ? 's' : ''}';
  String get boutiqueViewGrid   => _isFr ? 'Vue grille'              : 'Grid view';
  String get boutiqueViewList   => _isFr ? 'Vue liste'               : 'List view';
  // ── Shop settings v2 ──────────────────────────────────────────────────────
  String get shopSettingsTitle    => _isFr ? 'Paramètres boutique'   : 'Shop settings';
  String get shopTabOverview      => _isFr ? 'Boutique'              : 'Shop';
  String get shopTabMembers       => _isFr ? 'Membres'               : 'Members';
  String get shopTabCopy          => _isFr ? 'Copier'                : 'Copy';
  String get shopTabDanger        => _isFr ? 'Danger'                : 'Danger';
  String get shopActionShare      => _isFr ? 'Partager'              : 'Share';
  String get shopActionEdit       => _isFr ? 'Modifier'              : 'Edit';
  String get shopStatusActive     => _isFr ? 'Active'                : 'Active';
  String get shopStatusInactive   => _isFr ? 'Inactive'              : 'Inactive';
  String get shopInfoId           => _isFr ? 'Identifiant'           : 'Identifier';
  String get shopInfoCountry      => _isFr ? 'Pays'                  : 'Country';
  String get shopInfoCurrency     => _isFr ? 'Devise'                : 'Currency';
  String get shopInfoSector       => _isFr ? 'Secteur'               : 'Sector';
  String get shopInfoPhone        => _isFr ? 'Téléphone'             : 'Phone';
  String get shopInfoEmail        => _isFr ? 'Email'                 : 'Email';
  String get shopInfoStatus       => _isFr ? 'Statut'                : 'Status';
  String get shopCopied           => _isFr ? 'Copié !'               : 'Copied!';
  String get shopStatusConfirmTitle => _isFr
      ? 'Modifier le statut ?' : 'Change status?';
  String shopStatusConfirmBody(bool activating) => _isFr
      ? (activating
          ? 'La boutique redeviendra active : ventes, produits et membres seront accessibles.'
          : 'La boutique sera désactivée : les ventes seront suspendues. Tu pourras la réactiver à tout moment.')
      : (activating
          ? 'The shop will become active again: sales, products and members will be accessible.'
          : 'The shop will be deactivated: sales will be suspended. You can reactivate it anytime.');
  String get shopStatusDescActive   => _isFr
      ? 'Boutique opérationnelle' : 'Shop is operational';
  String get shopStatusDescInactive => _isFr
      ? 'Boutique désactivée'     : 'Shop is disabled';
  String get shopShareSubject     => _isFr ? 'Info boutique'         : 'Shop info';
  String shopMembersCount(int n)  => _isFr
      ? '$n membre${n > 1 ? 's' : ''}'
      : '$n member${n > 1 ? 's' : ''}';
  String get shopMembersSubtitle  => _isFr
      ? 'Gérez les accès et les rôles' : 'Manage access and roles';
  String get shopMembersInvite    => _isFr ? 'Inviter'               : 'Invite';
  String get shopRolesTitle       => _isFr ? 'Rôles disponibles'     : 'Available roles';
  String get shopRoleAdminDesc    => _isFr ? 'Accès complet'
      : 'Full access';
  String get shopRoleManagerDesc  => _isFr ? 'Gestion stock et produits'
      : 'Stock and product management';
  String get shopRoleCashierDesc  => _isFr ? 'Ventes uniquement'
      : 'Sales only';
  String get shopRoleViewerDesc   => _isFr ? 'Lecture seule'
      : 'Read-only';
  String get shopEmptyMembersTitle => _isFr ? 'Aucun membre pour l\'instant'
      : 'No members yet';
  String get shopEmptyMembersSubtitle => _isFr
      ? 'Invitez votre équipe pour qu\'elle puisse travailler dans cette boutique.'
      : 'Invite your team to start working in this shop.';
  String get shopEmptyMembersCta  => _isFr ? 'Inviter le premier membre'
      : 'Invite the first member';
  // ── Onglet Copier ──
  String get shopCopyTitle        => _isFr ? 'Copier des produits'
      : 'Copy products';
  String get shopCopySubtitle     => _isFr
      ? 'Dupliquer un produit vers une autre boutique de votre compte'
      : 'Duplicate a product to another shop of your account';
  String get shopCopyCardTitle    => _isFr ? 'Copier un produit'
      : 'Copy a product';
  String get shopCopyCardSubtitle => _isFr
      ? 'Choisissez un produit et une boutique de destination'
      : 'Choose a product and a destination shop';
  String get shopCopyInfo         => _isFr
      ? 'Le produit copié aura un nouvel identifiant. SKU et code-barres seront réinitialisés pour éviter les doublons.'
      : 'The copied product gets a new identifier. SKU and barcode are reset to avoid duplicates.';
  String get shopCopyDialogTitle  => _isFr ? 'Copier un produit'
      : 'Copy a product';
  String get shopCopyFieldProduct => _isFr ? 'Produit à copier'
      : 'Product to copy';
  String get shopCopyFieldShop    => _isFr ? 'Boutique de destination'
      : 'Destination shop';
  String get shopCopyPickProduct  => _isFr ? 'Choisir un produit'
      : 'Pick a product';
  String get shopCopyPickShop     => _isFr ? 'Choisir une boutique'
      : 'Pick a shop';
  String get shopCopyAction       => _isFr ? 'Copier'  : 'Copy';
  String get shopCopyNoOtherShop  => _isFr
      ? 'Pas d\'autre boutique disponible' : 'No other shop available';
  String get shopCopyNoProduct    => _isFr ? 'Aucun produit à copier'
      : 'No product to copy';
  String shopCopyDone(String shopName) => _isFr
      ? 'Copié vers $shopName' : 'Copied to $shopName';
  // ── Onglet Danger ─────────────────────────────────────────────────────────
  String get shopDangerHeaderTitle    => _isFr ? 'Zone de danger'
      : 'Danger zone';
  String get shopDangerHeaderSubtitle => _isFr
      ? 'Ces actions sont irréversibles. Soyez certain avant de continuer.'
      : 'These actions are irreversible. Make sure before continuing.';
  String get shopDangerOwnerOnly      => _isFr
      ? 'Zone réservée au propriétaire' : 'Owner-only area';
  String get shopDangerOwnerOnlyHint  => _isFr
      ? 'Seul le propriétaire de la boutique peut accéder à ces actions.'
      : 'Only the shop owner can access these actions.';
  // Reset
  String get shopResetTitle           => _isFr ? 'Réinitialiser la boutique'
      : 'Reset the shop';
  String get shopResetDescription     => _isFr
      ? 'Remet la boutique à zéro en gardant votre compte et la boutique elle-même.'
      : 'Resets the shop while keeping your account and the shop itself.';
  String get shopResetConseqSales     => _isFr
      ? 'Ventes et transactions supprimées' : 'Sales and transactions deleted';
  String get shopResetConseqProducts  => _isFr
      ? 'Produits et catégories supprimés' : 'Products and categories deleted';
  String get shopResetConseqClients   => _isFr
      ? 'Clients supprimés' : 'Clients deleted';
  String get shopResetConseqKeep      => _isFr
      ? 'Boutique et compte conservés' : 'Shop and account kept';
  String get shopResetAction          => _isFr ? 'Réinitialiser'  : 'Reset';
  String get shopResetDialogTitle     => _isFr ? 'Réinitialiser la boutique ?'
      : 'Reset the shop?';
  String shopResetDialogBody(String name) => _isFr
      ? 'Ventes, produits, clients et catégories de $name seront supprimés. Cette action ne peut pas être annulée.'
      : 'Sales, products, clients and categories of $name will be deleted. This cannot be undone.';
  String get shopResetDone            => _isFr ? 'Boutique réinitialisée'
      : 'Shop reset';
  // Delete
  String get shopDeleteTitle          => _isFr ? 'Supprimer cette boutique'
      : 'Delete this shop';
  String get shopDeleteDescription    => _isFr
      ? 'Suppression permanente et irréversible de la boutique et de toutes ses données.'
      : 'Permanent and irreversible deletion of the shop and all its data.';
  String get shopDeleteConseqAll      => _isFr
      ? 'Toutes les données supprimées définitivement'
      : 'All data permanently deleted';
  String get shopDeleteConseqNoRecover => _isFr
      ? 'Impossible de récupérer les données'
      : 'Data cannot be recovered';
  String get shopDeleteConseqAccount  => _isFr
      ? 'Votre compte reste actif' : 'Your account stays active';
  String get shopDeleteAction         => _isFr ? 'Supprimer'    : 'Delete';
  String get shopDeleteDialogTitle    => _isFr ? 'Supprimer la boutique ?'
      : 'Delete the shop?';
  String shopDeleteTypeName(String name) => _isFr
      ? 'Tapez le nom exact de la boutique pour confirmer : $name'
      : 'Type the exact shop name to confirm: $name';
  String get shopDeleteTypeHint       => _isFr ? 'Nom de la boutique'
      : 'Shop name';
  String get shopDeleteActionFinal    => _isFr ? 'Supprimer définitivement'
      : 'Delete permanently';
  // ── Éditeur de prix (panier) ──────────────────────────────────────────────
  String get priceEditTitle       => _isFr ? 'Modifier le prix de vente'
      : 'Edit selling price';
  String get priceEditSubtitle    => _isFr ? 'Pour cette vente uniquement'
      : 'For this sale only';
  String get priceEditOriginal    => _isFr ? 'Prix original'         : 'Original price';
  String get priceEditCost        => _isFr ? 'Prix de revient'       : 'Cost price';
  String get priceEditCostUnknown => _isFr ? 'Prix de revient non défini'
      : 'Cost price not set';
  String get priceEditMargin      => _isFr ? 'Marge'                 : 'Margin';
  String get priceEditMinPrice    => _isFr ? 'Prix minimum (30%)'    : 'Minimum price (30%)';
  String priceEditMarginOk(double pct)    => _isFr
      ? 'Marge : +${pct.toStringAsFixed(0)}% — bénéfice sain'
      : 'Margin: +${pct.toStringAsFixed(0)}% — healthy profit';
  String priceEditMarginLow(double pct)   => _isFr
      ? '⚠ Marge de ${pct.toStringAsFixed(0)}% inférieure à 30% — êtes-vous sûr ?'
      : '⚠ Margin of ${pct.toStringAsFixed(0)}% below 30% — are you sure?';
  String get priceEditBelowCost   => _isFr
      ? '✗ Prix inférieur au prix de revient — impossible'
      : '✗ Price below cost — not allowed';
  String get priceEditReset       => _isFr ? 'Réinitialiser'         : 'Reset';
  String get priceEditApply       => _isFr ? 'Appliquer'             : 'Apply';
  String get priceEditConfirmTitle => _isFr ? 'Marge inférieure à 30%'
      : 'Margin below 30%';
  String get priceEditConfirmBody => _isFr
      ? 'Marge inférieure à 30% pour cet article.'
      : 'Margin below 30% for this item.';
  String get priceEditConfirmKeep => _isFr ? 'Confirmer quand même'
      : 'Confirm anyway';

  // ── Inventaire v2 ──────────────────────────────────────────────────────────
  String get invAllProducts     => _isFr ? 'Tous les produits' : 'All Product List';
  String get invProductStats    => _isFr ? 'Statistiques produits' : 'Product Statistic';
  String get invActiveProducts  => _isFr ? 'Produits actifs' : 'Active Products';
  String get invWinningProduct  => _isFr ? 'Meilleur produit' : 'Winning Product';
  String get invAvgPerformance  => _isFr ? 'Performance moy.' : 'Average Performance';
  String get invProductsSold    => _isFr ? 'Produits vendus' : 'Product Sold';
  String get invProductsReturned => _isFr ? 'Retours' : 'Product Returned';
  String get invSortBy          => _isFr ? 'Trier par' : 'Sort by';
  String get invShowAll         => _isFr ? 'Tout afficher' : 'Show All';
  String get invNewProduct      => _isFr ? '+ Nouveau produit' : '+ New Product';
  String get invPerformance     => _isFr ? 'Performance' : 'Performance';
  String get invStock           => _isFr ? 'Stock' : 'Stock';
  String get invPriceLabel      => _isFr ? 'Prix vente' : 'Product Price';
  String get invVisibility      => _isFr ? 'Visibilité' : 'Visibility';
  String get invReview          => _isFr ? 'Avis' : 'Review';
  String get invItems           => _isFr ? 'articles' : 'items';
  String get invPrevPage        => _isFr ? 'Précédent' : 'Previous';
  String get invNextPage         => _isFr ? 'Suivant'           : 'Next';
  String get invPerPage          => _isFr ? 'Par page'          : 'Per page';
  String get invFilterBy         => _isFr ? 'Filtrer'           : 'Filter';
  String get invSortByLabel      => _isFr ? 'Trier par'         : 'Sort by';
  String get invDeleteConfirm    => _isFr ? 'Supprimer ce produit ?' : 'Delete this product?';
  String get invDeleteWarning    => _isFr ? 'Cette action est irréversible.' : 'This action cannot be undone.';
  String get invDeleteBtn        => _isFr ? 'Supprimer'         : 'Delete';
  String get invCancel           => _isFr ? 'Annuler'           : 'Cancel';
  String get invShowDetails      => _isFr ? 'Voir détails'      : 'Show details';
  String get invHideDetails      => _isFr ? 'Masquer'           : 'Hide';
  String get invFilterActive     => _isFr ? 'Actifs'            : 'Active';
  String get invFilterAll        => _isFr ? 'Tous'              : 'All';
  String get invFilterInactive   => _isFr ? 'Inactifs'          : 'Inactive';
  String get invFilterLowStock   => _isFr ? 'Stock faible'      : 'Low stock';
  String get invFilterNoPrice    => _isFr ? 'Sans prix'         : 'No price';

  // ── Inventaire — textes supplémentaires ────────────────────────────────────
  String get invNoResult        => _isFr ? 'Aucun produit trouvé' : 'No product found';
  String get invNoResultHint    => _isFr ? 'Essayez un autre filtre ou terme de recherche' : 'Try a different filter or search term';
  String get invAddProduct      => _isFr ? 'Ajouter un produit'   : 'Add a product';
  String get invTotalLabel      => _isFr ? 'Produits'             : 'Products';
  String get invActiveLabel     => _isFr ? 'Actifs'               : 'Active';
  String get invLowStockLabel   => _isFr ? 'Stock bas'            : 'Low stock';
  String get invInactiveLabel   => _isFr ? 'Inactifs'             : 'Inactive';
  String get invAvailableLabel  => _isFr ? 'Disponible'           : 'Available';
  String get invBlockedLabel    => _isFr ? 'Bloqué'               : 'Blocked';
  String get invActionOrders      => _isFr ? 'Commandes'         : 'Orders';
  String get invActionReceptions  => _isFr ? 'Réceptions'        : 'Receptions';
  String get invActionMovements   => _isFr ? 'Mouvements'        : 'Movements';
  String get invActionIncidents   => _isFr ? 'Incidents'         : 'Incidents';
  String get invActionReturns     => _isFr ? 'Retours'           : 'Returns';
  String get invActionSelect      => _isFr ? 'Sélectionner'      : 'Select';
  String get invActionCancelSelect => _isFr ? 'Annuler sélection': 'Cancel selection';
  String get invActionNewProduct  => _isFr ? 'Nouveau produit'   : 'New product';
  String get invTableVariant    => _isFr ? 'Variante'            : 'Variant';
  String get invTableSellPrice  => _isFr ? 'Prix vente'          : 'Sell price';
  String get invTableBuyPrice   => _isFr ? 'Prix achat'          : 'Buy price';
  String get invTableMargin     => _isFr ? 'Marge'               : 'Margin';
  String get invTableActions    => _isFr ? 'Actions'             : 'Actions';
  String get invAddVariant      => _isFr ? 'Ajouter une variante': 'Add variant';
  String get invActionAddStock  => _isFr ? 'Arrivée stock'       : 'Add stock';
  String get invActionShareVariant => _isFr ? 'Partager WhatsApp': 'Share on WhatsApp';
  String get invEdit            => _isFr ? 'Modifier'            : 'Edit';
  String get invActionSetMain   => _isFr ? 'Mettre en avant'     : 'Set as main';
  String get invActionMainActive => _isFr ? 'Variante principale': 'Main variant';
  String get invChipAll         => _isFr ? 'Tous'                 : 'All';
  String get invChipLowStock    => _isFr ? 'Stock bas'            : 'Low stock';
  String get invChipNoPrice     => _isFr ? 'Sans prix'            : 'No price';
  String get invCategoryLabel   => _isFr ? 'Catégorie'            : 'Category';
  String get invBrandLabel      => _isFr ? 'Marque'               : 'Brand';
  String get invApply           => _isFr ? 'Appliquer'            : 'Apply';
  String get invVariantsLabel   => _isFr ? 'Variantes'            : 'Variants';
  String get invStockLabel      => _isFr ? 'Stock'                : 'Stock';
  String get invPurchaseLabel   => _isFr ? 'Achat'                : 'Purchase';
  String get invMarginLabel     => _isFr ? 'Marge'                : 'Margin';
  String get invActiveInCaisse  => _isFr ? 'Actif en caisse'      : 'Active in POS';
  String get invVisibleWeb      => _isFr ? 'Visible web'          : 'Visible online';
  String get invSearchHint      => _isFr ? 'Chercher un produit, SKU…' : 'Search product, SKU…';
  String get invSortLabel       => _isFr ? 'Trier'                : 'Sort';
  String get invAddBtn          => _isFr ? '+ Produit'            : '+ Product';
  String get invDeleteTitle     => _isFr ? 'Supprimer'            : 'Delete';

  // ── Formulaire produit — calculs ───────────────────────────────────────────
  String get prodBenefit        => _isFr ? 'Bénéfice'             : 'Profit';
  String get prodEffectiveCost  => _isFr ? 'Prix de revient'      : 'Effective cost';
  String get prodExpensePerUnit => _isFr ? 'Dépense/unité'        : 'Expense/unit';
  String get prodTotalExpenses  => _isFr ? 'Total dépenses'       : 'Total expenses';
  String get prodMarginPOS      => _isFr ? 'Marge POS'            : 'POS margin';
  String get prodVariantBenefit => _isFr ? 'Bénéfice variante'    : 'Variant profit';
  String get invSortName         => _isFr ? 'Nom'               : 'Name';
  String get invSortStock        => _isFr ? 'Stock'             : 'Stock';
  String get invSortPrice        => _isFr ? 'Prix'              : 'Price';
  String get invSortPerf         => _isFr ? 'Performance'       : 'Performance';
  String get invSortSales        => _isFr ? 'Ventes'            : 'Sales';

  // ── Produit — variantes et dépenses ───────────────────────────────────────
  String get prodVariants       => _isFr ? 'Variantes'          : 'Variants';
  String get prodAddVariant     => _isFr ? 'Ajouter une variante' : 'Add variant';
  String get prodVariantName    => _isFr ? 'Nom de la variante' : 'Variant name';
  String get prodPurchasePrice  => _isFr ? 'Prix d\'achat'     : 'Purchase price';
  String get prodSalePrice      => _isFr ? 'Prix de vente'      : 'Sale price';
  String get prodVariantStock   => _isFr ? 'Stock variante'     : 'Variant stock';
  String get prodExpenses       => _isFr ? 'Dépenses liées'     : 'Related expenses';
  String get prodAddExpense     => _isFr ? 'Ajouter une dépense' : 'Add expense';
  String get prodExpenseName    => _isFr ? 'Description'        : 'Description';
  String get prodExpenseAmount  => _isFr ? 'Montant (XAF)'      : 'Amount';
  String get prodExpenseHint    => _isFr ? 'Ex: Transport, emballage...' : 'e.g. Transport, packaging...';
  String get prodPurchasePriceAuto => _isFr ? 'Prix d\'achat (calculé auto)' : 'Purchase price (auto-calculated)';
  String get prodPerUnit          => _isFr ? 'par unité'              : 'per unit';
  String get prodSku              => _isFr ? 'SKU (référence interne)' : 'SKU (internal ref)';
  String get prodSkuHint          => _isFr ? 'Ex: PROD-001'            : 'e.g. PROD-001';
  String get prodBrand            => _isFr ? 'Marque'                  : 'Brand';
  String get prodAddBrand     => _isFr ? 'Ajouter une marque'     : 'Add brand';
  String get prodCategoryHint => _isFr ? 'Ex: Boissons, Électronique…' : 'e.g. Beverages…';
  String get prodAddUnit      => _isFr ? 'Ajouter une unité'       : 'Add unit';
  String get prodUnitHint     => _isFr ? 'Ex: Kg, Litre, Carton…'  : 'e.g. Kg, Litre…';
  String get prodBrandHint        => _isFr ? 'Ex: Samsung, Nike...'    : 'e.g. Samsung, Nike...';
  String get prodCustomsFee       => _isFr ? 'Frais de douane'         : 'Customs fee';
  String get prodPriceSellWeb     => _isFr ? 'Prix vente (web)'        : 'Web sale price';
  String get prodTaxRate          => _isFr ? 'Taux TVA (%)'            : 'Tax rate (%)';
  String get prodStockMinAlert    => _isFr ? 'Alerte stock min.'       : 'Min stock alert';
  String get prodIsActive         => _isFr ? 'Produit actif'           : 'Active product';
  String get prodIsVisibleWeb     => _isFr ? 'Visible sur le web'      : 'Visible on web';
  String get prodRating           => _isFr ? 'Note (0–5)'              : 'Rating (0–5)';
  String get prodPricing          => _isFr ? 'Tarification'            : 'Pricing';
  String get prodStockInfo        => _isFr ? 'Stock & alertes'         : 'Stock & alerts';
  String get prodVisibility       => _isFr ? 'Visibilité & statut'     : 'Visibility & status';
  String get prodGeneralInfo      => _isFr ? 'Informations générales'  : 'General information';
  String get prodAddCategory      => _isFr ? 'Ajouter une catégorie' : 'Add category';
  String get prodNewCategoryHint  => _isFr ? 'Nom de la catégorie'  : 'Category name';
  String get prodStockAlertMin    => _isFr ? 'Alerte stock (min)'   : 'Stock alert (min)';
  String get prodVariantImg       => _isFr ? 'Image variante'       : 'Variant image';
  String get prodChooseFile       => _isFr ? 'Choisir un fichier'   : 'Choose file';
  String get prodStepValidError   => _isFr ? 'Remplissez les champs obligatoires (*)' : 'Fill required fields (*)';
  String get prodIdentification   => _isFr ? 'Identification'            : 'Identification';
  String get prodMedia            => _isFr ? 'Médias & images'            : 'Media & images';
  String get prodAddImage         => _isFr ? 'Ajouter une image'          : 'Add image';
  String get prodImageUrl         => _isFr ? 'URL de l\'image'           : 'Image URL';
  String get prodImageUrlHint     => _isFr ? 'https://...'                : 'https://...';
  String get prodWeightDims       => _isFr ? 'Poids & dimensions'         : 'Weight & dimensions';
  String get prodWeight           => _isFr ? 'Poids (g)'                  : 'Weight (g)';
  String get prodLength           => _isFr ? 'Longueur (cm)'              : 'Length (cm)';
  String get prodWidth            => _isFr ? 'Largeur (cm)'               : 'Width (cm)';
  String get prodHeight           => _isFr ? 'Hauteur (cm)'               : 'Height (cm)';
  String get prodSupplier         => _isFr ? 'Fournisseur'                : 'Supplier';
  String get prodSupplierHint     => _isFr ? 'Nom du fournisseur'         : 'Supplier name';
  String get prodSupplierRef      => _isFr ? 'Réf. fournisseur'           : 'Supplier ref.';
  String get prodLeadTime         => _isFr ? 'Délai réappro. (j)'         : 'Lead time (days)';
  String get prodNotes            => _isFr ? 'Notes internes'             : 'Internal notes';
  String get prodNotesHint        => _isFr ? 'Visible uniquement par l\'équipe' : 'Visible only to your team';
  String get prodPromoPrice       => _isFr ? 'Prix promotionnel'          : 'Promotional price';
  String get prodPromoStart       => _isFr ? 'Début promo'                : 'Promo start';
  String get prodPromoEnd         => _isFr ? 'Fin promo'                  : 'Promo end';
  String get prodPriceHistory     => _isFr ? 'Promotion'                  : 'Promotion';
  String get prodUnitType         => _isFr ? 'Unité de mesure'            : 'Unit type';
  String get prodMinOrderQty      => _isFr ? 'Qté min. commande'          : 'Min order qty';
  String get prodSectionSummary   => _isFr ? 'Récapitulatif'              : 'Summary';
  String get prodStep             => _isFr ? 'Étape'                      : 'Step';
  String get prodOf               => _isFr ? 'sur'                        : 'of';
  String get prodNext             => _isFr ? 'Suivant'                    : 'Next';
  String get prodPrev             => _isFr ? 'Précédent'                  : 'Previous';
  String get prodCategory       => _isFr ? 'Catégorie' : 'Category';
  String get prodBarcode        => _isFr ? 'Code-barres' : 'Barcode';
  String get prodDescription    => _isFr ? 'Description' : 'Description';
  String get errorGeneric  => _isFr ? 'Une erreur est survenue' : 'An error occurred';
  // ── Shop selector ────────────────────────────────────────────────────────
  String get shopActive          => _isFr ? 'Actif'                     : 'Active';
  String get shopCreatedSuccess  => _isFr ? 'créée avec succès !'       : 'created successfully!';
  String get shopNew             => _isFr ? 'Nouvelle boutique'          : 'New shop';
  String get shopToday           => _isFr ? "Aujourd'hui"               : 'Today';
  String get shopMyShops         => _isFr ? 'Mes boutiques'              : 'My shops';
  String get shopCreate          => _isFr ? 'Créer une boutique'         : 'Create a shop';
  String get shopNoShop          => _isFr ? 'Aucune boutique'            : 'No shop yet';
  String get shopNoShopHint      => _isFr ? 'Créez votre première boutique' : 'Create your first shop';
  String get shopName            => _isFr ? 'Nom de la boutique'         : 'Shop name';
  String get shopSector          => _isFr ? 'Secteur d\'activité'       : 'Business sector';
  String get shopCurrency        => _isFr ? 'Devise'                     : 'Currency';
  String get shopCountry         => _isFr ? 'Pays'                       : 'Country';
  String get shopPhone           => _isFr ? 'Téléphone boutique'         : 'Shop phone';
  String get shopEmail           => _isFr ? 'Email boutique'             : 'Shop email';
  String get shopOwner           => _isFr ? 'Propriétaire'               : 'Owner';
  String get shopSelectCountry   => _isFr ? 'Sélectionner un pays'       : 'Select a country';

  // ── Paramètres ────────────────────────────────────────────────────────────
  String get paramDangerZone         => _isFr ? 'Zone dangereuse'                     : 'Danger zone';
  String get paramEndSession         => _isFr ? 'Terminer la session en cours'         : 'End current session';
  String get paramReset              => _isFr ? 'Réinitialiser l\'application'        : 'Reset application';
  String get paramResetHint          => _isFr ? 'Efface tous les comptes, boutiques et produits' : 'Erases all accounts, shops and products';
  String get paramResetConfirmTitle  => _isFr ? 'Réinitialiser ?'                      : 'Reset?';
  String get paramResetConfirmBody   => _isFr ? 'Toutes les données locales seront effacées. Cette action est irréversible.' : 'All local data will be erased. This action cannot be undone.';
  String get paramResetConfirmBtn    => _isFr ? 'Réinitialiser'                        : 'Reset';
  String get paramResetDone          => _isFr ? 'Données effacées — redémarrez l\'app' : 'Data erased — restart the app';
  String get paramLogoutConfirm      => _isFr ? 'Se déconnecter ?'                     : 'Sign out?';

  // ── Caisse ────────────────────────────────────────────────────────────────
  String get caisseCartTitle     => _isFr ? 'Panier'                    : 'Cart';
  String get caisseCartCount     => _isFr ? 'articles'                  : 'items';
  String get caisseClear         => _isFr ? 'Vider'                     : 'Clear';
  String get caisseEmpty         => _isFr ? 'Panier vide'               : 'Cart is empty';
  String get caisseSubtotal      => _isFr ? 'Sous-total'                : 'Subtotal';
  String get caisseDiscount      => _isFr ? 'Remise'                    : 'Discount';
  String get caissePay           => _isFr ? 'Encaisser'                 : 'Checkout';
  String get caissePayAmount     => _isFr ? 'Montant à encaisser'       : 'Amount to collect';

  // ── CRM ───────────────────────────────────────────────────────────────────
  String get crmClientDetail     => _isFr ? 'Détail client'             : 'Customer detail';
  String get crmVisitsLabel      => _isFr ? 'visites'                   : 'visits';
  String get crmClientId         => _isFr ? 'Client'                    : 'Customer';

  // ── Super Admin ───────────────────────────────────────────────────────────
  String get adminDashboard      => _isFr ? 'Dashboard admin'           : 'Admin dashboard';
  String get adminAllShops       => _isFr ? 'Toutes les boutiques'      : 'All shops';
  String get adminUsers          => _isFr ? 'Utilisateurs'              : 'Users';
  String get adminStats          => _isFr ? 'Statistiques globales'     : 'Global statistics';
  String get adminSuspend        => _isFr ? 'Suspendre'                 : 'Suspend';
  String get adminActivate       => _isFr ? 'Activer'                   : 'Activate';

  // ── Boutique en ligne ─────────────────────────────────────────────────────
  String get webShopEnable       => _isFr ? 'Activer la boutique en ligne' : 'Enable online shop';
  String get webShopSlug         => _isFr ? 'URL de la boutique'        : 'Shop URL';
  String get webShopBanner       => _isFr ? 'Image bannière'            : 'Banner image';
  String get webShopTheme        => _isFr ? 'Thème'                     : 'Theme';
  String get webShopOrders       => _isFr ? 'Commandes en ligne'        : 'Online orders';
  String get webShopPublish      => _isFr ? 'Publier'                   : 'Publish';
  String get webShopPreview      => _isFr ? 'Aperçu'                    : 'Preview';

  // ── Erreurs génériques ────────────────────────────────────────────────────
  String get errNetwork          => _isFr ? 'Pas de connexion internet'  : 'No internet connection';
  String get errTimeout          => _isFr ? 'Délai dépassé. Réessayez.' : 'Timeout. Please try again.';
  String get errUnknown          => _isFr ? 'Erreur inattendue'          : 'Unexpected error';
  String get errRequired         => _isFr ? 'Ce champ est requis'        : 'This field is required';

  // ── Commun supplémentaire ─────────────────────────────────────────────────
  String get yes                 => _isFr ? 'Oui'                       : 'Yes';
  String get no                  => _isFr ? 'Non'                       : 'No';
  String get edit                => _isFr ? 'Modifier'                  : 'Edit';
  String get delete              => _isFr ? 'Supprimer'                 : 'Delete';
  String get confirm             => _isFr ? 'Confirmer'                 : 'Confirm';
  String get back                => _isFr ? 'Retour'                    : 'Back';
  String get next                => _isFr ? 'Suivant'                   : 'Next';
  String get done                => _isFr ? 'Terminer'                  : 'Done';
  String get retry               => _isFr ? 'Réessayer'                 : 'Retry';
  String get close               => _isFr ? 'Fermer'                    : 'Close';
  String get add                 => _isFr ? 'Ajouter'                   : 'Add';
  String get apply               => _isFr ? 'Appliquer'                 : 'Apply';
  String get clear               => _isFr ? 'Effacer'                   : 'Clear';
  String get or_                 => _isFr ? 'ou'                        : 'or';
  String get active              => _isFr ? 'Actif'                     : 'Active';
  String get inactive            => _isFr ? 'Inactif'                   : 'Inactive';
  String get enabled             => _isFr ? 'Activé'                    : 'Enabled';
  String get disabled            => _isFr ? 'Désactivé'                 : 'Disabled';
  String get optional            => _isFr ? '(optionnel)'               : '(optional)';
  String get required_           => _isFr ? '(requis)'                  : '(required)';
  String get xafCurrency         => 'XAF';
  // ── Produit — hints toggle ────────────────────────────────────────────────
  String get caisseActiveHint    => _isFr ? 'Apparaît en caisse'           : 'Appears in POS';


  // ── Produit — nouvelles clés variante fusionnée ──────────────────────────
  String get prodIdentificationVariants => _isFr ? 'Identification & variantes' : 'Identification & variants';
  String get prodVariantBaseHint  => _isFr ? 'La 1ère variante est le produit de base avec son propre SKU et image.' : 'The 1st variant is the base product with its own SKU and image.';
  String get prodBaseVariant      => _isFr ? 'Base'                     : 'Base';
  String get prodBaseVariantHint  => _isFr ? 'Nom du produit de base'   : 'Base product name';
  String get prodSetMain          => _isFr ? 'Mettre en avant'          : 'Set as main';
  String get prodMainImage        => _isFr ? 'Image principale'         : 'Main image';
  String get prodMainImageHint    => _isFr ? 'Appuyez sur une variante pour la définir comme image principale (★).' : 'Tap a variant to set it as the main image (★).';
  // ── Produit — états image ─────────────────────────────────────────────────
  String get prodImageSelected => _isFr ? 'Image sélectionnée'         : 'Image selected';
  String get prodImageOnline   => _isFr ? 'Image en ligne'             : 'Online image';
  String get prodImageNone     => _isFr ? 'Aucune image sélectionnée'  : 'No image selected';
  String get webShopVisibleHint  => _isFr ? 'Visible en boutique en ligne' : 'Visible in online shop';



  // ── Sync / Offline ────────────────────────────────────────────────────────
  String offlinePendingOps(int n) => _isFr
      ? '$n opération(s) en attente de synchronisation'
      : '$n operation(s) pending sync';
  String syncPendingAlert(int n) => _isFr
      ? '$n modification(s) non synchronisée(s) avec le cloud'
      : '$n unsynchronized change(s)';
  String get syncNow    => _isFr ? 'Synchroniser' : 'Sync now';
  String get syncDone   => _isFr ? 'Synchronisation terminée' : 'Sync complete';
  String get logoutSyncTitle => _isFr
      ? 'Modifications non synchronisées'
      : 'Unsynchronized changes';
  String logoutSyncDescription(int n) => _isFr
      ? 'Vous avez $n modification(s) locale(s) non encore envoyée(s) au cloud.\nSynchronisez avant de vous déconnecter pour que ces données soient visibles sur tous vos appareils.'
      : 'You have $n local change(s) not yet uploaded to the cloud.\nSync before signing out so they appear on all your devices.';
  String get logoutSyncBtn  => _isFr
      ? 'Synchroniser et se déconnecter'
      : 'Sync & sign out';
  String get logoutAnyway   => _isFr
      ? 'Se déconnecter sans synchroniser'
      : 'Sign out without syncing';
  String get syncPendingTitle => _isFr ? 'Synchronisation en attente' : 'Sync pending';
  String get syncInProgress   => _isFr ? 'Synchronisation…' : 'Syncing…';
  String get offlineDescription => _isFr
      ? 'Vous êtes hors ligne. Vos modifications sont sauvegardées localement et seront synchronisées à la reconnexion.'
      : 'You are offline. Your changes are saved locally and will be synced when you reconnect.';
  String syncPendingDescription(int count) => _isFr
      ? '$count modification(s) en attente d\'envoi vers le serveur.'
      : '$count local change(s) pending upload to server.';
  String get syncFailed => _isFr ? 'Synchronisation échouée' : 'Sync failed';
  String get onlineRequiredForRegister => _isFr
      ? 'Connexion internet requise pour créer un compte'
      : 'Internet connection required to create an account';

  String get createFirst   => _isFr ? 'Créer maintenant'        : 'Create now';
  String get emptyStateBtn => _isFr ? 'Commencer'               : 'Get started';

  // ══ Paramètres — sous-titres & libellés complémentaires ═════════════════════
  String get paramBoutiqueSubtitle   => _isFr ? 'Nom, adresse, devise…'        : 'Name, address, currency…';
  String get paramCaisseSubtitle     => _isFr ? 'Reçus, taxes, raccourcis'      : 'Receipts, taxes, shortcuts';
  String get paramEmployesSubtitle   => _isFr ? 'Rôles et accès'                : 'Roles and access';
  String get paramLanguageSubtitle   => _isFr ? 'Français / English'            : 'French / English';
  String get paramCurrencySubtitle   => _isFr ? 'XAF, EUR, USD…'                : 'XAF, EUR, USD…';
  String get paramNotifsSubtitle     => _isFr ? 'Alertes stock, ventes'         : 'Stock & sales alerts';
  String get paramWhatsAppSubtitle   => _isFr ? 'Notifications & promotions'    : 'Notifications & promotions';
  String get paramPaymentsSubtitle   => _isFr ? 'Mobile Money, carte…'          : 'Mobile Money, card…';
  String get paramProfileSubtitle    => _isFr ? 'Vos informations personnelles' : 'Your personal information';
  String get paramReadOnly           => _isFr ? 'Informations (lecture seule)'  : 'Information (read-only)';
  String get paramTheme              => _isFr ? 'Thème'                         : 'Theme';
  String get paramThemeHint          => _isFr ? 'Choisissez une palette de couleurs pour personnaliser votre application.' : 'Choose a color palette to customize your app.';
  String get paramThemeSubtitle      => _isFr ? 'Palettes modernes'              : 'Modern palettes';

  // Rôles
  String get roleSuperAdmin => _isFr ? 'Super Admin' : 'Super Admin';
  String get roleAdmin      => _isFr ? 'Admin'       : 'Admin';
  String get roleEmployee   => _isFr ? 'Employé'     : 'Employee';

  // Verrouillage / permissions
  String get permissionDenied        => _isFr ? 'Accès non autorisé'                                                  : 'Access denied';
  String get permissionDeniedDetails => _isFr ? 'Contactez l\'administrateur de la boutique pour obtenir les droits.' : 'Contact the shop administrator to request access.';
  String get lockedBadge             => _isFr ? 'Verrouillé'                                                           : 'Locked';

  // Section Administration (super admin)
  String get paramAdminSection    => _isFr ? 'Administration'                             : 'Administration';
  String get paramAdminManageUsers => _isFr ? 'Gérer les utilisateurs'                    : 'Manage users';
  String get paramAdminManageHint  => _isFr ? 'Abonnements, blocages, statistiques'       : 'Subscriptions, blocks, statistics';

  // Suppression de compte
  String get deleteAccount       => _isFr ? 'Supprimer mon compte'                : 'Delete my account';
  String get deleteAccountHint   => _isFr ? 'Suppression définitive de vos données' : 'Permanent deletion of your data';

  // ══ Page Configuration caisse ═══════════════════════════════════════════════
  String get caisseConfigTitle    => _isFr ? 'Configuration caisse'              : 'Checkout configuration';
  String get caisseReceipt        => _isFr ? 'Reçu de vente'                     : 'Sales receipt';
  String get caisseReceiptHeader  => _isFr ? 'En-tête du reçu'                   : 'Receipt header';
  String get caisseReceiptFooter  => _isFr ? 'Pied du reçu'                      : 'Receipt footer';
  String get caisseAutoPrint      => _isFr ? 'Impression automatique'            : 'Auto-print';
  String get caisseAutoPrintHint  => _isFr ? 'Imprimer automatiquement après validation' : 'Print automatically after validation';
  String get caisseTaxes          => _isFr ? 'Taxes'                              : 'Taxes';
  String get caisseTaxEnabled     => _isFr ? 'Appliquer la TVA'                   : 'Apply VAT';
  String get caisseTaxRate        => _isFr ? 'Taux de TVA (%)'                    : 'VAT rate (%)';
  String get caisseOrderNumber    => _isFr ? 'Numérotation des commandes'         : 'Order numbering';
  String get caisseOrderPrefix    => _isFr ? 'Préfixe des commandes'              : 'Order prefix';
  String get caisseShortcuts      => _isFr ? 'Raccourcis caisse'                  : 'Checkout shortcuts';
  String get caisseQuickSale      => _isFr ? 'Vente rapide (sans client)'         : 'Quick sale (no customer)';
  String get caisseConfirmDelete  => _isFr ? 'Confirmer la suppression d\'article' : 'Confirm item deletion';

  // ══ Page Notifications ══════════════════════════════════════════════════════
  String get notifsTitle          => _isFr ? 'Notifications'                     : 'Notifications';
  String get notifsSubtitle       => _isFr ? 'Choisissez ce dont vous voulez être informé' : 'Choose what you want to be notified about';
  String get notifsStockLow       => _isFr ? 'Stock faible'                      : 'Low stock';
  String get notifsStockLowHint   => _isFr ? 'Alerte quand un produit descend sous le seuil' : 'Alert when a product falls below threshold';
  String get notifsNewSale        => _isFr ? 'Nouvelle vente'                    : 'New sale';
  String get notifsNewSaleHint    => _isFr ? 'Notifier à chaque vente validée'   : 'Notify on every validated sale';
  String get notifsBigSale        => _isFr ? 'Vente importante'                  : 'Large sale';
  String get notifsBigSaleHint    => _isFr ? 'Ventes dépassant un seuil personnalisé' : 'Sales exceeding a custom threshold';
  String get notifsBigSaleAmount  => _isFr ? 'Seuil (montant)'                   : 'Threshold (amount)';
  String get notifsDaily          => _isFr ? 'Récapitulatif quotidien'           : 'Daily summary';
  String get notifsDailyHint      => _isFr ? 'Résumé des ventes chaque soir'     : 'Daily sales summary each evening';
  String get notifsSound          => _isFr ? 'Son'                                : 'Sound';
  String get notifsVibration      => _isFr ? 'Vibration'                          : 'Vibration';

  // ══ Page WhatsApp ═══════════════════════════════════════════════════════════
  String get whatsappTitle        => _isFr ? 'WhatsApp Business'                 : 'WhatsApp Business';
  String get whatsappSubtitle     => _isFr ? 'Envoyez reçus et promos à vos clients' : 'Send receipts and promotions to your customers';
  String get whatsappEnabled      => _isFr ? 'Activer WhatsApp'                  : 'Enable WhatsApp';
  String get whatsappNumber       => _isFr ? 'Numéro WhatsApp Business'          : 'WhatsApp Business number';
  String get whatsappNumberHint   => '+237 6XX XX XX XX';
  String get whatsappSendReceipt  => _isFr ? 'Envoyer le reçu au client'         : 'Send receipt to customer';
  String get whatsappSendPromo    => _isFr ? 'Envoyer promotions'                : 'Send promotions';
  String get whatsappTemplate     => _isFr ? 'Modèle de message'                 : 'Message template';
  String get whatsappTemplateHint => _isFr ? 'Bonjour {client}, merci pour votre achat !' : 'Hello {customer}, thank you for your purchase!';
  String get whatsappTest         => _isFr ? 'Envoyer un test'                   : 'Send test';
  String get whatsappConnected    => _isFr ? 'Connecté'                          : 'Connected';
  String get whatsappDisconnected => _isFr ? 'Non connecté'                      : 'Not connected';

  // ── Style des messages WhatsApp (paramètres caisse) ──
  String get whatsappStyleSection    => _isFr
      ? 'Style des messages WhatsApp'                  : 'WhatsApp message style';
  String get whatsappStyleHint       => _isFr
      ? 'Format utilisé pour l\'envoi des factures aux clients.'
      : 'Format used when sending invoices to customers.';
  String get whatsappStyleStandard   => _isFr ? 'Standard' : 'Standard';
  String get whatsappStyleStandardHint => _isFr
      ? 'Équilibré, illustré, lisible.'                : 'Balanced, illustrated, readable.';
  String get whatsappStyleShort      => _isFr ? 'Court'    : 'Short';
  String get whatsappStyleShortHint  => _isFr
      ? 'Ultra-condensé pour les achats rapides.'      : 'Ultra-compact for quick purchases.';
  String get whatsappStylePremium    => _isFr ? 'Premium'  : 'Premium';
  String get whatsappStylePremiumHint => _isFr
      ? 'Présentation soignée + invitation à noter.'   : 'Refined layout + rating invitation.';
  String get whatsappStylePreview    => _isFr ? 'Aperçu'   : 'Preview';

  // ══ Page Paiements ══════════════════════════════════════════════════════════
  String get paymentsTitle        => _isFr ? 'Modes de paiement'                 : 'Payment methods';
  String get paymentsSubtitle     => _isFr ? 'Activez les méthodes acceptées en caisse' : 'Enable methods accepted at checkout';
  String get paymentCash          => _isFr ? 'Espèces'                           : 'Cash';
  String get paymentMobileMoney   => _isFr ? 'Mobile Money (MTN)'                : 'Mobile Money (MTN)';
  String get paymentOrangeMoney   => 'Orange Money';
  String get paymentCard          => _isFr ? 'Carte bancaire'                    : 'Card';
  String get paymentBank          => _isFr ? 'Virement bancaire'                 : 'Bank transfer';
  String get paymentCheck         => _isFr ? 'Chèque'                            : 'Check';
  String get paymentCredit        => _isFr ? 'Crédit client'                     : 'Customer credit';
  String get paymentAccountNumber => _isFr ? 'Numéro de compte associé'          : 'Associated account number';
  String get paymentDefault       => _isFr ? 'Méthode par défaut'                : 'Default method';

  // ══ Page Profil utilisateur ═════════════════════════════════════════════════
  String get profileTitle         => _isFr ? 'Profil'                             : 'Profile';
  String get profileEditPhoto     => _isFr ? 'Modifier la photo'                  : 'Change photo';
  String get profileName          => _isFr ? 'Nom complet'                        : 'Full name';
  String get profileEmail         => _isFr ? 'Adresse email'                      : 'Email address';
  String get profileEmailLocked   => _isFr ? 'L\'email ne peut pas être modifié'  : 'Email cannot be changed';
  String get profilePhone         => _isFr ? 'Téléphone'                          : 'Phone';
  String get profilePassword      => _isFr ? 'Mot de passe'                       : 'Password';
  String get profileChangePassword => _isFr ? 'Changer le mot de passe'           : 'Change password';
  String get profileCurrentPassword => _isFr ? 'Mot de passe actuel'              : 'Current password';
  String get profileNewPassword   => _isFr ? 'Nouveau mot de passe'               : 'New password';
  String get profileConfirmNewPassword => _isFr ? 'Confirmer le nouveau mot de passe' : 'Confirm new password';
  String get profileSave          => _isFr ? 'Enregistrer'                        : 'Save';
  String get profileSaved         => _isFr ? 'Profil mis à jour'                  : 'Profile updated';
  String get profilePasswordChanged => _isFr ? 'Mot de passe modifié'              : 'Password changed';

  // ══ Commun ══════════════════════════════════════════════════════════════════
  String get commonSave    => _isFr ? 'Enregistrer' : 'Save';
  String get commonCancel  => _isFr ? 'Annuler'     : 'Cancel';
  String get commonSaved   => _isFr ? 'Enregistré'  : 'Saved';
  String get commonError   => _isFr ? 'Erreur'      : 'Error';
  String get commonLoading => _isFr ? 'Chargement…' : 'Loading…';

  // ══ Dialogue de confirmation destructive ════════════════════════════════════
  String dangerConfirmTypeToConfirm(String name) => _isFr
      ? 'Tapez « $name » pour confirmer'
      : 'Type "$name" to confirm';
  String get dangerConfirmConsequencesTitle =>
      _isFr ? 'Conséquences de cette action' : 'Consequences of this action';
  String get dangerConfirmCancel  => _isFr ? 'Annuler'   : 'Cancel';
  String get dangerConfirmConfirm => _isFr ? 'Confirmer' : 'Confirm';
  String get dangerConfirmInputHint =>
      _isFr ? 'Saisissez ici' : 'Type here';

  // ══ Dialogue PIN propriétaire ═══════════════════════════════════════════════
  String get ownerPinSubtitle => _isFr
      ? 'Entrez votre code PIN propriétaire'
      : 'Enter your owner PIN code';
  String ownerPinAttemptsRemaining(int count) {
    if (_isFr) {
      return count == 1
          ? '$count tentative restante'
          : '$count tentatives restantes';
    }
    return count == 1
        ? '$count attempt remaining'
        : '$count attempts remaining';
  }
  String get ownerPinIncorrect =>
      _isFr ? 'Code PIN incorrect' : 'Incorrect PIN code';
  String get ownerPinLocked => _isFr
      ? 'Trop de tentatives — bloqué pendant 15 minutes'
      : 'Too many attempts — locked for 15 minutes';
  String ownerPinLockedUntil(int minutes) => _isFr
      ? 'Bloqué — réessayez dans $minutes min'
      : 'Locked — try again in $minutes min';

  String get dangerCriticalNoPinConfigured => _isFr
      ? 'Aucun code PIN propriétaire défini. Configurez-le dans Paramètres › Sécurité.'
      : 'No owner PIN set. Configure it in Settings › Security.';

  // ══ Section Sécurité (paramètres PIN) ═══════════════════════════════════════
  String get securitySectionTitle => _isFr ? 'Sécurité' : 'Security';
  String get pinSetupTitle      => _isFr ? 'Code PIN propriétaire'         : 'Owner PIN code';
  String get pinSetupSubtitle   => _isFr
      ? 'Protège les actions irréversibles (suppressions, réinitialisations…)'
      : 'Protects irreversible actions (deletions, resets…)';
  String get pinDefine          => _isFr ? 'Définir un code PIN'           : 'Set a PIN code';
  String get pinChange          => _isFr ? 'Modifier mon PIN'              : 'Change my PIN';
  String get pinDelete          => _isFr ? 'Supprimer mon PIN'             : 'Remove my PIN';
  String get pinEnterNew        => _isFr ? 'Entrez un nouveau code PIN'    : 'Enter a new PIN code';
  String get pinConfirmNew      => _isFr ? 'Confirmez votre nouveau code'  : 'Confirm your new PIN';
  String get pinMismatch        => _isFr ? 'Les codes ne correspondent pas' : 'PIN codes do not match';
  String get pinChanged         => _isFr ? 'Code PIN enregistré'           : 'PIN code saved';
  String get pinRemoved         => _isFr ? 'Code PIN supprimé'             : 'PIN code removed';
  String get pinDeleteWarning   => _isFr
      ? 'Sans PIN, certaines actions critiques ne pourront plus être effectuées.'
      : 'Without a PIN, some critical actions can no longer be performed.';
  String get pinActive          => _isFr ? 'Activé'                        : 'Active';
  String get pinInactive        => _isFr ? 'Non configuré'                 : 'Not configured';

  // ══ Verrouillage PIN ════════════════════════════════════════════════════════
  String get lockBlockedTitle => _isFr
      ? 'Accès bloqué'
      : 'Access blocked';
  String lockBlockedBody(int minutes) => _isFr
      ? 'Trop de tentatives échouées. Réessayez dans $minutes min.'
      : 'Too many failed attempts. Try again in $minutes min.';
  String pinLockBannerMessage(int minutes) => _isFr
      ? 'Actions sensibles bloquées · $minutes min restantes'
      : 'Sensitive actions blocked · $minutes min remaining';
  String get commonClose => _isFr ? 'Fermer' : 'Close';

  // ══ Page Historique sécurité ════════════════════════════════════════════════
  String get securityHistoryTitle    => _isFr ? 'Historique sécurité'           : 'Security history';
  String get securityHistorySubtitle => _isFr
      ? 'Toutes les actions sensibles tracées (succès et échecs)'
      : 'All sensitive actions logged (successes and failures)';
  String get securityHistoryOwnerOnly => _isFr
      ? 'Cette page est réservée au propriétaire de la boutique.'
      : 'This page is restricted to the shop owner.';
  String get securityHistoryEmptyTitle    => _isFr ? 'Aucune action enregistrée' : 'No action recorded';
  String get securityHistoryEmptySubtitle => _isFr
      ? 'Les tentatives d\'actions sensibles apparaîtront ici.'
      : 'Sensitive action attempts will appear here.';
  String get securityHistorySuccess     => _isFr ? 'Succès'           : 'Success';
  String get securityHistoryFailure     => _isFr ? 'Échec'            : 'Failure';
  String get securityHistoryUnknownUser => _isFr ? 'Utilisateur inconnu' : 'Unknown user';

  // Libellés des actions enum
  String get dangerActionDeleteShop    => _isFr ? 'Suppression de boutique'        : 'Shop deletion';
  String get dangerActionDeleteAdmin   => _isFr ? 'Suppression d\'administrateur'  : 'Admin deletion';
  String get dangerActionDemoteAdmin   => _isFr ? 'Rétrogradation d\'admin'        : 'Admin demotion';
  String get dangerActionCancelSale    => _isFr ? 'Annulation de vente'            : 'Sale cancellation';
  String get dangerActionDeleteProduct => _isFr ? 'Suppression de produit'         : 'Product deletion';
  String get dangerActionDeleteClient  => _isFr ? 'Suppression de client'          : 'Client deletion';

  // ══ Page Membres — refonte UI ══════════════════════════════════════════════
  String get hrMembersTitle    => _isFr ? 'Membres'         : 'Members';
  String get hrNewMember       => _isFr ? 'Nouveau membre'  : 'New member';
  String get hrStatTotal       => _isFr ? 'Membres total'   : 'Total members';
  String get hrStatActive      => _isFr ? 'Actifs'          : 'Active';
  String get hrStatAdmins      => _isFr ? 'Admins'          : 'Admins';
  String get hrSectionOwner    => _isFr ? 'Propriétaire'    : 'Owner';
  String get hrSectionAdmins   => _isFr ? 'Admins'          : 'Admins';
  String get hrSectionStaff    => _isFr ? 'Personnel'       : 'Staff';
  String hrAdminCount(int n)   => _isFr
      ? '$n ${n <= 1 ? "admin" : "admins"}'
      : '$n ${n <= 1 ? "admin" : "admins"}';
  String hrStaffCount(int n)   => _isFr
      ? '$n ${n <= 1 ? "vendeur" : "vendeurs"}'
      : '$n ${n <= 1 ? "staff" : "staff"}';
  String hrSlotsRemaining(int n) => _isFr
      ? '$n ${n <= 1 ? "slot restant" : "slots restants"}'
      : '$n ${n <= 1 ? "slot left" : "slots left"}';
  String hrAdminQuota(int used, int total) => '$used/$total';
  String get hrLastActivity    => _isFr ? 'Dernière activité' : 'Last activity';
  String get hrNeverActive     => '—';
  String hrSinceDate(String d) => _isFr ? 'Depuis $d' : 'Since $d';
  String get hrSearchPlaceholder => _isFr
      ? 'Rechercher par nom ou email…'
      : 'Search by name or email…';
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();
  @override
  bool isSupported(Locale locale) => ['fr', 'en'].contains(locale.languageCode);
  @override
  Future<AppLocalizations> load(Locale locale) async => AppLocalizations(locale);
  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}