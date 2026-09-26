import 'package:flutter/material.dart';
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
import '../widgets/daily_count_sheet.dart';
import '../widgets/dish_details_sheet.dart';
import '../../domain/cart_pane_layout.dart';
import '../../domain/menu_grid_geometry.dart';
import '../../domain/menu_view.dart';
import '../widgets/dish_form_sheet.dart';
import '../widgets/resto_dish_visuals.dart';
import '../widgets/resto_empty_state.dart';
import '../widgets/resto_amount_text.dart';
import '../widgets/resto_fab.dart';
import '../widgets/resto_underline_tabs.dart';
import '../widgets/resto_surfaces.dart';

part 'restaurant_menu_page.header.dart';
part 'restaurant_menu_page.grid.dart';
part 'restaurant_menu_page.cart.dart';

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

  /// Ce que montre la page en ce moment — carte ou plats retirés, filtrés
  /// par catégorie et par recherche. Les règles vivent dans `MenuView`
  /// (domaine, sous test) ; relu à chaque build, comme l'était Hive.
  MenuView get _view => MenuView(
        all: LocalStorageService.getProductsForShop(widget.shopId),
        showRetired: _showRetired,
        category: _category,
        query: _query,
      );

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

  /// Éditeur du stock du jour d'un plat (admin) — la feuille
  /// `DailyCountSheet` rend un nombre, ou illimité.
  Future<void> _editCount(Product p) async {
    final pid = p.id;
    if (pid == null || pid.isEmpty) return;
    final a = DailyMenuService.read(widget.shopId, pid);
    final result = await showAdaptiveFormSheet<DailyCountResult>(
      context: context,
      builder: (_) => DailyCountSheet(dishName: p.name, current: a.count),
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
    final view = _view;
    final products = view.visible;
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
            // Le CORPS de page, et non l'écran : barre latérale dépliée, il
            // est de 247 px plus étroit, et c'est lui qui dit si la carte
            // tient encore à côté du volet (`cartPaneLayout`).
            return LayoutBuilder(builder: (context, c) {
              final layout = _MenuCartPane.layoutFor(context, c.maxWidth);
              return Row(children: [
                Expanded(child: _buildMenu(view, products, isAdmin,
                    canDelete: canDelete, canEdit: canEdit, canAdd: canAdd)),
                _MenuCartPane(
                    open: open, shopId: widget.shopId, layout: layout),
              ]);
            });
          },
        ),
      ),
    );
  }

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

  Widget _buildMenu(
    MenuView view,
    List<Product> products,
    bool isAdmin, {
    required bool canDelete,
    required bool canEdit,
    required bool canAdd,
  }) {
    // Carte vide, tout retiré, recherche en cours : les règles et leurs
    // raisons sont dans `MenuView` (isEmptyMenu, isAllRetired, isSearching).
    final emptyMenu = view.isEmptyMenu;
    final category = view.effectiveCategory;
    final empty = view.emptyKind;
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
              dishCount: view.source.length,
              categoryCount: view.categories.length,
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
          if (view.retired.isNotEmpty || _showRetired)
            _RetiredBanner(
              count: view.retired.length,
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
              categories: view.categories,
              counts: view.categoryCounts,
              selected: _category,
              onSelect: (c) => setState(() => _category = c),
            ),
          ],
          Expanded(
            child: products.isEmpty
                ? RestoEmptyState(
                    icon: empty == MenuEmptyKind.noMatch
                        ? Icons.search_off_rounded
                        : Icons.restaurant_rounded,
                    title: switch (empty) {
                      MenuEmptyKind.noMatch => 'Aucun plat trouvé',
                      MenuEmptyKind.noRetired => 'Aucun plat retiré',
                      MenuEmptyKind.allRetired => 'Tous vos plats sont retirés',
                      MenuEmptyKind.emptyMenu => 'Carte vide',
                      MenuEmptyKind.emptyCategory =>
                        'Aucun plat dans « $category »',
                    },
                    subtitle: switch (empty) {
                      MenuEmptyKind.noMatch =>
                        'Aucun plat ne correspond à « ${_query.trim()} ». '
                            'Essayez un autre mot ou changez de catégorie.',
                      MenuEmptyKind.noRetired =>
                        'Toute votre carte est en vente.',
                      MenuEmptyKind.allRetired =>
                        'Vos plats existent, mais aucun n\'est en '
                            'vente. Ouvrez « plats retirés » pour en '
                            'remettre un à la carte.',
                      MenuEmptyKind.emptyMenu =>
                        'Ajoutez vos plats pour composer la '
                            'carte de votre établissement.',
                      MenuEmptyKind.emptyCategory =>
                        'Choisissez une autre catégorie ou '
                            'ajoutez un plat.',
                    },
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
