part of 'restaurant_stock_page.dart';

// L'onglet Fournitures et sa fiche.

// ═══════════════════════════════════════════════════════════════════════
//  Onglet ACTIVITÉS
// ═══════════════════════════════════════════════════════════════════════

class _StockItemsTab extends StatefulWidget {
  final String shopId;
  const _StockItemsTab({required this.shopId});
  @override
  State<_StockItemsTab> createState() => _StockItemsTabState();
}

class _StockItemsTabState extends RestoTabState<_StockItemsTab> {
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
          RestoBackfillBanner(
            count: pending.length,
            total: pending.fold<int>(
                0, (s, i) => s + StockItemService.backfillAmountFor(i)),
            busy: _backfilling,
            onRun: _backfill,
            label: 'fourniture',
          ),
        // LE PARAGRAPHE D'ORIENTATION QUI ÉTAIT ICI A DISPARU. Il répétait
        // l'état vide en dessous, avec une autre liste d'exemples. Son contenu
        // survit en deux morceaux : ce qu'est une fourniture, dans l'état vide
        // (`_SuppliesEmptyState`) ; le cas des boissons, en note — dans l'état
        // vide ET en pied de liste (`_DrinksNote`), pour qu'il ne disparaisse
        // pas au premier article saisi.
        // Le « Nouvelle fourniture » qui doublait ici le bouton d'en-tête a
        // disparu avec lui : le bouton flottant est la seule porte.
        Expanded(
          child: items.isEmpty
              ? _SuppliesEmptyState(
                  onCreate: () => _edit(null),
                  // OÙ SE FAIT L'ACHAT : on crée une fourniture ici, on
                  // l'achète au hub Finances. « Dépenses » est l'onglet
                  // d'index 0 du hub : la route seule y atterrit.
                  onOpenPurchases: () =>
                      context.push('/shop/${widget.shopId}/restaurant/finances'),
                )
              : ListView(
                  // En bas : la place du bouton flottant, toujours affiché sur
                  // une liste non vide (80 = 48 + 16 + 16).
                  padding: const EdgeInsets.fromLTRB(
                      16, 4, 16, kRestoFabClearance),
                  children: [
                    // Même panneau et mêmes lignes que les ingrédients — voir
                    // `_StockLines`. La note sur les boissons suit la liste.
                    _StockLines(children: [
                  for (final s in items)
                    // Ligne INERTE : elle ouvrait l'éditeur, ce qui faisait
                    // basculer vers un formulaire chaque fois qu'on visait la
                    // réception et qu'on la manquait de quelques pixels.
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
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
                                  const SizedBox(width: 8),
                                  RestoInlineTag.alert(
                                      'stock bas', sem.dangerText),
                                ],
                              ]),
                              Text(
                                  'Vente ${CurrencyFormatter.format(s.sellingPrice.toDouble())} · '
                                  'stock ${restoQty(s.quantity)} ${s.unit}'
                                  '${s.minQuantity > 0 ? ' · min ${restoQty(s.minQuantity)}' : ''}',
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
                          visualDensity: compactUnlessTouch,
                          icon: Icon(Icons.add_box_outlined,
                              size: 20, color: cs.primary),
                        ),
                        IconButton(
                          onPressed: () => _edit(s),
                          tooltip: 'Modifier',
                          visualDensity: compactUnlessTouch,
                          icon: Icon(Icons.edit_outlined,
                              size: 19,
                              color: cs.onSurface.withValues(alpha: 0.7)),
                        ),
                        IconButton(
                          onPressed: () => _delete(s),
                          tooltip: 'Supprimer',
                          visualDensity: compactUnlessTouch,
                          icon: Icon(Icons.delete_outline_rounded,
                              size: 19, color: sem.danger),
                        ),
                      ]),
                    ),
                    ]),
                    const SizedBox(height: 16),
                    const _DrinksNote(),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _receive(StockItem s) async {
    final amount =
        await restoAskAmount(context, 'Réception — ${s.name}', suffix: s.unit);
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
        description: '${s.name} — ${restoQty(amount)} ${s.unit}',
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

/// ÉTAT VIDE DE L'ONGLET FOURNITURES — sans carte, borné à 440 px à gauche.
///
/// ─── SECONDE EXCEPTION À LA RÈGLE DU 16/09 — CET ONGLET SEULEMENT ─────────
///
/// La règle : « un état vide est une CARTE, pas un texte flottant »
/// (`RestoEmptyState`, qui sert les écrans vides du module et n'est PAS
/// modifié). Elle a deux raisons, et elles ne tombent pas ensemble :
///
///   • la LISIBILITÉ du texte sur le décor — levée par la première exception
///     (24/09, `restoGlassFill`) : le décor géométrique est mesuré, primaire
///     ≥ 12,2:1, secondaire ≥ 5,2:1 ;
///   • la FORME : une icône seule devant un paragraphe se lit comme une PUCE
///     DE LISTE, et un texte seul au milieu du vide comme un écran qui n'a pas
///     fini de charger. Celle-ci demeure.
///
/// D'où ce qui reste ici : pas de carte, mais le CARRÉ D'ICÔNE de 34 px, qui
/// dit « état vide » avant que le texte soit lu. Et une largeur de lecture
/// (440 px, à gauche) plutôt qu'un paragraphe qui traverse 1 030 px.
///
/// Cette exception ne vaut QUE pour cet onglet (24/09/2026). Ne pas l'étendre
/// sans la même instruction : ailleurs, `RestoEmptyState` reste la règle.
///
/// Une seule explication : la phrase dit CE QUI DISTINGUE une fourniture d'un
/// ingrédient (section 1 de la définition financière) — une charge, jamais une
/// matière. Le bouton fait sa taille, et le renvoi vers les achats est un lien
/// à côté de lui, plus une ligne encadrée à part.
class _SuppliesEmptyState extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onOpenPurchases;

  const _SuppliesEmptyState({
    required this.onCreate,
    required this.onOpenPurchases,
  });

  /// Largeur de LECTURE, pas une taille typographique.
  static const double _kMaxWidth = 440;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kMaxWidth),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // LE CARRÉ RESTE : c'est lui qui évite la lecture « puce ».
                // Même carré que `RestoEmptyState` compact.
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.inventory_2_outlined,
                      size: 17, color: cs.primary),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Aucune fourniture',
                          style: AppTextStyles.bodyBold
                              .copyWith(color: cs.onSurface)),
                      const SizedBox(height: 3),
                      Text(
                          'Ce que vous consommez sans le servir — barquettes, '
                          'gaz, charbon, produits d\'entretien. Chaque achat '
                          'compte comme une charge, jamais comme une matière.',
                          style: AppTextStyles.caption
                              .copyWith(color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Aligné sous le TEXTE, pas sous le carré d'icône.
            Padding(
              padding: const EdgeInsets.only(left: 45),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // SA TAILLE, plus la pleine largeur : un bouton de 1 030 px
                  // pour un libellé de deux mots.
                  FilledButton.icon(
                    onPressed: onCreate,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Nouvelle fourniture'),
                    // Thème global : minimumSize infini.
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 40)),
                  ),
                  TextButton(
                    onPressed: onOpenPurchases,
                    child: const Text('Voir vos achats'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.only(left: 45),
              child: _DrinksNote(),
            ),
          ],
        ),
      ),
    );
  }
}

/// LE CAS DES BOISSONS, en note — c'est LA confusion du module.
///
/// Une boisson saisie en fourniture ne se décrémenterait jamais à la vente, et
/// son stock divergerait dès le premier service. Une précision, pas
/// l'explication principale : 11 px, sous un filet, après l'action.
///
/// DANS L'ÉTAT VIDE ET EN PIED DE LISTE : une note qui répond à la confusion
/// la plus fréquente ne peut pas disparaître au premier article saisi.
///
/// `textSecondary` et non `textHint` : ce dernier ne fait que 3,07:1 en sombre
/// (dette de palette, `docs/backlog.md`).
class _DrinksNote extends StatelessWidget {
  const _DrinksNote();

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1, thickness: 1, color: sem.borderSubtle),
        const SizedBox(height: 8),
        Text(
            'Pour une boisson revendue telle quelle, créez plutôt un plat avec '
            '« Suivi du stock » — il se décrémente tout seul à chaque vente.',
            style:
                AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
      ],
    );
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
      text: widget.existing == null ? '' : restoQty(widget.existing!.quantity));
  late final _min = TextEditingController(
      text: widget.existing == null ? '' : restoQty(widget.existing!.minQuantity));
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
          description: stock > 0 ? '$name — ${restoQty(stock)} $unit' : name,
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
              Expanded(child: restoNumField(_price, 'Prix vente (F)')),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: restoNumField(_stock, 'Stock', decimal: true)),
              const SizedBox(width: 10),
              Expanded(child: restoNumField(_min, 'Min', decimal: true)),
            ]),
            const SizedBox(height: 10),
            restoNumField(_cost, 'Coût d\'achat / unité (F)'),
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
