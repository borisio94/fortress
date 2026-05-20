part of '../pages/register_page.dart';

// ─── Step 1 — Compte ───────────────────────────────────────────────────────
//
// Inclus comme `part of register_page.dart` pour accéder à `_RegisterPageState`
// qui reste privé. Découpage motivé par le cap 400 lignes/fichier de
// CLAUDE.md — la page racine seule excéderait sinon.

class _StepAccount extends StatelessWidget {
  final _RegisterPageState state;
  const _StepAccount({required this.state});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Créez votre compte', style: AppTextStyles.display),
          const SizedBox(height: 4),
          Text('Vos identifiants pour vous connecter à Fortress.',
              style: AppTextStyles.bodySmSecondary),
          const SizedBox(height: 20),
          NameField(
            controller: state._namCtrl,
            hint: l.registerNameHint,
            label: l.registerName,
            required: true,
            validator: (_) => state._nameError,
          ),
          if (state._nameError != null) _ErrText(state._nameError!),
          const SizedBox(height: 14),
          EmailField(
            controller: state._mailCtrl,
            hint: l.loginEmailHint,
            label: l.loginEmail,
            required: true,
            validator: (_) => state._emailError,
          ),
          if (state._emailError != null) _ErrText(state._emailError!),
          const SizedBox(height: 14),
          PhoneField(
            controller: state._telCtrl,
            label: l.registerPhone,
            required: true,
            onChanged: (full, valid) {
              // ignore: invalid_use_of_protected_member
              state.setState(() {
                state._phoneFull  = full;
                state._phoneValid = valid;
              });
            },
          ),
          const SizedBox(height: 14),
          PasswordStrengthField(
            controller: state._passCtrl,
            hint: l.loginPasswordHint,
            label: l.loginPassword,
            required: true,
            validator: (_) => state._passError,
          ),
          if (state._passError != null) _ErrText(state._passError!),
          const SizedBox(height: 14),
          ConfirmPasswordField(
            controller: state._confCtrl,
            originalController: state._passCtrl,
            hint: l.loginPasswordHint,
            label: l.registerConfirmPass,
            required: true,
          ),
          if (state._confError != null) _ErrText(state._confError!),
        ],
      ),
    );
  }
}
