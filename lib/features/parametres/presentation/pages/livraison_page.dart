import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/delivery_zone_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/entities/delivery_quartier.dart';

/// Paramètres → Livraison : gestion des zones et des tarifs de livraison par
/// quartier (offline-first via [DeliveryZoneService]). PR-1 du système
/// « frais de livraison par quartier ».
class LivraisonPage extends StatefulWidget {
  final String shopId;
  const LivraisonPage({super.key, required this.shopId});

  @override
  State<LivraisonPage> createState() => _LivraisonPageState();
}

class _LivraisonPageState extends State<LivraisonPage> {
  late void Function(String, String) _listener;
  String? _selectedCity;

  @override
  void initState() {
    super.initState();
    _listener = (table, sid) {
      if (!mounted) return;
      if (sid != widget.shopId) return;
      if (table == 'delivery_zones' || table == 'delivery_quartiers') {
        setState(() {});
      }
    };
    AppDatabase.addListener(_listener);
    // Rafraîchit depuis Supabase à l'ouverture (silencieux si offline).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppDatabase.syncDeliveryZones(widget.shopId);
      AppDatabase.syncDeliveryQuartiers(widget.shopId);
    });
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  // ── Actions ───────────────────────────────────────────────────────────────
  /// Création (par LOT) : on peut ajouter plusieurs quartiers avant d'enregistrer.
  Future<void> _addQuartier({String? city}) async {
    final cities = DeliveryZoneService.citiesForShop(widget.shopId);
    final n = await showAdaptiveFormSheet<int>(
      context: context,
      builder: (_) => _QuartierFormSheet(
        shopId: widget.shopId,
        initialCity: city,
        knownCities: cities,
      ),
    );
    if (n != null && n > 0 && mounted) {
      AppSnack.success(context,
          '$n quartier${n > 1 ? 's' : ''} ajouté${n > 1 ? 's' : ''}');
    }
  }

  Future<void> _editQuartier(DeliveryQuartier q) async {
    final cities = DeliveryZoneService.citiesForShop(widget.shopId);
    final n = await showAdaptiveFormSheet<int>(
      context: context,
      builder: (_) => _QuartierFormSheet(
        shopId: widget.shopId,
        initialCity: q.city,
        knownCities: cities,
        existing: q,
      ),
    );
    if (n != null && n > 0 && mounted) {
      setState(() => _selectedCity = q.city);
      AppSnack.success(context, 'Quartier modifié');
    }
  }

  Future<void> _renameCity(String city) async {
    final ctrl = TextEditingController(text: city);
    final theme = Theme.of(context);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Renommer la ville', style: AppTextStyles.subtitleBold),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nom de la ville'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.primaryFill),
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Renommer'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (newName == null || newName.isEmpty || newName == city) return;
    await DeliveryZoneService.renameCity(widget.shopId, city, newName);
    if (mounted) {
      setState(() => _selectedCity = newName);
      AppSnack.success(context, 'Ville renommée');
    }
  }

  Future<void> _confirmDelete({
    required String title,
    required String message,
    required Future<void> Function() onConfirm,
  }) async {
    final theme = Theme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: AppTextStyles.subtitleBold),
        content: Text(message, style: AppTextStyles.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok == true) await onConfirm();
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final cities = DeliveryZoneService.citiesForShop(widget.shopId);
    final effectiveCity = _selectedCity != null && cities.contains(_selectedCity)
        ? _selectedCity
        : (cities.isNotEmpty ? cities.first : null);
    final quartiers = effectiveCity == null
        ? <DeliveryQuartier>[]
        : DeliveryZoneService.quartiersForShop(widget.shopId,
            city: effectiveCity);

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Livraison',
      isRootPage: false,
      // NB : on enveloppe le ListView dans Column>Expanded (pattern
      // stock_locations_page) — un ListView nu renvoyé en pass-through
      // d'AppScaffold reçoit une contrainte de largeur dégénérée (texte
      // rendu verticalement). L'Expanded borne correctement la largeur.
      body: Column(children: [
        Expanded(
          child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Quartiers par ville ─────────────────────────────────────────
          _SectionHeader(
            title: 'Quartiers par ville',
            subtitle: 'Nom du quartier + prix de livraison',
            actionLabel: 'Quartier',
            onAction: () => _addQuartier(city: effectiveCity),
          ),
          const SizedBox(height: 10),
          if (cities.isEmpty)
            _EmptyHint(
              icon: Icons.location_city_outlined,
              text: 'Aucun quartier. Touchez « + Quartier » pour ajouter '
                  'votre premier tarif de livraison.',
            )
          else ...[
            // Sélecteur de ville (chips).
            Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                for (final c in cities)
                  ChoiceChip(
                    label: Text(c),
                    selected: c == effectiveCity,
                    onSelected: (_) => setState(() => _selectedCity = c),
                    selectedColor: AppColors.primarySurface,
                    labelStyle: AppTextStyles.bodySm.copyWith(
                      fontWeight: FontWeight.w600,
                      color: c == effectiveCity
                          ? AppColors.primary
                          : AppColors.textSecondary,
                    ),
                    side: BorderSide(
                        color: c == effectiveCity
                            ? AppColors.primary
                            : Theme.of(context).semantic.borderSubtle),
                    backgroundColor: Theme.of(context).colorScheme.surface,
                  ),
              ],
            ),
            // Nombre EXACT de quartiers pour la ville sélectionnée + renommage.
            if (effectiveCity != null) ...[
              const SizedBox(height: 10),
              Row(children: [
                Icon(Icons.home_work_outlined,
                    size: 16, color: AppColors.primary),
                const SizedBox(width: 6),
                Text(
                  '${quartiers.length} quartier'
                  '${quartiers.length > 1 ? 's' : ''} à $effectiveCity',
                  style: AppTextStyles.bodySmBold
                      .copyWith(color: AppColors.primary),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _renameCity(effectiveCity),
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text('Renommer'),
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact),
                ),
              ]),
            ],
            const SizedBox(height: 4),
            if (quartiers.isEmpty)
              _EmptyHint(
                icon: Icons.home_work_outlined,
                text: 'Aucun quartier pour « $effectiveCity ».',
              )
            else
              for (final q in quartiers)
                _QuartierRow(
                  quartier: q,
                  onTap: () => _editQuartier(q),
                  onDelete: () => _confirmDelete(
                    title: 'Supprimer le quartier',
                    message: '« ${q.name} » (${q.city}) sera supprimé.',
                    onConfirm: () => DeliveryZoneService.deleteQuartier(
                        q.id, widget.shopId),
                  ),
                ),
          ],
          const SizedBox(height: 24),
        ],
      ),
        ),
      ]),
    );
  }
}

// ═══ Sous-widgets ════════════════════════════════════════════════════════════

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: AppTextStyles.subtitle
                      .copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textHint)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: onAction,
          icon: const Icon(Icons.add_rounded, size: 16),
          label: Text(actionLabel,
              style: AppTextStyles.bodySmBold.copyWith(color: Colors.white)),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primaryFill,
            foregroundColor: Colors.white,
            elevation: 0,
            // CRITIQUE : sans ce minimumSize, le thème global impose
            // Size(double.infinity, 52) → le bouton réclame une largeur
            // infinie dans le Row et écrase l'Expanded du titre (texte rendu
            // verticalement, 1 caractère par ligne).
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9)),
          ),
        ),
      ],
    );
  }
}

class _QuartierRow extends StatelessWidget {
  final DeliveryQuartier quartier;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _QuartierRow({
    required this.quartier,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: InkWell(
        onTap: onTap, // tap = modifier le quartier
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Row(children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            color: AppColors.primarySurface,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(Icons.home_work_outlined,
              size: 17, color: AppColors.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(quartier.name,
              style: AppTextStyles.bodyBold,
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Text(CurrencyFormatter.format(quartier.price.toDouble()),
            style: AppTextStyles.bodyBold.copyWith(color: AppColors.primary)),
        IconButton(
          onPressed: onTap,
          icon: const Icon(Icons.edit_outlined, size: 17),
          color: AppColors.primary,
          visualDensity: VisualDensity.compact,
          tooltip: 'Modifier',
        ),
        IconButton(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          color: AppColors.textHint,
          visualDensity: VisualDensity.compact,
          tooltip: 'Supprimer',
        ),
      ]),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyHint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).semantic.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: Row(children: [
        Icon(icon, size: 20, color: AppColors.textHint),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: AppTextStyles.bodySm
                  .copyWith(color: AppColors.textSecondary)),
        ),
      ]),
    );
  }
}

// ═══ Formulaire : quartier (édition single OU création par LOT) ═══════════════

class _QuartierFormSheet extends StatefulWidget {
  final String shopId;
  final String? initialCity;
  final List<String> knownCities;
  /// Non-null → mode édition d'un quartier existant. Null → mode création
  /// par lot (on peut empiler plusieurs quartiers avant d'enregistrer).
  final DeliveryQuartier? existing;
  const _QuartierFormSheet({
    required this.shopId,
    required this.initialCity,
    required this.knownCities,
    this.existing,
  });

  @override
  State<_QuartierFormSheet> createState() => _QuartierFormSheetState();
}

class _QuartierFormSheetState extends State<_QuartierFormSheet> {
  final _cityCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  String? _zoneId;
  bool _saving = false;
  String? _error;
  // Lot de quartiers à créer (mode création uniquement).
  final List<({String name, int price})> _drafts = [];

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      _cityCtrl.text  = ex.city;
      _nameCtrl.text  = ex.name;
      _priceCtrl.text = ex.price.toString();
      _zoneId = ex.zoneId;
    } else if ((widget.initialCity ?? '').isNotEmpty) {
      _cityCtrl.text = widget.initialCity!;
    }
  }

  @override
  void dispose() {
    _cityCtrl.dispose();
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  /// Ajoute la saisie courante (nom + prix) au lot, puis vide les champs.
  void _addToBatch() {
    final name = _nameCtrl.text.trim();
    final price = int.tryParse(_priceCtrl.text.trim().replaceAll(' ', ''));
    if (name.isEmpty || price == null || price < 0) {
      setState(() => _error = 'Nom + prix valides requis.');
      return;
    }
    setState(() {
      _drafts.add((name: name, price: price));
      _nameCtrl.clear();
      _priceCtrl.clear();
      _error = null;
    });
  }

  Future<void> _submit() async {
    final city = _cityCtrl.text.trim();
    if (city.isEmpty) {
      setState(() => _error = 'La ville est requise.');
      return;
    }
    // ── Mode édition ──
    if (_isEdit) {
      final name = _nameCtrl.text.trim();
      final price = int.tryParse(_priceCtrl.text.trim().replaceAll(' ', ''));
      if (name.isEmpty) {
        setState(() => _error = 'Le nom du quartier est requis.');
        return;
      }
      if (price == null || price < 0) {
        setState(() => _error = 'Saisissez un prix valide (FCFA).');
        return;
      }
      setState(() => _saving = true);
      await DeliveryZoneService.updateQuartier(
        id: widget.existing!.id,
        shopId: widget.shopId,
        city: city,
        name: name,
        price: price,
        zoneId: _zoneId,
        clearZone: _zoneId == null,
      );
      if (mounted) Navigator.of(context).pop(1);
      return;
    }
    // ── Mode création par lot ── (inclut la saisie courante non ajoutée)
    final batch = [..._drafts];
    final curName = _nameCtrl.text.trim();
    final curPrice = int.tryParse(_priceCtrl.text.trim().replaceAll(' ', ''));
    if (curName.isNotEmpty && curPrice != null && curPrice >= 0) {
      batch.add((name: curName, price: curPrice));
    }
    if (batch.isEmpty) {
      setState(() => _error = 'Ajoutez au moins un quartier (nom + prix).');
      return;
    }
    setState(() => _saving = true);
    await DeliveryZoneService.addQuartiersBatch(
      shopId: widget.shopId,
      city: city,
      zoneId: _zoneId,
      items: batch,
    );
    if (mounted) Navigator.of(context).pop(batch.length);
  }

  @override
  Widget build(BuildContext context) {
    final saveLabel = _isEdit
        ? 'Enregistrer'
        : (_drafts.isEmpty ? 'Enregistrer' : 'Enregistrer (${_drafts.length})');
    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier le quartier' : 'Nouveaux quartiers',
      icon: Icons.home_work_outlined,
      iconColor: AppColors.primary,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Villes connues (remplissage rapide).
            if (widget.knownCities.isNotEmpty) ...[
              Wrap(
                spacing: 6, runSpacing: 6,
                children: [
                  for (final c in widget.knownCities)
                    ActionChip(
                      label: Text(c, style: AppTextStyles.caption),
                      onPressed: () => setState(() => _cityCtrl.text = c),
                      backgroundColor: AppColors.primarySurface,
                      side: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.3)),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            _Label('Ville'),
            AppField(
              controller: _cityCtrl,
              hint: 'Ville (ex. Douala)',
              prefixIcon: Icons.location_city_outlined,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: 12),
            _Label('Nom du quartier'),
            AppField(
              controller: _nameCtrl,
              hint: 'Quartier (ex. Bonapriso)',
              prefixIcon: Icons.home_work_outlined,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: 12),
            _Label('Prix de livraison (FCFA)'),
            AppField(
              controller: _priceCtrl,
              hint: 'Prix FCFA',
              prefixIcon: Icons.payments_outlined,
              keyboardType: TextInputType.number,
              numbersOnly: true,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            // En CRÉATION : bouton « Ajouter à la liste » + liste du lot.
            if (!_isEdit) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _addToBatch,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('Ajouter à la liste'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(
                        color: AppColors.primary.withValues(alpha: 0.4)),
                    minimumSize: const Size(0, 40),
                  ),
                ),
              ),
              if (_drafts.isNotEmpty) ...[
                const SizedBox(height: 10),
                _Label('À enregistrer (${_drafts.length})'),
                Wrap(
                  spacing: 6, runSpacing: 6,
                  children: [
                    for (var i = 0; i < _drafts.length; i++)
                      Chip(
                        label: Text(
                            '${_drafts[i].name} · '
                            '${CurrencyFormatter.format(
                                _drafts[i].price.toDouble())}',
                            style: AppTextStyles.caption),
                        onDeleted: () => setState(() => _drafts.removeAt(i)),
                        deleteIcon: const Icon(Icons.close_rounded, size: 14),
                        backgroundColor: AppColors.primarySurface,
                        side: BorderSide(
                            color: AppColors.primary.withValues(alpha: 0.3)),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: AppTextStyles.caption.copyWith(color: AppColors.error)),
            ],
          ],
        ),
      ),
      footer: _FormFooter(saving: _saving, onSave: _submit, label: saveLabel),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: AppTextStyles.captionBold
                .copyWith(color: AppColors.textSecondary)),
      );
}

class _FormFooter extends StatelessWidget {
  final bool saving;
  final VoidCallback onSave;
  final String label;
  const _FormFooter({
    required this.saving,
    required this.onSave,
    this.label = 'Enregistrer',
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: SizedBox(
        width: double.infinity, height: 46,
        child: ElevatedButton(
          onPressed: saving ? null : onSave,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primaryFill,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11)),
          ),
          child: saving
              ? const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(label,
                  style: AppTextStyles.bodyBold.copyWith(color: Colors.white)),
        ),
      ),
    );
  }
}
