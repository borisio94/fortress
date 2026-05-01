import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

// ═════════════════════════════════════════════════════════════════════════════
// AutocompleteTextField — champ texte avec menu de suggestions filtrées.
//
// Usage :
//   AutocompleteTextField(
//     controller: _cityCtrl,
//     label: 'Ville',
//     hint: 'Yaoundé, Douala…',
//     suggestions: allCities,           // List<String> — valeurs déjà saisies
//     required: true,
//     validator: (v) => ...,
//     onChanged: (v) => ...,
//   )
//
// Comportement :
// • Au focus, le menu s'ouvre avec toutes les suggestions (triées alphabétique).
// • À chaque caractère saisi, la liste est filtrée (contains insensible à la
//   casse/accents) et limitée aux [maxSuggestions].
// • Tap sur une suggestion → remplit le champ et ferme le menu.
// • Le menu disparaît quand le champ perd le focus.
// • Zero dépendance externe — OverlayEntry + CompositedTransformFollower.
// ═════════════════════════════════════════════════════════════════════════════

class AutocompleteTextField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final List<String> suggestions;
  final bool required;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final int maxSuggestions;
  final IconData? prefixIcon;

  const AutocompleteTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.suggestions = const [],
    this.required = false,
    this.validator,
    this.onChanged,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.words,
    this.maxSuggestions = 8,
    this.prefixIcon,
  });

  @override
  State<AutocompleteTextField> createState() => _AutocompleteTextFieldState();
}

class _AutocompleteTextFieldState extends State<AutocompleteTextField> {
  final _focus = FocusNode();
  final _layerLink = LayerLink();
  OverlayEntry? _overlay;
  List<String> _filtered = const [];

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
    widget.controller.addListener(_onTextChange);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    widget.controller.removeListener(_onTextChange);
    _hideOverlay();
    super.dispose();
  }

  String _normalize(String s) => s
      .toLowerCase()
      .replaceAll('à', 'a').replaceAll('â', 'a').replaceAll('ä', 'a')
      .replaceAll('é', 'e').replaceAll('è', 'e').replaceAll('ê', 'e').replaceAll('ë', 'e')
      .replaceAll('î', 'i').replaceAll('ï', 'i')
      .replaceAll('ô', 'o').replaceAll('ö', 'o')
      .replaceAll('ù', 'u').replaceAll('û', 'u').replaceAll('ü', 'u')
      .replaceAll('ç', 'c');

  void _updateFiltered() {
    final q = _normalize(widget.controller.text.trim());
    // Déduplique, ignore les vides, trie alphabétique
    final unique = <String>{...widget.suggestions.where((s) => s.trim().isNotEmpty)};
    final base = unique.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final filtered = q.isEmpty
        ? base
        : base.where((s) => _normalize(s).contains(q)).toList();
    _filtered = filtered.take(widget.maxSuggestions).toList();
  }

  void _onFocusChange() {
    if (_focus.hasFocus) {
      _updateFiltered();
      _showOverlay();
    } else {
      // Petit délai : si l'utilisateur a tapé sur une suggestion, laisser
      // le temps à _pick() de s'exécuter avant de retirer l'overlay.
      Future.delayed(const Duration(milliseconds: 180), () {
        if (!mounted) return;
        if (!_focus.hasFocus) _hideOverlay();
      });
    }
  }

  void _onTextChange() {
    if (!_focus.hasFocus) return;
    _updateFiltered();
    _overlay?.markNeedsBuild();
  }

  void _showOverlay() {
    if (_overlay != null) return;
    _overlay = OverlayEntry(builder: (_) => _buildOverlay());
    Overlay.of(context).insert(_overlay!);
  }

  void _hideOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _pick(String value) {
    widget.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    widget.onChanged?.call(value);
    _hideOverlay();
    _focus.unfocus();
  }

  Widget _buildOverlay() {
    if (_filtered.isEmpty) return const SizedBox.shrink();
    final renderBox = context.findRenderObject() as RenderBox?;
    final width = renderBox?.size.width ?? 280;
    return Positioned(
      width: width,
      child: CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        offset: Offset(0, (renderBox?.size.height ?? 48) + 4),
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.separated(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: _filtered.length,
              separatorBuilder: (_, __) => const Divider(
                  height: 1, color: Color(0xFFF3F4F6)),
              itemBuilder: (_, i) {
                final v = _filtered[i];
                // GestureDetector + onTapDown : se déclenche AVANT la perte
                // de focus du TextField, sinon le tap est avalé.
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) => _pick(v),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    child: Row(children: [
                      const Icon(Icons.history_rounded,
                          size: 14, color: Color(0xFF9CA3AF)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(v,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13,
                              color: Color(0xFF0F172A)))),
                    ]),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: TextFormField(
        controller: widget.controller,
        focusNode: _focus,
        keyboardType: widget.keyboardType,
        textCapitalization: widget.textCapitalization,
        onChanged: widget.onChanged,
        validator: widget.validator ?? (v) {
          if (widget.required && (v == null || v.trim().isEmpty)) {
            return '${widget.label} requis';
          }
          return null;
        },
        decoration: InputDecoration(
          labelText: widget.required ? '${widget.label} *' : widget.label,
          hintText: widget.hint,
          isDense: true,
          prefixIcon: widget.prefixIcon != null
              ? Icon(widget.prefixIcon, size: 16,
                  color: const Color(0xFF9CA3AF))
              : null,
          labelStyle: const TextStyle(fontSize: 12),
          hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFD1D5DB)),
          contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
        ),
      ),
    );
  }
}
