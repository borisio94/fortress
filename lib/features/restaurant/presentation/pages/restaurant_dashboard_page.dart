import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/daily_menu_service.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/ingredient_service.dart';
import '../../../../core/services/restaurant_reporting_service.dart';
import '../../../../core/services/restaurant_setup_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/period_selector.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../../caisse/presentation/bloc/caisse_bloc.dart';
import '../../../dashboard/data/dashboard_providers.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../data/restaurant_dashboard_providers.dart';
import '../widgets/resto_kpi_tile.dart';
import '../widgets/resto_surfaces.dart';

/// Tableau de bord dédié à la restauration.
///
/// Reprend la composition d'une console de restaurant : bandeau de 4 tuiles
/// colorées, répartition en anneau, activité hebdomadaire en barres, et
/// carrousel des plats qui marchent.
///
/// Les COMPOSANTS sont fidèles à la maquette de référence ; le FOND de page
/// et les cartes suivent le thème de l'application (clair/sombre, couleur de
/// marque de la boutique). Seules les 4 teintes de tuiles sont fixes : ce
/// sont des couleurs de données, au même titre qu'une légende de graphique.
///
/// L'écran e-commerce (`DashboardPage`) n'est pas touché : le routeur choisit
/// l'un ou l'autre selon le secteur de la boutique.
class RestaurantDashboardPage extends ConsumerStatefulWidget {
  final String shopId;

  const RestaurantDashboardPage({super.key, required this.shopId});

  @override
  ConsumerState<RestaurantDashboardPage> createState() =>
      _RestaurantDashboardPageState();
}

class _RestaurantDashboardPageState
    extends ConsumerState<RestaurantDashboardPage> {
  @override
  void initState() {
    super.initState();
    // Sans cet abonnement, `dashSignalProvider` n'est jamais incrémenté depuis
    // la restauration (seul l'écran e-commerce le faisait) : les providers
    // `family` servaient leur résultat en cache et les chiffres restaient
    // figés jusqu'à un changement de période. Une vente encaissée doit se voir
    // tout de suite.
    AppDatabase.addListener(_onDataChanged);
    DailyMenuService.revision.addListener(_onMenuChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(dashSignalProvider.notifier).state++;
    });
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDataChanged);
    DailyMenuService.revision.removeListener(_onMenuChanged);
    super.dispose();
  }

  void _onDataChanged(String table, String shopId) {
    if (!mounted) return;
    // '_all' = notification globale (reset, flush de la file offline).
    if (shopId != widget.shopId && shopId != '_all') return;
    ref.read(dashSignalProvider.notifier).state++;
  }

  /// Les disponibilités du jour vivent hors Hive synchronisé : elles ont leur
  /// propre notifieur.
  void _onMenuChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final shopId = widget.shopId;
    final data = ref.watch(dashDataProvider(shopId));
    final resto = ref.watch(restaurantDashProvider(shopId));
    final finance = ref.watch(restaurantFinanceProvider(shopId));

    return AppScaffold(
      shopId: shopId,
      title: 'Tableau de bord',
      body: ListView(
        // Défilable même contenu court : geste « tirer pour actualiser ».
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          // ── Contexte : boutique et service ────────────────────────────
          // En TÊTE DU CORPS et non dans la barre du haut : le titre vient du
          // châssis partagé avec l'e-commerce, et il ne prend qu'une chaîne.
          _Greeting(shopId: shopId),
          const SizedBox(height: 16),
          // ── Configuration incomplète ──────────────────────────────────
          // Le routeur redirige déjà vers /restaurant/setup ; cette bannière
          // couvre le cas où l'on atteint le tableau de bord par un chemin
          // qui n'est pas gardé (retour arrière navigateur, lien direct).
          if (!RestaurantSetupService.stepFor(shopId).isComplete) ...[
            _SetupBanner(shopId: shopId),
            const SizedBox(height: 16),
          ],
          // ── Menu du jour ──────────────────────────────────────────────
          // Remontée AVANT les indicateurs : c'est la seule carte de l'écran
          // sur laquelle on AGIT — les autres se lisent. En service, ce qu'on
          // veut d'abord c'est ajouter un plat, pas consulter un chiffre.
          _DailyMenuCard(shopId: shopId),
          const SizedBox(height: 16),
          // ── Bandeau principal : 4 indicateurs du service ──────────────
          _TopKpiRow(shopId: shopId, resto: resto, data: data, finance: finance),
          const SizedBox(height: 16),
          // ── Deux panneaux : commandes · ingrédients ────────────────────
          _ServiceRow(shopId: shopId, resto: resto),
          const SizedBox(height: 16),
          // ── Rapport financier ─────────────────────────────────────────
          _FinanceKpiRow(report: finance),
          const SizedBox(height: 16),
          _FoodCostCard(report: finance),
          const SizedBox(height: 16),
          _FinanceChartCard(report: finance),
          const SizedBox(height: 16),
          _SectorCard(report: finance),
          const SizedBox(height: 16),
          _TwoCol(
            first: _ChannelCard(resto: resto),
            second: _WeekChart(resto: resto),
          ),
          const SizedBox(height: 16),
          _TrendingCard(shopId: shopId, top: data.topProducts),
        ],
      ),
    );
  }
}

/// Bandeau principal : les 4 chiffres qu'on regarde en entrant en service.
///
/// Ventes de la période · commandes encore ouvertes · clients servis · stock
/// bas. Chaque tuile mène à l'écran qui permet d'agir dessus.
class _TopKpiRow extends ConsumerWidget {
  final String shopId;
  final RestaurantDashData resto;
  final DashData data;
  final RestaurantFinanceReport finance;

  const _TopKpiRow({
    required this.shopId,
    required this.resto,
    required this.data,
    required this.finance,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sem = Theme.of(context).semantic;
    final period = ref.watch(dashPeriodProvider);
    // QUATRE tuiles, pas cinq : à cinq, la dernière restait seule sur sa
    // deuxième ligne et la grille cassait. « Clients servis » est sorti — c'est
    // le seul des cinq qui n'appelle aucun geste et ne mène nulle part, là où
    // « Stock bas » passe en rouge et ouvre les finances.
    //
    // Chaque tuile porte un liseré vertical de sa NATURE : l'argent en vert,
    // le service en couleur de marque, la salle en bleu, l'alerte en ambre.
    final tiles = <Widget>[
      _StatCard(
        // Le libellé suit le sélecteur de période : annoncer « du jour » sur
        // une plage mensuelle serait un mensonge à l'écran.
        title: 'Ventes · ${_periodLabel(period)}',
        value: CurrencyFormatter.format(finance.revenue),
        stripe: sem.success,
        onTap: () => context.push('/shop/$shopId/caisse/orders'),
      ),
      _StatCard(
        title: 'Commandes en cours',
        value: resto.openCount.toString(),
        stripe: Theme.of(context).colorScheme.primary,
        icon: Icons.receipt_long_rounded,
        onTap: () => context.push('/shop/$shopId/caisse/orders'),
      ),
      // CAPACITÉ DE LA SALLE — places libres sur places totales.
      //
      // En PLACES et non en tables : une table de huit à moitié occupée n'est
      // ni libre ni pleine, et un compteur de tables masquerait justement les
      // chaises encore disponibles — celles qu'on cherche quand des clients
      // se présentent à l'entrée.
      _StatCard(
        title: 'Places libres',
        value: resto.freeSeats.toString(),
        stripe: sem.info,
        suffix: 'sur ${resto.totalSeats}',
        // Salle pleine : l'information vaut d'être vue de loin, c'est elle qui
        // décide si l'on fait patienter ou si l'on refuse.
        valueColor: resto.totalSeats > 0 && resto.freeSeats == 0
            ? sem.danger
            : null,
        icon: Icons.event_seat_outlined,
        onTap: () => context.push('/shop/$shopId/restaurant/tables'),
      ),
      _StatCard(
        title: 'Stock bas',
        value: resto.lowStockCount.toString(),
        stripe: sem.warning,
        suffix: resto.lowStockCount > 1 ? 'alertes' : 'alerte',
        valueColor: resto.lowStockCount > 0 ? sem.danger : null,
        icon: Icons.inventory_2_outlined,
        onTap: () => context.push('/shop/$shopId/restaurant/finances'),
      ),
    ];

    return LayoutBuilder(builder: (_, c) {
      final wide = c.maxWidth >= 760;
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: tiles.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: wide ? 4 : 2,
          childAspectRatio: wide ? 2.15 : 1.85,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemBuilder: (_, i) => tiles[i],
      );
    });
  }
}

/// Tuile d'indicateur : intitulé discret au-dessus, chiffre en grand dessous.
///
/// [stripe] est un liseré VERTICAL de 3 px sur le bord gauche, à la couleur de
/// la NATURE de l'indicateur — l'argent, le service, la salle, l'alerte. Une
/// seule tuile portait auparavant une barre horizontale sous elle, réservée aux
/// ventes : les quatre se distinguaient alors par leur seul intitulé, qu'il
/// fallait lire. Un liseré se reconnaît sans lire.
class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final String? suffix;
  final Color? valueColor;
  final IconData? icon;
  final Color? stripe;
  final VoidCallback? onTap;

  const _StatCard({
    required this.title,
    required this.value,
    this.suffix,
    this.valueColor,
    this.icon,
    this.stripe,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      // Le `Material` passe en transparent par-dessus : il ne sert qu'à porter
      // l'encre du toucher, sa couleur masquerait la surface.
      decoration: _cardSurface(context, radius: 14),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            children: [
              Padding(
                // Décalé à gauche de la largeur du liseré : sans ce retrait, le
                // texte le toucherait.
                padding: const EdgeInsets.fromLTRB(17, 14, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.bodySm.copyWith(
                                  color: cs.onSurface
                                      .withValues(alpha: 0.6))),
                        ),
                        if (icon != null)
                          Icon(icon,
                              size: 18,
                              color: cs.onSurface.withValues(alpha: 0.3)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(value,
                              maxLines: 1,
                              style: AppTextStyles.title.copyWith(
                                  color: valueColor ?? cs.onSurface,
                                  fontWeight: FontWeight.w800)),
                          if (suffix != null) ...[
                            const SizedBox(width: 5),
                            Text(suffix!,
                                style: AppTextStyles.bodySm.copyWith(
                                    color: valueColor ??
                                        cs.onSurface
                                            .withValues(alpha: 0.6))),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (stripe != null)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: stripe,
                      // Arrondi du même côté que la carte, sinon le liseré
                      // déborde de l'angle.
                      borderRadius: const BorderRadius.horizontal(
                          left: Radius.circular(14)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ligne de CONTEXTE : où l'on est, et à quel moment du service.
///
/// Pas de salutation ici, à dessein : la barre du haut en porte déjà une
/// (« Bienvenue, <prénom> 👋 »). Deux salutations à quelques pixels l'une de
/// l'autre, avec le même emoji, se répéteraient sans rien ajouter. La barre
/// salue la PERSONNE, ce bloc situe le LIEU et le MOMENT.
///
/// ─── LE SERVICE EST DÉDUIT DE L'HEURE ──────────────────────────────────────
///
/// L'application ne SAIT PAS dans quel service elle se trouve : il n'existe
/// aucune donnée d'horaires, et « service midi » n'apparaît nulle part ailleurs
/// que dans du texte libre saisi par l'utilisateur (motif de perte, note de
/// dépense). Les créneaux ci-dessous sont donc une CONVENTION de notre part,
/// pas une information du restaurant — un établissement de nuit la démentira.
///
/// Le jour où les horaires deviennent un réglage, c'est une colonne `shops`
/// qu'il faudra lire ici, jamais un `ShopSettingsStore` local.
class _Greeting extends StatelessWidget {
  final String shopId;

  const _Greeting({required this.shopId});

  /// Créneau de service, selon la convention documentée ci-dessus.
  static String _service(int hour) {
    if (hour >= 6 && hour < 11) return 'service du matin';
    if (hour >= 11 && hour < 15) return 'service du midi';
    if (hour >= 18 && hour < 24) return 'service du soir';
    return 'hors service';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hour = DateTime.now().hour;
    final shopName = LocalStorageService.getShop(shopId)?.name.trim() ?? '';

    // UNE seule ligne quand la boutique est nommée : « Chez Mado · service du
    // soir » se lit d'un trait. Deux lignes couperaient une phrase de cinq
    // mots. Sans nom de boutique, il ne reste que le créneau.
    //
    // Échelon `label` (14) pour le lieu : l'échelle typographique de l'app ne
    // compte pas de 15, et inventer une taille en dur pour un pixel d'écart
    // casserait la règle qui tient tout le reste.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: shopName.isEmpty
              ? Text(_service(hour),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.label.copyWith(color: cs.onSurface))
              : Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: shopName,
                        style: AppTextStyles.label
                            .copyWith(color: cs.onSurface)),
                    TextSpan(
                        text: ' · ${_service(hour)}',
                        style: AppTextStyles.caption),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
      ],
    );
  }
}

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
      if (c.maxWidth >= 700) {
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

    /// Couleur et icône par étape de service.
    (Color, IconData) look(int stage) => switch (stage) {
          2 => (sem.success, Icons.check_circle_outline_rounded),
          1 => (sem.warning, Icons.local_fire_department_outlined),
          _ => (cs.primary, Icons.schedule_rounded),
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
                                        .copyWith(color: look(o.stage).$1)),
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
            style: AppTextStyles.bodySm.copyWith(color: cs.primary)),
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
                        child: _DishAvatar(product: product),
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
                    color: available ? cs.primary : sem.danger)),
          ],
        ),
      ),
    );
  }
}

/// Contenu du cercle : la photo du plat, ou son INITIALE.
///
/// Un plat sans photo tombait sur le placeholder générique de
/// `ProductImageCard` — le même pour tous, ce qui rendait deux plats sans
/// photo indistinguables dans une rangée. L'initiale, elle, les sépare, et la
/// teinte dérivée du nom fait que le même plat garde la même couleur d'un
/// écran à l'autre.
class _DishAvatar extends StatelessWidget {
  final Product product;

  const _DishAvatar({required this.product});

  /// Teinte stable, dérivée du nom. `hashCode` suffit : on ne cherche pas une
  /// répartition parfaite, seulement qu'un plat garde SA couleur.
  Color _tint(BuildContext context) {
    final hue = (product.name.hashCode.abs() % 360).toDouble();
    final base = HSLColor.fromColor(Theme.of(context).colorScheme.primary);
    return HSLColor.fromAHSL(1, hue, 0.35, base.lightness).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final url = product.mainImageUrl;
    if (url != null && url.isNotEmpty) {
      return ProductImageCard(
        imageUrl: url,
        fillParent: true,
        borderRadius: BorderRadius.zero,
      );
    }
    final initial = product.name.trim().isEmpty
        ? '?'
        : product.name.trim().characters.first.toUpperCase();
    final tint = _tint(context);
    return ColoredBox(
      color: tint.withValues(alpha: 0.18),
      child: Center(
        child: Text(initial,
            style: AppTextStyles.subtitleBold.copyWith(color: tint)),
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
                                  i.isLowStock ? sem.danger : cs.onSurface)),
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

// ═══════════════════════════════════════════════════════════════════════
//  FINANCES (module finances — Lot 3)
// ═══════════════════════════════════════════════════════════════════════

/// Les quatre courbes du graphique finances — et les quatre KPI du bandeau.
enum _Curve { sales, profit, expense, loss }

extension _CurveX on _Curve {
  String get label => switch (this) {
        _Curve.sales => 'Ventes',
        _Curve.profit => 'Bénéfice',
        _Curve.expense => 'Dépenses',
        _Curve.loss => 'Pertes',
      };

  Color get color => switch (this) {
        _Curve.sales => RestoSeriesColors.sales,
        _Curve.profit => RestoSeriesColors.profit,
        _Curve.expense => RestoSeriesColors.expense,
        _Curve.loss => RestoSeriesColors.loss,
      };
}

/// Bandeau financier : ventes, bénéfice net, dépenses, pertes de la période.
///
/// Les couleurs sont celles des courbes du graphique juste en dessous : une
/// pastille verte ici = la courbe verte là.
///
/// BÉNÉFICE, DÉPENSES ET PERTES SONT MASQUÉS À L'OUVERTURE. Le tableau de bord
/// vit sur une tablette de salle, à portée de regard des clients et de toute
/// l'équipe ; ce que gagne l'établissement n'a pas à s'afficher en continu. Ils
/// se révèlent d'un geste, et se remasquent au prochain passage.
///
/// Les VENTES restent visibles : c'est l'indicateur de service, celui qu'on
/// consulte en salle, et il ne dit rien de la rentabilité.
class _FinanceKpiRow extends StatefulWidget {
  final RestaurantFinanceReport report;
  const _FinanceKpiRow({required this.report});

  @override
  State<_FinanceKpiRow> createState() => _FinanceKpiRowState();
}

class _FinanceKpiRowState extends State<_FinanceKpiRow> {
  /// Volontairement NON persisté : le masquage doit être l'état par défaut à
  /// chaque ouverture. Mémoriser « affiché » reviendrait à ne masquer qu'une
  /// fois, ce qui ne protège rien.
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final cs = Theme.of(context).colorScheme;
    final tiles = <Widget>[
      _FinanceTile(curve: _Curve.sales, amount: report.revenue),
      _FinanceTile(
        curve: _Curve.profit,
        amount: report.netProfit,
        // La marge brute contextualise le bénéfice : un bénéfice net faible
        // avec une marge brute élevée désigne les charges, pas la carte.
        hint: 'Marge brute ${report.marginRate.toStringAsFixed(0)} %',
        hidden: !_revealed,
        onTap: () => setState(() => _revealed = !_revealed),
      ),
      _FinanceTile(
        curve: _Curve.expense,
        amount: report.expenses,
        // « dont matières » suit la même règle que le bénéfice : les achats
        // réels dès qu'ils sont saisis, l'estimation des recettes sinon.
        hint: 'dont matières '
            '${CurrencyFormatter.format(report.foodCost)}'
            '${report.payroll > 0 ? ' · paie ${CurrencyFormatter.format(report.payroll.toDouble())}' : ''}',
        hidden: !_revealed,
        onTap: () => setState(() => _revealed = !_revealed),
      ),
      _FinanceTile(
        curve: _Curve.loss,
        amount: report.losses.toDouble(),
        hidden: !_revealed,
        onTap: () => setState(() => _revealed = !_revealed),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: Text(
                _revealed
                    ? 'Résultat financier'
                    : 'Résultat financier — masqué',
                style: AppTextStyles.bodySmBold
                    .copyWith(color: cs.onSurface.withValues(alpha: 0.7))),
          ),
          TextButton.icon(
            onPressed: () => setState(() => _revealed = !_revealed),
            icon: Icon(
                _revealed
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 16),
            label: Text(_revealed ? 'Masquer' : 'Afficher'),
          ),
        ]),
        const SizedBox(height: 4),
        LayoutBuilder(builder: (_, c) {
          final wide = c.maxWidth >= 760;
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: tiles.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: wide ? 4 : 2,
              childAspectRatio: wide ? 2.15 : 1.85,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemBuilder: (_, i) => tiles[i],
          );
        }),
      ],
    );
  }
}

/// Carte FOOD COST (Lot E) — l'indicateur de survie d'un restaurant.
///
/// Le food cost est la part du chiffre d'affaires qui repart en matières
/// premières. Au-delà de 35 %, la carte ne dégage plus assez pour couvrir le
/// loyer et les salaires : c'est le premier chiffre qu'un restaurateur doit
/// voir, avant même son bénéfice.
///
/// Deux mesures cohabitent, et leur ÉCART est le vrai signal :
///   * le THÉORIQUE vient des fiches recettes — ce que les plats vendus
///     auraient dû consommer ;
///   * le RÉEL vient des achats saisis — ce qui est réellement sorti.
/// Un réel durablement supérieur au théorique, c'est du gaspillage, du vol, ou
/// une fiche recette fausse.
class _FoodCostCard extends StatelessWidget {
  final RestaurantFinanceReport report;
  const _FoodCostCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final level = report.foodCostLevel;
    // Pas de vente sur la période : un taux sans chiffre d'affaires ne veut
    // rien dire, on n'affiche pas une pastille rouge trompeuse.
    if (level == null) return const SizedBox.shrink();

    final color = switch (level) {
      'good' => sem.success,
      'warning' => sem.warning,
      _ => sem.danger,
    };
    final rate = report.foodCostRate;

    return Container(
      padding: const EdgeInsets.all(14),
      // Arête haute teintée du NIVEAU de food cost : la carte s'annonce avant
      // d'être lue. Vert, orange ou rouge selon le seuil franchi.
      decoration: _cardSurface(context, radius: 14).copyWith(
        border: Border(
          top: BorderSide(color: color.withValues(alpha: 0.55), width: 2),
          left: BorderSide(color: restoGlassBorder(context), width: 0.5),
          right: BorderSide(color: restoGlassBorder(context), width: 0.5),
          bottom: BorderSide(color: restoGlassBorder(context), width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.restaurant_menu_rounded, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Food cost', style: AppTextStyles.bodyBold),
              ),
              Text('${rate.toStringAsFixed(1)} %',
                  style: AppTextStyles.title.copyWith(color: color)),
            ],
          ),
          const SizedBox(height: 6),
          // Barre de niveau : la position par rapport aux seuils se lit plus
          // vite qu'un pourcentage.
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (rate / 50).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: sem.trackMuted,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 6),
          Text(
              switch (level) {
                'good' => 'Sous les 30 % — bonne maîtrise des matières.',
                'warning' =>
                  'Entre 30 et 35 % — surveillez les portions et les pertes.',
                _ => 'Au-dessus de 35 % — la carte ne couvre plus ses charges.',
              },
              style: AppTextStyles.captionHint),
          const Divider(height: 20),
          Row(
            children: [
              Expanded(
                child: _FoodCostSide(
                  label: report.usesRealFoodCost ? 'Réel (achats)' : 'Estimé',
                  amount: report.foodCost,
                  rate: report.foodCostRate,
                  strong: true,
                ),
              ),
              if (report.usesRealFoodCost)
                Expanded(
                  child: _FoodCostSide(
                    label: 'Théorique (recettes)',
                    amount: report.materialCost,
                    rate: report.theoreticalFoodCostRate,
                  ),
                ),
            ],
          ),
          if (report.usesRealFoodCost && report.foodCostGap.abs() > 0) ...[
            const SizedBox(height: 6),
            Text(
                report.foodCostGap > 0
                    ? 'Vous avez acheté '
                        '${CurrencyFormatter.format(report.foodCostGap)} '
                        'de plus que ce que vos ventes ont consommé — stock '
                        'constitué, gaspillage ou fiche recette à revoir.'
                    : 'Vous avez consommé '
                        '${CurrencyFormatter.format(-report.foodCostGap)} '
                        'de plus que vos achats de la période — vous puisez '
                        'dans le stock existant.',
                style: AppTextStyles.caption.copyWith(
                    color: report.foodCostGap > 0 ? sem.warning : null)),
          ],
          if (!report.usesRealFoodCost) ...[
            const SizedBox(height: 6),
            Text(
                'Estimé d\'après vos fiches recettes. Saisissez vos achats '
                'dans Finances → Dépenses pour obtenir le coût réel.',
                style: AppTextStyles.captionHint),
          ],
        ],
      ),
    );
  }
}

/// Un côté de la comparaison food cost (réel / théorique).
class _FoodCostSide extends StatelessWidget {
  final String label;
  final double amount;
  final double rate;
  final bool strong;

  const _FoodCostSide({
    required this.label,
    required this.amount,
    required this.rate,
    this.strong = false,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.captionHint),
          Text(CurrencyFormatter.format(amount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  strong ? AppTextStyles.bodyBold : AppTextStyles.bodySmBold),
          Text('${rate.toStringAsFixed(1)} % du CA',
              style: AppTextStyles.micro),
        ],
      );
}

/// Tuile d'indicateur financier : pastille de couleur de courbe + montant.
class _FinanceTile extends StatelessWidget {
  final _Curve curve;
  final double amount;
  final String? hint;

  /// Montant remplacé par des points. La tuile garde sa place et son libellé :
  /// on doit voir QU'IL Y A un bénéfice à consulter, pas sa valeur.
  final bool hidden;

  /// Révèle au toucher — la tuile masquée est elle-même l'interrupteur, plus
  /// direct que de viser le bouton d'en-tête.
  final VoidCallback? onTap;

  const _FinanceTile({
    required this.curve,
    required this.amount,
    this.hint,
    this.hidden = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    // Un bénéfice négatif se lit en rouge : c'est l'information la plus
    // importante de l'écran, elle ne doit pas se fondre dans le violet.
    //
    // JAMAIS quand la tuile est masquée : la couleur trahirait ce que les
    // points cachent. Un rectangle rouge dit « vous perdez de l'argent » aussi
    // clairement que le montant lui-même.
    final negative = !hidden && curve == _Curve.profit && amount < 0;

    return Container(
      decoration: _cardSurface(context, radius: 14),
      child: Material(
        // Transparent : la couleur du Material masquerait la surface. Il ne
        // porte plus que l'encre du toucher.
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 6,
                height: 38,
                decoration: BoxDecoration(
                  color: negative
                      ? sem.danger
                      : (hidden
                          ? curve.color.withValues(alpha: 0.35)
                          : curve.color),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        hidden ? '••• •••' : CurrencyFormatter.format(amount),
                        maxLines: 1,
                        style: AppTextStyles.title.copyWith(
                          color: negative
                              ? sem.danger
                              : cs.onSurface.withValues(
                                  alpha: hidden ? 0.45 : 1),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // L'indice est masqué avec le montant : « Marge brute
                      // 62 % » et « dont matières 93 400 F » en disent autant
                      // que le chiffre principal.
                      hidden ? curve.label : (hint ?? curve.label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySm
                          .copyWith(color: cs.onSurface.withValues(alpha: 0.6)),
                    ),
                  ],
                ),
              ),
              if (hidden)
                Icon(Icons.visibility_outlined,
                    size: 15, color: cs.onSurface.withValues(alpha: 0.35)),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

/// Graphique financier à courbes activables.
///
/// Quatre courbes indépendantes (ventes · bénéfice · dépenses · pertes), une
/// puce par courbe, et un filtre par secteur d'activité.
///
/// **Vue par secteur** : charges fixes et pertes ne sont pas ventilables par
/// secteur (un loyer ne se découpe pas entre le bar et la cuisine). En vue
/// secteur, « Dépenses » ne compte donc que les matières et la courbe
/// « Pertes » est retirée — la légende le dit explicitement plutôt que
/// d'afficher une courbe globale sous une étiquette de secteur.
class _FinanceChartCard extends ConsumerStatefulWidget {
  final RestaurantFinanceReport report;
  const _FinanceChartCard({required this.report});

  @override
  ConsumerState<_FinanceChartCard> createState() => _FinanceChartCardState();
}

class _FinanceChartCardState extends ConsumerState<_FinanceChartCard> {
  final Set<_Curve> _on = {..._Curve.values};

  /// `null` = vue globale · `''` = ventes sans secteur · sinon un activityId.
  String? _sectorKey;

  /// Secteur sélectionné, ou `null` si vue globale — ou si le secteur choisi
  /// n'a plus de vente sur la nouvelle période (retour au global plutôt qu'un
  /// graphique vide sans explication).
  SectorLine? get _sector {
    final key = _sectorKey;
    if (key == null) return null;
    for (final s in widget.report.sectors) {
      if ((s.activityId ?? '') == key) return s;
    }
    return null;
  }

  /// Le filtre par secteur n'a de sens que si au moins une activité réelle a
  /// vendu : sinon la seule ligne serait « Sans secteur », égale au global.
  bool get _sectorsUsable =>
      widget.report.sectors.any((s) => s.activityId != null);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    final report = widget.report;
    final sector = _sector;
    final n = report.labels.length;
    final period = ref.watch(dashPeriodProvider);

    // Séries affichées : globales, ou celles du secteur sélectionné.
    final zero = List<double>.filled(n, 0);
    final sales = sector?.revenueSeries ?? report.revenueSeries;
    final expenses = sector?.costSeries ?? report.expenseSeries;
    final losses = sector == null ? report.lossSeries : zero;
    final profit = [
      for (var i = 0; i < n; i++) sales[i] - expenses[i] - losses[i],
    ];
    final series = {
      _Curve.sales: sales,
      _Curve.profit: profit,
      _Curve.expense: expenses,
      _Curve.loss: losses,
    };

    // En vue secteur, la courbe des pertes n'existe pas : on la retire au
    // lieu de tracer une ligne plate qui laisserait croire à zéro perte.
    final selectable = sector == null
        ? _Curve.values
        : [_Curve.sales, _Curve.profit, _Curve.expense];
    final shown = selectable.where(_on.contains).toList();

    return _Card(
      title: 'Finances',
      subtitle: sector == null
          ? _periodLabel(period)
          : '${sector.name} · ${_periodLabel(period)}',
      trailing: const PeriodSelector(mode: PeriodSelectorMode.inline),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_sectorsUsable) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Choice(
                  label: 'Global',
                  selected: _sectorKey == null,
                  onTap: () => setState(() => _sectorKey = null),
                ),
                for (final s in report.sectors)
                  _Choice(
                    label: s.name,
                    selected: _sectorKey == (s.activityId ?? ''),
                    onTap: () =>
                        setState(() => _sectorKey = s.activityId ?? ''),
                  ),
              ],
            ),
            const SizedBox(height: 14),
          ],

          // ── Puces de courbes + tout activer / désactiver ──────────────
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in selectable)
                      _CurveChip(
                        curve: c,
                        selected: _on.contains(c),
                        onTap: () => setState(() {
                          if (!_on.remove(c)) _on.add(c);
                        }),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() {
                  if (_on.length == _Curve.values.length) {
                    _on.clear();
                  } else {
                    _on.addAll(_Curve.values);
                  }
                }),
                child: Text(
                  _on.length == _Curve.values.length
                      ? 'Tout masquer'
                      : 'Tout afficher',
                  style: AppTextStyles.bodySm.copyWith(color: cs.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          if (report.isEmpty)
            const _EmptyBlock(
              icon: Icons.show_chart_rounded,
              message: 'Aucun mouvement financier sur cette période.',
            )
          else if (shown.isEmpty)
            const _EmptyBlock(
              icon: Icons.visibility_off_outlined,
              message: 'Toutes les courbes sont masquées.',
            )
          else
            SizedBox(
              height: 230,
              child: LineChart(_chartData(context, shown, series, report)),
            ),

          if (sector != null) ...[
            const SizedBox(height: 10),
            Text(
                'Vue secteur : « Dépenses » ne compte que les matières. '
                'Charges fixes et pertes ne sont pas ventilables par secteur.',
                style: AppTextStyles.micro.copyWith(color: sem.borderSubtle)),
          ],
        ],
      ),
    );
  }

  LineChartData _chartData(
    BuildContext context,
    List<_Curve> shown,
    Map<_Curve, List<double>> series,
    RestaurantFinanceReport report,
  ) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    final n = report.labels.length;

    // Bornes calculées sur les SEULES courbes affichées : masquer les ventes
    // doit re-zoomer sur ce qui reste, sinon les petites courbes s'écrasent.
    // Le zéro est toujours inclus — un bénéfice négatif doit se voir passer
    // sous l'axe.
    var lo = 0.0, hi = 0.0;
    for (final c in shown) {
      for (final v in series[c]!) {
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    if (lo == 0 && hi == 0) hi = 1;
    final pad = (hi - lo) * 0.12;
    final minY = lo - pad;
    final maxY = hi + pad;
    final yStep = ((maxY - minY) / 4).abs();

    // Au plus ~6 étiquettes en bas, sinon elles se chevauchent sur mobile.
    final xStep = (n / 6).ceil();

    return LineChartData(
      minY: minY,
      maxY: maxY,
      minX: 0,
      maxX: (n - 1).toDouble(),
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: yStep <= 0 ? null : yStep,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: sem.borderSubtle, strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 46,
            interval: yStep <= 0 ? null : yStep,
            getTitlesWidget: (v, _) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(_compact(v),
                  maxLines: 1, style: AppTextStyles.micro),
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 24,
            interval: 1,
            getTitlesWidget: (v, _) {
              final i = v.round();
              if (i < 0 || i >= n || i % xStep != 0) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Text(report.labels[i], style: AppTextStyles.micro),
              );
            },
          ),
        ),
      ),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => cs.onSurface,
          tooltipRoundedRadius: 8,
          getTooltipItems: (spots) => [
            for (final s in spots)
              LineTooltipItem(
                '${shown[s.barIndex].label} : '
                '${CurrencyFormatter.format(s.y)}',
                AppTextStyles.microBold.copyWith(color: cs.surface),
              ),
          ],
        ),
      ),
      lineBarsData: [
        for (final c in shown)
          LineChartBarData(
            spots: [
              for (var i = 0; i < n; i++)
                FlSpot(i.toDouble(), series[c]![i]),
            ],
            isCurved: true,
            curveSmoothness: 0.28,
            preventCurveOverShooting: true,
            color: c.color,
            barWidth: 2,
            dotData: const FlDotData(show: false),
          ),
      ],
    );
  }
}

/// Puce d'activation d'une courbe : pastille de couleur + libellé.
class _CurveChip extends StatelessWidget {
  final _Curve curve;
  final bool selected;
  final VoidCallback onTap;

  const _CurveChip({
    required this.curve,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? curve.color.withValues(alpha: 0.12)
              : sem.trackMuted,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? curve.color : sem.borderSubtle,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                // Puce éteinte : pastille creuse, la couleur reste lisible
                // sans prétendre que la courbe est tracée.
                color: selected ? curve.color : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(color: curve.color, width: 1.5),
              ),
            ),
            const SizedBox(width: 7),
            Text(curve.label,
                style: AppTextStyles.bodySm.copyWith(
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: selected ? 1 : 0.55),
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                )),
          ],
        ),
      ),
    );
  }
}

/// Puce de sélection simple (secteur).
class _Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.12)
              : sem.trackMuted,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? cs.primary : sem.borderSubtle,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(label,
            style: AppTextStyles.bodySm.copyWith(
              color: selected ? cs.primary : cs.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            )),
      ),
    );
  }
}

/// Résumé par secteur d'activité : ventes · matières · marge · taux.
///
/// S'efface complètement tant qu'aucune activité n'a vendu : une table à une
/// seule ligne « Sans secteur » ne dirait rien de plus que le bandeau du haut.
class _SectorCard extends StatelessWidget {
  final RestaurantFinanceReport report;
  const _SectorCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final sectors = report.sectors;
    if (!sectors.any((s) => s.activityId != null)) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final maxRevenue = sectors.fold<double>(
        0, (m, s) => s.revenue > m ? s.revenue : m);

    return _Card(
      title: 'Par secteur',
      subtitle: 'Ventes et marge brute de chaque activité',
      child: Column(
        children: [
          for (final s in sectors)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.bodyBold
                                .copyWith(color: cs.onSurface)),
                      ),
                      Text(CurrencyFormatter.format(s.revenue),
                          style: AppTextStyles.bodyBold
                              .copyWith(color: cs.onSurface)),
                    ],
                  ),
                  const SizedBox(height: 5),
                  // Barre de part relative : compare les secteurs d'un coup
                  // d'œil sans avoir à lire les montants.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: maxRevenue <= 0 ? 0 : s.revenue / maxRevenue,
                      minHeight: 6,
                      backgroundColor: Theme.of(context).semantic.trackMuted,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          RestoSeriesColors.sales),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                      'Matières ${CurrencyFormatter.format(s.materialCost)} · '
                      'Marge ${CurrencyFormatter.format(s.margin)} '
                      '(${s.marginRate.toStringAsFixed(0)} %)',
                      style: AppTextStyles.caption),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Montant compact pour l'axe vertical (12 500 → « 13k »).
String _compact(double v) {
  final a = v.abs();
  if (a >= 1000000) {
    return '${(v / 1000000).toStringAsFixed(a >= 10000000 ? 0 : 1)}M';
  }
  if (a >= 1000) return '${(v / 1000).toStringAsFixed(0)}k';
  return v.toStringAsFixed(0);
}

/// Répartition des commandes par canal de service, en anneau + légende.
class _ChannelCard extends ConsumerWidget {
  final RestaurantDashData resto;
  const _ChannelCard({required this.resto});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final period = ref.watch(dashPeriodProvider);

    final slices = <({String label, int count, Color color})>[
      (label: 'Salle', count: resto.dineIn, color: RestoTileColors.average),
      (
        label: 'À emporter',
        count: resto.takeaway,
        color: RestoTileColors.orders
      ),
      (
        label: 'Livraison',
        count: resto.delivery,
        color: RestoTileColors.expense
      ),
    ];

    return _Card(
      title: 'Répartition des commandes',
      subtitle: _periodLabel(period),
      // Sélecteur de période CANONIQUE de l'app (mode pastille) : il pilote
      // `dashPeriodProvider`, donc les tuiles du haut suivent le même choix
      // sans qu'on ait à recâbler quoi que ce soit.
      trailing: const PeriodSelector(mode: PeriodSelectorMode.inline),
      child: resto.totalOrders == 0
          ? const _EmptyBlock(
              icon: Icons.donut_large_rounded,
              message: 'Aucune commande encaissée sur cette période.',
            )
          : Row(
              children: [
                SizedBox(
                  width: 150,
                  height: 150,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(PieChartData(
                        sections: [
                          for (final s in slices)
                            if (s.count > 0)
                              PieChartSectionData(
                                value: s.count.toDouble(),
                                color: s.color,
                                radius: 26,
                                showTitle: false,
                              ),
                        ],
                        centerSpaceRadius: 46,
                        sectionsSpace: 3,
                        borderData: FlBorderData(show: false),
                        startDegreeOffset: -90,
                      )),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('${resto.totalOrders}',
                              style: AppTextStyles.display
                                  .copyWith(color: cs.onSurface)),
                          Text('commandes', style: AppTextStyles.micro),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final s in slices)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(
                            children: [
                              Container(
                                width: 13,
                                height: 13,
                                decoration: BoxDecoration(
                                  color: s.color,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(s.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.body
                                        .copyWith(color: cs.onSurface)),
                              ),
                              Text(
                                '${resto.pctOf(s.count).toStringAsFixed(0)}%',
                                style: AppTextStyles.bodyBold
                                    .copyWith(color: cs.onSurface),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text('sur ${resto.totalOrders} commandes encaissées',
                          style: AppTextStyles.micro
                              .copyWith(color: sem.borderSubtle)),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// Activité des 7 derniers jours, en barres, jour courant mis en avant.
class _WeekChart extends StatelessWidget {
  final RestaurantDashData resto;
  const _WeekChart({required this.resto});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final counts = resto.ordersByWeekday;
    final maxVal = counts.fold<int>(0, (m, v) => v > m ? v : m);
    final todayIdx = (DateTime.now().weekday - 1) % 7;
    // clamp() sur un double renvoie  — cast explicite requis par les
    // paramètres  de fl_chart, typés double.
    final step = (maxVal / 4).ceilToDouble().clamp(1.0, double.infinity);

    return _Card(
      title: 'Activité de la semaine',
      // Pastille SANS chevron : la fenêtre est fixe à 7 jours (un histogramme
      // par jour de semaine n'a pas de sens au-delà), donc pas de faux
      // contrôle qui laisserait croire à un choix.
      trailing: const RestoPeriodPill(label: '7 jours'),
      child: maxVal == 0
          ? const _EmptyBlock(
              icon: Icons.bar_chart_rounded,
              message: 'Aucune commande sur les 7 derniers jours.',
            )
          : SizedBox(
              height: 196,
              child: BarChart(BarChartData(
                // Marge haute généreuse : la valeur est affichée AU-DESSUS
                // de la barre du jour, elle ne doit pas être tronquée.
                maxY: (maxVal * 1.32).ceilToDouble(),
                alignment: BarChartAlignment.spaceAround,
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      interval: step,
                      getTitlesWidget: (v, _) => Text(
                        v.toInt().toString(),
                        style: AppTextStyles.micro,
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= kWeekdayLabels.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Text(
                            kWeekdayLabels[i],
                            style: i == todayIdx
                                ? AppTextStyles.bodySmBold
                                    .copyWith(color: cs.onSurface)
                                : AppTextStyles.bodySm,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => cs.onSurface,
                    tooltipRoundedRadius: 8,
                    getTooltipItem: (g, gi, rod, ri) => BarTooltipItem(
                      '${rod.toY.toInt()} commande'
                      '${rod.toY.toInt() > 1 ? 's' : ''}',
                      AppTextStyles.microBold.copyWith(color: cs.surface),
                    ),
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < counts.length; i++)
                    BarChartGroupData(x: i, barRods: [
                      BarChartRodData(
                        toY: counts[i].toDouble(),
                        color: i == todayIdx
                            ? RestoTileColors.revenue
                            : sem.trackMuted,
                        width: 17,
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ], showingTooltipIndicators: i == todayIdx ? [0] : []),
                ],
              )),
            ),
    );
  }
}

/// Plats les plus vendus, en carrousel avec flèches.
class _TrendingCard extends StatefulWidget {
  final String shopId;
  final List<TopProd> top;

  const _TrendingCard({required this.shopId, required this.top});

  @override
  State<_TrendingCard> createState() => _TrendingCardState();
}

class _TrendingCardState extends State<_TrendingCard> {
  final _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Défile d'une carte entière (largeur + gouttière).
  void _scroll(int direction) {
    if (!_ctrl.hasClients) return;
    final target = (_ctrl.offset + direction * 236)
        .clamp(0.0, _ctrl.position.maxScrollExtent);
    _ctrl.animateTo(target,
        duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final top = widget.top;

    return _Card(
      title: 'Plats qui marchent',
      trailing: top.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ArrowBtn(
                    icon: Icons.chevron_left_rounded,
                    onTap: () => _scroll(-1)),
                const SizedBox(width: 6),
                _ArrowBtn(
                    icon: Icons.chevron_right_rounded,
                    onTap: () => _scroll(1)),
              ],
            ),
      child: top.isEmpty
          ? const _EmptyBlock(
              icon: Icons.restaurant_rounded,
              message: 'Aucune vente sur cette période.',
            )
          : SizedBox(
              height: 208,
              child: ListView.separated(
                controller: _ctrl,
                scrollDirection: Axis.horizontal,
                itemCount: top.length,
                separatorBuilder: (_, __) => const SizedBox(width: 14),
                itemBuilder: (_, i) {
                  final p = top[i];
                  return Container(
                    width: 222,
                    decoration: BoxDecoration(
                      color: restoGlassInner(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: sem.borderSubtle),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 150,
                          width: double.infinity,
                          child: ProductImageCard(
                            imageUrl: p.imageUrl,
                            fillParent: true,
                            borderRadius: BorderRadius.zero,
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 11),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.bodySm
                                        .copyWith(color: cs.onSurface),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Vendus : ${p.qty}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.bodySmBold
                                      .copyWith(color: cs.onSurface),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// Bouton rond de défilement du carrousel.
class _ArrowBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ArrowBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.semantic.trackMuted,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 20, color: theme.colorScheme.onSurface),
        ),
      ),
    );
  }
}

/// Carte de section — titre, sous-titre, contrôle à droite.
class _Card extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  const _Card({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _cardSurface(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: AppTextStyles.subtitleBold
                            .copyWith(color: theme.colorScheme.onSurface)),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle!,
                            style: AppTextStyles.bodySmSecondary),
                      ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// État vide d'une carte : UNE LIGNE, icône et phrase côte à côte.
///
/// Il occupait 150 px de haut, centré — la hauteur d'une carte pleine pour
/// dire qu'il n'y a rien. Sur un restaurant qui démarre, sept cartes dans cet
/// état donnaient quatre écrans de vide à faire défiler avant d'atteindre quoi
/// que ce soit.
///
/// La hauteur constante était justifiée par « la page ne saute pas au
/// chargement ». Elle saute de toute façon : les cartes pleines n'ont pas cette
/// hauteur-là. Autant que le vide coûte ce qu'il vaut.
///
/// L'action éventuelle ne vit PAS ici : elle reste dans l'en-tête de la carte,
/// en pastille compacte (cf. « Ajouter » du stock d'ingrédients) — un bouton
/// sous une ligne de texte rendrait au bloc la hauteur qu'on vient de lui
/// retirer.
class _EmptyBlock extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyBlock({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 19, color: cs.onSurface.withValues(alpha: 0.35)),
        const SizedBox(width: 9),
        Expanded(
          child: Text(message, style: AppTextStyles.bodySmSecondary),
        ),
      ],
    );
  }
}

/// Surface d'une carte du tableau de bord.
///
/// Translucide, bordure de 0,5 px, arrondi 17 — posée sur le motif du fond
/// sans le masquer. Elle remplace le relief à trois ombres, qui avait été
/// dessiné pour se détacher d'une PHOTO : le fond en dégradé et formes douces
/// n'a plus besoin qu'on crie par-dessus.
///
/// PAS de flou d'arrière-plan, et c'est délibéré : cet écran porte huit cartes
/// à la fois, et `RestoGlassPanel` documente déjà que le `BackdropFilter` coûte
/// cher sur le web dès qu'il se répète. La translucidité du remplissage suffit
/// à laisser deviner le motif.
BoxDecoration _cardSurface(BuildContext context, {double radius = 17}) =>
    BoxDecoration(
      color: restoGlassFill(context),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: restoGlassBorder(context), width: 0.5),
    );

/// Deux cartes côte à côte sur large écran, empilées sinon.
class _TwoCol extends StatelessWidget {
  final Widget first;
  final Widget second;

  const _TwoCol({required this.first, required this.second});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (_, c) => c.maxWidth >= 860
            ? IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: first),
                    const SizedBox(width: 16),
                    Expanded(child: second),
                  ],
                ),
              )
            : Column(
                children: [first, const SizedBox(height: 16), second],
              ),
      );
}

/// Libellé long de la période, affiché en sous-titre.
String _periodLabel(DashPeriod p) => switch (p) {
      DashPeriod.today     => 'Aujourd\'hui',
      DashPeriod.yesterday => 'Hier',
      DashPeriod.week      => 'Cette semaine',
      DashPeriod.month     => 'Ce mois-ci',
      DashPeriod.quarter   => 'Ce trimestre',
      DashPeriod.year      => 'Cette année',
      DashPeriod.custom    => 'Période personnalisée',
    };

/// Bannière de configuration incomplète.
///
/// Elle disparaît d'elle-même une fois les deux étapes faites — l'état est
/// recalculé depuis Hive à chaque rendu, il n'y a rien à « fermer » ni à
/// marquer comme vu.
class _SetupBanner extends StatelessWidget {
  final String shopId;
  const _SetupBanner({required this.shopId});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final step = RestaurantSetupService.stepFor(shopId);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sem.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sem.warning.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        Icon(Icons.rocket_launch_outlined, size: 20, color: sem.warning),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Votre restaurant n\'est pas encore configuré',
                  style:
                      AppTextStyles.bodySmBold.copyWith(color: cs.onSurface)),
              Text(
                  switch (step) {
                    RestaurantSetupStep.needsTable =>
                      'Étape 1 sur 3 — créez votre première table.',
                    RestaurantSetupStep.needsMenuItem =>
                      'Étape 2 sur 3 — créez un plat avec au moins un '
                          'ingrédient.',
                    _ => 'Étape 3 sur 3 — enregistrez ce que vous avez payé '
                        'vos ingrédients.',
                  },
                  style: AppTextStyles.caption),
            ],
          ),
        ),
        const SizedBox(width: 10),
        FilledButton(
          onPressed: () => context.go('/shop/$shopId/restaurant/setup'),
          style: FilledButton.styleFrom(
            backgroundColor: sem.warning,
            minimumSize: const Size(0, 38),
          ),
          child: const Text('Configurer'),
        ),
      ]),
    );
  }
}
