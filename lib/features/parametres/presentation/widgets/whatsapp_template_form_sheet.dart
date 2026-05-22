import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/app_switch.dart';
import '../../domain/entities/whatsapp_template.dart';
import '../providers/whatsapp_template_provider.dart';

// ═════════════════════════════════════════════════════════════════════════════
// WhatsappTemplateFormSheet — création / édition d'un template.
//
// Champs :
//   • type (dropdown, désactivé en édition pour éviter de casser un défaut)
//   • nom
//   • body multiline avec hint des variables cliquables (insertion au curseur)
//   • switch "défaut pour ce type"
//
// La liste des variables affichées dépend du `type` sélectionné — change
// dynamiquement quand l'utilisateur switch le type en création.
// ═════════════════════════════════════════════════════════════════════════════

class WhatsappTemplateFormSheet extends ConsumerStatefulWidget {
  final String              shopId;
  final WhatsappTemplate?   existing;
  /// Si fourni en création, pré-sélectionne le type dans le dropdown.
  final WhatsappTemplateType? initialType;
  const WhatsappTemplateFormSheet({
    super.key,
    required this.shopId,
    this.existing,
    this.initialType,
  });

  @override
  ConsumerState<WhatsappTemplateFormSheet> createState() =>
      _WhatsappTemplateFormSheetState();
}

class _WhatsappTemplateFormSheetState
    extends ConsumerState<WhatsappTemplateFormSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _bodyCtrl;
  final _bodyFocus = FocusNode();
  late WhatsappTemplateType _type;
  bool   _isDefault = false;
  bool   _saving    = false;
  String? _nameError, _bodyError;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _type = e?.type ?? widget.initialType ?? WhatsappTemplateType.invoice;
    _nameCtrl  = TextEditingController(text: e?.name ?? '');
    _bodyCtrl  = TextEditingController(text: e?.body ?? _type.defaultBody);
    _isDefault = e?.isDefault ?? false;
  }

  void _insertVariable(String name) {
    final placeholder = '{{$name}}';
    final text = _bodyCtrl.text;
    var selection = _bodyCtrl.selection;
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
    final name = _nameCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    setState(() {
      _nameError = name.isEmpty ? 'Nom requis' : null;
      _bodyError = body.isEmpty ? 'Message requis' : null;
    });
    if (_nameError != null || _bodyError != null) return;

    setState(() => _saving = true);
    try {
      final notifier =
          ref.read(whatsappTemplatesProvider(widget.shopId).notifier);
      if (widget.existing == null) {
        await notifier.createTemplate(
            type: _type, name: name, body: body, isDefault: _isDefault);
      } else {
        await notifier.updateTemplate(widget.existing!.copyWith(
            type: _type, name: name, body: body, isDefault: _isDefault));
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        final msg = e.toString();
        AppSnack.error(context,
            msg.contains('whatsapp_templates_name_per_shop')
                ? 'Un template avec ce nom existe déjà.'
                : msg);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AdaptiveFormFrame(
      title: isEdit ? 'Modifier le template' : 'Nouveau template',
      icon: Icons.chat_outlined,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Type (dropdown). Désactivé en édition pour ne pas casser le
              // défaut courant du shop. Si l'utilisateur veut changer de
              // type, il duplique vers le nouveau type puis supprime
              // l'ancien.
              const AppFieldLabel('Type', required: true),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF9FAFB),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).semantic.borderSubtle),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<WhatsappTemplateType>(
                    value: _type,
                    isExpanded: true,
                    onChanged: isEdit
                        ? null
                        : (v) {
                            if (v == null) return;
                            setState(() {
                              _type = v;
                              // En création, on pré-remplit le body avec le
                              // default body du type — sauf si l'utilisateur
                              // a déjà modifié le champ.
                              if (_bodyCtrl.text.trim().isEmpty ||
                                  WhatsappTemplateType.values
                                      .any((t) => t.defaultBody ==
                                          _bodyCtrl.text)) {
                                _bodyCtrl.text = v.defaultBody;
                              }
                            });
                          },
                    items: [
                      for (final t in WhatsappTemplateType.values)
                        DropdownMenuItem(
                          value: t,
                          child: Text(t.label,
                              style: AppTextStyles.body),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const AppFieldLabel('Nom', required: true),
              const SizedBox(height: 4),
              AppField(
                controller: _nameCtrl,
                hint: 'Ex: Facture par défaut',
                prefixIcon: Icons.label_outline_rounded,
                validator: (_) => _nameError,
              ),
              const SizedBox(height: 14),
              const AppFieldLabel('Message', required: true),
              const SizedBox(height: 4),
              TextField(
                controller: _bodyCtrl,
                focusNode: _bodyFocus,
                maxLines: null,
                minLines: 8,
                style: const TextStyle(
                    fontSize: 12, height: 1.5, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  hintText:
                      'Tapez votre message. Insérez les variables ci-dessous '
                      'avec {{nom}}.',
                  hintStyle: AppTextStyles.caption.copyWith(
                      color: const Color(0xFFBBBBBB)),
                  filled: true,
                  fillColor: const Color(0xFFF9FAFB),
                  contentPadding: const EdgeInsets.all(12),
                  border: _outlineBorder(_bodyError != null),
                  enabledBorder: _outlineBorder(_bodyError != null),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          BorderSide(color: AppColors.primary, width: 1.5)),
                  errorText: _bodyError,
                ),
              ),
              const SizedBox(height: 8),
              _VariablesHint(type: _type, onInsert: _insertVariable),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF9FAFB),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).semantic.borderSubtle),
                ),
                child: Row(children: [
                  const Expanded(
                    child: Text('Définir comme défaut pour ce type',
                        style: AppTextStyles.bodySmBold),
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
        Divider(height: 1, color: Theme.of(context).semantic.borderSubtle),
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
              label: Text(isEdit ? 'Enregistrer' : 'Créer',
                  style: AppTextStyles.bodyBold.copyWith(
                      color: Colors.white)),
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

class _VariablesHint extends StatelessWidget {
  final WhatsappTemplateType type;
  final ValueChanged<String> onInsert;
  const _VariablesHint({required this.type, required this.onInsert});

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
          Icon(Icons.touch_app_rounded, size: 12, color: AppColors.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                'Variables disponibles pour ${type.label.toLowerCase()} '
                '— tap pour insérer',
                style: AppTextStyles.microBold.copyWith(
                    letterSpacing: 0.3,
                    color: AppColors.primary)),
          ),
        ]),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4, runSpacing: 4,
          children: [
            for (final v in type.variables)
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => onInsert(v),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                            color: AppColors.primary
                                .withValues(alpha: 0.3))),
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
