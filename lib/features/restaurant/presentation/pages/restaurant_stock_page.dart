import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_service.dart';
import '../../../../core/services/daily_expense_service.dart';
import '../../../../core/services/ingredient_service.dart';
import '../../../../core/services/recipe_service.dart';
import '../../../../core/services/stock_item_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/entities/daily_expense.dart';
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/stock_item.dart';
import '../widgets/cost_method_picker.dart';
import '../widgets/ingredient_quick_sheet.dart';
import '../widgets/resto_empty_state.dart' show RestoEmptyState;
import '../widgets/resto_pill_tabs.dart';
import '../widgets/resto_section_header.dart';
import '../widgets/resto_tab_kit.dart';

/// LE STOCK DU RESTAURANT — ce qu'on achète, ce qu'on consomme.
///
/// Sorti du hub Finances le 21/09/2026. Trois de ses six onglets n'étaient pas
/// financiers, et le premier d'entre eux — Ingrédients — s'ouvrait par défaut :
/// un écran de réserve accueillait quiconque cliquait sur « Finances ».
///
/// DEUX MATIÈRES, DEUX ONGLETS. Les ingrédients entrent dans les plats et leur
/// coût se répartit sur les ventes ; les fournitures se consomment sans entrer
/// dans aucune recette. Le calcul les sépare depuis l'origine, l'écran le dit
/// maintenant.
///
/// La RÉCEPTION d'un ingrédient reste une feuille ouverte depuis sa ligne, et
/// non un onglet : quantité entrée et montant payé se saisissent ensemble,
/// sinon le second est oublié.
class RestaurantStockPage extends StatefulWidget {
  final String shopId;
  const RestaurantStockPage({super.key, required this.shopId});

  @override
  State<RestaurantStockPage> createState() => _RestaurantStockPageState();
}

class _RestaurantStockPageState extends State<RestaurantStockPage> {
  int _tab = 0;

  late final OnDataChanged _listener;

  @override
  void initState() {
    super.initState();
    // Les compteurs de l'en-tête et des pastilles vivent ICI, au-dessus des
    // onglets : ils doivent bouger quand une ligne est créée dans l'un d'eux,
    // alors que chaque onglet n'écoute que sa propre table.
    _listener = (t, sid) {
      if (!mounted) return;
      if (t != 'ingredients' && t != 'stock_items') return;
      if (sid != widget.shopId && sid != '_all') return;
      setState(() {});
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
    final shopId = widget.shopId;
    final sem = Theme.of(context).semantic;
    final nIng = IngredientService.forShop(shopId).length;
    final nSup = StockItemService.forShop(shopId).length;

    return AppScaffold(
      shopId: shopId,
      title: 'Stock',
      isRootPage: false,
      actions: [
        IconButton(
          tooltip: 'Inventaire',
          icon: const Icon(Icons.fact_check_outlined),
          onPressed: () =>
              context.push('/shop/$shopId/restaurant/inventory/reconcile'),
        ),
      ],
      body: Column(
        children: [
          RestoSectionHeader(
            title: 'Stock',
            subtitle: '${_count(nIng, zero: 'aucun ingrédient', one: 'ingrédient')}'
                ' · '
                '${_count(nSup, zero: 'aucune fourniture', one: 'fourniture')}',
          ),
          // DEUX NATURES, DEUX SIGNAUX : une icône et une couleur.
          //
          // L'ICÔNE D'ABORD, parce que la couleur seule ne tient pas partout.
          // Mesuré en ΔE76 (Lab) entre l'ambre sémantique et l'accent de
          // chaque palette : 145 sur Violet Fortress, mais **17,7 sur la
          // palette Amber en mode clair** — deux oranges voisins, où les deux
          // onglets deviendraient difficiles à distinguer. L'icône ne dépend
          // d'aucune palette, d'aucun mode, et sert aussi qui distingue mal
          // les couleurs.
          //
          // Ce sont celles des états vides : la feuille pour ce qui entre dans
          // les plats, le carton pour ce qui se consomme sans être servi. Un
          // écran qui change de pictogramme entre sa liste vide et ses onglets
          // ferait douter qu'il parle de la même chose.
          //
          // LA COULEUR RESTE, en renfort. Aucune teinte en dur : `warning` et
          // `primary` suivent les huit palettes, en clair comme en sombre. Sur
          // la palette par défaut — Violet Fortress — l'accent EST le violet.
          RestoPillTabs(
            items: [
              RestoPillTab(
                  label: 'Ingrédients',
                  count: nIng,
                  color: sem.warning,
                  icon: Icons.eco_outlined),
              RestoPillTab(
                  label: 'Fournitures',
                  count: nSup,
                  icon: Icons.inventory_2_outlined),
            ],
            selected: _tab,
            onSelect: (i) => setState(() => _tab = i),
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                _IngredientsTab(shopId: shopId),
                _StockItemsTab(shopId: shopId),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// « aucun ingrédient », « 1 ingrédient », « 4 ingrédients ».
  ///
  /// LE ZÉRO S'ÉCRIT EN TOUTES LETTRES, et il a un genre : « 0 ingrédient »
  /// se lit comme une mesure ratée, « aucun ingrédient » comme un état. Et le
  /// genre n'est pas dérivable du mot — c'est l'appelant qui le donne, parce
  /// qu'aucune règle mécanique ne distingue « aucun ingrédient » d'« aucune
  /// fourniture ».
  static String _count(int n, {required String zero, required String one}) =>
      n == 0
          ? zero
          : n == 1
              ? '1 $one'
              : '$n ${one}s';
}

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
    return Column(
      children: [
        if (pending.isNotEmpty) RestoBackfillBanner(
          count: pending.length,
          total: pending.fold<int>(
              0, (s, i) => s + IngredientService.backfillAmountFor(i)),
          busy: _backfilling,
          onRun: _backfill,
        ),
        // UN BOUTON « Ingrédient » ICI, et c'est un revirement assumé.
        //
        // Cet écran n'en portait pas, à dessein : un ingrédient existe parce
        // qu'un plat le contient, et le créer hors de toute recette produit
        // des lignes orphelines. Le raisonnement tenait tant que cet onglet
        // vivait dans « Finances », où l'on vient lire des marges.
        //
        // Il ne tient plus sur un écran qui s'appelle STOCK. Un gérant qui
        // veut inscrire l'huile rouge dans sa réserve devait ouvrir un plat,
        // composer une recette, et créer l'ingrédient au passage — un détour
        // que rien à l'écran n'annonçait, et que l'état vide énonçait comme
        // une règle plutôt que comme un chemin.
        //
        // La feuille ouverte est CELLE de la fiche plat (`IngredientQuickSheet`,
        // extraite le 21/09/2026) : mêmes champs, même écriture de la dépense
        // d'achat. Deux formulaires auraient divergé.
        // Le bouton n'est ici QUE si la liste existe. Vide, l'action descend
        // dans l'état vide, sous la phrase qui la promet.
        if (items.isNotEmpty) headerButton('Ingrédient', _createIngredient),
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
                      'riz, épices. Créez-en un ici, ou en composant la '
                      'recette d\'un plat.',
                  actionLabel: 'Ingrédient',
                  onAction: _createIngredient,
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _IngredientRow(
                    ing: items[i],
                    noCost: noCost.contains(items[i].id),
                    unlinked:
                        linked != null && !linked.contains(items[i].id),
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
    return RestoCard(
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
                // Méthode de chiffrage — l'information la plus structurante
                // de la ligne : elle dit si cet ingrédient se pèse ou se
                // répartit, donc ce qu'on attend de l'utilisateur dans les
                // fiches recette.
                const SizedBox(width: 6),
                RestoPill(ing.costMethodLabel,
                    ing.usesTechnicalSheet ? cs.primary : sem.warning),
                if (ing.isShared) ...[
                  const SizedBox(width: 6),
                  RestoPill('partagé', cs.primary),
                ],
                if (ing.isLowStock) ...[
                  const SizedBox(width: 6),
                  RestoPill('stock bas', sem.danger),
                ],
                if (noCost) ...[
                  const SizedBox(width: 6),
                  RestoPill('coût manquant', sem.warning),
                ],
                // AUCUN PLAT — deux niveaux, parce que les deux situations ne
                // demandent pas la même urgence.
                //
                // Sans achat, c'est une information : l'ingrédient existe, il
                // ne sert encore à rien, et il ne coûte rien à personne.
                //
                // AVEC des achats, c'est un avertissement : son montant entre
                // dans l'assiette à répartir et n'en sort par aucun plat — il
                // grossit les « achats non rattachés » de l'écart du tableau
                // de bord (cf. lot 8 des marges).
                if (unlinked) ...[
                  const SizedBox(width: 6),
                  RestoPill('aucun plat',
                      noCost ? AppColors.textSecondary : sem.warning),
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
                      'seuil ${restoQty(ing.alertThreshold)}',
                    if (ing.purchaseDate != null)
                      'acheté le ${restoDayLabel(ing.purchaseDate!)}',
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
          'La fiche technique exige une quantité : le coût unitaire se déduit '
          'du montant divisé par elle.');
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
        if (items.isNotEmpty) headerButton('Fourniture', () => _edit(null)),
        Expanded(
          child: items.isEmpty
              ? RestoEmptyState(
                  compact: true,
                  icon: Icons.inventory_2_outlined,
                  title: 'Aucune fourniture',
                  // Le pendant exact de l'autre onglet : ce qui se consomme
                  // SANS ÊTRE SERVI. C'est la frontière qui décide où ranger
                  // une barquette, et elle n'est évidente pour personne.
                  subtitle: 'Ce que vous consommez sans le servir — '
                      'barquettes, gaz, produits d\'entretien. Créez-en une '
                      'ici.',
                  actionLabel: 'Fourniture',
                  onAction: () => _edit(null),
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
                    return RestoCard(
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
                                  RestoPill('stock bas', sem.danger),
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
