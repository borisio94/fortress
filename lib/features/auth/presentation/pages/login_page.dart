import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/language_switcher.dart';
import '../../../../shared/widgets/auth_fields.dart';
import '../../../../core/storage/local_storage_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const double _kDesktopBreakpoint = 800;

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});
  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Pré-remplir avec le dernier email utilisé — évite la ressaisie après logout.
    final last = LocalStorageService.getLastLoginEmail();
    if (last != null && last.isNotEmpty) {
      _emailCtrl.text = last;
      // Focus directement le champ mot de passe : l'utilisateur n'a plus
      // qu'à taper son mdp et valider.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _passFocus.requestFocus();
      });
    }
  }

  final FocusNode _passFocus = FocusNode();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      context.read<AuthBloc>().add(AuthLoginRequested(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primarySurface,
      body: Stack(
        children: [
          // ── Contenu principal ─────────────────────────────────────
          BlocConsumer<AuthBloc, AuthState>(
            listener: (context, state) {
              // ✅ Navigation : gérée automatiquement par AuthRouterNotifier
              // ✅ Erreur : affichée ici dans la page
              if (state is AuthError) {
                AppSnack.error(context, state.message);
              }
            },
            builder: (context, state) {
              final isLoading = state is AuthLoading;
              return LayoutBuilder(builder: (context, box) {
                final isDesktop = box.maxWidth >= _kDesktopBreakpoint;
                return isDesktop
                    ? _DesktopLayout(
                  screenW: box.maxWidth, screenH: box.maxHeight,
                  formKey: _formKey, emailCtrl: _emailCtrl,
                  passCtrl: _passCtrl, passFocus: _passFocus,
                  isLoading: isLoading,
                  onSubmit: _submit,
                  onForgot: () => context.push(RouteNames.forgotPassword),
                  onRegister: () => context.push(RouteNames.register),
                )
                    : _MobileLayout(
                  formKey: _formKey, emailCtrl: _emailCtrl,
                  passCtrl: _passCtrl, passFocus: _passFocus,
                  isLoading: isLoading,
                  onSubmit: _submit,
                  onForgot: () => context.push(RouteNames.forgotPassword),
                  onRegister: () => context.push(RouteNames.register),
                );
              });
            },
          ),

          // ── Switcher de langue — flottant en haut à droite ────────
          Positioned(
            top: 12,
            right: 16,
            child: SafeArea(
              child: LanguageSwitcher(
                backgroundColor: Colors.white.withOpacity(0.92),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DESKTOP
// ─────────────────────────────────────────────────────────────────────────────

class _DesktopLayout extends StatelessWidget {
  final double screenW, screenH;
  final GlobalKey<FormState> formKey;
  final TextEditingController emailCtrl, passCtrl;
  final FocusNode passFocus;
  final bool isLoading;
  final VoidCallback onSubmit, onForgot, onRegister;

  const _DesktopLayout({
    required this.screenW, required this.screenH,
    required this.formKey, required this.emailCtrl, required this.passCtrl,
    required this.passFocus,
    required this.isLoading,
    required this.onSubmit,
    required this.onForgot, required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    final cW = screenW * 0.78;
    final cH = screenH * 0.82;

    return Container(
      width: screenW, height: screenH,
      color: AppColors.primarySurface,
      child: Center(
        child: SizedBox(
          width: cW, height: cH,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Row(
              children: [
                Expanded(flex: 5, child: _LeftPanel(cardH: cH)),
                Expanded(
                  flex: 5,
                  child: Container(
                    color: Colors.white,
                    child: OverflowBox(
                      alignment: Alignment.center,
                      maxHeight: cH, minHeight: cH,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: (cW * 0.07).clamp(32.0, 60.0),
                          vertical: (cH * 0.05).clamp(16.0, 36.0),
                        ),
                        child: _FormContent(
                          formKey: formKey, emailCtrl: emailCtrl,
                          passCtrl: passCtrl, passFocus: passFocus,
                          isLoading: isLoading,
                          onSubmit: onSubmit, onForgot: onForgot,
                          onRegister: onRegister, availableH: cH,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Panneau gauche — fond confondu avec l'arrière-plan
// ─────────────────────────────────────────────────────────────────────────────

class _LeftPanel extends StatelessWidget {
  final double cardH;
  const _LeftPanel({required this.cardH});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final illustSize = (cardH * 0.36).clamp(100.0, 240.0);
    final titleSize  = (cardH * 0.038).clamp(14.0, 22.0);
    final subSize    = (cardH * 0.019).clamp(10.0, 13.0);

    return Container(
      color: AppColors.primarySurface,
      child: Column(
        children: [
          const Spacer(flex: 2),

          // Grande icône bouclier avec cercle de fond
          SizedBox(
            width: illustSize, height: illustSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: illustSize, height: illustSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primary.withOpacity(0.10),
                  ),
                ),
                // FortressLogo icône — taille dynamique scalée sur l'illustration
                FortressLogo.light(size: illustSize * 0.52),
                ..._buildFloating(illustSize),
              ],
            ),
          ),

          const Spacer(flex: 1),

          // Nom + tagline
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Text(
              l.appName,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: titleSize,
                fontWeight: FontWeight.w800,
                color: const Color(0xFF0F172A),
                letterSpacing: 2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Text(
              l.panelTagline,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: subSize,
                color: AppColors.primary.withOpacity(0.65),
                height: 1.5,
              ),
            ),
          ),

          const Spacer(flex: 1),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Dot(active: false),
              const SizedBox(width: 6),
              _Dot(active: true),
              const SizedBox(width: 6),
              _Dot(active: false),
            ],
          ),

          const Spacer(flex: 2),
        ],
      ),
    );
  }

  List<Widget> _buildFloating(double size) {
    const icons = [Icons.receipt_long, Icons.inventory_2_outlined,
      Icons.people_outline, Icons.bar_chart];
    final pos = [
      Offset(-size * 0.37, -size * 0.26), Offset(size * 0.37, -size * 0.22),
      Offset(-size * 0.35, size * 0.24),  Offset(size * 0.35, size * 0.28),
    ];
    return List.generate(icons.length, (i) {
      final bx = (size * 0.17).clamp(22.0, 38.0);
      final ic = (size * 0.10).clamp(12.0, 20.0);
      return Positioned(
        left: size / 2 + pos[i].dx - bx / 2,
        top:  size / 2 + pos[i].dy - bx / 2,
        child: Container(
          width: bx, height: bx,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [BoxShadow(
              color: AppColors.primary.withOpacity(0.14),
              blurRadius: 8, offset: const Offset(0, 2),
            )],
          ),
          child: Icon(icons[i], size: ic, color: AppColors.primary),
        ),
      );
    });
  }
}

class _Dot extends StatelessWidget {
  final bool active;
  const _Dot({required this.active});
  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 200),
    width: active ? 20 : 7, height: 7,
    decoration: BoxDecoration(
      color: active ? AppColors.primary : AppColors.primary.withOpacity(0.25),
      borderRadius: BorderRadius.circular(4),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// MOBILE
// ─────────────────────────────────────────────────────────────────────────────

class _MobileLayout extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController emailCtrl, passCtrl;
  final FocusNode passFocus;
  final bool isLoading;
  final VoidCallback onSubmit, onForgot, onRegister;

  const _MobileLayout({
    required this.formKey, required this.emailCtrl, required this.passCtrl,
    required this.passFocus,
    required this.isLoading,
    required this.onSubmit,
    required this.onForgot, required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: _FormContent(
          formKey: formKey, emailCtrl: emailCtrl, passCtrl: passCtrl,
          passFocus: passFocus,
          isLoading: isLoading,
          onSubmit: onSubmit, onForgot: onForgot, onRegister: onRegister,
          availableH: double.infinity,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Formulaire — zéro texte en dur
// ─────────────────────────────────────────────────────────────────────────────

class _FormContent extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController emailCtrl, passCtrl;
  final FocusNode passFocus;
  final bool isLoading;
  final VoidCallback onSubmit, onForgot, onRegister;
  final double availableH;

  const _FormContent({
    required this.formKey, required this.emailCtrl, required this.passCtrl,
    required this.passFocus,
    required this.isLoading,
    required this.onSubmit,
    required this.onForgot, required this.onRegister,
    required this.availableH,
  });

  double get _gap => availableH.isFinite ? (availableH * 0.022).clamp(8, 16) : 12;
  double get _sg  => availableH.isFinite ? (availableH * 0.036).clamp(14, 26) : 20;

  @override
  Widget build(BuildContext context) {
    final l  = context.l10n;
    final tt = Theme.of(context).textTheme;

    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [

          // ── Logo Fortress — variant light, footer ─────────────────
          const FortressLogo.light(size: 34),
          SizedBox(height: _sg),

          // ── Email ──────────────────────────────────────────────────
          Align(
            alignment: Alignment.centerLeft,
            child: Text(l.loginEmail,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                    color: Color(0xFF6B7280))),
          ),
          const SizedBox(height: 5),
          EmailField(
            controller: emailCtrl,
            hint: l.loginEmailHint,
          ),

          SizedBox(height: _gap),

          // ── Mot de passe ───────────────────────────────────────────
          Align(
            alignment: Alignment.centerLeft,
            child: Text(l.loginPassword,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                    color: Color(0xFF6B7280))),
          ),
          const SizedBox(height: 5),
          PasswordField(
            controller: passCtrl,
            focusNode: passFocus,
            hint: l.loginPasswordHint,
          ),

          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onForgot,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: Text(l.loginForgot,
                  style: TextStyle(color: AppColors.primary, fontSize: 12,
                      fontWeight: FontWeight.w500)),
            ),
          ),

          SizedBox(height: _gap),

          AppPrimaryButton(isLoading: isLoading, enabled: !isLoading, onTap: onSubmit, label: l.loginButton),

          SizedBox(height: _sg),

          Row(children: [
            Expanded(child: Divider(color: Colors.grey.shade200, thickness: 1)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(l.loginOrWith,
                  style: tt.bodySmall?.copyWith(color: Colors.grey.shade400, fontSize: 11)),
            ),
            Expanded(child: Divider(color: Colors.grey.shade200, thickness: 1)),
          ]),

          SizedBox(height: _sg),

          _GoogleBtn(label: l.socialGoogle),

          SizedBox(height: _sg),

          Center(
            child: Wrap(
              alignment: WrapAlignment.center,
              children: [
                Text(l.loginNoAccount,
                    style: tt.bodySmall?.copyWith(color: Colors.grey.shade500, fontSize: 12)),
                GestureDetector(
                  onTap: onRegister,
                  child: Text(l.loginCreate,
                      style: TextStyle(color: AppColors.primary, fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets atomiques du formulaire
// ─────────────────────────────────────────────────────────────────────────────

class _GoogleBtn extends StatefulWidget {
  final String label;
  const _GoogleBtn({required this.label});
  @override
  State<_GoogleBtn> createState() => _GoogleBtnState();
}

class _GoogleBtnState extends State<_GoogleBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _h = true),
    onExit: (_) => setState(() => _h = false),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: double.infinity, height: 43,
      decoration: BoxDecoration(
        color: _h ? Colors.grey.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: _h ? AppColors.primary.withOpacity(0.4) : const Color(0xFFDDDDDD),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {},
          borderRadius: BorderRadius.circular(6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('G', style: TextStyle(fontSize: 17,
                  fontWeight: FontWeight.bold, color: Color(0xFFEA4335))),
              const SizedBox(width: 8),
              Text('Sign in with ${widget.label}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                      color: Color(0xFF444444))),
            ],
          ),
        ),
      ),
    ),
  );
}