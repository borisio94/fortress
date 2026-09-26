/// CE QUE MONTRE LA PAGE MENU : la carte ou les plats retirés, filtrés par
/// catégorie et par recherche, avec le compte de chaque onglet et le cas
/// d'écran vide.
///
/// Logique PURE, sortie de `_RestaurantMenuPageState` le 26/09/2026 (lot
/// « classes géantes ») : la page vit sous `AppScaffold`, qu'on ne sait pas
/// monter en test — ici, ces règles se testent sans rien monter
/// (`test/unit/menu_view_test.dart`). Le code est celui de la page, déplacé :
/// seuls les noms ont perdu leur tiret bas.
library;

import '../../../core/utils/name_key.dart';
import '../../inventaire/domain/entities/product.dart';
import 'category_labels.dart';

/// Pourquoi la grille est vide — la page en tire son titre et son message.
enum MenuEmptyKind {
  /// Une recherche ne trouve rien.
  noMatch,

  /// Mode « plats retirés », et aucun plat retiré.
  noRetired,

  /// Des plats existent, mais tous sont retirés de la vente.
  allRetired,

  /// Aucun plat du tout (ou aucun dans la liste affichée).
  emptyMenu,

  /// La catégorie choisie ne contient rien.
  emptyCategory,
}

class MenuView {
  /// Le catalogue COMPLET de la boutique, plats retirés compris.
  final List<Product> all;

  /// La grille montre-t-elle les plats RETIRÉS au lieu de la carte ?
  final bool showRetired;

  /// Catégorie active. `null` = « Tout ».
  final String? category;

  /// Recherche libre sur le nom et la description du plat.
  final String query;

  const MenuView({
    required this.all,
    this.showRetired = false,
    this.category,
    this.query = '',
  });

  /// LA CARTE : les plats réellement vendables.
  ///
  /// C'est le filtre que posent déjà toutes les autres surfaces de vente
  /// (cf. `Product.isSellable`) et que cet écran était seul à ne pas poser : un
  /// plat décoché s'affichait comme les autres, sans tampon, et se commandait.
  List<Product> get products => all.where((p) => p.isSellable).toList();

  /// Les plats RETIRÉS de la vente. Ils restent au catalogue : c'est d'ici
  /// qu'on les rouvre.
  List<Product> get retired => all.where((p) => !p.isSellable).toList();

  /// Ce que la grille affiche en ce moment — la carte, ou les plats retirés.
  List<Product> get source => showRetired ? retired : products;

  /// Libellé de chaque catégorie, par clé `nameKey`.
  ///
  /// « Plats » et « plats » faisaient deux onglets : la catégorie est une
  /// chaîne libre, et rien ne les rapprochait. Elles n'en font plus qu'un,
  /// sous l'orthographe la plus portée (cf. `categoryLabels`). Rien n'est
  /// réécrit : chaque plat garde son texte.
  Map<String, String> get labels =>
      categoryLabels(source.map((p) => p.categoryId));

  /// Catégories réellement portées par au moins un plat — une catégorie
  /// vide n'aurait aucun contenu à filtrer.
  List<String> get categories => labels.values.toList()..sort();

  /// Nombre de plats par catégorie, plus le total sous la clé `null`.
  ///
  /// Remplace les vignettes photo de l'ancienne barre : à la taille d'une
  /// pastille, une photo de plat n'est plus qu'une tache de couleur, alors
  /// qu'un compte dit exactement ce qu'on trouvera en filtrant.
  ///
  /// Compté sur `source` et non sur la carte entière : en mode « plats
  /// retirés », les nombres doivent décrire ce qui est à l'écran.
  Map<String?, int> get categoryCounts {
    final labels = this.labels;
    final counts = <String?, int>{null: source.length};
    for (final p in source) {
      final c = p.categoryId?.trim() ?? '';
      if (c.isEmpty) continue;
      // Compté sous le LIBELLÉ retenu, celui de l'onglet : « plats » ajoute
      // au compteur de « Plats ».
      final label = labels[nameKey(c)] ?? c;
      counts[label] = (counts[label] ?? 0) + 1;
    }
    return counts;
  }

  /// Les plats de la grille : la source, filtrée par catégorie puis par
  /// recherche (nom ou description, sans casse).
  List<Product> get visible {
    var all = source;
    if (category != null) {
      all = all.where((p) => sameCategory(p.categoryId, category)).toList();
    }
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((p) {
      if (p.name.toLowerCase().contains(q)) return true;
      final d = p.description;
      return d != null && d.toLowerCase().contains(q);
    }).toList();
  }

  // ── Carte vide ─────────────────────────────────────────────────────────

  /// CARTE TOTALEMENT VIDE — pas « aucun résultat », mais aucun plat du tout.
  ///
  /// Dans ce cas la recherche et les filtres de catégorie disparaissent :
  /// chercher et trier zéro élément ne peut rien donner, et deux barres de
  /// tri au-dessus d'un écran vide laissent croire que quelque chose est
  /// filtré alors qu'il n'y a simplement rien. Elles reviennent au premier
  /// plat enregistré.
  bool get isEmptyMenu => source.isEmpty;

  /// Des plats existent, mais tous retirés de la vente : ce n'est PAS une
  /// carte vide, et le dire ferait chercher une saisie déjà faite.
  bool get isAllRetired =>
      !showRetired && products.isEmpty && retired.isNotEmpty;

  /// Conséquence : sur une carte vide, la recherche et la catégorie encore
  /// en mémoire ne décident plus du message — leurs commandes ne sont plus à
  /// l'écran, on ne pourrait ni les effacer ni comprendre d'où sort
  /// « aucun plat trouvé ».
  bool get isSearching => !isEmptyMenu && query.trim().isNotEmpty;

  /// La catégorie qui compte pour le message (cf. [isSearching]).
  String? get effectiveCategory => isEmptyMenu ? null : category;

  /// Le cas d'écran vide, quand [visible] est vide.
  MenuEmptyKind get emptyKind => isSearching
      ? MenuEmptyKind.noMatch
      : showRetired
          ? MenuEmptyKind.noRetired
          : isAllRetired
              ? MenuEmptyKind.allRetired
              : effectiveCategory == null
                  ? MenuEmptyKind.emptyMenu
                  : MenuEmptyKind.emptyCategory;
}
