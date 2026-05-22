import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'core/router/app_router.dart';
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
import 'core/services/notification_service.dart';
import 'core/services/stock_service.dart';
import 'features/onboarding/presentation/providers/onboarding_seen_provider.dart';

// ConsumerStatefulWidget — les blocs sont créés UNE SEULE FOIS dans initState
// évite la recréation de BlocProvider à chaque rebuild → plus de Duplicate GlobalKey
class PosApp extends ConsumerStatefulWidget {
  const PosApp({super.key});
  @override
  ConsumerState<PosApp> createState() => _PosAppState();
}

class _PosAppState extends ConsumerState<PosApp> {
  // Blocs créés une seule fois — stables pour toute la durée de vie de l'app
  late final ShopSelectorBloc _shopSelectorBloc;
  late final CaisseBloc        _caisseBloc;
  late final HubBloc           _hubBloc;

  @override
  void initState() {
    super.initState();
    _shopSelectorBloc = ShopSelectorBloc(
      getMyShopsUseCase: ref.read(getMyShopsUseCaseProvider),
      createShopUseCase: ref.read(createShopUseCaseProvider),
      updateShopUseCase: ref.read(updateShopUseCaseProvider),
    );
    _caisseBloc = CaisseBloc();
    _hubBloc    = ref.read(hubBlocProvider);

    // Amorçage du cache `onboarding_seen` (PR-1). Lu en async depuis
    // SharedPreferences puis rendu disponible synchroniquement au
    // `redirect` GoRouter pour décider d'afficher les slides marketing
    // au tout premier lancement.
    // ignore: discarded_futures
    primeOnboardingSeenCache(ref);

    // Écoute les deep-links (fortress://reset-password, universal links)
    // une fois le router construit — ref.read est sûr dans addPostFrameCallback.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DeepLinkService.init(ref.read(appRouterProvider));
    });
  }

  @override
  void dispose() {
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
    // Brightness effectif (themeMode résolu) → tokens de surface
    // brightness-aware (AppColors.surface/background/inputFill/divider…).
    // Sans ça, les widgets qui lisent ces tokens restent clairs en sombre.
    final effectiveBrightness = switch (themeMode) {
      ThemeMode.light  => Brightness.light,
      ThemeMode.dark   => Brightness.dark,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };
    AppColors.applyBrightness(effectiveBrightness);
    final notifier = ref.watch(authRouterNotifierProvider);
    final authBloc = ref.watch(authBlocProvider);
    final router   = ref.watch(appRouterProvider);

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
            return MediaQuery(
              data: mq.copyWith(textScaler: clamped),
              child: ScheduledAlertsOverlay(
                child: child ?? const SizedBox.shrink(),
              ),
            );
          },
        ),
      ),
    );
  }
}