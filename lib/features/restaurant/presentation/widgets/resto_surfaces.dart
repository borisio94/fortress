import 'dart:math' show pi;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Socle visuel du mode restaurant : un fond géométrique dessiné et des
/// panneaux translucides posés dessus.
///
/// Décliné dans les DEUX modes (clair et sombre), et ce n'est pas la même
/// recette : sur fond clair, des formes claires disparaissent ; sur fond
/// sombre, des formes sombres salissent. Les opacités s'inversent donc de sens,
/// et elles vivent toutes dans [RestoBackdropTokens] — aucune forme ne teste
/// elle-même la luminosité.

// ─── Fond, voile et panneaux ────────────────────────────────────────────────

/// Réglages du motif de fond, résolus UNE fois selon la luminosité.
///
/// Toutes les opacités du fond vivent ici : une forme lit un champ nommé, elle
/// ne teste jamais `Brightness` elle-même. Recopier le test à chaque forme,
/// c'est se garantir qu'un jour l'une d'elles ne suivra plus les autres.
class RestoBackdropTokens {
  /// Teinte principale — la couleur de la boutique, ramenée dans une plage
  /// utilisable comme fond.
  final Color tintA;

  /// Même TEINTE, autre luminosité. Voir [restoBackdropTokens] pour la raison
  /// d'être de cette contrainte.
  final Color tintB;

  /// Opacités, par nature de forme. Les valeurs sont plus hautes en sombre :
  /// sur un fond à L 5 %, une teinte à 6 % est simplement invisible — l'œil lit
  /// des écarts relatifs de luminance, pas des pourcentages absolus.
  final double glow;
  final double ring;
  final double frame;
  final double dot;

  const RestoBackdropTokens({
    required this.tintA,
    required this.tintB,
    required this.glow,
    required this.ring,
    required this.frame,
    required this.dot,
  });
}

/// Fabrique des tokens du fond — L'UNIQUE endroit où la luminosité est testée.
///
/// ─── POURQUOI UNE SEULE TEINTE ─────────────────────────────────────────────
///
/// Les deux teintes sont la MÊME, à deux luminosités. Une seconde teinte
/// obtenue par rotation a été mesurée sur les huit palettes et écartée :
///
///   • +32° donne du JAUNE sur `sunset` (#EDE222) et `amber` (#C1CE11) — deux
///     palettes dont la primaire est orange. Le fond cessait de se lire comme
///     une variation de la marque pour devenir une seconde identité.
///   • −32° est pire : `amber` y donne #CE1111, un rouge pur — exactement la
///     couleur d'erreur de l'app.
///
/// Si quelqu'un reprend l'idée, le test est déjà fait.
///
/// ─── POURQUOI NORMALISER ───────────────────────────────────────────────────
///
/// La teinte de la boutique ne peut pas servir telle quelle : la palette
/// `midnight` a une primaire à S 33 % / L 17 %, qui ne produit aucun halo
/// visible — surtout en sombre, où le fond est déjà à L 5 %. Saturation et
/// luminosité sont donc ramenées dans une plage de fond ; la TEINTE, elle, est
/// intacte. Midnight garde son bleu ardoise, en visible.
RestoBackdropTokens restoBackdropTokens(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final hsl = HSLColor.fromColor(AppColors.primary);
  // Plage de saturation : assez pour exister, pas assez pour crier.
  final s = hsl.saturation.clamp(0.45, 0.85);
  // En clair les formes sont plus SOMBRES que le fond, en sombre plus CLAIRES.
  final lA = dark ? 0.60 : 0.48;
  final lB = dark ? 0.74 : 0.62;

  return RestoBackdropTokens(
    tintA: hsl.withSaturation(s).withLightness(lA).toColor(),
    tintB: hsl.withSaturation(s).withLightness(lB).toColor(),
    glow: dark ? 0.10 : 0.06,
    ring: dark ? 0.12 : 0.08,
    frame: dark ? 0.09 : 0.06,
    dot: dark ? 0.14 : 0.10,
  );
}

/// Fond d'écran du mode restaurant : un motif géométrique DESSINÉ, posé sur un
/// dégradé profond, avec [child] par-dessus.
///
/// ─── POURQUOI DESSINÉ, ET NON UNE IMAGE ────────────────────────────────────
///
/// C'était une photo de salle (`assets/images/resto_backdrop.jpg`), à 80 %
/// d'opacité sous un voile de lisibilité. Le contraste dépendait alors de
/// l'image : les titres de carte et les états vides du tableau de bord se
/// lisaient par-dessus des chaises et un climatiseur, et rien ne garantissait
/// qu'une autre photo ferait mieux.
///
/// Un motif dessiné garantit ce qu'une photo ne peut pas : ses opacités sont
/// connues, bornées (0,06 à 0,14 — cf. [RestoBackdropTokens]) et identiques
/// d'un écran à l'autre. **Ne remettez pas d'image ici** : le problème n'était
/// pas cette photo-là, c'était le principe.
///
/// Le voile plein écran a disparu avec elle. Il servait à assombrir une image
/// imprévisible ; au-dessus d'un motif à 6-14 %, il ne ferait que l'effacer. Le
/// contraste a été mesuré avant et après : sur une carte, `captionHint` passe
/// de 5,88:1 à 5,87:1 en clair, et de 3,95:1 à 3,97:1 en sombre. À nu sur le
/// fond, 4,91 → 4,85 en clair et 3,30 → 3,47 en sombre. Le voile ne protégeait
/// rien — il ramenait la photo au niveau du dégradé, que le motif conserve.
///
/// Le dégradé RESTE la base : il porte la déclinaison clair/sombre et couvre
/// toute la surface. Le motif n'est qu'une couche par-dessus.
class RestoBackdrop extends StatelessWidget {
  final Widget child;

  const RestoBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: brightness == Brightness.dark
                  ? [kRestoBackdropDarkTop, const Color(0xFF0B0F14)]
                  : [const Color(0xFFFFFFFF), const Color(0xFFEFF1F5)],
            ),
          ),
        ),
        // UN SEUL `CustomPaint`, et non une dizaine de `Positioned`.
        //
        // Le motif ne change jamais : dix couches de composition recalculées à
        // chaque reconstruction du shell coûteraient pour rien, là où une passe
        // de peinture suffit. Elle est aussi hors flux et ne capte aucun
        // pointeur par nature — ce qu'un `IgnorePointer` aurait dû garantir sur
        // des widgets.
        Positioned.fill(
          child: CustomPaint(
            painter: _RestoPatternPainter(restoBackdropTokens(context)),
            // Décor pur : rien à annoncer aux lecteurs d'écran.
            isComplex: false,
          ),
        ),
        child,
      ],
    );
  }
}

/// Peint le motif : deux halos, deux anneaux, un cadre incliné, quelques points.
///
/// Tout est exprimé en FRACTIONS de la surface — le motif suit l'écran du
/// téléphone à la tablette sans qu'aucune position ne soit écrite en pixels.
class _RestoPatternPainter extends CustomPainter {
  final RestoBackdropTokens t;

  const _RestoPatternPainter(this.t);

  /// Halo : un disque dont la couleur s'éteint vers les bords. C'est la forme
  /// la plus large et la plus douce — elle donne la couleur d'ambiance, les
  /// autres ne font que la ponctuer.
  void _glow(Canvas canvas, Offset center, double radius, Color color) {
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color.withValues(alpha: t.glow), color.withValues(alpha: 0)],
        // L'arrêt intermédiaire évite un bord net : sans lui, un dégradé
        // linéaire laisse un cercle visible là où l'opacité atteint zéro.
        stops: const [0.0, 1.0],
      ).createShader(rect);
    canvas.drawCircle(center, radius, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // ── Halos, en coins opposés ────────────────────────────────────────
    _glow(canvas, Offset(w * 0.12, h * 0.10), w * 0.55, t.tintA);
    _glow(canvas, Offset(w * 0.92, h * 0.82), w * 0.48, t.tintB);

    // ── Anneaux épais ──────────────────────────────────────────────────
    // Épais et non fins : un trait de 1 px à 12 % disparaît, une bande de 20
    // se devine. C'est la masse qui porte la forme, pas le contour.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.045
      ..color = t.tintA.withValues(alpha: t.ring);
    canvas.drawCircle(Offset(w * 0.86, h * 0.14), w * 0.20, ring);

    final ring2 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.035
      ..color = t.tintB.withValues(alpha: t.ring);
    canvas.drawCircle(Offset(w * 0.08, h * 0.74), w * 0.16, ring2);

    // ── Cadre incliné, bordure fine seulement ──────────────────────────
    // Vide : rempli, il ferait un bloc de couleur au milieu de l'écran.
    final frame = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = t.tintA.withValues(alpha: t.frame);
    canvas.save();
    canvas.translate(w * 0.62, h * 0.42);
    canvas.rotate(-12 * pi / 180);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: w * 0.42, height: w * 0.42),
        Radius.circular(w * 0.06),
      ),
      frame,
    );
    canvas.restore();

    // ── Points ─────────────────────────────────────────────────────────
    // Petite surface, donc opacité plus haute : c'est le seul endroit où la
    // valeur monte à 0,14 en sombre.
    final dot = Paint()..color = t.tintB.withValues(alpha: t.dot);
    const spots = <Offset>[
      Offset(0.24, 0.32),
      Offset(0.41, 0.18),
      Offset(0.72, 0.62),
      Offset(0.33, 0.83),
      Offset(0.58, 0.91),
      Offset(0.90, 0.46),
    ];
    for (final s in spots) {
      canvas.drawCircle(Offset(w * s.dx, h * s.dy), 3, dot);
    }
  }

  /// Le motif est immuable : il ne se repeint que si les tokens changent,
  /// c'est-à-dire au basculement clair/sombre ou au changement de palette.
  @override
  bool shouldRepaint(_RestoPatternPainter old) =>
      old.t.tintA != t.tintA ||
      old.t.tintB != t.tintB ||
      old.t.glow != t.glow ||
      old.t.ring != t.ring ||
      old.t.frame != t.frame ||
      old.t.dot != t.dot;
}

/// Panneau translucide posé sur [RestoBackdrop] — l'équivalent d'une carte,
/// mais qui laisse deviner le fond.
///
/// À utiliser partout où le mode restaurant affichait une `Card` opaque.
class RestoGlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// Flou du fond sous le panneau. Coûteux sur le web quand il y en a
  /// beaucoup à l'écran : à laisser à `false` pour les petites tuiles
  /// répétées, à activer sur les grands panneaux.
  final bool blur;

  const RestoGlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 16,
    this.blur = false,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final border = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );

    Widget panel = DecoratedBox(
      decoration: BoxDecoration(
        color: restoGlassFill(context),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: restoGlassBorder(context)),
      ),
      child: Padding(padding: padding, child: child),
    );

    if (blur) {
      panel = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: panel,
        ),
      );
    }

    return Material(
      type: MaterialType.transparency,
      shape: border,
      // Ombre portée seulement en clair : sur fond sombre elle ne se voit pas
      // et coûte un repaint pour rien.
      child: dark
          ? panel
          : DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: panel,
            ),
    );
  }
}

/// Remplissage d'un panneau translucide. Exposé pour les widgets qui
/// construisent déjà leur propre conteneur et ne peuvent pas envelopper.
///
/// ─── RÈGLE DU MODULE : AUCUN TEXTE À NU SUR LA PHOTO ───────────────────────
///
/// Tout contenu textuel du mode restaurant repose sur une surface opaque à
/// ~85 %, sans exception. Une salle photographiée a des zones très claires et
/// des zones très sombres, et le recadrage change d'un écran à l'autre : le
/// même paragraphe tombe sur une nappe blanche ici et sur un mur noir là. Le
/// voile général du fond ne peut pas régler ça — il baisse le contraste de la
/// photo partout de la même manière, alors que le problème est LOCAL. C'est
/// donc la surface POSÉE SOUS LE TEXTE qui porte la lisibilité.
///
/// Concrètement, pour tout nouvel écran du module : le texte va dans un
/// [RestoGlassPanel], ou dans un conteneur peint avec cette teinte.
///
/// ─── EXCEPTION (24/09/2026) : LE DÉCOR GÉOMÉTRIQUE ─────────────────────────
///
/// **Le texte peut vivre sur le décor géométrique ; jamais sur une photo. Les
/// pastilles posées sur une photo gardent leur voile à 85 %.**
///
/// La règle ci-dessus a été écrite contre une PHOTO de salle, imprévisible.
/// [RestoBackdrop] n'en est plus une : c'est un dégradé et un motif
/// géométrique à faible opacité (6 à 14 %, cf. [RestoBackdropTokens]), donc
/// CALCULABLE — et il a été calculé. Pire cas sur les huit palettes (motif le
/// plus opaque sur la zone la plus claire ou la plus sombre du dégradé) :
///
///   • texte primaire  : ≥ 13,1:1 en clair, ≥ 12,2:1 en sombre ;
///   • texte secondaire : ≥ 5,6:1 en clair,  ≥ 5,2:1 en sombre.
///
/// Tout est au-dessus du seuil AA de 4,5:1. ⚠ NE PAS RÉTABLIR la contrainte
/// sur le décor en croyant bien faire : ces chiffres sont la raison de
/// l'exception. Elle tombe si le décor redevient une photo, ou si le motif
/// dépasse ~15 % d'opacité — il faut alors REMESURER, pas supposer.
///
/// Premier usage : la grille du Menu, dont le nom et le prix vivent sous la
/// photo sans carte autour.
///
/// En sombre, le panneau est TEINTÉ SOMBRE (et non blanc translucide) : un
/// voile blanc par-dessus une photo de salle éclairée délaverait le texte clair
/// posé dessus. C'est aussi ce que fait la maquette.
Color restoGlassFill(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF0B0F14).withValues(alpha: 0.86)
        : Colors.white.withValues(alpha: 0.91);

/// Bordure d'un panneau translucide.
Color restoGlassBorder(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.07);

/// Remplissage d'un élément DANS un panneau (ligne de liste, tuile) — un cran
/// plus marqué que le panneau qui le porte, sinon il disparaît dedans.
/// Le décor restaurant est-il actif pour l'écran courant ?
///
/// Mis à jour par `AdaptiveScaffold` à chaque construction du shell — c'est le
/// seul endroit qui connaît le `shopId`. Les widgets PARTAGÉS (feuilles de
/// formulaire, dialogues de confirmation, navigation basse) le consultent pour
/// devenir translucides, sans avoir à recevoir un `shopId` qu'ils n'ont pas et
/// qu'il faudrait plomber à travers des dizaines d'appels.
///
/// Volontairement un simple drapeau et non un provider : ces widgets sont
/// ouverts via `showModalBottomSheet`/`showDialog`, dont le contexte est celui
/// du Navigator racine — il n'a donc pas le shell parmi ses ancêtres et ne peut
/// pas remonter jusqu'à la boutique.
bool restoDecorActive = false;

// `restoModalFill` a été SUPPRIMÉ : les surfaces modales du mode restaurant
// (feuilles, dialogues) sont désormais OPAQUES, comme partout ailleurs dans
// l'app. Même translucide à 90 %, une feuille laissait lire la page en dessous
// — et ce n'était pas le décor de salle qui transparaissait, c'était l'écran
// que la feuille recouvrait. Le fond se prend maintenant dans le thème, une
// fois pour toutes, dans `showFormSheet`.

/// Rend une couleur d'incrustation OPAQUE en la composant sur la surface du
/// thème.
///
/// À utiliser pour les BOUTONS : un fond en `alpha` laisse passer le décor et
/// délave le libellé. Composer d'abord donne la même teinte, en pleine opacité.
Color restoOpaqueOverlay(BuildContext context, double alpha) {
  final cs = Theme.of(context).colorScheme;
  return Color.alphaBlend(cs.onSurface.withValues(alpha: alpha), cs.surface);
}

/// Teinte du CHROME de l'application en mode restaurant : barre latérale de
/// navigation et barre supérieure.
///
/// Plus opaque que les panneaux de contenu : ce sont des repères permanents,
/// leurs libellés doivent rester lisibles quelle que soit la zone de la photo
/// qui passe derrière (la salle a des zones très claires et très sombres).
/// Mais suffisamment translucide pour que le décor se devine — c'est
/// exactement ce qui était demandé.
Color restoChromeFill(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF0B0F14).withValues(alpha: 0.82)
        : Colors.white.withValues(alpha: 0.90);

/// Départ (coin haut-gauche) du dégradé du décor en SOMBRE — là où vivent la
/// barre du haut et le haut de la barre latérale.
const Color kRestoBackdropDarkTop = Color(0xFF10161D);

/// Fond OPAQUE de la barre du haut (ordinateur) et de l'AppBar (mobile) en mode
/// restaurant — DÉRIVÉ, jamais choisi.
///
/// POURQUOI (25/09/2026) : `080bcf1` a rendu la barre OPAQUE — le décor qui la
/// traversait dessinait une bande claire — en prenant `colorScheme.surface`.
/// En clair, c'est du blanc et la barre se confond avec le verre du contenu
/// (1,009:1). En SOMBRE, c'est `#1E293B`, la surface des CARTES : un slate
/// bleuté, seul bloc hors de la famille quasi-noire du chrome (barre latérale,
/// [restoChromeFill]) et du contenu ([restoGlassFill]) — 1,30:1 d'écart, et
/// une autre teinte.
///
/// La règle : le verre du CONTENU composé sur le haut du décor — même teinte
/// que le bloc du dessous, sans transparence. ≈ `#0C1015` en sombre. En clair,
/// `colorScheme.surface`, inchangé (le composé donnerait le même blanc).
Color restoChromeOpaque(BuildContext context) {
  final theme = Theme.of(context);
  if (theme.brightness != Brightness.dark) return theme.colorScheme.surface;
  return Color.alphaBlend(restoGlassFill(context), kRestoBackdropDarkTop);
}

/// Composé PAR-DESSUS un panneau déjà opacifié : un blanc très léger suffit
/// alors à faire ressortir l'élément, dans les deux modes.
Color restoGlassInner(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.white.withValues(alpha: 0.72);

/// Décoration en RELIEF d'un panneau du tableau de bord.
///
/// Quatre effets qui, ensemble, donnent l'impression d'une plaque BISEAUTÉE
/// posée sur le fond — aucun ne suffit seul :
///
///   1. un LISERÉ LUMINEUX sur les premiers pour cent de la hauteur : c'est le
///      chanfrein, la tranche vive du bord supérieur. C'est lui qui fait le
///      plus pour la sensation d'épaisseur, bien plus qu'un dégradé long ;
///   2. un DÉGRADÉ vertical, clair en haut et nettement plus sombre en bas.
///      Notre œil suppose une lumière venue d'en haut : une surface uniforme
///      se lit comme un aplat quoi qu'on mette autour ;
///   3. des ARÊTES contrastées — le haut clair, le bas sombre et plus épais,
///      comme l'ombre propre sous une plaque ;
///   4. TROIS OMBRES portées : une de contact, très proche et nette, qui pose
///      la carte ; une principale, décalée, qui la soulève ; une ambiante,
///      large et diffuse, qui l'ancre dans la scène. Une ombre unique donne
///      un halo, jamais du volume.
///
/// Intensité RÉGLÉE EN DEUX TEMPS : une première version trop discrète — le
/// fond photographique du mode restaurant mange les nuances faibles —, puis
/// une seconde trop appuyée, où la tranche devenait un trait dessiné et où les
/// ombres de deux cartes voisines se recouvraient. Le réglage actuel se tient
/// entre les deux.
///
/// Tout se règle ici : les cartes de tout le tableau de bord suivent. Si le
/// relief doit encore bouger, ce sont les TROIS OMBRES et le premier arrêt du
/// dégradé qu'il faut toucher, dans cet ordre — les bordures ne font que
/// souligner ce qu'ils ont déjà posé.
///
/// [radius] doit être celui de la carte, sinon l'ombre déborde des angles.
/// [accent] teinte l'arête supérieure — un panneau peut ainsi s'annoncer par
/// sa tranche (vert, orange ou rouge sur la carte Food cost).
BoxDecoration restoReliefDecoration(
  BuildContext context, {
  double radius = 16,
  Color? accent,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final base = restoGlassFill(context);

  Color lighten(double a) =>
      Color.alphaBlend(Colors.white.withValues(alpha: a), base);
  Color darken(double a) =>
      Color.alphaBlend(Colors.black.withValues(alpha: a), base);

  return BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    // Le dégradé part du remplissage habituel : les cartes gardent la
    // translucidité du mode restaurant, elles ne deviennent pas opaques.
    //
    // Trois arrêts, pas deux : le premier segment est très court et très
    // clair — c'est le chanfrein. Un dégradé linéaire simple étale cette
    // lumière sur toute la hauteur et la dilue jusqu'à l'invisible.
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: const [0.0, 0.10, 1.0],
      colors: [
        lighten(dark ? 0.16 : 0.80),
        lighten(dark ? 0.08 : 0.62),
        darken(dark ? 0.16 : 0.06),
      ],
    ),
    border: Border(
      // Tranche supérieure à peine épaissie : c'est le bord qu'on voit d'une
      // plaque regardée d'un peu au-dessus, la position réelle d'un écran de
      // salle. À 1,6 px et plein blanc, elle devenait un trait dessiné.
      top: BorderSide(
          color: accent ??
              Colors.white.withValues(alpha: dark ? 0.28 : 0.80),
          width: 1.2),
      left: BorderSide(
          color: Colors.white.withValues(alpha: dark ? 0.11 : 0.45)),
      right: BorderSide(
          color: Colors.black.withValues(alpha: dark ? 0.18 : 0.05)),
      bottom: BorderSide(
          color: Colors.black.withValues(alpha: dark ? 0.40 : 0.13),
          width: 1.2),
    ),
    boxShadow: [
      // Contact — proche et peu floue : elle POSE la carte. Sans elle, tout
      // flotte. C'est la dernière qu'il faudrait retirer.
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.30 : 0.08),
        blurRadius: 3,
        offset: const Offset(0, 2),
      ),
      // Principale — c'est elle qui donne la hauteur.
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.38 : 0.11),
        blurRadius: 15,
        offset: const Offset(0, 6),
      ),
      // Ambiante — large et très diffuse, elle ancre la carte dans la scène
      // au lieu de la découper au ciseau. Raccourcie : à 18 px de décalage,
      // les ombres de deux cartes voisines se recouvraient et l'ensemble
      // paraissait sale.
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.20 : 0.05),
        blurRadius: 26,
        spreadRadius: -4,
        offset: const Offset(0, 10),
      ),
    ],
  );
}
