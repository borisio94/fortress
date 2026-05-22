import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/form_sheet.dart';

/// Formulaire création / édition d'un plan d'abonnement (SA-2, super-admin).
/// Travaille directement sur la map brute d'un plan (table `plans`) : pas
/// de dépendance à l'enum `PlanType` (qui ne couvre que les plans seedés),
/// afin de permettre la création de plans arbitraires.
///
/// [existing] null → création (id généré côté serveur). Sinon édition.
/// Soumission via `AppDatabase.upsertPlan`. Retourne `true` au pop si une
/// modification a été enregistrée (le caller rafraîchit la liste).
class PlanFormSheet extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const PlanFormSheet({super.key, this.existing});

  @override
  State<PlanFormSheet> createState() => _PlanFormSheetState();
}

class _PlanFormSheetState extends State<PlanFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _label;
  late final TextEditingController _priceM;
  late final TextEditingController _priceQ;
  late final TextEditingController _priceY;
  late final TextEditingController _maxProducts;
  late final TextEditingController _maxMembers;
  late final TextEditingController _maxShops;
  late final TextEditingController _trialDays;
  late bool _offline;
  late bool _isActive;
  late Set<String> _features;
  bool _saving = false;

  /// Features connues (alignées sur l'enum `Feature` côté abonnement +
  /// seed SQL hotfix_017). L'utilisateur en sélectionne via chips.
  static const _availableFeatures = <String>[
    'multiShop',
    'advancedReports',
    'csvExport',
    'finances',
    'apiIntegration',
  ];

  static const _featureLabels = <String, String>{
    'multiShop':       'Multi-boutiques',
    'advancedReports': 'Rapports avancés',
    'csvExport':       'Export CSV/PDF',
    'finances':        'Module finances',
    'apiIntegration':  'Intégration API',
  };

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name        = TextEditingController(text: e?['name']?.toString() ?? '');
    _label       = TextEditingController(text: e?['label']?.toString() ?? '');
    _priceM      = TextEditingController(text: _numStr(e?['price_monthly']));
    _priceQ      = TextEditingController(text: _numStr(e?['price_quarterly']));
    _priceY      = TextEditingController(text: _numStr(e?['price_yearly']));
    _maxProducts = TextEditingController(text: _numStr(e?['max_products'], def: '50'));
    _maxMembers  = TextEditingController(text: _numStr(e?['max_users_per_shop'], def: '1'));
    _maxShops    = TextEditingController(text: _numStr(e?['max_shops'], def: '1'));
    _trialDays   = TextEditingController(text: _numStr(e?['trial_days'], def: '0'));
    _offline     = e?['offline_enabled'] == true;
    _isActive    = e?['is_active'] as bool? ?? true;
    _features    = ((e?['features'] as List?) ?? const [])
        .map((x) => x.toString())
        .toSet();
  }

  static String _numStr(dynamic v, {String def = ''}) =>
      v == null ? def : (v as num).toString();

  @override
  void dispose() {
    for (final c in [
      _name, _label, _priceM, _priceQ, _priceY,
      _maxProducts, _maxMembers, _maxShops, _trialDays,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  int _int(TextEditingController c, int fallback) =>
      int.tryParse(c.text.trim()) ?? fallback;
  num _num(TextEditingController c) =>
      num.tryParse(c.text.trim().replaceAll(',', '.')) ?? 0;

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await AppDatabase.upsertPlan(
        id:              widget.existing?['id'] as String?,
        name:            _name.text.trim(),
        label:           _label.text.trim(),
        priceMonthly:    _num(_priceM),
        priceQuarterly:  _num(_priceQ),
        priceYearly:     _num(_priceY),
        maxProducts:     _int(_maxProducts, 50),
        maxUsersPerShop: _int(_maxMembers, 1),
        maxShops:        _int(_maxShops, 1),
        features:        _features.toList(),
        offlineEnabled:  _offline,
        trialDays:       _int(_trialDays, 0),
        isActive:        _isActive,
      );
      if (mounted) {
        AppSnack.success(context,
            widget.existing == null ? 'Plan créé' : 'Plan mis à jour');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Échec : $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Form(
          key: _formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FormSheetHeader(title: isEdit ? 'Modifier le plan' : 'Nouveau plan'),
            _field(_name, 'Nom technique (ex: pro)', required: true),
            _field(_label, 'Libellé affiché (ex: Pro)', required: true),
            Row(children: [
              Expanded(child: _field(_priceM, 'Prix /mois', number: true)),
              const SizedBox(width: 10),
              Expanded(child: _field(_priceQ, 'Prix /trim.', number: true)),
            ]),
            Row(children: [
              Expanded(child: _field(_priceY, 'Prix /an', number: true)),
              const SizedBox(width: 10),
              Expanded(child: _field(_trialDays, 'Jours d\'essai', number: true)),
            ]),
            Row(children: [
              Expanded(child: _field(_maxProducts, 'Max produits', number: true)),
              const SizedBox(width: 10),
              Expanded(child: _field(_maxMembers, 'Max membres', number: true)),
            ]),
            _field(_maxShops, 'Max boutiques', number: true),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Fonctionnalités incluses',
                  style: AppTextStyles.captionBold),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final f in _availableFeatures)
                FilterChip(
                  label: Text(_featureLabels[f] ?? f),
                  selected: _features.contains(f),
                  onSelected: (sel) => setState(() {
                    if (sel) {
                      _features.add(f);
                    } else {
                      _features.remove(f);
                    }
                  }),
                  selectedColor: AppColors.primary.withValues(alpha: 0.18),
                  checkmarkColor: AppColors.primary,
                ),
            ]),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Mode hors-ligne', style: AppTextStyles.body),
              value: _offline,
              onChanged: (v) => setState(() => _offline = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Plan actif (visible / souscriptible)',
                  style: AppTextStyles.body),
              value: _isActive,
              onChanged: (v) => setState(() => _isActive = v),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _submit,
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                child: _saving
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(isEdit ? 'Enregistrer' : 'Créer le plan',
                        style: AppTextStyles.label.copyWith(
                            color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label,
      {bool number = false, bool required = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        controller: c,
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        decoration: InputDecoration(labelText: label, isDense: true),
        validator: required
            ? (v) => (v == null || v.trim().isEmpty) ? 'Requis' : null
            : null,
      ),
    );
  }
}
