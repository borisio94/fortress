part of 'restaurant_menu_page.dart';

// L'en-tête de la carte : titre, recherche, catégories, bandeaux.

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
                style: AppTextStyles.caption.copyWith(color: Theme.of(context).semantic.brandText),
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
