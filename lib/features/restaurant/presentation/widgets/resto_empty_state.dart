import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
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

  /// Rendu COMPACT : une ligne, icône et phrase, sans carte ni pastille.
  ///
  /// La carte dit « cette zone existe, elle est vide » — c'est juste quand
  /// elle occupe l'écran. Sous une barre d'onglets qui porte déjà le nom et
  /// le compte de ce qu'on regarde, elle répète ce qui est écrit juste
  /// au-dessus et pousse le bouton d'action hors de vue.
  ///
  /// Même grammaire que le tableau de bord (`_EmptyBlock`) : icône de 19,
  /// texte secondaire, alignés en haut.
  final bool compact;

  const RestoEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
    this.footer,
    this.compact = false,
  });

  /// Au-delà, la ligne de texte devient trop longue pour être lue d'un trait
  /// et la carte s'étire sur toute la largeur d'un écran de bureau.
  static const double _kMaxWidth = 420;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 19, color: cs.onSurface.withValues(alpha: 0.35)),
            const SizedBox(width: 9),
            // Le TITRE est absorbé dans la phrase : en compact, « Aucun
            // ingrédient » suivi de « Aucun ingrédient. Créez-en un ici » se
            // lirait deux fois. C'est le sous-titre qui porte le sens, parce
            // que c'est lui qui dit ce qu'on peut FAIRE.
            Expanded(
              child: Text(subtitle, style: AppTextStyles.bodySmSecondary),
            ),
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
