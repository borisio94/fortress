import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/language_switcher.dart';
import '../../domain/login_password_check.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';

/// Bascule layout desktop ↔ mobile. > 800px = desktop split (panneau
/// décoratif gauche fixe + formulaire droite), sinon mobile centré.
const double _kDesktopBreakpoint = 800;

/// Fond du panneau gauche desktop : exactement la surface du thème, sans
/// teinte primaire, pour un fond identique à celui du formulaire de droite.
/// 100 % dynamique → s'adapte à la palette choisie (pas de Color(0xFF…)).
Color _panelBg(ColorScheme cs) => cs.surface;

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});
  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formKey   = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  final _passFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    final last = LocalStorageService.getLastLoginEmail();
    if (last != null && last.isNotEmpty) {
      _emailCtrl.text = last;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _passFocus.requestFocus();
      });
    }
  }

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
        email:    _emailCtrl.text.trim(),
        password: _passCtrl.text,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: BlocConsumer<AuthBloc, AuthState>(
        listener: (ctx, state) {
          if (state is AuthError) AppSnack.error(ctx, state.message);
        },
        builder: (ctx, state) {
          final loading = state is AuthLoading;
          return LayoutBuilder(builder: (lbCtx, box) {
            final isDesktop = box.maxWidth > _kDesktopBreakpoint;
            return isDesktop
                ? _DesktopLayout(
                    formKey:   _formKey,
                    emailCtrl: _emailCtrl,
                    passCtrl:  _passCtrl,
                    passFocus: _passFocus,
                    isLoading: loading,
                    onSubmit:   _submit,
                    onForgot:   () => ctx.push(RouteNames.forgotPassword),
                    onRegister: () => ctx.push(RouteNames.register),
                  )
                : _MobileLayout(
                    formKey:   _formKey,
                    emailCtrl: _emailCtrl,
                    passCtrl:  _passCtrl,
                    passFocus: _passFocus,
                    isLoading: loading,
                    onSubmit:   _submit,
                    onForgot:   () => ctx.push(RouteNames.forgotPassword),
                    onRegister: () => ctx.push(RouteNames.register),
                  );
          });
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DESKTOP — split 310px / flex
// ─────────────────────────────────────────────────────────────────────────────

class _DesktopLayout extends StatelessWidget {
  final GlobalKey<FormState>     formKey;
  final TextEditingController    emailCtrl, passCtrl;
  final FocusNode                passFocus;
  final bool                     isLoading;
  final VoidCallback             onSubmit, onForgot, onRegister;

  const _DesktopLayout({
    required this.formKey,
    required this.emailCtrl,
    required this.passCtrl,
    required this.passFocus,
    required this.isLoading,
    required this.onSubmit,
    required this.onForgot,
    required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        // Panneau gauche : 50%.
        const Expanded(flex: 50, child: _LeftPanel()),
        // Panneau droit : 50%, formulaire centré vertical+horizontal.
        Expanded(
          flex: 50,
          child: Container(
            color: cs.surface,
            child: Stack(
              children: [
                LayoutBuilder(builder: (ctx, box) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 48, vertical: 32),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: box.maxHeight),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: _LoginForm(
                            formKey:   formKey,
                            emailCtrl: emailCtrl,
                            passCtrl:  passCtrl,
                            passFocus: passFocus,
                            isLoading: isLoading,
                            onSubmit:   onSubmit,
                            onForgot:   onForgot,
                            onRegister: onRegister,
                            compact:    false,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                const Positioned(
                  top: 16, right: 24,
                  child: SafeArea(child: LanguageSwitcher()),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MOBILE — centré, padding 18 / 16
// ─────────────────────────────────────────────────────────────────────────────

class _MobileLayout extends StatelessWidget {
  final GlobalKey<FormState>     formKey;
  final TextEditingController    emailCtrl, passCtrl;
  final FocusNode                passFocus;
  final bool                     isLoading;
  final VoidCallback             onSubmit, onForgot, onRegister;

  const _MobileLayout({
    required this.formKey,
    required this.emailCtrl,
    required this.passCtrl,
    required this.passFocus,
    required this.isLoading,
    required this.onSubmit,
    required this.onForgot,
    required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    final l  = context.l10n;
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: LanguageSwitcher(),
            ),
          ),
          // Scroll vertical sans contraintes — le contenu est aligné en
          // haut et l'utilisateur scrolle naturellement. Le précédent
          // layout `ConstrainedBox(minHeight: box.maxHeight) + Center`
          // cachait les boutons (Connecter / Créer un compte) sous le bas
          // de l'écran sur les petits mobiles.
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              child: Column(
                mainAxisSize:       MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 16),
                  const FortressLogo.light(size: 84),
                  const SizedBox(height: 10),
                  Text(
                    l.appName.toUpperCase(),
                    style: TextStyle(
                      fontFamily:    'Georgia',
                      fontSize:      15,
                      fontWeight:    FontWeight.w600,
                      letterSpacing: 3,
                      color:         cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l.loginPanelKicker,
                    style: AppTextStyles.micro.copyWith(
                      letterSpacing: 2,
                      color:         cs.primary.withValues(alpha: 0.75),
                      fontWeight:    FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 22),
                  _LoginForm(
                    formKey:   formKey,
                    emailCtrl: emailCtrl,
                    passCtrl:  passCtrl,
                    passFocus: passFocus,
                    isLoading: isLoading,
                    onSubmit:   onSubmit,
                    onForgot:   onForgot,
                    onRegister: onRegister,
                    compact:    true,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PANNEAU DÉCORATIF GAUCHE (desktop) — fond #1A1A2E + 3 cercles + features
// ─────────────────────────────────────────────────────────────────────────────

class _LeftPanel extends StatelessWidget {
  const _LeftPanel();

  @override
  Widget build(BuildContext context) {
    final l  = context.l10n;
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: _panelBg(cs),
      child: Stack(
        alignment: Alignment.center,
        children: [
          _DecorCircle(size: 380, color: cs.primary.withValues(alpha: 0.18)),
          _DecorCircle(size: 270, color: cs.primary.withValues(alpha: 0.18)),
          _DecorCircle(size: 170, color: cs.primary.withValues(alpha: 0.18)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo doublé : 64 → 128. `.light` car le panneau est
                // désormais sur un fond presque blanc.
                const FortressLogo.light(size: 128),
                const SizedBox(height: 24),
                Text(
                  l.appName.toUpperCase(),
                  style: TextStyle(
                    fontFamily:    'Georgia',
                    fontSize:      20,
                    fontWeight:    FontWeight.w600,
                    letterSpacing: 5,
                    color:         cs.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l.loginPanelKicker.toUpperCase(),
                  style: AppTextStyles.micro.copyWith(
                    fontWeight:    FontWeight.w500,
                    letterSpacing: 3,
                    color:         cs.primary.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: 40),
                // Bloc features — Column dédiée align.start pour que les
                // icônes soient parfaitement alignées verticalement quelle
                // que soit la longueur du label. Le bloc lui-même reste
                // centré dans la colonne parent (intrinsic width).
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize:       MainAxisSize.min,
                  children: [
                    _FeatureRow(
                        icon: Icons.point_of_sale_rounded,
                        label: l.loginPanelFeatureSales),
                    _FeatureRow(
                        icon: Icons.inventory_2_rounded,
                        label: l.loginPanelFeatureInventory),
                    _FeatureRow(
                        icon: Icons.people_alt_rounded,
                        label: l.loginPanelFeatureCrm),
                    _FeatureRow(
                        icon: Icons.bar_chart_rounded,
                        label: l.loginPanelFeatureReports),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DecorCircle extends StatelessWidget {
  final double size;
  final Color  color;
  const _DecorCircle({required this.size, required this.color});
  @override
  Widget build(BuildContext context) => Container(
        width:  size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1),
        ),
      );
}

// Note: `_FeatureRow` est utilisée uniquement par le panneau gauche
// desktop. Toutes les couleurs sont issues du `colorScheme` actuel
// (icône, fond carré et label) — adaptable à n'importe quelle palette.
class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  const _FeatureRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color:        cs.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 22, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: AppTextStyles.bodySm.copyWith(
              fontWeight: FontWeight.w500,
              color:      cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FORMULAIRE — partagé desktop / mobile, densité contrôlée par `compact`
// ─────────────────────────────────────────────────────────────────────────────

class _LoginForm extends StatefulWidget {
  final GlobalKey<FormState>  formKey;
  final TextEditingController emailCtrl, passCtrl;
  final FocusNode             passFocus;
  final bool                  isLoading;
  final VoidCallback          onSubmit, onForgot, onRegister;
  final bool                  compact;

  const _LoginForm({
    required this.formKey,
    required this.emailCtrl,
    required this.passCtrl,
    required this.passFocus,
    required this.isLoading,
    required this.onSubmit,
    required this.onForgot,
    required this.onRegister,
    required this.compact,
  });

  @override
  State<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<_LoginForm> {
  bool _obscurePass = true;

  @override
  Widget build(BuildContext context) {
    final l  = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final c  = widget.compact;

    final titleSize = c ? 13.0 : 17.0;
    final subSize   = c ? 10.0 : 11.0;
    final btnVPad   = c ? 20.0 : 22.0;
    // fieldVPad : mobile +10% (14 → 15.4). Desktop reste à 18.
    final fieldVPad = c ? 15.4 : 18.0;
    final gap       = c ? 18.0 : 22.0;
    final sectionGap = c ? 26.0 : 30.0;
    final forgotGap = c ? 8.0  : 10.0;

    return Form(
      key: widget.formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Titre + sous-titre ────────────────────────────────────
          Text(
            l.loginTitle,
            style: TextStyle(
              fontSize:   titleSize,
              fontWeight: FontWeight.w500,
              color:      cs.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l.loginSubtitle,
            style: TextStyle(
              fontSize: subSize,
              color:    cs.onSurfaceVariant,
            ),
          ),
          SizedBox(height: c ? 18 : 24),

          // ── Email ─────────────────────────────────────────────────
          TextFormField(
            controller:        widget.emailCtrl,
            keyboardType:      TextInputType.emailAddress,
            textInputAction:   TextInputAction.next,
            autofillHints:     const [AutofillHints.email],
            style:             AppTextStyles.bodySm,
            decoration: _decoration(
              context,
              hint: l.loginEmailHint,
              icon: Icons.email_outlined,
              vPad: fieldVPad,
            ),
            validator: (v) {
              final s = (v ?? '').trim();
              if (s.isEmpty) return l.errEmailRequired;
              if (!s.contains('@') || !s.contains('.')) {
                return l.errEmailInvalid;
              }
              return null;
            },
          ),
          SizedBox(height: gap),

          // ── Mot de passe ──────────────────────────────────────────
          // `autofillHints` retiré + `autocorrect`/`enableSuggestions`
          // désactivés pour empêcher le browser web de proposer la
          // sauvegarde du mot de passe. Sur mobile web, le popup
          // "Enregistrer ce mot de passe ?" interférait avec le clavier
          // (apparition/disparition à chaque touche frappée).
          TextFormField(
            controller:           widget.passCtrl,
            focusNode:            widget.passFocus,
            obscureText:          _obscurePass,
            textInputAction:      TextInputAction.done,
            autocorrect:          false,
            enableSuggestions:    false,
            autofillHints:        const <String>[],
            onFieldSubmitted:     (_) => widget.onSubmit(),
            style:             AppTextStyles.bodySm,
            decoration: _decoration(
              context,
              hint: l.loginPasswordHint,
              icon: Icons.lock_outline_rounded,
              vPad: fieldVPad,
              suffix: IconButton(
                splashRadius: 18,
                padding:      EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _obscurePass
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size:  16,
                  color: cs.onSurfaceVariant,
                ),
                onPressed: () =>
                    setState(() => _obscurePass = !_obscurePass),
              ),
            ),
            // AUCUN CONTRÔLE DE LONGUEUR ICI, et ce n'est pas un oubli :
            // voir `login_password_check.dart`, qui porte le raisonnement et
            // le test qui l'épingle. Un écran de connexion transmet, il ne
            // juge pas — le serveur sait ce qui est acceptable, pas lui.
            validator: (v) =>
                loginPasswordError(v, requiredMessage: l.errPasswordRequired),
          ),
          SizedBox(height: forgotGap),

          // ── Mot de passe oublié ───────────────────────────────────
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: widget.onForgot,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                minimumSize:    Size.zero,
                tapTargetSize:  MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                l.loginForgot,
                style: AppTextStyles.caption.copyWith(
                  color:      cs.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          SizedBox(height: gap),

          // ── Bouton principal ──────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: widget.isLoading ? null : widget.onSubmit,
              style: ElevatedButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: Colors.white,
                elevation:       0,
                padding: EdgeInsets.symmetric(vertical: btnVPad),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                minimumSize:  Size.zero,
                textStyle: AppTextStyles.body.copyWith(
                    fontWeight: FontWeight.w600, color: Colors.white),
              ),
              child: widget.isLoading
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(l.loginButton),
            ),
          ),
          SizedBox(height: sectionGap),

          // ── Lien créer un compte ──────────────────────────────────
          Center(
            child: GestureDetector(
              onTap: widget.onRegister,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: l.loginNoAccount,
                    style: AppTextStyles.caption
                        .copyWith(color: cs.onSurfaceVariant),
                  ),
                  TextSpan(
                    text: l.loginCreate,
                    style: AppTextStyles.caption.copyWith(
                      color:      cs.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// InputDecoration locale — override le `inputDecorationTheme` global
  /// (rayon 12px) pour respecter la spec login (rayon 8px, bordure 1.5px,
  /// fillColor surfaceContainerHighest, prefixIcon 14px). Toutes les
  /// couleurs sont 100% issues du `colorScheme` actuel.
  InputDecoration _decoration(
    BuildContext context, {
    required String   hint,
    required IconData icon,
    required double   vPad,
    Widget?           suffix,
  }) {
    final cs = Theme.of(context).colorScheme;
    // `surfaceContainerHighest` est forcé à blanc par le theme global —
    // on lui ajoute un voile primaire ultra-léger pour différencier la
    // zone de saisie du fond du panneau (sinon les bordures sont la
    // seule séparation visible).
    final fillColor = Color.alphaBlend(
      cs.primary.withValues(alpha: 0.04),
      cs.surfaceContainerHighest,
    );
    OutlineInputBorder border(Color color, [double w = 1.5]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:   BorderSide(color: color, width: w),
        );
    return InputDecoration(
      hintText:  hint,
      hintStyle: AppTextStyles.bodySm
          .copyWith(color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
      filled:    true,
      fillColor: fillColor,
      isDense:   true,
      contentPadding: EdgeInsets.symmetric(
          horizontal: 12, vertical: vPad),
      prefixIcon: Padding(
        padding: const EdgeInsets.only(left: 12, right: 8),
        child: Icon(icon, size: 14, color: cs.onSurfaceVariant),
      ),
      prefixIconConstraints:
          const BoxConstraints(minWidth: 0, minHeight: 0),
      suffixIcon: suffix == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(right: 6),
              child: suffix,
            ),
      suffixIconConstraints:
          const BoxConstraints(minWidth: 0, minHeight: 0),
      border:             border(cs.outlineVariant),
      enabledBorder:      border(cs.outlineVariant),
      focusedBorder:      border(cs.primary),
      errorBorder:        border(cs.error),
      focusedErrorBorder: border(cs.error),
      errorStyle:         AppTextStyles.caption,
    );
  }
}

