part of 'dish_form_sheet.dart';

// Les petites pièces de la fiche plat.

/// Saisie d'une nouvelle catégorie ; rend le nom tapé (rogné).
///
/// Un widget À ÉTAT, propriétaire de son contrôleur : il le libère dans son
/// propre `dispose`, quand la route a vraiment disparu. La fiche le libérait
/// dès que la feuille rendait son résultat, alors que l'animation de
/// fermeture reconstruisait encore le champ (« TextEditingController was used
/// after being disposed » — trouvé par le banc de test le 26/09/2026).
class _NewCategorySheet extends StatefulWidget {
  const _NewCategorySheet();

  @override
  State<_NewCategorySheet> createState() => _NewCategorySheetState();
}

class _NewCategorySheetState extends State<_NewCategorySheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveFormFrame(
      title: 'Nouvelle catégorie',
      icon: Icons.category_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppField(
              controller: _ctrl,
              hint: 'Entrées, Plats, Boissons…',
              autofocus: true,
            ),
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Ajouter',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(context).pop(_ctrl.text.trim()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Puce de sélection (catégorie ou groupe d'options).
/// Puce de choix — sélectionnée en ACCENT PLEIN, sinon en simple contour.
///
/// L'état choisi se marquait par un fond d'accent à 12 % et une bordure : deux
/// nuances de la même teinte, que l'œil doit comparer pour trancher. Sur une
/// ligne de six catégories, on ne voyait plus laquelle était prise. Plein contre
/// contour se lit sans comparer.
class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Contour discontinu : la puce ne désigne pas un choix, elle en CRÉE un.
  final bool dashed;

  /// Teinte de l'état sélectionné. Défaut : la couleur du thème. Les
  /// ingrédients d'une recette prennent `success` — ce sont des cases cochées,
  /// pas un choix parmi d'autres.
  final Color? accent;

  /// Icône posée avant le libellé, une fois la puce sélectionnée.
  final IconData? selectedIcon;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dashed = false,
    this.accent,
    this.selectedIcon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    final tint = accent ?? AppColors.primary;
    // Noir ou blanc selon la teinte : un vert clair et un ambre ne portent pas
    // le même texte. `estimateBrightnessForColor` évite de le deviner.
    final onTint =
        ThemeData.estimateBrightnessForColor(tint) == Brightness.dark
            ? Colors.white
            : Colors.black87;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selected && selectedIcon != null) ...[
          Icon(selectedIcon, size: 15, color: onTint),
          const SizedBox(width: 6),
        ],
        Text(
          label,
          style: AppTextStyles.bodySm.copyWith(
            color: selected ? onTint : theme.colorScheme.onSurface,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );

    final box = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? tint : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        // Le pointillé est peint par `_DashedBorder` : laisser AUSSI une
        // bordure pleine ici dessinerait les deux l'une sur l'autre.
        border: dashed
            ? null
            : Border.all(
                color: selected ? tint : sem.borderSubtle,
                width: selected ? 1.5 : 1,
              ),
      ),
      child: content,
    );

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: dashed
          ? _DashedBorder(color: sem.borderSubtle, radius: 8, child: box)
          : box,
    );
  }
}

/// Création rapide d'un ingrédient sans quitter la fiche du plat.
///
/// Volontairement minimale : nom et unité. Le coût ne se saisit PAS ici — il
/// vient des achats rattachés à l'ingrédient, pas d'un prix théorique tapé une
/// fois pour toutes.
class _DashedBorder extends StatelessWidget {
  final Widget child;
  final Color color;
  final double radius;
  final bool enabled;

  const _DashedBorder({
    required this.child,
    required this.color,
    required this.radius,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return CustomPaint(
      foregroundPainter: _DashedPainter(color: color, radius: radius),
      child: child,
    );
  }
}

class _DashedPainter extends CustomPainter {
  final Color color;
  final double radius;

  const _DashedPainter({required this.color, required this.radius});

  /// Tiret et espace. Des tirets courts sur un petit rayon donnent un pointillé
  /// régulier ; plus longs, les angles arrondis les cassent en plein milieu.
  static const double _dash = 4;
  static const double _gap = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(radius),
      ));

    // Le chemin est parcouru métrique par métrique : c'est la seule façon de
    // découper un tracé arrondi en segments de longueur égale.
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final end = (dist + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, end), paint);
        dist = end + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPainter old) =>
      old.color != color || old.radius != radius;
}

/// Avertissement de plat homonyme, sous le champ Nom.
///
/// Ton WARNING et non danger : ce n'est pas une erreur, l'enregistrement reste
/// possible — deux plats de même nom sont parfois voulus. Le champ lui-même est
/// bordé de la même teinte pendant que ce message est là (cf. `borderColor`
/// d'`AppField`), pour qu'on sache lequel il concerne.
class _DupNameNotice extends StatelessWidget {
  final String name;

  const _DupNameNotice({required this.name});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 14, color: sem.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Un plat nommé "$name" existe déjà à la carte.',
              style: AppTextStyles.caption.copyWith(color: sem.warningText),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bandeau d'information avec une action à droite.
///
/// Pour un champ obligatoire qu'on ne PEUT pas encore remplir : il ne suffit
/// pas de proposer « + Nouvelle » au milieu de rien, il faut dire que c'est
/// attendu. Fond d'accent atténué — on informe, on n'alarme pas.
class _InfoBanner extends StatelessWidget {
  final String text;
  final String actionLabel;
  final VoidCallback onAction;

  const _InfoBanner({
    required this.text,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: sem.brandSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 17, color: sem.brandText),
          const SizedBox(width: 9),
          Expanded(
            child: Text(text,
                style:
                    AppTextStyles.caption.copyWith(color: sem.brandText)),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: onAction,
            // Hauteur explicite : le thème impose une largeur minimale infinie
            // aux boutons, qui écraserait l'Expanded voisin.
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: Text(actionLabel,
                style: AppTextStyles.bodySmBold
                    .copyWith(color: Theme.of(context).semantic.brandText)),
          ),
        ],
      ),
    );
  }
}

/// Une ligne de la liste « Coût, secteur, stock et visibilité ».
///
/// Titre en gras, explication dessous, contrôle à droite — ou sous le texte
/// quand le contrôle est large (`below`). Un filet fin sépare les lignes : il
/// suffit à faire une liste, là où des cartes empilées feraient cinq blocs
/// concurrents pour des réglages qu'on ne touche presque jamais.
class _SettingTile extends StatelessWidget {
  final String title;
  final String hint;

  /// Contrôle posé à droite du texte (interrupteur, petit champ).
  final Widget? trailing;

  /// Contrôle posé SOUS le texte, sur toute la largeur — pour ce qui ne tient
  /// pas dans une marge droite, comme une rangée de puces.
  final Widget? below;

  const _SettingTile({
    required this.title,
    required this.hint,
    this.trailing,
    this.below,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          // 0,5 px : un séparateur, pas un trait. À 1 px, cinq filets
          // rapprochés dessinent une grille et attirent l'œil sur des réglages
          // secondaires.
          top: BorderSide(color: sem.borderSubtle, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: AppTextStyles.bodySmBold
                            .copyWith(color: theme.colorScheme.onSurface)),
                    const SizedBox(height: 2),
                    Text(hint, style: AppTextStyles.caption),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
          if (below != null) ...[
            const SizedBox(height: 10),
            below!,
          ],
        ],
      ),
    );
  }
}
