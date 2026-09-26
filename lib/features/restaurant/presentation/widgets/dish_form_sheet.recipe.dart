part of 'dish_form_sheet.dart';

// La composition du plat : brouillon de recette, portions, résumé.

class _RecipeDraft {
  final String ingredientId;
  final String name;
  double portionWeight;

  /// Cet ingrédient est-il chiffré à la FICHE TECHNIQUE ? Décide, ligne par
  /// ligne, si l'on demande une quantité par portion ou une générosité.
  final bool usesSheet;

  /// Unité de l'INGRÉDIENT — jamais choisie ici. Le module ne convertit pas
  /// les unités : la quantité de recette s'exprime forcément dans celle de
  /// l'ingrédient, et l'écran l'affiche en dur à côté du champ.
  final String unit;

  /// Quantité par portion (fiche technique). Vide = non renseignée.
  final TextEditingController qty;

  /// La valeur pré-remplie vient-elle d'une saisie ANCIENNE, jamais relue ?
  /// Elle s'affiche alors en avertissement tant qu'on ne l'a pas retouchée ou
  /// confirmée — cf. `RecipeIngredient.quantityConfirmed`.
  bool inheritedUnconfirmed;

  _RecipeDraft({
    required this.ingredientId,
    required this.name,
    required this.portionWeight,
    this.unit = '',
    this.usesSheet = false,
    double initialQty = 0,
    this.inheritedUnconfirmed = false,
  }) : qty = TextEditingController(
            text: initialQty > 0 ? _trimZeros(initialQty) : '');

  double get qtyValue =>
      double.tryParse(qty.text.trim().replaceAll(',', '.')) ?? 0;

  static String _trimZeros(double v) {
    final s = v.toStringAsFixed(3);
    return s.contains('.')
        ? s.replaceFirst(RegExp(r'\.?0+$'), '')
        : s;
  }
}

/// Une ligne de composition.
///
/// Son contenu dépend de la MÉTHODE DE COÛT active, et c'est voulu :
///   * **répartition** — générosité de la portion (petite · normale · grande).
///     Aucune quantité n'est demandée, c'est le principe même de la méthode ;
///   * **fiche technique** — quantité par portion, dans l'unité de
///     l'ingrédient. Les pastilles de générosité disparaissent : elles ne
///     servent qu'à la répartition, et les laisser laisserait croire qu'elles
///     pondèrent aussi la fiche.
///
/// Afficher les deux ensemble ferait saisir deux fois la même intention sous
/// deux formes, dont une seule compte.
class _PortionRow extends StatelessWidget {
  final _RecipeDraft draft;
  final ValueChanged<double> onChanged;
  final VoidCallback onRemove;
  final bool sheetMode;
  final VoidCallback onQtyChanged;

  const _PortionRow({
    required this.draft,
    required this.onChanged,
    required this.onRemove,
    required this.sheetMode,
    required this.onQtyChanged,
  });

  static const _options = <({double weight, String label})>[
    (weight: RecipeIngredient.smallPortion, label: 'Petite'),
    (weight: RecipeIngredient.normalPortion, label: 'Normale'),
    (weight: RecipeIngredient.largePortion, label: 'Grande'),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    // Une quantité héritée jamais relue : signalée tant qu'on n'y a pas
    // touché. Elle ne compte dans aucun calcul avant confirmation.
    final warn = sheetMode && draft.inheritedUnconfirmed;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(draft.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySm.copyWith(color: cs.onSurface)),
            ),
            if (sheetMode) ...[
              SizedBox(
                width: 96,
                child: TextField(
                  controller: draft.qty,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.end,
                  style: AppTextStyles.input,
                  onChanged: (_) => onQtyChanged(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '0',
                    hintStyle: _kHintStyle,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 8),
                    // Unité IMPOSÉE, jamais choisie : le module ne convertit
                    // pas, et « kg » dosé en grammes ferait un coût faux d'un
                    // facteur mille.
                    suffixText:
                        draft.unit.isEmpty ? null : ' ${draft.unit}',
                    suffixStyle: AppTextStyles.caption,
                  ),
                ),
              ),
            ] else
              for (final o in _options) ...[
                _Chip(
                  label: o.label,
                  selected: (draft.portionWeight - o.weight).abs() < 0.01,
                  onTap: () => onChanged(o.weight),
                ),
                const SizedBox(width: 6),
              ],
            IconButton(
              onPressed: onRemove,
              visualDensity: VisualDensity.compact,
              tooltip: 'Retirer',
              icon: Icon(Icons.close_rounded, size: 18, color: sem.danger),
            ),
          ]),
          if (warn)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 2),
              child: Text(
                  'Quantité héritée d\'une version antérieure — '
                  'vérifiez-la, elle ne compte pas encore.',
                  style: AppTextStyles.micro
                      .copyWith(color: sem.warningText)),
            ),
        ],
      ),
    );
  }
}

/// Bloc récapitulatif : coût matières du MOIS · prix de vente · marge.
///
/// Le coût affiché n'est pas une propriété du plat mais le résultat des achats
/// et des ventes du mois en cours. Le dire est indispensable : sans cette
/// mention, un gérant croirait à un chiffre figé et s'inquiéterait de le voir
/// bouger le mois suivant.
class _RecipeSummary extends StatelessWidget {
  final double cost;
  final double price;

  /// Un plat pas encore créé n'a aucune vente : rien à répartir sur lui.
  final bool isNewDish;

  const _RecipeSummary({
    required this.cost,
    required this.price,
    this.isNewDish = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final margin = price - cost;
    final pct = price <= 0 ? 0.0 : (margin / price) * 100;
    // Couleur de la marge ÉCRITE : les variantes texte (le token suit son fond).
    final accent = margin >= 0 ? sem.successText : sem.dangerText;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Column(children: [
        if (isNewDish)
          Text(
              'Le coût matières apparaîtra ici une fois le plat créé et des '
              'ventes enregistrées : il se déduit de vos achats du mois.',
              style: AppTextStyles.captionHint)
        else if (cost <= 0)
          Text(
              'Aucun coût imputé ce mois-ci : rattachez vos achats à ces '
              'ingrédients dans Finances → Dépenses, et vendez ce plat au '
              'moins une fois.',
              style: AppTextStyles.captionHint)
        else ...[
          _line(context, 'Coût matières (ce mois)',
              CurrencyFormatter.format(cost)),
          _line(context, 'Prix de vente', CurrencyFormatter.format(price)),
          Divider(height: 16, color: sem.borderSubtle),
          _line(context, 'Marge', CurrencyFormatter.format(margin),
              color: accent, bold: true),
          _line(context, 'Marge %', '${pct.toStringAsFixed(0)} %',
              color: accent),
          const SizedBox(height: 6),
          Text(
              'Calculé sur les achats et les ventes du mois en cours — ce '
              'chiffre évolue avec eux.',
              style: AppTextStyles.captionHint),
        ],
      ]),
    );
  }

  Widget _line(BuildContext c, String label, String value,
      {Color? color, bool bold = false}) {
    final cs = Theme.of(c).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: AppTextStyles.bodySm
                  .copyWith(color: cs.onSurface.withValues(alpha: 0.7))),
        ),
        Text(value,
            style: (bold ? AppTextStyles.bodyBold : AppTextStyles.bodySm)
                .copyWith(color: color ?? cs.onSurface)),
      ]),
    );
  }
}
