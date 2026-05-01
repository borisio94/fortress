import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/auth_fields.dart';
import '../../../../shared/widgets/phone_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/language_switcher.dart';
import '../../../../core/validators/input_validators.dart';
import '../../../../core/validators/password_policy.dart';

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});
  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _formKey  = GlobalKey<FormState>();
  final _namCtrl  = TextEditingController();
  final _mailCtrl = TextEditingController();
  final _telCtrl  = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confCtrl = TextEditingController();

  bool   _isOnline     = true;
  String _phoneFull    = '';
  bool   _phoneValid   = false;

  // ── Erreurs temps réel ───────────────────────────────────────────────────
  String? _nameError;
  String? _emailError;
  String? _passError;
  String? _confError;

  bool get _btnEnabled =>
      _isOnline &&
          _nameError == null &&
          _emailError == null &&
          _passError == null &&
          _confError == null &&
          _namCtrl.text.trim().length >= 2 &&
          _mailCtrl.text.trim().isNotEmpty &&
          _passCtrl.text.length >= PasswordPolicy.minLength &&
          _confCtrl.text == _passCtrl.text &&
          _phoneFull.isNotEmpty && _phoneValid;

  String? _validateConfirm(String v) {
    if (v != _passCtrl.text) return 'Mots de passe différents';
    return null;
  }

  @override
  void initState() {
    super.initState();
    _checkConnectivity();
    Connectivity().onConnectivityChanged.listen((results) {
      if (mounted) setState(() => _isOnline = results.any((x) =>
      x == ConnectivityResult.wifi ||
          x == ConnectivityResult.mobile ||
          x == ConnectivityResult.ethernet));
    });
    _namCtrl.addListener(() => setState(() =>
        _nameError = InputValidators.name(_namCtrl.text)));
    _mailCtrl.addListener(() => setState(() =>
        _emailError = InputValidators.email(_mailCtrl.text)));
    _passCtrl.addListener(() => setState(() {
      _passError = InputValidators.password(_passCtrl.text);
      if (_confCtrl.text.isNotEmpty)
        _confError = _validateConfirm(_confCtrl.text);
    }));
    _confCtrl.addListener(() => setState(() =>
        _confError = _validateConfirm(_confCtrl.text)));
  }

  Future<void> _checkConnectivity() async {
    final r = await Connectivity().checkConnectivity();
    if (mounted) setState(() => _isOnline = r.any((x) =>
    x == ConnectivityResult.wifi ||
        x == ConnectivityResult.mobile ||
        x == ConnectivityResult.ethernet));
  }

  @override
  void dispose() {
    for (final c in [_namCtrl, _mailCtrl, _telCtrl, _passCtrl, _confCtrl])
      c.dispose();
    super.dispose();
  }

  void _submit() {
    // Déclencher toutes les validations
    setState(() {
      _nameError  = InputValidators.name(_namCtrl.text);
      _emailError = InputValidators.email(_mailCtrl.text);
      _passError  = InputValidators.password(_passCtrl.text);
      _confError  = _validateConfirm(_confCtrl.text);
    });
    if (_nameError != null || _emailError != null ||
        _passError != null || _confError != null) return;
    if (_phoneFull.isNotEmpty && !_phoneValid) {
      AppSnack.error(context, 'Numéro de téléphone invalide');
      return;
    }
    context.read<AuthBloc>().add(AuthRegisterRequested(
      name:     _namCtrl.text.trim(),
      email:    _mailCtrl.text.trim(),
      password: _passCtrl.text,
      phone:    _phoneFull.isEmpty ? null : _phoneFull,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.primarySurface,
      body: BlocConsumer<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is AuthError) AppSnack.error(context, state.message);
          if (state is AuthRegisterSuccess) {
            AppSnack.success(context,
                'Compte créé. Connectez-vous avec vos identifiants.');
            context.go('/auth/login');
          }
        },
        builder: (context, state) {
          final isLoading = state is AuthLoading;
          return Stack(children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: LayoutBuilder(builder: (context, box) {
                  final isDesktop = box.maxWidth >= 600;
                  return Center(
                    child: Container(
                      width: isDesktop ? 480 : box.maxWidth * 0.88,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 36, vertical: 36),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const FortressLogo.light(size: 30),
                            const SizedBox(height: 24),
                            Text(l.registerTitle,
                                style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A))),
                            const SizedBox(height: 4),
                            Text(l.loginSubtitle,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF6B7280))),
                            const SizedBox(height: 24),

                            // ── Nom ────────────────────────────────────
                            NameField(
                              controller: _namCtrl,
                              hint: l.registerNameHint,
                              label: l.registerName,
                              required: true,
                              validator: (_) => _nameError,
                            ),
                            if (_nameError != null)
                              _ErrText(_nameError!),
                            const SizedBox(height: 14),

                            // ── Email ──────────────────────────────────
                            EmailField(
                              controller: _mailCtrl,
                              hint: l.loginEmailHint,
                              label: l.loginEmail,
                              required: true,
                              validator: (_) => _emailError,
                            ),
                            if (_emailError != null)
                              _ErrText(_emailError!),
                            const SizedBox(height: 14),

                            // ── Téléphone ──────────────────────────────
                            PhoneField(
                              controller: _telCtrl,
                              label: l.registerPhone,
                              required: true,
                              onChanged: (full, valid) {
                                setState(() {
                                  _phoneFull  = full;
                                  _phoneValid = valid;
                                });
                              },
                            ),
                            const SizedBox(height: 14),

                            // ── Mot de passe ───────────────────────────
                            PasswordStrengthField(
                              controller: _passCtrl,
                              hint: l.loginPasswordHint,
                              label: l.loginPassword,
                              required: true,
                              validator: (_) => _passError,
                            ),
                            if (_passError != null)
                              _ErrText(_passError!),
                            const SizedBox(height: 14),

                            // ── Confirmation ───────────────────────────
                            ConfirmPasswordField(
                              controller: _confCtrl,
                              originalController: _passCtrl,
                              hint: l.loginPasswordHint,
                              label: l.registerConfirmPass,
                              required: true,
                            ),
                            if (_confError != null)
                              _ErrText(_confError!),
                            const SizedBox(height: 28),

                            // ── Alerte hors ligne ──────────────────────
                            if (!_isOnline)
                              Container(
                                padding: const EdgeInsets.all(10),
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF7ED),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: const Color(0xFFFBBF24)),
                                ),
                                child: Row(children: [
                                  const Icon(Icons.wifi_off_rounded,
                                      size: 14,
                                      color: Color(0xFFF59E0B)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      l.onlineRequiredForRegister,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF92400E)),
                                    ),
                                  ),
                                ]),
                              ),

                            // ── Bouton ─────────────────────────────────
                            AppPrimaryButton(
                              isLoading: isLoading,
                              enabled: _btnEnabled && !isLoading,
                              onTap: _submit,
                              label: l.registerButton,
                            ),
                            const SizedBox(height: 20),

                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(l.registerAlreadyAccount,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF6B7280))),
                                GestureDetector(
                                  onTap: () => context.pop(),
                                  child: Text(l.registerSignIn,
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.primary)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
            Positioned(
              top: 12, right: 16,
              child: SafeArea(
                child: LanguageSwitcher(
                    backgroundColor: Colors.white.withOpacity(0.92)),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

// ── Message d'erreur ──────────────────────────────────────────────────────────
class _ErrText extends StatelessWidget {
  final String message;
  const _ErrText(this.message);
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(top: 4, left: 2),
      child: Text(message,
          style: const TextStyle(
              fontSize: 10, color: Color(0xFFEF4444))),
    ),
  );
}

