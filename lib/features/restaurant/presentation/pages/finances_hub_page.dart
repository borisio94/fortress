import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_service.dart';
import '../../../../core/services/fixed_charge_service.dart';
import '../../../../core/services/ingredient_service.dart';
import '../../../../core/services/loss_service.dart';
import '../../../../core/services/reconciliation_service.dart';
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
import '../../domain/entities/fixed_charge.dart';
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/loss.dart';
import '../../domain/entities/restaurant_activity.dart';
import '../../domain/entities/stock_item.dart';

/// Hub finances restaurant (module finances — PR-B/PR-C).
/// Cinq onglets : Ingrédients · Activités · Stock · Charges · Pertes.
/// Restaurant-only (route `sectorIn` restaurant + admin).
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
      actions: [
        IconButton(
          tooltip: 'Inventaire',
          icon: const Icon(Icons.fact_check_outlined),
          onPressed: () =>
              context.push('/shop/$shopId/restaurant/inventory/reconcile'),
        ),
      ],
      body: DefaultTabController(
        length: 5,
        child: Column(
          children: [
            Material(
              color: cs.surface,
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: cs.primary,
                unselectedLabelColor: cs.onSurface.withValues(alpha: 0.6),
                indicatorColor: cs.primary,
                labelStyle: AppTextStyles.label,
                tabs: const [
                  Tab(text: 'Ingrédients'),
                  Tab(text: 'Activités'),
                  Tab(text: 'Stock'),
                  Tab(text: 'Charges'),
                  Tab(text: 'Pertes'),
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
                  _ChargesTab(shopId: shopId),
                  _LossesTab(shopId: shopId),
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
//  Onglet CHARGES FIXES
// ═══════════════════════════════════════════════════════════════════════
class _ChargesTab extends StatefulWidget {
  final String shopId;
  const _ChargesTab({required this.shopId});
  @override
  State<_ChargesTab> createState() => _ChargesTabState();
}

class _ChargesTabState extends _TabState<_ChargesTab> {
  @override
  String get table => 'fixed_charges';
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final items = FixedChargeService.forShop(widget.shopId);
    return Column(children: [
      headerButton('Charge', () => _edit(null)),
      Expanded(
        child: items.isEmpty
            ? const RestoEmptyState(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Aucune charge fixe',
                subtitle:
                    'Loyer, électricité, salaires… suivez vos échéances récurrentes.',
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _ChargeRow(
                  charge: items[i],
                  onTap: () => _edit(items[i]),
                  onPaid: () => _markPaid(items[i]),
                ),
              ),
      ),
    ]);
  }

  Future<void> _markPaid(FixedCharge c) async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.check_circle_outline,
      title: 'Marquer réglée ?',
      body: Text('« ${c.name} » — échéance du ${_dayLabel(c.nextDueDate)}. '
          'La prochaine échéance sera calculée automatiquement.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Régler',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await FixedChargeService.markPaid(widget.shopId, c.id);
  }

  Future<void> _edit(FixedCharge? c) async {
    await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => _ChargeEditor(shopId: widget.shopId, existing: c),
    );
    if (mounted) setState(() {});
  }
}

class _ChargeRow extends StatelessWidget {
  final FixedCharge charge;
  final VoidCallback onTap;
  final VoidCallback onPaid;
  const _ChargeRow(
      {required this.charge, required this.onTap, required this.onPaid});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final freq = _kFrequencyLabels[charge.frequency] ?? charge.frequency;
    final cat = _kChargeCategoryLabels[charge.category] ?? charge.category;
    return _Card(
      onTap: onTap,
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(charge.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyBold
                          .copyWith(color: cs.onSurface)),
                ),
                if (charge.isCurrentPaid) ...[
                  const SizedBox(width: 6),
                  _Pill('réglée', sem.success),
                ] else if (charge.isOverdue) ...[
                  const SizedBox(width: 6),
                  _Pill('en retard', sem.danger),
                ] else if (charge.isDueSoon) ...[
                  const SizedBox(width: 6),
                  _Pill('bientôt', sem.warning),
                ],
              ]),
              Text(
                  '${CurrencyFormatter.format(charge.amount.toDouble())}'
                  ' · $freq · $cat · échéance ${_dayLabel(charge.nextDueDate)}',
                  style: AppTextStyles.caption),
            ],
          ),
        ),
        if (!charge.isCurrentPaid)
          IconButton(
            onPressed: onPaid,
            tooltip: 'Marquer réglée',
            icon: Icon(Icons.check_circle_outline, size: 20, color: cs.primary),
          ),
      ]),
    );
  }
}

/// Éditeur charge fixe (création / modification / suppression).
class _ChargeEditor extends StatefulWidget {
  final String shopId;
  final FixedCharge? existing;
  const _ChargeEditor({required this.shopId, this.existing});
  @override
  State<_ChargeEditor> createState() => _ChargeEditorState();
}

class _ChargeEditorState extends State<_ChargeEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _amount = TextEditingController(
      text: widget.existing == null ? '' : '${widget.existing!.amount}');
  late final _alert = TextEditingController(
      text: '${widget.existing?.alertDaysBefore ?? 7}');
  late String _frequency = widget.existing?.frequency ?? 'monthly';
  late String _category = widget.existing?.category ?? 'autre';
  late DateTime _dueDate = widget.existing?.nextDueDate ?? DateTime.now();
  String? _err;
  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _alert.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _dueDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null && mounted) setState(() => _dueDate = d);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _err = 'Nom requis');
      return;
    }
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    final alert = int.tryParse(_alert.text.trim()) ?? 7;
    if (_isEdit) {
      await FixedChargeService.update(widget.existing!.copyWith(
        name: name,
        amount: amount,
        frequency: _frequency,
        nextDueDate: _dueDate,
        alertDaysBefore: alert,
        category: _category,
      ));
    } else {
      await FixedChargeService.create(
        shopId: widget.shopId,
        name: name,
        amount: amount,
        frequency: _frequency,
        nextDueDate: _dueDate,
        alertDaysBefore: alert,
        category: _category,
      );
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette charge ?',
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await FixedChargeService.delete(widget.existing!.id, widget.shopId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier la charge' : 'Nouvelle charge',
      icon: Icons.account_balance_wallet_outlined,
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
              Expanded(child: _numField(_amount, 'Montant (F)')),
              const SizedBox(width: 10),
              Expanded(child: _numField(_alert, 'Alerte (j avant)')),
            ]),
            const SizedBox(height: 14),
            Text('Fréquence', style: AppTextStyles.caption),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in _kFrequencyLabels.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: _frequency == e.key,
                  onSelected: (_) => setState(() => _frequency = e.key),
                ),
            ]),
            const SizedBox(height: 14),
            Text('Catégorie', style: AppTextStyles.caption),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in _kChargeCategoryLabels.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: _category == e.key,
                  onSelected: (_) => setState(() => _category = e.key),
                ),
            ]),
            const SizedBox(height: 14),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Prochaine échéance',
                    prefixIcon: Icon(Icons.calendar_today, size: 18)),
                child: Text(_dayLabel(_dueDate), style: AppTextStyles.body),
              ),
            ),
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
//  Onglet PERTES
// ═══════════════════════════════════════════════════════════════════════
class _LossesTab extends StatefulWidget {
  final String shopId;
  const _LossesTab({required this.shopId});
  @override
  State<_LossesTab> createState() => _LossesTabState();
}

class _LossesTabState extends _TabState<_LossesTab> {
  @override
  String get table => 'losses';
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final items = LossService.forShop(widget.shopId);
    final total = items.fold<int>(0, (s, l) => s + l.amount);
    return Column(children: [
      headerButton('Perte', () => _edit(null)),
      if (items.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
                'Total des pertes : '
                '${CurrencyFormatter.format(total.toDouble())}',
                style: AppTextStyles.captionHint),
          ),
        ),
      Expanded(
        child: items.isEmpty
            ? const RestoEmptyState(
                icon: Icons.warning_amber_rounded,
                title: 'Aucune perte déclarée',
                subtitle:
                    'Casse, invendus, additions non payées… déclarez-les ici.',
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _LossRow(
                  loss: items[i],
                  onTap: () => _edit(items[i]),
                ),
              ),
      ),
    ]);
  }

  Future<void> _edit(Loss? l) async {
    await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => _LossEditor(shopId: widget.shopId, existing: l),
    );
    if (mounted) setState(() {});
  }
}

class _LossRow extends StatelessWidget {
  final Loss loss;
  final VoidCallback onTap;
  const _LossRow({required this.loss, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final cat = _kLossCategoryLabels[loss.category] ?? loss.category;
    return _Card(
      onTap: onTap,
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(loss.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyBold
                          .copyWith(color: cs.onSurface)),
                ),
                const SizedBox(width: 6),
                _Pill(cat, sem.danger),
              ]),
              Text(
                  '${CurrencyFormatter.format(loss.amount.toDouble())}'
                  ' · ${_dayLabel(loss.date)}'
                  '${loss.origin.isNotEmpty ? ' · ${loss.origin}' : ''}',
                  style: AppTextStyles.caption),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Éditeur perte (déclaration / modification / suppression).
class _LossEditor extends StatefulWidget {
  final String shopId;
  final Loss? existing;
  const _LossEditor({required this.shopId, this.existing});
  @override
  State<_LossEditor> createState() => _LossEditorState();
}

class _LossEditorState extends State<_LossEditor> {
  late final _desc =
      TextEditingController(text: widget.existing?.description ?? '');
  late final _amount = TextEditingController(
      text: widget.existing == null ? '' : '${widget.existing!.amount}');
  late final _origin =
      TextEditingController(text: widget.existing?.origin ?? '');
  late String _category = widget.existing?.category ?? 'casse';
  late DateTime _date = widget.existing?.date ?? DateTime.now();
  String? _err;
  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _desc.dispose();
    _amount.dispose();
    _origin.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null && mounted) setState(() => _date = d);
  }

  Future<void> _save() async {
    final desc = _desc.text.trim();
    if (desc.isEmpty) {
      setState(() => _err = 'Description requise');
      return;
    }
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    if (amount <= 0) {
      setState(() => _err = 'Montant requis');
      return;
    }
    if (_isEdit) {
      await LossService.update(widget.existing!.copyWith(
        description: desc,
        amount: amount,
        category: _category,
        origin: _origin.text.trim(),
        date: _date,
      ));
    } else {
      await LossService.record(
        shopId: widget.shopId,
        description: desc,
        amount: amount,
        category: _category,
        origin: _origin.text.trim(),
        date: _date,
      );
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette perte ?',
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await LossService.delete(widget.existing!.id, widget.shopId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier la perte' : 'Déclarer une perte',
      icon: Icons.warning_amber_rounded,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                controller: _desc,
                autofocus: !_isEdit,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Description')),
            const SizedBox(height: 10),
            _numField(_amount, 'Montant (F)'),
            const SizedBox(height: 14),
            Text('Catégorie', style: AppTextStyles.caption),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in _kLossCategoryLabels.entries)
                // Catégorie réservée à la réconciliation : masquée, sauf si
                // c'est justement celle de la perte en cours d'édition (sinon
                // aucune puce n'apparaîtrait sélectionnée).
                if (e.key != ReconciliationService.lossCategory ||
                    _category == e.key)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: _category == e.key,
                    onSelected: (_) => setState(() => _category = e.key),
                  ),
            ]),
            const SizedBox(height: 14),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Date',
                    prefixIcon: Icon(Icons.calendar_today, size: 18)),
                child: Text(_dayLabel(_date), style: AppTextStyles.body),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
                controller: _origin,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                    labelText: 'Provenance (optionnel)',
                    hintText: 'Service midi, table 4…')),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
                label: _isEdit ? 'Enregistrer' : 'Déclarer',
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

/// Libellés des fréquences de charge (clé = valeur stockée / CHECK SQL).
const Map<String, String> _kFrequencyLabels = {
  'monthly': 'Mensuel',
  'quarterly': 'Trimestriel',
  'yearly': 'Annuel',
  'once': 'Unique',
};

/// Libellés des catégories de charge fixe (clé = valeur stockée / CHECK SQL).
const Map<String, String> _kChargeCategoryLabels = {
  'loyer': 'Loyer',
  'electricite': 'Électricité',
  'internet': 'Internet',
  'impots': 'Impôts',
  'salaires': 'Salaires',
  'autre': 'Autre',
};

/// Libellés des catégories de perte (clé = valeur stockée / CHECK SQL).
///
/// `ecart_inventaire` est produit UNIQUEMENT par la réconciliation
/// (hotfix_141) : il figure ici pour l'affichage, mais l'éditeur de perte ne
/// le propose pas à la saisie manuelle — un écart d'inventaire se constate en
/// comptant, il ne se déclare pas à la main.
const Map<String, String> _kLossCategoryLabels = {
  'casse': 'Casse',
  'reste_invendu': 'Invendu',
  'plat_mal_fait': 'Plat raté',
  'non_paye': 'Non payé',
  'materiel_endommage': 'Matériel',
  'ecart_inventaire': 'Écart d\'inventaire',
  'autre': 'Autre',
};

/// Date courte `jj/mm/aaaa`.
String _dayLabel(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/${d.year}';

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
