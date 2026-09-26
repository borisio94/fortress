import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_service.dart';
import '../../../../core/services/daily_expense_service.dart';
import '../../../../core/services/fixed_charge_service.dart';
import '../../../../core/services/ingredient_service.dart';
import '../../../../core/services/loss_service.dart';
import '../../../../core/services/reconciliation_service.dart';
import '../../../../core/services/restaurant_reporting_service.dart'
    show LossLine;
import '../../../../core/services/round_routing.dart';
import '../../../../core/services/service_incident_service.dart';
import '../../../../core/services/stock_item_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../data/restaurant_dashboard_providers.dart'
    show restaurantFinanceProvider;
import '../widgets/resto_empty_state.dart' show RestoEmptyState;
import '../../../caisse/domain/entities/sale_item.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../domain/entities/daily_expense.dart';
import '../../domain/entities/fixed_charge.dart';
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/loss.dart';
import '../../domain/entities/restaurant_activity.dart';
import '../widgets/resto_period_sheet.dart';
import '../widgets/resto_tab_kit.dart';
import '../widgets/resto_section_header.dart';
import '../widgets/expense_kind_visuals.dart';
import '../widgets/resto_underline_tabs.dart';

/// HUB FINANCES DU RESTAURANT — ce que l'établissement dépense et perd.
///
/// Quatre onglets : Activités · Dépenses · Charges · Pertes.
///
/// IL EN PORTAIT SIX, et trois n'étaient pas financiers. Ingrédients et
/// Fournitures sont partis le 21/09/2026 vers l'écran Stock, qui a sa propre
/// entrée de menu : compter sa réserve et lire ses marges ne demandent ni les
/// mêmes gestes ni les mêmes droits.
///
/// ACTIVITÉS RESTE ICI. C'est de la configuration — les secteurs qui ventilent
/// le chiffre d'affaires, cuisine et bar — mais son seul usage est cette
/// ventilation, et il n'existe aucun écran de paramètres restaurant où la
/// loger. En créer un pour une page consultée deux fois dans la vie d'un
/// établissement coûterait plus que l'approximation.
///
/// L'ONGLET PAR DÉFAUT EST DÉPENSES. C'était Ingrédients : un écran de réserve
/// accueillait quiconque cliquait sur « Finances ».
///
/// Restaurant-only (route `sectorIn` restaurant + admin).
class FinancesHubPage extends StatelessWidget {
  final String shopId;
  const FinancesHubPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: shopId,
      title: 'Finances',
      isRootPage: false,
      actions: [
        IconButton(
          tooltip: 'Personnel',
          icon: const Icon(Icons.badge_outlined),
          onPressed: () => context.push('/shop/$shopId/restaurant/personnel'),
        ),
        IconButton(
          tooltip: 'Clôture de caisse',
          icon: const Icon(Icons.point_of_sale_outlined),
          onPressed: () =>
              context.push('/shop/$shopId/restaurant/caisse/cloture'),
        ),
        // L'inventaire compare le stock théorique au stock compté : il a
        // suivi le stock, dont il est le prolongement.
        IconButton(
          tooltip: 'Stock',
          icon: const Icon(Icons.inventory_2_outlined),
          onPressed: () => context.push('/shop/$shopId/restaurant/stock'),
        ),
      ],
      body: DefaultTabController(
        // La longueur DOIT valoir le nombre d'onglets rendus. Elle annonçait
        // sept pour six depuis `45e517a` (28/07/2026) : en debug, Flutter lève
        // une assertion sur ce désaccord ; en release, elle est retirée et le
        // désaccord passe inaperçu. Les builds web de production étant des
        // release, personne ne l'avait vu.
        length: 4,
        child: Column(
          children: [
            // LE TITRE DE LA PAGE, DANS LE CORPS (lot Shell, 25/09/2026) : une page
            // racine du restaurant porte son nom ici, la barre du haut se tait. Il
            // manquait : sur ordinateur, l'écran n'affichait aucun nom.
            // Titre SEUL : la période ne cadre pas toute la page, elle vit dans
            // l'onglet Pertes.
            const RestoSectionHeader(title: 'Finances'),
            // ONGLETS SOULIGNÉS, comme Stock, Menu et Commandes (25/09/2026) :
            // plus de bande teintée ni de `TabBar` dont libellé et trait
            // étaient en primaire. Le balayage entre onglets reste.
            const RestoUnderlineTabBar(
                labels: ['Dépenses', 'Charges', 'Pertes', 'Activités']),
            Expanded(
              child: TabBarView(
                children: [
                  _DailyExpensesTab(shopId: shopId),
                  _ChargesTab(shopId: shopId),
                  _LossesTab(shopId: shopId),
                  _ActivitiesTab(shopId: shopId),
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
class _ActivitiesTab extends StatefulWidget {
  final String shopId;
  const _ActivitiesTab({required this.shopId});
  @override
  State<_ActivitiesTab> createState() => _ActivitiesTabState();
}

class _ActivitiesTabState extends RestoTabState<_ActivitiesTab> {
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
                    return RestoCard(
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
                                  '${a.isStockMode ? 'Mode stock${a.stockThreshold > 0 ? ' · seuil ${a.stockThreshold}' : ''}' : 'Mode recette'}'
                                  ' · ${_stationLabel(a)}',
                                  style: AppTextStyles.caption),
                            ],
                          ),
                        ),
                        RestoPill(a.isStockMode ? 'stock' : 'recette', cs.primary),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Poste explicite, ou celui que le routage déduira du mode — le gérant doit
  /// lire où partiront ses bons, pas s'il a rempli un champ.
  String _stationLabel(RestaurantActivity a) {
    final explicit = ServiceStation.fromKey(a.station);
    if (explicit != null) return explicit.title;
    return a.isStockMode
        ? '${ServiceStation.bar.title} (auto)'
        : '${ServiceStation.cuisine.title} (auto)';
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

  /// Poste de service. `null` = « Auto », le poste reste déduit du mode —
  /// c'est l'état de toutes les activités créées avant hotfix_144.
  late ServiceStation? _station =
      ServiceStation.fromKey(widget.existing?.station);
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
      await ActivityService.update(widget.existing!.copyWith(
        name: name,
        mode: _mode,
        stockThreshold: seuil,
        station: _station?.key,
        // Repasser sur « Auto » doit VRAIMENT détacher le poste : sans ce
        // drapeau, `copyWith` garderait l'ancien (résolution par `??`).
        clearStation: _station == null,
      ));
    } else {
      await ActivityService.create(
          shopId: widget.shopId,
          name: name,
          mode: _mode,
          stockThreshold: seuil,
          station: _station?.key);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final a = widget.existing!;
    // LA CONFIRMATION DIT CE QUE LA SUPPRESSION EMPORTE. Elle n'avait pas de
    // texte : on supprimait « Bar » sans savoir que douze plats y étaient
    // rattachés, ni que leurs ventes passées changeraient de ligne — le
    // secteur d'une vente n'est pas figé, il se relit sur le plat.
    final n = ActivityService.attachedTo(widget.shopId, a.id);
    final attached = ActivityService.attachedLabel(n.dishes, n.stockItems);
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer « ${a.name} » ?',
      body: Text(attached == null
          ? 'Aucun plat ni article de stock n\'y est rattaché.'
          : '$attached '
              '${n.dishes + n.stockItems > 1 ? 'seront détachés et passeront' : 'sera détaché et passera'} '
              'sous « Sans secteur », ventes passées comprises.'),
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
              restoNumField(_seuil, 'Seuil d\'alerte (global)'),
            ],
            const SizedBox(height: 14),
            Text('Poste de service', style: AppTextStyles.caption),
            const SizedBox(height: 2),
            Text(
              'Où les articles de ce secteur sont préparés. « Auto » déduit le '
              'poste du mode : stock → bar, recette → cuisine.',
              style: AppTextStyles.captionHint,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('Auto'),
                  selected: _station == null,
                  onSelected: (_) => setState(() => _station = null),
                ),
                for (final s in ServiceStation.values)
                  ChoiceChip(
                    label: Text(s.title),
                    selected: _station == s,
                    onSelected: (_) => setState(() => _station = s),
                  ),
              ],
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
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
                      style: AppTextStyles.label.copyWith(color: sem.dangerText)),
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
class _ChargesTab extends StatefulWidget {
  final String shopId;
  const _ChargesTab({required this.shopId});
  @override
  State<_ChargesTab> createState() => _ChargesTabState();
}

class _ChargesTabState extends RestoTabState<_ChargesTab> {
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
      body: Text('« ${c.name} » — échéance du ${restoDayLabel(c.nextDueDate)}. '
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
    return RestoCard(
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
                  RestoPill('réglée', sem.success),
                ] else if (charge.isOverdue) ...[
                  const SizedBox(width: 6),
                  RestoPill('en retard', sem.danger),
                ] else if (charge.isDueSoon) ...[
                  const SizedBox(width: 6),
                  RestoPill('bientôt', sem.warning),
                ],
              ]),
              Text(
                  '${CurrencyFormatter.format(charge.amount.toDouble())}'
                  ' · $freq · $cat · échéance ${restoDayLabel(charge.nextDueDate)}',
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
              Expanded(child: restoNumField(_amount, 'Montant (F)')),
              const SizedBox(width: 10),
              Expanded(child: restoNumField(_alert, 'Alerte (j avant)')),
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
                child: Text(restoDayLabel(_dueDate), style: AppTextStyles.body),
              ),
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
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
                      style: AppTextStyles.label.copyWith(color: sem.dangerText)),
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
//  Onglet DÉPENSES DU JOUR (Lot E — achats marché, gaz, entretien…)
// ═══════════════════════════════════════════════════════════════════════
class _DailyExpensesTab extends StatefulWidget {
  final String shopId;
  const _DailyExpensesTab({required this.shopId});
  @override
  State<_DailyExpensesTab> createState() => _DailyExpensesTabState();
}

class _DailyExpensesTabState extends RestoTabState<_DailyExpensesTab> {
  @override
  String get table => 'daily_expenses';
  @override
  String get shopId => widget.shopId;

  /// Mois affiché — les dépenses se lisent par mois, comme la paie.
  DateTime _month = DateTime.now();

  DateTime get _from => DateTime(_month.year, _month.month, 1);
  DateTime get _to => DateTime(_month.year, _month.month + 1, 0);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final items =
        DailyExpenseService.forShop(widget.shopId, from: _from, to: _to);
    final food = DailyExpenseService.foodCost(widget.shopId,
        from: _from, to: _to);
    final other = DailyExpenseService.operatingCost(widget.shopId,
        from: _from, to: _to);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              IconButton(
                onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month - 1)),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(_monthLabel(_month),
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyBold),
              ),
              IconButton(
                onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month + 1)),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ),
        // Les deux chiffres qui comptent : ce qui part en matières (le food
        // cost réel) et le reste de l'exploitation.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(children: [
            Expanded(
              child: RestoMiniStat(
                label: 'Achats matières',
                value: CurrencyFormatter.format(food.toDouble()),
                color: cs.primary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: RestoMiniStat(
                label: 'Autres dépenses',
                value: CurrencyFormatter.format(other.toDouble()),
                color: sem.warning,
              ),
            ),
          ]),
        ),
        headerButton('Dépense', () => _edit(null)),
        Expanded(
          child: items.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'Aucune dépense ce mois',
                  subtitle: 'Achat au marché, gaz, transport… Saisir vos '
                      'achats permet de comparer le coût réel des matières à '
                      'ce que vos recettes prévoient.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final e = items[i];
                    return RestoCard(
                      onTap: () => _edit(e),
                      child: Row(children: [
                        Icon(e.kind.icon, size: 18, color: cs.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.description,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.bodyBold
                                      .copyWith(color: cs.onSurface)),
                              Text(
                                  [
                                    e.kind.label,
                                    restoDayLabel(e.expenseDate),
                                    if ((e.paidBy ?? '').isNotEmpty)
                                      'payé par ${e.paidBy}',
                                    if (!e.isCash) 'hors caisse',
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.caption),
                            ],
                          ),
                        ),
                        Text(CurrencyFormatter.format(e.amount.toDouble()),
                            style: AppTextStyles.bodyBold),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _edit(DailyExpense? e) async {
    await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => _DailyExpenseEditor(shopId: widget.shopId, existing: e),
    );
    if (mounted) setState(() {});
  }

  static String _monthLabel(DateTime d) {
    const months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
    ];
    return '${months[d.month - 1]} ${d.year}';
  }
}

class _DailyExpenseEditor extends StatefulWidget {
  final String shopId;
  final DailyExpense? existing;
  const _DailyExpenseEditor({required this.shopId, this.existing});
  @override
  State<_DailyExpenseEditor> createState() => _DailyExpenseEditorState();
}

class _DailyExpenseEditorState extends State<_DailyExpenseEditor> {
  late final _desc =
      TextEditingController(text: widget.existing?.description ?? '');
  late final _amount = TextEditingController(
      text: (widget.existing?.amount ?? 0) == 0
          ? ''
          : '${widget.existing!.amount}');
  late final _paidBy =
      TextEditingController(text: widget.existing?.paidBy ?? '');
  late ExpenseKind _kind = widget.existing?.kind ?? ExpenseKind.achatMarche;
  late bool _isCash = widget.existing?.isCash ?? true;
  late DateTime _date = widget.existing?.expenseDate ?? DateTime.now();

  /// Catalogue d'ingrédients, pour rattacher l'achat à l'un d'eux.
  late final List<Ingredient> _ingredients =
      IngredientService.forShop(widget.shopId);

  /// Ingrédient acheté par cette dépense — `null` = non rattachée.
  ///
  /// Vérifié contre le catalogue : un ingrédient supprimé depuis la saisie
  /// laisserait un id orphelin que le formulaire réenregistrerait en silence.
  late String? _ingredientId = _ingredients
          .any((i) => i.id == widget.existing?.ingredientId)
      ? widget.existing!.ingredientId
      : null;

  String? _err;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _desc.dispose();
    _amount.dispose();
    _paidBy.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final desc = _desc.text.trim();
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    if (desc.isEmpty) {
      setState(() => _err = 'Description requise');
      return;
    }
    if (amount <= 0) {
      setState(() => _err = 'Montant invalide');
      return;
    }
    if (_isEdit) {
      await DailyExpenseService.update(widget.existing!.copyWith(
        description: desc,
        amount: amount,
        category: _kind.key,
        paidBy: _paidBy.text.trim(),
        isCash: _isCash,
        expenseDate: _date,
        ingredientId: _ingredientId,
        // Détachement explicite : un `null` seul voudrait dire « inchangé ».
        clearIngredient: _ingredientId == null,
      ));
    } else {
      await DailyExpenseService.record(
        shopId: widget.shopId,
        description: desc,
        amount: amount,
        kind: _kind,
        paidBy: _paidBy.text.trim(),
        isCash: _isCash,
        date: _date,
        ingredientId: _ingredientId,
      );
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette dépense ?',
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await DailyExpenseService.delete(widget.existing!.id, widget.shopId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier la dépense' : 'Nouvelle dépense',
      icon: Icons.receipt_long_outlined,
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
              decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'Poisson, tomates, bouteille de gaz…'),
            ),
            const SizedBox(height: 10),
            restoNumField(_amount, 'Montant'),
            const SizedBox(height: 12),
            Text('Catégorie', style: AppTextStyles.caption),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final k in ExpenseKind.selectable)
                  ChoiceChip(
                    label: Text(k.label),
                    selected: _kind == k,
                    // Le rattachement à un ingrédient S'EFFACE quand on quitte
                    // « achat marché ». Son champ disparaît alors de l'écran,
                    // mais la valeur, elle, partait toujours à
                    // l'enregistrement : on créait un lien invisible, que le
                    // bilan comptait ensuite des deux côtés. Un réglage qu'on
                    // ne voit plus ne doit plus exister.
                    onSelected: (_) => setState(() {
                      _kind = k;
                      if (!k.isFoodCost) _ingredientId = null;
                    }),
                  ),
              ],
            ),
            // ── Rattachement à un ingrédient ─────────────────────────────
            // C'est ce lien qui rend le coût par plat calculable : sans lui,
            // l'argent sort de la caisse mais aucune assiette ne sait qu'elle
            // l'a consommé. Proposé uniquement sur un achat de matières — gaz
            // et électricité n'ont pas d'ingrédient.
            if (_kind.isFoodCost && _ingredients.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Ingrédient acheté', style: AppTextStyles.caption),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('Aucun'),
                    selected: _ingredientId == null,
                    onSelected: (_) => setState(() => _ingredientId = null),
                  ),
                  for (final i in _ingredients)
                    ChoiceChip(
                      label: Text(i.name),
                      selected: _ingredientId == i.id,
                      onSelected: (_) => setState(() => _ingredientId = i.id),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                  _ingredientId == null
                      ? 'Sans ingrédient, cette dépense compte dans le food '
                          'cost global mais n\'est imputée à aucun plat.'
                      : 'Ce montant sera réparti entre les plats qui '
                          'contiennent cet ingrédient, au prorata des ventes '
                          'du mois.',
                  style: AppTextStyles.captionHint),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _paidBy,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Payé par (optionnel)',
                  hintText: 'Nom de la personne à rembourser'),
            ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isCash,
              onChanged: (v) => setState(() => _isCash = v),
              title: Text('Payé en espèces', style: AppTextStyles.bodySm),
              subtitle: Text(
                  _isCash
                      ? 'Déduit du tiroir à la clôture de caisse.'
                      : 'Mobile money, virement… n\'affecte pas le tiroir.',
                  style: AppTextStyles.captionHint),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(restoDayLabel(_date), style: AppTextStyles.bodySm),
              trailing: const Text('Modifier'),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime.now().subtract(const Duration(days: 365)),
                  lastDate: DateTime.now(),
                );
                if (picked != null) setState(() => _date = picked);
              },
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: _isEdit ? 'Enregistrer' : 'Ajouter',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: _save,
            ),
            if (_isEdit) ...[
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: _delete,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: sem.danger),
                  label: Text('Supprimer',
                      style: AppTextStyles.label.copyWith(color: sem.dangerText)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Petit indicateur chiffré (en-tête d'onglet).
class _LossesTab extends ConsumerStatefulWidget {
  final String shopId;
  const _LossesTab({required this.shopId});
  @override
  ConsumerState<_LossesTab> createState() => _LossesTabState();
}

class _LossesTabState extends ConsumerState<_LossesTab> {
  /// Tout ce qui fait bouger la valeur d'une perte : la perte elle-même, et
  /// les ventes, achats et recettes dont dépend la répartition.
  static const _valuationTables = {
    'losses',
    'orders',
    'daily_expenses',
    'ingredients',
    'recipe_ingredients',
    'products',
  };

  late final OnDataChanged _listener;

  @override
  void initState() {
    super.initState();
    _listener = (t, sid) {
      if (!mounted) return;
      if (!_valuationTables.contains(t)) return;
      if (sid != widget.shopId && sid != '_all') return;
      ref.invalidate(restaurantFinanceProvider(widget.shopId));
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(restaurantFinanceProvider(widget.shopId));
    final lines = report.lossLines;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          // Le même sélecteur que le tableau de bord, et la MÊME période : les
          // deux pilotent `dashPeriodProvider`. La feuille le dit, pour qu'un
          // choix fait ici ne surprenne pas au retour sur le tableau de bord.
          const Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: RestoPeriodButton(
                  scope: 'Partagée avec le tableau de bord'),
            ),
          ),
          FilledButton.icon(
            onPressed: () => _edit(null),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Perte'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
          ),
        ]),
      ),
      if (lines.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
                'Total des pertes sur la période : '
                '${CurrencyFormatter.format(report.losses.toDouble())}',
                style: AppTextStyles.captionHint),
          ),
        ),
      Expanded(
        child: lines.isEmpty
            ? const RestoEmptyState(
                icon: Icons.warning_amber_rounded,
                title: 'Aucune perte sur cette période',
                subtitle:
                    'Casse, invendus, additions non payées… déclarez-les ici.',
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: lines.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _LossRow(
                  line: lines[i],
                  onTap: () => _edit(lines[i].loss),
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
    if (mounted) ref.invalidate(restaurantFinanceProvider(widget.shopId));
  }
}

class _LossRow extends StatelessWidget {
  final LossLine line;
  final VoidCallback onTap;
  const _LossRow({required this.line, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final loss = line.loss;
    final cat = _kLossCategoryLabels[loss.category] ?? loss.category;
    return RestoCard(
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
                RestoPill(cat, sem.danger),
              ]),
              Text(
                  '${CurrencyFormatter.format(line.value)}'
                  ' · ${restoDayLabel(loss.date)}'
                  '${loss.origin.isNotEmpty ? ' · ${loss.origin}' : ''}',
                  style: AppTextStyles.caption),
              // Perte de matière : le montant de déclaration n'est qu'une
              // estimation. Affiché pour mémoire, JAMAIS sommé.
              if (line.isRecalculated)
                Text(
                    'Estimation à la déclaration : '
                    '${CurrencyFormatter.format(loss.amount.toDouble())} '
                    '(non comptée)',
                    style: AppTextStyles.captionHint),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Ce à quoi une perte est rattachée dans l'éditeur.
enum _LossAttach { none, plates, ingredient }

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

  // ── Rattachement (audit des marges, 2026-09-15) ─────────────────────────
  // Une perte de MATIÈRE doit dire ce qui a été perdu — des plats ou un
  // ingrédient — sans quoi le bilan la compterait en plus d'achats déjà
  // répartis sur les plats vendus. Règle : `Loss.attachmentError`.

  late final List<Product> _dishes = LocalStorageService.getProductsForShop(
          widget.shopId)
      .where((p) => p.id != null && p.isActive)
      .toList();
  late final List<Ingredient> _ingredients =
      IngredientService.forShop(widget.shopId);

  late final List<WastedPlate> _plates = [...?widget.existing?.items];
  late String? _ingredientId = (widget.existing?.ingredientId
                  ?.startsWith('ig_') ??
              false) &&
          _ingredients.any((i) => i.id == widget.existing!.ingredientId)
      ? widget.existing!.ingredientId
      : null;
  late _LossAttach _mode = _plates.isNotEmpty
      ? _LossAttach.plates
      : (_ingredientId != null ? _LossAttach.ingredient : _LossAttach.none);

  String? _pickedDish;
  final _dishQty = TextEditingController(text: '1');

  /// Catégorie de matière saisissable à la main : rattachement obligatoire.
  bool get _mustAttach =>
      Loss.materialCategories.contains(_category) &&
      _category != ReconciliationService.lossCategory;

  /// Rattachement proposé à l'écran (obligatoire ou facultatif).
  bool get _canAttach => _mustAttach || _category == 'autre';

  /// Écart d'inventaire : produit par la réconciliation, son rattachement
  /// (ingrédient ou fourniture) n'est pas modifiable ici.
  bool get _isInventory => _category == ReconciliationService.lossCategory;

  /// Mode effectif : une catégorie obligatoire n'offre pas « aucun ».
  _LossAttach get _effectiveMode =>
      _mustAttach && _mode == _LossAttach.none ? _LossAttach.plates : _mode;

  @override
  void dispose() {
    _desc.dispose();
    _amount.dispose();
    _origin.dispose();
    _dishQty.dispose();
    super.dispose();
  }

  String _dishName(String productId) {
    for (final p in _dishes) {
      if (p.id == productId) return p.name;
    }
    return 'Plat supprimé';
  }

  void _addPlate() {
    final pid = _pickedDish;
    final qty = int.tryParse(_dishQty.text.trim()) ?? 0;
    if (pid == null || qty <= 0) {
      setState(() => _err = 'Choisissez un plat et une quantité');
      return;
    }
    setState(() {
      final i = _plates.indexWhere((p) => p.productId == pid);
      if (i >= 0) {
        _plates[i] = WastedPlate(
            productId: pid, quantity: _plates[i].quantity + qty);
      } else {
        _plates.add(WastedPlate(productId: pid, quantity: qty.toDouble()));
      }
      _pickedDish = null;
      _dishQty.text = '1';
      _err = null;
    });
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
    // Rattachement retenu selon la catégorie.
    List<WastedPlate> items = const [];
    String? ingredientId;
    if (_isInventory) {
      items = widget.existing?.items ?? const [];
      ingredientId = widget.existing?.ingredientId;
    } else if (_canAttach) {
      switch (_effectiveMode) {
        case _LossAttach.plates:
          items = List.of(_plates);
        case _LossAttach.ingredient:
          ingredientId = _ingredientId;
        case _LossAttach.none:
          break;
      }
    }

    final issue = Loss.attachmentError(
        category: _category, items: items, ingredientId: ingredientId);
    if (issue != null) {
      setState(() => _err = issue);
      return;
    }

    var amount = int.tryParse(_amount.text.trim()) ?? 0;
    if (amount <= 0) {
      if (items.isNotEmpty && ingredientId == null) {
        // Assiettes : le montant n'est qu'une estimation, le bilan recalcule.
        // Estimée ici plutôt qu'exigée — personne ne sait chiffrer la matière
        // d'un plat raté de tête.
        amount = ServiceIncidentService.materialCostOf(widget.shopId, [
          for (final p in items)
            SaleItem(
              productId: p.productId,
              productName: _dishName(p.productId),
              unitPrice: 0,
              quantity: p.quantity.round(),
            ),
        ]).round();
      } else {
        setState(() => _err = 'Montant requis');
        return;
      }
    }

    try {
      if (_isEdit) {
        await LossService.update(widget.existing!.copyWith(
          description: desc,
          amount: amount,
          category: _category,
          origin: _origin.text.trim(),
          date: _date,
          items: items,
          ingredientId: ingredientId,
          clearIngredient: ingredientId == null,
        ));
      } else {
        await LossService.record(
          shopId: widget.shopId,
          description: desc,
          amount: amount,
          category: _category,
          origin: _origin.text.trim(),
          date: _date,
          items: items,
          ingredientId: ingredientId,
        );
      }
    } on LossAttachmentException catch (e) {
      if (mounted) setState(() => _err = e.message);
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  /// Section « Ce qui a été perdu » : plats ou ingrédient.
  List<Widget> _attachmentSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final inputStyle = AppTextStyles.input.copyWith(color: cs.onSurface);

    if (_isInventory) {
      final id = widget.existing?.ingredientId;
      String? name;
      for (final i in _ingredients) {
        if (i.id == id) name = i.name;
      }
      name ??= id == null ? null : StockItemService.byId(widget.shopId, id)?.name;
      return [
        const SizedBox(height: 14),
        Text(
            'Écart constaté à l\'inventaire'
            '${name == null ? '' : ' — $name'}.',
            style: AppTextStyles.captionHint),
      ];
    }
    if (!_canAttach) return const [];

    final mode = _effectiveMode;
    return [
      const SizedBox(height: 14),
      Text(
          _mustAttach
              ? 'Ce qui a été perdu (obligatoire)'
              : 'Ce qui a été perdu (facultatif)',
          style: AppTextStyles.caption),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (!_mustAttach)
          ChoiceChip(
            label: const Text('Rien de précis'),
            selected: mode == _LossAttach.none,
            onSelected: (_) => setState(() => _mode = _LossAttach.none),
          ),
        ChoiceChip(
          label: const Text('Des plats'),
          selected: mode == _LossAttach.plates,
          onSelected: (_) => setState(() => _mode = _LossAttach.plates),
        ),
        ChoiceChip(
          label: const Text('Un ingrédient'),
          selected: mode == _LossAttach.ingredient,
          onSelected: (_) => setState(() => _mode = _LossAttach.ingredient),
        ),
      ]),
      if (mode == _LossAttach.plates) ...[
        for (final p in _plates)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(_dishName(p.productId), style: AppTextStyles.bodySm),
            subtitle: Text('× ${p.quantity.round()}',
                style: AppTextStyles.caption),
            trailing: IconButton(
              tooltip: 'Retirer',
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => setState(() => _plates.remove(p)),
            ),
          ),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<String>(
              initialValue: _pickedDish,
              isExpanded: true,
              style: inputStyle,
              decoration: const InputDecoration(labelText: 'Plat'),
              items: [
                for (final d in _dishes)
                  DropdownMenuItem(
                    value: d.id,
                    child: Text(d.name,
                        overflow: TextOverflow.ellipsis, style: inputStyle),
                  ),
              ],
              onChanged: (v) => setState(() => _pickedDish = v),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 64, child: restoNumField(_dishQty, 'Qté')),
          IconButton(
            tooltip: 'Ajouter ce plat',
            icon: const Icon(Icons.add_circle_outline_rounded),
            onPressed: _addPlate,
          ),
        ]),
        const SizedBox(height: 4),
        Text(
            'Montant facultatif : laissé vide, il est estimé. Le bilan '
            'recalcule la matière de ces plats sur la période affichée.',
            style: AppTextStyles.captionHint),
      ],
      if (mode == _LossAttach.ingredient) ...[
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: _ingredientId,
          isExpanded: true,
          style: inputStyle,
          decoration: const InputDecoration(labelText: 'Ingrédient'),
          items: [
            for (final i in _ingredients)
              DropdownMenuItem(
                value: i.id,
                child: Text(i.name,
                    overflow: TextOverflow.ellipsis, style: inputStyle),
              ),
          ],
          onChanged: (v) => setState(() => _ingredientId = v),
        ),
        const SizedBox(height: 4),
        Text(
            'Le montant est retiré des achats de cet ingrédient sur la '
            'période, dans la limite de ce qui a été acheté.',
            style: AppTextStyles.captionHint),
      ],
    ];
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
            restoNumField(_amount, 'Montant (F)'),
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
                    onSelected: (_) => setState(() {
                      _category = e.key;
                      _err = null;
                    }),
                  ),
            ]),
            ..._attachmentSection(context),
            const SizedBox(height: 14),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Date',
                    prefixIcon: Icon(Icons.calendar_today, size: 18)),
                child: Text(restoDayLabel(_date), style: AppTextStyles.body),
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
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
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
                      style: AppTextStyles.label.copyWith(color: sem.dangerText)),
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

