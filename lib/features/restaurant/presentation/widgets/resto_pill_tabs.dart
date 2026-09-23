import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import 'resto_surfaces.dart';

/// Un onglet de la barre : son libellé et ce qu'il contient.
class RestoPillTab {
  final String label;
  final int count;

  /// Couleur de l'onglet ACTIF. `null` → l'accent de la palette.
  ///
  /// Sert à distinguer deux natures qu'on ne veut pas confondre — la matière
  /// qui entre dans les plats et ce qui se consomme sans être servi. La
  /// différence se voit alors AVANT de lire le libellé.
  ///
  /// Laisser `null` est le cas courant : des onglets qui listent la même
  /// chose (les catégories d'une carte) n'ont aucune raison de changer de
  /// couleur entre eux.
  final Color? color;

  /// Pictogramme posé AVANT le libellé. `null` → aucun.
  ///
  /// LA COULEUR NE SUFFIT PAS, et c'est mesurable. L'écart perceptuel entre
  /// l'ambre sémantique et l'accent des huit palettes, calculé en ΔE76 (Lab),
  /// va de 145 sur Violet Fortress à **17,7 sur la palette Amber en mode
  /// clair** — deux oranges voisins. La distinction par la teinte y tient mal,
  /// et elle ne tient pas du tout pour qui distingue mal les couleurs.
  ///
  /// L'icône est donc le signal PRINCIPAL, la couleur le renfort. Elle coûte
  /// environ 22 px de largeur par pastille : acceptable à deux onglets,
  /// à surveiller au-delà sur un téléphone.
  final IconData? icon;

  const RestoPillTab({
    required this.label,
    required this.count,
    this.color,
    this.icon,
  });
}

/// BARRE D'ONGLETS EN PASTILLES, avec compteur dans le libellé.
///
/// Extraite de `_CategoryBar` (écran Menu) le 21/09/2026, quand l'écran Stock
/// a eu besoin de la même grammaire. Deux copies auraient divergé au premier
/// ajustement — c'est précisément ce que la cohérence posée depuis le tableau
/// de bord cherche à éviter.
///
/// L'API est indexée plutôt que typée par valeur : le Menu sélectionne une
/// catégorie (`String?`), Stock sélectionne un onglet. Un index couvre les
/// deux sans qu'aucun des deux n'ait à porter le vocabulaire de l'autre.
class RestoPillTabs extends StatelessWidget {
  final List<RestoPillTab> items;
  final int selected;
  final ValueChanged<int> onSelect;

  /// Marge extérieure. Le Menu la veut collée à sa barre de recherche, Stock
  /// la veut sous son en-tête.
  final EdgeInsets padding;

  const RestoPillTabs({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelect,
    this.padding = const EdgeInsets.fromLTRB(16, 10, 16, 6),
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // ── LA BARRE DIT QU'ELLE CONTINUE ────────────────────────────────────
    //
    // Elle défilait déjà, sans le montrer : à huit onglets, le dernier était
    // coupé en plein mot et rien n'annonçait qu'il y en avait d'autres. Une
    // barre qui se termine par un libellé tronqué se lit comme un défaut
    // d'affichage, pas comme une invitation à faire glisser.
    //
    // UN DÉGRADÉ ET UN CHEVRON, et non une flèche cliquable : la barre se
    // fait glisser au doigt comme au trackpad, et un bouton de défilement
    // réclamerait des taps répétés pour parcourir ce qu'un geste traverse.
    // Le dégradé dit « ça continue », le chevron dit dans quel sens.
    //
    // `Stack` plutôt qu'un `ShaderMask` : le masque aurait aussi délavé les
    // pastilles actives en fin de course, alors qu'on veut voiler ce qui est
    // coupé, pas ce qui est sélectionné.
    return Stack(children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++) _chip(context, i),
          ],
        ),
      ),
      // Posé à droite, ignoré par le doigt : sans `IgnorePointer`, la zone
      // voilée cesserait de répondre au glissement — c'est-à-dire que
      // l'indice de défilement empêcherait de défiler.
      Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        child: IgnorePointer(
          child: Container(
            width: 36,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  cs.surface.withValues(alpha: 0),
                  cs.surface,
                ],
              ),
            ),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 2),
            child: Icon(Icons.chevron_right_rounded,
                size: 18, color: cs.onSurfaceVariant),
          ),
        ),
      ),
    ]);
  }

  Widget _chip(BuildContext context, int i) {
    final theme = Theme.of(context);
    final sel = selected == i;
    final radius = BorderRadius.circular(999);
    final accent = items[i].color ?? theme.colorScheme.primary;
    // BLANC SUR FOND PLEIN, quelle que soit la teinte. `onPrimary` ne vaut que
    // pour l'accent de la palette ; sur une couleur propre à l'onglet, il
    // pourrait rendre un texte sombre sur un fond sombre.
    final fg = sel ? Colors.white : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        // Active : accent plein. Inactive : la surface des cartes, qui laisse
        // deviner le motif du fond comme le reste de l'écran.
        color: sel ? accent : restoGlassFill(context),
        borderRadius: radius,
        child: InkWell(
          onTap: () => onSelect(i),
          borderRadius: radius,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: sel ? accent : restoGlassBorder(context),
                width: 0.5,
              ),
            ),
            // Le compteur est DANS le libellé, pas dans une pastille à côté :
            // une seconde forme ferait varier la largeur sans rien apprendre
            // de plus.
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (items[i].icon != null) ...[
                Icon(items[i].icon, size: 15, color: fg),
                const SizedBox(width: 6),
              ],
              Text('${items[i].label} · ${items[i].count}',
                  style: AppTextStyles.bodySmBold.copyWith(color: fg)),
            ]),
          ),
        ),
      ),
    );
  }
}
