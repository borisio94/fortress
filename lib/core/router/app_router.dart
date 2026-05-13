import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../shared/widgets/alerts/_alert_demo_page.dart';
import '../../features/auth/presentation/bloc/auth_state.dart';
import '../../features/auth/presentation/pages/login_page.dart';
import '../../features/auth/presentation/pages/register_page.dart';
import '../../features/auth/presentation/pages/forgot_password_page.dart';
import '../../features/auth/presentation/pages/accept_invite_page.dart';
import '../../features/dashboard/presentattion/pages/dashboard_page.dart';
import '../../features/super_admin/presentation/pages/super_admin_page.dart';
import '../../features/super_admin/presentation/pages/admin_subscriptions_page.dart';
import '../../features/super_admin/presentation/pages/plans_page.dart';
import '../../features/catalogue/presentation/pages/catalogue_page.dart';
import '../../features/tracking/presentation/pages/order_tracking_page.dart';
import '../../features/subscription/presentation/pages/subscription_page.dart';
import '../../features/hr/presentation/pages/employees_page.dart';
import '../../features/shop_selector/presentation/pages/shop_list_page.dart';
import '../../features/shop_selector/presentation/pages/create_shop_page.dart';
import '../../features/shop_selector/presentation/pages/edit_shop_page.dart';
import '../../features/caisse/presentation/pages/caisse_page.dart';
import '../../features/caisse/presentation/pages/orders_page.dart';
import '../../features/caisse/presentation/pages/payment_page.dart';
import '../../features/inventaire/presentation/pages/inventaire_page.dart';
import '../../features/inventaire/presentation/pages/product_form_page.dart';
import '../../features/inventaire/presentation/pages/reception_page.dart';
import '../../features/inventaire/presentation/pages/incidents_page.dart';
import '../../features/inventaire/presentation/pages/suppliers_page.dart';
import '../../features/inventaire/presentation/pages/purchase_orders_page.dart';
import '../../features/inventaire/presentation/pages/stock_movements_page.dart';
import '../../features/inventaire/presentation/pages/client_returns_page.dart';
import '../../features/crm/presentation/pages/clients_page.dart' show ClientsPage;
import '../../features/hr/presentation/pages/employee_form_sheet.dart';
import '../../shared/widgets/form_sheet.dart';
import '../../features/crm/presentation/pages/client_detail_page.dart';
import '../../features/crm/presentation/pages/send_notification_page.dart';
import '../../features/finances/presentation/pages/finances_page.dart';
import '../../features/hub_central/presentation/pages/hub_dashboard_page.dart';
import '../../features/hub_central/presentation/pages/shop_comparison_page.dart';
import '../../features/parametres/presentation/pages/parametres_page.dart';
import '../../features/parametres/presentation/pages/shop_settings_page.dart';
import '../../features/parametres/presentation/pages/stock_locations_page.dart';
import '../../features/parametres/presentation/pages/location_contents_page.dart';
import '../../features/parametres/presentation/pages/transfers_list_page.dart';
import '../../features/parametres/presentation/pages/activity_log_page.dart';
import '../../features/tickets/presentation/pages/tickets_page.dart';
import '../../features/tickets/presentation/pages/ticket_detail_page.dart';
import '../../features/parametres/presentation/pages/security_history_page.dart';
import '../../features/parametres/presentation/pages/user_profile_page.dart';
import '../../features/parametres/presentation/pages/language_page.dart';
import '../../features/parametres/presentation/pages/currency_page.dart';
import '../../features/parametres/presentation/pages/theme_page.dart';
import '../../features/parametres/presentation/pages/caisse_config_page.dart';
import '../../features/parametres/presentation/pages/notifications_page.dart';
import '../../features/parametres/presentation/pages/payments_page.dart';
import '../../features/parametres/presentation/pages/delivery_templates_page.dart';
import '../../features/parametres/presentation/pages/partner_accounts_page.dart';
import '../../features/parametres/presentation/pages/pin_delete_page.dart';
import '../../features/parametres/presentation/pages/sessions_page.dart';
import '../permisions/admin_panel_page.dart';
import '../permisions/subscription_provider.dart';
import '../database/app_database.dart';
import '../services/presence_service.dart';
import '../services/session_refresher.dart';
import '../services/session_validator.dart';
import '../../shared/widgets/offline_banner_widget.dart'
    show tokenRefreshFailedProvider, isOfflineProvider;
import '../storage/local_storage_service.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../storage/hive_boxes.dart';
import '../../shared/widgets/adaptive_scaffold.dart';
import '../i18n/app_localizations.dart';

import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;
import 'route_names.dart';
import '../../shared/providers/current_shop_provider.dart';

/// Transition appliquée aux 8 pages "shell" (Dashboard, Caisse, Inventaire,
/// Clients, Finances, Commandes, Membres, Paramètres).
///
/// - Mobile : `FadeTransition` 150ms — comportement attendu pour des onglets
///   bottom nav (pas de glissement latéral).
/// - Desktop : instantané — la sidebar reste fixe, la zone de contenu doit
///   changer sans animation pour préserver le ressenti "tableau de bord
///   bureau".
Page<void> _shellPage(GoRouterState state, Widget child) {
  final isDesktop = !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  return CustomTransitionPage<void>(
    key:                state.pageKey,
    child:              child,
    transitionDuration: isDesktop
        ? Duration.zero
        : const Duration(milliseconds: 150),
    transitionsBuilder: (ctx, anim, _, c) =>
        isDesktop ? c : FadeTransition(opacity: anim, child: c),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider du statut d'authentification — source unique de vérité pour le router
// Alimenté par AuthBloc via AuthRouterNotifier
// ─────────────────────────────────────────────────────────────────────────────

/// Notifier qui écoute AuthBloc et expose isAuthenticated au GoRouter
class AuthRouterNotifier extends ChangeNotifier {
  bool _isAuthenticated = false;
  bool get isAuthenticated => _isAuthenticated;

  /// `false` tant qu'AuthBloc n'a pas encore évalué la session existante
  /// (refresh navigateur). Pendant cette fenêtre le redirect doit retourner
  /// `null` — sinon un utilisateur connecté est renvoyé sur /login parce
  /// que `_isAuthenticated` est encore à sa valeur par défaut (false).
  bool _initialized = false;
  bool get initialized => _initialized;

  /// `true` tant que le `Future.wait([load(), _syncMemberships])` lancé au
  /// login n'est pas terminé. Pendant cette fenêtre, le redirect évite
  /// d'envoyer un employé sur la page paywall (car ses memberships ne sont
  /// pas encore en cache → faux positif "0 boutique").
  bool _syncing = false;
  bool get isSyncing => _syncing;

  Ref? _ref;
  void setRef(Ref ref) => _ref = ref;

  /// Force le router à ré-évaluer ses redirects (utilisé quand le plan change)
  void refresh() => notifyListeners();

  void update(AuthState state) {
    // Au tout 1er update reçu (Authenticated ou Unauthenticated), on
    // considère le check initial terminé → autorise les redirects.
    final justInitialized = !_initialized &&
        (state is AuthAuthenticated || state is AuthUnauthenticated);
    if (justInitialized) {
      _initialized = true;
    }
    final wasAuth = _isAuthenticated;
    _isAuthenticated = state is AuthAuthenticated;
    if (!wasAuth && _isAuthenticated) {
      // Validation serveur de la session : si le compte a été supprimé
      // côté serveur (delete_employee → _purge_auth_user), la session
      // est invalidée + Hive purgé → l'utilisateur revient sur login
      // sans pouvoir réutiliser le cache offline.
      SessionValidator.validate().then((valid) {
        if (!valid) notifyListeners();
      });
      // Vient de se connecter → charger plan + memberships EN PARALLÈLE
      // puis re-déclencher le redirect une fois les deux prêts.
      // Le flag `_syncing` empêche le redirect d'envoyer un employé sur
      // la page paywall pendant cette fenêtre transitoire.
      final ref = _ref;
      if (ref != null) {
        _syncing = true;
        Future.wait([
          ref.read(subscriptionProvider.notifier).load(),
          _syncMemberships(ref),
        ]).whenComplete(() {
          _syncing = false;
          notifyListeners();
        });
        // Refresh token avec retry exponentiel (1s · 2s · 4s). Si échec
        // après 3 essais → flag offline levé pour étendre la bannière
        // (le device a peut-être une interface mais Supabase est KO).
        // Non-bloquant : on n'attend pas pour ne pas retarder l'entrée
        // dans l'app.
        unawaited(SessionRefresher.refresh().then((ok) {
          ref.read(tokenRefreshFailedProvider.notifier).state = !ok;
        }));
      }
      // Démarre le heartbeat de présence (PresenceService).
      // Permet au workflow d'approbation owner de fonctionner.
      PresenceService.start();
    } else if (wasAuth && !_isAuthenticated) {
      _ref?.read(subscriptionProvider.notifier).reset();
      _ref?.read(shopRolesMapProvider.notifier).state = {};
      // Vider la boutique active et notifier le dashboard
      try {
        _ref?.read(currentShopProvider.notifier).clearShop();
      } catch (_) {}
      AppDatabase.notifyAllChanged();
      PresenceService.stop();
    }
    if (wasAuth != _isAuthenticated || justInitialized) notifyListeners();
  }

  /// Synchronise les memberships de l'utilisateur courant et met à jour
  /// le provider des rôles. Bloque jusqu'à completion.
  Future<void> _syncMemberships(Ref ref) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final roles = await AppDatabase.syncMemberships(uid);
      ref.read(shopRolesMapProvider.notifier).state = roles;
    } catch (_) {
      // En cas d'échec réseau, lire le cache Hive
      final cached = AppDatabase.getMemberships(uid);
      ref.read(shopRolesMapProvider.notifier).state = cached;
    }
  }
}

final authRouterNotifierProvider = Provider<AuthRouterNotifier>((ref) {
  final n = AuthRouterNotifier();
  n.setRef(ref);
  // Re-évaluer le redirect du router chaque fois que le plan change
  // (après load() au login ou refresh() après souscription)
  ref.listen(subscriptionProvider, (_, __) => n.refresh());
  // Retry du refresh token au retour du réseau : si l'utilisateur est
  // resté hors ligne assez longtemps pour que le token expire, on
  // retente dès la reconnexion pour effacer la bannière sans attendre
  // qu'il fasse une action.
  ref.listen<AsyncValue<bool>>(isOfflineProvider, (prev, next) {
    final wasOffline = prev?.valueOrNull ?? false;
    final isOnline = next.valueOrNull == false;
    if (wasOffline && isOnline && n.isAuthenticated) {
      unawaited(SessionRefresher.refresh().then((ok) {
        ref.read(tokenRefreshFailedProvider.notifier).state = !ok;
      }));
    }
  });
  return n;
});

// ─────────────────────────────────────────────────────────────────────────────
// Router
// ─────────────────────────────────────────────────────────────────────────────

// Clé navigator dédiée au ShellRoute — évite les conflits de GlobalKey
// lors de la navigation entre routes shell et routes hors-shell
final _shellNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'shell');

final appRouterProvider = Provider<GoRouter>((ref) {
  final notifier = ref.watch(authRouterNotifierProvider);

  return GoRouter(
    initialLocation: RouteNames.login,
    refreshListenable: notifier, // ← le router se rafraîchit quand notifier change
    redirect: (context, state) {
      // Helper : destination après login. Si l'utilisateur a EXACTEMENT
      // 1 boutique en cache (owner ou membre), on saute la page
      // /shop-selector et on l'envoie directement sur le dashboard de
      // cette boutique. Évite le flash visuel `ShopListPage` → redirect
      // qui se produisait avant : la page se rendait, faisait un
      // `LoadMyShops`, recevait 1 boutique, puis appelait `context.go`
      // vers le dashboard. Désormais le saut se fait dès le redirect
      // GoRouter, donc la transition Login → Dashboard est directe.
      // Persiste aussi `active_shop_$uid` pour que la prochaine session
      // démarre sur la même boutique.
      String postAuthDestination() {
        final uid = Supabase.instance.client.auth.currentUser?.id;
        if (uid == null) return RouteNames.shopSelector;
        final shops = LocalStorageService.getShopsForUser(uid);
        if (shops.length == 1) {
          LocalStorageService.saveActiveShopId(uid, shops.first.id);
          return '/shop/${shops.first.id}/dashboard';
        }
        return RouteNames.shopSelector;
      }

      final isLoggedIn           = notifier.isAuthenticated;
      final loc                  = state.matchedLocation;
      final isAuthRoute          = loc.startsWith('/auth');
      final isSubscriptionRoute  = loc.startsWith('/subscription');
      final isAcceptInviteRoute  = loc.startsWith('/accept-invite');
      final isCatalogueRoute     = loc.startsWith('/catalogue/');
      final isTrackRoute         = loc.startsWith('/track/');

      // ── /accept-invite : page publique, jamais rediriger ───────────
      // Gère elle-même l'état (invité/connecté/mauvais compte)
      if (isAcceptInviteRoute) return null;
      // ── /catalogue/:shopId : vitrine publique sans auth ────────────
      if (isCatalogueRoute) return null;
      // ── /track/:orderId : suivi de commande public sans auth ───────
      if (isTrackRoute) return null;

      // ── Boot : check session pas encore terminé ────────────────────
      // Au refresh navigateur, AuthBloc évalue la session Supabase de
      // façon asynchrone. Tant que ce check n'a pas émis de résultat,
      // on n'a pas le droit de rediriger : sinon l'utilisateur connecté
      // est envoyé sur /login alors que sa session est valide.
      if (!notifier.initialized) return null;

      // ── Non connecté ───────────────────────────────────────────────
      if (!isLoggedIn) {
        return isAuthRoute ? null : RouteNames.login;
      }

      // ── Connecté : lire le plan (peut être null pendant le chargement) ─
      final plan = ref.read(subscriptionProvider).valueOrNull;

      // Plan pas encore chargé → ne pas rediriger (évite le flash)
      if (plan == null) return null;

      // ── CAS 1 — Super Admin ────────────────────────────────────────
      if (plan.isSuperAdmin) {
        if (isAuthRoute) return RouteNames.superAdminHome;
        final allowed = loc.startsWith('/super-admin') ||
            loc.startsWith('/admin') ||
            loc.startsWith('/subscription');
        if (!allowed) return RouteNames.superAdminHome;
        return null;
      }

      // ── Souscription qui vient d'être activée ─────────────────────
      // Priorité sur les autres cas : consomme le flag et route une fois.
      // Si une seule boutique → dashboard direct, sinon shop-selector.
      final subNotifier = ref.read(subscriptionProvider.notifier);
      if (subNotifier.justActivated) {
        subNotifier.consumeJustActivated();
        return postAuthDestination();
      }

      // ── CAS 2 — Pas d'abonnement actif ────────────────────────────
      // Logique en trois temps :
      //   - Si l'utilisateur est EMPLOYÉ (membre d'au moins une boutique
      //     mais pas owner d'une boutique connue) → JAMAIS de paywall.
      //     La page /subscription est réservée au propriétaire. On bascule
      //     en mode dégradé jusqu'à ce que le sync ramène le plan hérité
      //     du owner.
      //   - Si l'utilisateur n'a JAMAIS utilisé l'app (0 boutique) — typique
      //     d'un trial fraîchement expiré sans engagement → on force vers
      //     /subscription pour qu'il choisisse un plan.
      //   - Sinon (au moins 1 boutique créée) — l'utilisateur a déjà investi
      //     ses données, on bascule en MODE DÉGRADÉ : il accède à l'app en
      //     lecture seule (dashboard, listes produits/clients/commandes,
      //     export). Les actions d'écriture sont bloquées par
      //     AppPermissions.canAdd*/canEdit*. La SubscriptionBanner (insérée
      //     dans le shell) propose le bouton « Renouveler » → /subscription.
      if (!plan.isActive) {
        final uid = Supabase.instance.client.auth.currentUser?.id;

        // Sync au login en cours → ne pas paywall prématurément.
        // Pendant cette fenêtre les caches Hive (shop_roles_$uid) ne sont
        // pas encore peuplés pour un employé qui se reconnecte. On
        // l'envoie sur shop-selector qui affichera son spinner de
        // chargement le temps que la sync termine.
        if (notifier.isSyncing) {
          // Pendant la sync, le cache des boutiques peut être vide ou
          // partiel — postAuthDestination retomberait sur shop-selector
          // de toute façon, mais on essaie quand même le bypass au cas
          // où le cache local est déjà peuplé.
          if (isAuthRoute) return postAuthDestination();
          return null;
        }

        // Employé : a des rôles boutique mais aucun n'est 'owner'.
        // Lit le cache `shop_roles_$uid` rempli par AppDatabase.syncMemberships
        // au login (et NON HiveBoxes.membershipsBox qui n'est rempli que
        // lors de la création d'une boutique ou de l'acceptation d'invitation).
        if (uid != null) {
          final roles = AppDatabase.getMemberships(uid);
          if (roles.isNotEmpty
              && !roles.values.any((r) => r == 'owner')) {
            // Employé authentifié → jamais paywall, peu importe l'état
            // de son plan (il hérite du owner via le RPC get_user_plan).
            if (isAuthRoute) return postAuthDestination();
            return null;
          }
        }

        final hasShops = uid != null
            && LocalStorageService.getShopsForUser(uid).isNotEmpty;
        if (!hasShops) {
          // Aucune boutique → trial épuisé sans utilisation : paywall.
          return isSubscriptionRoute ? null : RouteNames.subscription;
        }
        // Sinon → mode dégradé, on laisse passer.
        if (isAuthRoute) return postAuthDestination();
        return null;
      }

      // ── CAS 3 — Abonnement actif : auth route → dashboard direct si
      // 1 boutique, sinon shop-selector (cf. postAuthDestination).
      if (isAuthRoute) return postAuthDestination();

      return null;
    },
    routes: [
      GoRoute(path: '/catalogue/:shopId',
          builder: (c, s) {
            final qp = s.uri.queryParameters;
            final ids = qp['ids']
                ?.split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList();
            // Parse `stock=<key>:<qty>,<key>:<qty>,...` en Map. Clé =
            // `productId` ou `productId|variantId`. Valeurs invalides
            // ignorées silencieusement (pas de crash si lien malformé).
            Map<String, int>? stockOverride;
            final rawStock = qp['stock'];
            if (rawStock != null && rawStock.isNotEmpty) {
              final m = <String, int>{};
              for (final tok in rawStock.split(',')) {
                final i = tok.lastIndexOf(':');
                if (i <= 0 || i >= tok.length - 1) continue;
                final key = tok.substring(0, i);
                final qty = int.tryParse(tok.substring(i + 1));
                if (qty != null) m[key] = qty;
              }
              if (m.isNotEmpty) stockOverride = m;
            }
            return CataloguePage(
              shopId: s.pathParameters['shopId']!,
              initialCategory: qp['cat'],
              productIds: (ids != null && ids.isNotEmpty) ? ids : null,
              stockOverride: stockOverride,
            );
          }),
      // Suivi de commande publique — lien envoyé par WhatsApp dans la
      // relance. La page appelle la RPC `get_tracked_order` (anon) puis
      // `validate_order_by_client` au tap sur « Valider ma commande ».
      GoRoute(path: '/track/:orderId',
          builder: (c, s) => OrderTrackingPage(
              orderId: s.pathParameters['orderId']!)),
      // Route dev — visualisation isolée des composants d'alerte commandes
      // (modal + banner + favicon blinker). Gated `kDebugMode` : la route
      // n'est PAS enregistrée en build release, donc inaccessible en prod.
      if (kDebugMode)
        GoRoute(path: '/dev/alerts-demo',
            builder: (c, s) => const AlertDemoPage()),
      GoRoute(path: RouteNames.login,          builder: (c, s) => const LoginPage()),
      GoRoute(path: RouteNames.register,        builder: (c, s) => const RegisterPage()),
      GoRoute(path: RouteNames.adminPanel,      builder: (c, s) => const AdminPanelPage()),
      GoRoute(path: RouteNames.superAdminHome,  builder: (c, s) => const SuperAdminPage()),
      GoRoute(path: RouteNames.adminSubscriptions,
          builder: (c, s) => const AdminSubscriptionsPage()),
      GoRoute(path: '/super-admin/plans',
          builder: (c, s) => const PlansPage()),
      GoRoute(path: RouteNames.subscription,    builder: (c, s) => const SubscriptionPage()),
      GoRoute(path: RouteNames.forgotPassword,  builder: (c, s) => const ForgotPasswordPage()),
      GoRoute(path: RouteNames.acceptInvite,
          builder: (c, s) => AcceptInvitePage(
              token: s.uri.queryParameters['token'])),
      GoRoute(path: RouteNames.shopSelector,    builder: (c, s) => const ShopListPage()),
      GoRoute(
        path: RouteNames.createShop,
        // Garde : seul un owner (ou admin avec permission shopCreate
        // attribuée par le owner) peut créer une boutique. Les employés
        // qui tentent l'URL directement sont renvoyés au shop-selector.
        //
        // ⚠ Cette logique DOIT rester en miroir avec
        // `_ShopListPageState._canCreateShop()` dans shop_list_page.dart.
        // Sinon le bouton "Nouvelle boutique" pousserait vers /create
        // qui redirigerait immédiatement → boucle perçue par l'user
        // comme "l'app cherche à charger une boutique".
        //
        // 3 cas :
        //   1. Owner d'au moins une boutique en local → autorisé.
        //   2. 0 membership en local pour cet uid → nouvel inscrit qui
        //      crée sa première boutique → autorisé. Sans cette branche,
        //      on rejette à tort le tout premier compte.
        //   3. Au moins un membership mais aucun shop possédé → employé
        //      invité dans une autre boutique → bloqué.
        redirect: (ctx, state) {
          final uid = Supabase.instance.client.auth.currentUser?.id;
          if (uid == null) return null;

          final ownsAShop = HiveBoxes.shopsBox.values.any((raw) {
            try {
              final m = Map<String, dynamic>.from(raw);
              return m['owner_id'] == uid;
            } catch (_) { return false; }
          });
          if (ownsAShop) return null;

          final hasAnyMembership = HiveBoxes.membershipsBox.values.any((raw) {
            try {
              final m = Map<String, dynamic>.from(raw);
              return m['user_id'] == uid;
            } catch (_) { return false; }
          });
          return hasAnyMembership ? RouteNames.shopSelector : null;
        },
        builder: (c, s) => const CreateShopPage(),
      ),
      GoRoute(path: RouteNames.editShop,
          builder: (c, s) => EditShopPage(shopId: s.pathParameters['shopId']!)),
      GoRoute(path: RouteNames.hub,             builder: (c, s) => const HubDashboardPage()),
      GoRoute(path: RouteNames.shopComparison,  builder: (c, s) => const ShopComparisonPage()),

      ShellRoute(
        // navigatorKey unique — isole le ShellRoute du navigator racine
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) {
          final shopId = state.pathParameters['shopId'] ?? '';
          return ShopShell(key: ValueKey(shopId), child: child, shopId: shopId);
        },
        routes: [
          GoRoute(path: '/shop/:shopId/dashboard',
              pageBuilder: (c, s) => _shellPage(s,
                  DashboardPage(shopId: s.pathParameters['shopId']!))),
          GoRoute(path: '/shop/:shopId/caisse',
              pageBuilder: (c, s) => _shellPage(s, CaissePage(
                shopId: s.pathParameters['shopId']!,
                editOrderId: s.uri.queryParameters['edit'],
                preselectedClientId: s.uri.queryParameters['clientId'],
              ))),
          GoRoute(path: '/shop/:shopId/caisse/payment',
              builder: (c, s) => PaymentPage(shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/caisse/orders',
              pageBuilder: (c, s) => _shellPage(s,
                  OrdersPage(shopId: s.pathParameters['shopId']!))),
          GoRoute(path: '/shop/:shopId/inventaire',
              pageBuilder: (c, s) => _shellPage(s,
                  InventairePage(shopId: s.pathParameters['shopId']!))),
          GoRoute(path: '/shop/:shopId/employees',
              pageBuilder: (c, s) => _shellPage(s, EmployeesPage(
                  shopId: s.pathParameters['shopId']!))),
          GoRoute(path: '/shop/:shopId/inventaire/product',
              builder: (c, s) => ProductFormPage(
                  shopId: s.pathParameters['shopId']!,
                  extra: s.extra)),
          GoRoute(path: '/shop/:shopId/inventaire/receptions',
              builder: (c, s) => ReceptionPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/inventaire/incidents',
              builder: (c, s) => IncidentsPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/inventaire/suppliers',
              builder: (c, s) => SuppliersPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/inventaire/purchase-orders',
              pageBuilder: (c, s) => _shellPage(s, PurchaseOrdersPage(
                  shopId: s.pathParameters['shopId']!))),
          GoRoute(path: '/shop/:shopId/inventaire/stock-movements',
              builder: (c, s) => StockMovementsPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/inventaire/returns',
              builder: (c, s) => ClientReturnsPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/crm',
              pageBuilder: (c, s) => _shellPage(s,
                  ClientsPage(shopId: s.pathParameters['shopId']!))),
          GoRoute(path: '/shop/:shopId/crm/client/:clientId',
              builder: (c, s) => ClientDetailPage(
                shopId: s.pathParameters['shopId']!,
                clientId: s.pathParameters['clientId']!,
              )),
          GoRoute(path: '/shop/:shopId/crm/notify',
              builder: (c, s) => SendNotificationPage(shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/finances',
              pageBuilder: (c, s) => _shellPage(s,
                  FinancesPage(shopId: s.pathParameters['shopId']!))),
          GoRoute(path: '/shop/:shopId/historique',
              builder: (c, s) => ActivityLogPage(shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/tickets',
              builder: (c, s) => TicketsPage(shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/tickets/:ticketId',
              builder: (c, s) => TicketDetailPage(
                  shopId:   s.pathParameters['shopId']!,
                  ticketId: s.pathParameters['ticketId']!)),
          GoRoute(path: '/shop/:shopId/parametres',
              pageBuilder: (c, s) => _shellPage(s,
                  ParametresPage(shopId: s.pathParameters['shopId']!))),
          GoRoute(path: '/shop/:shopId/parametres/shop',
              builder: (c, s) {
                final showOverview =
                    s.uri.queryParameters['with_overview'] == '1';
                // Query `tab` (overview|members|copy) prioritaire — utilisé
                // par le sync URL ↔ tab de ShopSettingsPage pour préserver
                // l'onglet courant lors d'une navigation Membres ↔ Copier
                // qui change de path. Sans ça, on retombait sur le tab
                // par défaut (Boutique) après le push, ce qui faisait
                // « clignoter » Copier vers Boutique.
                final tabParam = s.uri.queryParameters['tab'];
                final initialTab = switch (tabParam) {
                  'overview' => ShopSettingsTab.overview,
                  'members'  => ShopSettingsTab.members,
                  'copy'     => ShopSettingsTab.copy,
                  _ => showOverview
                      ? ShopSettingsTab.overview
                      : ShopSettingsTab.members,
                };
                return ShopSettingsPage(
                  shopId: s.pathParameters['shopId']!,
                  initialTab: initialTab,
                  showOverviewTab: showOverview,
                );
              }),
          GoRoute(path: '/shop/:shopId/parametres/locations',
              builder: (c, s) => StockLocationsPage(shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/parametres/locations/:locationId',
              builder: (c, s) => LocationContentsPage(
                  shopId: s.pathParameters['shopId']!,
                  locationId: s.pathParameters['locationId']!)),
          GoRoute(path: '/shop/:shopId/parametres/transfers',
              builder: (c, s) => TransfersListPage(
                  shopId: s.pathParameters['shopId']!)),
          // Route legacy — préservée pour les liens externes / deeplinks.
          // Redirige systématiquement vers /parametres/shop?tab=members&with_overview=1
          // pour que TOUTES les transitions internes restent sur le même
          // path : GoRouter conserve alors la pageKey, la page n'est jamais
          // démontée entre tabs, et le clignotement disparaît.
          GoRoute(path: '/shop/:shopId/parametres/users',
              redirect: (ctx, s) =>
                  '/shop/${s.pathParameters['shopId']!}/parametres/shop'
                  '?tab=members&with_overview=1'),
          GoRoute(path: '/shop/:shopId/parametres/security-history',
              builder: (c, s) => SecurityHistoryPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/parametres/profile',
              builder: (c, s) => UserProfilePage(
                  shopId: s.pathParameters['shopId'])),
          GoRoute(path: '/shop/:shopId/parametres/language',
              builder: (c, s) => LanguagePage(
                  shopId: s.pathParameters['shopId'])),
          GoRoute(path: '/shop/:shopId/parametres/currency',
              builder: (c, s) => CurrencyPage(
                  shopId: s.pathParameters['shopId'])),
          GoRoute(path: '/shop/:shopId/parametres/theme',
              builder: (c, s) => ThemePage(
                  shopId: s.pathParameters['shopId'])),
          GoRoute(path: '/shop/:shopId/parametres/caisse',
              builder: (c, s) => CaisseConfigPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/parametres/notifications',
              builder: (c, s) => NotificationsPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/parametres/payments',
              builder: (c, s) => PaymentsPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/parametres/delivery-templates',
              builder: (c, s) => DeliveryTemplatesPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/parametres/partner-accounts',
              builder: (c, s) => PartnerAccountsPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/parametres/pin/delete',
              builder: (c, s) => PinDeletePage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/parametres/sessions',
              builder: (c, s) => SessionsPage(
                  shopId: s.pathParameters['shopId']!)),
        ],
      ),
    ],
  );
});

class ShopShell extends ConsumerWidget {
  final Widget child;
  final String shopId;

  const ShopShell({super.key, required this.child, this.shopId = ''});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Toutes les routes /shop/:shopId/... passent par AdaptiveScaffold
    // pour garantir un layout cohérent (sidebar desktop / bottom nav
    // mobile). AdaptiveScaffold détecte si la route active correspond à
    // un nav item (page root) ou non (sub-page) et adapte le rendu :
    //   - root : bottom nav visible, breadcrumb FORTRESS › <module>
    //   - sub-page : bottom nav masqué, AppBar back button, breadcrumb
    //     replié sur FORTRESS uniquement
    // Les sub-pages utilisent encore AppScaffold en interne — celui-ci
    // détecte AdaptiveScaffold ancestor et devient pass-through pour
    // éviter le double layout (cf. AppScaffold.build).
    //
    // CTAs topbar : calculés en fonction de la route active (spec round 9).
    // Stock/Clients exposent un bouton « + » dans la topbar shell, déplaçant
    // les CTAs précédemment inline dans le body.
    final goState = GoRouterState.of(context);
    final loc      = goState.matchedLocation;
    final tabQuery = goState.uri.queryParameters['tab'];
    final extraActions = _topbarActionsFor(context, loc, shopId, tabQuery);
    return AdaptiveScaffold(
      shopId: shopId,
      body: child,
      extraActions: extraActions,
    );
  }

  /// Bouton « + » conditionnel dans la topbar shell — basé sur la route
  /// active. Inventaire (`/inventaire` exact) → push form produit ;
  /// Clients (`/crm` exact) → ouvre ClientFormSheet en bottom sheet ;
  /// Membres (`/parametres/shop?tab=members`) → ouvre EmployeeFormSheet.
  /// Sur les sub-pages (édition produit, détail client…), pas de CTA.
  static List<Widget>? _topbarActionsFor(
      BuildContext context, String loc, String shopId, String? tabQuery) {
    // Inventaire et CRM : leur "+" topbar a été retiré au profit d'un
    // bouton inline sur la ligne des filtres / recherche (cf. lots UX).
    // Membres = path /parametres/shop avec query tab=members.
    final usersRoot      = loc == '/shop/$shopId/parametres/shop'
        && tabQuery == 'members';
    if (!usersRoot) return null;
    // usersRoot — Membres : ouvre EmployeeFormSheet. EmployeesPage écoute
    // employeesProvider via Riverpod, refresh auto sur invalidation.
    return [
      IconButton(
        icon: const Icon(Icons.add_rounded, size: 26),
        tooltip: context.l10n.hrNewMember,
        onPressed: () {
          showFormSheet<bool>(
            context: context,
            builder: (_) => EmployeeFormSheet(shopId: shopId),
          );
        },
      ),
    ];
  }
}