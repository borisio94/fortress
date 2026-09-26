import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/daily_menu_service.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/restaurant_setup_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../caisse/domain/entities/sale_item.dart';
import '../../../caisse/presentation/bloc/caisse_bloc.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../features/subscription/presentation/widgets/product_quota_guard.dart';
import '../../../../features/caisse/data/repositories/sale_local_datasource.dart';
import '../../../../shared/providers/cart_pane_provider.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../../caisse/presentation/widgets/cart_widget.dart';
import '../widgets/dish_details_sheet.dart';
import '../../../../core/utils/name_key.dart';
import '../../domain/category_labels.dart';
import '../../domain/menu_grid_geometry.dart';
import '../widgets/dish_form_sheet.dart';
import '../widgets/resto_dish_visuals.dart';
import '../widgets/resto_empty_state.dart';
import '../widgets/resto_amount_text.dart';
import '../widgets/resto_fab.dart';
import '../widgets/resto_underline_tabs.dart';
import '../widgets/resto_surfaces.dart';

/// Tables dont un changement doit redessiner cet écran.
///
/// `products` pour la carte elle-même ; les quatre autres pour la progression
/// de mise en route affichée sur une carte vide — une table créée au plan de
/// salle ou un achat d'ingrédient saisi aux finances cochent une étape d'ici.
const _kWatchedTables = {
  'products',
  'restaurant_tables',
  'recipe_ingredients',
  'ingredients',
  'daily_expenses',
};

/// La carte du restaurant — grille de plats avec filtres par catégorie.
///
/// Remplace l'écran d'inventaire pour les boutiques de restauration : on y
/// consulte et gère la carte, et on y prend une commande à emporter au
/// comptoir.
///
/// DEUX ZONES TACTILES sur une même carte, et AUCUN bouton « Ajouter » :
///   • la PHOTO ajoute au panier à emporter quand le plat est disponible —
///     c'est le geste du service, celui qu'on répète toute la soirée. Sur un
///     plat indisponible elle ouvre la fiche : il n'y a plus rien à ajouter ;
///   • le BLOC TEXTE ouvre toujours la fiche du plat (prix, photo,
///     composition, stock). C'est le seul chemin vers elle pour un serveur
///     sans droit d'édition, à qui le menu ⋮ ne s'affiche pas.
///
/// Ce partage tient dans `tapAdds` (`_DishCard`) : `onTap: tapAdds ? onAdd :
/// onTap` sur la photo, `onTap:` seul sur le texte. Le bouton « Ajouter »
/// que ce commentaire annonçait n'a jamais existé dans ce fichier.
///
/// Ce bloc documentait `_kWatchedTables` jusqu'ici : rien ne le séparait du
/// commentaire de la constante, et la page elle-même n'avait aucune
/// description. Il revient sur la classe qu'il décrit.
class RestaurantMenuPage extends ConsumerStatefulWidget {
  final String shopId;

  const RestaurantMenuPage({super.key, required this.shopId});

  @override
  ConsumerState<RestaurantMenuPage> createState() => _RestaurantMenuPageState();
}

class _RestaurantMenuPageState extends ConsumerState<RestaurantMenuPage> {
  late final OnDataChanged _listener;

  /// Catégorie active. `null` = « Tout ».
  String? _category;

  /// Recherche libre sur le nom et la description du plat. Purement locale :
  /// une carte de cinquante plats devient impraticable au défilement, alors
  /// qu'un serveur connaît le nom de ce qu'on lui commande.
  final _searchCtrl = TextEditingController();
  String _query = '';

  /// Champ de recherche DÉPLOYÉ. Replié, il n'est qu'une loupe dans l'en-tête :
  /// un champ vide pleine largeur au-dessus d'une carte de quelques plats ne
  /// sert à rien. Il reste ouvert tant qu'une recherche est saisie.
  bool _searchOpen = false;

  /// La grille montre-t-elle les plats RETIRÉS au lieu de la carte ?
  ///
  /// Nécessaire parce que cet écran est le seul inventaire du restaurant : la
  /// route `/inventaire` y mène, et l'item « Inventaire » e-commerce est masqué
  /// pour le secteur. Sans ce mode, décocher « Disponible à la vente » ferait
  /// disparaître le plat sans aucun moyen de le rouvrir — l'opération serait
  /// irréversible depuis l'application.
  bool _showRetired = false;

  /// Écriture et relecture du panier de CETTE boutique.
  ///
  /// Le panier vit dans un Bloc créé UNE FOIS au démarrage de l'application,
  /// qui ne connaît aucune boutique. C'est donc à l'écran de composition —
  /// celui-ci, le seul où l'on remplit un panier au restaurant — de dire de
  /// quelle boutique il s'agit.
  final _cartStore = SaleLocalDatasource();

  @override
  void initState() {
    super.initState();
    _listener = (table, sid) {
      if (!mounted) return;
      // Pas seulement `products` : l'état vide porte la progression de mise
      // en route, qui se coche avec la première table et le premier achat
      // d'ingrédient — saisis ailleurs, parfois depuis un autre appareil.
      if (!_kWatchedTables.contains(table)) return;
      if (sid != widget.shopId && sid != '_all') return;
      setState(() {});
    };
    AppDatabase.addListener(_listener);
    // Rebuild immédiat quand une dispo change (dispo/stock/décrément à la
    // commande) — y compris quand le décrément vient d'une vente encaissée
    // depuis le panier alors que cette page est encore montée sous le sheet.
    DailyMenuService.revision.addListener(_onAvailabilityChanged);
    _restoreCart();
  }

  /// Rend le panier qu'un rechargement de page avait chassé.
  ///
  /// SEULEMENT si le panier en mémoire est vide. Au retour sur la carte après
  /// avoir composé une commande, le Bloc a déjà les lignes : les remplacer par
  /// celles du disque ferait revenir un état plus ancien que l'écran.
  Future<void> _restoreCart() async {
    final bloc = context.read<CaisseBloc>();
    if (bloc.state.items.isNotEmpty) return;
    final saved = await _cartStore.loadCart(widget.shopId);
    if (!mounted || saved.isEmpty) return;
    bloc.add(RestoreCart(saved));
  }

  /// Écrit le panier après chaque changement de lignes.
  ///
  /// Sans `await` et sans garde de montage : c'est une écriture Hive locale,
  /// et son échec ne doit pas interrompre un service. Le panier en mémoire
  /// reste la vérité de l'instant ; le disque n'est là que pour le F5.
  void _persistCart(List<SaleItem> items) {
    if (items.isEmpty) {
      _cartStore.clearCart(widget.shopId);
    } else {
      _cartStore.saveCart(widget.shopId, items);
    }
  }

  void _onAvailabilityChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    DailyMenuService.revision.removeListener(_onAvailabilityChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Le catalogue COMPLET de la boutique, plats retirés compris.
  List<Product> get _allProducts =>
      LocalStorageService.getProductsForShop(widget.shopId);

  /// LA CARTE : les plats réellement vendables.
  ///
  /// C'est le filtre que posent déjà toutes les autres surfaces de vente
  /// (cf. `Product.isSellable`) et que cet écran était seul à ne pas poser : un
  /// plat décoché s'affichait comme les autres, sans tampon, et se commandait.
  List<Product> get _products =>
      _allProducts.where((p) => p.isSellable).toList();

  /// Les plats RETIRÉS de la vente. Ils restent au catalogue : c'est d'ici
  /// qu'on les rouvre.
  List<Product> get _retired =>
      _allProducts.where((p) => !p.isSellable).toList();

  /// Ce que la grille affiche en ce moment — la carte, ou les plats retirés.
  List<Product> get _source => _showRetired ? _retired : _products;

  /// Libellé de chaque catégorie, par clé `nameKey`.
  ///
  /// « Plats » et « plats » faisaient deux onglets : la catégorie est une
  /// chaîne libre, et rien ne les rapprochait. Elles n'en font plus qu'un,
  /// sous l'orthographe la plus portée (cf. `categoryLabels`). Rien n'est
  /// réécrit : chaque plat garde son texte.
  Map<String, String> get _labels =>
      categoryLabels(_source.map((p) => p.categoryId));

  /// Catégories réellement portées par au moins un plat — une catégorie
  /// vide n'aurait aucun contenu à filtrer.
  List<String> get _categories => _labels.values.toList()..sort();

  /// Nombre de plats par catégorie, plus le total sous la clé `null`.
  ///
  /// Remplace les vignettes photo de l'ancienne barre : à la taille d'une
  /// pastille, une photo de plat n'est plus qu'une tache de couleur, alors
  /// qu'un compte dit exactement ce qu'on trouvera en filtrant.
  ///
  /// Compté sur `_source` et non sur la carte entière : en mode « plats
  /// retirés », les nombres doivent décrire ce qui est à l'écran.
  Map<String?, int> get _categoryCounts {
    final labels = _labels;
    final counts = <String?, int>{null: _source.length};
    for (final p in _source) {
      final c = p.categoryId?.trim() ?? '';
      if (c.isEmpty) continue;
      // Compté sous le LIBELLÉ retenu, celui de l'onglet : « plats » ajoute
      // au compteur de « Plats ».
      final label = labels[nameKey(c)] ?? c;
      counts[label] = (counts[label] ?? 0) + 1;
    }
    return counts;
  }

  List<Product> get _visible {
    var all = _source;
    if (_category != null) {
      all = all.where((p) => sameCategory(p.categoryId, _category)).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((p) {
      if (p.name.toLowerCase().contains(q)) return true;
      final d = p.description;
      return d != null && d.toLowerCase().contains(q);
    }).toList();
  }

  void _addToCart(Product p) {
    final pid = p.id;
    if (pid == null || pid.isEmpty) {
      AppSnack.error(context, 'Plat non enregistré : ${p.name}');
      return;
    }
    // Retiré de la vente : c'est un réglage PERMANENT, distinct de la dispo du
    // jour ci-dessous. Le plat n'est déjà plus dans la grille — cette garde
    // couvre les chemins qui ne passent pas par elle (liste en cache, plat
    // décoché sur un autre appareil pendant que la carte est à l'écran).
    if (!p.isSellable) {
      AppSnack.error(
          context, '« ${p.name} » est retiré de la vente.');
      return;
    }
    // Dispo du jour : un plat désactivé ou épuisé ne peut pas être commandé.
    if (!DailyMenuService.read(widget.shopId, pid).isAvailable) {
      AppSnack.error(
          context, '« ${p.name} » n\'est pas disponible aujourd\'hui.');
      return;
    }
    // Panier UNIFIÉ : le plat rejoint le panier caisse (l'icône 🛒 en haut à
    // droite du shell), pas un panier local à la page. Le badge se met à jour
    // et la commande se valide par le flux caisse standard. `CaisseBloc` est
    // fourni au sommet de l'app (PosApp) → accessible via context.read ici.
    context.read<CaisseBloc>().add(AddItemToCart(
          RestaurantOrderService.buildItem(
            productId: pid,
            productName: p.name,
            unitPrice: p.priceSellPos,
            priceBuy: p.priceBuy,
            imageUrl: p.mainImageUrl,
          ),
        ));
    // Volet replié par le bouton 🛒 de la barre du haut : on le redéploie.
    // Sans ça, ajouter un plat ne produirait rien à l'écran et le serveur
    // taperait une seconde fois, croyant avoir manqué son geste.
    ref.read(cartPaneVisibleProvider.notifier).show();
    // AUCUN message de succès : l'article apparaît dans le volet panier, à
    // droite, à l'instant même. Le confirmer par un bandeau reviendrait à
    // annoncer ce qui est déjà visible — et en composant une commande de dix
    // plats, ces bandeaux se succèdent en masquant la carte. Les messages sont
    // réservés à ce qui, lui, ne se voit pas : le refus d'ajout.
  }

  /// Tap sur une carte : la fiche s'ouvre en MODIFICATION ou en LECTURE
  /// SEULE selon le droit de l'utilisateur.
  ///
  /// La page Menu est l'écran d'atterrissage d'un restaurant et celui où le
  /// serveur prend les commandes : tout le monde y arrive. Sans cette
  /// distinction, n'importe quel serveur ouvrait le formulaire complet et
  /// pouvait changer un prix de vente.
  ///
  /// Lecture seule et non « rien du tout » : un serveur a besoin de lire la
  /// composition d'un plat pour répondre au client qui demande ce qu'il y a
  /// dedans.
  Future<void> _onDishTap(Product p, bool canEdit) async {
    if (canEdit) return _openDishForm(p);
    await showDishDetails(context: context, shopId: widget.shopId, product: p);
  }

  /// Ouvre la feuille de saisie d'un plat — création si [product] est null.
  ///
  /// Le formulaire produit complet (variantes, SKU, fournisseurs) n'est plus
  /// atteint en restauration : créer et modifier passent par la même feuille
  /// courte, sans quoi on saisirait un plat en 20 secondes pour retomber sur
  /// un écran à 6 sections dès qu'il faut corriger un prix.
  Future<void> _openDishForm([Product? product]) async {
    // Le plafond de l'abonnement ne concerne QUE la création : corriger le prix
    // d'un plat déjà à la carte ne prend aucun emplacement de plus. Sans cette
    // condition, un restaurant au plafond ne pourrait plus toucher à sa propre
    // carte — c'est-à-dire ne plus travailler.
    if (product == null &&
        !ProductQuotaGuard.ensureCanAdd(context,
            plan: ref.read(currentPlanProvider),
            shopId: widget.shopId,
            label: ProductQuotaGuard.dishesLabel)) {
      return;
    }
    final saved = await showDishForm(
      context: context,
      shopId: widget.shopId,
      existing: product,
    );
    // La grille lit Hive à chaque build : un rebuild suffit à refléter la
    // création ou la modification.
    if (saved == true && mounted) setState(() {});
  }

  /// Retire un plat de la carte, depuis la carte elle-même.
  ///
  /// La fiche du plat porte déjà un bouton « Supprimer », mais il est au bas
  /// d'un formulaire à six sections : retirer un plat obligeait à ouvrir la
  /// fiche et à la faire défiler jusqu'en bas. Ici, deux gestes.
  ///
  /// Suppression DOUCE (`AppDatabase.deleteProduct`) — la même que la fiche,
  /// avec le même motif : le plat quitte la carte mais reste restaurable
  /// depuis l'historique, et l'historique des ventes qui le référencent n'est
  /// pas amputé.
  Future<void> _deleteDish(Product p) async {
    final pid = p.id;
    if (pid == null || pid.isEmpty) {
      AppSnack.error(context, 'Plat non enregistré : ${p.name}');
      return;
    }
    final confirmed = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer ce plat ?',
      body: Text('« ${p.name} » sera retiré de la carte. '
          'Action réversible depuis l\'historique.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (confirmed != true || !mounted) return;
    try {
      await AppDatabase.deleteProduct(
        pid,
        reason: 'Plat retiré de la carte',
        userId: LocalStorageService.getCurrentUser()?.id ?? '',
      );
      if (!mounted) return;
      // `getProductsForShop` filtre les supprimés : un rebuild suffit.
      setState(() {});
      AppSnack.success(context, '« ${p.name} » retiré de la carte.');
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Suppression impossible : $e');
    }
  }

  /// Active / désactive un plat pour la journée (admin).
  Future<void> _toggleDispo(Product p, bool enabled) async {
    final pid = p.id;
    if (pid == null || pid.isEmpty) return;
    await DailyMenuService.setEnabled(widget.shopId, pid, enabled);
    if (mounted) setState(() {});
  }

  /// Éditeur du stock du jour d'un plat (admin) — un nombre, ou illimité.
  /// Passe par le châssis de formulaire canonique (clavier natif géré).
  Future<void> _editCount(Product p) async {
    final pid = p.id;
    if (pid == null || pid.isEmpty) return;
    final a = DailyMenuService.read(widget.shopId, pid);
    final ctrl = TextEditingController(text: a.count?.toString() ?? '');
    int? parse() {
      final t = ctrl.text.trim();
      return t.isEmpty ? null : int.tryParse(t);
    }

    final result = await showAdaptiveFormSheet<_CountResult>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Stock du jour',
        subtitle: p.name,
        icon: Icons.inventory_2_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Nombre de plats disponibles aujourd\'hui. Le compteur diminue '
                'à chaque commande ; à 0 le plat passe « épuisé ». Laissez vide '
                'pour un stock illimité.',
                style: AppTextStyles.caption,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Nombre de plats',
                  hintText: 'ex. 20 (vide = illimité)',
                ),
                onSubmitted: (_) =>
                    Navigator.of(sheetCtx).pop(_CountResult(parse())),
              ),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(sheetCtx)
                        .pop(const _CountResult(null)),
                    child: const Text('Illimité'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () =>
                        Navigator.of(sheetCtx).pop(_CountResult(parse())),
                    child: const Text('Enregistrer'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
    if (result == null) return; // fermé sans valider
    await DailyMenuService.setCount(widget.shopId, pid, result.count);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider(widget.shopId));
    final isAdmin = perms.isShopAdmin;
    // Permission DÉDIÉE et non `isShopAdmin` : un employé peut se voir
    // accorder `inventoryDelete` sans être administrateur de la boutique.
    final canDelete = perms.canDeleteProduct;
    // Droits sur la CARTE, distincts de l'accès à l'écran : la page Menu est
    // l'atterrissage du restaurant, tout le monde y arrive — c'est ce qu'on
    // peut y FAIRE qui se protège, pas la porte.
    final canEdit = perms.canEditProduct;
    final canAdd = perms.canAddProduct;
    final products = _visible;
    // Lu ICI et non dans le `builder` du BlocBuilder : `ref.watch` ne vaut que
    // pendant le build de ce widget-ci, pas dans la closure d'un autre.
    final paneVisible = ref.watch(cartPaneVisibleProvider);

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Menu',
      // LE BOUTON FLOTTANT, seul appel de création (cf. `RestoFab`). Masqué :
      //   • sans le droit d'ajouter ;
      //   • sur une grille vide — l'état vide porte son propre bouton ;
      //   • sur la liste des plats RETIRÉS, où l'on n'ajoute rien ;
      //   • PANIER OUVERT : sur mobile le volet occupe toute la largeur (cf.
      //     `_cartPaneWidth`) et le bouton recouvrait « Commander », le geste
      //     même que l'on cherche à provoquer (`7a6a417`).
      floatingActionButton: (products.isEmpty ||
              !canAdd ||
              _showRetired ||
              _cartOpen(context))
          ? null
          : RestoFab(tooltip: 'Ajouter un plat', onPressed: _openDishForm),
      //
      // VOLET PANIER À DROITE — ouvert dès le premier article, refermé dès le
      // dernier retiré. Il remplace la feuille modale : celle-ci recouvrait la
      // carte, obligeant à la fermer pour ajouter le plat suivant et à la
      // rouvrir pour vérifier. Ici la commande se compose sous les yeux.
      //
      // L'ouverture et la fermeture ne sont donc PAS un état à part : elles se
      // déduisent du panier lui-même. Un état booléen se serait fatalement
      // désynchronisé du contenu (panier vidé ailleurs, commande enregistrée).
      //
      // SAUVEGARDE DU PANIER — sur les LIGNES, pas sur leur nombre.
      //
      // Le `buildWhen` du constructeur ci-dessous ne regarde que la longueur,
      // parce que le volet ne s'ouvre et ne se ferme qu'au premier et au
      // dernier article. Ici, il faut plus : changer une quantité ou négocier
      // un prix ne change pas le compte de lignes, et se perdrait au premier
      // F5 — c'est-à-dire exactement le cas que ce lot referme.
      body: BlocListener<CaisseBloc, CaisseState>(
        listenWhen: (p, c) => p.items != c.items,
        listener: (_, s) => _persistCart(s.items),
        child: BlocBuilder<CaisseBloc, CaisseState>(
          buildWhen: (p, c) => p.items.length != c.items.length,
          builder: (context, cart) {
            // Deux conditions, pas une : il faut quelque chose à montrer ET que
            // l'utilisateur n'ait pas replié le volet depuis le bouton 🛒.
            final open = cart.items.isNotEmpty && paneVisible;
            return Row(children: [
              Expanded(child: _buildMenu(products, isAdmin,
                  canDelete: canDelete, canEdit: canEdit, canAdd: canAdd)),
              // Animé en largeur : le volet glisse au lieu d'apparaître d'un
              // bloc, ce qui rend visible d'où il vient.
              // Le panier est un BLOC À PART : coins arrondis et écart avec la
              // carte, comme la maquette. L'écart est compris DANS la largeur
              // animée — ajouté à côté, il apparaîtrait d'un coup au premier
              // article pendant que le panier, lui, glisse encore.
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: open ? _cartPaneWidth(context) + _kCartGap : 0,
                child: open
                    // `ClipRect` + `OverflowBox` : pendant l'animation, la
                    // largeur imposée est inférieure à la largeur finale du
                    // panier. Sans ces deux-là, Flutter tenterait de comprimer
                    // sa mise en page à chaque image et lèverait un débordement.
                    ? ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          maxWidth: _cartPaneWidth(context) + _kCartGap,
                          child: Padding(
                            padding: const EdgeInsets.only(left: _kCartGap),
                            child: SizedBox(
                              width: _cartPaneWidth(context),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: CartWidget(
                                    shopId: widget.shopId, isEcommerce: true),
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ]);
          },
        ),
      ),
    );
  }

  /// Écart entre la carte et le volet panier — les deux sont des blocs
  /// distincts, pas deux moitiés d'une même surface.
  static const double _kCartGap = 10;

  /// Le volet panier est-il déployé ?
  ///
  /// `select` et non `watch` : seule la bascule vide/non-vide nous intéresse.
  /// Observer l'état entier ferait reconstruire toute la carte à chaque
  /// changement de quantité, pour un bouton qui, lui, ne change pas.
  bool _cartOpen(BuildContext context) {
    final hasItems =
        context.select<CaisseBloc, bool>((b) => b.state.items.isNotEmpty);
    return hasItems && ref.watch(cartPaneVisibleProvider);
  }

  /// Largeur du volet : assez pour lire une ligne d'article, jamais plus du
  /// tiers de l'écran — la carte doit rester l'écran principal.
  double _cartPaneWidth(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    // Le seuil est partagé avec le panier, qui doit savoir s'il recouvre la
    // carte pour proposer d'y revenir. Voir `kCartPaneFullWidthBelow`.
    return w < kCartPaneFullWidthBelow ? w : (w / 3).clamp(320.0, 420.0);
  }

  Widget _buildMenu(
    List<Product> products,
    bool isAdmin, {
    required bool canDelete,
    required bool canEdit,
    required bool canAdd,
  }) {
    // CARTE TOTALEMENT VIDE — pas « aucun résultat », mais aucun plat du tout.
    //
    // Dans ce cas la recherche et les filtres de catégorie disparaissent :
    // chercher et trier zéro élément ne peut rien donner, et deux barres de
    // tri au-dessus d'un écran vide laissent croire que quelque chose est
    // filtré alors qu'il n'y a simplement rien. Elles reviennent au premier
    // plat enregistré.
    final emptyMenu = _source.isEmpty;
    // Des plats existent, mais tous retirés de la vente : ce n'est PAS une
    // carte vide, et le dire ferait chercher une saisie déjà faite.
    final allRetired = !_showRetired && _products.isEmpty && _retired.isNotEmpty;
    // Conséquence : sur une carte vide, la recherche et la catégorie encore
    // en mémoire ne décident plus du message — leurs commandes ne sont plus à
    // l'écran, on ne pourrait ni les effacer ni comprendre d'où sort
    // « aucun plat trouvé ».
    final searching = !emptyMenu && _query.trim().isNotEmpty;
    final category = emptyMenu ? null : _category;
    return Column(
        children: [
          // En-tête EN TÊTE DU CORPS et non dans la barre du haut : le titre
          // vient du châssis partagé avec l'e-commerce, qui ne prend qu'une
          // chaîne — deux lignes n'y entreraient pas sans toucher au shell de
          // toute l'application. Même parti pris qu'au tableau de bord.
          //
          // Masqué sur une carte vide, pour la même raison que la recherche et
          // les filtres : « Notre carte · 0 plat » juste au-dessus du panneau
          // « Carte vide » dirait deux fois la même chose, dont une fois en
          // laissant croire qu'il y a une carte.
          if (!emptyMenu)
            _MenuHeader(
              dishCount: _source.length,
              categoryCount: _categories.length,
              retired: _showRetired,
              // La loupe s'efface quand le champ est déployé : il porte déjà sa
              // propre croix de fermeture.
              onSearch: _searchOpen || _query.isNotEmpty
                  ? null
                  : () => setState(() => _searchOpen = true),
            ),
          // Porte de retour vers les plats retirés — et retour à la carte.
          // Affiché même quand la grille est vide : c'est précisément le cas où
          // l'on a besoin de savoir que les plats sont ailleurs.
          if (_retired.isNotEmpty || _showRetired)
            _RetiredBanner(
              count: _retired.length,
              showingRetired: _showRetired,
              onToggle: () => setState(() {
                _showRetired = !_showRetired;
                // La catégorie du mode précédent n'existe probablement pas dans
                // l'autre liste : la garder n'afficherait rien.
                _category = null;
              }),
            ),
          if (!emptyMenu) ...[
            if (_searchOpen || _query.isNotEmpty)
              _SearchField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                // La croix EFFACE et REPLIE : une recherche finie n'a plus de
                // raison d'occuper une ligne.
                onClose: () => setState(() {
                  _searchCtrl.clear();
                  _query = '';
                  _searchOpen = false;
                }),
              ),
            _CategoryBar(
              categories: _categories,
              counts: _categoryCounts,
              selected: _category,
              onSelect: (c) => setState(() => _category = c),
            ),
          ],
          Expanded(
            child: products.isEmpty
                ? RestoEmptyState(
                    icon: searching
                        ? Icons.search_off_rounded
                        : Icons.restaurant_rounded,
                    title: searching
                        ? 'Aucun plat trouvé'
                        : _showRetired
                            ? 'Aucun plat retiré'
                            : allRetired
                                ? 'Tous vos plats sont retirés'
                                : category == null
                                    ? 'Carte vide'
                                    : 'Aucun plat dans « $category »',
                    subtitle: searching
                        ? 'Aucun plat ne correspond à « ${_query.trim()} ». '
                            'Essayez un autre mot ou changez de catégorie.'
                        : _showRetired
                            ? 'Toute votre carte est en vente.'
                            : allRetired
                                ? 'Vos plats existent, mais aucun n\'est en '
                                    'vente. Ouvrez « plats retirés » pour en '
                                    'remettre un à la carte.'
                                : category == null
                                    ? 'Ajoutez vos plats pour composer la '
                                        'carte de votre établissement.'
                                    : 'Choisissez une autre catégorie ou '
                                        'ajoutez un plat.',
                    // Sans le droit de créer, l'état vide reste informatif :
                    // proposer un bouton qui refuserait ensuite serait pire
                    // que ne rien proposer.
                    actionLabel: canAdd ? 'Ajouter un plat' : null,
                    onAction: canAdd ? _openDishForm : null,
                    // Ce qu'il reste à faire, et seulement là où c'est utile :
                    // sur une carte vide, pas quand une recherche ne trouve
                    // rien — l'établissement est alors déjà en service.
                    footer: emptyMenu &&
                            !RestaurantSetupService.stepFor(widget.shopId)
                                .isComplete
                        ? _SetupProgressCard(shopId: widget.shopId)
                        : null,
                  )
                : _MenuGrid(
                    products: products,
                    shopId: widget.shopId,
                    retired: _showRetired,
                    isAdmin: isAdmin,
                    canDelete: canDelete,
                    canEdit: canEdit,
                    onTap: (p) => _onDishTap(p, canEdit),
                    onAdd: _addToCart,
                    // Marge basse qui dégage le bouton flottant, quand il est
                    // affiché — mêmes conditions que lui (voir `build`).
                    fabShown: canAdd && !_showRetired,
                    onToggleDispo: _toggleDispo,
                    onEditCount: _editCount,
                    onDelete: _deleteDish,
                  ),
          ),
        ],
    );
  }
}

/// PORTE VERS LES PLATS RETIRÉS DE LA VENTE, et retour.
///
/// Cet écran est le seul inventaire du restaurant : la route `/inventaire` y
/// mène et l'item « Inventaire » e-commerce est masqué pour le secteur. Un plat
/// décoché disparaît donc de la carte — ce qui est voulu, une carte de service
/// ne montre que ce qui se vend — mais sans ce bandeau il disparaîtrait de
/// l'application entière, et le décocher serait irréversible.
///
/// Invisible quand aucun plat n'est retiré : c'est une réparation, pas un
/// filtre permanent, et rien ne doit s'ajouter à l'écran d'un restaurant dont
/// toute la carte est en vente.
class _RetiredBanner extends StatelessWidget {
  final int count;
  final bool showingRetired;
  final VoidCallback onToggle;

  const _RetiredBanner({
    required this.count,
    required this.showingRetired,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(12),
          child: RestoGlassPanel(
            radius: 12,
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(children: [
              Icon(
                showingRetired
                    ? Icons.arrow_back_rounded
                    : Icons.visibility_off_outlined,
                size: 17,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  showingRetired
                      ? 'Plats retirés de la vente'
                      // Accord au pluriel : le bandeau s'affiche dès UN plat.
                      : count == 1
                          ? '1 plat retiré de la vente'
                          : '$count plats retirés de la vente',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmBold.copyWith(color: cs.onSurface),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                showingRetired ? 'Revenir à la carte' : 'Voir',
                // lot 1 clair : lien interactif, garde la primaire (backlog).
                style: AppTextStyles.caption.copyWith(color: cs.primary),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: cs.primary),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Champ de recherche de la carte — pilule pleine, icône loupe, croix
/// d'effacement dès qu'il y a du texte.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// Efface ET replie le champ — la loupe de l'en-tête revient.
  final VoidCallback onClose;

  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        // Déployé au tap sur la loupe : on vient pour taper.
        autofocus: true,
        textInputAction: TextInputAction.search,
        style: AppTextStyles.input,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: sem.trackMuted,
          hintText: 'Rechercher un plat…',
          hintStyle: AppTextStyles.inputHint,
          prefixIcon: Icon(Icons.search_rounded,
              size: 20, color: theme.colorScheme.onSurfaceVariant),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 42, minHeight: 42),
          // TOUJOURS PRÉSENTE, même champ vide : c'est aussi le seul moyen de
          // replier un champ ouvert par erreur.
          suffixIcon: IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            tooltip: 'Fermer la recherche',
            onPressed: onClose,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          // Pilule : bordure invisible au repos, teintée au focus — le champ
          // se fond dans la barre tant qu'on ne s'en sert pas.
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(999),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(999),
            borderSide: BorderSide(color: sem.borderSubtle),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(999),
            borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
          ),
        ),
      ),
    );
  }
}
/// Barre de filtres par catégorie — onglets soulignés, avec compteur.
///
/// La vignette ronde a disparu. C'était elle qui dimensionnait la pastille
/// (`dot = height - 12`), et sa hauteur suivait le `textScaler` : de 64 à 96 px
/// selon les réglages système, avec des pastilles inégales selon qu'une
/// catégorie avait une photo ou une icône de repli.
///
/// À 17 px, une photo de plat n'est de toute façon plus identifiable : c'est
/// une tache de couleur. Le COMPTEUR la remplace et dit quelque chose d'exact —
/// « Plats · 8 ». La hauteur devient uniforme par construction, sans clamp ni
/// calcul.
class _CategoryBar extends StatelessWidget {
  final List<String> categories;

  /// Nombre de plats par catégorie — `null` porte le total (« Tout »).
  final Map<String?, int> counts;
  final String? selected;
  final ValueChanged<String?> onSelect;

  const _CategoryBar({
    required this.categories,
    required this.counts,
    required this.selected,
    required this.onSelect,
  });

  /// Les valeurs, dans l'ordre d'affichage : « Tout » puis les catégories.
  List<String?> get _values => [null, ...categories];

  @override
  Widget build(BuildContext context) {
    // SOULIGNÉS, plus en pastilles : même grammaire que les onglets de
    // Commandes, et le même widget (`RestoUnderlineTabs`) — deux copies
    // auraient divergé. Le Stock l'emploie aussi.
    //
    // Cette classe garde ce qui lui est propre : le vocabulaire des catégories
    // (`String?`, où `null` vaut « Tout »). Le widget partagé, lui, raisonne
    // par index.
    final values = _values;
    return RestoUnderlineTabs(
      items: [
        for (final v in values)
          RestoUnderlineTab(
            label: v ?? 'Tout',
            count: counts[v] ?? 0,
            // « Tout » n'est pas un filtre : vide, il dit que la carte l'est.
            mutedWhenEmpty: v != null,
          ),
      ],
      selected: values.indexOf(selected).clamp(0, values.length - 1),
      onSelect: (i) => onSelect(values[i]),
    );
  }
}

/// En-tête de la carte : son nom, et ce qu'elle contient — compté en direct.
class _MenuHeader extends StatelessWidget {
  final int dishCount;
  final int categoryCount;

  /// La grille montre les plats RETIRÉS : l'en-tête doit le dire, sans quoi
  /// « Notre carte · 3 plats » contredirait ce qu'on a sous les yeux.
  final bool retired;

  /// Déploie la recherche. `null` : champ déjà ouvert, pas de loupe.
  final VoidCallback? onSearch;

  const _MenuHeader({
    required this.dishCount,
    required this.categoryCount,
    required this.retired,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final plats = '$dishCount plat${dishCount > 1 ? 's' : ''}';
    final cats = '$categoryCount catégorie${categoryCount > 1 ? 's' : ''}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 0),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Échelon `label` (14) : l'échelle typographique de l'app ne
              // compte pas de 15, et inventer une taille en dur pour un pixel
              // d'écart casserait la règle qui tient tout le reste.
              Text(retired ? 'Plats retirés' : 'Notre carte',
                  style: AppTextStyles.label.copyWith(color: cs.onSurface)),
              const SizedBox(height: 2),
              Text(
                  // Les catégories n'ont de sens que sur la carte : sur la
                  // liste des plats retirés, elles ne filtrent rien d'utile.
                  retired ? plats : '$plats · $cats',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary)),
            ],
          ),
        ),
        // LA RECHERCHE EST UNE ICÔNE. Un champ vide pleine largeur au-dessus
        // d'une carte de quelques plats ne servait à rien ; il se déploie au
        // tap, sous l'en-tête.
        if (onSearch != null)
          IconButton(
            onPressed: onSearch,
            tooltip: 'Rechercher un plat',
            icon: Icon(Icons.search_rounded,
                size: 20, color: AppColors.textSecondary),
          ),
        // L'AJOUT N'EST PLUS ICI : le bouton flottant est la seule porte
        // (cf. `RestoFab`).
      ]),
    );
  }
}

/// Grille des plats.
class _MenuGrid extends StatelessWidget {
  final List<Product> products;
  final String shopId;

  /// La grille montre-t-elle des plats RETIRÉS de la vente ?
  final bool retired;
  final bool isAdmin;
  final bool canDelete;
  final bool canEdit;
  final ValueChanged<Product> onTap;
  final ValueChanged<Product> onAdd;

  /// Le bouton flottant est-il affiché ? Décide de la marge basse
  /// ([kRestoFabClearance]) : sans elle, la dernière rangée passe sous lui.
  final bool fabShown;
  final void Function(Product, bool) onToggleDispo;
  final ValueChanged<Product> onEditCount;
  final ValueChanged<Product> onDelete;

  const _MenuGrid({
    required this.products,
    required this.shopId,
    required this.retired,
    required this.isAdmin,
    required this.canDelete,
    required this.canEdit,
    required this.onTap,
    required this.onAdd,
    this.fabShown = false,
    required this.onToggleDispo,
    required this.onEditCount,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      const hPad = 16.0;
      // TOUTE LA GÉOMÉTRIE VIENT DE `menu_grid_geometry.dart`, sous test :
      // colonnes (plancher de 200 dp — 4 dès ~860 dp de contenu), hauteur de
      // photo (ratio 0,78 borné entre 104 et 150) et hauteur de tuile. La
      // tuile rend exactement les lignes que ce calcul compte.
      final layout = menuGridLayout(c.maxWidth - hPad * 2);
      final ts = MediaQuery.textScalerOf(context);
      final tileH = menuTileHeight(layout.photoHeight, ts.scale);

      return GridView.builder(
        // En bas : la place du bouton flottant quand il est là (80 = 48 + 16
        // + 16, cf. `kRestoFabClearance`), 24 sinon.
        padding: EdgeInsets.fromLTRB(
            hPad, 8, hPad, fabShown ? kRestoFabClearance : 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: layout.cols,
          mainAxisSpacing: kMenuRowGap,
          crossAxisSpacing: kMenuGap,
          // Hauteur FIXE issue du calcul, et non un ratio : c'est elle que le
          // test verrouille.
          mainAxisExtent: tileH,
        ),
        itemCount: products.length,
        itemBuilder: (_, i) => _DishCard(
          product: products[i],
          shopId: shopId,
          retired: retired,
          isAdmin: isAdmin,
          canDelete: canDelete,
          canEdit: canEdit,
          photoHeight: layout.photoHeight,
          onTap: () => onTap(products[i]),
          onAdd: () => onAdd(products[i]),
          onToggleDispo: (v) => onToggleDispo(products[i], v),
          onEditCount: () => onEditCount(products[i]),
          onDelete: () => onDelete(products[i]),
        ),
      );
    });
  }
}

/// Rayon de la PHOTO — qui est désormais le bloc entier de la tuile.
///
/// La géométrie (colonnes, hauteur de photo, hauteur de tuile) vit dans
/// `menu_grid_geometry.dart`, sous test.
const double _kPhotoRadius = 14;

/// Pastilles posées SUR la photo : stock à gauche, menu ⋮ à droite.
///
/// Fond noir à 85 % et non 45 % : c'est la règle du module — le texte du mode
/// restaurant ne se pose jamais à nu sur une photo. En dessous, l'assiette
/// blanche d'un plat clair repasse au travers du chiffre.
const double _kBadgeDot = 22;
const double _kBadgeVeil = 0.85;

/// Cible tactile du menu ⋮. La pastille n'en occupe que le centre : 22 px de
/// visible pour 36 px de touchable, soit 7 px de marge tout autour, qui la
/// posent au même niveau que la pastille de stock d'en face.
///
/// Sans cette contrainte, `IconButton` imposerait son minimum de 48 px et la
/// pastille se retrouverait à 19 px du bord au lieu de 6 — visiblement plus
/// enfoncée dans la photo que celle du stock.
const double _kBadgeTap = 36;

/// Pastille claire qui porte l'initiale d'un plat SANS photo, au centre de
/// l'aplat teinté. Assez grande pour que la lettre ne flotte pas, assez petite
/// pour qu'on voie l'aplat tout autour et qu'on reconnaisse la carte à sa
/// couleur avant de la lire.
const double _kInitialDisc = 54;

/// Matrice de désaturation — la vignette d'un plat indisponible passe en gris.
///
/// Trois lignes identiques calées sur les coefficients de luminance de la
/// recommandation ITU-R BT.709, ceux-là mêmes qui servent au calcul de
/// contraste : la vignette perd sa couleur sans changer de clarté, donc sans
/// devenir plus sombre que les cartes voisines.
const ColorFilter _kGreyscale = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Carte d'un plat — photo en plein cadre, informations dessous.
///
/// La photo était une vignette ronde de 70 px centrée. Ce cercle est le bon
/// objet au TABLEAU DE BORD, où il sert de bouton d'ajout rapide et où la
/// photo n'est qu'un repère. Ici l'écran est une surface de gestion : on y
/// regarde sa carte, et une carte se regarde d'abord en images.
///
/// La photo prend donc toute la largeur sur une hauteur dominante, et les
/// contrôles qui la surplombent reprennent le voile à 85 % du module — stock à
/// gauche, menu ⋮ à droite. Sous elle, deux lignes seulement : le nom, puis le
/// prix et le bouton d'ajout. La ligne « catégorie · stock » a disparu, la
/// catégorie étant déjà lisible dans le filtre actif au-dessus de la grille et
/// le stock étant passé sur la photo.
///
/// La carte porte DEUX zones tactiles, et non plus une seule :
///   • la PHOTO ajoute au panier ;
///   • le BLOC TEXTE ouvre la fiche du plat.
///
/// Plus de bouton d'ajout : la photo EST le bouton, sur toutes les largeurs.
/// Le geste n'est donc annoncé par aucun signe — seuls le retour au toucher et,
/// sur le web, l'infobulle au survol le révèlent. C'est assumé : un écran de
/// service se prend en main une fois, et le bouton coûtait une pastille sur
/// chaque photo de la grille.
///
/// CONSÉQUENCE À CONNAÎTRE : sous 720 dp, le volet panier recouvre l'écran
/// entier quand il s'ouvre. Un tap de travers pendant un défilement y bascule
/// donc sur le panier, qu'il faut refermer pour revenir à la carte. Le retour
/// arrière existe — chaque ligne du volet porte une corbeille — mais il n'y a
/// pas d'annulation en un geste : `AppSnack` n'expose pas de `SnackBarAction`.
///
/// Le bloc texte, et pas seulement le menu ⋮ : celui-ci n'apparaît qu'à qui
/// possède un droit d'édition ou de suppression, alors que la fiche en LECTURE
/// existe pour le serveur qui n'en a aucun — c'est lui qui doit répondre au
/// client demandant ce qu'il y a dans un plat. C'est aussi, pour un
/// administrateur, le seul chemin vers le formulaire depuis la carte, puisque
/// la photo ne l'ouvre plus.
class _DishCard extends StatelessWidget {
  final Product product;
  final String shopId;

  /// Plat RETIRÉ de la vente (`isActive == false`).
  ///
  /// Distinct de l'indisponibilité du jour, qui est locale au poste et remise à
  /// zéro chaque matin : ici le retrait est permanent et synchronisé.
  final bool retired;
  final bool isAdmin;
  final bool canDelete;
  final bool canEdit;

  /// Décidée par la GRILLE, qui seule connaît la largeur de carte, et reportée
  /// telle quelle dans la hauteur de tuile. Les deux doivent rester d'accord,
  /// sans quoi le bloc texte déborde.
  final double photoHeight;
  final VoidCallback onTap;
  final VoidCallback onAdd;
  final ValueChanged<bool> onToggleDispo;
  final VoidCallback onEditCount;
  final VoidCallback onDelete;

  const _DishCard({
    required this.product,
    required this.shopId,
    required this.retired,
    required this.isAdmin,
    required this.canDelete,
    required this.canEdit,
    required this.photoHeight,
    required this.onTap,
    required this.onAdd,
    required this.onToggleDispo,
    required this.onEditCount,
    required this.onDelete,
  });

  /// Contenu de la zone photo : l'image, ou l'APLAT teinté qui la remplace.
  ///
  /// Le repli ne peut plus être le cercle du tableau de bord — il faut couvrir
  /// toute la zone. La teinte vient de [restoDishTint], partagée, pour qu'un
  /// plat sans photo garde la même couleur d'un écran à l'autre ; seule la
  /// forme change, et l'initiale se pose sur une pastille claire qui la détache
  /// de l'aplat.
  Widget _photo(BuildContext context) {
    final url = product.mainImageUrl;
    if (url != null && url.isNotEmpty) {
      // `ProductImageCard` cadre en `BoxFit.cover` : la photo remplit sans se
      // déformer, au prix d'une coupe sur les clichés très verticaux. Ce widget
      // est partagé avec l'e-commerce et n'expose ni `fit` ni `alignment` — on
      // ne l'ouvre pas pour cet écran. Un biais de cadrage serait de toute
      // façon un pari : sur une photo mal cadrée, il couperait le plat au lieu
      // de la nappe.
      return ProductImageCard(
        imageUrl: url,
        fillParent: true,
        borderRadius: BorderRadius.zero,
      );
    }
    final tint = restoDishTint(context, product);
    return ColoredBox(
      color: tint.withValues(alpha: 0.22),
      child: Center(
        child: Container(
          width: _kInitialDisc,
          height: _kInitialDisc,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.35),
          ),
          alignment: Alignment.center,
          child: Text(restoDishInitial(product),
              style: AppTextStyles.title.copyWith(color: tint)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    // Dispo du jour (état local) : pilote le grisage de la photo, la ligne
    // d'état et la présence du bouton d'ajout. Lu à chaque build → suit les
    // setState déclenchés par les actions admin et le décrément à la commande.
    final avail = DailyMenuService.read(shopId, product.id ?? '');
    // Un plat retiré n'est jamais « disponible », quelle que soit la dispo du
    // jour : le réglage permanent l'emporte sur celui de la journée.
    final available = !retired && avail.isAvailable;

    final photo = _photo(context);
    // L'image n'ajoute que si elle a quelque chose à ajouter : sur un plat
    // indisponible elle ouvre la fiche. Les trois gardes de `_addToCart`
    // restent derrière de toute façon — elles couvrent les chemins qui ne
    // passent pas par cet écran.
    final tapAdds = available;

    // ── PLUS DE CARTE AUTOUR DE LA PHOTO ──────────────────────────────────
    //
    // Ni fond ni bordure : la photo EST le bloc, arrondie seule, et le texte
    // vit dessous, à nu sur le décor géométrique du module. C'est l'exception
    // écrite à la règle du 16/09 (cf. `restoGlassFill`) : le décor est
    // calculable — texte primaire ≥ 12,2:1, secondaire ≥ 5,2:1 sur le pire
    // cas des huit palettes — là où la règle visait une PHOTO de salle.
    // Rien de textuel ne se pose sur la photo sans son voile à 85 %.
    return Material(
      type: MaterialType.transparency,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── PHOTO, LE BLOC ─────────────────────────────────────
            ClipRRect(
              borderRadius: BorderRadius.circular(_kPhotoRadius),
              child: SizedBox(
              height: photoHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Plat indisponible : la photo passe en GRIS. Elle est
                  // la plus grande surface de la carte, donc la seule
                  // chose qui se voie de l'autre bout de la salle — ce
                  // que faisait le tampon incliné en barrant le nom.
                  available
                      ? photo
                      : ColorFiltered(
                          colorFilter: _kGreyscale, child: photo),
                  // ZONE TACTILE DE LA PHOTO, posée PAR-DESSUS l'image.
                  //
                  // Un `InkWell` peint son encre sur le `Material` le
                  // plus proche, donc SOUS son enfant : enveloppé autour
                  // de la carte, son retour au toucher disparaissait
                  // derrière la photo. Un `Material` transparent placé
                  // ici, au-dessus de l'image, rend l'encre visible sur
                  // la photo — et c'est justement ce qui annonce qu'il
                  // s'y passe quelque chose.
                  Positioned.fill(
                    child: Material(
                      type: MaterialType.transparency,
                      child: Tooltip(
                        message: tapAdds
                            ? 'Ajouter au panier'
                            : 'Voir la fiche du plat',
                        child: InkWell(
                          onTap: tapAdds ? onAdd : onTap,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _StockBadge(
                      value: avail.count == null ? '∞' : '${avail.count}',
                      soldOut: !available,
                    ),
                  ),
                  // Sur un plat RETIRÉ, la dispo du jour et son stock ne
                  // veulent plus rien dire — mais rouvrir sa fiche ou le
                  // supprimer, si : c'est même tout l'objet de la liste
                  // des plats retirés.
                  if (retired
                      ? (canEdit || canDelete)
                      : (isAdmin || canEdit || canDelete))
                    Positioned(
                      top: 0,
                      right: 0,
                      child: SizedBox(
                        width: _kBadgeTap,
                        height: _kBadgeTap,
                        child: _DishMenuBtn(
                          onEdit: canEdit ? onTap : null,
                          onDelete: canDelete ? onDelete : null,
                          onToggleDispo: isAdmin && !retired
                              ? () => onToggleDispo(!avail.enabled)
                              : null,
                          onEditCount:
                              isAdmin && !retired ? onEditCount : null,
                          dispoEnabled: avail.enabled,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ),

            // ── BLOC TEXTE ─────────────────────────────────────────
            //
            // Tapable, et c'est le SEUL chemin vers la fiche d'un plat
            // pour qui n'a ni droit d'édition ni droit de suppression :
            // le menu ⋮ ne s'affiche pas pour lui. Or c'est le serveur
            // qui doit lire la composition d'un plat quand le client
            // demande ce qu'il y a dedans.
            Expanded(
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                // Marges = celles que compte `menuTileHeight` : 8 en haut, 4
                // en bas. Les changer ici sans les changer là-bas fait
                // déborder le bloc.
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      2, kMenuTextTop, 2, kMenuTextBottom),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySmBold.copyWith(
                            color: available
                                ? cs.onSurface
                                : cs.onSurfaceVariant),
                      ),

                      // ── LIGNE D'ÉTAT ─────────────────────────────
                      // Absente quand le plat est disponible, et c'est
                      // voulu : la grille lui réserve quand même sa
                      // hauteur, et le `Spacer` ci-dessous mange la place
                      // inutilisée. Les cartes gardent donc la même
                      // hauteur sans qu'un trou se creuse sous le nom.
                      if (!available) ...[
                        const SizedBox(height: kMenuNameToState),
                        if (retired)
                          Text('Retiré de la vente',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.micro
                                  .copyWith(color: cs.onSurfaceVariant))
                        else
                          // TAPABLE pour l'admin, et c'est le point :
                          // rendre un plat indisponible est un geste
                          // réfléchi qui passe par le menu ⋮, mais le
                          // remettre à la carte arrive dans la minute — un
                          // arrivage, une erreur de manipulation. Le chemin
                          // le plus court sert le cas le plus fréquent. Un
                          // appui long serait introuvable sur le web, comme
                          // l'a déjà tranché le Plan de salle.
                          //
                          // DEUX causes d'indisponibilité, deux remèdes :
                          // un plat ÉPUISÉ est resté `enabled` avec un
                          // compteur à zéro — rebasculer l'interrupteur ne
                          // ferait rien, il faut lui rendre du stock. Un
                          // plat retiré du jour, lui, se rallume.
                          InkWell(
                            onTap: isAdmin
                                ? (avail.isSoldOut
                                    ? onEditCount
                                    : () => onToggleDispo(true))
                                : null,
                            borderRadius: BorderRadius.circular(6),
                            child: Text(
                              // Les deux libellés finissent par
                              // « aujourd'hui » : ce sont des états du
                              // jour, qui tomberont demain matin, et leur
                              // premier mot dit le remède. Épuisé : il
                              // manque du stock. Retiré : il manque une
                              // décision. « Retiré aujourd'hui » se
                              // distingue ainsi de « Retiré de la vente »,
                              // qui est le retrait permanent.
                              avail.isSoldOut
                                  ? 'Épuisé aujourd’hui'
                                  : 'Retiré aujourd’hui',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              // LE TOKEN SUIT SON FOND, et c'est la seule
                              // règle : `warningText` ici, sur la surface
                              // claire de la carte (6,7:1 en clair, ~9:1 en
                              // sombre) ; `warning` sur la pastille de
                              // stock, posée sur un voile noir, où
                              // `warningText` ne tiendrait que 2,2:1.
                              // Ce n'est pas « toujours la variante Text » :
                              // `warning` est calibré pour un fond sombre
                              // ou une icône, `warningText` pour un fond
                              // clair. Même règle pour `danger` et
                              // `success`.
                              style: AppTextStyles.microBold
                                  .copyWith(color: sem.warningText),
                            ),
                          ),
                      ],
                      const Spacer(),

                      // ── LE PRIX, L'ANCRE ─────────────────────────
                      //
                      // Le plus gros texte de la tuile — `subtitle` (16)
                      // semi-gras, unité en petit gris — parce que c'est ce
                      // qu'on lit en premier. En texte primaire et non en
                      // couleur de marque : sur Midnight en sombre, la
                      // primaire ne fait que 1,93:1 (cf. `docs/backlog.md`).
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: RestoAmountText(
                          product.priceSellPos,
                          style: AppTextStyles.subtitle.copyWith(
                              fontWeight: FontWeight.w600,
                              color: available
                                  ? cs.onSurface
                                  : AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
      ),
    );
  }
}

/// Pastille de stock du jour, coin haut gauche de la photo.
///
/// Le compteur vivait dans une barre de contrôle en travers de la photo, à
/// côté d'un interrupteur de 22 px. Il revient sur l'image, mais SEUL et en
/// lecture seule : c'est une information, pas un réglage. Le réglage est resté
/// dans le menu ⋮.
class _StockBadge extends StatelessWidget {
  /// `∞` quand le stock n'est pas compté, sinon le nombre restant.
  final String value;
  final bool soldOut;

  const _StockBadge({required this.value, required this.soldOut});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    // LE TOKEN SUIT SON FOND : sur ce voile noir, `warning` tient 7,0:1 en
    // clair et 8,9:1 en sombre, quand `warningText` — qui est pourtant le bon
    // choix dans le bloc texte, sur surface claire — tomberait à 2,2:1.
    final fg = soldOut ? sem.warning : Colors.white;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: _kBadgeVeil),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Le point dit l'état sans mot : vert tant qu'il reste à servir,
          // ambre quand il n'y a plus rien. Il double le code couleur du
          // chiffre pour ceux qui distinguent mal les deux teintes.
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: soldOut ? sem.warning : sem.success,
            ),
          ),
          const SizedBox(width: 5),
          Text(value, style: AppTextStyles.microBold.copyWith(color: fg)),
        ],
      ),
    );
  }
}

/// Menu ⋮ au coin de la photo : dispo du jour · stock · modifier · supprimer.
///
/// Même parti pris que le Plan de salle : un seul point d'entrée discret pour
/// les actions qui touchent à la fiche, à l'écart des gestes de service (tap =
/// ouvrir, bouton d'ajout = panier). Sans lui, retirer un plat obligeait à
/// ouvrir la fiche et à la faire défiler jusqu'à son dernier bouton.
///
/// Il porte la DISPO DU JOUR et le STOCK DU JOUR, qui occupaient jadis une
/// barre de contrôle en travers de l'image — un interrupteur miniature et un
/// compteur éditable. Ce sont des réglages : leur place est dans un menu, pas
/// en travers de ce qu'on regarde. Seule la LECTURE du stock est restée sur la
/// photo, dans sa pastille.
///
/// La remise à la carte, elle, reste accessible d'un seul tap sur la ligne
/// d'état sous le nom : c'est le geste pressé, il ne passe pas par ici.
///
/// Il revient sur la photo maintenant qu'elle occupe le plein cadre, et
/// reprend donc le voile à 85 % de la pastille de stock : sans lui, l'icône
/// disparaîtrait sur une assiette blanche. La contrainte de 22 px l'emporte sur
/// le minimum de 48 px d'`IconButton` — `ConstrainedBox` clampe les siennes sur
/// celles du parent — sans quoi la pastille déborderait de la photo.
class _DishMenuBtn extends StatelessWidget {
  /// `null` = droit absent → l'entrée n'est pas proposée. Un menu qui montre
  /// une option grisée invite à demander pourquoi ; un menu qui ne la montre
  /// pas ne pose pas la question.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onToggleDispo;
  final VoidCallback? onEditCount;

  /// Sert au seul libellé de l'entrée : « Rendre indisponible » ou « Remettre
  /// à la carte ». Dire l'action plutôt que l'état évite l'ambiguïté d'un
  /// interrupteur, dont on ne sait jamais s'il montre ce qui est ou ce qui
  /// arrivera si on le touche.
  final bool dispoEnabled;

  const _DishMenuBtn({
    required this.onEdit,
    required this.onDelete,
    required this.onToggleDispo,
    required this.onEditCount,
    required this.dispoEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return PopupMenuButton<int>(
      tooltip: 'Actions sur le plat',
      padding: EdgeInsets.zero,
      splashRadius: _kBadgeDot / 2,
      iconSize: _kBadgeDot,
      constraints: const BoxConstraints(minWidth: 210),
      icon: Container(
        width: _kBadgeDot,
        height: _kBadgeDot,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: _kBadgeVeil),
        ),
        alignment: Alignment.center,
        // Blanc sur ce voile : 15:1, quelle que soit la photo dessous. Le
        // token de thème, lui, dépendrait du mode et non du fond réel.
        child: const Icon(Icons.more_vert_rounded,
            size: 15, color: Colors.white),
      ),
      onSelected: (v) {
        switch (v) {
          case 0:
            onEdit?.call();
          case 1:
            onDelete?.call();
          case 2:
            onToggleDispo?.call();
          case 3:
            onEditCount?.call();
        }
      },
      itemBuilder: (_) => [
        if (onToggleDispo != null)
          PopupMenuItem<int>(
            value: 2,
            height: 40,
            child: Row(children: [
              Icon(
                  dispoEnabled
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 16),
              const SizedBox(width: 10),
              Text(dispoEnabled ? 'Rendre indisponible' : 'Remettre à la carte',
                  style: AppTextStyles.bodySm),
            ]),
          ),
        if (onEditCount != null)
          const PopupMenuItem<int>(
            value: 3,
            height: 40,
            child: Row(children: [
              Icon(Icons.inventory_2_outlined, size: 16),
              SizedBox(width: 10),
              Text('Stock du jour', style: AppTextStyles.bodySm),
            ]),
          ),
        if (onEdit != null)
          const PopupMenuItem<int>(
            value: 0,
            height: 40,
            child: Row(children: [
              Icon(Icons.edit_outlined, size: 16),
              SizedBox(width: 10),
              Text('Modifier', style: AppTextStyles.bodySm),
            ]),
          ),
        if (onDelete != null)
          PopupMenuItem<int>(
            value: 1,
            height: 40,
            child: Row(children: [
              Icon(Icons.delete_outline_rounded, size: 16, color: sem.danger),
              const SizedBox(width: 10),
              Text('Supprimer',
                  style: AppTextStyles.bodySm.copyWith(color: sem.dangerText)),
            ]),
          ),
      ],
    );
  }
}

/// Résultat de l'éditeur de stock du jour : `count == null` = illimité.
class _CountResult {
  final int? count;
  const _CountResult(this.count);
}

/// PROGRESSION DE MISE EN ROUTE, sous l'état vide de la carte.
///
/// La page Menu est l'écran d'atterrissage du restaurant : c'est le premier
/// écran que voit un établissement qui vient d'être créé. Lui annoncer
/// « Carte vide » est exact mais sans usage — il le sait déjà. Ce qu'il
/// ignore, c'est ce qu'il reste à faire pour que la caisse et les finances
/// aient quelque chose à afficher, et dans quel ordre.
///
/// Les étapes ne sont PAS recopiées ici : elles sont lues dans
/// [RestaurantSetupService], le même calcul que l'écran Configuration et que
/// la bannière du tableau de bord. Trois affichages, une seule vérité — une
/// liste recopiée aurait fini par cocher une étape que le service, lui,
/// considère encore à faire.
class _SetupProgressCard extends StatelessWidget {
  final String shopId;

  const _SetupProgressCard({required this.shopId});

  /// Libellés dans l'ordre des rangs de [RestaurantSetupStep].
  static const _labels = [
    'Créer une table',
    'Créer un plat et sa recette',
    'Enregistrer vos achats d\'ingrédients',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    final step = RestaurantSetupService.stepFor(shopId);
    // Étapes FRANCHIES : l'étape courante est celle qui reste à faire, donc
    // tout ce qui la précède est acquis.
    final done = step.isComplete
        ? RestaurantSetupStep.totalSteps
        : step.index1 - 1;

    return RestoGlassPanel(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.rocket_launch_outlined, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Mise en route',
                  style:
                      AppTextStyles.bodySmBold.copyWith(color: cs.onSurface)),
            ),
            Text('$done sur ${RestaurantSetupStep.totalSteps}',
                style: AppTextStyles.captionBold.copyWith(color: cs.onSurface)),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: done / RestaurantSetupStep.totalSteps,
              minHeight: 6,
              backgroundColor: sem.trackMuted,
              valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
            ),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < _labels.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            Row(children: [
              Icon(
                i < done
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 16,
                color: i < done ? sem.success : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              // Trois états de lecture : fait (barré, atténué), à faire
              // maintenant (appuyé), plus tard (neutre). Sans cette
              // distinction, la liste dit ce qu'il reste mais pas par où
              // commencer — c'est pourtant toute la question ici.
              Expanded(
                child: Text(
                  _labels[i],
                  style: i < done
                      ? AppTextStyles.caption.copyWith(
                          color: cs.onSurfaceVariant,
                          decoration: TextDecoration.lineThrough)
                      : i == done
                          ? AppTextStyles.captionBold
                              .copyWith(color: cs.onSurface)
                          : AppTextStyles.caption,
                ),
              ),
            ]),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () =>
                  context.go('/shop/$shopId/restaurant/setup'),
              icon: const Icon(Icons.checklist_rounded, size: 18),
              label: const Text('Ouvrir la configuration'),
              // Bouton SECONDAIRE, et volontairement : l'action principale de
              // cet écran reste « Ajouter un plat », juste au-dessus. Le
              // thème impose une largeur minimale infinie aux boutons pleins
              // — d'où la hauteur explicite, sinon la ligne s'étire.
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
            ),
          ),
        ],
      ),
    );
  }
}
