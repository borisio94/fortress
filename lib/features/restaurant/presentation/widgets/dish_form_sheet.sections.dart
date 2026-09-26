part of 'dish_form_sheet.dart';

// Les SECTIONS de la fiche plat : des widgets sans état, qui reçoivent leurs
// valeurs et rendent la main par des rappels. L'état (brouillon, contrôleurs,
// enregistrement) reste dans `_DishFormSheetState` ; ces classes n'en lisent
// rien d'autre que ce qu'on leur passe.
//
// Extraites de l'état de la fiche le 26/09/2026 (lot « classes géantes »),
// sous le banc `test/widget/dish_form_sheet_test.dart`.

/// Vignette photo — carré de [_kPhotoTile], bordure pointillée quand elle est
/// vide.
///
/// Elle occupait 190 px de large sur 210 de haut, soit le tiers de la feuille
/// pour un ornement facultatif : le prix, lui, arrivait sous la ligne de
/// flottaison. Réduite à une vignette, elle laisse la place aux deux champs
/// obligatoires.
///
/// Le POINTILLÉ dit « à remplir » sans écrire un mot de plus — un trait plein
/// se lit comme un cadre vide, et c'est ainsi que la photo passait pour une
/// image qui n'a pas chargé.
class _DishPhotoTile extends StatelessWidget {
  /// Photo choisie dans cette saisie, pas encore envoyée.
  final Uint8List? imageBytes;

  /// Photo déjà en ligne (plat en édition).
  final String? existingImageUrl;
  final VoidCallback onTap;

  const _DishPhotoTile({
    required this.imageBytes,
    required this.existingImageUrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final cs = theme.colorScheme;
    final filled = imageBytes != null || existingImageUrl != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: _DashedBorder(
            // Une fois la photo posée, le pointillé n'a plus rien à demander.
            enabled: !filled,
            color: sem.borderSubtle,
            radius: 12,
            child: Container(
              width: _kPhotoTile,
              height: _kPhotoTile,
              decoration: BoxDecoration(
                color: sem.trackMuted,
                borderRadius: BorderRadius.circular(12),
                border: filled
                    ? Border.all(color: sem.borderSubtle)
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: imageBytes != null
                  ? Image.memory(imageBytes!, fit: BoxFit.cover)
                  : (existingImageUrl != null
                      ? ProductImageCard(
                          imageUrl: existingImageUrl,
                          fillParent: true,
                          borderRadius: BorderRadius.zero,
                        )
                      : Icon(Icons.photo_camera_outlined,
                          size: 24,
                          color: cs.onSurface.withValues(alpha: 0.45))),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: _kPhotoTile,
          child: Text('Photo',
              textAlign: TextAlign.center,
              style: AppTextStyles.microSecondary),
        ),
      ],
    );
  }
}

/// Les DEUX champs obligatoires du plat, et eux seuls : nom puis prix.
///
/// La catégorie et le secteur les suivaient ici même. Le prix arrivait donc en
/// quatrième position, alors que c'est — avec le nom — tout ce qu'il faut pour
/// mettre un plat à la carte. La catégorie est descendue en pleine largeur
/// sous ce bloc, le secteur dans le repli.
class _IdentityFields extends StatelessWidget {
  final TextEditingController nameCtrl;
  final TextEditingController priceCtrl;

  /// Focus d'entrée sur le nom — à la création seulement.
  final bool autofocusName;

  /// Nom du plat homonyme déjà à la carte, `null` s'il n'y en a pas.
  final String? dupName;

  const _IdentityFields({
    required this.nameCtrl,
    required this.priceCtrl,
    required this.autofocusName,
    required this.dupName,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Nom ──────────────────────────────────────────────────
        const AppFieldLabel('Nom du plat', required: true),
        const SizedBox(height: 8),
        AppField(
          controller: nameCtrl,
          hint: 'Poulet DG',
          hintStyle: _kHintStyle,
          autofocus: autofocusName,
          prefixIcon: Icons.restaurant_rounded,
          // Le champ porte lui-même l'avertissement : un message qui flotte
          // sous un champ d'allure normale ne dit pas lequel il concerne.
          borderColor:
              dupName != null ? Theme.of(context).semantic.warning : null,
        ),
        if (dupName != null) _DupNameNotice(name: dupName!),
        const SizedBox(height: 16),

        // ── Prix de vente ────────────────────────────────────────
        // Juste sous le nom : avec lui, c'est tout ce qu'il faut pour
        // mettre un plat à la carte.
        const AppFieldLabel('Prix de vente', required: true),
        const SizedBox(height: 8),
        AppField(
          controller: priceCtrl,
          hint: '3500',
          hintStyle: _kHintStyle,
          numbersOnly: true,
          keyboardType: TextInputType.number,
          prefixIcon: Icons.payments_outlined,
          suffixIcon: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(CurrencyFormatter.currentSymbol,
                style: AppTextStyles.bodySmSecondary),
          ),
        ),
      ],
    );
  }
}

/// Catégorie — sur toute la largeur, sous le bloc d'identité.
///
/// Deux états, parce qu'un champ obligatoire et vide ne peut pas se contenter
/// d'une puce « + Nouvelle » posée seule : rien ne disait qu'il fallait agir,
/// ni que l'enregistrement serait refusé sans elle.
class _CategoryPicker extends StatelessWidget {
  final List<String> categories;
  final String? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;

  const _CategoryPicker({
    required this.categories,
    required this.selected,
    required this.onSelect,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) {
      return _InfoBanner(
        text: 'Aucune catégorie. Créez-en une pour ranger vos plats.',
        actionLabel: 'Nouvelle',
        onAction: onAdd,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppFieldLabel('Catégorie', required: true),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in categories)
              _Chip(
                label: c,
                // À la casse près : un plat rangé sous « plats » allume la
                // puce « Plats ». Sans y toucher, il garde son texte.
                selected: sameCategory(selected, c),
                onTap: () => onSelect(c),
              ),
            // Pointillée : elle n'est pas une catégorie de plus, elle en
            // fabrique une. Le trait discontinu suffit à le dire.
            _Chip(
              label: '+ Nouvelle',
              selected: false,
              dashed: true,
              onTap: onAdd,
            ),
          ],
        ),
      ],
    );
  }
}

/// Secteur d'activité — descendu dans le repli.
///
/// Il était masqué en silence quand la boutique n'a aucune activité : on ne
/// pouvait donc pas savoir que ce réglage existe, ni où le créer. Il annonce
/// désormais où ça se passe.
class _ActivityPicker extends StatelessWidget {
  final List<RestaurantActivity> activities;

  /// `restaurant_activities.id` choisi, `null` = aucun.
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  const _ActivityPicker({
    required this.activities,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (activities.isEmpty) {
      return const RestoEmptyNote(
          'Aucun secteur défini. Ils se créent dans Finances → Activités, pour '
          'séparer les chiffres du bar et de la cuisine.');
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Chip(
          label: 'Aucun',
          selected: selectedId == null,
          onTap: () => onSelect(null),
        ),
        for (final a in activities)
          _Chip(
            label: a.name,
            selected: selectedId == a.id,
            onTap: () => onSelect(a.id),
          ),
      ],
    );
  }
}

/// En-tête du repli « Coût, secteur, stock et visibilité ».
class _AdvancedHeader extends StatelessWidget {
  final bool open;

  /// Pastille « Secteur à choisir », vue bloc fermé.
  final bool showSectorBadge;
  final VoidCallback onTap;

  const _AdvancedHeader({
    required this.open,
    required this.showSectorBadge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(
                open
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 20,
                color: cs.onSurface),
            const SizedBox(width: 6),
            // Le titre DIT CE QU'IL CACHE. « Plus de réglages »
            // n'annonçait rien : on l'ouvrait pour voir, ou jamais.
            // Le secteur y manquait : on créait un plat sans jamais
            // croiser le champ.
            Flexible(
              child: Text('Coût, secteur, stock et visibilité',
                  style: AppTextStyles.bodySmBold
                      .copyWith(color: cs.onSurface)),
            ),
            // CE QUI RESTE À REMPLIR, vu bloc fermé. Seulement si la
            // boutique a des secteurs — sans eux il n'y a rien à
            // choisir, et la plupart des restaurants n'en ont pas — et
            // seulement replié : ouvert, le champ se voit lui-même.
            // Ton neutre : « Aucun » reste un choix valide, le plat
            // ira simplement sous « Sans secteur ».
            if (showSectorBadge) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: sem.info.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('Secteur à choisir',
                    maxLines: 1,
                    style: AppTextStyles.microBold
                        .copyWith(color: AppColors.textSecondary)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Le contenu du repli : coût matière, stock, vente, vitrine, secteur.
///
/// LISTE et non empilement de champs : chaque réglage porte son titre en gras
/// et son explication dessous, séparés par un filet. En vrac, le coût matière
/// — le moins important des cinq — était le plus visible, parce que seul lui
/// avait la forme d'un champ.
class _AdvancedSettings extends StatelessWidget {
  final TextEditingController costCtrl;
  final bool trackStock;
  final ValueChanged<bool> onTrackStock;
  final bool isActive;
  final ValueChanged<bool> onActive;
  final bool isVisibleWeb;
  final ValueChanged<bool> onVisibleWeb;

  /// Le sélecteur de secteur, posé sous son titre.
  final Widget activityPicker;

  const _AdvancedSettings({
    required this.costCtrl,
    required this.trackStock,
    required this.onTrackStock,
    required this.isActive,
    required this.onActive,
    required this.isVisibleWeb,
    required this.onVisibleWeb,
    required this.activityPicker,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        _SettingTile(
          title: 'Coût matière',
          hint: 'Utilisé tant qu\'aucun ingrédient n\'est rattaché. '
              'Le coût réel le remplacera dès vos premiers achats.',
          trailing: SizedBox(
            width: 132,
            child: AppField(
              controller: costCtrl,
              hint: '0',
              hintStyle: _kHintStyle,
              numbersOnly: true,
              isDense: true,
              keyboardType: TextInputType.number,
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(CurrencyFormatter.currentSymbol,
                    style: AppTextStyles.bodySmSecondary),
              ),
            ),
          ),
        ),
        _SettingTile(
          title: 'Suivre le stock',
          hint: 'Pour les boissons en bouteille, pas pour un plat '
              'cuisiné.',
          trailing: Switch(
            value: trackStock,
            onChanged: onTrackStock,
          ),
        ),
        _SettingTile(
          title: 'Proposer à la vente',
          // Décrit le comportement RÉEL : le plat quitte la carte ET la
          // vitrine (la page publique filtre aussi sur ce drapeau), et il
          // se retrouve derrière le bandeau de l'écran Menu, nommé ici
          // exactement comme il s'affiche là-bas.
          hint: 'Décoché, le plat quitte la carte et la vitrine en '
              'ligne. Il reste accessible depuis « plats retirés de la '
              'vente », sur l\'écran Menu.',
          trailing: Switch(
            value: isActive,
            onChanged: onActive,
          ),
        ),
        _SettingTile(
          title: 'Afficher sur ma vitrine en ligne',
          hint: 'La photo et le prix seront visibles publiquement.',
          trailing: Switch(
            value: isVisibleWeb,
            onChanged: onVisibleWeb,
          ),
        ),
        // Le SECTEUR descend ici : il ne concerne que les
        // établissements qui séparent leurs chiffres (bar / cuisine), et
        // il encombrait le bloc d'identité de tous les autres.
        _SettingTile(
          title: 'Secteur',
          hint: 'Sépare les chiffres du bar et de la cuisine dans vos '
              'rapports.',
          below: activityPicker,
        ),
      ],
    );
  }
}

/// Composition du plat : les ingrédients à cocher, puis — dès le premier —
/// le bloc des portions, le coût du mois et « Vider la composition ».
class _CompositionSection extends StatelessWidget {
  final List<Ingredient> catalog;
  final List<_RecipeDraft> recipe;

  /// Parcours de mise en route : au moins un ingrédient exigé.
  final bool requireIngredient;

  /// Au moins une ligne chiffrée à la fiche technique ?
  final bool hasSheetLine;

  /// Coût matières du mois imputé au plat (`_RecipeSummary`).
  final double allocatedCost;

  /// Prix saisi, pour la marge du résumé.
  final double price;
  final bool isNewDish;
  final bool saving;

  final VoidCallback onCreateIngredient;
  final ValueChanged<Ingredient> onToggle;
  final void Function(_RecipeDraft draft, double weight) onPortionChanged;
  final ValueChanged<_RecipeDraft> onQtyTouched;
  final ValueChanged<_RecipeDraft> onRemove;
  final VoidCallback onClear;

  const _CompositionSection({
    required this.catalog,
    required this.recipe,
    required this.requireIngredient,
    required this.hasSheetLine,
    required this.allocatedCost,
    required this.price,
    required this.isNewDish,
    required this.saving,
    required this.onCreateIngredient,
    required this.onToggle,
    required this.onPortionChanged,
    required this.onQtyTouched,
    required this.onRemove,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.receipt_long_outlined,
              size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            // Même échelon que l'en-tête « Plus de réglages » juste
            // au-dessus : ce sont deux sections de même niveau dans la
            // même feuille, elles ne doivent pas avoir deux tailles.
            child: Text('Composition',
                style: AppTextStyles.bodySmBold
                    .copyWith(color: cs.onSurface)),
          ),
          TextButton.icon(
            onPressed: onCreateIngredient,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Nouvel ingrédient'),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
              'Cochez ce que ce plat contient. Aucune quantité à saisir : '
              'le coût de chaque ingrédient est réparti entre les plats '
              'qui le portent, au prorata de ce qui se vend.',
              style: AppTextStyles.caption),
        ),
        // Mise en route : on dit POURQUOI c'est exigé plutôt que de
        // laisser un bouton grisé sans explication.
        if (requireIngredient && recipe.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
                'Ajoutez au moins 1 ingrédient pour continuer — c\'est ce '
                'lien qui permettra de calculer votre marge.',
                style:
                    AppTextStyles.caption.copyWith(color: sem.warningText)),
          ),
        if (catalog.isEmpty)
          const RestoEmptyNote(
              'Aucun ingrédient dans votre catalogue. Créez-en un pour '
              'commencer à suivre le coût de ce plat.')
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final ing in catalog)
                // SUCCESS plein + coche : ce sont des cases cochées, pas
                // un choix parmi d'autres. À 12 % d'accent et une bordure,
                // coché et non coché se ressemblaient trop pour qu'on voie
                // d'un coup d'œil ce que le plat contient.
                _Chip(
                  label: ing.name,
                  selected: recipe.any((d) => d.ingredientId == ing.id),
                  accent: sem.success,
                  selectedIcon: Icons.check_rounded,
                  onTap: () => onToggle(ing),
                ),
            ],
          ),
        // BLOC À PART, sur une surface plus marquée : ces lignes ne sont
        // pas une suite de champs du formulaire, ce sont les réglages des
        // ingrédients qu'on vient de cocher juste au-dessus. Sans fond,
        // elles flottaient sous les puces sans qu'on voie ce qui les lie.
        if (recipe.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: sem.elevatedSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sem.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    hasSheetLine
                        ? 'Portions et quantités'
                        : 'Générosité des portions',
                    style: AppTextStyles.bodySmBold
                        .copyWith(color: cs.onSurface)),
                const SizedBox(height: 2),
                Text(
                    hasSheetLine
                        ? 'Les ingrédients en « Quantité connue » demandent la '
                            'quantité contenue dans UNE assiette. Une seule '
                            'manquante et le plat perd son coût — mieux vaut ça '
                            'qu\'un chiffre sous-évalué et crédible. Les autres '
                            'gardent leur générosité de portion.'
                        : 'Laissez « Normale » sauf si ce plat en contient '
                            'nettement plus ou moins que vos autres plats.',
                    style: AppTextStyles.caption),
                const SizedBox(height: 10),
                for (final d in recipe)
                  _PortionRow(
                    draft: d,
                    sheetMode: d.usesSheet,
                    onChanged: (w) => onPortionChanged(d, w),
                    // Toucher au champ vaut relecture : l'avertissement de
                    // quantité héritée tombe dès la première frappe.
                    onQtyChanged: () => onQtyTouched(d),
                    onRemove: () => onRemove(d),
                  ),
                const SizedBox(height: 10),
                _RecipeSummary(
                  cost: allocatedCost,
                  price: price,
                  isNewDish: isNewDish,
                ),
                // Tout décocher d'un coup — le ✕ de chaque ligne reste la
                // voie normale pour en retirer UN.
                Center(
                  child: TextButton.icon(
                    onPressed: saving ? null : onClear,
                    icon: Icon(Icons.delete_sweep_outlined,
                        size: 18, color: sem.danger),
                    label: Text('Vider la composition',
                        style: AppTextStyles.label
                            .copyWith(color: sem.dangerText)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Enregistrer et Supprimer sur la MÊME ligne. « Supprimer » reste secondaire
/// — contour rouge et non aplat — pour qu'une action destructive ne se
/// présente pas comme l'action attendue.
class _FormActions extends StatelessWidget {
  final bool isEdit;
  final bool saving;

  /// `false` : le bouton principal est grisé (ingrédient exigé, aucun coché).
  final bool canSubmit;
  final VoidCallback onSubmit;
  final VoidCallback onDelete;

  const _FormActions({
    required this.isEdit,
    required this.saving,
    required this.canSubmit,
    required this.onSubmit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Row(children: [
      Expanded(
        flex: 2,
        child: AppPrimaryButton(
          label: isEdit ? 'Enregistrer' : 'Créer le plat',
          icon: Icons.check_rounded,
          fullWidth: true,
          isLoading: saving,
          enabled: canSubmit,
          onTap: onSubmit,
        ),
      ),
      if (isEdit) ...[
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: saving ? null : onDelete,
            icon: Icon(Icons.delete_outline_rounded,
                size: 18, color: sem.danger),
            label: Text('Supprimer',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.label.copyWith(color: sem.dangerText)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 46),
              side: BorderSide(color: sem.danger.withValues(alpha: 0.5)),
            ),
          ),
        ),
      ],
    ]);
  }
}
