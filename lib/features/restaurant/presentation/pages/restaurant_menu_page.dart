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
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../caisse/presentation/bloc/caisse_bloc.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../features/subscription/presentation/widgets/product_quota_guard.dart';
import '../../../../shared/providers/cart_pane_provider.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../../caisse/presentation/widgets/cart_widget.dart';
import '../widgets/dish_details_sheet.dart';
import '../widgets/dish_form_sheet.dart';
import '../widgets/resto_empty_state.dart';
import '../widgets/resto_surfaces.dart';

/// La carte du restaurant — grille de plats avec filtres par catégorie.
///
/// Remplace l'écran d'inventaire pour les boutiques de restauration : on y
/// consulte et gère la carte, et on y prend une commande à emporter au
/// comptoir.
///
/// Deux gestes distincts sur une même carte :
///   • tap sur la carte → fiche du plat (prix, photo, options, stock) ;
///   • bouton « Ajouter » → ajoute au panier à emporter en cours.
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

  List<Product> get _products =>
      LocalStorageService.getProductsForShop(widget.shopId);

  /// Catégories réellement portées par au moins un plat — une catégorie
  /// vide n'aurait aucun contenu à filtrer.
  List<String> get _categories {
    final used = <String>{};
    for (final p in _products) {
      final c = p.categoryId;
      if (c != null && c.isNotEmpty) used.add(c);
    }
    return used.toList()..sort();
  }

  /// Vignette ronde de chaque catégorie : la photo du premier plat qui en
  /// porte une. Les catégories sont de simples chaînes côté données — elles
  /// n'ont pas d'image propre — et un rond gris uniforme sur toute la barre
  /// n'apporterait rien. La photo d'un plat de la catégorie, elle, la rend
  /// reconnaissable d'un coup d'œil.
  Map<String, String?> get _categoryThumbs {
    final thumbs = <String, String?>{};
    for (final p in _products) {
      final c = p.categoryId;
      if (c == null || c.isEmpty) continue;
      final url = p.mainImageUrl;
      if (thumbs[c] == null && url != null && url.isNotEmpty) thumbs[c] = url;
    }
    return thumbs;
  }

  List<Product> get _visible {
    var all = _products;
    if (_category != null) {
      all = all.where((p) => p.categoryId == _category).toList();
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
      // Masqué quand la grille est vide : l'état vide porte déjà son propre
      // bouton d'ajout, et deux options d'ajout simultanées se
      // concurrenceraient à l'écran.
      floatingActionButton: (products.isEmpty || !canAdd)
          ? null
          : FloatingActionButton.extended(
              onPressed: _openDishForm,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Plat'),
            ),
      // VOLET PANIER À DROITE — ouvert dès le premier article, refermé dès le
      // dernier retiré. Il remplace la feuille modale : celle-ci recouvrait la
      // carte, obligeant à la fermer pour ajouter le plat suivant et à la
      // rouvrir pour vérifier. Ici la commande se compose sous les yeux.
      //
      // L'ouverture et la fermeture ne sont donc PAS un état à part : elles se
      // déduisent du panier lui-même. Un état booléen se serait fatalement
      // désynchronisé du contenu (panier vidé ailleurs, commande enregistrée).
      body: BlocBuilder<CaisseBloc, CaisseState>(
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
    );
  }

  /// Écart entre la carte et le volet panier — les deux sont des blocs
  /// distincts, pas deux moitiés d'une même surface.
  static const double _kCartGap = 10;

  /// Largeur du volet : assez pour lire une ligne d'article, jamais plus du
  /// tiers de l'écran — la carte doit rester l'écran principal.
  double _cartPaneWidth(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return w < 720 ? w : (w / 3).clamp(320.0, 420.0);
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
    final emptyMenu = _products.isEmpty;
    // Conséquence : sur une carte vide, la recherche et la catégorie encore
    // en mémoire ne décident plus du message — leurs commandes ne sont plus à
    // l'écran, on ne pourrait ni les effacer ni comprendre d'où sort
    // « aucun plat trouvé ».
    final searching = !emptyMenu && _query.trim().isNotEmpty;
    final category = emptyMenu ? null : _category;
    return Column(
        children: [
          if (!emptyMenu) ...[
            _SearchField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
            ),
            _CategoryBar(
              categories: _categories,
              thumbs: _categoryThumbs,
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
                        : category == null
                            ? 'Carte vide'
                            : 'Aucun plat dans « $category »',
                    subtitle: searching
                        ? 'Aucun plat ne correspond à « ${_query.trim()} ». '
                            'Essayez un autre mot ou changez de catégorie.'
                        : category == null
                            ? 'Ajoutez vos plats pour composer la carte de '
                                'votre établissement.'
                            : 'Choisissez une autre catégorie ou ajoutez '
                                'un plat.',
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
                    isAdmin: isAdmin,
                    canDelete: canDelete,
                    canEdit: canEdit,
                    onTap: (p) => _onDishTap(p, canEdit),
                    onAdd: _addToCart,
                    onToggleDispo: _toggleDispo,
                    onEditCount: _editCount,
                    onDelete: _deleteDish,
                  ),
          ),
        ],
    );
  }
}

/// Champ de recherche de la carte — pilule pleine, icône loupe, croix
/// d'effacement dès qu'il y a du texte.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
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
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (_, v, __) => v.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Effacer',
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
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
/// Barre de filtres par catégorie — pilules à vignette ronde.
///
/// Chaque pilule porte la photo d'un plat de la catégorie, ce qui la rend
/// identifiable sans lire. La pilule active se remplit de la couleur
/// principale de la boutique ; les autres restent sur une surface neutre
/// bordée, lisible en clair comme en sombre.
class _CategoryBar extends StatelessWidget {
  final List<String> categories;
  final Map<String, String?> thumbs;
  final String? selected;
  final ValueChanged<String?> onSelect;

  const _CategoryBar({
    required this.categories,
    required this.thumbs,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // Hauteur pilotée par le textScaler : à 200 %, une hauteur figée
    // rognerait le libellé.
    final h = MediaQuery.textScalerOf(context).scale(44).clamp(44.0, 76.0);
    return SizedBox(
      height: h + 20,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        children: [
          _chip(context, label: 'Tout', value: null, height: h),
          for (final c in categories)
            _chip(context, label: c, value: c, height: h, thumb: thumbs[c]),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required String label,
    required String? value,
    required double height,
    String? thumb,
  }) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final sel = selected == value;
    final radius = BorderRadius.circular(999);
    final fg =
        sel ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    // Vignette légèrement plus petite que la pilule → l'anneau de fond reste
    // visible tout autour, comme sur les pastilles de la maquette.
    final dot = height - 12;

    return Padding(
      padding: const EdgeInsets.only(right: 9),
      child: Material(
        color: sel ? theme.colorScheme.primary : sem.elevatedSurface,
        borderRadius: radius,
        child: InkWell(
          onTap: () => onSelect(value),
          borderRadius: radius,
          child: Container(
            height: height,
            padding: const EdgeInsets.fromLTRB(6, 0, 18, 0),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                  color: sel ? theme.colorScheme.primary : sem.borderSubtle),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipOval(
                  child: SizedBox(
                    width: dot,
                    height: dot,
                    child: thumb == null || thumb.isEmpty
                        ? ColoredBox(
                            color: sem.trackMuted,
                            child: Icon(
                              value == null
                                  ? Icons.grid_view_rounded
                                  : Icons.restaurant_rounded,
                              size: dot * 0.5,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          )
                        : ProductImageCard(
                            imageUrl: thumb,
                            width: dot,
                            height: dot,
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: AppTextStyles.bodySmBold.copyWith(color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Grille des plats.
class _MenuGrid extends StatelessWidget {
  final List<Product> products;
  final String shopId;
  final bool isAdmin;
  final bool canDelete;
  final bool canEdit;
  final ValueChanged<Product> onTap;
  final ValueChanged<Product> onAdd;
  final void Function(Product, bool) onToggleDispo;
  final ValueChanged<Product> onEditCount;
  final ValueChanged<Product> onDelete;

  const _MenuGrid({
    required this.products,
    required this.shopId,
    required this.isAdmin,
    required this.canDelete,
    required this.canEdit,
    required this.onTap,
    required this.onAdd,
    required this.onToggleDispo,
    required this.onEditCount,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    // Bandeau de description affiché seulement si AU MOINS un plat visible en
    // porte une : sur une carte sans descriptions, réserver deux lignes vides
    // sous chaque nom creuserait un trou sur toute la grille.
    final showDesc = products.any((p) {
      final d = p.description;
      return d != null && d.trim().isNotEmpty;
    });

    return LayoutBuilder(builder: (_, c) {
      const hPad = 16.0, gap = 14.0;
      final inner = c.maxWidth - hPad * 2;
      // ~231 dp par carte : 2 colonnes minimum sur téléphone.
      final cols = (inner / 231).floor().clamp(2, 6);
      final cardW = (inner - gap * (cols - 1)) / cols;

      // Hauteur de carte CALCULÉE, pas devinée : photo à ratio fixe + bloc
      // texte dimensionné au textScaler courant. Un `childAspectRatio` figé
      // ferait déborder le bloc texte dès que l'utilisateur agrandit la
      // police dans les préférences.
      final ts = MediaQuery.textScalerOf(context);
      final photoH = (cardW - _kPhotoInset * 2) * 0.72 + _kPhotoInset * 2;
      final infoH = 8 // padding haut
          + ts.scale(13) * 1.5 // nom (1 ligne)
          + (showDesc ? 3 + ts.scale(11) * 1.35 * 2 : 0) // description
          + 8 // respiration
          + (ts.scale(16) * 1.35 > _kAddBtn ? ts.scale(16) * 1.35 : _kAddBtn)
          + 10; // padding bas

      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(hPad, 4, hPad, 96),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: gap,
          crossAxisSpacing: gap,
          childAspectRatio: cardW / (photoH + infoH),
        ),
        itemCount: products.length,
        itemBuilder: (_, i) => _DishCard(
          product: products[i],
          shopId: shopId,
          isAdmin: isAdmin,
          canDelete: canDelete,
          canEdit: canEdit,
          showDescription: showDesc,
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

/// Marge de la photo à l'intérieur de la carte (la photo est encartée, pas
/// à fleur de bord) et diamètre du bouton rond d'ajout. Partagés entre le
/// calcul de hauteur de la grille et le rendu de la carte — les deux DOIVENT
/// rester d'accord, sans quoi le bloc texte déborde.
const double _kPhotoInset = 6;
const double _kAddBtn = 34;

/// Carte d'un plat : photo encartée en haut, informations dessous sur la
/// surface de la carte.
///
/// La photo n'est plus le fond des textes — seuls les éléments qui doivent
/// rester collés à l'image (barre admin, étoiles, tampon « épuisé ») lui sont
/// superposés, sur bandeau sombre. Le nom, la description et le prix sont
/// posés sur `elevatedSurface` et suivent donc les couleurs du thème : ils
/// restent lisibles en clair comme en sombre, quelle que soit la photo.
class _DishCard extends StatelessWidget {
  final Product product;
  final String shopId;
  final bool isAdmin;
  final bool canDelete;
  final bool canEdit;

  /// Réserve les deux lignes de description. Décidé au niveau de la grille
  /// pour que toutes les cartes gardent la même hauteur de bloc texte, donc
  /// des prix alignés d'une carte à l'autre.
  final bool showDescription;
  final VoidCallback onTap;
  final VoidCallback onAdd;
  final ValueChanged<bool> onToggleDispo;
  final VoidCallback onEditCount;
  final VoidCallback onDelete;

  const _DishCard({
    required this.product,
    required this.shopId,
    required this.isAdmin,
    required this.canDelete,
    required this.canEdit,
    required this.showDescription,
    required this.onTap,
    required this.onAdd,
    required this.onToggleDispo,
    required this.onEditCount,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    // Dispo du jour (état local) : pilote le voile « épuisé », le tampon et
    // l'activation du bouton Ajouter. Lu à chaque build → suit les setState
    // déclenchés par les actions admin et le décrément à la commande.
    final avail = DailyMenuService.read(shopId, product.id ?? '');
    final available = avail.isAvailable;

    final ts = MediaQuery.textScalerOf(context);
    final desc = product.description?.trim() ?? '';

    return Material(
      color: sem.elevatedSurface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── PHOTO ENCARTÉE ───────────────────────────────────────────
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(_kPhotoInset),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ProductImageCard(
                        imageUrl: product.mainImageUrl,
                        fillParent: true,
                        borderRadius: BorderRadius.zero,
                      ),
                      // Voile RENFORCÉ quand le plat est indisponible →
                      // photo « éteinte ». Sous les contrôles, qui restent
                      // lisibles.
                      if (!available)
                        Positioned.fill(
                          child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.45)),
                        ),
                      Positioned.fill(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Barre de contrôle en tête de photo : dispo du
                            // jour (admin) et menu ⋮ (droit de suppression).
                            // Invisible pour un serveur sans ces droits, qui
                            // ne fait que prendre les commandes.
                            if (isAdmin || canDelete || canEdit)
                              _GlassPanel(
                                padding:
                                    const EdgeInsets.fromLTRB(6, 1, 2, 1),
                                child: Row(
                                  children: [
                                    if (isAdmin) ...[
                                      SizedBox(
                                        height: 22,
                                        width: 34,
                                        child: FittedBox(
                                          fit: BoxFit.contain,
                                          // Couleurs pilotées par le
                                          // switchTheme global.
                                          child: Switch(
                                            value: avail.enabled,
                                            onChanged: onToggleDispo,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(avail.enabled ? 'Dispo' : 'Off',
                                          style: AppTextStyles.micro.copyWith(
                                              color: Colors.white,
                                              shadows: _kTextShadow)),
                                    ],
                                    const Spacer(),
                                    // Stock du jour — tap = éditer.
                                    if (isAdmin)
                                      InkWell(
                                        onTap: onEditCount,
                                        borderRadius:
                                            BorderRadius.circular(6),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 5, vertical: 3),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(
                                                  Icons.inventory_2_outlined,
                                                  size: 13,
                                                  color: Colors.white),
                                              const SizedBox(width: 3),
                                              Text(
                                                avail.count == null
                                                    ? '∞'
                                                    : '${avail.count}',
                                                style: AppTextStyles.microBold
                                                    .copyWith(
                                                        color: Colors.white,
                                                        shadows:
                                                            _kTextShadow),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    if (canEdit || canDelete)
                                      _DishMenuBtn(
                                        onEdit: canEdit ? onTap : null,
                                        onDelete: canDelete ? onDelete : null,
                                      ),
                                  ],
                                ),
                              ),
                            const Spacer(),
                            // Étoiles posées en bas à gauche de la photo,
                            // sur bandeau sombre — la note reste visible sans
                            // manger une ligne du bloc texte.
                            if (product.rating > 0)
                              Align(
                                alignment: Alignment.bottomLeft,
                                child: _GlassPanel(
                                  borderRadius: BorderRadius.circular(999),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 3),
                                  child: _Stars(rating: product.rating),
                                ),
                              ),
                          ],
                        ),
                      ),
                      // Tampon « ÉPUISÉ / INDISPONIBLE » incliné.
                      // `IgnorePointer` : ne bloque ni le tap carte
                      // (édition) ni la barre admin au-dessus.
                      if (!available)
                        IgnorePointer(
                          child: Center(
                            child: Transform.rotate(
                              angle: -0.12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: (avail.isSoldOut
                                          ? sem.danger
                                          : Colors.black)
                                      .withValues(alpha: 0.82),
                                  borderRadius: BorderRadius.circular(7),
                                  border: Border.all(
                                      color: Colors.white
                                          .withValues(alpha: 0.85),
                                      width: 1.5),
                                ),
                                child: Text(
                                  avail.isSoldOut
                                      ? 'ÉPUISÉ'
                                      : 'INDISPONIBLE',
                                  style: AppTextStyles.captionBold.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            // ── BLOC TEXTE ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodyBold,
                  ),
                  if (showDescription) ...[
                    const SizedBox(height: 3),
                    // Hauteur RÉSERVÉE à deux lignes, même quand ce plat n'a
                    // pas de description : sans elle, les prix ne seraient
                    // plus alignés d'une carte à l'autre.
                    SizedBox(
                      height: ts.scale(11) * 1.35 * 2,
                      child: Text(
                        desc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.caption,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  // Prix à gauche, bouton rond d'ajout à droite.
                  Row(
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            CurrencyFormatter.format(product.priceSellPos),
                            maxLines: 1,
                            style: AppTextStyles.subtitleBold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _AddButton(
                        enabled: available,
                        onAdd: onAdd,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Menu ⋮ posé sur la photo du plat : modifier · supprimer.
///
/// Même parti pris que le Plan de salle : un seul point d'entrée discret pour
/// les actions qui touchent à la fiche, à l'écart des gestes de service (tap =
/// ouvrir, bouton rond = ajouter au panier). Sans lui, retirer un plat
/// obligeait à ouvrir la fiche et à la faire défiler jusqu'à son dernier
/// bouton.
class _DishMenuBtn extends StatelessWidget {
  /// `null` = droit absent → l'entrée n'est pas proposée. Un menu qui montre
  /// une option grisée invite à demander pourquoi ; un menu qui ne la montre
  /// pas ne pose pas la question.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _DishMenuBtn({required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return PopupMenuButton<int>(
      tooltip: 'Actions sur le plat',
      padding: EdgeInsets.zero,
      splashRadius: 16,
      iconSize: 16,
      constraints: const BoxConstraints(minWidth: 168),
      icon: const Icon(Icons.more_vert_rounded,
          size: 16, color: Colors.white, shadows: _kTextShadow),
      onSelected: (v) => v == 0 ? onEdit?.call() : onDelete?.call(),
      itemBuilder: (_) => [
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
                  style: AppTextStyles.bodySm.copyWith(color: sem.danger)),
            ]),
          ),
      ],
    );
  }
}

/// Bouton rond « ajouter au panier » — pastille pleine à la couleur de la
/// boutique, éteinte sur surface neutre quand le plat n'est pas disponible.
class _AddButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onAdd;

  const _AddButton({required this.enabled, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;

    return Tooltip(
      message: enabled ? 'Ajouter au panier' : 'Plat indisponible',
      child: Material(
        color: enabled ? theme.colorScheme.primary : sem.trackMuted,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onAdd : null,
          child: SizedBox(
            width: _kAddBtn,
            height: _kAddBtn,
            child: Icon(
              enabled
                  ? Icons.shopping_cart_rounded
                  : Icons.remove_shopping_cart_rounded,
              size: _kAddBtn * 0.48,
              color: enabled
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Résultat de l'éditeur de stock du jour : `count == null` = illimité.
class _CountResult {
  final int? count;
  const _CountResult(this.count);
}

/// Ombre portée commune aux textes et aux étoiles posés sur la photo.
/// Deuxième filet de sécurité derrière le flou : même sur un fond clair et
/// contrasté, le glyphe garde un liseré sombre qui le détache.
const _kTextShadow = [
  Shadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 1)),
];

/// Bandeau semi-opaque posé sur la photo pour rendre le texte lisible quelle
/// que soit l'image du plat.
///
/// Opacité alignée sur la règle du module (cf. `restoGlassFill`) : le texte du
/// mode restaurant ne se pose JAMAIS à nu sur une photo, il lui faut une
/// surface à ~85 %. À 45 %, la photo d'un plat clair — une assiette blanche,
/// une nappe — repassait au travers du libellé « Dispo » et du compteur.
///
/// IMPORTANT — plus de `BackdropFilter` (flou) ici : sur Flutter web
/// (CanvasKit), EMPILER plusieurs `BackdropFilter` par-dessus une image
/// (`CachedNetworkImage`) casse le compositing et fait DISPARAÎTRE la photo
/// (carte grise). On utilise donc un simple voile noir translucide + l'ombre
/// portée du texte, qui suffisent au contraste et sont robustes sur toutes les
/// plateformes.
class _GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final BorderRadius? borderRadius;

  const _GlassPanel({
    required this.child,
    required this.padding,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: borderRadius,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
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
                style: AppTextStyles.captionBold.copyWith(color: cs.primary)),
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

/// Note du plat en étoiles (`Product.rating`, 0–5).
///
/// Teintées à la couleur principale du thème, pleine opacité + ombre
/// portée : à 70 % elles disparaissaient sur les photos claires. Pleines et
/// vides partagent la même teinte, seule l'icône (pleine / contour) les
/// distingue.
class _Stars extends StatelessWidget {
  final int rating;
  const _Stars({required this.rating});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    // Taille passée par le `textScaler` : les étoiles grandissent avec le
    // texte quand l'utilisateur augmente la taille dans les préférences.
    final size = MediaQuery.textScalerOf(context).scale(14);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            i <= rating ? Icons.star_rounded : Icons.star_border_rounded,
            size: size,
            color: color,
            shadows: _kTextShadow,
          ),
      ],
    );
  }
}
