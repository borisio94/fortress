part of 'finances_hub_page.dart';

// L'onglet Pertes.

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
