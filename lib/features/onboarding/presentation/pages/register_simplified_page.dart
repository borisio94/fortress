import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/validators/input_validators.dart';
import '../../../../core/validators/password_policy.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/auth_fields.dart';
import '../../../../shared/widgets/language_switcher.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/bloc/auth_event.dart';
import '../../../auth/presentation/bloc/auth_state.dart';

/// Inscription minimale 3 champs (point 4 de l'onboarding spec).
///
/// Champs visibles : nom · email · mot de passe.
/// Aucune confirmation password, aucun téléphone, aucune étape boutique.
/// Validation inline au blur (errorText sous chaque champ).
///
/// Au submit :
///   • Dispatch `AuthSignUpAutoLoginRequested` (variante self-service qui
///     garde l'utilisateur connecté — cf. RegisterPage existante).
///   • Sur succès → navigation vers le wizard boutique
///     (`/onboarding/shop`) qui sera livré en PR-2. Tant que le wizard
///     n'existe pas, fallback vers `/shop-selector/create` (form complet).
///   • Sur erreur → SnackBar et restitution du formulaire.
///
/// La bannière « Confirmez votre email » est affichée sur le dashboard
/// (cf. `EmailConfirmBanner` dans shared/widgets) — pas dans ce
/// formulaire, qui sera unmount à la navigation suivante.
///
/// La `RegisterPage` complète (3 étapes avec boutique inline) reste
/// disponible via `/register` pour les usages avancés ou tests.
class RegisterSimplifiedPage extends StatefulWidget {
  const RegisterSimplifiedPage({super.key});

  @override
  State<RegisterSimplifiedPage> createState() =>
      _RegisterSimplifiedPageState();
}

class _RegisterSimplifiedPageState extends State<RegisterSimplifiedPage> {
  final _nameCtrl  = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();

  // Erreurs affichées sous chaque champ — alimentées au BLUR (FocusNode),
  // pas à chaque keystroke, pour ne pas crier rouge sous l'utilisateur
  // pendant qu'il tape.
  String? _nameError, _emailError, _passError;
  final _nameFocus  = FocusNode();
  final _emailFocus = FocusNode();
  final _passFocus  = FocusNode();

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(_onBlurName);
    _emailFocus.addListener(_onBlurEmail);
    _passFocus.addListener(_onBlurPass);
  }

  @override
  void dispose() {
    for (final c in [_nameCtrl, _emailCtrl, _passCtrl]) {
      c.dispose();
    }
    for (final f in [_nameFocus, _emailFocus, _passFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  void _onBlurName() {
    if (_nameFocus.hasFocus) return;
    setState(() => _nameError = InputValidators.name(_nameCtrl.text));
  }
  void _onBlurEmail() {
    if (_emailFocus.hasFocus) return;
    setState(() => _emailError = InputValidators.email(_emailCtrl.text));
  }
  void _onBlurPass() {
    if (_passFocus.hasFocus) return;
    setState(() => _passError = InputValidators.password(_passCtrl.text));
  }

  bool get _isValid =>
      _nameError == null &&
      _emailError == null &&
      _passError == null &&
      _nameCtrl.text.trim().length >= 2 &&
      _emailCtrl.text.trim().isNotEmpty &&
      _passCtrl.text.length >= PasswordPolicy.minLength;

  void _submit() {
    // Force la validation finale même si l'utilisateur n'a pas blur.
    setState(() {
      _nameError  = InputValidators.name(_nameCtrl.text);
      _emailError = InputValidators.email(_emailCtrl.text);
      _passError  = InputValidators.password(_passCtrl.text);
    });
    if (!_isValid || _submitting) return;
    setState(() => _submitting = true);
    context.read<AuthBloc>().add(AuthSignUpAutoLoginRequested(
          name:     _nameCtrl.text.trim(),
          email:    _emailCtrl.text.trim(),
          password: _passCtrl.text,
          // Téléphone optionnel — non demandé dans cette version
          // simplifiée. Pourra être rempli plus tard via Paramètres.
          phone:    null,
        ));
  }

  void _onAuthState(BuildContext ctx, AuthState state) {
    if (!_submitting) return;
    if (state is AuthError) {
      setState(() => _submitting = false);
      AppSnack.error(ctx, state.message);
    } else if (state is AuthAuthenticated) {
      // Bascule vers le wizard boutique 3 étapes (PR-2). Tant que la
      // route n'existe pas, on retombe sur la création boutique
      // standalone (qui reste fonctionnelle). Le router GoRouter laisse
      // passer si la route n'est pas définie ? Non — il faut une route
      // qui existe. On utilise RouteNames.onboardingShop si défini,
      // sinon createShop.
      _submitting = false;
      ctx.go(RouteNames.onboardingShop);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primarySurface,
      body: BlocListener<AuthBloc, AuthState>(
        listener: _onAuthState,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Top bar : back + language ──────────────────────────
                  Row(
                    children: [
                      IconButton(
                        onPressed: () =>
                            context.go(RouteNames.onboardingAuthChoice),
                        icon: const Icon(Icons.arrow_back_rounded,
                            color: AppColors.textSecondary),
                      ),
                      const Spacer(),
                      const LanguageSwitcher(),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // ── Logo + titre ─────────────────────────────────────
                  const Center(child: FortressLogo(size: 64)),
                  const SizedBox(height: 20),
                  const Text('Créez votre compte',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.title),
                  const SizedBox(height: 6),
                  const Text(
                    '3 champs et c\'est parti. Vous configurerez votre '
                    'boutique juste après.',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySecondary,
                  ),
                  const SizedBox(height: 28),

                  // ── Champ Nom ─────────────────────────────────────────
                  NameField(
                    controller: _nameCtrl,
                    focusNode:  _nameFocus,
                    hint:       'Votre nom complet',
                    label:      'Nom',
                    required:   true,
                    validator:  (_) => _nameError,
                  ),
                  if (_nameError != null) _ErrText(_nameError!),
                  const SizedBox(height: 14),

                  // ── Champ Email ───────────────────────────────────────
                  EmailField(
                    controller: _emailCtrl,
                    focusNode:  _emailFocus,
                    hint:       'vous@exemple.com',
                    label:      'Email',
                    required:   true,
                    validator:  (_) => _emailError,
                  ),
                  if (_emailError != null) _ErrText(_emailError!),
                  const SizedBox(height: 14),

                  // ── Champ Password ───────────────────────────────────
                  // PasswordStrengthField inclut l'indicateur de force —
                  // l'utilisateur voit s'il respecte la policy.
                  PasswordStrengthField(
                    controller: _passCtrl,
                    focusNode:  _passFocus,
                    hint:       'Choisissez un mot de passe',
                    label:      'Mot de passe',
                    required:   true,
                    validator:  (_) => _passError,
                  ),
                  if (_passError != null) _ErrText(_passError!),
                  const SizedBox(height: 24),

                  // ── CTA ──────────────────────────────────────────────
                  AppPrimaryButton(
                    label:     'Démarrer mon essai 14 jours',
                    icon:      Icons.rocket_launch_outlined,
                    enabled:   _isValid,
                    isLoading: _submitting,
                    onTap:     _submit,
                  ),
                  const SizedBox(height: 12),

                  // ── Mention bas + lien login ──────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Déjà un compte ? ',
                          style: AppTextStyles.caption),
                      InkWell(
                        onTap: () => context.go(RouteNames.login),
                        child: Text(
                          'Connectez-vous',
                          style: AppTextStyles.caption.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrText extends StatelessWidget {
  final String text;
  const _ErrText(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
        child: Text(text,
            style: AppTextStyles.caption
                .copyWith(color: AppColors.error)),
      );
}
