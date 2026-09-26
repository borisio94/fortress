import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Diamètre du bouton flottant — celui de l'ancien bouton du Menu, repris.
const double kRestoFabSize = 48;

/// Marge au bord de la zone qui le porte : la valeur Material
/// (`kFloatingActionButtonMargin`). Sur téléphone, cette zone est le corps du
/// shell, qui s'arrête AU-DESSUS de la barre de navigation du bas : le bouton
/// se pose donc 16 px au-dessus d'elle, jamais dessous.
const double kRestoFabMargin = 16;

/// Marge basse d'une liste qui porte le bouton : 48 (le bouton) + 16 (sa
/// marge) + 16 (de respiration) = 80. Sans elle, la dernière ligne passe SOUS
/// le bouton. Appliquée seulement quand le bouton est affiché.
const double kRestoFabClearance = kRestoFabSize + kRestoFabMargin + 16;

/// LE BOUTON FLOTTANT DES ÉCRANS DE LISTE DU RESTAURANT — Menu, Stock (deux
/// onglets), Plan de salle, Commandes. Rond, icône seule, en bas à droite.
///
/// ─── POURQUOI IL REVIENT (24/09/2026) ─────────────────────────────────────
///
/// Il avait été remplacé par un bouton d'en-tête, puis par une case pointillée
/// en fin de liste, sous la règle « jamais deux appels à la même action à
/// quinze centimètres ». Juste sur une liste courte ; faux à l'échelle : sur
/// deux cents ingrédients, la case est à trois écrans de défilement. Le
/// flottant reste atteignable. Ses deux défauts d'origine étaient de POSITION,
/// pas de principe :
///   • il masquait la dernière ligne → [kRestoFabClearance] en marge basse ;
///   • il recouvrait « Commander » quand le panier s'ouvrait → le Menu le
///     masque dans ce cas (`_cartOpen`).
///
/// Un seul appel par écran : ni bouton d'en-tête, ni case en fin de liste.
/// Jamais sur un écran VIDE, dont l'état vide porte son propre bouton.
///
/// UN SEUL WIDGET pour les cinq écrans. Le premier bouton existait en deux
/// versions — un rond au Menu, un étendu « Table » au Plan de salle.
///
/// ─── COULEUR ───────────────────────────────────────────────────────────────
///
/// `primaryDark` EN CLAIR, et non `primary` : une icône blanche sur `primary`
/// tombait sous 3:1 sur trois palettes (Emerald 2,54, Ocean 2,77, Sunset
/// 2,80) — le bouton était illisible sur trois palettes sur huit. Sur
/// `primaryDark`, 5,18:1 au minimum. En sombre, `colorScheme.primary` (qui y
/// vaut `primaryLight`).
///
/// ⚠ Limite connue, NON traitée ici : Midnight en sombre, où le bord du bouton
/// ne fait que 1,93:1 sur la surface (dette de palette, `docs/backlog.md`).
/// L'ombre l'aide sans la régler.
///
/// OMBRE NEUTRE et douce — la même que les cartes actives de Commandes. Un
/// élément qui flotte au-dessus du contenu a besoin d'une élévation ; sans
/// elle, il se confondrait avec les cartes en sombre. L'ancienne ombre teintée
/// à la marque était un ornement.
///
/// `Material` en cercle plutôt que `FloatingActionButton` : celui-ci impose
/// 56 px (40 en `.small`), et le rond de 48 est celui qu'on avait.
class RestoFab extends StatelessWidget {
  final String tooltip;
  final VoidCallback onPressed;

  const RestoFab({super.key, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Tooltip(
      message: tooltip,
      child: Container(
        width: kRestoFabSize,
        height: kRestoFabSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: theme.shadowColor.withValues(alpha: 0.07),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Material(
          color: dark ? cs.primary : AppColors.primaryDark,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Icon(Icons.add_rounded, size: 22, color: cs.onPrimary),
          ),
        ),
      ),
    );
  }
}
