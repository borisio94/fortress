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
/// En sombre, le panneau est TEINTÉ SOMBRE (et non blanc translucide) : un
/// voile blanc par-dessus une photo de salle éclairée délaverait le texte clair
/// posé dessus. C'est aussi ce que fait la maquette.
/// Opacité montée en même temps que le voile baissait : c'est le panneau qui
/// porte désormais toute la lisibilité du texte.
Color restoGlassFill(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF0B0F14).withValues(alpha: 0.74)
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
