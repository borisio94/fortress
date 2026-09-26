part of 'finances_hub_page.dart';

// L'onglet Dépenses.

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
