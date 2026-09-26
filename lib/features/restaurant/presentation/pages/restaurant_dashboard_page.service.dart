part of 'restaurant_dashboard_page.dart';

// Le service en cours : commandes ouvertes, menu du jour, stock.

// ═══════════════════════════════════════════════════════════════════════
//  RANGÉE DE SERVICE — commandes · ingrédients
// ═══════════════════════════════════════════════════════════════════════

/// Les deux panneaux du service, côte à côte sur large écran, empilés sinon.
class _ServiceRow extends StatelessWidget {
  final String shopId;
  final RestaurantDashData resto;

  const _ServiceRow({required this.shopId, required this.resto});

  @override
  Widget build(BuildContext context) {
    final orders = _OpenOrdersCard(shopId: shopId, resto: resto);
    final stock = _IngredientsCard(shopId: shopId);

    // DEUX cartes depuis que « Menu du jour » est remontée en tête d'écran :
    // le palier à 1040 px, qui servait à loger trois colonnes, n'a plus d'objet.
    return LayoutBuilder(builder: (_, c) {
      if (c.maxWidth >= kRestoServiceRowSideBySideMin) {
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 3, child: orders),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: stock),
            ],
          ),
        );
      }
      return Column(children: [
        orders,
        const SizedBox(height: 16),
        stock,
      ]);
    });
  }
}

/// Commandes encore ouvertes, les plus récentes en tête.
class _OpenOrdersCard extends StatelessWidget {
  final String shopId;
  final RestaurantDashData resto;

  const _OpenOrdersCard({required this.shopId, required this.resto});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    final lines = resto.openOrders;

    /// Couleur (icône), icône et couleur de TEXTE par étape de service. Le
    /// texte suit son fond : variantes `*Text`, et `onSurface` plutôt que la
    /// primaire — un libellé d'étape est une information.
    (Color, IconData, Color) look(int stage) => switch (stage) {
          2 => (
              sem.success,
              Icons.check_circle_outline_rounded,
              sem.successText
            ),
          1 => (
              sem.warning,
              Icons.local_fire_department_outlined,
              sem.warningText
            ),
          _ => (cs.primary, Icons.schedule_rounded, cs.onSurface),
        };

    return _Card(
      title: 'Commandes en cours',
      subtitle: resto.openCount > lines.length
          ? '${resto.openCount} au total'
          : null,
      child: lines.isEmpty
          ? const _EmptyBlock(
              icon: Icons.done_all_rounded,
              message: 'Aucune commande en attente. Service à jour.',
            )
          : Column(
              children: [
                for (final o in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: restoGlassInner(context),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () =>
                            context.push('/shop/$shopId/caisse/orders'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 11),
                          child: Row(
                            children: [
                              Icon(look(o.stage).$2,
                                  size: 19, color: look(o.stage).$1),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(o.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.bodyBold
                                        .copyWith(color: cs.onSurface)),
                              ),
                              const SizedBox(width: 8),
                              Text('|',
                                  style: AppTextStyles.bodySm.copyWith(
                                      color: sem.borderSubtle)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(o.statusLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.bodySm
                                        .copyWith(color: look(o.stage).$3)),
                              ),
                              Icon(Icons.chevron_right_rounded,
                                  size: 20,
                                  color:
                                      cs.onSurface.withValues(alpha: 0.35)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Menu du jour — une rangée de plats qu'on ajoute au panier d'un doigt.
///
/// ─── CE QUE « DU JOUR » VEUT DIRE ICI ──────────────────────────────────────
///
/// Les plats VENDABLES de la carte, les disponibles d'abord. Ce n'est pas une
/// sélection composée par le gérant : `DailyMenuService` ne porte qu'une
/// disponibilité — un interrupteur et un stock, locaux à l'appareil et remis à
/// zéro chaque matin. Une vraie carte du jour demanderait une donnée de plus.
///
/// ─── LE TAP AJOUTE AU PANIER ───────────────────────────────────────────────
///
/// Le même geste que l'écran Menu, et le même panier : celui de la caisse,
/// partagé par toute l'app. AUCUNE table n'est demandée ici — elle se choisit à
/// la validation, dans « Type de commande ». Demander la table d'abord
/// créerait un second parcours de prise de commande, alors que tout passe par
/// le Menu depuis qu'on a supprimé l'écran de service.
///
/// Les trois gardes de l'écran Menu sont reprises telles quelles : identifiant
/// présent, plat vendable, disponible aujourd'hui. Les omettre rouvrirait ce
/// que ces contrôles ferment.
class _DailyMenuCard extends StatelessWidget {
  final String shopId;

  const _DailyMenuCard({required this.shopId});

  /// Au-delà, la rangée devient un second écran Menu. En deçà de la dizaine,
  /// le défilement n'aurait pas d'objet.
  static const int _maxDishes = 12;

  /// Diamètre du cercle, et de sa pastille.
  static const double _circle = 62;
  static const double _badge = 21;

  void _add(BuildContext context, Product p) {
    final pid = p.id;
    if (pid == null || pid.isEmpty) return;
    if (!p.isSellable) {
      AppSnack.error(context, '« ${p.name} » est retiré de la vente.');
      return;
    }
    if (!DailyMenuService.read(shopId, pid).isAvailable) {
      AppSnack.error(
          context, '« ${p.name} » n\'est pas disponible aujourd\'hui.');
      return;
    }
    context.read<CaisseBloc>().add(AddItemToCart(
          RestaurantOrderService.buildItem(
            productId: pid,
            productName: p.name,
            unitPrice: p.priceSellPos,
            priceBuy: p.priceBuy,
            imageUrl: p.mainImageUrl,
          ),
        ));
    AppSnack.success(context, '${p.name} ajouté');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // `isSellable` et non `isActive` seul : la règle des surfaces de vente
    // exclut aussi les brouillons (cf. `Product.isSellable`).
    final dishes = LocalStorageService.getProductsForShop(shopId)
        .where((p) => p.isSellable && p.id != null)
        .toList();
    dishes.sort((a, b) {
      final av = DailyMenuService.read(shopId, a.id!).isAvailable ? 0 : 1;
      final bv = DailyMenuService.read(shopId, b.id!).isAvailable ? 0 : 1;
      return av != bv ? av - bv : a.name.compareTo(b.name);
    });
    final shown = dishes.take(_maxDishes).toList();
    final hasMore = dishes.length > shown.length;

    return _Card(
      title: 'Menu du jour',
      subtitle: shown.isEmpty ? null : 'Touchez un plat pour l\'ajouter',
      trailing: TextButton(
        // La carte restaurant vit sur la route `/inventaire` (même route que
        // l'inventaire e-commerce, l'écran change selon le secteur).
        onPressed: () => context.push('/shop/$shopId/inventaire'),
        child: Text('Voir la carte',
            style: AppTextStyles.bodySm.copyWith(color: Theme.of(context).semantic.brandText)),
      ),
      child: shown.isEmpty
          ? const _EmptyBlock(
              icon: Icons.restaurant_menu_rounded,
              message: 'Aucun plat sur la carte. Ajoutez-en depuis le Menu.',
            )
          : SizedBox(
              // Cercle + nom + prix, sans hauteur perdue.
              height: _circle + 42,
              child: Row(children: [
                Expanded(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: shown.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (_, i) => _DishBubble(
                      product: shown[i],
                      available: DailyMenuService.read(shopId, shown[i].id!)
                          .isAvailable,
                      soldOut:
                          DailyMenuService.read(shopId, shown[i].id!).isSoldOut,
                      diameter: _circle,
                      badge: _badge,
                      onTap: () => _add(context, shown[i]),
                    ),
                  ),
                ),
                // Il reste des plats hors écran : un chevron le dit, là où le
                // bord coupé d'une vignette ne le dit qu'à moitié.
                if (hasMore)
                  Icon(Icons.chevron_right_rounded,
                      size: 20,
                      color: cs.onSurface.withValues(alpha: 0.35)),
              ]),
            ),
    );
  }
}

/// Un plat de la rangée : cercle photo, pastille « + », nom, prix.
///
/// Le cercle ENTIER est la cible du toucher, pas seulement la pastille : à
/// 21 px, celle-ci est trop petite pour un doigt en plein service. Elle
/// annonce l'action, elle ne la porte pas.
class _DishBubble extends StatelessWidget {
  final Product product;
  final bool available;
  final bool soldOut;
  final double diameter;
  final double badge;
  final VoidCallback onTap;

  const _DishBubble({
    required this.product,
    required this.available,
    required this.soldOut,
    required this.diameter,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;

    return SizedBox(
      width: diameter + 16,
      child: InkWell(
        onTap: available ? onTap : null,
        borderRadius: BorderRadius.circular(diameter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: diameter,
              height: diameter,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Opacity(
                    // Indisponible : le cercle s'éteint. L'information doit se
                    // voir d'un coup d'œil, pas seulement se lire.
                    opacity: available ? 1 : 0.4,
                    child: ClipOval(
                      child: SizedBox(
                        width: diameter,
                        height: diameter,
                        child: RestoDishAvatar(product: product),
                      ),
                    ),
                  ),
                  // Pas de pastille sur un plat indisponible : proposer un
                  // « + » qui refuserait ensuite serait pire que ne rien
                  // proposer.
                  if (available)
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: badge,
                        height: badge,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                          // Liseré à la couleur de la carte : sans lui, la
                          // pastille se confond avec le bord du cercle.
                          border: Border.all(
                              color: restoGlassFill(context), width: 2),
                        ),
                        child: Icon(Icons.add_rounded,
                            size: 13, color: cs.onPrimary),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(product.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppTextStyles.caption.copyWith(color: cs.onSurface)),
            Text(
                available
                    ? CurrencyFormatter.format(product.priceSellPos)
                    : (soldOut ? 'Épuisé' : 'Indisponible'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.microBold.copyWith(
                    color: available ? cs.onSurface : sem.dangerText)),
          ],
        ),
      ),
    );
  }
}

/// Stock d'ingrédients : les plus urgents d'abord, puis deux raccourcis.
class _IngredientsCard extends StatelessWidget {
  final String shopId;

  const _IngredientsCard({required this.shopId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;

    // Stock bas en tête : c'est ce sur quoi il faut agir.
    final all = IngredientService.forShop(shopId);
    all.sort((a, b) {
      if (a.isLowStock != b.isLowStock) return a.isLowStock ? -1 : 1;
      return a.quantity.compareTo(b.quantity);
    });
    final shown = all.take(4).toList();

    return _Card(
      title: 'Stock d\'ingrédients',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (shown.isEmpty)
            const _EmptyBlock(
              icon: Icons.eco_outlined,
              message: 'Aucun ingrédient enregistré.',
            )
          else
            for (final i in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: restoGlassInner(context),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: sem.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.eco_outlined,
                          size: 17,
                          color: i.isLowStock ? sem.danger : cs.primary),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(i.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.bodySm
                                .copyWith(color: cs.onSurface)),
                      ),
                      Text(
                          '${_qty(i.quantity)} ${i.unit}',
                          style: AppTextStyles.bodySmBold.copyWith(
                              color:
                                  i.isLowStock ? sem.dangerText : cs.onSurface)),
                    ],
                  ),
                ),
              ),
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: () => context.push('/shop/$shopId/restaurant/finances'),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Ajouter ingrédient'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => context
                .push('/shop/$shopId/restaurant/inventory/reconcile'),
            icon: const Icon(Icons.fact_check_outlined, size: 18),
            label: const Text('Inventaire'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
          ),
        ],
      ),
    );
  }

  /// Quantité lisible, sans « .0 » superflu.
  String _qty(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}
