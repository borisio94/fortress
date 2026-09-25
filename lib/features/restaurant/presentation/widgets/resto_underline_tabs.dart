import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';

/// Un onglet : son libellé et son compteur.
class RestoUnderlineTab {
  final String label;
  final int count;

  /// Un onglet VIDE s'efface (`textHint`)… sauf celui qui n'en est pas un
  /// filtre : « Toutes », « Tout ». Vide, il dit que l'écran est vide, ce qui
  /// n'a rien de secondaire.
  final bool mutedWhenEmpty;

  /// Pictogramme FACULTATIF, devant le libellé, à sa couleur.
  ///
  /// Pour les écrans où le mot seul ne suffit pas à distinguer deux onglets
  /// d'un coup d'œil — le Stock, dont les deux natures (ingrédients,
  /// fournitures) reprennent les pictogrammes de leurs états vides. Commandes
  /// et le Menu ne le passent pas.
  final IconData? icon;

  const RestoUnderlineTab({
    required this.label,
    required this.count,
    this.mutedWhenEmpty = true,
    this.icon,
  });
}

/// ONGLETS SOULIGNÉS du module restaurant — Commandes et Menu.
///
/// Ni fond ni contour : le libellé, son compteur en atténué, et un trait de
/// 1,5 px à la couleur de marque sous l'onglet actif. La hiérarchie passe par
/// la typographie, pas par des pastilles.
///
/// L'ACTIF SE LIT AUSSI SANS LE TRAIT, par sa graisse et sa couleur de texte.
/// C'est voulu : sur Midnight en sombre, la primaire ne fait que 1,93:1 sur la
/// carte (cf. `docs/backlog.md`, dette de palette) — le trait y est à peine
/// visible, et ne doit pas être seul à parler.
///
/// `textHint` est réservé aux onglets vides : en sombre il ne fait que 3,07:1,
/// sous le seuil du petit texte. Tout le reste de l'atténué est en
/// `textSecondary`.
///
/// Raisonne PAR INDEX : chaque écran garde son propre
/// vocabulaire (rang de service, catégorie) et le traduit à l'appel.
class RestoUnderlineTabs extends StatelessWidget {
  final List<RestoUnderlineTab> items;
  final int selected;
  final ValueChanged<int> onSelect;

  const RestoUnderlineTabs({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        for (var i = 0; i < items.length; i++)
          Builder(builder: (context) {
            final t = items[i];
            final active = i == selected;
            final muted = t.count == 0 && t.mutedWhenEmpty;
            final labelColor = active
                ? cs.onSurface
                : muted
                    ? AppColors.textHint
                    : AppColors.textSecondary;
            return InkWell(
              onTap: () => onSelect(i),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: active ? cs.primary : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                ),
                child: Text.rich(
                  TextSpan(children: [
                    if (t.icon != null) ...[
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Icon(t.icon, size: 15, color: labelColor),
                      ),
                      const TextSpan(text: ' '),
                    ],
                    TextSpan(
                        text: t.label,
                        style: (active
                                ? AppTextStyles.bodySmBold
                                : AppTextStyles.bodySm)
                            .copyWith(color: labelColor)),
                    if (t.count > 0)
                      TextSpan(
                          text: '  ${t.count}',
                          style: AppTextStyles.caption.copyWith(
                              color: muted
                                  ? AppColors.textHint
                                  : AppColors.textSecondary)),
                  ]),
                  maxLines: 1,
                ),
              ),
            );
          }),
      ]),
    );
  }
}

/// LES MÊMES ONGLETS, reliés à un `TabController` — pour les écrans qui
/// balaient leurs onglets avec une `TabBarView` (Finances, Personnel).
///
/// Remplace la `TabBar` Material (25/09/2026) : son libellé ET son trait
/// étaient en primaire, et sur une palette où la primaire est faible en clair
/// plus rien ne distinguait l'onglet actif. Ici l'actif se lit aussi par la
/// graisse et la couleur du texte (cf. [RestoUnderlineTabs]).
///
/// Le contrôleur reste la source : l'onglet actif le SUIT (tap comme
/// balayage), un tap l'ANIME. Rien de la navigation ne change.
///
/// Libellés SEULS, sans compteur : sur ces écrans les données se chargent
/// dans chaque onglet, pas au niveau de la page — les remonter toucherait à la
/// logique.
class RestoUnderlineTabBar extends StatelessWidget {
  final List<String> labels;

  const RestoUnderlineTabBar({super.key, required this.labels});

  @override
  Widget build(BuildContext context) {
    final controller = DefaultTabController.of(context);
    // À GAUCHE quel que soit le parent : dans une `Column` qui n'étire pas,
    // une rangée défilante plus étroite que l'écran se centrerait.
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => RestoUnderlineTabs(
        items: [
          for (final l in labels)
            // `mutedWhenEmpty: false` : sans compteur, un onglet n'est pas
            // « vide » — il ne doit pas s'éteindre.
            RestoUnderlineTab(label: l, count: 0, mutedWhenEmpty: false),
        ],
        selected: controller.index,
        onSelect: controller.animateTo,
      ),
      ),
    );
  }
}
