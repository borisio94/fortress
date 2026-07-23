import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/app_switch.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
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
  /// Pré-sélection du scope à la création (hotfix_093). Null = shop-wide.
  /// Sinon id d'un partenaire (StockLocation.id) — le template sera lié
  /// à ce partenaire uniquement. Ignoré en édition (le scope du template
  /// existant est lu sur `existing.partnerId`).
  final String?           initialPartnerId;
  const DeliveryTemplateFormSheet({
    super.key,
    required this.shopId,
    this.existing,
    this.initialPartnerId,
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
  /// Scope du template : null = shop-wide, sinon id partenaire.
  String? _partnerId;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl  = TextEditingController(text: e?.name ?? '');
    _bodyCtrl  = TextEditingController(text: e?.body ?? '');
    _isDefault = e?.isDefault ?? false;
    _partnerId = e?.partnerId ?? widget.initialPartnerId;
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
            name: name, body: body, isDefault: _isDefault,
            partnerId: _partnerId);
      } else {
        // Edition : on persiste aussi le scope (permet de RE-PORTER un
        // template d'un partenaire à un autre ou vers shop-wide).
        await notifier.updateTemplate(widget.existing!.copyWith(
            name: name, body: body, isDefault: _isDefault,
            partnerId: _partnerId,
            clearPartnerId: _partnerId == null));
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        // Détection du conflit de nom (UNIQUE constraint). Le nom de
        // l'index a changé avec hotfix_093 : ancien
        // `delivery_templates_name_per_shop` → nouveau scope-aware
        // `delivery_templates_name_per_scope_uniq`. On garde les deux
        // patterns pour rester rétro-compatible avec un Postgres pas
        // encore migré.
        final msg = e.toString();
        AppSnack.error(context,
            msg.contains('delivery_templates_name_per_shop') ||
            msg.contains('delivery_templates_name_per_scope_uniq')
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
                  // ── Scope picker (hotfix_093) ──────────────────────────
                  const AppFieldLabel('Portée'),
                  const SizedBox(height: 4),
                  _ScopePicker(
                    shopId:     widget.shopId,
                    selectedId: _partnerId,
                    onChanged:  _saving
                        ? null
                        : (v) => setState(() => _partnerId = v),
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
                      fillColor: AppColors.inputFill,
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
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Theme.of(context).semantic.borderSubtle),
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
          color: hasError ? AppColors.error : AppColors.divider));
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
    'caisse',
    // Titre dynamique (NOUVELLE LIVRAISON / LIVRAISON RELANCÉE) + référence
    // courte de la commande.
    'titre_livraison', 'reference',
    'client_name', 'client_phone', 'lieu_livraison',
    'ville_expedition',
    // {{produits}} : lien court vers la mini-vitrine catalogue de la
    // commande (images + quantités) en contexte envoi, sinon retombe sur
    // la liste texte. {{produits_text}} = toujours la liste texte (compat).
    'produits', 'produits_text',
    'date', 'heure',
    'prix_produit', 'frais_livraison', 'total', 'notes',
    // Variables partenaire (hotfix_093) — résolues depuis la StockLocation
    // ciblée par le transfert. Vides + ligne supprimée si pas de partenaire
    // (employé ou numéro libre).
    'partner_name', 'partner_phone', 'partner_city', 'partner_notes',
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
                    color: Theme.of(context).colorScheme.surface,
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
        // Légende des variables de MONTANT — évite la confusion qui fait
        // envoyer au livreur un total sans les frais de livraison.
        const SizedBox(height: 8),
        Text(
          '💰 {{total}} = produits + livraison   ·   '
          '{{prix_produit}} = produits seuls   ·   '
          '{{frais_livraison}} = livraison seule',
          style: TextStyle(
              fontSize: 9, height: 1.5, color: AppColors.textSecondary),
        ),
      ]),
    );
  }
}

/// Picker de portée pour un template (hotfix_093) : shop-wide (défaut)
/// ou rattaché à un partenaire spécifique (StockLocation type=partner).
/// La liste des partenaires est lue depuis Hive (offline-friendly) via
/// `AppDatabase.getStockLocationsForOwner`. Les partenaires inactifs
/// sont masqués.
class _ScopePicker extends StatelessWidget {
  final String         shopId;
  final String?        selectedId;
  final ValueChanged<String?>? onChanged;
  const _ScopePicker({
    required this.shopId,
    required this.selectedId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Les partenaires sont owner-scoped (pas shop-scoped) — cf.
    // memory project_multishop_roadmap : partenaires = locations de
    // type 'partner' dans l'owner, partagés entre toutes ses boutiques.
    final ownerId = Supabase.instance.client.auth.currentUser?.id;
    final partners = ownerId == null
        ? const <StockLocation>[]
        : AppDatabase.getStockLocationsForOwner(ownerId)
            .where((l) => l.type == StockLocationType.partner && l.isActive)
            .toList();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          isExpanded: true,
          value: selectedId == null
              ? null
              : (partners.any((p) => p.id == selectedId) ? selectedId : null),
          icon: Icon(Icons.keyboard_arrow_down_rounded,
              size: 18, color: AppColors.textHint),
          items: <DropdownMenuItem<String?>>[
            DropdownMenuItem<String?>(
              value: null,
              child: Row(children: [
                Icon(Icons.store_outlined, size: 13, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                const Text('Shop — tous partenaires',
                    style: AppTextStyles.bodySm),
              ]),
            ),
            for (final p in partners)
              DropdownMenuItem<String?>(
                value: p.id,
                child: Row(children: [
                  // local_shipping plutôt que handshake — cf.
                  // project_icon_tree_shaking (handshake dans plan
                  // Unicode supplémentaire, à éviter).
                  Icon(Icons.local_shipping_outlined, size: 13,
                      color: AppColors.primary),
                  const SizedBox(width: 6),
                  Flexible(child: Text(p.name,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySm)),
                ]),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
