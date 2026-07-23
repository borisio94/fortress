import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/restaurant_mode.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/router/registration_flag.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/country_phone_data.dart';
import '../../../../core/validators/input_validators.dart';
import '../../../../core/validators/password_policy.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/auth_fields.dart';
import '../../../../shared/widgets/language_switcher.dart';
import '../../../../shared/widgets/phone_field.dart';
import '../../../shop_selector/domain/usecases/create_shop_usecase.dart';
import '../../../shop_selector/presentation/bloc/shop_selector_bloc.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';

// Steps découpés en `part of` pour respecter le cap 400 lignes/fichier
// (CLAUDE.md). Le state `_RegisterPageState` reste privé mais accessible
// aux 3 step widgets via la library implicite. Voir register_step_*.dart.
part '../widgets/register_step_account.dart';
part '../widgets/register_step_shop.dart';
part '../widgets/register_step_recap.dart';

// ═════════════════════════════════════════════════════════════════════════════
// RegisterPage — tunnel self-service en 3 étapes :
//   ① Compte    : nom, email, téléphone E.164, password + confirmation
//   ② Boutique  : nom, secteur (6 valeurs), adresse / ville
//   ③ Récap     : résumé + CTA « Démarrer mon essai 14 jours »
//
// Submit étape 3 :
//   1. Dispatch `AuthSignUpAutoLoginRequested` (cf. auth_bloc — variante
//      qui n'appelle PAS `logoutUseCase`, donc session active après signup).
//   2. BlocListener AuthAuthenticated → dispatch `CreateShopRequested`.
//   3. BlocListener ShopCreated → `context.go('/shop/{id}/dashboard')`.
//   4. Fallback ShopSelectorError → `context.go('/shop-selector/create')`
//      pour que l'utilisateur retente manuellement (compte est créé OK,
//      pas de rollback).
//
// Mapping pays/devise : auto-déduit du téléphone E.164 saisi (cohérent
// avec `_countryFromPhone` de CreateShopPage). Pas de champ explicite.
// ═════════════════════════════════════════════════════════════════════════════

// Choix DÉFINITIF, non modifiable après création (cf. kCreationSectors).
// Les secteurs legacy restent valides en base mais ne sont plus proposés.
const _kSectors = <_SectorOption>[
  _SectorOption('ecommerce',   'E-commerce'),
  _SectorOption('restaurant',  'Restaurant / Café'),
  _SectorOption('fastfood',    'Fast-food'),
];

const _countryCurrency = <String, String>{
  'CM': 'XAF', 'TD': 'XAF', 'CF': 'XAF', 'CG': 'XAF', 'GA': 'XAF', 'GQ': 'XAF',
  'SN': 'XOF', 'CI': 'XOF', 'BF': 'XOF', 'ML': 'XOF', 'NE': 'XOF', 'TG': 'XOF',
  'BJ': 'XOF', 'GW': 'XOF',
  'NG': 'NGN', 'GH': 'GHS', 'MA': 'MAD', 'TN': 'TND',
  'FR': 'EUR', 'BE': 'EUR', 'DE': 'EUR', 'IT': 'EUR', 'ES': 'EUR',
  'US': 'USD', 'CA': 'CAD', 'GB': 'GBP',
};

String _countryFromPhone(String? phone) {
  if (phone == null || phone.isEmpty) return 'CM';
  final sorted = kCountries.toList()
    ..sort((a, b) => b.dialCode.length.compareTo(a.dialCode.length));
  for (final c in sorted) {
    if (phone.startsWith(c.dialCode)) return c.isoCode;
  }
  return 'CM';
}

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});
  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _pageCtrl = PageController();
  int _step = 0; // 0 / 1 / 2

  // ── Step 1 — Compte ───────────────────────────────────────────────────
  final _namCtrl  = TextEditingController();
  final _mailCtrl = TextEditingController();
  final _telCtrl  = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confCtrl = TextEditingController();
  String  _phoneFull  = '';
  bool    _phoneValid = false;
  String? _nameError, _emailError, _passError, _confError;

  // ── Step 2 — Boutique ─────────────────────────────────────────────────
  final _shopNameCtrl    = TextEditingController();
  String  _sector        = kDefaultSector;
  String? _shopNameError;

  bool   _isOnline = true;

  // True le temps que le bloc enchaîne signup → create-shop. Bloque les
  // taps répétés du bouton « Démarrer ».
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _checkConnectivity();
    Connectivity().onConnectivityChanged.listen((results) {
      if (mounted) setState(() => _isOnline = results.any(_isReal));
    });
    _namCtrl.addListener(() => setState(() =>
        _nameError = InputValidators.name(_namCtrl.text)));
    _mailCtrl.addListener(() => setState(() =>
        _emailError = InputValidators.email(_mailCtrl.text)));
    _passCtrl.addListener(() => setState(() {
      _passError = InputValidators.password(_passCtrl.text);
      if (_confCtrl.text.isNotEmpty) {
        _confError = _confCtrl.text != _passCtrl.text
            ? 'Mots de passe différents' : null;
      }
    }));
    _confCtrl.addListener(() => setState(() =>
        _confError = _confCtrl.text != _passCtrl.text
            ? 'Mots de passe différents' : null));
    _shopNameCtrl.addListener(() => setState(() {
      final v = _shopNameCtrl.text.trim();
      _shopNameError = v.isEmpty
          ? null
          : v.length < 2
              ? 'Minimum 2 caractères'
              : v.length > 60 ? 'Maximum 60 caractères' : null;
    }));
  }

  Future<void> _checkConnectivity() async {
    final r = await Connectivity().checkConnectivity();
    if (mounted) setState(() => _isOnline = r.any(_isReal));
  }

  static bool _isReal(ConnectivityResult x) =>
      x == ConnectivityResult.wifi
      || x == ConnectivityResult.mobile
      || x == ConnectivityResult.ethernet;

  @override
  void dispose() {
    for (final c in [_namCtrl, _mailCtrl, _telCtrl, _passCtrl, _confCtrl,
                     _shopNameCtrl]) {
      c.dispose();
    }
    _pageCtrl.dispose();
    registrationInProgress = false;
    super.dispose();
  }

  // ── Validation par étape ──────────────────────────────────────────────
  bool get _step1Valid =>
      _nameError == null &&
      _emailError == null &&
      _passError == null &&
      _confError == null &&
      _namCtrl.text.trim().length >= 2 &&
      _mailCtrl.text.trim().isNotEmpty &&
      _passCtrl.text.length >= PasswordPolicy.minLength &&
      _confCtrl.text == _passCtrl.text &&
      _phoneFull.isNotEmpty && _phoneValid;

  bool get _step2Valid =>
      _shopNameError == null &&
      _shopNameCtrl.text.trim().length >= 2;

  void _next() {
    if (_step == 0) {
      setState(() {
        _nameError  = InputValidators.name(_namCtrl.text);
        _emailError = InputValidators.email(_mailCtrl.text);
        _passError  = InputValidators.password(_passCtrl.text);
        _confError  = _confCtrl.text != _passCtrl.text
            ? 'Mots de passe différents' : null;
      });
      if (!_step1Valid) return;
    } else if (_step == 1) {
      setState(() {
        _shopNameError = _shopNameCtrl.text.trim().isEmpty
            ? 'Nom de boutique requis' : _shopNameError;
      });
      if (!_step2Valid) return;
    }
    setState(() => _step = (_step + 1).clamp(0, 2));
    _pageCtrl.animateToPage(_step,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut);
  }

  void _back() {
    if (_step == 0) {
      context.pop();
      return;
    }
    setState(() => _step = _step - 1);
    _pageCtrl.animateToPage(_step,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut);
  }

  void _submit() {
    if (_submitting) return;
    setState(() => _submitting = true);
    // Empêche le routeur de détourner /auth/register vers le paywall pendant
    // l'auto-login → création boutique → déconnexion → login.
    registrationInProgress = true;
    context.read<AuthBloc>().add(AuthSignUpAutoLoginRequested(
      name:     _namCtrl.text.trim(),
      email:    _mailCtrl.text.trim(),
      password: _passCtrl.text,
      phone:    _phoneFull.isEmpty ? null : _phoneFull,
    ));
  }

  void _createShopAfterSignUp() {
    final country  = _countryFromPhone(_phoneFull);
    final currency = _countryCurrency[country] ?? 'XAF';
    context.read<ShopSelectorBloc>().add(CreateShopRequested(
      CreateShopParams(
        name:     _shopNameCtrl.text.trim(),
        sector:   _sector,
        currency: currency,
        country:  country,
        phone:    null,
        email:    null,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primarySurface,
      body: MultiBlocListener(
        listeners: [
          BlocListener<AuthBloc, AuthState>(
            listener: (ctx, state) {
              if (state is AuthError && _submitting) {
                setState(() => _submitting = false);
                registrationInProgress = false;
                AppSnack.error(ctx, state.message);
              } else if (state is AuthAuthenticated && _submitting) {
                // Sign-up OK → enchaîne sur la création de boutique. Le
                // user est déjà authentifié côté Supabase + cache local.
                _createShopAfterSignUp();
              }
            },
          ),
          BlocListener<ShopSelectorBloc, ShopSelectorState>(
            listener: (ctx, state) {
              if (state is ShopCreated && _submitting) {
                // Nouveau flux (2026-06-06) : l'essai 14 jours est DÉJÀ activé
                // en base par le trigger create_trial_subscription. Plutôt que
                // d'enchaîner en auto-login (où get_user_plan pouvait être
                // appelé AVANT que le trial soit visible → paywall « Expiré »),
                // on déconnecte et on renvoie vers l'écran de connexion. Au
                // login suivant, le trial existe → aucun paywall.
                context.read<AuthBloc>().add(AuthLogoutRequested());
                AppSnack.success(ctx,
                    'Compte créé ! Votre essai de 14 jours est activé. '
                    'Connectez-vous pour commencer.');
                ctx.go(RouteNames.login);
                registrationInProgress = false;
              } else if (state is ShopSelectorError && _submitting) {
                // Compte créé OK mais shop KO → on envoie l'utilisateur sur
                // le formulaire create-shop classique pour qu'il retente
                // manuellement. Pas de rollback du compte (impossible
                // sans RPC dédié côté Supabase Auth).
                setState(() => _submitting = false);
                registrationInProgress = false;
                AppSnack.error(ctx,
                    'Compte créé, mais la boutique n\'a pas pu être créée : '
                    '${state.message}. Réessayez ci-dessous.');
                ctx.go(RouteNames.createShop);
              }
            },
          ),
        ],
        child: SafeArea(
          child: Stack(children: [
            // Desktop : on borne la largeur du tunnel et on le centre — sans
            // ça le contenu s'étirait sur toute la largeur de l'écran.
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(children: [
                  _ProgressHeader(step: _step),
                  Expanded(
                    child: PageView(
                      controller: _pageCtrl,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _StepAccount(state: this),
                        _StepShop(state: this),
                        _StepRecap(state: this),
                      ],
                    ),
                  ),
                  _BottomBar(state: this),
                ]),
              ),
            ),
            Positioned(
              top: 8, right: 16,
              child: LanguageSwitcher(
                  backgroundColor: Colors.white.withValues(alpha: 0.92)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _SectorOption {
  final String value;
  final String label;
  const _SectorOption(this.value, this.label);
}

// ─── Progress header ───────────────────────────────────────────────────────

class _ProgressHeader extends StatelessWidget {
  final int step;
  const _ProgressHeader({required this.step});

  @override
  Widget build(BuildContext context) {
    const titles = ['Vos infos', 'Votre boutique', 'C\'est parti !'];
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const FortressLogo.light(size: 26),
          const SizedBox(width: 8),
          Text('Fortress', style: AppTextStyles.subtitleBold),
        ]),
        const SizedBox(height: 16),
        Row(children: List.generate(3, (i) => Expanded(
          child: Container(
            height: 4,
            margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
            decoration: BoxDecoration(
                color: i <= step
                    ? AppColors.primary
                    : AppColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2)),
          ),
        ))),
        const SizedBox(height: 10),
        Text('Étape ${step + 1}/3 — ${titles[step]}',
            style: AppTextStyles.bodySmSecondary
                .copyWith(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ─── Bottom navigation bar (Précédent / Continuer / Démarrer) ──────────────

class _BottomBar extends StatelessWidget {
  final _RegisterPageState state;
  const _BottomBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final isLast = state._step == 2;
    final canForward = state._step == 0
        ? state._step1Valid
        : state._step == 1
            ? state._step2Valid
            : state._isOnline;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      decoration: BoxDecoration(
        color: AppColors.primarySurface,
        border: Border(
          top: BorderSide(
              color: AppColors.primary.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(children: [
        TextButton(
          onPressed: state._submitting ? null : state._back,
          child: Text(state._step == 0 ? 'Annuler' : 'Précédent',
              style: AppTextStyles.bodySecondary
                  .copyWith(fontWeight: FontWeight.w700)),
        ),
        const Spacer(),
        // Bouton dimensionné au CONTENU, collé à l'angle droit, texte centré
        // (demande utilisateur). `AppPrimaryButton` est content-sized par
        // défaut (fullWidth:false) → la largeur épouse le label.
        AppPrimaryButton(
          isLoading: state._submitting,
          enabled: canForward && !state._submitting,
          onTap: isLast ? state._submit : state._next,
          label: isLast
              ? 'Démarrer mon essai 14 jours'
              : 'Continuer',
        ),
      ]),
    );
  }
}

// Step widgets définis dans les fichiers `part of` en haut de ce fichier.
// _StepAccount      → widgets/register_step_account.dart
// _StepShop         → widgets/register_step_shop.dart
// _StepRecap + _RecapRow + _RecapBullet + _ErrText
//                   → widgets/register_step_recap.dart
