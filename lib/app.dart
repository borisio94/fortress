import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'core/router/app_router.dart';
import 'core/services/deep_link_service.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/theme_palette.dart';
import 'core/di/injection_container.dart';
import 'core/i18n/app_localizations.dart';
import 'shared/providers/auth_provider.dart';
import 'features/auth/presentation/bloc/auth_bloc.dart';
import 'features/auth/presentation/bloc/auth_state.dart';
import 'features/shop_selector/presentation/bloc/shop_selector_bloc.dart';
import 'features/caisse/presentation/bloc/caisse_bloc.dart';
import 'features/hub_central/presentation/bloc/hub_bloc.dart';

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
    // Applique les couleurs primaires globales AVANT de construire l'UI —
    // tous les widgets qui lisent AppColors.primary verront la bonne couleur
    // au prochain build.
    AppColors.applyPalette(palette);
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
        },
        child: MaterialApp.router(
          title: 'Fortress',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(palette: palette),
          darkTheme: AppTheme.dark(palette: palette),
          themeMode: ThemeMode.light,
          routerConfig: router,
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // Échelle du texte : 90% sur mobile / fenêtre étroite (< 900px),
          // 100% sur desktop large. Densifie l'affichage mobile sans
          // écraser le rendu desktop qui a la place pour des tailles
          // standard Material.
          builder: (context, child) {
            final isCompact =
                MediaQuery.of(context).size.width < 900;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(isCompact ? 0.9 : 1.0),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
        ),
      ),
    );
  }
}