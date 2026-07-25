import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_service.dart';
import '../../../../core/services/ingredient_service.dart';
import '../../../../core/services/stock_item_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../widgets/resto_empty_state.dart' show RestoEmptyState;
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/restaurant_activity.dart';
import '../../domain/entities/stock_item.dart';

/// Hub finances restaurant (module finances — PR-B).
/// Trois onglets : Ingrédients · Activités · Stock (articles sans
/// transformation). Restaurant-only (route `sectorIn` restaurant + admin).
class FinancesHubPage extends StatelessWidget {
  final String shopId;
  const FinancesHubPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    return AppScaffold(
      shopId: shopId,
      title: 'Finances',
      isRootPage: false,
      body: DefaultTabController(
        length: 3,
        child: Column(
          children: [
            Material(
              color: cs.surface,
              child: TabBar(
                labelColor: cs.primary,
                unselectedLabelColor: cs.onSurface.withValues(alpha: 0.6),
                indicatorColor: cs.primary,
                labelStyle: AppTextStyles.label,
                tabs: const [
                  Tab(text: 'Ingrédients'),
                  Tab(text: 'Activités'),
                  Tab(text: 'Stock'),
                ],
              ),
            ),
            Divider(height: 1, color: sem.borderSubtle),
            Expanded(
              child: TabBarView(
                children: [
                  _IngredientsTab(shopId: shopId),
                  _ActivitiesTab(shopId: shopId),
                  _StockItemsTab(shopId: shopId),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Base commune d'un onglet (liste + bouton d'ajout + rebuild sur sync)
// ═══════════════════════════════════════════════════════════════════════
abstract class _TabState<T extends StatefulWidget> extends State<T> {
  late final OnDataChanged _listener;

  /// Table Supabase à écouter pour rafraîchir la liste.
  String get table;
  String get shopId;

  @override
  void initState() {
    super.initState();
    _listener = (t, sid) {
      if (!mounted) return;
      if (t != table) return;
      if (sid != shopId && sid != '_all') return;
      setState(() {});
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  Widget headerButton(String label, VoidCallback onTap) => Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: FilledButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(label),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
          ),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  Onglet INGRÉDIENTS
// ═══════════════════════════════════════════════════════════════════════
class _IngredientsTab extends StatefulWidget {
  final String shopId;
  const _IngredientsTab({required this.shopId});
  @override
  State<_IngredientsTab> createState() => _IngredientsTabState();
}

class _IngredientsTabState extends _TabState<_IngredientsTab> {
  @override
  String get table => 'ingredients';
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final items = IngredientService.forShop(widget.shopId);
    return Column(
      children: [
        headerButton('Ingrédient', () => _edit(null)),
        Expanded(
          child: items.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.eco_outlined,
                  title: 'Aucun ingrédient',
                  subtitle:
                      'Créez vos ingrédients pour les utiliser dans les recettes.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _IngredientRow(
                    ing: items[i],
                    onTap: () => _edit(items[i]),
                    onReceive: () => _receive(items[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _receive(Ingredient ing) async {
    final amount = await _askAmount(context, 'Réception — ${ing.name}',
        suffix: ing.unit);
    if (amount == null) return;
    await IngredientService.update(
        ing.copyWith(quantity: ing.quantity + amount));
  }

  Future<void> _edit(Ingredient? ing) async {
    await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => _IngredientEditor(shopId: widget.shopId, existing: ing),
    );
    if (mounted) setState(() {});
  }
}

class _IngredientRow extends StatelessWidget {
  final Ingredient ing;
  final VoidCallback onTap;
  final VoidCallback onReceive;
  const _IngredientRow(
      {required this.ing, required this.onTap, required this.onReceive});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final q = _fmt(ing.quantity);
    return _Card(
      onTap: onTap,
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(ing.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyBold
                          .copyWith(color: cs.onSurface)),
                ),
                if (ing.isShared) ...[
                  const SizedBox(width: 6),
                  _Pill('partagé', cs.primary),
                ],
                if (ing.isLowStock) ...[
                  const SizedBox(width: 6),
                  _Pill('stock bas', sem.danger),
                ],
              ]),
              Text(
                  '${ing.costPerUnit} F/${ing.unit} · stock $q ${ing.unit}'
                  '${ing.alertThreshold > 0 ? ' · seuil ${_fmt(ing.alertThreshold)}' : ''}',
                  style: AppTextStyles.caption),
            ],
          ),
        ),
        IconButton(
          onPressed: onReceive,
          tooltip: 'Réception',
          icon: Icon(Icons.add_box_outlined, size: 20, color: cs.primary),
        ),
      ]),
    );
  }
}

/// Éditeur ingrédient (création / modification / suppression).
class _IngredientEditor extends StatefulWidget {
  final String shopId;
  final Ingredient? existing;
  const _IngredientEditor({required this.shopId, this.existing});
  @override
  State<_IngredientEditor> createState() => _IngredientEditorState();
}

class _IngredientEditorState extends State<_IngredientEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _unit =
      TextEditingController(text: widget.existing?.unit ?? 'g');
  late final _cost = TextEditingController(
      text: widget.existing == null ? '' : '${widget.existing!.costPerUnit}');
  late final _stock = TextEditingController(
      text: widget.existing == null ? '' : _fmt(widget.existing!.quantity));
  late final _seuil = TextEditingController(
      text: widget.existing == null
          ? ''
          : _fmt(widget.existing!.alertThreshold));
  String? _err;
  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _cost.dispose();
    _stock.dispose();
    _seuil.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _err = 'Nom requis');
      return;
    }
    final unit = _unit.text.trim().isEmpty ? 'pièce' : _unit.text.trim();
    final cost = int.tryParse(_cost.text.trim()) ?? 0;
    final stock = double.tryParse(_stock.text.trim().replaceAll(',', '.')) ?? 0;
    final seuil = double.tryParse(_seuil.text.trim().replaceAll(',', '.')) ?? 0;
    if (_isEdit) {
      await IngredientService.update(widget.existing!.copyWith(
          name: name,
          unit: unit,
          costPerUnit: cost,
          quantity: stock,
          alertThreshold: seuil));
    } else {
      await IngredientService.create(
          shopId: widget.shopId,
          name: name,
          unit: unit,
          costPerUnit: cost,
          quantity: stock,
          alertThreshold: seuil);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cet ingrédient ?',
      body: Text('« ${widget.existing!.name} » sera retiré. Les recettes qui '
          'l\'utilisent afficheront « ingrédient supprimé ».'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await IngredientService.delete(widget.existing!.id, widget.shopId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier l\'ingrédient' : 'Nouvel ingrédient',
      icon: Icons.eco_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                controller: _name,
                autofocus: !_isEdit,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Nom')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _unit,
                      decoration: const InputDecoration(
                          labelText: 'Unité', hintText: 'g, kg, L, pièce'))),
              const SizedBox(width: 10),
              Expanded(child: _numField(_cost, 'Coût / unité (F)')),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _numField(_stock, 'Stock', decimal: true)),
              const SizedBox(width: 10),
              Expanded(child: _numField(_seuil, 'Seuil alerte', decimal: true)),
            ]),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
                label: _isEdit ? 'Enregistrer' : 'Créer',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: _save),
            if (_isEdit) ...[
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: _delete,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: sem.danger),
                  label: Text('Supprimer',
                      style: AppTextStyles.label.copyWith(color: sem.danger)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Onglet ACTIVITÉS
// ═══════════════════════════════════════════════════════════════════════
class _ActivitiesTab extends StatefulWidget {
  final String shopId;
  const _ActivitiesTab({required this.shopId});
  @override
  State<_ActivitiesTab> createState() => _ActivitiesTabState();
}

class _ActivitiesTabState extends _TabState<_ActivitiesTab> {
  @override
  String get table => 'restaurant_activities';
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = ActivityService.forShop(widget.shopId);
    return Column(
      children: [
        headerButton('Activité', () => _edit(null)),
        Expanded(
          child: items.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.category_outlined,
                  title: 'Aucune activité',
                  subtitle:
                      'Ex. Chawarma, Glace, Bar… Regroupez vos secteurs de vente.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final a = items[i];
                    return _Card(
                      onTap: () => _edit(a),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.bodyBold
                                      .copyWith(color: cs.onSurface)),
                              Text(
                                  a.isStockMode
                                      ? 'Mode stock${a.stockThreshold > 0 ? ' · seuil ${a.stockThreshold}' : ''}'
                                      : 'Mode recette',
                                  style: AppTextStyles.caption),
                            ],
                          ),
                        ),
                        _Pill(a.isStockMode ? 'stock' : 'recette', cs.primary),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _edit(RestaurantActivity? a) async {
    await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => _ActivityEditor(shopId: widget.shopId, existing: a),
    );
    if (mounted) setState(() {});
  }
}

class _ActivityEditor extends StatefulWidget {
  final String shopId;
  final RestaurantActivity? existing;
  const _ActivityEditor({required this.shopId, this.existing});
  @override
  State<_ActivityEditor> createState() => _ActivityEditorState();
}

class _ActivityEditorState extends State<_ActivityEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _seuil = TextEditingController(
      text: (widget.existing?.stockThreshold ?? 0) == 0
          ? ''
          : '${widget.existing!.stockThreshold}');
  late String _mode = widget.existing?.mode ?? 'stock';
  String? _err;
  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _name.dispose();
    _seuil.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _err = 'Nom requis');
      return;
    }
    final seuil = int.tryParse(_seuil.text.trim()) ?? 0;
    if (_isEdit) {
      await ActivityService.update(widget.existing!
          .copyWith(name: name, mode: _mode, stockThreshold: seuil));
    } else {
      await ActivityService.create(
          shopId: widget.shopId,
          name: name,
          mode: _mode,
          stockThreshold: seuil);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette activité ?',
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await ActivityService.delete(widget.existing!.id, widget.shopId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier l\'activité' : 'Nouvelle activité',
      icon: Icons.category_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                controller: _name,
                autofocus: !_isEdit,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                    labelText: 'Nom', hintText: 'Chawarma, Glace, Bar…')),
            const SizedBox(height: 14),
            Text('Mode', style: AppTextStyles.caption),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'stock', label: Text('Stock')),
                ButtonSegment(value: 'recipe', label: Text('Recette')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            if (_mode == 'stock') ...[
              const SizedBox(height: 12),
              _numField(_seuil, 'Seuil d\'alerte (global)'),
            ],
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
                label: _isEdit ? 'Enregistrer' : 'Créer',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: _save),
            if (_isEdit) ...[
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: _delete,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: sem.danger),
                  label: Text('Supprimer',
                      style: AppTextStyles.label.copyWith(color: sem.danger)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Onglet STOCK (articles sans transformation)
// ═══════════════════════════════════════════════════════════════════════
class _StockItemsTab extends StatefulWidget {
  final String shopId;
  const _StockItemsTab({required this.shopId});
  @override
  State<_StockItemsTab> createState() => _StockItemsTabState();
}

class _StockItemsTabState extends _TabState<_StockItemsTab> {
  @override
  String get table => 'stock_items';
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final items = StockItemService.forShop(widget.shopId);
    return Column(
      children: [
        headerButton('Article', () => _edit(null)),
        Expanded(
          child: items.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: 'Aucun article',
                  subtitle:
                      'Boissons, emballages… articles vendus tels quels.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final s = items[i];
                    return _Card(
                      onTap: () => _edit(s),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Flexible(
                                  child: Text(s.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTextStyles.bodyBold
                                          .copyWith(color: cs.onSurface)),
                                ),
                                if (s.isLowStock) ...[
                                  const SizedBox(width: 6),
                                  _Pill('stock bas', sem.danger),
                                ],
                              ]),
                              Text(
                                  'Vente ${CurrencyFormatter.format(s.sellingPrice.toDouble())} · '
                                  'stock ${_fmt(s.quantity)} ${s.unit}'
                                  '${s.minQuantity > 0 ? ' · min ${_fmt(s.minQuantity)}' : ''}',
                                  style: AppTextStyles.caption),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => _receive(s),
                          tooltip: 'Réception',
                          icon: Icon(Icons.add_box_outlined,
                              size: 20, color: cs.primary),
                        ),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _receive(StockItem s) async {
    final amount =
        await _askAmount(context, 'Réception — ${s.name}', suffix: s.unit);
    if (amount == null) return;
    await StockItemService.receive(widget.shopId, s.id, amount);
  }

  Future<void> _edit(StockItem? s) async {
    await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => _StockItemEditor(shopId: widget.shopId, existing: s),
    );
    if (mounted) setState(() {});
  }
}

class _StockItemEditor extends StatefulWidget {
  final String shopId;
  final StockItem? existing;
  const _StockItemEditor({required this.shopId, this.existing});
  @override
  State<_StockItemEditor> createState() => _StockItemEditorState();
}

class _StockItemEditorState extends State<_StockItemEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _unit =
      TextEditingController(text: widget.existing?.unit ?? 'pièce');
  late final _stock = TextEditingController(
      text: widget.existing == null ? '' : _fmt(widget.existing!.quantity));
  late final _min = TextEditingController(
      text: widget.existing == null ? '' : _fmt(widget.existing!.minQuantity));
  late final _cost = TextEditingController(
      text: widget.existing == null ? '' : '${widget.existing!.costPerUnit}');
  late final _price = TextEditingController(
      text: widget.existing == null ? '' : '${widget.existing!.sellingPrice}');
  late String? _activityId = widget.existing?.activityId;
  String? _err;
  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _stock.dispose();
    _min.dispose();
    _cost.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _err = 'Nom requis');
      return;
    }
    final unit = _unit.text.trim().isEmpty ? 'pièce' : _unit.text.trim();
    final stock = double.tryParse(_stock.text.trim().replaceAll(',', '.')) ?? 0;
    final min = double.tryParse(_min.text.trim().replaceAll(',', '.')) ?? 0;
    final cost = int.tryParse(_cost.text.trim()) ?? 0;
    final price = int.tryParse(_price.text.trim()) ?? 0;
    if (_isEdit) {
      await StockItemService.update(widget.existing!.copyWith(
        name: name,
        unit: unit,
        quantity: stock,
        minQuantity: min,
        costPerUnit: cost,
        sellingPrice: price,
        activityId: _activityId,
        clearActivity: _activityId == null,
      ));
    } else {
      await StockItemService.create(
        shopId: widget.shopId,
        name: name,
        unit: unit,
        quantity: stock,
        minQuantity: min,
        costPerUnit: cost,
        sellingPrice: price,
        activityId: _activityId,
      );
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cet article ?',
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await StockItemService.delete(widget.existing!.id, widget.shopId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final activities = ActivityService.forShop(widget.shopId)
        .where((a) => a.isStockMode)
        .toList();
    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier l\'article' : 'Nouvel article',
      icon: Icons.inventory_2_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                controller: _name,
                autofocus: !_isEdit,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Nom')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _unit,
                      decoration: const InputDecoration(labelText: 'Unité'))),
              const SizedBox(width: 10),
              Expanded(child: _numField(_price, 'Prix vente (F)')),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _numField(_stock, 'Stock', decimal: true)),
              const SizedBox(width: 10),
              Expanded(child: _numField(_min, 'Min', decimal: true)),
            ]),
            const SizedBox(height: 10),
            _numField(_cost, 'Coût d\'achat / unité (F)'),
            if (activities.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('Activité (optionnel)', style: AppTextStyles.caption),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                ChoiceChip(
                  label: const Text('Aucune'),
                  selected: _activityId == null,
                  onSelected: (_) => setState(() => _activityId = null),
                ),
                for (final a in activities)
                  ChoiceChip(
                    label: Text(a.name),
                    selected: _activityId == a.id,
                    onSelected: (_) => setState(() => _activityId = a.id),
                  ),
              ]),
            ],
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
                label: _isEdit ? 'Enregistrer' : 'Créer',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: _save),
            if (_isEdit) ...[
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: _delete,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: sem.danger),
                  label: Text('Supprimer',
                      style: AppTextStyles.label.copyWith(color: sem.danger)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Helpers partagés
// ═══════════════════════════════════════════════════════════════════════

/// Formate une quantité double sans « .0 » superflu.
String _fmt(double v) => v == v.truncateToDouble()
    ? v.toInt().toString()
    : v.toStringAsFixed(1);

/// Champ numérique compact (entier par défaut, décimal si demandé).
Widget _numField(TextEditingController c, String label, {bool decimal = false}) =>
    TextField(
      controller: c,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      inputFormatters: decimal
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))]
          : [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label),
    );

/// Petite feuille « saisir une quantité » (réception).
Future<double?> _askAmount(BuildContext context, String title,
    {String? suffix}) async {
  final ctrl = TextEditingController();
  return showAdaptiveFormSheet<double>(
    context: context,
    builder: (sheetCtx) => AdaptiveFormFrame(
      title: title,
      icon: Icons.add_box_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            decoration:
                InputDecoration(labelText: 'Quantité reçue', suffixText: suffix),
          ),
          const SizedBox(height: 18),
          AppPrimaryButton(
            label: 'Ajouter au stock',
            icon: Icons.check_rounded,
            fullWidth: true,
            onTap: () {
              final v = double.tryParse(ctrl.text.trim().replaceAll(',', '.'));
              if (v == null || v <= 0) {
                AppSnack.error(sheetCtx, 'Quantité invalide');
                return;
              }
              Navigator.of(sheetCtx).pop(v);
            },
          ),
        ]),
      ),
    ),
  );
}

/// Carte de liste standard (surface + bordure douce).
class _Card extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _Card({required this.child, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    return Material(
      color: cs.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sem.borderSubtle),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Pastille colorée (statut : partagé / stock bas / mode).
class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill(this.label, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: AppTextStyles.micro
                .copyWith(color: color, fontWeight: FontWeight.w700)),
      );
}
