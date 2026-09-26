import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'core/router/app_router.dart';
import 'core/database/app_database.dart';
import 'core/services/deep_link_service.dart';
import 'core/services/session_service.dart';
import 'shared/widgets/app_snack.dart';
import 'core/router/route_names.dart';
import 'features/auth/presentation/bloc/auth_event.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/theme_palette.dart';
import 'core/theme/theme_mode_provider.dart';
import 'core/di/injection_container.dart';
import 'core/i18n/app_localizations.dart';
import 'shared/providers/auth_provider.dart';
import 'features/auth/presentation/bloc/auth_bloc.dart';
import 'features/auth/presentation/bloc/auth_state.dart';
import 'features/shop_selector/presentation/bloc/shop_selector_bloc.dart';
import 'features/caisse/presentation/bloc/caisse_bloc.dart';
import 'features/hub_central/presentation/bloc/hub_bloc.dart';
import 'shared/widgets/alerts/scheduled_alerts_overlay.dart';
import 'shared/widgets/demo_tap_indicator.dart';
import 'features/hr/data/providers/employees_provider.dart'
    show permissionsSignalProvider;
import 'core/services/notification_service.dart';
import 'core/services/stock_service.dart';
import 'core/providers/demo_mode_provider.dart';
import 'core/providers/text_scale_provider.dart';

// ConsumerStatefulWidget — les blocs sont créés UNE SEULE FOIS dans initState
// évite la recréation de BlocProvider à chaque rebuild → plus de Duplicate GlobalKey
class PosApp extends ConsumerStatefulWidget {
  const PosApp({super.key});
  @override
  ConsumerState<PosApp> createState() => _PosAppState();
}

class _PosAppState extends ConsumerState<PosApp>
    with WidgetsBindingObserver {
  // Blocs créés une seule fois — stables pour toute la durée de vie de l'app
  late final ShopSelectorBloc _shopSelectorBloc;
  late final CaisseBloc        _caisseBloc;
  late final HubBloc           _hubBloc;

  @override
  void initState() {
    super.initState();
    // Observateur de cycle de vie GLOBAL : au retour de l'app au premier
    // plan (onglet web ré-affiché / téléphone déverrouillé), on force un
    // re-sync immédiat des commandes. Sans ça, le websocket Realtime
    // suspendu en arrière-plan ne livre la validation client qu'après un
    // long délai (cf. AppDatabase.onAppResumed).
    WidgetsBinding.instance.addObserver(this);
    _shopSelectorBloc = ShopSelectorBloc(
      getMyShopsUseCase: ref.read(getMyShopsUseCaseProvider),
      createShopUseCase: ref.read(createShopUseCaseProvider),
      updateShopUseCase: ref.read(updateShopUseCaseProvider),
    );
    _caisseBloc = CaisseBloc();
    _hubBloc    = ref.read(hubBlocProvider);

    // RELIRE SES DROITS QUAND LE RÉSEAU REVIENT.
    //
    // `_onNetworkRestored` notifie `shop_memberships` après une coupure : les
    // permissions ont pu être modifiées pendant qu'on ne regardait pas. Le
    // provider ne sait pas se redemander tout seul, c'est ce compteur qui l'y
    // oblige.
    AppDatabase.addListener(_onPermissionsMayHaveChanged);

    // Écoute les deep-links (fortress://reset-password, universal links)
    // une fois le router construit — ref.read est sûr dans addPostFrameCallback.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DeepLinkService.init(ref.read(appRouterProvider));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // Fire-and-forget : ne bloque pas le thread UI au réveil.
      // ignore: discarded_futures
      AppDatabase.onAppResumed();
      // Le second des deux moments où l'on relit ses droits. Sur le web,
      // c'est le retour sur l'onglet — l'instant exact où quelqu'un revient
      // après qu'on a pu modifier ses permissions ailleurs.
      _bumpPermissions();
    }
  }

  /// Relit les permissions de l'utilisateur courant au prochain rendu.
  void _bumpPermissions() {
    if (!mounted) return;
    ref.read(permissionsSignalProvider.notifier).state++;
  }

  void _onPermissionsMayHaveChanged(String table, String shopId) {
    if (table == 'shop_memberships') _bumpPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppDatabase.removeListener(_onPermissionsMayHaveChanged);
    DeepLinkService.dispose();
    _shopSelectorBloc.close();
    _caisseBloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locale   = ref.watch(localeProvider);
    final palette  = ref.watch(themePaletteProvider);
    final themeMode = ref.watch(themeModeProvider);
    // Applique les couleurs primaires globales AVANT de construire l'UI —
    // tous les widgets qui lisent AppColors.primary verront la bonne couleur
    // au prochain build.
    AppColors.applyPalette(palette);
    // ── Mode sombre ACTIF (opt-in via Paramètres → Thème) ─────────────
    // Le thème dark complet existe (AppTheme.dark + tokens brightness-aware).
    // On résout le brightness EFFECTIVEMENT affiché (light / dark / système)
    // et on l'applique aux tokens AppColors AVANT le build, afin que les
    // widgets qui lisent AppColors.surface/inputFill/… obtiennent la bonne
    // couleur sans passer par Theme.of(context). MaterialApp.router reçoit le
    // même `themeMode` → cohérence parfaite des deux côtés.
    // NB : certaines pages feature ont encore des couleurs en dur à migrer ;
    // le sombre s'améliore au fur et à mesure de cette migration.
    final effectiveBrightness = switch (themeMode) {
      ThemeMode.light  => Brightness.light,
      ThemeMode.dark   => Brightness.dark,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };
    AppColors.applyBrightness(effectiveBrightness);
    final notifier = ref.watch(authRouterNotifierProvider);
    final authBloc = ref.watch(authBlocProvider);
    final router   = ref.watch(appRouterProvider);
    // Taille de texte réglable par l'utilisateur (Paramètres → Taille du
    // texte). Observée ici pour que tout changement reconstruise l'app et
    // redimensionne le texte EN DIRECT (aperçu instantané).
    final userTextScale = ref.watch(textScaleProvider);
    // Mode démo observé au PREMIER niveau : indispensable pour que basculer
    // l'interrupteur reconstruise l'app et (dés)active le détecteur de clic +
    // le ripple amplifié. (Le `ref.watch` à l'intérieur du builder ne suffit
    // pas à abonner PosApp.)
    final demoEnabled = ref.watch(demoModeProvider);

    return MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: authBloc),
        // .value() — on passe les instances créées dans initState
        // elles ne sont JAMAIS recréées lors des rebuilds
        BlocProvider<ShopSelectorBloc>.value(value: _shopSelectorBloc),
        BlocProvider<CaisseBloc>.value(value: _caisseBloc),
        BlocProvider<HubBloc>.value(value: _hubBloc),
      ],
      child: BlocListener<AuthBloc, AuthState>(
        bloc: authBloc,
        listener: (context, state) {
          notifier.update(state);
          if (state is AuthAuthenticated) {
            // Positionne le scope notifications du compte authentifié.
            // Le `shopId` est complété plus tard par `AdaptiveScaffold`
            // (au premier rendu du shell). Sans ça, une notif émise
            // entre login et entrée shell serait taguée userId mais
            // shopId=null → invisible (acceptable).
            NotificationService.setCurrentScope(userId: state.user.id);
            // Démarre heartbeat + listener kick. Le callback `onKicked`
            // affiche un snack, force le logout et redirige vers /login.
            SessionService.start(onKicked: () {
              if (!context.mounted) return;
              AppSnack.warning(context,
                  'Vous avez été déconnecté car une nouvelle session a '
                  'été ouverte sur un autre appareil.');
              authBloc.add(AuthLogoutRequested());
              try {
                ref.read(appRouterProvider).go(RouteNames.login);
              } catch (_) {}
            });
            // Audit stock au boot (Couche 3) — silent + idempotent (1×/session).
            // Délai 10s : laisse Hive monter en cache et la 1re vague de sync
            // Supabase Realtime s'absorber, sinon les pushes remote ressemblent
            // à des "écritures externes" et produisent des faux drifts.
            Future.delayed(const Duration(seconds: 10),
                StockService.runBootReconciliation);
          } else if (state is AuthUnauthenticated) {
            SessionService.stop();
            // Purge le scope notifications — empêche la cloche d'un autre
            // compte de réafficher l'inbox du précédent sur le même device.
            NotificationService.onLogout();
          }
        },
        child: MaterialApp.router(
          title: 'Fortress',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(palette: palette),
          darkTheme: AppTheme.dark(palette: palette),
          themeMode: themeMode,
          routerConfig: router,
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // Échelle de texte BORNÉE et cohérente :
          //  - l'échelle typo (AppTextStyles) est calibrée en px réels avec
          //    la police Inter embarquée → mêmes tailles partout.
          //  - on respecte le réglage d'accessibilité de l'OS, mais clampé
          //    entre 1.0 (taille de design, jamais plus petit) et 1.20
          //    (jamais assez grand pour casser la mise en page / déborder).
          // Remplace l'ancien gonflage fixe ×1.15 (qui ignorait l'OS et
          // rendait les textes trop grands vs l'échelle recalibrée).
          // Wrap : `ScheduledAlertsOverlay` watch le Stream global du
          // service d'alertes commandes programmées et pousse la modal
          // automatiquement quand un niveau ≥ CRITICAL est atteint. Placé
          // ici pour avoir un Navigator/Overlay ancestor disponible (le
          // builder du MaterialApp.router est juste au-dessus du shell).
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            // Plancher 1.10 : sur web/desktop le réglage OS = 1.0, ce qui
            // rendait le texte un peu petit. On garantit un léger
            // grossissement uniforme tout en respectant un OS plus grand
            // jusqu'au plafond 1.30 (au-delà ça casse la mise en page).
            final clamped = mq.textScaler.clamp(
              minScaleFactor: 1.10,
              maxScaleFactor: 1.30,
            );
            // Taille de texte choisie par l'utilisateur (réactive). On
            // multiplie l'échelle effective (OS + clamp) par ce facteur —
            // façon globale d'agrandir/réduire le texte sans toucher chaque
            // style AppTextStyles. Aperçu instantané (cf. userTextScale watché).
            final boosted =
                TextScaler.linear(clamped.scale(1.0) * userTextScale);
            // Mode démo (enregistrements promo) : on amplifie le splash
            // Material via un sur-thème local. Chaque InkWell / ListTile /
            // bouton de l'app utilise alors un ripple violet bien visible,
            // exactement à l'endroit où l'utilisateur a tapé. Aucun cercle
            // sur les labels / espaces vides / pendant les scrolls : la
            // mécanique du splash Material gère déjà ces cas par défaut.
            final demo = demoEnabled; // valeur observée au 1er niveau (réactif)
            Widget content = ScheduledAlertsOverlay(
              child: child ?? const SizedBox.shrink(),
            );
            if (demo) {
              final base = Theme.of(context);
              content = Theme(
                data: base.copyWith(
                  splashFactory: InkRipple.splashFactory,
                  splashColor:
                      AppColors.primary.withValues(alpha: 0.55),
                  highlightColor:
                      AppColors.primary.withValues(alpha: 0.30),
                ),
                child: content,
              );
            }
            // Repère de tap GLOBAL : un cercle apparaît à chaque appui, pile
            // où le doigt touche (tous les éléments, pas seulement Material) —
            // pour savoir exactement quelle action est déclenchée à
            // l'enregistrement d'écran.
            content = DemoTapIndicator(
              enabled: demo,
              color: AppColors.primary,
              child: content,
            );
            return MediaQuery(
              data: mq.copyWith(textScaler: boosted),
              child: content,
            );
          },
        ),
      ),
    );
  }
}