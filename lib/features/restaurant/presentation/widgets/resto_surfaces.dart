import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Socle visuel du mode restaurant : un fond photographique flouté et des
/// panneaux translucides posés dessus.
///
/// Décliné dans les DEUX modes (clair et sombre) : la photo est la même, seul
/// le voile change de sens — sombre sur fond sombre, clair sur fond clair.
/// Sans cette double déclinaison, le sélecteur clair/sombre de l'app n'aurait
/// plus d'effet sur la restauration.

// ─── Voile et panneaux ──────────────────────────────────────────────────────

/// Fond d'écran du mode restaurant : une photo de salle posée sur un dégradé
/// profond, avec [child] par-dessus.
///
/// **Comment changer la photo** : dépose ton image sous [photoAsset]
/// (`assets/images/resto_backdrop.jpg`). Le dossier est déjà déclaré dans
/// `pubspec.yaml`, il n'y a rien d'autre à faire.
///
/// **Si le fichier est absent, seul le dégradé s'affiche** — exactement le
/// rendu d'avant. C'est volontaire : un asset manquant ne doit jamais casser
/// l'écran de quelqu'un en plein service.
///
/// Le dégradé RESTE peint sous la photo, il n'est pas remplacé par elle. Il
/// couvre les bords quand le format de l'image ne correspond pas à celui de
/// l'écran, et il porte la déclinaison clair/sombre : sans lui, le mode sombre
/// afficherait du blanc brut autour d'une photo recadrée.
class RestoBackdrop extends StatelessWidget {
  final Widget child;

  /// Photo de salle. Absente du dépôt par défaut (cf. doc de classe).
  static const String photoAsset = 'assets/images/resto_backdrop.jpg';

  /// Opacité de la photo. À 0,8 elle domine tout en laissant le dégradé
  /// l'habiller — au-delà, les panneaux translucides posés dessus perdent en
  /// lisibilité, surtout en mode clair.
  static const double photoOpacity = 0.8;

  /// Le voile posé sur la photo est [restoChromeFill] — EXACTEMENT la teinte
  /// de la barre latérale et de la barre supérieure.
  ///
  /// La zone de contenu et le chrome reçoivent ainsi le même traitement : le
  /// décor a la même présence partout, et aucune zone de l'écran n'est plus
  /// chargée qu'une autre. C'est la fonction elle-même qui est réutilisée, pas
  /// sa valeur recopiée — les deux ne peuvent donc pas diverger si le réglage
  /// change un jour.

  const RestoBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: brightness == Brightness.dark
                  ? [const Color(0xFF10161D), const Color(0xFF0B0F14)]
                  : [const Color(0xFFFFFFFF), const Color(0xFFEFF1F5)],
            ),
          ),
        ),
        Opacity(
          opacity: photoOpacity,
          child: Image.asset(
            photoAsset,
            fit: BoxFit.cover,
            // `cover` recadre plutôt que déformer : une salle étirée sur un
            // écran large se voit immédiatement.
            alignment: Alignment.center,
            // Asset absent → on retombe sur le dégradé seul, sans erreur.
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            // Décor pur : les lecteurs d'écran n'ont rien à annoncer avant
            // chaque page.
            excludeFromSemantics: true,
          ),
        ),
        // Voile de lisibilité, à l'opacité du chrome (cf. doc de classe). Sans
        // lui, la zone de contenu affichait la photo en pleine force sous des
        // textes écrits à nu — paragraphe d'aide, état vide — illisibles.
        Positioned.fill(
          child: ColoredBox(color: restoChromeFill(context)),
        ),
        child,
      ],
    );
  }
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
/// [RestoGlassPanel], ou dans un conteneur peint avec cette teinte. Un `Text`
/// posé directement sur [RestoBackdrop] est un défaut, même s'il se lit sur la
/// photo du moment.
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

/// Fond des surfaces MODALES en mode restaurant (feuilles, dialogues).
///
/// Plus opaque que les panneaux de contenu : une boîte de dialogue demande une
/// décision, son texte doit primer sur le décor.
Color restoModalFill(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF0B0F14).withValues(alpha: 0.90)
        : Colors.white.withValues(alpha: 0.93);

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
