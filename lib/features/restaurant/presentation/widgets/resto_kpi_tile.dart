import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';

/// Teintes des tuiles du tableau de bord restaurant.
///
/// Ce sont des couleurs de DONNÉES, pas des couleurs de thème : elles
/// identifient un indicateur (recette, commandes, dépenses, ticket) et
/// doivent rester stables d'un écran à l'autre et d'un mode clair/sombre à
/// l'autre — comme les couleurs d'une légende de graphique. C'est la seule
/// raison pour laquelle elles sont fixes ici : le fond de page, lui, suit
/// bien le thème de l'application.
///
/// Pastels clairs : ils teintent désormais la PASTILLE d'icône (icône sombre
/// par-dessus), plus le fond de la tuile — qui suit la surface du thème.
class RestoTileColors {
  RestoTileColors._();

  static const revenue  = Color(0xFF6EE7A8); // vert
  static const orders   = Color(0xFFDDA9F0); // lilas
  static const expense  = Color(0xFF8B9BF7); // bleu
  static const average  = Color(0xFFFB8177); // corail

  static const List<Color> all = [revenue, orders, expense, average];
}

/// Teintes des COURBES du graphique finances (module finances — Lot 3).
///
/// Distinctes des pastels de [RestoTileColors] : une courbe d'1,5 px doit
/// rester lisible sur fond clair ET sur fond sombre, ce que ne permettent pas
/// des pastels. Ce sont aussi des couleurs de données — elles portent le sens
/// (vert = ventes, violet = bénéfice, rouge = dépenses, orange = pertes) et ne
/// suivent donc pas le thème.
class RestoSeriesColors {
  RestoSeriesColors._();

  static const sales   = Color(0xFF16A34A); // vert
  static const profit  = Color(0xFF7C3AED); // violet
  static const expense = Color(0xFFDC2626); // rouge
  static const loss    = Color(0xFFF97316); // orange
}

/// Tuile d'indicateur NEUTRE (surface du thème + bordure douce), avec une
/// petite pastille d'icône colorée qui porte l'identité de l'indicateur.
///
/// Les aplats de couleur pleine « cassaient l'ambiance » : ils juraient avec
/// les autres cartes neutres du tableau de bord. On garde l'identité couleur
/// (via la pastille d'icône) mais la carte s'harmonise avec le reste et suit
/// le thème clair/sombre.
class RestoKpiTile extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const RestoKpiTile({
    super.key,
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    // Pastille : la teinte pastel de l'indicateur, icône sombre (les pastels
    // sont clairs → un icône foncé contraste dans les deux modes).
    const onBadge = Color(0xFF1F2937);

    return Material(
      color: cs.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sem.borderSubtle),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, size: 21, color: onBadge),
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
                          value,
                          maxLines: 1,
                          style: AppTextStyles.title.copyWith(
                              color: cs.onSurface, fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySm.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.6)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pastille de période, style « dropdown » de la maquette.
///
/// [onTap] null → simple étiquette informative, sans chevron : on n'affiche
/// pas un chevron qui ne ferait rien.
class RestoPeriodPill extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const RestoPeriodPill({super.key, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = theme.semantic;

    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: sem.trackMuted,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: AppTextStyles.bodySm
                  .copyWith(color: theme.colorScheme.onSurface)),
          if (onTap != null) ...[
            const SizedBox(width: 5),
            Icon(Icons.expand_more_rounded,
                size: 16, color: theme.colorScheme.onSurface),
          ],
        ],
      ),
    );

    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: content,
    );
  }
}
