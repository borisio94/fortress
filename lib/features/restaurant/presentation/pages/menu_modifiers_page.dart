import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/menu_modifier_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../domain/entities/menu_modifier.dart';

/// Configuration des groupes de modificateurs de menu (module restaurant,
/// PR-4) : Cuisson · Options · Suppléments.
///
/// Un groupe est présenté à l'utilisateur comme une entité unique, alors
/// qu'il est stocké en une ligne par produit lié (cf. `MenuModifierService`).
/// Cette page fait donc le regroupement par nom à l'affichage.
class MenuModifiersPage extends StatefulWidget {
  final String shopId;

  const MenuModifiersPage({super.key, required this.shopId});

  @override
  State<MenuModifiersPage> createState() => _MenuModifiersPageState();
}

/// Vue agrégée d'un groupe : toutes ses lignes partagent nom et options.
class _Group {
  final String name;
  final List<MenuModifier> rows;

  const _Group(this.name, this.rows);

  List<ModifierOption> get options => rows.first.options;

  /// Ids des produits liés. Vide = groupe applicable à toute la carte.
  List<String> get productIds =>
      rows.map((r) => r.productId).whereType<String>().toList();

  bool get isGlobal => productIds.isEmpty;
}

class _MenuModifiersPageState extends State<MenuModifiersPage> {
  late final OnDataChanged _listener;

  @override
  void initState() {
    super.initState();
    _listener = (table, sid) {
      if (!mounted) return;
      if (table != 'menu_modifiers') return;
      if (sid != widget.shopId) return;
      setState(() {});
    };
    AppDatabase.addListener(_listener);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppDatabase.syncMenuModifiers(widget.shopId);
    });
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  List<_Group> get _groups {
    final byName = <String, List<MenuModifier>>{};
    for (final m in MenuModifierService.forShop(widget.shopId)) {
      (byName[m.name] ??= <MenuModifier>[]).add(m);
    }
    final out = byName.entries.map((e) => _Group(e.key, e.value)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  List<Product> get _products =>
      LocalStorageService.getProductsForShop(widget.shopId);

  Future<void> _openForm({_Group? existing}) async {
    final saved = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => _GroupFormSheet(
        shopId: widget.shopId,
        products: _products,
        existing: existing,
      ),
    );
    if (saved == true && mounted) {
      AppSnack.success(context,
          existing == null ? 'Groupe créé' : 'Groupe modifié');
    }
  }

  Future<void> _delete(_Group group) async {
    await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer « ${group.name} » ?',
      body: Text(
        'Les commandes déjà passées conservent les options choisies.',
        style: AppTextStyles.bodySmSecondary,
      ),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      confirmColor: Theme.of(context).semantic.danger,
      onConfirm: () =>
          MenuModifierService.deleteGroupByName(widget.shopId, group.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Modificateurs',
      isRootPage: false,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Groupe'),
      ),
      body: groups.isEmpty
          ? EmptyStateWidget(
              icon: Icons.tune_rounded,
              title: 'Aucun modificateur',
              subtitle: 'Créez des groupes d\'options — Cuisson, '
                  'Suppléments — proposés à la prise de commande.',
              ctaLabel: 'Créer un groupe',
              onCta: () => _openForm(),
            )
          // Column + Expanded obligatoires : un ListView nu passé en
          // pass-through d'AppScaffold reçoit une contrainte de largeur
          // dégénérée.
          : Column(
              children: [
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                    itemCount: groups.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _GroupCard(
                      group: groups[i],
                      products: _products,
                      onEdit: () => _openForm(existing: groups[i]),
                      onDelete: () => _delete(groups[i]),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Carte d'un groupe : nom, portée, options et impacts tarifaires.
class _GroupCard extends StatelessWidget {
  final _Group group;
  final List<Product> products;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _GroupCard({
    required this.group,
    required this.products,
    required this.onEdit,
    required this.onDelete,
  });

  String get _scopeLabel {
    if (group.isGlobal) return 'Toute la carte';
    final names = <String>[];
    for (final id in group.productIds) {
      final p = products.where((x) => x.id == id).firstOrNull;
      if (p != null) names.add(p.name);
    }
    if (names.isEmpty) return '${group.productIds.length} produit(s)';
    if (names.length <= 2) return names.join(' · ');
    return '${names.take(2).join(' · ')} +${names.length - 2}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.semantic;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: semantic.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.name, style: AppTextStyles.bodyBold),
                    Text(_scopeLabel, style: AppTextStyles.captionHint),
                  ],
                ),
              ),
              IconButton(
                onPressed: onEdit,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
              IconButton(
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.delete_outline_rounded,
                    size: 18, color: semantic.danger),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final o in group.options)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: semantic.trackMuted,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    o.priceImpact == 0
                        ? o.name
                        : '${o.name} ${o.priceImpact > 0 ? '+' : ''}'
                            '${o.priceImpact}',
                    style: AppTextStyles.caption.copyWith(
                        color: o.priceImpact == 0
                            ? theme.colorScheme.onSurface
                            : semantic.warning),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Formulaire de création / édition d'un groupe.
class _GroupFormSheet extends StatefulWidget {
  final String shopId;
  final List<Product> products;
  final _Group? existing;

  const _GroupFormSheet({
    required this.shopId,
    required this.products,
    this.existing,
  });

  @override
  State<_GroupFormSheet> createState() => _GroupFormSheetState();
}

class _GroupFormSheetState extends State<_GroupFormSheet> {
  final _nameCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _options = <ModifierOption>[];
  final _selectedProductIds = <String>{};
  String _search = '';
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final g = widget.existing;
    if (g != null) {
      _nameCtrl.text = g.name;
      _options.addAll(g.options);
      _selectedProductIds.addAll(g.productIds);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Product> get _filteredProducts {
    if (_search.isEmpty) return widget.products;
    final q = _search.toLowerCase();
    return widget.products
        .where((p) => p.name.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _addOption() async {
    final result = await showDialog<ModifierOption>(
      context: context,
      builder: (_) => const _OptionDialog(),
    );
    if (result != null) setState(() => _options.add(result));
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Donnez un nom au groupe (ex. Cuisson).');
      return;
    }
    if (_options.isEmpty) {
      setState(() => _error = 'Ajoutez au moins une option.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Édition = suppression puis recréation : le groupe est stocké en N
      // lignes dont le nombre change avec la sélection de produits. Un
      // update ligne à ligne demanderait un diff pour un gain nul à cette
      // échelle (quelques lignes par boutique).
      if (_isEdit) {
        await MenuModifierService.deleteGroupByName(
            widget.shopId, widget.existing!.name);
      }
      await MenuModifierService.addGroup(
        shopId: widget.shopId,
        name: name,
        options: List.of(_options),
        productIds: _selectedProductIds.toList(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.semantic;

    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier le groupe' : 'Nouveau groupe',
      icon: Icons.tune_rounded,
      iconColor: AppColors.primary,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppFieldLabel('Nom du groupe', required: true),
            const SizedBox(height: 8),
            AppField(
              controller: _nameCtrl,
              hint: 'Cuisson, Suppléments…',
              prefixIcon: Icons.label_outline_rounded,
            ),
            const SizedBox(height: 18),

            Row(
              children: [
                AppFieldLabel('Options (${_options.length})', required: true),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addOption,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('Ajouter'),
                  style: TextButton.styleFrom(
                      minimumSize: const Size(0, 36)),
                ),
              ],
            ),
            if (_options.isEmpty)
              Text('Ex. Saignant · À point · Bien cuit',
                  style: AppTextStyles.captionHint)
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < _options.length; i++)
                    InputChip(
                      label: Text(
                        _options[i].priceImpact == 0
                            ? _options[i].name
                            : '${_options[i].name} '
                                '${_options[i].priceImpact > 0 ? '+' : ''}'
                                '${_options[i].priceImpact}',
                        style: AppTextStyles.caption,
                      ),
                      onDeleted: () => setState(() => _options.removeAt(i)),
                    ),
                ],
              ),
            const SizedBox(height: 18),

            AppFieldLabel(
                'Produits liés (${_selectedProductIds.length})'),
            Text(
              _selectedProductIds.isEmpty
                  ? 'Aucun produit sélectionné : le groupe s\'appliquera à '
                      'toute la carte.'
                  : 'Le groupe ne sera proposé que sur ces produits.',
              style: AppTextStyles.captionHint,
            ),
            const SizedBox(height: 8),
            AppField(
              controller: _searchCtrl,
              hint: 'Rechercher un produit…',
              prefixIcon: Icons.search_rounded,
              onChanged: (v) => setState(() => _search = v),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 220,
              child: widget.products.isEmpty
                  ? Center(
                      child: Text('Aucun produit au catalogue.',
                          style: AppTextStyles.bodySecondary))
                  : ListView.builder(
                      itemCount: _filteredProducts.length,
                      itemBuilder: (_, i) {
                        final p = _filteredProducts[i];
                        final id = p.id ?? '';
                        final sel = _selectedProductIds.contains(id);
                        return InkWell(
                          onTap: id.isEmpty
                              ? null
                              : () => setState(() {
                                    if (sel) {
                                      _selectedProductIds.remove(id);
                                    } else {
                                      _selectedProductIds.add(id);
                                    }
                                  }),
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Icon(
                                  sel
                                      ? Icons.check_circle_rounded
                                      : Icons
                                          .radio_button_unchecked_rounded,
                                  size: 18,
                                  color: sel
                                      ? AppColors.primary
                                      : theme.colorScheme.onSurface
                                          .withValues(alpha: 0.35),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(p.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTextStyles.bodySm),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: AppTextStyles.caption
                      .copyWith(color: semantic.danger)),
            ],
            const SizedBox(height: 16),
            AppPrimaryButton(
              label: _isEdit ? 'Enregistrer' : 'Créer le groupe',
              icon: Icons.check_rounded,
              fullWidth: true,
              isLoading: _saving,
              onTap: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// Saisie d'une option : libellé + impact tarifaire.
class _OptionDialog extends StatefulWidget {
  const _OptionDialog();

  @override
  State<_OptionDialog> createState() => _OptionDialogState();
}

class _OptionDialogState extends State<_OptionDialog> {
  final _nameCtrl = TextEditingController();
  final _priceCtrl = TextEditingController(text: '0');

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nouvelle option'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppFieldLabel('Libellé', required: true),
          const SizedBox(height: 6),
          AppField(
            controller: _nameCtrl,
            hint: 'Saignant, +Fromage…',
            autofocus: true,
          ),
          const SizedBox(height: 12),
          const AppFieldLabel('Impact sur le prix'),
          const SizedBox(height: 6),
          AppField(
            controller: _priceCtrl,
            hint: '0',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 6),
          Text('0 = sans supplément. Une valeur négative applique une remise.',
              style: AppTextStyles.micro),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        TextButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) return;
            // `numbersOnly` n'est pas utilisé sur le champ prix : il
            // interdirait le signe « - » d'une remise.
            final impact = int.tryParse(_priceCtrl.text.trim()) ?? 0;
            Navigator.of(context)
                .pop(ModifierOption(name: name, priceImpact: impact));
          },
          child: const Text('Ajouter'),
        ),
      ],
    );
  }
}
