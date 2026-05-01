import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../data/datasources/auth_supabase_datasource.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/language_switcher.dart';
import '../../../../shared/widgets/auth_fields.dart';
import '../../../../core/validators/password_policy.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Mot de passe oublié — flux unifié OTP email pour tous :
//   1. Email  → détection super admin (pour UI + règles) + envoi OTP
//   2. OTP    → vérification code (longueur configurable, 6-10) → session
//   3. New pw → updatePassword → (SA seulement : activity log + signOutGlobal)
//               → redirection /auth/login
//
// Pas de deep link : compatible mobile ET desktop.
// ─────────────────────────────────────────────────────────────────────────────

enum _Step { email, otp, newPassword }

class ForgotPasswordPage extends ConsumerStatefulWidget {
  const ForgotPasswordPage({super.key});
  @override
  ConsumerState<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends ConsumerState<ForgotPasswordPage> {
  final _ds = AuthSupabaseDataSource();

  _Step _step = _Step.email;
  bool  _isSuperAdmin = false;

  // Étape 1 — email
  final _emailKey  = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  bool  _sendingEmail = false;

  // Étape 2 — OTP
  final _otpCtrl = TextEditingController();
  bool   _verifyingOtp = false;
  String? _otpError;
  int    _resendCooldown = 0;
  Timer? _resendTimer;

  // Étape 3 — nouveau mot de passe
  final _pwdKey    = GlobalKey<FormState>();
  final _pwdCtrl   = TextEditingController();
  final _confCtrl  = TextEditingController();
  bool  _savingPwd   = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _otpCtrl.dispose();
    _pwdCtrl.dispose();
    _confCtrl.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }

  // ── Étape 1 → détection SA + envoi OTP ───────────────────────────────────
  Future<void> _submitEmail() async {
    if (!(_emailKey.currentState?.validate() ?? false)) return;
    final email = _emailCtrl.text.trim().toLowerCase();
    setState(() => _sendingEmail = true);
    try {
      final isSa = await _ds.isSuperAdminEmail(email);
      await _ds.sendEmailOtp(email);
      if (!mounted) return;
      _startResendCooldown();
      setState(() {
        _isSuperAdmin = isSa;
        _step = _Step.otp;
      });
    } catch (e) {
      if (mounted) AppSnack.error(context, _readable(e));
    } finally {
      if (mounted) setState(() => _sendingEmail = false);
    }
  }

  // ── Étape 2 → vérification OTP ───────────────────────────────────────────
  // Supabase accepte 6 à 10 chiffres selon la config projet (défaut 6).
  static const int _otpLength = 8;

  Future<void> _verifyOtp() async {
    final code = _otpCtrl.text.trim();
    if (code.length != _otpLength) {
      setState(() => _otpError = 'Code à $_otpLength chiffres requis');
      return;
    }
    setState(() { _verifyingOtp = true; _otpError = null; });
    try {
      await _ds.verifyEmailOtp(
        email: _emailCtrl.text.trim().toLowerCase(),
        token: code,
      );
      if (!mounted) return;
      setState(() => _step = _Step.newPassword);
    } catch (e) {
      if (!mounted) return;
      setState(() => _otpError = 'Code invalide ou expiré');
    } finally {
      if (mounted) setState(() => _verifyingOtp = false);
    }
  }

  Future<void> _resendOtp() async {
    if (_resendCooldown > 0) return;
    try {
      await _ds.sendEmailOtp(_emailCtrl.text.trim().toLowerCase());
      if (!mounted) return;
      AppSnack.success(context, 'Nouveau code envoyé');
      _startResendCooldown();
    } catch (e) {
      if (mounted) AppSnack.error(context, _readable(e));
    }
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendCooldown = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _resendCooldown--;
        if (_resendCooldown <= 0) t.cancel();
      });
    });
  }

  // ── Étape 3 → enregistrement nouveau mot de passe ────────────────────────
  Future<void> _saveNewPassword() async {
    if (!(_pwdKey.currentState?.validate() ?? false)) return;
    if (_pwdCtrl.text != _confCtrl.text) {
      AppSnack.error(context, 'Les mots de passe ne correspondent pas');
      return;
    }
    final strength = PasswordPolicy.evaluate(_pwdCtrl.text);
    final ok = _isSuperAdmin
        ? strength.level == PasswordStrengthLevel.strong
        : strength.level != PasswordStrengthLevel.weak;
    if (!ok) {
      AppSnack.error(context,
          _isSuperAdmin
              ? 'Mot de passe trop faible pour un administrateur'
              : 'Mot de passe trop faible');
      return;
    }
    setState(() => _savingPwd = true);
    try {
      await _ds.updatePassword(_pwdCtrl.text);

      if (_isSuperAdmin) {
        // Journaliser + forcer la déconnexion de toutes les sessions
        await ActivityLogService.log(
          action:     'super_admin_password_reset',
          targetType: 'user',
          details:    {'method': 'email_otp'},
        );
        await _ds.signOutGlobal();
        if (!mounted) return;
        AppSnack.success(context,
          'Mot de passe modifié. Toutes vos sessions ont été déconnectées.');
      } else {
        // Utilisateur normal : on déconnecte aussi pour forcer un re-login
        // avec le nouveau mot de passe (sinon la session d'OTP reste active).
        await _ds.signOutGlobal();
        if (!mounted) return;
        AppSnack.success(context, 'Mot de passe modifié avec succès');
      }
      context.go(RouteNames.login);
    } catch (e) {
      if (mounted) AppSnack.error(context, _readable(e));
    } finally {
      if (mounted) setState(() => _savingPwd = false);
    }
  }

  String _readable(Object e) {
    final s = e.toString();
    if (s.startsWith('Exception: ')) return s.substring(11);
    if (s.startsWith('Instance of')) return 'Une erreur est survenue';
    return s;
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primarySurface,
      body: Stack(children: [
        Center(
          child: SingleChildScrollView(
            child: LayoutBuilder(builder: (context, box) {
              final isDesktop = box.maxWidth >= 600;
              return Center(
                child: Container(
                  width: isDesktop ? 440 : double.infinity,
                  margin: isDesktop
                      ? const EdgeInsets.symmetric(vertical: 32)
                      : EdgeInsets.zero,
                  decoration: isDesktop ? BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ) : null,
                  color: isDesktop ? null : Colors.white,
                  padding: EdgeInsets.symmetric(
                      horizontal: isDesktop ? 36 : 20,
                      vertical: isDesktop ? 40 : 24),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _buildStep(),
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
              backgroundColor: Colors.white.withOpacity(0.92),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case _Step.email:
        return _EmailStep(
          key: const ValueKey('email'),
          formKey: _emailKey,
          emailCtrl: _emailCtrl,
          isLoading: _sendingEmail,
          onSubmit: _submitEmail,
          onBack: () => context.pop(),
        );
      case _Step.otp:
        return _OtpStep(
          key: const ValueKey('otp'),
          email: _emailCtrl.text.trim(),
          otpCtrl: _otpCtrl,
          isSuperAdmin: _isSuperAdmin,
          error: _otpError,
          isLoading: _verifyingOtp,
          resendCooldown: _resendCooldown,
          otpLength: _otpLength,
          onVerify: _verifyOtp,
          onResend: _resendOtp,
          onBack: () => setState(() => _step = _Step.email),
        );
      case _Step.newPassword:
        return _NewPasswordStep(
          key: const ValueKey('pwd'),
          formKey: _pwdKey,
          pwdCtrl: _pwdCtrl,
          confCtrl: _confCtrl,
          isLoading: _savingPwd,
          isSuperAdmin: _isSuperAdmin,
          onSubmit: _saveNewPassword,
        );
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Étape 1 — saisie email
// ═════════════════════════════════════════════════════════════════════════════

class _EmailStep extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController emailCtrl;
  final bool isLoading;
  final VoidCallback onSubmit, onBack;

  const _EmailStep({
    super.key,
    required this.formKey, required this.emailCtrl,
    required this.isLoading,
    required this.onSubmit, required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final tt = Theme.of(context).textTheme;
    return Form(
      key: formKey,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const FortressLogo.light(size: 30),
        const SizedBox(height: 32),
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            color: AppColors.primarySurface, shape: BoxShape.circle),
          child: Icon(Icons.lock_reset_rounded,
              size: 30, color: AppColors.primary),
        ),
        const SizedBox(height: 20),
        Text(l.forgotTitle,
            style: tt.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: const Color(0xFF0F172A), letterSpacing: 0.3,
            )),
        const SizedBox(height: 8),
        const Text(
          'Saisissez votre email. Nous vous enverrons un code à usage '
          'unique pour réinitialiser votre mot de passe.',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12, color: Color(0xFF6B7280), height: 1.6),
        ),
        const SizedBox(height: 28),
        EmailField(
          controller: emailCtrl,
          hint: l.loginEmailHint,
          label: l.loginEmail,
          required: true,
        ),
        const SizedBox(height: 24),
        AppPrimaryButton(
          isLoading: isLoading,
          enabled: !isLoading,
          onTap: onSubmit,
          label: 'Envoyer le code',
        ),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: onBack,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.arrow_back_rounded,
                  size: 14, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(l.registerSignIn,
                  style: TextStyle(
                    color: AppColors.primary, fontSize: 13,
                    fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ]),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Étape 2 — OTP
// ═════════════════════════════════════════════════════════════════════════════

class _OtpStep extends StatelessWidget {
  final String email;
  final TextEditingController otpCtrl;
  final bool isSuperAdmin;
  final String? error;
  final bool isLoading;
  final int resendCooldown;
  final int otpLength;
  final VoidCallback onVerify, onResend, onBack;

  const _OtpStep({
    super.key,
    required this.email, required this.otpCtrl,
    required this.isSuperAdmin,
    required this.error, required this.isLoading,
    required this.resendCooldown,
    required this.otpLength,
    required this.onVerify, required this.onResend, required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const FortressLogo.light(size: 30),
      const SizedBox(height: 24),

      if (isSuperAdmin) ...[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF7ED),
            border: Border.all(color: const Color(0xFFFBBF24)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: const [
            Icon(Icons.shield_outlined, size: 14, color: Color(0xFFF59E0B)),
            SizedBox(width: 6),
            Flexible(child: Text(
              'Compte Administrateur — Vérification renforcée requise',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                  color: Color(0xFF92400E)),
            )),
          ]),
        ),
        const SizedBox(height: 20),
      ],

      Container(
        width: 64, height: 64,
        decoration: BoxDecoration(
          color: AppColors.primarySurface, shape: BoxShape.circle),
        child: Icon(Icons.sms_outlined, size: 30, color: AppColors.primary),
      ),
      const SizedBox(height: 18),
      Text('Entrez le code',
          style: tt.titleMedium?.copyWith(
            fontWeight: FontWeight.w800, color: const Color(0xFF0F172A))),
      const SizedBox(height: 6),
      Text(
        'Un code à $otpLength chiffres a été envoyé à $email. '
        'Vérifiez aussi vos spams.',
        textAlign: TextAlign.center,
        style: const TextStyle(
            fontSize: 12, color: Color(0xFF6B7280), height: 1.5),
      ),
      const SizedBox(height: 22),

      _PinField(controller: otpCtrl, error: error, length: otpLength),
      if (error != null) ...[
        const SizedBox(height: 6),
        Text(error!,
            style: const TextStyle(
                fontSize: 11, color: Color(0xFFEF4444))),
      ],

      const SizedBox(height: 20),
      AppPrimaryButton(
        isLoading: isLoading,
        enabled: !isLoading,
        onTap: onVerify,
        label: 'Vérifier le code',
      ),
      const SizedBox(height: 14),

      GestureDetector(
        onTap: resendCooldown > 0 ? null : onResend,
        child: Text(
          resendCooldown > 0
              ? 'Renvoyer le code dans ${resendCooldown}s'
              : 'Renvoyer le code',
          style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600,
            color: resendCooldown > 0
                ? const Color(0xFF9CA3AF)
                : AppColors.primary,
          ),
        ),
      ),

      const SizedBox(height: 14),
      GestureDetector(
        onTap: onBack,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.arrow_back_rounded, size: 14,
                color: const Color(0xFF6B7280)),
            const SizedBox(width: 6),
            const Text('Changer d\'email',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          ],
        ),
      ),
    ]);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Étape 3 — nouveau mot de passe
// ═════════════════════════════════════════════════════════════════════════════

class _NewPasswordStep extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController pwdCtrl, confCtrl;
  final bool isLoading, isSuperAdmin;
  final VoidCallback onSubmit;

  const _NewPasswordStep({
    super.key,
    required this.formKey, required this.pwdCtrl, required this.confCtrl,
    required this.isLoading, required this.isSuperAdmin,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Form(
      key: formKey,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const FortressLogo.light(size: 30),
        const SizedBox(height: 20),

        // Badge vert "Identité vérifiée"
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFECFDF5),
            border: Border.all(color: const Color(0xFF10B981)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: const [
            Icon(Icons.verified_user_outlined, size: 14,
                color: Color(0xFF10B981)),
            SizedBox(width: 6),
            Text('Identité vérifiée ✓',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                    color: Color(0xFF065F46))),
          ]),
        ),
        const SizedBox(height: 20),

        Text('Nouveau mot de passe',
            style: tt.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: const Color(0xFF0F172A))),
        const SizedBox(height: 6),
        Text(
          isSuperAdmin
              ? 'Règles administrateur : mot de passe FORT requis '
                '(majuscule, minuscule, chiffre, caractère spécial).'
              : 'Minimum 8 caractères. Mélangez majuscule, chiffre et '
                'caractère spécial pour un mot de passe BON.',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 11, color: Color(0xFF6B7280), height: 1.5),
        ),
        const SizedBox(height: 18),

        PasswordStrengthField(
          controller: pwdCtrl,
          hint: 'Mot de passe',
          strict: isSuperAdmin,
        ),
        const SizedBox(height: 14),

        ConfirmPasswordField(
          controller: confCtrl,
          originalController: pwdCtrl,
          hint: 'Confirmation',
        ),
        const SizedBox(height: 24),

        AppPrimaryButton(
          isLoading: isLoading,
          enabled: !isLoading,
          onTap: onSubmit,
          label: 'Enregistrer',
        ),
      ]),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Widgets partagés
// ═════════════════════════════════════════════════════════════════════════════

class _PinField extends StatelessWidget {
  final TextEditingController controller;
  final String? error;
  final int length;
  const _PinField({
    required this.controller,
    required this.error,
    this.length = 8,
  });

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(
          color: error != null ? AppColors.error : const Color(0xFFE5E7EB),
          width: 1),
    );
    final dots = '·' * length;
    // Serrer le letterSpacing à 8 devient vite étroit au-delà de 6 chiffres
    final spacing = length > 6 ? 6.0 : 8.0;
    final fontSize = length > 6 ? 20.0 : 22.0;
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      maxLength: length,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: TextStyle(
        fontSize: fontSize, fontWeight: FontWeight.w700,
        color: const Color(0xFF0F172A), letterSpacing: spacing,
      ),
      decoration: InputDecoration(
        counterText: '',
        hintText: dots,
        hintStyle: TextStyle(
            color: const Color(0xFFBBBBBB),
            fontSize: fontSize, letterSpacing: spacing),
        filled: true, fillColor: const Color(0xFFF9FAFB),
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
    );
  }
}

