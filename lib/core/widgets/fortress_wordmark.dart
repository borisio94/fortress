import 'package:flutter/material.dart';

/// LE MOT-SYMBOLE « FORTRESS ».
///
/// Il était écrit deux fois en `TextStyle` inline dans `login_page` — une fois
/// pour le téléphone, une fois pour le panneau de bureau — avec
/// `fontFamily: 'Georgia'` dans les deux cas.
///
/// GEORGIA N'EST PAS EMBARQUÉE. `pubspec.yaml` ne déclare qu'Inter : la police
/// tombait donc sur une sans-serif de repli sur Android et sur tout appareil
/// qui ne la possède pas. Le mot-symbole était serif sur Windows et sans
/// ailleurs — la marque ne se ressemblait pas d'un appareil à l'autre, ce qui
/// est exactement ce qu'un mot-symbole doit éviter.
///
/// Il utilise donc la police EMBARQUÉE, la seule qui rende identique partout.
///
/// ─── SES TAILLES SONT HORS DE L'ÉCHELLE, ET C'EST VOULU ────────────────────
///
/// 15 et 20 ne figurent pas dans les échelons d'`AppTextStyles`
/// (10/11/12/13/14/16/18), et ne doivent pas y être ramenées : un mot-symbole
/// est un élément GRAPHIQUE, pas du texte courant. Sa taille se règle sur le
/// logo qu'il accompagne — 84 dp sur téléphone, 128 dp sur le panneau — et non
/// sur la hiérarchie typographique des écrans.
///
/// C'est pour tenir cette exception en UN SEUL endroit, au lieu de deux
/// `fontSize` en dur dans une page, que ce widget existe.
class FortressWordmark extends StatelessWidget {
  /// `false` = téléphone (15 dp), `true` = panneau de bureau (20 dp).
  final bool large;

  /// `null` → `colorScheme.onSurface`.
  final Color? color;

  const FortressWordmark({super.key, this.large = false, this.color});

  @override
  Widget build(BuildContext context) => Text(
        'FORTRESS',
        style: TextStyle(
          fontSize: large ? 20 : 15,
          fontWeight: FontWeight.w600,
          // L'espacement suit la taille : serré, un mot-symbole capitale perd
          // sa respiration et se lit comme un mot ordinaire.
          letterSpacing: large ? 5 : 3,
          color: color ?? Theme.of(context).colorScheme.onSurface,
        ),
      );
}
