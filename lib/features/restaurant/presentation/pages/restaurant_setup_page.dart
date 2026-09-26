import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/restaurant_mode.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/restaurant_setup_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../features/subscription/presentation/widgets/product_quota_guard.dart';
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
///
/// ─── QUI PEUT FAIRE QUOI ───────────────────────────────────────────────────
///
/// Cet écran ENCHAÎNE des gestes qui, partout ailleurs, sont gardés : composer
/// la carte l'est sur l'écran Menu (`canAddProduct`), enregistrer un achat l'est
/// au hub Finances. Rassemblés ici sans garde, ils rouvraient en grand ce que
/// ces deux écrans ferment : un serveur créait un plat, fixait son prix, et
/// inscrivait une dépense dans la comptabilité de l'établissement.
///
/// La page reste OUVERTE à tout membre — elle dit où en est l'établissement,
/// et c'est une information de service. Ce sont les ÉTAPES qui portent les
/// droits. Même parti pris que l'écran Menu : la porte est ouverte, les gestes
/// sont gardés.
///
/// Les permissions sont celles des écrans d'origine, jamais `isShopAdmin` : un
/// employé à qui le gérant a délégué `inventoryWrite` compose la carte ici
/// comme il la compose au Menu. Un droit accordé ne doit pas dépendre de
/// l'écran par lequel on passe.
class RestaurantSetupPage extends ConsumerStatefulWidget {
  final String shopId;
  const RestaurantSetupPage({super.key, required this.shopId});

  @override
  ConsumerState<RestaurantSetupPage> createState() =>
      _RestaurantSetupPageState();
}

class _RestaurantSetupPageState extends ConsumerState<RestaurantSetupPage> {
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
    // Filet, en plus du bouton qui n'est pas rendu : une méthode de State
    // reste appelable autrement que par son bouton (évolution du rendu,
    // raccourci, appel direct). La règle vit donc AUSSI au plus près du geste
    // — c'est ce qui manquait ici.
    if (!RestaurantSetupStep.needsMenuItem
        .allowedFor(ref.read(permissionsProvider(widget.shopId)))) {
      return;
    }
    // Le plafond de l'abonnement, comme à l'écran Menu : ce parcours crée un
    // produit, il ne peut pas être la porte de sortie du quota. Toujours le
    // premier plat ici, mais l'écran reste atteignable après coup — supprimer
    // sa dernière table y ramène un établissement déjà rempli.
    if (!ProductQuotaGuard.ensureCanAdd(context,
        plan: ref.read(currentPlanProvider),
        shopId: widget.shopId,
        label: ProductQuotaGuard.dishesLabel)) {
      return;
    }
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
    // Même filet que `_addDish` : une dépense engage la comptabilité de
    // l'établissement, elle ne doit pas dépendre du seul rendu d'un bouton.
    if (!RestaurantSetupStep.needsIngredientCost
        .allowedFor(ref.read(permissionsProvider(widget.shopId)))) {
      return;
    }
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
    // Droits des étapes : définis une seule fois, à côté du calcul du parcours
    // (cf. `RestaurantSetupStep.allowedFor`).
    final perms = ref.watch(permissionsProvider(widget.shopId));
    final canComposeMenu =
        RestaurantSetupStep.needsMenuItem.allowedFor(perms);
    final canRecordCosts =
        RestaurantSetupStep.needsIngredientCost.allowedFor(perms);

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
          // Étape 1 volontairement ouverte à tout membre — le pourquoi est
          // dans `RestaurantSetupStep.allowedFor`, avec les deux autres.
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
            lockedNote: canComposeMenu
                ? null
                : 'Réservé au gérant : c\'est lui qui compose la carte et '
                    'fixe les prix.',
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
            lockedNote: canRecordCosts
                ? null
                : 'Réservé au gérant : lui seul enregistre ce que les '
                    'ingrédients ont coûté.',
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

  /// Renseigné = l'utilisateur n'a pas le droit de faire cette étape. Le
  /// bouton cède alors la place à cette phrase.
  ///
  /// Une PHRASE et pas un bouton grisé : une option désactivée invite à
  /// demander pourquoi elle l'est, alors qu'elle ne le dira jamais. L'étape,
  /// elle, reste affichée — un serveur doit pouvoir lire où en est
  /// l'établissement, et la masquer ferait mentir le « 3 étapes » que deux
  /// personnes doivent lire à l'identique.
  final String? lockedNote;

  const _SetupStepCard({
    required this.rank,
    required this.title,
    required this.description,
    required this.done,
    required this.active,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
    this.lockedNote,
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
                      // L'étape active s'écrit en `onSurface` : la primaire en
                      // texte, sur sa propre teinte, échoue dans les deux modes.
                      style: AppTextStyles.bodyBold.copyWith(
                          color: active ? cs.onSurface : accent)),
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
                      AppTextStyles.caption.copyWith(color: sem.successText)),
          ]),
          const SizedBox(height: 8),
          Text(description, style: AppTextStyles.caption),
          if (active) ...[
            const SizedBox(height: 14),
            if (lockedNote == null)
              AppPrimaryButton(
                label: actionLabel,
                icon: actionIcon,
                fullWidth: true,
                onTap: onAction,
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline_rounded,
                      size: 15, color: cs.onSurfaceVariant),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(lockedNote!,
                        style: AppTextStyles.caption
                            .copyWith(color: cs.onSurfaceVariant)),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}
