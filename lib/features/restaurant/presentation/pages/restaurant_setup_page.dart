import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/restaurant_mode.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/restaurant_setup_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../widgets/dish_form_sheet.dart';
import '../widgets/ingredient_cost_sheet.dart';
import '../widgets/resto_surfaces.dart';

/// MISE EN ROUTE D'UN RESTAURANT — trois étapes, dans l'ordre.
///
/// Un restaurant fraîchement créé n'a ni salle ni carte. Lui ouvrir les huit
/// écrans du module, tous vides, revient à lui demander de deviner par où
/// commencer — et les premiers écrans consultés (tableau de bord, finances)
/// sont justement ceux qui ne peuvent rien afficher tant que rien n'est saisi.
///
/// L'étape est RECALCULÉE à chaque rendu depuis Hive (cf.
/// [RestaurantSetupService]) : aucun drapeau à maintenir, donc aucun risque
/// qu'elle mente. Supprimer sa dernière table ramène ici.
class RestaurantSetupPage extends StatefulWidget {
  final String shopId;
  const RestaurantSetupPage({super.key, required this.shopId});

  @override
  State<RestaurantSetupPage> createState() => _RestaurantSetupPageState();
}

class _RestaurantSetupPageState extends State<RestaurantSetupPage> {
  late final OnDataChanged _listener;

  @override
  void initState() {
    super.initState();
    // Les données peuvent arriver d'un AUTRE appareil : le gérant crée ses
    // tables au bureau pendant que le serveur regarde cet écran en salle.
    _listener = (table, sid) {
      if (!mounted) return;
      if (table != 'restaurant_tables' &&
          table != 'products' &&
          table != 'recipe_ingredients' &&
          table != 'ingredients' &&
          table != 'daily_expenses') return;
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

  /// Renvoie au Plan de salle : les tables s'y créent, et nulle part ailleurs.
  ///
  /// `push` et non `go` — l'écran de mise en route reste dessous, et l'étape
  /// se coche au retour (le listener `restaurant_tables` redéclenche le
  /// rendu).
  void _addTable() =>
      context.push('/shop/${widget.shopId}/restaurant/tables');

  Future<void> _addDish() async {
    // `requireIngredient` n'est posé QUE sur ce parcours : ailleurs, un plat
    // sans ingrédient est parfaitement légitime (une bière, une bouteille
    // d'eau). L'exiger partout rendrait ces articles impossibles à créer.
    final saved = await showDishForm(
      context: context,
      shopId: widget.shopId,
      requireIngredient: true,
    );
    if (saved != true || !mounted) return;
    setState(() {});
    _finishIfComplete();
  }

  Future<void> _recordCosts() async {
    final pending =
        RestaurantSetupService.ingredientsWithoutCost(widget.shopId);
    if (pending.isEmpty) return;
    final done = await showIngredientCostSheet(
      context: context,
      shopId: widget.shopId,
      ingredients: pending,
    );
    if (done == null || !mounted) return;
    setState(() {});
    if (done > 0) {
      AppSnack.success(context, '$done achat(s) enregistré(s)');
    }
    _finishIfComplete();
  }

  /// Configuration terminée : on rend la main sur l'écran d'accueil du
  /// restaurant plutôt que de laisser l'utilisateur sur un stepper tout vert.
  void _finishIfComplete() {
    if (!mounted) return;
    if (RestaurantSetupService.stepFor(widget.shopId).isComplete) {
      context.go(shopLandingRoute(widget.shopId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = RestaurantSetupService.stepFor(widget.shopId);
    final tableDone = step != RestaurantSetupStep.needsTable;
    final dishDone = tableDone && step != RestaurantSetupStep.needsMenuItem;
    final pendingCosts =
        RestaurantSetupService.ingredientsWithoutCost(widget.shopId);

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Configuration',
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          // En-tête sur panneau, comme tout texte du module : écrit à nu, il
          // reposait sur la photo de salle et changeait de lisibilité selon la
          // zone de l'image (cf. la règle sur `restoGlassFill`).
          RestoGlassPanel(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Trois étapes pour ouvrir votre restaurant',
                    style: AppTextStyles.title),
                const SizedBox(height: 6),
                Text(
                    'Le reste de l\'application s\'ouvrira une fois ces trois '
                    'points faits — sans eux, la caisse et les finances '
                    'n\'auraient rien à afficher.',
                    style: AppTextStyles.captionHint),
              ],
            ),
          ),
          const SizedBox(height: 22),
          _SetupStepCard(
            rank: 1,
            title: 'Créer une table',
            description:
                'Votre plan de salle. Une seule suffit pour commencer — vous '
                'en ajouterez d\'autres au fur et à mesure.',
            done: tableDone,
            active: !tableDone,
            actionLabel: 'Ouvrir le plan de salle',
            actionIcon: Icons.table_restaurant_outlined,
            onAction: _addTable,
          ),
          const SizedBox(height: 12),
          _SetupStepCard(
            rank: 2,
            title: 'Créer un plat',
            description: tableDone
                ? 'Un plat de votre carte, avec au moins un ingrédient coché. '
                    'C\'est ce lien qui permettra de connaître son coût et '
                    'votre marge.'
                : 'Disponible après la première étape.',
            done: dishDone,
            active: tableDone && !dishDone,
            actionLabel: 'Créer mon premier plat',
            actionIcon: Icons.restaurant_menu_rounded,
            onAction: _addDish,
          ),
          const SizedBox(height: 12),
          _SetupStepCard(
            rank: 3,
            title: 'Enregistrer vos achats',
            description: dishDone
                ? 'Combien avez-vous payé vos ingrédients ? Sans ce montant, '
                    'vos plats coûtent 0 F et la marge affichée est fausse.'
                : 'Disponible après la deuxième étape.',
            done: step.isComplete,
            active: dishDone && !step.isComplete,
            actionLabel: pendingCosts.length > 1
                ? 'Renseigner mes ${pendingCosts.length} ingrédients'
                : 'Renseigner mon achat',
            actionIcon: Icons.receipt_long_outlined,
            onAction: _recordCosts,
          ),
        ],
      ),
    );
  }
}

/// Une étape du stepper : rang, état, et action quand elle est active.
class _SetupStepCard extends StatelessWidget {
  final int rank;
  final String title;
  final String description;
  final bool done;
  final bool active;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onAction;

  const _SetupStepCard({
    required this.rank,
    required this.title,
    required this.description,
    required this.done,
    required this.active,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    // Trois états visuels distincts : fait (vert), à faire maintenant
    // (accentué), pas encore accessible (atténué). Sans cette distinction, un
    // utilisateur tape sur l'étape 2 et ne comprend pas pourquoi rien ne bouge.
    final accent = done ? sem.success : (active ? cs.primary : sem.borderSubtle);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: accent.withValues(alpha: active ? 1 : 0.4),
            width: active ? 2 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: done ? sem.success : accent.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: done
                  ? const Icon(Icons.check_rounded, size: 18,
                      color: Colors.white)
                  : Text('$rank',
                      style: AppTextStyles.bodyBold.copyWith(color: accent)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title,
                  style: AppTextStyles.bodyBold.copyWith(
                      color: active || done
                          ? cs.onSurface
                          : cs.onSurface.withValues(alpha: 0.5))),
            ),
            if (done)
              Text('Fait',
                  style:
                      AppTextStyles.caption.copyWith(color: sem.success)),
          ]),
          const SizedBox(height: 8),
          Text(description, style: AppTextStyles.caption),
          if (active) ...[
            const SizedBox(height: 14),
            AppPrimaryButton(
              label: actionLabel,
              icon: actionIcon,
              fullWidth: true,
              onTap: onAction,
            ),
          ],
        ],
      ),
    );
  }
}
