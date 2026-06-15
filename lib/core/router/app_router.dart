import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import '../observability/error_reporter.dart';
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
import '../../features/super_admin/presentation/pages/broadcast_page.dart';
import '../../features/super_admin/presentation/pages/platform_stats_page.dart';
import '../../features/super_admin/presentation/pages/platform_incidents_page.dart';
import '../../features/super_admin/presentation/pages/platform_export_page.dart';
import '../../features/super_admin/presentation/pages/super_admin_deleted_hub_page.dart';
import '../../features/onboarding/presentation/pages/onboarding_slides_page.dart';
import '../../features/onboarding/presentation/pages/auth_choice_page.dart';
import '../../features/onboarding/presentation/pages/register_simplified_page.dart';
import '../../features/onboarding/presentation/pages/shop_onboarding_wizard.dart';
import '../../features/onboarding/presentation/pages/product_quick_add_page.dart';
import '../../features/onboarding/presentation/providers/onboarding_seen_provider.dart';
import '../../features/onboarding/data/onboarding_prefs.dart';
import '../../features/catalogue/presentation/pages/catalogue_page.dart';
import '../../features/marketing/presentation/pages/landing_page.dart';
import '../../features/promo_campaigns/presentation/pages/campaign_send_page.dart';
import '../../features/promo_campaigns/presentation/pages/campaigns_page.dart';
import '../../features/promo_campaigns/presentation/pages/promo_showcase_page.dart';
import '../../features/marketing/presentation/pages/pricing_page.dart';
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
import '../../features/parametres/presentation/pages/aide_page.dart';
import '../../features/parametres/presentation/pages/apropos_page.dart';
import '../../features/parametres/presentation/pages/language_page.dart';
import '../../features/parametres/presentation/pages/currency_page.dart';
import '../../features/parametres/presentation/pages/theme_page.dart';
import '../../features/parametres/presentation/pages/text_size_page.dart';
import '../../features/parametres/presentation/pages/caisse_config_page.dart';
import '../../features/parametres/presentation/pages/whatsapp_templates_page.dart';
import '../../features/parametres/presentation/pages/notifications_page.dart';
import '../../features/parametres/presentation/pages/exports_page.dart';
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
import '../../shared/widgets/suspended_shop_screen.dart';
import '../../shared/widgets/blocked_account_screen.dart';
import 'registration_flag.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../storage/hive_boxes.dart';
import '../../shared/widgets/adaptive_scaffold.dart';

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
      // Toute authentification réussie marque les slides d'onboarding
      // comme « vues » — y compris pour un user qui a contourné les
      // slides (inscription directe /auth/register, lien d'invitation,
      // import de session existante). Sinon, au logout, le redirect le
      // renverrait sur l'onboarding au lieu de /login.
      unawaited(OnboardingPrefs.markSlidesSeen());
      _ref?.read(onboardingSeenCacheProvider.notifier).state = true;
      // Vient de se connecter → charger plan + memberships EN PARALLÈLE
      // avec la validation serveur de la session (compte zombie : profile
      // ou membership supprimés côté serveur sans purge auth). Si invalide,
      // SessionValidator déclenche signOut + clear Hive → l'AuthBloc émet
      // AuthUnauthenticated et le router redirige vers /login sans flash
      // dashboard. Le flag `_syncing` bloque toute redirection vers le
      // dashboard tant que ces 3 étapes ne sont pas terminées.
      final ref = _ref;
      if (ref != null) {
        _syncing = true;
        Future.wait([
          SessionValidator.validate(),
          ref.read(subscriptionProvider.notifier).load(),
          _syncMemberships(ref),
          // Statut des boutiques (status='suspended' inclus) en Hive AVANT le
          // notifyListeners → la garde « Boutique suspendue » du shell voit le
          // bon statut dès le 1er build (même principe que le blocage/plan).
          _syncUserShops(),
          // Flag serveur des slides d'intro (1 fois par compte, cross-device).
          loadOnboardingSlidesSeen(ref),
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
      // Phase 0 — enrichissement Sentry : associe la cible exacte (qui est
      // connecté) à tout event remonté.
      if (state is AuthAuthenticated) {
        final u = state.user;
        Sentry.configureScope((scope) =>
            scope.setUser(SentryUser(id: u.id, email: u.email)));
      }
    } else if (wasAuth && !_isAuthenticated) {
      _ref?.read(subscriptionProvider.notifier).reset();
      _ref?.read(shopRolesMapProvider.notifier).state = {};
      // Réinitialise le flag slides → rechargé à la prochaine connexion
      // (un autre compte sur le même appareil doit être réévalué).
      _ref?.read(onboardingSlidesSeenProvider.notifier).state = null;
      // Vider la boutique active et notifier le dashboard
      try {
        _ref?.read(currentShopProvider.notifier).clearShop();
      } catch (_) {}
      AppDatabase.notifyAllChanged();
      PresenceService.stop();
      // Phase 0 — Sentry : on oublie l'utilisateur ET la boutique au logout
      // (les events suivants ne doivent pas être attribués au compte précédent).
      Sentry.configureScope((scope) {
        scope.setUser(null);
        scope.removeTag('shop_id');
      });
    }
    if (wasAuth != _isAuthenticated || justInitialized) notifyListeners();
  }

  /// Synchronise les boutiques de l'utilisateur (incluant status/suspension)
  /// dans Hive. Bloque jusqu'à completion pour que getShop() soit à jour.
  Future<void> _syncUserShops() async {
    try {
      await AppDatabase.getMyShops();
    } catch (_) {}
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
    initialLocation: RouteNames.landing,
    refreshListenable: notifier, // ← le router se rafraîchit quand notifier change
    // Phase 0 — SentryNavigatorObserver RÉACTIVÉ : pose le nom de la route
    // courante (cible « écran ») sur chaque event + breadcrumbs de navigation.
    // (Désactivé un temps pendant le debug du gel logout ; la cause réelle
    // était le signOut bloquant — corrigée. La déconnexion redirige désormais
    // en une seule navigation, l'observer ne s'emballe plus.)
    observers: [SentryNavigatorObserver(setRouteNameAsTransaction: true)],
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
      // Phase 1 observabilité — cible « écran » des rapports de bugs.
      ErrorReporter.lastRoute = loc;
      final isAuthRoute          = loc.startsWith('/auth');
      final isSubscriptionRoute  = loc.startsWith('/subscription');
      final isAcceptInviteRoute  = loc.startsWith('/accept-invite');
      final isCatalogueRoute     = loc.startsWith('/catalogue/');
      final isTrackRoute         = loc.startsWith('/track/');
      final isPromoRoute         = loc.startsWith('/promo/');
      // Routes marketing publiques (`/` landing + `/pricing`). Toujours
      // accessibles sans auth ; un utilisateur loggé qui les visite est
      // redirigé vers sa destination habituelle (dashboard / shop-selector).
      final isLandingRoute       = loc == RouteNames.landing;
      final isPricingRoute       = loc == RouteNames.pricing;
      final isPublicMarketing    = isLandingRoute || isPricingRoute;
      // Onboarding routes (PR-1) : slides marketing + auth choice +
      // register simplifié + wizard boutique. Toutes accessibles sans
      // auth — un visiteur 1ʳᵉ ouverture est explicitement envoyé ici
      // par le redirect ci-dessous quand `onboarding_seen` est absent.
      final isOnboardingRoute    = loc.startsWith('/onboarding');

      // ── /accept-invite : page publique, jamais rediriger ───────────
      // Gère elle-même l'état (invité/connecté/mauvais compte)
      if (isAcceptInviteRoute) return null;
      // ── /catalogue/:shopId : vitrine publique sans auth ────────────
      if (isCatalogueRoute) return null;
      // ── /track/:orderId : suivi de commande public sans auth ───────
      if (isTrackRoute) return null;
      // ── /promo/:shopId/:campaignId : vitrine promo publique ────────
      if (isPromoRoute) return null;
      // ── / et /pricing : pages marketing publiques sans auth.
      // Pour les visiteurs anonymes → on laisse passer. Pour les utilisateurs
      // déjà loggés, le bloc plus bas (`CAS 3 — Abonnement actif : isAuthRoute
      // → dashboard direct`) ne s'applique pas (ils ne sont pas sur /auth).
      // On gère donc explicitement ici : loggé + plan chargé → postAuthDest.
      if (isPublicMarketing && !isLoggedIn) return null;

      // ── Inscription en cours : ne pas détourner /auth/* ────────────
      // Pendant le tunnel d'inscription, l'auto-login post-signup rend la
      // session active ; sans ce garde, le redirect enverrait /auth/register
      // vers /subscription (plan pas encore actif + 0 boutique) avant que le
      // tunnel ait créé la boutique puis déconnecté. cf. registration_flag.
      if (isAuthRoute && registrationInProgress) return null;

      // ── Boot : check session pas encore terminé ────────────────────
      // Au refresh navigateur, AuthBloc évalue la session Supabase de
      // façon asynchrone. Tant que ce check n'a pas émis de résultat,
      // on n'a pas le droit de rediriger : sinon l'utilisateur connecté
      // est envoyé sur /login alors que sa session est valide.
      if (!notifier.initialized) return null;

      // ── Non connecté ───────────────────────────────────────────────
      if (!isLoggedIn) {
        // /onboarding/* et /auth/* sont publics par construction.
        if (isOnboardingRoute) return null;
        if (isAuthRoute)       return null;
        // Les slides d'intro ne sont PLUS un tunnel pré-login : elles
        // s'affichent uniquement après la 1ʳᵉ connexion d'un compte (flag
        // serveur, cf. branche connectée + hotfix_099). Un visiteur anonyme
        // sur une route protégée va donc directement au login.
        return RouteNames.login;
      }

      // ── Connecté : lire le plan (peut être null pendant le chargement) ─
      final plan = ref.read(subscriptionProvider).valueOrNull;

      // Plan pas encore chargé → ne pas rediriger (évite le flash)
      if (plan == null) return null;

      // ── Compte bloqué par le super-admin → écran dédié (priorité haute) ──
      // get_user_plan.is_blocked reflète prof_status='blocked' (hotfix_106).
      // Le SA n'est jamais bloqué ; il conserve l'accès pour gérer le blocage.
      if (!plan.isSuperAdmin && plan.isBlocked) {
        return loc == RouteNames.blocked ? null : RouteNames.blocked;
      }
      if (loc == RouteNames.blocked) {
        // Plus bloqué (ou super-admin) → ressortir vers la destination normale.
        return postAuthDestination();
      }

      // ── Boutique suspendue / membre suspendu → écran dédié ──────────
      // Même mécanisme que le blocage (redirect, fiable). Les données
      // (status boutique + statut membership) sont rafraîchies au login
      // AVANT notifyListeners (cf. _syncUserShops / _syncMemberships).
      if (!plan.isSuperAdmin) {
        final suspUid = Supabase.instance.client.auth.currentUser?.id;
        bool suspendedFor(String sid) {
          if (sid.isEmpty) return false;
          final shopSusp = LocalStorageService.getShop(sid)?.isSuspended ?? false;
          final memberSusp = suspUid != null &&
              AppDatabase.getMembershipStatus(suspUid, sid) == 'suspended';
          return shopSusp || memberSusp;
        }
        if (loc.startsWith('${RouteNames.suspended}/')) {
          final parts = loc.split('/');
          final sid = parts.length >= 3 ? parts[2] : '';
          return suspendedFor(sid) ? null : '/shop/$sid/dashboard';
        }
        if (loc.startsWith('/shop/')) {
          final parts = loc.split('/');
          final sid = parts.length >= 3 ? parts[2] : '';
          if (suspendedFor(sid)) return '${RouteNames.suspended}/$sid';
        }
      }

      // ── Garde super-admin (défense en profondeur, hotfix 2026-06-06) ──
      // Le serveur refuse déjà toute RPC SA (_is_super_admin) et la RLS
      // masque les données, mais SANS ce garde un utilisateur NON-SA muni
      // d'un plan actif (ou en mode dégradé) pouvait charger la page
      // `/super-admin` (ou `/admin`) en tapant l'URL — la redirection
      // retombait sur `null` plus bas. On le renvoie vers sa destination
      // normale. La confinement RÉCIPROQUE (SA hors de sa zone) est géré
      // par le CAS 1 ci-dessous.
      if (!plan.isSuperAdmin &&
          (loc.startsWith('/super-admin') || loc.startsWith('/admin'))) {
        return postAuthDestination();
      }

      // ── Slides d'intro : UNE FOIS par compte, à la 1ʳᵉ connexion ────
      // Flag serveur profiles.onboarding_slides_seen (hotfix_099), chargé au
      // login dans AuthRouterNotifier. Le super admin n'a pas de tunnel
      // onboarding. On N'INTERROMPT PAS le tunnel d'inscription /onboarding/*
      // (register simplifié + wizard boutique) : les slides s'afficheront
      // quand l'utilisateur arrive sur une vraie route applicative.
      // `null` = en chargement → attendre (pas de flash). `false` = compte
      // neuf → slides. `true` = déjà vu.
      if (!plan.isSuperAdmin) {
        final slidesSeen = ref.read(onboardingSlidesSeenProvider);
        // Les slides d'intro s'affichent UNIQUEMENT à la fin de la création
        // de compte : le flux d'inscription (RegisterPage / wizard onboarding)
        // navigue EXPLICITEMENT vers `/onboarding/slides`. On ne FORCE plus
        // les slides via le redirect — un compte existant qui se (re)connecte
        // ne doit jamais les revoir. Seul garde-fou conservé : si on atterrit
        // sur la page slides alors qu'elles sont déjà vues (refresh / retour
        // arrière), on entre directement dans l'app.
        if (loc == RouteNames.onboardingSlides && slidesSeen == true) {
          return postAuthDestination();
        }
      }

      // ── CAS 1 — Super Admin ────────────────────────────────────────
      if (plan.isSuperAdmin) {
        if (isAuthRoute) return RouteNames.superAdminHome;
        // Le super admin peut prévisualiser les pages marketing publiques
        // (utile pour vérifier le rendu live avant communication externe).
        final allowed = loc.startsWith('/super-admin') ||
            loc.startsWith('/admin') ||
            loc.startsWith('/subscription') ||
            isPublicMarketing;
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

      // ── CAS 3 — Abonnement actif : auth route OU landing → dashboard
      // direct si 1 boutique, sinon shop-selector (cf. postAuthDestination).
      // Pour `/pricing` on laisse le user loggé y rester librement —
      // utile pour comparer les plans avant upgrade.
      if (isAuthRoute || isLandingRoute) return postAuthDestination();

      return null;
    },
    routes: [
      // ── Pages marketing publiques (sans auth, sans shell) ─────────
      GoRoute(path: RouteNames.landing,
          builder: (c, s) => const LandingPage()),
      GoRoute(path: RouteNames.pricing,
          builder: (c, s) => const PricingPage()),

      // Vitrine publique d'une campagne promo/nouveautés (cf. hotfix_068).
      GoRoute(path: '/promo/:shopId/:campaignId',
          builder: (c, s) => PromoShowcasePage(
                shopId:     s.pathParameters['shopId']!,
                campaignId: s.pathParameters['campaignId']!,
              )),

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
            final loc = qp['loc']?.trim();
            final deliveryMode = qp['mode']?.trim() == 'delivery';
            return CataloguePage(
              shopId: s.pathParameters['shopId']!,
              initialCategory: qp['cat'],
              productIds: (ids != null && ids.isNotEmpty) ? ids : null,
              stockOverride: stockOverride,
              locationId: (loc != null && loc.isNotEmpty) ? loc : null,
              deliveryMode: deliveryMode,
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
      GoRoute(path: RouteNames.blocked,         builder: (c, s) => const BlockedAccountScreen()),
      GoRoute(path: '/suspended/:shopId', builder: (c, s) {
        final sid = s.pathParameters['shopId'] ?? '';
        final shop = LocalStorageService.getShop(sid);
        final reason = (shop?.isSuspended ?? false)
            ? shop?.suspendedReason
            : 'Votre accès à cette boutique a été suspendu par un administrateur.';
        return SuspendedShopScreen(reason: reason);
      }),
      // Onboarding 1ʳᵉ ouverture (PR-1).
      GoRoute(path: RouteNames.onboardingSlides,
          builder: (c, s) => const OnboardingSlidesPage()),
      GoRoute(path: RouteNames.onboardingAuthChoice,
          builder: (c, s) => const AuthChoicePage()),
      GoRoute(path: RouteNames.onboardingRegister,
          builder: (c, s) => const RegisterSimplifiedPage()),
      // Wizard boutique (PR-2) — 3 étapes + sélecteur palette.
      GoRoute(path: RouteNames.onboardingShop,
          builder: (c, s) => const ShopOnboardingWizard()),
      GoRoute(path: RouteNames.adminPanel,      builder: (c, s) => const AdminPanelPage()),
      GoRoute(path: RouteNames.superAdminHome,  builder: (c, s) => const SuperAdminPage()),
      GoRoute(path: RouteNames.adminSubscriptions,
          builder: (c, s) => const AdminSubscriptionsPage()),
      GoRoute(path: '/super-admin/plans',
          builder: (c, s) => const PlansPage()),
      GoRoute(path: RouteNames.superAdminBroadcast,
          builder: (c, s) => const BroadcastPage()),
      GoRoute(path: RouteNames.superAdminStats,
          builder: (c, s) => const PlatformStatsPage()),
      GoRoute(path: RouteNames.superAdminIncidents,
          builder: (c, s) => const PlatformIncidentsPage()),
      GoRoute(path: RouteNames.superAdminExport,
          builder: (c, s) => const PlatformExportPage()),
      // Hub « Éléments supprimés » (super-admin) — tabs Commandes/Produits.
      // Les 3 paths pointent vers le même hub, seul l'onglet initial diffère.
      // Le guard d'accès est porté par la page elle-même (currentPlanProvider)
      // + la RLS Supabase qui ne renvoie 0 ligne à tout non super-admin.
      GoRoute(path: RouteNames.superAdminDeletedHub,
          builder: (c, s) => const SuperAdminDeletedHubPage()),
      GoRoute(path: RouteNames.superAdminDeletedOrders,
          builder: (c, s) =>
              const SuperAdminDeletedHubPage(initialTab: 0)),
      GoRoute(path: RouteNames.superAdminDeletedProducts,
          builder: (c, s) =>
              const SuperAdminDeletedHubPage(initialTab: 1)),
      // Anciennes routes — redirigent vers le hub pour ne pas casser les
      // bookmarks éventuels (un onglet est forcé pour préserver l'intention).
      GoRoute(path: RouteNames.superAdminDeletedOrdersLegacy,
          redirect: (_, __) => RouteNames.superAdminDeletedOrders),
      GoRoute(path: RouteNames.superAdminDeletedProductsLegacy,
          redirect: (_, __) => RouteNames.superAdminDeletedProducts),
      // Note : `DeletedOrdersPage` et `DeletedProductsPage` (les
      // standalone Scaffold) ne sont plus exposées en route, mais leurs
      // widgets `DeletedOrdersBody` / `DeletedProductsBody` sont
      // utilisés directement par le hub. Les imports restent pour
      // documenter la disponibilité des pages standalone si un futur
      // contexte (deeplink direct sans hub) en a besoin.
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
          // Au niveau d'un ShellRoute, state.pathParameters['shopId'] est
          // souvent VIDE (le param appartient à la sous-route). On l'extrait
          // donc du chemin /shop/<id>/… pour que les gardes (boutique
          // suspendue / membre suspendu) reçoivent le bon shopId.
          final segs = state.uri.pathSegments;
          final shopId = (segs.length >= 2 && segs.first == 'shop')
              ? segs[1]
              : (state.pathParameters['shopId'] ?? '');
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
          // Quick-add produit 3 champs (PR-2 onboarding). Builder direct
          // (pas pageBuilder) car la page utilise son propre Scaffold +
          // AppBar et ne doit pas être imbriquée dans le shell.
          GoRoute(path: '/shop/:shopId/inventaire/quick-add',
              builder: (c, s) => ProductQuickAddPage(
                  shopId: s.pathParameters['shopId']!)),
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
              pageBuilder: (c, s) {
                final tab = s.uri.queryParameters['tab'];
                // ValueKey dépendante du `tab` : state.pageKey est basée
                // sur le PATH uniquement → sans cette key, changer de
                // sous-menu Finances (?tab=X) ne recrée pas la page et
                // l'onglet ne bascule pas. La key force Flutter à
                // reconstruire FinancesPage avec le bon initialTab.
                return _shellPage(s,
                  FinancesPage(
                    key:        ValueKey('finances-${tab ?? 'revenus'}'),
                    shopId:     s.pathParameters['shopId']!,
                    initialTab: tab,
                  ));
              }),
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
          // Redirige vers /parametres/shop?tab=members (SANS with_overview=1).
          // ShopSettingsPage rend EmployeesPage quand showOverviewTab=false
          // (= pas de with_overview en query). Mettre with_overview=1 ferait
          // afficher la vue Boutique → l'utilisateur ne voit pas Membres et
          // le bouton « + » de la topbar (gated sur tab=members) ne s'ouvre
          // sur rien d'utile.
          GoRoute(path: '/shop/:shopId/parametres/users',
              redirect: (ctx, s) =>
                  '/shop/${s.pathParameters['shopId']!}/parametres/shop'
                  '?tab=members'),
          GoRoute(path: '/shop/:shopId/parametres/security-history',
              builder: (c, s) => SecurityHistoryPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/parametres/profile',
              builder: (c, s) => UserProfilePage(
                  shopId: s.pathParameters['shopId'])),
          // Pages globales accessibles via le menu « 3 points » de la topbar.
          GoRoute(path: '/shop/:shopId/aide',
              builder: (c, s) => AidePage(
                  shopId: s.pathParameters['shopId'])),
          GoRoute(path: '/shop/:shopId/apropos',
              builder: (c, s) => AProposPage(
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
          GoRoute(path: '/shop/:shopId/parametres/text-size',
              builder: (c, s) => TextSizePage(
                  shopId: s.pathParameters['shopId'])),
          GoRoute(path: '/shop/:shopId/parametres/caisse',
              builder: (c, s) => CaisseConfigPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/parametres/whatsapp-templates',
              builder: (c, s) => WhatsappTemplatesPage(
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
          GoRoute(path: '/shop/:shopId/parametres/exports',
              builder: (c, s) => ExportsPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/parametres/sessions',
              builder: (c, s) => SessionsPage(
                  shopId: s.pathParameters['shopId']!)),

          // ── Campagnes marketing (promotions + nouveautés) ──────────
          GoRoute(path: '/shop/:shopId/campaigns',
              builder: (c, s) => CampaignsPage(
                  shopId: s.pathParameters['shopId']!)),
          GoRoute(path: '/shop/:shopId/campaigns/:campaignId/send',
              builder: (c, s) => CampaignSendPage(
                    shopId:     s.pathParameters['shopId']!,
                    campaignId: s.pathParameters['campaignId']!,
                  )),
        ],
      ),
    ],
  );
});

/// Statut « suspendu » RÉACTIF d'une boutique. Écoute les changements
/// AppDatabase (sync/realtime) et force un refresh serveur à l'entrée, pour
/// que le shell bascule sur SuspendedShopScreen dès qu'une suspension SA
/// arrive — y compris en cours de session. La valeur reflète getShop().
final shopSuspendedProvider =
    StreamProvider.autoDispose.family<bool, String>((ref, shopId) {
  bool read() => LocalStorageService.getShop(shopId)?.isSuspended ?? false;
  final controller = StreamController<bool>();
  controller.add(read());
  AppDatabase.refreshShop(shopId); // récupère le statut courant à l'entrée
  void listener(String table, String _) {
    if (table == 'shops' && !controller.isClosed) controller.add(read());
  }
  AppDatabase.addListener(listener);
  ref.onDispose(() {
    AppDatabase.removeListener(listener);
    controller.close();
  });
  return controller.stream;
});

/// Le MEMBRE courant est-il suspendu de cette boutique ?
/// (shop_memberships.status='suspended'). Rafraîchit les adhésions depuis le
/// serveur à l'entrée. L'owner n'est jamais suspendu ainsi (set_employee_status
/// le refuse) → seul un employé suspendu est bloqué de la boutique.
final membershipSuspendedProvider =
    FutureProvider.autoDispose.family<bool, String>((ref, shopId) async {
  final uid = Supabase.instance.client.auth.currentUser?.id
      ?? LocalStorageService.getCurrentUser()?.id;
  if (uid == null) return false;
  try {
    await AppDatabase.syncMemberships(uid);
  } catch (_) {}
  return AppDatabase.getMembershipStatus(uid, shopId) == 'suspended';
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
    // ── Guard suspension (SA-1) ───────────────────────────────────────
    // Si la boutique courante a été suspendue par le super-admin, on
    // bloque TOUT le contenu derrière un écran « Compte suspendu ». Les
    // super-admins passent (ils doivent pouvoir gérer la suspension).
    // Réactif : rebuild dès que le statut de la boutique change (suspension SA
    // poussée par sync/realtime), et force un refresh serveur à l'entrée.
    ref.watch(shopSuspendedProvider(shopId));
    final shop    = LocalStorageService.getShop(shopId);
    final isSuper = LocalStorageService.getCurrentUser()?.isSuperAdmin ?? false;
    if (shop != null && shop.isSuspended && !isSuper) {
      return SuspendedShopScreen(reason: shop.suspendedReason);
    }
    // Membre (employé) suspendu de cette boutique → accès bloqué.
    final memberSuspended =
        ref.watch(membershipSuspendedProvider(shopId)).valueOrNull ?? false;
    if (memberSuspended && !isSuper) {
      return const SuspendedShopScreen(
          reason:
              'Votre accès à cette boutique a été suspendu par un administrateur.');
    }

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

  /// Bouton « + » conditionnel dans la topbar shell. Désormais renvoie
  /// toujours null : Inventaire / CRM / Membres ont leur propre FAB
  /// inline en bas à droite de leur page (évite le doublon UI).
  static List<Widget>? _topbarActionsFor(
      BuildContext context, String loc, String shopId, String? tabQuery) {
    return null;
  }
}