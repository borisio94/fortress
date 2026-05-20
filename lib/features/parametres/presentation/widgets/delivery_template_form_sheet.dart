import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/app_switch.dart';
import '../../domain/entities/delivery_template.dart';
import '../providers/delivery_template_provider.dart';

/// Bottom-sheet d'édition / création d'un template de livraison.
///
/// Utilisation :
/// ```dart
/// showModalBottomSheet<bool>(
///   context: context,
///   isScrollControlled: true,
///   isDismissible: false,
///   builder: (_) => DeliveryTemplateFormSheet(
///     shopId: shopId,
///     existing: tplOrNull,
///   ),
/// );
/// ```
/// Retourne `true` si un template a été sauvegardé, `null`/`false` sinon.
class DeliveryTemplateFormSheet extends ConsumerStatefulWidget {
  final String            shopId;
  final DeliveryTemplate? existing;
  const DeliveryTemplateFormSheet({
    super.key,
    required this.shopId,
    this.existing,
  });

  @override
  ConsumerState<DeliveryTemplateFormSheet> createState() =>
      _DeliveryTemplateFormSheetState();
}

class _DeliveryTemplateFormSheetState
    extends ConsumerState<DeliveryTemplateFormSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _bodyCtrl;
  /// Focus du champ body — gardé pour pouvoir le re-focuser après un
  /// click sur une variable (insertion à la position du curseur).
  final _bodyFocus = FocusNode();
  bool   _isDefault = false;
  bool   _saving    = false;
  String? _nameError, _bodyError;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl  = TextEditingController(text: e?.name ?? '');
    _bodyCtrl  = TextEditingController(text: e?.body ?? '');
    _isDefault = e?.isDefault ?? false;
  }

  /// Insère `{{name}}` à la position courante du curseur (ou remplace la
  /// sélection si non vide). Re-focus le champ pour permettre à
  /// l'utilisateur de continuer la saisie sans toucher l'écran.
  void _insertVariable(String name) {
    final placeholder = '{{$name}}';
    final text = _bodyCtrl.text;
    var selection = _bodyCtrl.selection;
    // Si la sélection est invalide (champ jamais focus), insère en fin.
    if (!selection.isValid) {
      selection = TextSelection.collapsed(offset: text.length);
    }
    final start = selection.start;
    final end   = selection.end;
    final newText = text.replaceRange(start, end, placeholder);
    final newCursor = start + placeholder.length;
    _bodyCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
    // Repasse le focus sur le champ body après le clic sur la chip.
    _bodyFocus.requestFocus();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _bodyCtrl.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = context.l10n;
    final name = _nameCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    setState(() {
      _nameError = name.isEmpty ? l.deliveryTplNameRequired : null;
      _bodyError = body.isEmpty ? l.deliveryTplBodyRequired : null;
    });
    if (_nameError != null || _bodyError != null) return;

    setState(() => _saving = true);
    try {
      final notifier =
          ref.read(deliveryTemplatesProvider(widget.shopId).notifier);
      if (widget.existing == null) {
        await notifier.createTemplate(
            name: name, body: body, isDefault: _isDefault);
      } else {
        await notifier.updateTemplate(widget.existing!.copyWith(
            name: name, body: body, isDefault: _isDefault));
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        // Détection du conflit de nom (UNIQUE constraint).
        final msg = e.toString();
        AppSnack.error(context,
            msg.contains('delivery_templates_name_per_shop')
                ? l.deliveryTplNameDuplicate
                : msg);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final isEdit = widget.existing != null;

    return AdaptiveFormFrame(
      title: isEdit
          ? l.deliveryTplFormEditTitle
          : l.deliveryTplFormCreateTitle,
      icon: Icons.message_rounded,
      body: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppFieldLabel(l.deliveryTplFormName, required: true),
                  const SizedBox(height: 4),
                  AppField(
                    controller: _nameCtrl,
                    hint: l.deliveryTplFormNameHint,
                    prefixIcon: Icons.label_outline_rounded,
                    validator: (_) => _nameError,
                  ),
                  const SizedBox(height: 14),
                  AppFieldLabel(l.deliveryTplFormBody, required: true),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _bodyCtrl,
                    focusNode: _bodyFocus,
                    maxLines: null,
                    minLines: 8,
                    style: const TextStyle(
                        fontSize: 12, height: 1.5,
                        fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: l.deliveryTplFormBodyHint,
                      hintStyle: const TextStyle(
                          fontSize: 11, color: Color(0xFFBBBBBB)),
                      filled: true,
                      fillColor: const Color(0xFFF9FAFB),
                      contentPadding: const EdgeInsets.all(12),
                      border: _outlineBorder(_bodyError != null),
                      enabledBorder: _outlineBorder(_bodyError != null),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: AppColors.primary, width: 1.5)),
                      errorText: _bodyError,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _VariablesHint(l: l, onInsert: _insertVariable),
                  const SizedBox(height: 14),
                  // Switch "Définir par défaut"
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Row(children: [
                      Expanded(
                        child: Text(l.deliveryTplFormDefault,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ),
                      AppSwitch(
                        value: _isDefault,
                        onChanged: _saving
                            ? null
                            : (v) => setState(() => _isDefault = v),
                      ),
                    ]),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFF0F0F0)),
            Padding(
              padding: const EdgeInsets.all(14),
              child: SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.check_rounded, size: 16),
                  label: Text(
                      isEdit
                          ? l.commonSave
                          : l.commonCreate,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                ),
              ),
            ),
          ]),
    );
  }

  OutlineInputBorder _outlineBorder(bool hasError) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(
          color: hasError ? AppColors.error : const Color(0xFFE5E7EB)));
}

/// Encart d'aide listant les variables disponibles. Tap sur une chip
/// l'insère à la position du curseur du champ body via `onInsert`.
class _VariablesHint extends StatelessWidget {
  final AppLocalizations l;
  /// Appelé quand l'utilisateur tap sur une chip variable. Le caller
  /// s'occupe d'insérer `{{name}}` à la position du curseur du body.
  final ValueChanged<String> onInsert;
  const _VariablesHint({required this.l, required this.onInsert});

  static const _vars = [
    'caisse', 'client_name', 'client_phone', 'lieu_livraison',
    'ville_expedition',
    'produits', 'date', 'heure',
    'prix_produit', 'frais_livraison', 'total', 'notes',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.primarySurface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.touch_app_rounded,
              size: 12, color: AppColors.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                '${l.deliveryTplFormVarsHint} '
                '— tap pour insérer',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                    color: AppColors.primary)),
          ),
        ]),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4, runSpacing: 4,
          children: [
            for (final v in _vars)
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => onInsert(v),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.3))),
                child: Text('{{$v}}',
                    style: TextStyle(
                        fontSize: 9,
                        fontFamily: 'monospace',
                        color: AppColors.primary)),
              ),
            ),
          ),
          ],
        ),
      ]),
    );
  }
}
