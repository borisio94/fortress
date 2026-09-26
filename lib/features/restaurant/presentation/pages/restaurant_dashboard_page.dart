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
import '../../../../core/services/staff_score_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../../caisse/presentation/bloc/caisse_bloc.dart';
import '../../../dashboard/data/dashboard_providers.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../data/restaurant_dashboard_providers.dart';
import '../../domain/margin_window.dart';
import '../../domain/entities/staff_rating.dart';
import '../widgets/resto_dish_visuals.dart';
import '../widgets/resto_kpi_tile.dart';
import '../widgets/resto_period_sheet.dart';
import '../widgets/resto_surfaces.dart';
import '../widgets/resto_table_listener.dart';
import '../widgets/staff_score_gauge.dart';

part 'restaurant_dashboard_page.service.dart';
part 'restaurant_dashboard_page.finances.dart';
part 'restaurant_dashboard_page.activity.dart';

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
    // La période choisie décide si une marge a un sens — cf. `margin_window`.
    //
    // LA PÉRIODE LIBRE SE JUGE SUR SES VRAIES DATES. `rangeFor(custom)` sans
    // bornes rend « aujourd'hui » : une période libre de trois mois était donc
    // jugée à un jour, et ses marges ne s'affichaient jamais.
    final period = ref.watch(dashPeriodProvider);
    final custom = ref.watch(dashCustomRangeProvider);
    final showsMargins = marginsMakeSenseOn(
        period,
        period == DashPeriod.custom && custom != null
            ? rangeFor(period, customFrom: custom.from, customTo: custom.to)
            : rangeFor(period));

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
          //
          // LE SÉLECTEUR DE PÉRIODE VIT ICI, SEUL. Il y en avait un par carte
          // (Finances, Répartition) alors qu'ils pilotaient tous le même
          // provider : changer l'un changeait les autres sans le dire. Un seul
          // bouton, en tête, dit que le choix vaut pour toute la page.
          _Greeting(shopId: shopId),
          // L'explication suit le sélecteur qui la provoque, au lieu d'arriver
          // au milieu de la page, loin des chiffres qu'elle explique.
          if (!showsMargins) ...[
            const SizedBox(height: 10),
            const _MarginsUnavailableCard(),
          ],
          const SizedBox(height: 16),
          // ── Configuration incomplète ──────────────────────────────────
          // CETTE BANNIÈRE EST LE CHEMIN, pas un filet de sécurité. Elle a
          // longtemps été décrite comme couvrant « le cas où l'on atteint le
          // tableau de bord par un chemin qui n'est pas gardé », le routeur
          // étant censé rediriger — il ne redirige plus, et à dessein
          // (`app_router.dart`, `_restaurantGuard` : l'accompagnement PROPOSE
          // au lieu d'imposer). Il n'existe aucune entrée « Configuration » au
          // menu : cette bannière et la carte de progression de l'écran Menu
          // sont les deux seules façons de trouver `/restaurant/setup`.
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
          // ── Notation de l'équipe ──────────────────────────────────────
          // Placée AVANT les chiffres financiers, et non reléguée en bas : un
          // serveur à 4 sur 10 coûte plus cher au restaurant qu'un point de
          // marge, et c'est la seule information de cet écran sur laquelle on
          // peut agir le soir même.
          _StaffScoreCard(shopId: shopId),
          const SizedBox(height: 16),
          // ── Rapport financier ─────────────────────────────────────────
          //
          // LES MARGES NE S'AFFICHENT QUE SUR UN MOIS OU PLUS. Les achats
          // d'une période se répartissent sur ses ventes : sur trois jours,
          // un marché du lundi écrase le taux et le mardi le remet à zéro.
          // Le chiffre existait, il ne mesurait rien. Cf.
          // `margin_window.dart` et la section 6 de la définition.
          //
          // LES VOLUMES RESTENT, eux, sur toutes les périodes — ventes,
          // commandes, pertes. « Hier » sert tous les matins.
          //
          // Sans marge, rien ne s'affiche ici : l'explication est montée dans
          // l'en-tête, sous le sélecteur.
          if (showsMargins) ...[
            _FinanceKpiRow(report: finance),
            const SizedBox(height: 16),
            _FoodCostCard(report: finance),
            const SizedBox(height: 16),
          ],
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
            ? sem.dangerText
            : null,
        icon: Icons.event_seat_outlined,
        onTap: () => context.push('/shop/$shopId/restaurant/tables'),
      ),
      _StatCard(
        title: 'Stock bas',
        value: resto.lowStockCount.toString(),
        stripe: sem.warning,
        suffix: resto.lowStockCount > 1 ? 'alertes' : 'alerte',
        valueColor: resto.lowStockCount > 0 ? sem.dangerText : null,
        icon: Icons.inventory_2_outlined,
        onTap: () => context.push('/shop/$shopId/restaurant/finances'),
      ),
    ];

    return LayoutBuilder(builder: (_, c) {
      final wide = c.maxWidth >= kRestoKpiFourColumnsMin;
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
      decoration: restoCardSurface(context, radius: 14),
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
        const SizedBox(width: 12),
        const RestoPeriodButton(),
      ],
    );
  }
}

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
      decoration: restoCardSurface(context),
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

/// SEUILS DE CONTENU du tableau de bord (document de design § 8). Chacun lit
/// la largeur de son CONTENEUR (`LayoutBuilder`), jamais l'écran, et dit ce
/// qu'il garantit au-dessus. Ce ne sont pas des seuils d'écran : ceux-là sont
/// les trois officiels (600, 720, 900).
///
/// Tuiles d'indicateurs (ventes et finances) : QUATRE colonnes à partir de
/// 760 px, soit des tuiles d'au moins 181 px — (760 − 3 × 12 d'écart) / 4 ;
/// deux en dessous.
const double kRestoKpiFourColumnsMin = 760;

/// Rangée Service : « Commandes en cours » (3) et « Stock » (2) CÔTE À CÔTE à
/// partir de 700 px — au moins 410 px pour la liste des commandes et 274 pour
/// le stock, une fois les 16 px d'écart retirés ; empilées en dessous.
const double kRestoServiceRowSideBySideMin = 700;

/// Paire de cartes (`_TwoCol` : canaux de service, semaine) CÔTE À CÔTE à
/// partir de 860 px — au moins 422 px chacune, l'anneau et sa légende n'y
/// tiennent pas plus étroits ; empilées en dessous.
const double kRestoCardPairSideBySideMin = 860;

/// Deux cartes côte à côte sur un conteneur large, empilées sinon
/// (cf. [kRestoCardPairSideBySideMin]).
class _TwoCol extends StatelessWidget {
  final Widget first;
  final Widget second;

  const _TwoCol({required this.first, required this.second});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (_, c) => c.maxWidth >= kRestoCardPairSideBySideMin
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
///
/// Il dit la fenêtre RÉELLE (`rangeFor`) : « Cette semaine » et « Cette
/// année » annonçaient des fenêtres calendaires qui sont en fait glissantes.
String _periodLabel(DashPeriod p) => switch (p) {
      DashPeriod.today     => 'Aujourd\'hui',
      DashPeriod.yesterday => 'Hier',
      DashPeriod.week      => '7 derniers jours',
      DashPeriod.month     => 'Ce mois-ci',
      DashPeriod.quarter   => '90 derniers jours',
      DashPeriod.year      => '12 derniers mois',
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
