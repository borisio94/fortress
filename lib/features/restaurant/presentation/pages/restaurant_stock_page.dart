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
import '../widgets/resto_amount_text.dart';
import '../widgets/resto_fab.dart';
import '../widgets/resto_surfaces.dart' show RestoGlassPanel;
import '../widgets/resto_underline_tabs.dart';
import '../widgets/resto_section_header.dart';
import '../widgets/resto_tab_kit.dart';
import '../../../../core/widgets/touch_target.dart';

part 'restaurant_stock_page.ingredients.dart';
part 'restaurant_stock_page.supplies.dart';

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
    final nIng = IngredientService.forShop(shopId).length;
    final nSup = StockItemService.forShop(shopId).length;

    return AppScaffold(
      shopId: shopId,
      // TITRE VIDE : « Stock » est déjà en tête du corps, avec ses compteurs.
      // L'écrire deux fois volait une ligne à un écran qui n'en a pas de trop.
      // La barre garde la cloche et le menu.
      //
      // Le tableau de bord, lui, garde son titre : son en-tête de corps dit
      // « Bonjour… », pas « Tableau de bord ». Le doublon est propre à Stock.
      title: '',
      isRootPage: false,
      // LE BOUTON FLOTTANT, seul appel de création (cf. `RestoFab`). Il SUIT
      // L'ONGLET ACTIF — d'où sa place ici, au niveau de la page : ingrédient
      // ou fourniture. Masqué sur une liste vide, dont l'état vide porte son
      // propre bouton. Aucune permission, comme l'ancien bouton d'en-tête.
      floatingActionButton: (_tab == 0 ? nIng : nSup) == 0
          ? null
          : RestoFab(
              tooltip: _tab == 0
                  ? 'Ajouter un ingrédient'
                  : 'Ajouter une fourniture',
              onPressed: _tab == 0
                  ? () => _createIngredient(context, shopId)
                  : () => _createStockItem(context, shopId),
            ),
      actions: [
        IconButton(
          tooltip: 'Inventaire',
          icon: const Icon(Icons.fact_check_outlined),
          onPressed: () =>
              context.push('/shop/$shopId/restaurant/inventory/reconcile'),
        ),
      ],
      // TOUT SUR LA MÊME MARGE. Sans cette ligne, Flutter centre par défaut :
      // l'en-tête et la rangée de pastilles, qui ont une largeur intrinsèque,
      // se retrouvaient au milieu, tandis que les enfants sous `Expanded`
      // remplissaient la largeur et paraissaient alignés. Quatre alignements
      // sur un écran, pour un seul défaut.
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RestoSectionHeader(
            title: 'Stock',
            subtitle: '${_count(nIng, zero: 'aucun ingrédient', one: 'ingrédient')}'
                ' · '
                '${_count(nSup, zero: 'aucune fourniture', one: 'fourniture')}',
            // PAS DE BOUTON DE CRÉATION ICI : le bouton flottant est le seul
            // appel de l'écran (cf. `floatingActionButton` plus haut).
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
          // SOULIGNÉS, plus en pastilles — même widget que Commandes et le Menu
          // (`RestoUnderlineTabs`). La couleur par onglet disparaît avec la
          // pastille qui la portait : l'ICÔNE, qui était déjà le signal fiable,
          // reste seule — c'est précisément ce que le ΔE de 17,7 sur Amber
          // exigeait.
          RestoUnderlineTabs(
            items: [
              RestoUnderlineTab(
                  label: 'Ingrédients',
                  count: nIng,
                  icon: Icons.eco_outlined),
              RestoUnderlineTab(
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

  /// Crée un ingrédient — MÊME feuille que la fiche d'un plat.
  ///
  /// `IngredientQuickSheet` écrit l'ingrédient et, si un montant est saisi, la
  /// dépense d'achat qui va avec. La liste se rafraîchit par l'écoute de
  /// `ingredients`, comme toujours — aucun `setState` n'est nécessaire ici.
  ///
  /// `warnsAboutUnlinked` : créé depuis STOCK, rien n'oblige à le rattacher à
  /// une recette ensuite, et la feuille le dit.
  static Future<void> _createIngredient(BuildContext context, String shopId) =>
      showAdaptiveFormSheet<Ingredient>(
        context: context,
        builder: (_) => IngredientQuickSheet(
          shopId: shopId,
          warnsAboutUnlinked: true,
        ),
      );

  /// Crée une fourniture. Même remontée, même raison.
  static Future<void> _createStockItem(BuildContext context, String shopId) =>
      showAdaptiveFormSheet<bool>(
        context: context,
        builder: (_) => _StockItemEditor(shopId: shopId),
      );

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

/// LA LISTE DU STOCK : UN SEUL PANNEAU, des lignes dedans.
///
/// Seize cartes empilées, chacune avec son fond et sa bordure, faisaient un mur
/// de rectangles. Les lignes perdent fond et bordure ; elles sont séparées par
/// un filet `borderSubtle`, et portées TOUTES ensemble par une seule surface.
///
/// POURQUOI UN PANNEAU ET PAS LE DÉCOR NU : mesuré, le filet `#E5E7EB` posé à
/// nu sur le décor clair tombe à 1,09:1 en bas d'écran, là où le dégradé
/// descend vers `#EFF1F5` — les lignes s'y fondent (même ordre que le 1,07 des
/// deux fonds du lot Commandes). Sur le panneau de verre, il reste à 1,23:1
/// sur toute la hauteur, et 1,84:1 en sombre. Aucun token de filet n'est plus
/// marqué : `divider` et `inputBorder` valent le même `#E5E7EB`.
///
/// Pas de fond alterné : il ferait revenir le mur de rectangles.
class _StockLines extends StatelessWidget {
  final List<Widget> children;

  const _StockLines({required this.children});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return RestoGlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      radius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(height: 1, thickness: 1, color: sem.borderSubtle),
            children[i],
          ],
        ],
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
