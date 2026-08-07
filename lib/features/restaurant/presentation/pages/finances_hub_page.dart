import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_service.dart';
import '../../../../core/services/daily_expense_service.dart';
import '../../../../core/services/fixed_charge_service.dart';
import '../../../../core/services/dish_cost_service.dart';
import '../../../../core/services/ingredient_service.dart';
import '../../../../core/services/loss_service.dart';
import '../../../../core/services/reconciliation_service.dart';
import '../../../../core/services/round_routing.dart';
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
import '../../domain/entities/daily_expense.dart';
import '../../domain/entities/fixed_charge.dart';
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/loss.dart';
import '../../domain/entities/restaurant_activity.dart';
import '../../domain/entities/stock_item.dart';
import '../widgets/resto_surfaces.dart';

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
        IconButton(
          tooltip: 'Inventaire',
          icon: const Icon(Icons.fact_check_outlined),
          onPressed: () =>
              context.push('/shop/$shopId/restaurant/inventory/reconcile'),
        ),
      ],
      body: DefaultTabController(
        length: 7,
        child: Column(
          children: [
            Material(
              // Même opacité que les cartes : la barre d'onglets était le
              // dernier aplat plein de la page.
              color: restoGlassFill(context),
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
                  Tab(text: 'Fournitures'),
                  Tab(text: 'Dépenses'),
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
                  _DailyExpensesTab(shopId: shopId),
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

  bool _backfilling = false;

  /// Écrit les achats manquants, après confirmation chiffrée.
  Future<void> _backfill() async {
    final pending = IngredientService.withoutRecordedPurchase(widget.shopId);
    if (pending.isEmpty) return;
    final total = pending.fold<int>(
        0, (s, i) => s + IngredientService.backfillAmountFor(i));

    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.receipt_long_outlined,
      iconColor: Theme.of(context).colorScheme.primary,
      title: 'Enregistrer les achats manquants ?',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
              '${pending.length} ingrédient(s) ont du stock mais aucun achat '
              'enregistré. Une dépense sera créée pour chacun, à hauteur de la '
              'valeur de son stock — ${CurrencyFormatter.format(total.toDouble())} '
              'au total.',
              style: AppTextStyles.body),
          const SizedBox(height: 8),
          Text(
              'Chaque dépense est datée du jour d\'achat déclaré, et marquée '
              'hors espèces : ces achats sont anciens, les compter comme '
              'sorties du tiroir fausserait votre prochaine clôture de caisse.',
              style: AppTextStyles.caption),
        ],
      ),
      cancelLabel: 'Annuler',
      confirmLabel: 'Enregistrer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;

    setState(() => _backfilling = true);
    try {
      final r = await IngredientService.recordMissingPurchases(widget.shopId);
      if (!mounted) return;
      setState(() => _backfilling = false);
      AppSnack.success(
          context,
          '${r.count} achat(s) enregistré(s) · '
          '${CurrencyFormatter.format(r.total.toDouble())}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _backfilling = false);
      AppSnack.error(context, 'Régularisation incomplète : $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = IngredientService.forShop(widget.shopId);
    // Ingrédients dont l'achat n'a jamais été enregistré en dépense — donc
    // dont le coût n'est imputé à aucun plat.
    final pending = IngredientService.withoutRecordedPurchase(widget.shopId);
    // Ingrédients sans AUCUNE dépense rattachée — donc sans coût imputable.
    // Calculé une fois pour toute la liste : le faire par ligne relirait le
    // journal des dépenses à chaque ingrédient.
    final noCost = IngredientService.withoutCostData(widget.shopId);
    return Column(
      children: [
        // MÉTHODE DE COÛT — en tête de l'onglet Ingrédients parce que c'est
        // elle qui décide de ce qu'on saisit en dessous : des quantités, ou
        // rien du tout.
        _CostMethodSelector(
          shopId: widget.shopId,
          onChanged: () => setState(() {}),
        ),
        if (pending.isNotEmpty) _BackfillBanner(
          count: pending.length,
          total: pending.fold<int>(
              0, (s, i) => s + IngredientService.backfillAmountFor(i)),
          busy: _backfilling,
          onRun: _backfill,
        ),
        // PAS de bouton « + Ingrédient » ici, à dessein.
        //
        // Un ingrédient ne s'invente pas : il existe parce qu'un plat le
        // contient. Le créer depuis cet écran produisait des ingrédients
        // orphelins, rattachés à aucune recette et souvent sans montant —
        // exactement ceux qui minorent le coût matières sans qu'on le voie.
        // La création vit désormais dans la fiche du plat, au moment où l'on
        // sait à quoi l'ingrédient sert. Cet onglet garde ce qui lui revient :
        // réapprovisionner, corriger, supprimer.
        const SizedBox(height: 4),
        Expanded(
          child: items.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.eco_outlined,
                  title: 'Aucun ingrédient',
                  subtitle:
                      'Les ingrédients se créent depuis la fiche d\'un plat, '
                      'au moment de composer sa recette. Ils apparaîtront ici '
                      'pour être réapprovisionnés et suivis.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _IngredientRow(
                    ing: items[i],
                    noCost: noCost.contains(items[i].id),
                    onReceive: () => _receive(items[i]),
                    onEdit: () => _edit(items[i]),
                    onDelete: () => _delete(items[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _receive(Ingredient ing) async {
    final r = await showAdaptiveFormSheet<_ReceiptResult>(
      context: context,
      builder: (_) => _IngredientReceiptSheet(ingredient: ing),
    );
    if (r == null || !mounted) return;

    // Le stock d'abord : c'est la correction attendue, elle ne doit pas
    // dépendre du succès de l'écriture de la dépense. Le coût unitaire est
    // réévalué au passage, en moyenne pondérée avec le stock existant.
    await IngredientService.receive(
      widget.shopId,
      ing.id,
      quantity: r.quantity,
      amountPaid: r.amount,
    );

    // La dépense RATTACHÉE à l'ingrédient : c'est elle qui rendra le coût du
    // plat calculable. Sans ce lien, l'argent sort de la caisse mais aucune
    // assiette ne sait qu'elle l'a consommé.
    if (r.amount > 0) {
      await DailyExpenseService.record(
        shopId: widget.shopId,
        description: '${ing.name} — ${_fmt(r.quantity)} ${ing.unit}',
        amount: r.amount,
        kind: ExpenseKind.achatMarche,
        ingredientId: ing.id,
        date: r.date,
      );
    }
    if (mounted) setState(() {});
  }

  /// Suppression depuis la liste — même confirmation et même avertissement que
  /// depuis l'éditeur : c'est la MÊME action, elle ne doit pas être plus légère
  /// parce qu'elle est plus accessible.
  Future<void> _delete(Ingredient ing) async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cet ingrédient ?',
      body: Text('« ${ing.name} » sera retiré. Les plats qui le contiennent '
          'perdront leur lien vers lui, et sa part de coût ne leur sera plus '
          'imputée.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await IngredientService.delete(ing.id, widget.shopId);
    if (mounted) setState(() {});
  }

  /// MODIFICATION seulement — la création est passée dans la fiche du plat.
  Future<void> _edit(Ingredient ing) async {
    await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => _IngredientEditor(shopId: widget.shopId, existing: ing),
    );
    if (mounted) setState(() {});
  }
}

/// Une ligne d'ingrédient : trois boutons explicites, et une carte INERTE.
///
/// La carte ne réagit plus au toucher. Elle ouvrait l'éditeur, ce qui faisait
/// basculer vers un formulaire de modification chaque fois qu'on visait le
/// bouton de réception et qu'on le manquait de quelques pixels. Une action qui
/// change des données ne doit pas être déclenchée par un geste imprécis.
class _IngredientRow extends StatelessWidget {
  final Ingredient ing;

  /// Aucune dépense rattachée : cet ingrédient ne coûte rien aux plats qui le
  /// contiennent, et leur marge est donc surévaluée.
  final bool noCost;
  final VoidCallback onReceive;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _IngredientRow({
    required this.ing,
    required this.onReceive,
    required this.onEdit,
    required this.onDelete,
    this.noCost = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final q = _fmt(ing.quantity);
    return _Card(
      // Signalement ORANGE, pas rouge : rien n'est cassé, il manque une
      // information. Le rouge est déjà pris par le stock bas, qui appelle une
      // action immédiate — mélanger les deux les banaliserait tous les deux.
      borderColor: noCost ? sem.warning : null,
      background: noCost ? sem.warning.withValues(alpha: 0.07) : null,
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
                if (noCost) ...[
                  const SizedBox(width: 6),
                  _Pill('coût manquant', sem.warning),
                ],
              ]),
              Text(
                  // Unité et quantité sont FACULTATIVES : un ingrédient saisi
                  // au nom et au prix afficherait sinon « 0 F/ · stock 0 »,
                  // une ligne de bruit qui laisse croire à une donnée perdue.
                  [
                    ing.unit.trim().isEmpty
                        ? '${ing.costPerUnit} F'
                        : '${ing.costPerUnit} F/${ing.unit}',
                    if (ing.quantity > 0)
                      'stock $q ${ing.unit}'.trim(),
                    if (ing.alertThreshold > 0)
                      'seuil ${_fmt(ing.alertThreshold)}',
                    if (ing.purchaseDate != null)
                      'acheté le ${_dayLabel(ing.purchaseDate!)}',
                  ].join(' · '),
                  style: AppTextStyles.caption),
              // Une couleur seule laisse deviner ; on dit ce qui manque et où
              // le corriger. Sans cette ligne, l'orange n'est qu'une énigme.
              if (noCost)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                      'Aucun achat enregistré — les plats qui le contiennent '
                      'paraissent plus rentables qu\'ils ne le sont. '
                      'Utilisez Réception pour saisir quantité et montant.',
                      style: AppTextStyles.caption
                          .copyWith(color: sem.warning)),
                ),
            ],
          ),
        ),
        // Réception · Modifier · Supprimer — dans cet ordre : du geste le plus
        // fréquent au plus rare, et le destructif en bout de rangée, le plus
        // loin possible de celui qu'on vise tous les jours.
        IconButton(
          onPressed: onReceive,
          tooltip: 'Réception',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.add_box_outlined, size: 20, color: cs.primary),
        ),
        IconButton(
          onPressed: onEdit,
          tooltip: 'Modifier',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.edit_outlined,
              size: 19, color: cs.onSurface.withValues(alpha: 0.7)),
        ),
        IconButton(
          onPressed: onDelete,
          tooltip: 'Supprimer',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.delete_outline_rounded, size: 19, color: sem.danger),
        ),
      ]),
    );
  }
}

/// Éditeur ingrédient (création / modification / suppression).
/// MODIFICATION d'un ingrédient existant — cet éditeur ne crée plus rien.
///
/// La création est passée dans la fiche du plat : un ingrédient existe parce
/// qu'une recette le contient. Le créer hors de ce contexte produisait des
/// ingrédients orphelins, rattachés à aucun plat et souvent sans montant —
/// exactement ceux qui minorent le coût matières sans qu'on le voie.
class _IngredientEditor extends StatefulWidget {
  final String shopId;
  final Ingredient existing;
  const _IngredientEditor({required this.shopId, required this.existing});
  @override
  State<_IngredientEditor> createState() => _IngredientEditorState();
}

class _IngredientEditorState extends State<_IngredientEditor> {
  late final _name = TextEditingController(text: widget.existing.name);

  /// Quantité achetée — c'est aussi le stock de l'ingrédient.
  late final _qty = TextEditingController(
      text: _fmt(widget.existing.quantity));

  /// PRIX TOTAL payé pour [_qty] (pas le prix unitaire) : on saisit ce qui est
  /// écrit sur le reçu, l'app en dérive le coût unitaire.
  ///
  /// En modification, le champ est pré-rempli avec le total correspondant à la
  /// quantité affichée, de sorte que rouvrir puis enregistrer sans rien changer
  /// retombe sur le même coût unitaire, au franc près.
  late final _price = TextEditingController(
      text: '${_initialPrice(widget.existing)}');

  /// Total à afficher pour un ingrédient existant.
  ///
  /// Quantité nulle → le prix affiché EST le coût unitaire, exactement comme
  /// [_derivedUnitCost] le relira. Sans ce cas, tous les ingrédients saisis
  /// sans quantité (la majorité de l'existant) verraient leur prix affiché à 0
  /// et EFFACÉ au premier enregistrement.
  static int _initialPrice(Ingredient i) =>
      i.quantity > 0 ? (i.costPerUnit * i.quantity).round() : i.costPerUnit;

  /// Unité choisie dans la liste. Une unité déjà en base qui n'y figure pas
  /// (saisie libre d'avant, « 10kg »…) est ajoutée à la liste pour ne pas être
  /// silencieusement remplacée à l'enregistrement.
  /// « non précisée » par défaut à la CRÉATION : forcer « kg » étiquetait au
  /// kilo des ingrédients qu'on n'avait jamais pesés, et ce faux
  /// conditionnement se retrouvait ensuite sur chaque ligne de la liste.
  late String _unit = widget.existing.unit.trim().isNotEmpty
      ? widget.existing.unit.trim()
      : _kUnitUnknown;

  /// Unité réellement enregistrée : la sentinelle redevient une chaîne vide.
  String get _unitValue => _unit == _kUnitUnknown ? '' : _unit;

  List<String> get _units => [
        if (!_kIngredientUnits.contains(_unit)) _unit,
        ..._kIngredientUnits,
      ];

  /// Date d'achat — informative. Pré-remplie à aujourd'hui pour une création :
  /// on saisit un ingrédient le jour où on l'achète.
  late DateTime? _purchase =
      widget.existing.purchaseDate;

  String? _err;

  double get _qtyValue =>
      double.tryParse(_qty.text.trim().replaceAll(',', '.')) ?? 0;

  int get _priceValue => int.tryParse(_price.text.trim()) ?? 0;

  /// Coût d'UNE unité, dérivé du prix total et de la quantité. C'est cette
  /// valeur qui est stockée et qui alimente le coût des fiches recettes.
  ///
  /// Sans quantité, on ne peut rien diviser : le prix saisi est alors pris pour
  /// le coût d'une unité (plutôt que de perdre l'information).
  int get _derivedUnitCost =>
      _qtyValue <= 0 ? _priceValue : (_priceValue / _qtyValue).round();

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _err = 'Nom requis');
      return;
    }
    // MONTANT ABSENT À LA CRÉATION — on demande confirmation, on ne bloque pas.
    // `alertThreshold` n'est PAS passé : le seuil d'alerte n'est plus dans ce
    // formulaire, et copyWith le préserve. Le repasser à 0 ici effacerait en
    // silence les seuils déjà configurés.
    //
    // AUCUNE DÉPENSE n'est écrite ici. Une modification est une CORRECTION,
    // pas un achat : y écrire une dépense gonflerait les charges à chaque
    // passage dans le formulaire. Pour enregistrer un vrai achat, c'est
    // « Réception » — ou la création, qui vit désormais dans la fiche du plat.
    await IngredientService.update(widget.existing.copyWith(
        name: name,
        unit: _unitValue,
        costPerUnit: _derivedUnitCost,
        quantity: _qtyValue,
        purchaseDate: _purchase,
        // Date effacée par l'utilisateur : `null` seul voudrait dire
        // « inchangée », il faut le dire explicitement.
        clearPurchaseDate: _purchase == null));
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _pickPurchaseDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _purchase ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null && mounted) setState(() => _purchase = d);
  }

  Future<void> _delete() async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cet ingrédient ?',
      body: Text('« ${widget.existing.name} » sera retiré. Les recettes qui '
          'l\'utilisent afficheront « ingrédient supprimé ».'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await IngredientService.delete(widget.existing.id, widget.shopId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Modifier l\'ingrédient',
      icon: Icons.eco_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                controller: _name,
                autofocus: false,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Nom')),
            const SizedBox(height: 10),

            // ── Quantité + unité choisie dans une liste ──────────────────
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  // Le coût unitaire dérivé dépend de la quantité : il doit se
                  // recalculer à chaque frappe, pas seulement à la validation.
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                      labelText: 'Quantité',
                      helperText: 'facultative'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _unit,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Unité'),
                  // Sans style explicite, les items héritent du `titleMedium`
                  // du thème Material (16) et le menu s'affiche bien plus gros
                  // que le texte saisi dans les champs voisins.
                  // `AppTextStyles.input` est LA référence de taille de saisie.
                  style: AppTextStyles.input
                      .copyWith(color: Theme.of(context).colorScheme.onSurface),
                  items: [
                    for (final u in _units)
                      DropdownMenuItem(
                        value: u,
                        child: Text(u,
                            style: AppTextStyles.input.copyWith(
                                color:
                                    Theme.of(context).colorScheme.onSurface)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _unit = v ?? _unit),
                ),
              ),
            ]),
            const SizedBox(height: 10),

            // ── Prix total payé, coût unitaire dérivé sous le champ ──────
            //
            // À la CRÉATION, ce montant devient une vraie dépense rattachée à
            // l'ingrédient. À la MODIFICATION, il ne sert qu'à valoriser le
            // stock — le libellé et l'aide le disent, sans quoi on croit
            // saisir un achat à chaque correction.
            TextField(
              controller: _price,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Valeur du stock (F)',
                helperText:
                    'Sert à valoriser la réserve — aucune dépense créée',
              ),
            ),
            if (_priceValue > 0) ...[
              const SizedBox(height: 6),
              Text(
                  _qtyValue > 0 && _unitValue.isNotEmpty
                      ? '→ soit $_derivedUnitCost F / $_unitValue'
                      : _qtyValue > 0
                          ? '→ soit $_derivedUnitCost F par unité'
                          : '→ retenu comme coût unitaire. Quantité et unité '
                              'restent facultatives : sans elles, ce montant '
                              'compte tel quel dans la répartition.',
                  style: AppTextStyles.caption),
            ],
            // Cet écran ne crée AUCUNE dépense — le dire, sinon on croirait
            // enregistrer un achat en corrigeant une valeur de stock.
            const SizedBox(height: 6),
            Text(
                'Corriger ces valeurs n\'enregistre aucun achat. Pour un vrai '
                'réapprovisionnement, utilisez « Réception » sur la ligne de '
                'l\'ingrédient.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 10),

            // ── Date d'achat (informative) ───────────────────────────────
            InkWell(
              onTap: _pickPurchaseDate,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Date d\'achat',
                  prefixIcon: const Icon(Icons.calendar_today, size: 18),
                  // Effacer la date : elle reste optionnelle.
                  suffixIcon: _purchase == null
                      ? null
                      : IconButton(
                          tooltip: 'Effacer la date',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () =>
                              setState(() => _purchase = null),
                        ),
                ),
                child: Text(
                    _purchase == null
                        ? 'Non renseignée'
                        : _dayLabel(_purchase!),
                    style: AppTextStyles.body),
              ),
            ),

            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
                label: 'Enregistrer',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: _save),
            ...[
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
                                  '${a.isStockMode ? 'Mode stock${a.stockThreshold > 0 ? ' · seuil ${a.stockThreshold}' : ''}' : 'Mode recette'}'
                                  ' · ${_stationLabel(a)}',
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

  bool _backfilling = false;

  /// Régularise les fournitures achetées avant que le formulaire n'écrive
  /// leur dépense. Même geste que pour les ingrédients, et même garde-fou :
  /// la liste ne retient que celles SANS dépense rattachée, donc relancer
  /// l'opération ne double aucun montant.
  Future<void> _backfill() async {
    final pending = StockItemService.withoutRecordedPurchase(widget.shopId);
    if (pending.isEmpty) return;
    final total = pending.fold<int>(
        0, (s, i) => s + StockItemService.backfillAmountFor(i));

    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.receipt_long_outlined,
      iconColor: Theme.of(context).colorScheme.primary,
      title: 'Enregistrer les achats manquants ?',
      body: Text(
          '${pending.length} fourniture(s) ont un coût mais aucun achat '
          'enregistré. ${CurrencyFormatter.format(total.toDouble())} seront '
          'ajoutés aux dépenses, en catégorie « Autre » et à la date de '
          'création de chaque article.\n\n'
          'Ces écritures sont marquées hors espèces : elles ne toucheront '
          'pas votre clôture de caisse.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Enregistrer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;

    setState(() => _backfilling = true);
    final r = await StockItemService.recordMissingPurchases(widget.shopId);
    if (!mounted) return;
    setState(() => _backfilling = false);
    AppSnack.success(
        context,
        '${r.count} achat(s) enregistré(s) — '
        '${CurrencyFormatter.format(r.total.toDouble())}');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final items = StockItemService.forShop(widget.shopId);
    // Fournitures dont l'achat n'a jamais été enregistré en dépense — leur
    // montant n'apparaît donc ni dans les charges, ni dans le bénéfice.
    final pending = StockItemService.withoutRecordedPurchase(widget.shopId);
    return Column(
      children: [
        if (pending.isNotEmpty)
          _BackfillBanner(
            count: pending.length,
            total: pending.fold<int>(
                0, (s, i) => s + StockItemService.backfillAmountFor(i)),
            busy: _backfilling,
            onRun: _backfill,
            label: 'fourniture',
          ),
        // Orientation explicite : c'est LA confusion du module. Une boisson
        // saisie ici ne se décrémenterait jamais à la vente, et son stock
        // divergerait dès le premier service.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
              'Ce que vous consommez sans le revendre : emballages, gaz, '
              'entretien, charbon. Pour une boisson revendue telle quelle, '
              'créez plutôt un plat avec « Suivi du stock » — il se décrémente '
              'tout seul à chaque vente.',
              style: AppTextStyles.captionHint),
        ),
        headerButton('Fourniture', () => _edit(null)),
        Expanded(
          child: items.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: 'Aucune fourniture',
                  subtitle: 'Emballages, gaz, produits d\'entretien… tout ce '
                      'qui se consomme sans être revendu.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final s = items[i];
                    // Carte INERTE : elle ouvrait l'éditeur, ce qui faisait
                    // basculer vers un formulaire chaque fois qu'on visait la
                    // réception et qu'on la manquait de quelques pixels.
                    return _Card(
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
                        // Réception · Modifier · Supprimer — du geste le plus
                        // fréquent au plus rare, le destructif en bout de
                        // rangée.
                        IconButton(
                          onPressed: () => _receive(s),
                          tooltip: 'Réception',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.add_box_outlined,
                              size: 20, color: cs.primary),
                        ),
                        IconButton(
                          onPressed: () => _edit(s),
                          tooltip: 'Modifier',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.edit_outlined,
                              size: 19,
                              color: cs.onSurface.withValues(alpha: 0.7)),
                        ),
                        IconButton(
                          onPressed: () => _delete(s),
                          tooltip: 'Supprimer',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.delete_outline_rounded,
                              size: 19, color: sem.danger),
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
    // Réapprovisionner, c'est acheter : la dépense suit, valorisée au coût
    // unitaire connu de l'article. Sans elle, un réassort hebdomadaire de
    // barquettes n'apparaissait nulle part dans les comptes — même trou que
    // sur la création, et plus insidieux parce qu'il se répète.
    final spent = (s.costPerUnit * amount).round();
    if (spent > 0) {
      await DailyExpenseService.record(
        shopId: widget.shopId,
        description: '${s.name} — ${_fmt(amount)} ${s.unit}',
        amount: spent,
        kind: ExpenseKind.autre,
        date: DateTime.now(),
        ingredientId: s.id,
      );
    }
    if (mounted) setState(() {});
  }

  /// Suppression depuis la liste — même confirmation que depuis l'éditeur :
  /// c'est la MÊME action, elle ne doit pas être plus légère parce qu'elle est
  /// plus accessible.
  Future<void> _delete(StockItem s) async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette fourniture ?',
      body: Text('« ${s.name} » sera retirée de votre réserve. Son stock et '
          'sa valeur ne compteront plus dans vos inventaires.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await StockItemService.delete(s.id, widget.shopId);
    if (mounted) setState(() {});
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
      final created = await StockItemService.create(
        shopId: widget.shopId,
        name: name,
        unit: unit,
        quantity: stock,
        minQuantity: min,
        costPerUnit: cost,
        sellingPrice: price,
        activityId: _activityId,
      );
      // LA DÉPENSE CORRESPONDANTE — elle manquait.
      //
      // Acheter du gaz, des barquettes ou du charbon sort de l'argent de la
      // caisse. Sans cette écriture, ce montant n'existait nulle part : ni
      // dans l'onglet Dépenses, ni dans le bénéfice, ni dans le P&L. Les
      // ingrédients écrivaient déjà la leur ; les fournitures, non — d'où
      // l'impression, justifiée, que cet onglet doublonne Dépenses sans rien
      // apporter aux comptes.
      //
      // Catégorie `autre`, PAS `achatMarche` : le food cost ne compte que la
      // matière première. Y verser le gaz et l'eau de javel gonflerait un
      // ratio qui sert précisément à juger la carte. Et pas une nouvelle
      // catégorie « fourniture » non plus — la colonne `kind` est susceptible
      // de porter une contrainte CHECK en base, et une clé inconnue ferait
      // rejeter l'écriture puis disparaître la ligne à la synchronisation.
      // `autre` compte comme charge d'exploitation, c'est ce qu'on veut.
      //
      // Seulement à la CRÉATION : une modification corrige une fiche, elle ne
      // rachète rien. Sans ça, chaque correction de prix créerait une dépense.
      final spent = (cost * (stock <= 0 ? 1 : stock)).round();
      if (spent > 0) {
        await DailyExpenseService.record(
          shopId: widget.shopId,
          description: stock > 0 ? '$name — ${_fmt(stock)} $unit' : name,
          amount: spent,
          kind: ExpenseKind.autre,
          date: DateTime.now(),
          // LIEN vers la fourniture — c'est lui qui rend la régularisation
          // idempotente : sans lui, la bannière reproposerait éternellement
          // cet article et doublerait son montant à chaque passage.
          ingredientId: created.id,
        );
      }
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
//  Onglet DÉPENSES DU JOUR (Lot E — achats marché, gaz, entretien…)
// ═══════════════════════════════════════════════════════════════════════
class _DailyExpensesTab extends StatefulWidget {
  final String shopId;
  const _DailyExpensesTab({required this.shopId});
  @override
  State<_DailyExpensesTab> createState() => _DailyExpensesTabState();
}

class _DailyExpensesTabState extends _TabState<_DailyExpensesTab> {
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
              child: _MiniStat(
                label: 'Achats matières',
                value: CurrencyFormatter.format(food.toDouble()),
                color: cs.primary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MiniStat(
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
                    return _Card(
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
                                    _dayLabel(e.expenseDate),
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
            _numField(_amount, 'Montant'),
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
                    onSelected: (_) => setState(() => _kind = k),
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
              title: Text(_dayLabel(_date), style: AppTextStyles.bodySm),
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
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
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

/// Petit indicateur chiffré (en-tête d'onglet).
class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _MiniStat(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: restoGlassFill(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.captionHint),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyBold.copyWith(color: color)),
        ],
      ),
    );
  }
}
// L'onglet « Consignes » a été SUPPRIMÉ (2026-08-05) : l'établissement ne
// prête aucun contenant. Le service `BottleDepositService` et la table
// `bottle_deposits` subsistent, inertes — rien n'écrit plus de consigne, et
// rétablir l'onglet ne demanderait que de recréer cet écran.
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

/// Unités proposées pour un ingrédient — volontairement courte et concrète :
/// ce qu'un cuisinier achète réellement. Une unité déjà en base qui n'y figure
/// pas est conservée et ajoutée à la liste par l'éditeur.
/// Unité INCONNUE — le cas le plus fréquent à la saisie rapide : on connaît
/// le nom et ce qu'on a payé, pas le conditionnement. Stockée comme chaîne
/// vide sur l'ingrédient ; c'est cette sentinelle qui la représente dans la
/// liste déroulante, où une entrée vide serait invisible.
const String _kUnitUnknown = 'non précisée';

const List<String> _kIngredientUnits = [
  _kUnitUnknown,
  'g', 'kg', 'mL', 'L',
  'pièce', 'sachet', 'paquet', 'boîte',
  // Le casier et la bouteille sont les unités d'achat réelles des boissons
  // (spec Lot B) : une brasserie livre au casier, le bar vend à la bouteille.
  'bouteille', 'casier',
  'carton', 'sac', 'bidon', 'seau', 'botte', 'tas',
];

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

  /// `null` = carte INERTE, sans effet au toucher.
  ///
  /// Une carte qui ouvre un formulaire au moindre contact déclenche des
  /// modifications non voulues quand on vise un bouton et qu'on le manque.
  /// Les listes dont chaque action a son propre bouton n'en passent donc pas.
  final VoidCallback? onTap;

  /// Bordure d'accentuation — sert à signaler une ligne qui demande
  /// l'attention. `null` = bordure discrète habituelle.
  final Color? borderColor;

  /// Teinte de fond superposée au verre. Volontairement séparée de
  /// [borderColor] : une bordure seule passe inaperçue dans une longue liste,
  /// un fond seul ne dit pas où s'arrête la ligne.
  final Color? background;

  const _Card({
    required this.child,
    this.onTap,
    this.borderColor,
    this.background,
  });
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Material(
      color: background ?? restoGlassFill(context),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: borderColor ?? sem.borderSubtle,
                width: borderColor == null ? 1 : 1.5),
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

/// Ce qu'une réception d'ingrédient produit.
class _ReceiptResult {
  /// Quantité entrée en stock, dans l'unité de l'ingrédient.
  final double quantity;

  /// Montant payé (FCFA). 0 = don, prélèvement sur un autre stock, ou montant
  /// inconnu — la quantité entre quand même, mais rien ne sera imputé aux plats.
  final int amount;

  final DateTime date;

  const _ReceiptResult(this.quantity, this.amount, this.date);
}

/// RÉCEPTION D'UN INGRÉDIENT : ce qui entre en réserve, et ce que ça a coûté.
///
/// Les deux vont ensemble et se saisissent ensemble. C'est LE geste qui
/// alimente tout le calcul de marge : le montant payé, rattaché à cet
/// ingrédient, est ce que la répartition imputera aux plats qui le contiennent.
/// Séparer les deux saisies (« j'ajoute 3 kg » ici, « j'ai payé 21 000 F »
/// ailleurs) garantissait que la seconde serait oubliée.
class _IngredientReceiptSheet extends StatefulWidget {
  final Ingredient ingredient;
  const _IngredientReceiptSheet({required this.ingredient});
  @override
  State<_IngredientReceiptSheet> createState() =>
      _IngredientReceiptSheetState();
}

class _IngredientReceiptSheetState extends State<_IngredientReceiptSheet> {
  final _qtyCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  DateTime _date = DateTime.now();
  String? _err;

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  double get _qty =>
      double.tryParse(_qtyCtrl.text.trim().replaceAll(',', '.')) ?? 0;

  int get _amount => int.tryParse(_amountCtrl.text.trim()) ?? 0;

  /// Coût unitaire de CETTE réception — un repère de vraisemblance : un prix
  /// au kilo dix fois trop élevé se voit ici, pas dans le total.
  double? get _unitCost => (_qty > 0 && _amount > 0) ? _amount / _qty : null;

  /// Coût moyen du stock APRÈS cette réception — la valeur qui sera écrite.
  int? get _newUnitCost => (_qty <= 0 || _amount <= 0)
      ? null
      : IngredientService.weightedUnitCost(
          currentQty: widget.ingredient.quantity,
          currentUnitCost: widget.ingredient.costPerUnit,
          receivedQty: _qty,
          amountPaid: _amount,
        );

  void _submit() {
    if (_qty <= 0) {
      setState(() => _err = 'Quantité invalide');
      return;
    }
    Navigator.of(context).pop(_ReceiptResult(_qty, _amount, _date));
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final ing = widget.ingredient;
    return AdaptiveFormFrame(
      title: 'Réception — ${ing.name}',
      icon: Icons.add_box_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _qtyCtrl,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  onChanged: (_) => setState(() => _err = null),
                  decoration: InputDecoration(
                      labelText: 'Quantité reçue', suffixText: ing.unit),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _amountCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() {}),
                  decoration:
                      const InputDecoration(labelText: 'Montant payé (F)'),
                ),
              ),
            ]),
            if (_unitCost != null) ...[
              const SizedBox(height: 6),
              Text('soit ${_unitCost!.round()} F / ${ing.unit} sur cet achat',
                  style: AppTextStyles.caption),
            ],
            // Nouveau coût unitaire après moyenne avec le stock existant.
            // Affiché AVANT validation : c'est cette valeur qui chiffrera vos
            // pertes d'inventaire, elle ne doit pas changer à votre insu.
            if (_newUnitCost != null && _newUnitCost != ing.costPerUnit) ...[
              const SizedBox(height: 2),
              Text(
                  'Coût moyen du stock : ${ing.costPerUnit} → '
                  '$_newUnitCost F / ${ing.unit}',
                  style: AppTextStyles.caption
                      .copyWith(color: Theme.of(context).colorScheme.primary)),
            ],
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(_dayLabel(_date), style: AppTextStyles.bodySm),
              trailing: const Text('Modifier'),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime.now().subtract(const Duration(days: 365)),
                  lastDate: DateTime.now(),
                );
                if (picked != null && mounted) setState(() => _date = picked);
              },
            ),
            Text(
                _amount > 0
                    ? 'Une dépense sera enregistrée et rattachée à cet '
                        'ingrédient : c\'est elle qui donnera son coût aux '
                        'plats qui le contiennent.'
                    : 'Sans montant, la quantité entre en stock mais aucun '
                        'coût ne sera imputé aux plats.',
                style: AppTextStyles.captionHint),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Enregistrer la réception',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bandeau de régularisation des achats non enregistrés.
///
/// Il n'apparaît que s'il y a réellement quelque chose à rattraper, et il
/// disparaît de lui-même une fois le travail fait. Il existe parce qu'un achat
/// jamais enregistré est de l'argent sorti que l'application ignore : un
/// ingrédient sans achat rend GRATUITS les plats qui le contiennent, une
/// fourniture sans achat disparaît des charges. Dans les deux cas le bénéfice
/// affiché est flatteur et faux, sans que rien à l'écran ne le signale.
///
/// [label] adapte le mot compté — le bandeau sert les deux onglets.
/// Choix de la MÉTHODE DE COÛT MATIÈRES de la boutique.
///
/// Les deux méthodes sont exclusives — on en active une. Le sélecteur affiche
/// en clair ce que chacune implique, parce que basculer change tous les
/// chiffres de marge de l'établissement : ce n'est pas une préférence
/// d'affichage.
class _CostMethodSelector extends StatelessWidget {
  final String shopId;
  final VoidCallback onChanged;

  const _CostMethodSelector({required this.shopId, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final current = DishCostSettings.forShop(shopId);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.calculate_outlined,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text('Méthode de calcul du coût matières',
                style: AppTextStyles.captionBold),
          ]),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final m in DishCostMethod.values) ...[
                Expanded(
                  child: _MethodChip(
                    label: m.label,
                    selected: m == current,
                    onTap: () async {
                      if (m == current) return;
                      await DishCostSettings.setForShop(shopId, m);
                      onChanged();
                    },
                  ),
                ),
                if (m != DishCostMethod.values.last)
                  const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(current.description, style: AppTextStyles.captionHint),
          const SizedBox(height: 6),
          // Le réglage vit dans la box `settings`, attachée à l'appareil.
          // Le taire ferait chercher longtemps pourquoi la tablette du passe
          // n'affiche pas les mêmes marges que le poste du gérant.
          Text(
              'Réglage propre à cet appareil : à répéter sur chaque poste de '
              'la boutique.',
              style: AppTextStyles.micro),
        ],
      ),
    );
  }
}

class _MethodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MethodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    return Material(
      color: selected ? theme.colorScheme.primary : sem.trackMuted,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: selected
                    ? theme.colorScheme.primary
                    : sem.borderSubtle),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySmBold.copyWith(
                color: selected
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}

class _BackfillBanner extends StatelessWidget {
  final int count;
  final int total;
  final bool busy;
  final VoidCallback onRun;
  final String label;

  const _BackfillBanner({
    required this.count,
    required this.total,
    required this.busy,
    required this.onRun,
    this.label = 'ingrédient',
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: sem.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.info_outline_rounded, size: 18, color: sem.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text('$count $label(s) sans achat enregistré',
                  style: AppTextStyles.bodySmBold
                      .copyWith(color: cs.onSurface)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
              'Ils ont du stock, mais aucune dépense ne leur est rattachée : '
              'les plats qui les contiennent affichent donc 0 F de coût '
              'matières. Enregistrer leurs achats '
              '(${CurrencyFormatter.format(total.toDouble())}) corrige vos '
              'marges.',
              style: AppTextStyles.caption),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : onRun,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.receipt_long_outlined, size: 18),
              label: Text(busy
                  ? 'Enregistrement…'
                  : 'Enregistrer les achats manquants'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            ),
          ),
        ],
      ),
    );
  }
}
