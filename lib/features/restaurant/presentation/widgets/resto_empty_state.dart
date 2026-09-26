import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import 'resto_dish_visuals.dart' show restoCardSurface;
import 'resto_surfaces.dart';

/// État vide des écrans du module restaurant.
///
/// Écrit ici plutôt que via `EmptyStateWidget` : le bouton de ce dernier
/// n'est pas centré (padding H10/V3 dans une largeur fixe de 220), et il est
/// partagé avec l'e-commerce — le corriger à la source changerait des écrans
/// hors du périmètre restaurant.
///
/// C'est une CARTE, pas un texte flottant. Le module restaurant pose ses
/// écrans sur une photo de salle : un titre et un paragraphe écrits à nu
/// dessus n'ont aucun fond à eux, leur lisibilité dépend alors de la zone de
/// l'image qui passe derrière (cf. la règle documentée sur `restoGlassFill`).
/// Un état vide en carte dit aussi autre chose : la zone existe, elle est
/// simplement vide — un texte seul au milieu du vide se lit comme un écran qui
/// n'a pas fini de charger.
class RestoEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  /// Libellé du bouton. `null` → aucun bouton (écran informatif seul).
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Bloc posé SOUS la carte, à la même largeur — par exemple la progression
  /// de mise en route sur la carte d'un restaurant neuf. En dehors de la
  /// carte et non dedans : l'état vide dit ce qu'il n'y a pas ici, le pied
  /// parle du reste de l'application.
  final Widget? footer;

  /// Rendu COMPACT : une carte dense, sous une barre d'onglets.
  ///
  /// Le mode plein occupe l'écran — pastille de 72 px, texte centré, largeur
  /// bornée à 420. C'est juste quand l'état vide EST l'écran. Sous une barre
  /// d'onglets qui porte déjà le nom et le compte de ce qu'on regarde, il
  /// répète ce qui est écrit au-dessus et pousse le bouton hors de vue.
  ///
  /// Le compact garde la CARTE — même surface que les autres écrans du module
  /// — et resserre tout : carré de 34 px, icône de 17, titre et phrase côte à
  /// côte plutôt qu'empilés au centre.
  ///
  /// Une première version supprimait la carte. Le texte et le bouton
  /// flottaient alors sur le fond géométrique, et l'icône seule devant un
  /// paragraphe se lisait comme une PUCE DE LISTE.
  final bool compact;

  /// Ligne CENTRÉE sous le bouton, dans la carte. `null` → aucune.
  ///
  /// Le second chemin, quand il y en a un : « ou en composant la recette d'un
  /// plat ». Distincte du [subtitle], qui dit ce qu'est la notion, et du
  /// [footer], qui sort de la carte pour parler d'un autre écran.
  final String? footnote;

  const RestoEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
    this.footer,
    this.compact = false,
    this.footnote,
  });

  /// Au-delà, la ligne de texte devient trop longue pour être lue d'un trait
  /// et la carte s'étire sur toute la largeur d'un écran de bureau.
  static const double _kMaxWidth = 420;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (compact) {
      // UNE CARTE, pas un paragraphe flottant.
      //
      // Le texte et le bouton reposaient à nu sur le fond géométrique du
      // module. Une icône de 18 px seule devant un paragraphe se lit comme une
      // PUCE DE LISTE ; dans un carré de 34 px à côté d'un titre, elle se lit
      // comme l'icône d'un état vide. La forme dit de quoi il s'agit avant que
      // le texte soit lu.
      //
      // Même recette que les cartes du tableau de bord (`restoCardSurface`) :
      // un état vide n'a aucune raison d'avoir sa propre surface.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(15),
              decoration: restoCardSurface(context, radius: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(icon, size: 17, color: cs.primary),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 13 px semi-gras : l'échelon `body` de
                            // l'échelle, en variante grasse. Pas de taille
                            // inventée.
                            Text(title,
                                style: AppTextStyles.bodyBold
                                    .copyWith(color: cs.onSurface)),
                            const SizedBox(height: 3),
                            // Ce qu'est la notion, avant le geste : « Aucun
                            // ingrédient » ne dit pas où ranger une barquette.
                            Text(subtitle, style: AppTextStyles.caption),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // L'ACTION sous la phrase qui la promet, pleine largeur de
                  // la carte. Elle flottait en pilule d'en-tête pendant que le
                  // texte disait « créez-en un ici » — « ici » ne désignait
                  // alors rien.
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: onAction,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: Text(actionLabel!),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40)),
                    ),
                  ],
                  // LE SECOND CHEMIN, quand il y en a un. Centré et discret :
                  // c'est une alternative, pas une seconde action.
                  if (footnote != null) ...[
                    const SizedBox(height: 10),
                    Text(footnote!,
                        textAlign: TextAlign.center,
                        style: AppTextStyles.captionHint),
                  ],
                ],
              ),
            ),
            // HORS de la carte : l'état vide dit ce qu'il n'y a pas ICI, le
            // pied parle du reste de l'application.
            if (footer != null) ...[
              const SizedBox(height: 10),
              footer!,
            ],
          ],
        ),
      );
    }

    final card = RestoGlassPanel(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30, color: cs.primary),
          ),
          const SizedBox(height: 16),
          Text(title,
              textAlign: TextAlign.center,
              style: AppTextStyles.subtitleBold.copyWith(color: cs.onSurface)),
          const SizedBox(height: 8),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySecondary),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 24),
            Material(
              color: cs.primary,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: onAction,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  // Padding vertical de 10, contenu centré.
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_rounded, size: 18, color: cs.onPrimary),
                      const SizedBox(width: 8),
                      Text(actionLabel!,
                          style: AppTextStyles.bodySmBold
                              .copyWith(color: cs.onPrimary)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    // Défilable : la carte peut désormais porter un pied (progression de mise
    // en route), et à 200 % de taille de texte sur un téléphone l'ensemble
    // dépasse la hauteur disponible. Sans ce défilement, c'est un débordement
    // rayé jaune et noir, sur l'écran d'accueil d'un restaurant neuf.
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          // Reste centré verticalement tant que ça tient, défile au-delà.
          constraints: BoxConstraints(
            minHeight: c.maxHeight.isFinite
                ? (c.maxHeight - 48).clamp(0.0, double.infinity)
                : 0,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kMaxWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  card,
                  if (footer != null) ...[
                    const SizedBox(height: 12),
                    footer!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// LISTE VIDE à l'intérieur d'une SECTION ou d'une FEUILLE — une phrase, pas
/// une carte (document de design § 11, tranché le 26/09/2026).
///
/// À cette échelle, le texte est déjà posé sur une surface : la feuille est
/// opaque, la section vit sous son titre. La raison de la carte — un texte à nu
/// sur la photo de salle, qui se lit comme un écran pas fini de charger — n'y
/// joue pas, et une carte dans une feuille ferait une carte dans une carte.
/// [RestoEmptyState] reste la règle quand l'état vide EST l'écran.
///
/// La phrase dit ce qui manque et, s'il y a lieu, où agir. Toujours en
/// `caption` / `textSecondary` (6,87:1 en clair, 5,71 en sombre) : ces notes
/// étaient pour la plupart en `captionHint`, dont le `textHint` tombe à
/// 3,07:1 en sombre.
class RestoEmptyNote extends StatelessWidget {
  final String text;
  const RestoEmptyNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) =>
      Text(text, style: AppTextStyles.caption);
}
