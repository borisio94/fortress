part of 'restaurant_stock_page.dart';

// L'onglet Ingrédients, sa fiche et la réception d'un achat.

class _IngredientsTab extends StatefulWidget {
  final String shopId;
  const _IngredientsTab({required this.shopId});
  @override
  State<_IngredientsTab> createState() => _IngredientsTabState();
}

class _IngredientsTabState extends RestoTabState<_IngredientsTab> {
  /// Crée un ingrédient depuis l'écran Stock.
  ///
  /// Délègue à la MÊME feuille que la fiche d'un plat : elle écrit
  /// l'ingrédient et, si un montant est saisi, la dépense d'achat qui va avec.
  /// La liste se rafraîchit par l'écoute de `ingredients`, comme toujours.
  Future<void> _createIngredient() => showAdaptiveFormSheet<Ingredient>(
        context: context,
        builder: (_) => IngredientQuickSheet(
          shopId: widget.shopId,
          // Depuis STOCK : rien n'oblige à rattacher l'ingrédient ensuite.
          warnsAboutUnlinked: true,
        ),
      );

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
    // Un seul passage sur les lignes de recette pour toute la liste. `null`
    // veut dire « illisible » et non « rien n'est rattaché » : dans ce cas
    // aucune ligne n'affiche l'avertissement.
    final linked = RecipeService.linkedIngredientIds(widget.shopId);
    // `null` veut dire « illisible » : dans ce cas on n'annonce RIEN plutôt
    // que d'annoncer zéro, qui se lirait comme « tout est rattaché ».
    final unlinkedCount = linked == null
        ? 0
        : items.where((i) => !linked.contains(i.id)).length;
    return Column(
      children: [
        if (pending.isNotEmpty) RestoBackfillBanner(
          count: pending.length,
          total: pending.fold<int>(
              0, (s, i) => s + IngredientService.backfillAmountFor(i)),
          busy: _backfilling,
          onRun: _backfill,
        ),
        // LA CRÉATION EST LE BOUTON FLOTTANT (24/09/2026).
        //
        // Elle a été une ligne entière ici jusqu'au 2026-09-23, entre les
        // onglets et la liste, puis un bouton d'en-tête, puis une case en pied
        // de liste — introuvable sur une longue liste. C'est désormais le
        // bouton flottant de la page (`RestoFab`), et le bouton de l'état vide
        // quand il n'y a rien à lister.
        Expanded(
          child: items.isEmpty
              // COMPACT : la barre d'onglets juste au-dessus porte déjà
              // « Ingrédients · 0 ». Une carte de 200 px répéterait ce qui est
              // écrit, et repousserait le bouton de création hors de vue.
              //
              // La phrase dit ce qu'on PEUT FAIRE, pas seulement ce qui
              // manque : les deux chemins de création sont nommés, celui d'ici
              // en premier puisque c'est l'écran où l'on est.
              ? RestoEmptyState(
                  compact: true,
                  icon: Icons.eco_outlined,
                  title: 'Aucun ingrédient',
                  // LA PHRASE DIT LA NOTION avant de dire le geste. « Aucun
                  // ingrédient » ne range pas les barquettes : un restaurateur
                  // doit savoir CE QUI va ici, sans quoi il mettra le gaz et
                  // les emballages dans la même liste que le poisson.
                  subtitle: 'Ce qui entre dans vos plats — poisson, huile, '
                      'riz, épices.',
                  actionLabel: 'Nouvel ingrédient',
                  onAction: _createIngredient,
                  // Le SECOND chemin, et il existe vraiment : composer la
                  // recette d'un plat crée l'ingrédient au passage. Le dire
                  // dans la phrase d'explication l'aurait répété sous le
                  // bouton qui porte le premier.
                  footnote: 'ou en composant la recette d\'un plat',
                )
              : ListView(
                  // En bas : la place du bouton flottant, toujours affiché sur
                  // une liste non vide (80 = 48 + 16 + 16).
                  padding: const EdgeInsets.fromLTRB(
                      16, 4, 16, kRestoFabClearance),
                  children: [
                    // ── « AUCUN PLAT » EN BANDEAU, PAS EN PASTILLE ──────
                    //
                    // La pastille était juste, et répétée seize fois elle ne
                    // disait plus rien : une liste dont chaque ligne porte le
                    // même avertissement n'avertit de rien. Le bandeau le dit
                    // UNE fois, avec le compte, et surtout avec un chemin —
                    // c'est la carte qu'il faut ouvrir pour rattacher un
                    // ingrédient à une recette.
                    //
                    // La ligne, elle, garde une mention en texte gris : sans
                    // quoi le bandeau annoncerait un nombre sans dire
                    // LESQUELS.
                    if (unlinkedCount > 0) ...[
                      _UnlinkedBanner(
                        count: unlinkedCount,
                        onOpenMenu: () =>
                            context.go('/shop/${widget.shopId}/inventaire'),
                      ),
                      const SizedBox(height: 4),
                    ],
                    _StockLines(children: [
                      for (final ing in items)
                        _IngredientRow(
                          ing: ing,
                          noCost: noCost.contains(ing.id),
                          unlinked: linked != null && !linked.contains(ing.id),
                          onReceive: () => _receive(ing),
                          onEdit: () => _edit(ing),
                          onDelete: () => _delete(ing),
                        ),
                    ]),
                  ],
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
        description: '${ing.name} — ${restoQty(r.quantity)} ${ing.unit}',
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

/// BANDEAU « AUCUN PLAT » — dit une fois ce que seize pastilles répétaient.
///
/// La pastille par ligne était juste et illisible : une liste dont chaque
/// ligne porte le même avertissement n'avertit de rien. Le bandeau donne le
/// COMPTE — ce que la pastille ne pouvait pas faire — et surtout un CHEMIN :
/// un ingrédient se rattache en composant la recette d'un plat, et c'est la
/// carte qu'il faut ouvrir.
///
/// Ambre et non rouge : rien n'est cassé. Ces ingrédients existent, ils ne
/// sont simplement dans aucune recette — et tant qu'ils n'ont pas d'achat
/// enregistré, ils ne faussent aucune marge. Le rouge est pris par le stock
/// bas, qui appelle une action dans la journée.
class _UnlinkedBanner extends StatelessWidget {
  final int count;
  final VoidCallback onOpenMenu;

  const _UnlinkedBanner({required this.count, required this.onOpenMenu});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    // SANS CADRE : icône, texte, lien. Le fond teinté et la bordure ambre en
    // faisaient un rectangle de plus au-dessus d'une liste qui n'en a plus ;
    // la couleur du texte suffit à dire que c'est une alerte.
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 0, 4),
      child: Row(children: [
        Icon(Icons.link_off_rounded, size: 18, color: sem.warningText),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
              count == 1
                  ? '1 ingrédient n\'entre dans aucun plat.'
                  : '$count ingrédients n\'entrent dans aucun plat.',
              style: AppTextStyles.bodySm
                  .copyWith(color: sem.warningText)),
        ),
        TextButton(
          onPressed: onOpenMenu,
          style: TextButton.styleFrom(
              foregroundColor: sem.warningText,
              visualDensity: VisualDensity.compact),
          child: const Text('Voir la carte'),
        ),
      ]),
    );
  }
}

/// Une ligne d'ingrédient : trois boutons explicites, et une ligne INERTE.
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

  /// AUCUNE RECETTE ne le reprend — c'est un ingrédient oublié.
  ///
  /// Le créer depuis cet écran est possible depuis le 21/09/2026, et rien
  /// n'oblige à le rattacher ensuite. La pastille aide à finir le travail.
  final bool unlinked;

  final VoidCallback onReceive;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _IngredientRow({
    required this.ing,
    required this.onReceive,
    required this.onEdit,
    required this.onDelete,
    this.noCost = false,
    this.unlinked = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final q = restoQty(ing.quantity);
    // UNE LIGNE, PLUS UNE CARTE : ni fond ni bordure, le panneau commun
    // (`_StockLines`) et son filet font la séparation.
    //
    // Le « coût manquant » perd son cadre ambre et son fond teinté : il reste
    // dit par son libellé et sa phrase d'explication, en `warningText`. Un
    // signal plus faible, mais honnête — accepté le 24/09/2026.
    //
    // 8 px de marge verticale : ce sont les boutons (40 px en densité
    // compacte) qui fixent la hauteur de la ligne, et 8 + 40 + 8 donne les
    // ~56 px visés. À 14, la ligne en ferait 68 — plus haute que la carte
    // qu'elle remplace.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
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
                // MÉTHODE DE CHIFFRAGE — SEULE L'EXCEPTION SE DIT.
                //
                // La pastille s'affichait sur CHAQUE ligne, et la répartition
                // étant le défaut, elle répétait « Sans peser » quinze fois
                // sur seize. Une information portée par presque toutes les
                // lignes ne distingue plus rien : elle occupe la place et
                // repousse celles qui, elles, appellent une action.
                //
                // Le défaut se tait, l'exception parle. C'est la règle du
                // module — le plat retiré, le stock bas et le coût manquant
                // fonctionnent déjà ainsi.
                //
                // EN TEXTE, plus en pastilles — voir `RestoInlineTag` : les
                // informations (« Quantité connue », « partagé ») passent en
                // gris, seules les alertes gardent leur couleur, dans sa
                // variante texte.
                if (ing.usesTechnicalSheet) ...[
                  const SizedBox(width: 8),
                  RestoInlineTag.info(ing.costMethodLabel),
                ],
                if (ing.isShared) ...[
                  const SizedBox(width: 8),
                  const RestoInlineTag.info('partagé'),
                ],
                if (ing.isLowStock) ...[
                  const SizedBox(width: 8),
                  RestoInlineTag.alert('stock bas', sem.dangerText),
                ],
                if (noCost) ...[
                  const SizedBox(width: 8),
                  RestoInlineTag.alert('coût manquant', sem.warningText),
                ],
                // « AUCUN PLAT » N'EST PLUS UNE PASTILLE — voir le bandeau en
                // tête de liste. Il reste en texte gris sous la ligne, pour
                // que le compte annoncé là-haut désigne des lignes précises.
              ]),
              Text(
                  // LE PRIX N'EST PLUS ICI : il est devenu l'ancre de droite.
                  // Noyé en tête d'une ligne de méta jointe par des points
                  // médians, il ne se comparait pas d'une ligne à l'autre —
                  // et c'est pourtant le chiffre qu'on vient lire.
                  //
                  // Unité et quantité restent FACULTATIVES : un ingrédient
                  // saisi au nom et au prix afficherait sinon « stock 0 », une
                  // ligne de bruit qui laisse croire à une donnée perdue.
                  [
                    if (ing.quantity > 0)
                      'stock $q ${ing.unit}'.trim(),
                    if (ing.alertThreshold > 0)
                      'seuil ${restoQty(ing.alertThreshold)}',
                    if (ing.purchaseDate != null)
                      'acheté le ${restoDayLabel(ing.purchaseDate!)}',
                  ].join(' · '),
                  style: AppTextStyles.caption),
              // La mention que la pastille portait. En gris et sur sa propre
              // ligne : elle nomme la ligne sans réclamer l'attention que le
              // bandeau a déjà prise une fois pour toutes.
              if (unlinked)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('Aucun plat ne l\'utilise',
                      style: AppTextStyles.caption
                          .copyWith(color: cs.onSurfaceVariant)),
                ),
              // Une couleur seule laisse deviner ; on dit ce qui manque et où
              // le corriger. Sans cette ligne, l'orange n'est qu'une énigme.
              if (noCost)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                      'Aucun achat enregistré — les plats qui le contiennent '
                      'paraissent plus rentables qu\'ils ne le sont. '
                      'Utilisez Réception pour saisir quantité et montant.',
                      // `warningText` et non `warning` : la phrase a perdu le
                      // fond teinté qui la portait (`warning` : 2,15:1 sur
                      // blanc).
                      style: AppTextStyles.caption
                          .copyWith(color: sem.warningText)),
                ),
            ],
          ),
        ),
        // ── LE PRIX, ANCRE DE LA COLONNE DE DROITE ──────────────────
        //
        // Aligné à droite, l'unité en petit dessous. La liste se parcourt par
        // cette colonne : vingt prix alignés se comparent d'un regard.
        //
        // EN TEXTE PRIMAIRE, plus en accent : seize prix ambre faisaient de
        // l'écran un mur orange, et l'ambre redevient disponible pour ce qui
        // compte (les alertes). `subtitle` (16) semi-gras, « FCFA » à 11 par
        // `RestoAmountText` — la même taille d'unité que Commandes et le Menu.
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            RestoAmountText(ing.costPerUnit.toDouble(),
                style: AppTextStyles.subtitle.copyWith(
                    fontWeight: FontWeight.w600, color: cs.onSurface)),
            // `textSecondary` et non `textHint` : ce dernier ne fait que
            // 3,07:1 en sombre (dette de palette, `docs/backlog.md`).
            if (ing.unit.trim().isNotEmpty)
              Text('par ${ing.unit.trim()}',
                  maxLines: 1,
                  style: AppTextStyles.micro
                      .copyWith(color: AppColors.textSecondary)),
          ],
        ),
        const SizedBox(width: 4),
        // ── UNE SEULE ACTION VISIBLE ────────────────────────────────
        //
        // Réapprovisionner reste : c'est le geste du quotidien, celui pour
        // lequel on ouvre cet écran. Modifier et supprimer descendent dans le
        // menu — non parce qu'ils sont rares, mais parce que la corbeille
        // était COLLÉE au crayon, à deux pixels l'un de l'autre, et qu'on les
        // vise du pouce sur un téléphone.
        IconButton(
          onPressed: onReceive,
          tooltip: 'Réapprovisionner',
          visualDensity: compactUnlessTouch,
          icon: Icon(Icons.add_box_outlined, size: 20, color: cs.primary),
        ),
        PopupMenuButton<String>(
          tooltip: 'Plus',
          icon: Icon(Icons.more_vert_rounded,
              size: 19, color: cs.onSurface.withValues(alpha: 0.7)),
          onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Modifier')),
            PopupMenuItem(
                value: 'delete',
                child: Text('Supprimer',
                    style: TextStyle(color: sem.dangerText))),
          ],
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

  /// Méthode de chiffrage — MODIFIABLE ici.
  ///
  /// Elle n'était réglable qu'à la création : on découvre pourtant après coup
  /// qu'on pèse finalement son riz, ou qu'on ne pèsera jamais son piment.
  /// Sans ce champ, la seule issue était de supprimer l'ingrédient et de le
  /// recréer — en perdant son historique d'achats.
  late String _costMethod = widget.existing.costMethod;

  bool get _qtyRequired => _costMethod == Ingredient.costSheet;

  /// Quantité achetée — c'est aussi le stock de l'ingrédient.
  late final _qty = TextEditingController(
      text: restoQty(widget.existing.quantity));

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
    // Basculer en fiche technique sans quantité rendrait le coût unitaire
    // absurde : il se déduit du montant DIVISÉ par la quantité, et sans
    // diviseur c'est le total du reçu qui serait multiplié par les grammes de
    // la recette. Même refus qu'à la création.
    if (_qtyRequired && _qtyValue <= 0) {
      setState(() => _err =
          '« Quantité connue » exige une quantité : le coût unitaire se '
          'déduit du montant divisé par elle.');
      return;
    }
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
        costMethod: _costMethod,
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
            // Même ordre qu'à la création : la méthode d'abord, puisqu'elle
            // décide de ce qui est exigé en dessous.
            CostMethodPicker(
              value: _costMethod,
              onChanged: (m) => setState(() {
                _costMethod = m;
                _err = null;
              }),
            ),
            const SizedBox(height: 14),
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
                        : restoDayLabel(_purchase!),
                    style: AppTextStyles.body),
              ),
            ),

            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
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
//  Onglet CHARGES FIXES
// ═══════════════════════════════════════════════════════════════════════

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
                      .copyWith(color: Theme.of(context).colorScheme.onSurface)),
            ],
            const SizedBox(height: 10),
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
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
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
