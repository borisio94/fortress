import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/country_phone_data.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AppField — champ de saisie unifié (texte + téléphone)
//
// Mode normal  : AppField(hint: '...', prefixIcon: Icons.person_outline)
// Mode phone   : AppField(isPhone: true, label: 'Téléphone')
//   → intègre sélecteur pays + validation E.164 + indicateur vert/rouge
// ─────────────────────────────────────────────────────────────────────────────

enum AppFieldStyle { filled, white }

class AppField extends StatefulWidget {
  final TextEditingController? controller;
  final String hint;
  final IconData? prefixIcon;
  final Widget? suffixIcon;
  final bool obscure;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final int maxLines;
  final AppFieldStyle style;
  final bool isDense;
  final bool numbersOnly;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool enabled;

  // ── Mode téléphone ────────────────────────────────────────────────────────
  final bool isPhone;
  final void Function(String fullNumber, bool isValid)? onPhoneChanged;

  const AppField({
    super.key,
    this.controller,
    this.hint = '',
    this.prefixIcon,
    this.suffixIcon,
    this.obscure = false,
    this.keyboardType,
    this.validator,
    this.onChanged,
    this.maxLines = 1,
    this.style = AppFieldStyle.filled,
    this.isDense = true,
    this.numbersOnly = false,
    this.autofocus = false,
    this.focusNode,
    this.enabled = true,
    // phone mode
    this.isPhone = false,
    this.onPhoneChanged,
  });

  @override
  State<AppField> createState() => _AppFieldState();
}

class _AppFieldState extends State<AppField> {
  bool _hasValue  = false;

  // ── Phone state ───────────────────────────────────────────────────────────
  late CountryPhoneData _country;
  bool   _phoneValid  = false;
  bool   _phoneHasInput = false;

  static CountryPhoneData get _defaultCountry =>
      kCountries.firstWhere((c) => c.isoCode == 'CM');

  @override
  void initState() {
    super.initState();
    _country  = _defaultCountry;
    _hasValue = widget.controller?.text.isNotEmpty ?? false;
    widget.controller?.addListener(_onTextChanged);
    if (widget.isPhone && widget.controller != null) {
      final existing = widget.controller!.text;
      if (existing.isNotEmpty) {
        // Édition : la valeur vient de la base en format complet
        // (ex: "+237612345678"). Détecter le pays via le dialCode
        // le plus long qui match, puis ne garder que la partie locale
        // dans le TextField pour éviter que l'utilisateur voie "237..."
        // devant son numéro — l'indicatif est déjà affiché par le
        // sélecteur pays à gauche.
        final detected = _detectCountry(existing);
        if (detected != null) {
          _country = detected;
          final stripped = _stripDialCode(existing, detected);
          if (stripped != existing) {
            // Met à jour le controller sans redéclencher _onTextChanged
            widget.controller!.removeListener(_onTextChanged);
            widget.controller!.value = TextEditingValue(
              text: stripped,
              selection: TextSelection.collapsed(offset: stripped.length),
            );
            widget.controller!.addListener(_onTextChanged);
          }
        }
        _phoneHasInput = true;
        _phoneValid    = _country.pattern.hasMatch(_buildFull(
            widget.controller!.text));
      }
    }
  }

  /// Retrouve le [CountryPhoneData] dont le dialCode préfixe le numéro
  /// fourni. Tolère avec ou sans `+` et ignore espaces/séparateurs.
  /// Privilégie le dialCode le plus long en cas de conflit (ex: +1 vs +12x).
  CountryPhoneData? _detectCountry(String raw) {
    final compact = raw.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    final normalized = compact.startsWith('+') ? compact : '+$compact';
    CountryPhoneData? best;
    for (final c in kCountries) {
      if (normalized.startsWith(c.dialCode)) {
        if (best == null || c.dialCode.length > best.dialCode.length) {
          best = c;
        }
      }
    }
    return best;
  }

  /// Retire le dialCode en tête et retourne uniquement la partie locale,
  /// sans espaces/séparateurs.
  String _stripDialCode(String raw, CountryPhoneData country) {
    final compact = raw.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    final normalized = compact.startsWith('+') ? compact : '+$compact';
    if (normalized.startsWith(country.dialCode)) {
      return normalized.substring(country.dialCode.length);
    }
    return raw;
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final hasVal = widget.controller!.text.isNotEmpty;
    if (hasVal != _hasValue) setState(() => _hasValue = hasVal);
    if (widget.isPhone) _validatePhone(widget.controller!.text);
  }

  void _validatePhone(String raw) {
    final full  = _buildFull(raw);
    final valid = raw.trim().isNotEmpty && _country.pattern.hasMatch(full);
    setState(() {
      _phoneHasInput = raw.trim().isNotEmpty;
      _phoneValid    = valid;
    });
    widget.onPhoneChanged?.call(full, valid);
  }

  String _buildFull(String local) {
    final digits = local.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return '';
    return '${_country.dialCode}$digits';
  }

  String get _phoneHint {
    final ex   = _country.example;
    final code = _country.dialCode;
    return ex.startsWith(code) ? ex.substring(code.length).trim() : ex;
  }

  // ── Border helpers ────────────────────────────────────────────────────────
  Color get _borderColor {
    if (widget.isPhone) {
      if (!_phoneHasInput) return AppColors.primary.withOpacity(0.5);
      return _phoneValid ? AppColors.primary : AppColors.error;
    }
    return _hasValue
        ? AppColors.primary.withOpacity(0.5)
        : const Color(0xFFE5E7EB);
  }

  double get _borderWidth {
    if (widget.isPhone) return _phoneHasInput && _phoneValid ? 1.5 : 1.0;
    return 1.0;
  }

  OutlineInputBorder _border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color, width: width),
      );

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return widget.isPhone ? _buildPhoneField() : _buildNormalField();
  }

  // ── Mode téléphone ────────────────────────────────────────────────────────
  Widget _buildPhoneField() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _borderColor, width: _borderWidth),
      ),
      child: Row(children: [
        // Sélecteur pays
        _CountryPicker(
          selected: _country,
          onSelected: (c) {
            setState(() => _country = c);
            if (widget.controller != null)
              _validatePhone(widget.controller!.text);
          },
        ),
        // Séparateur
        Container(
          width: 1, height: 22,
          color: const Color(0xFFE5E7EB),
          margin: const EdgeInsets.symmetric(horizontal: 4),
        ),
        // Saisie
        Expanded(
          child: TextField(
            controller:     widget.controller,
            keyboardType:   TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d\s\-\(\)]')),
            ],
            style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
            decoration: InputDecoration(
              hintText: _phoneHint,
              hintStyle: const TextStyle(
                  fontSize: 12, color: Color(0xFFBBBBBB)),
              border:         InputBorder.none,
              enabledBorder:  InputBorder.none,
              focusedBorder:  InputBorder.none,
              errorBorder:    InputBorder.none,
              disabledBorder: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 11),
            ),
          ),
        ),
        // Indicateur validation
        if (_phoneHasInput)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                _phoneValid
                    ? Icons.check_circle_rounded
                    : Icons.cancel_rounded,
                key: ValueKey(_phoneValid),
                size: 16,
                color: _phoneValid ? AppColors.secondary : AppColors.error,
              ),
            ),
          ),
      ]),
    );
  }

  // ── Mode normal ───────────────────────────────────────────────────────────
  Widget _buildNormalField() {
    final fillColor = widget.style == AppFieldStyle.white
        ? Colors.white
        : const Color(0xFFF9FAFB);

    return TextFormField(
      controller:   widget.controller,
      obscureText:  widget.obscure,
      keyboardType: widget.keyboardType,
      validator:    widget.validator,
      maxLines:     widget.maxLines,
      autofocus:    widget.autofocus,
      focusNode:    widget.focusNode,
      enabled:      widget.enabled,
      style: const TextStyle(fontSize: 13, color: Color(0xFF1A1D2E)),
      inputFormatters: widget.numbersOnly
          ? [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))]
          : null,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: const TextStyle(
            color: Color(0xFFBBBBBB), fontSize: 13),
        prefixIcon: widget.prefixIcon != null
            ? Icon(widget.prefixIcon, size: 15,
            color: const Color(0xFFAAAAAA))
            : null,
        suffixIcon: widget.suffixIcon,
        filled:    true,
        fillColor: fillColor,
        isDense:   widget.isDense,
        contentPadding:
        const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        border:        _border(const Color(0xFFE5E7EB)),
        enabledBorder: _border(_borderColor, width: _borderWidth),
        focusedBorder: _border(AppColors.primary, width: 1.5),
        errorBorder:   _border(AppColors.error),
        focusedErrorBorder: _border(AppColors.error, width: 1.5),
      ),
    );
  }
}

// ─── Sélecteur pays ────────────────────────────────────────────────────────
class _CountryPicker extends StatelessWidget {
  final CountryPhoneData selected;
  final void Function(CountryPhoneData) onSelected;
  const _CountryPicker({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) => PopupMenuButton<CountryPhoneData>(
    onSelected: onSelected,
    color: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    elevation: 4,
    offset: const Offset(0, 40),
    constraints: const BoxConstraints(maxHeight: 320),
    itemBuilder: (_) => kCountries.map((c) => PopupMenuItem(
      value: c,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Text(c.isoCode,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF374151))),
        const SizedBox(width: 8),
        Text(c.dialCode,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF374151))),
        const SizedBox(width: 6),
        Expanded(child: Text(c.nameFr,
            style: const TextStyle(
                fontSize: 12, color: Color(0xFF6B7280)),
            overflow: TextOverflow.ellipsis)),
      ]),
    )).toList(),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('${selected.isoCode} ${selected.dialCode}',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF374151))),
            const SizedBox(width: 2),
            const Icon(Icons.keyboard_arrow_down_rounded,
                size: 14, color: Color(0xFF9CA3AF)),
          ]),
    ),
  );
}

// ─── PhoneField — garde son nom, délègue à AppField(isPhone: true) ──────────
class PhoneField extends StatelessWidget {
  final TextEditingController? controller;
  final String? initialValue;
  final void Function(String fullNumber, bool isValid)? onChanged;
  final String? label;
  final bool required;

  const PhoneField({
    super.key,
    this.controller,
    this.initialValue,
    this.onChanged,
    this.label,
    this.required = false,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (label != null) ...[
        AppFieldLabel(label!, required: required),
        const SizedBox(height: 4),
      ],
      AppField(
        controller:    controller,
        isPhone:       true,
        onPhoneChanged: onChanged,
      ),
    ],
  );
}

// ─── Label de champ avec astérisque optionnel ─────────────────────────────
class AppFieldLabel extends StatelessWidget {
  final String text;
  final bool required;
  const AppFieldLabel(this.text, {super.key, this.required = false});

  @override
  Widget build(BuildContext context) => RichText(
    text: TextSpan(
      style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: Color(0xFF6B7280)),
      children: [
        TextSpan(text: text),
        if (required)
          const TextSpan(
              text: ' *',
              style: TextStyle(
                  color: Color(0xFFEF4444),
                  fontWeight: FontWeight.w700,
                  fontSize: 12)),
      ],
    ),
  );
}

// ─── AppLabeledField : label + champ regroupés ────────────────────────────
class AppLabeledField extends StatelessWidget {
  final String label;
  final bool required;
  final Widget child;

  const AppLabeledField({
    super.key,
    required this.label,
    this.required = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (label.isNotEmpty) ...[
        AppFieldLabel(label, required: required),
        const SizedBox(height: 4),
      ],
      child,
    ],
  );
}