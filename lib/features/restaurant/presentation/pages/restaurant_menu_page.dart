import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/daily_menu_service.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../caisse/presentation/bloc/caisse_bloc.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../widgets/dish_form_sheet.dart';
import '../widgets/resto_empty_state.dart';

/// La carte du restaurant — grille de plats avec filtres par catégorie.
///
/// Remplace l'écran d'inventaire pour les boutiques de restauration : on y
/// consulte et gère la carte, et on y prend une commande à emporter au
/// comptoir.
///
/// Deux gestes distincts sur une même carte :
///   • tap sur la carte → fiche du plat (prix, photo, options, stock) ;
///   • bouton « Ajouter » → ajoute au panier à emporter en cours.
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

  @override
  void initState() {
    super.initState();
    _listener = (table, sid) {
      if (!mounted) return;
      if (table != 'products') return;
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

  List<Product> get _visible {
    final all = _products;
    if (_category == null) return all;
    return all.where((p) => p.categoryId == _category).toList();
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
    AppSnack.success(context, '${p.name} ajouté au panier');
  }

  /// Ouvre la feuille de saisie d'un plat — création si [product] est null.
  ///
  /// Le formulaire produit complet (variantes, SKU, fournisseurs) n'est plus
  /// atteint en restauration : créer et modifier passent par la même feuille
  /// courte, sans quoi on saisirait un plat en 20 secondes pour retomber sur
  /// un écran à 6 sections dès qu'il faut corriger un prix.
  Future<void> _openDishForm([Product? product]) async {
    final saved = await showDishForm(
      context: context,
      shopId: widget.shopId,
      existing: product,
    );
    // La grille lit Hive à chaque build : un rebuild suffit à refléter la
    // création ou la modification.
    if (saved == true && mounted) setState(() {});
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
    final isAdmin =
        ref.watch(permissionsProvider(widget.shopId)).isShopAdmin;
    final products = _visible;

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Menu',
      // Masqué quand la grille est vide : l'état vide porte déjà son propre
      // bouton d'ajout, et deux options d'ajout simultanées se
      // concurrenceraient à l'écran.
      floatingActionButton: products.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _openDishForm,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Plat'),
            ),
      body: Column(
        children: [
          _CategoryBar(
            categories: _categories,
            selected: _category,
            onSelect: (c) => setState(() => _category = c),
          ),
          Expanded(
            child: products.isEmpty
                ? RestoEmptyState(
                    icon: Icons.restaurant_rounded,
                    title: _category == null
                        ? 'Carte vide'
                        : 'Aucun plat dans « $_category »',
                    subtitle: _category == null
                        ? 'Ajoutez vos plats pour composer la carte de '
                            'votre établissement.'
                        : 'Choisissez une autre catégorie ou ajoutez un plat.',
                    actionLabel: 'Ajouter un plat',
                    onAction: _openDishForm,
                  )
                : _MenuGrid(
                    products: products,
                    shopId: widget.shopId,
                    isAdmin: isAdmin,
                    onTap: _openDishForm,
                    onAdd: _addToCart,
                    onToggleDispo: _toggleDispo,
                    onEditCount: _editCount,
                  ),
          ),
        ],
      ),
    );
  }
}
/// Barre de filtres par catégorie.
class _CategoryBar extends StatelessWidget {
  final List<String> categories;
  final String? selected;
  final ValueChanged<String?> onSelect;

  const _CategoryBar({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        children: [
          _chip(context, label: 'Tout', value: null),
          for (final c in categories) _chip(context, label: c, value: c),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required String label, required String? value}) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final sel = selected == value;

    return Padding(
      padding: const EdgeInsets.only(right: 9),
      child: Material(
        color: sel ? theme.colorScheme.primary : sem.trackMuted,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: () => onSelect(value),
          borderRadius: BorderRadius.circular(9),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                  color: sel ? theme.colorScheme.primary : sem.borderSubtle),
            ),
            child: Text(
              label,
              style: AppTextStyles.bodySmBold.copyWith(
                color: sel
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurface,
              ),
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
  final ValueChanged<Product> onTap;
  final ValueChanged<Product> onAdd;
  final void Function(Product, bool) onToggleDispo;
  final ValueChanged<Product> onEditCount;

  const _MenuGrid({
    required this.products,
    required this.shopId,
    required this.isAdmin,
    required this.onTap,
    required this.onAdd,
    required this.onToggleDispo,
    required this.onEditCount,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      // ~231 dp par carte (210 + 10 %) : cartes agrandies d'un dixième, donc
      // une colonne de moins sur les largeurs limites. 2 colonnes minimum
      // sur téléphone.
      final cols = (c.maxWidth / 231).floor().clamp(2, 6);
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          // Image carrée + bloc texte de ~104 dp.
          // Carte dominée par l'image : proportion plus proche du carré
          // que la version photo + bloc texte.
          childAspectRatio: 0.82,
        ),
        itemCount: products.length,
        itemBuilder: (_, i) => _DishCard(
          product: products[i],
          shopId: shopId,
          isAdmin: isAdmin,
          onTap: () => onTap(products[i]),
          onAdd: () => onAdd(products[i]),
          onToggleDispo: (v) => onToggleDispo(products[i], v),
          onEditCount: () => onEditCount(products[i]),
        ),
      );
    });
  }
}

/// Carte d'un plat : la photo occupe toute la carte, les informations sont
/// posées par-dessus sur un voile sombre plein cadre.
///
/// Nom en haut centré, prix au centre, puis la ligne étoiles (gauche) /
/// « Ajouter » (droite). Les textes sont en blanc : ils reposent sur une
/// photo, pas sur une surface du thème — leur contraste dépend de l'image,
/// jamais du mode clair/sombre.
class _DishCard extends StatelessWidget {
  final Product product;
  final String shopId;
  final bool isAdmin;
  final VoidCallback onTap;
  final VoidCallback onAdd;
  final ValueChanged<bool> onToggleDispo;
  final VoidCallback onEditCount;

  const _DishCard({
    required this.product,
    required this.shopId,
    required this.isAdmin,
    required this.onTap,
    required this.onAdd,
    required this.onToggleDispo,
    required this.onEditCount,
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

    return Material(
      color: sem.elevatedSurface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ProductImageCard(
              imageUrl: product.mainImageUrl,
              fillParent: true,
              borderRadius: BorderRadius.zero,
            ),
            // Voile léger plein cadre : unifie la carte sans éteindre la
            // photo. La lisibilité des textes est assurée par les bandeaux
            // de verre dépoli ci-dessous, pas par ce voile.
            Positioned.fill(
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.15)),
            ),
            // Voile RENFORCÉ quand le plat est indisponible → carte « grisée ».
            // Placé sous le contenu : les textes/contrôles restent lisibles.
            if (!available)
              Positioned.fill(
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.42)),
              ),
            Positioned.fill(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Barre de contrôle ADMIN (dispo du jour) : interrupteur +
                  // stock éditable. Réservée aux admins ; invisible côté
                  // serveur/vendeur qui ne fait que prendre les commandes.
                  if (isAdmin)
                    _GlassPanel(
                      padding: const EdgeInsets.fromLTRB(6, 1, 4, 1),
                      child: Row(
                        children: [
                          SizedBox(
                            height: 22,
                            width: 34,
                            child: FittedBox(
                              fit: BoxFit.contain,
                              // Couleurs pilotées par le switchTheme global
                              // (thumb blanc / track primary quand actif).
                              child: Switch(
                                value: avail.enabled,
                                onChanged: onToggleDispo,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(avail.enabled ? 'Dispo' : 'Off',
                              style: AppTextStyles.micro.copyWith(
                                  color: Colors.white, shadows: _kTextShadow)),
                          const Spacer(),
                          // Stock du jour — tap = éditer (nombre / illimité).
                          InkWell(
                            onTap: onEditCount,
                            borderRadius: BorderRadius.circular(6),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 3),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.inventory_2_outlined,
                                      size: 13, color: Colors.white),
                                  const SizedBox(width: 3),
                                  Text(
                                    avail.count == null
                                        ? '∞'
                                        : '${avail.count}',
                                    style: AppTextStyles.microBold.copyWith(
                                        color: Colors.white,
                                        shadows: _kTextShadow),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Nom, centré, sur un bandeau flouté. Échelon `bodyBold` =
                  // corps par défaut : le nom suit le réglage Taille du texte.
                  _GlassPanel(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    child: Text(
                      product.name,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyBold
                          .copyWith(color: Colors.white, shadows: _kTextShadow),
                    ),
                  ),
                  // Prix centré. Échelon `subtitle` : l'information la plus
                  // utile de la carte. Pas de FittedBox (annulerait
                  // l'agrandissement demandé dans les préférences).
                  Expanded(
                    child: Center(
                      child: _GlassPanel(
                        borderRadius: BorderRadius.circular(999),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 5),
                        child: Text(
                          CurrencyFormatter.format(product.priceSellPos),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.subtitle.copyWith(
                              color: Colors.white, shadows: _kTextShadow),
                        ),
                      ),
                    ),
                  ),
                  // Ligne du bas : étoiles à gauche, « Ajouter » à droite.
                  _GlassPanel(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: _Stars(rating: product.rating),
                          ),
                        ),
                        const SizedBox(width: 6),
                        FilledButton(
                          // Désactivé quand le plat n'est pas disponible.
                          onPressed: available ? onAdd : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: (available
                                    ? theme.colorScheme.primary
                                    : Colors.black)
                                .withValues(alpha: available ? 0.7 : 0.45),
                            foregroundColor: theme.colorScheme.onPrimary,
                            disabledBackgroundColor:
                                Colors.black.withValues(alpha: 0.45),
                            disabledForegroundColor:
                                Colors.white.withValues(alpha: 0.7),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(7)),
                          ),
                          child: Text(
                            available ? 'Ajouter' : 'Indispo',
                            style: AppTextStyles.label.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Tampon « ÉPUISÉ / INDISPONIBLE » centré, légèrement incliné.
            // `IgnorePointer` : ne bloque ni le tap carte (édition) ni la
            // barre admin au-dessus.
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
                            color: Colors.white.withValues(alpha: 0.85),
                            width: 1.5),
                      ),
                      child: Text(
                        avail.isSoldOut ? 'ÉPUISÉ' : 'INDISPONIBLE',
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
/// IMPORTANT — plus de `BackdropFilter` (flou) ici : sur Flutter web
/// (CanvasKit), EMPILER plusieurs `BackdropFilter` par-dessus une image
/// (`CachedNetworkImage`) casse le compositing et fait DISPARAÎTRE la photo
/// (carte grise). On utilise donc un simple voile noir translucide (alpha
/// relevé pour compenser l'absence de flou) + l'ombre portée du texte, qui
/// suffisent au contraste et sont robustes sur toutes les plateformes.
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
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: borderRadius,
      ),
      child: Padding(padding: padding, child: child),
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
