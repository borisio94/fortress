import 'package:flutter/material.dart';
import '../../core/validators/input_validators.dart';
import '../../core/validators/password_policy.dart';
import 'app_field.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// Champs d'authentification unifiés. Tous utilisent [AppField] sous le capot
/// pour conserver un look-and-feel parfaitement cohérent à travers l'app.
///
/// Inputs disponibles :
///   - [EmailField]            : email + validator + icône
///   - [NameField]             : nom + validator + icône
///   - [PasswordField]         : mot de passe + toggle visibilité
///   - [PasswordStrengthField] : PasswordField + barre de force colorée
///   - [ConfirmPasswordField]  : confirmation + match avec une autre source
///
/// Pour le téléphone, utiliser [PhoneField] de `app_field.dart`.
/// ─────────────────────────────────────────────────────────────────────────────

// ═══════════════════════════════════════════════════════════════════════════
// EmailField
// ═══════════════════════════════════════════════════════════════════════════
class EmailField extends StatelessWidget {
  final TextEditingController? controller;
  final String hint;
  final String? label;
  final bool required;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final String? Function(String?)? validator;
  final bool enabled;

  const EmailField({
    super.key,
    this.controller,
    this.hint = 'votre@email.com',
    this.label,
    this.required = false,
    this.onChanged,
    this.autofocus = false,
    this.focusNode,
    this.textInputAction,
    this.validator,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final field = AppField(
      controller: controller,
      hint: hint,
      prefixIcon: Icons.alternate_email_rounded,
      keyboardType: TextInputType.emailAddress,
      validator: validator ?? InputValidators.email,
      onChanged: onChanged,
      autofocus: autofocus,
      focusNode: focusNode,
      enabled: enabled,
    );
    return label != null
        ? AppLabeledField(
            label: label!, required: required, child: field)
        : field;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// NameField
// ═══════════════════════════════════════════════════════════════════════════
class NameField extends StatelessWidget {
  final TextEditingController? controller;
  final String hint;
  final String? label;
  final bool required;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final FocusNode? focusNode;
  final String? Function(String?)? validator;

  const NameField({
    super.key,
    this.controller,
    this.hint = 'Nom complet',
    this.label,
    this.required = false,
    this.onChanged,
    this.autofocus = false,
    this.focusNode,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    final field = AppField(
      controller: controller,
      hint: hint,
      prefixIcon: Icons.person_outline_rounded,
      keyboardType: TextInputType.name,
      validator: validator ?? InputValidators.name,
      onChanged: onChanged,
      autofocus: autofocus,
      focusNode: focusNode,
    );
    return label != null
        ? AppLabeledField(
            label: label!, required: required, child: field)
        : field;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PasswordField — mot de passe simple avec toggle visibilité
// ═══════════════════════════════════════════════════════════════════════════
class PasswordField extends StatefulWidget {
  final TextEditingController? controller;
  final String hint;
  final String? label;
  final bool required;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final String? Function(String?)? validator;
  final bool autofocus;

  const PasswordField({
    super.key,
    this.controller,
    this.hint = 'Mot de passe',
    this.label,
    this.required = false,
    this.onChanged,
    this.focusNode,
    this.validator,
    this.autofocus = false,
  });

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final field = AppField(
      controller: widget.controller,
      hint: widget.hint,
      prefixIcon: Icons.lock_outline_rounded,
      obscure: _obscure,
      validator: widget.validator ?? InputValidators.password,
      onChanged: widget.onChanged,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      suffixIcon: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        splashRadius: 18,
        icon: Icon(
          _obscure
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined,
          size: 18,
          color: const Color(0xFF9CA3AF),
        ),
        onPressed: () => setState(() => _obscure = !_obscure),
      ),
    );
    return widget.label != null
        ? AppLabeledField(
            label: widget.label!,
            required: widget.required,
            child: field)
        : field;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// ConfirmPasswordField — match avec un autre controller
// ═══════════════════════════════════════════════════════════════════════════
class ConfirmPasswordField extends StatelessWidget {
  final TextEditingController? controller;
  final TextEditingController originalController;
  final String hint;
  final String? label;
  final bool required;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;

  const ConfirmPasswordField({
    super.key,
    required this.originalController,
    this.controller,
    this.hint = 'Confirmer le mot de passe',
    this.label,
    this.required = false,
    this.onChanged,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return PasswordField(
      controller: controller,
      hint: hint,
      label: label,
      required: required,
      onChanged: onChanged,
      focusNode: focusNode,
      validator:
          InputValidators.confirmPassword(() => originalController.text),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PasswordStrengthField — PasswordField + indicateur de force visuel
// ═══════════════════════════════════════════════════════════════════════════
class PasswordStrengthField extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final String? label;
  final bool required;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final String? Function(String?)? validator;
  final bool autofocus;

  /// Si true, le validator par défaut refuse les mots de passe `weak`.
  /// Sinon (défaut), accepte tout mot de passe ≥ 8 caractères.
  final bool strict;

  /// Si true, masque l'indicateur visuel quand le champ est vide.
  /// Évite de polluer le formulaire avant que l'utilisateur ne tape.
  final bool hideWhenEmpty;

  const PasswordStrengthField({
    super.key,
    required this.controller,
    this.hint = 'Mot de passe',
    this.label,
    this.required = false,
    this.onChanged,
    this.focusNode,
    this.validator,
    this.autofocus = false,
    this.strict = false,
    this.hideWhenEmpty = true,
  });

  @override
  State<PasswordStrengthField> createState() => _PasswordStrengthFieldState();
}

class _PasswordStrengthFieldState extends State<PasswordStrengthField> {
  PasswordStrength _strength = PasswordStrength.empty;

  @override
  void initState() {
    super.initState();
    _strength = PasswordPolicy.evaluate(widget.controller.text);
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final next = PasswordPolicy.evaluate(widget.controller.text);
    if (next.level != _strength.level || next.score != _strength.score) {
      setState(() => _strength = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final defaultValidator =
        widget.strict ? InputValidators.passwordStrict : InputValidators.password;
    final colors = PasswordStrengthColors.fallback();
    final showIndicator =
        !widget.hideWhenEmpty || widget.controller.text.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PasswordField(
          controller: widget.controller,
          hint: widget.hint,
          label: widget.label,
          required: widget.required,
          onChanged: widget.onChanged,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          validator: widget.validator ?? defaultValidator,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: showIndicator
              ? Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _StrengthBar(strength: _strength, colors: colors),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Indicateur visuel — barre de progression + label coloré
// ═══════════════════════════════════════════════════════════════════════════
class _StrengthBar extends StatelessWidget {
  final PasswordStrength strength;
  final PasswordStrengthColors colors;

  const _StrengthBar({required this.strength, required this.colors});

  @override
  Widget build(BuildContext context) {
    final color = colors.colorFor(strength.level);
    final label = passwordStrengthLabelFr(strength.level);
    final ratio = (strength.score / 100.0).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LayoutBuilder(
            builder: (context, c) => Stack(children: [
              Container(
                  height: 4, width: c.maxWidth, color: colors.empty),
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                height: 4,
                width: c.maxWidth * ratio,
                color: color,
              ),
            ]),
          ),
        ),
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
      ],
    );
  }
}
