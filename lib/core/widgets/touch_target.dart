import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// CIBLES TACTILES — 48 px au doigt, la densité d'origine à la souris.
///
/// ─── POURQUOI ───────────────────────────────────────────────────────────────
///
/// Le thème (`app_theme.dart`) dimensionne les boutons au CONTENU
/// (`minimumSize: Size.zero`, padding vertical 3) : 26 à 32 px de haut. À la
/// souris c'est une densité voulue ; au doigt, c'est une cible manquée. Les
/// gestes du service (− / + du panier, ⋮ d'une table) descendaient à 28 et
/// 26 × 22 px.
///
/// ─── LA RÈGLE ────────────────────────────────────────────────────────────────
///
/// Au TACTILE SEULEMENT ([isTouchPlatform]) : toute cible monte à
/// [kMinTouchTarget] (48 px, `kMinInteractiveDimension` de Material). Sur
/// ordinateur, rien ne bouge — la souris n'a pas besoin de 48 px, et
/// l'agrandissement coûterait de la densité aux écrans de gestion.
///
/// ⚠ UNE CIBLE NE PEUT PAS DÉPASSER SA BOÎTE. En Flutter, un appui hors des
/// limites d'un widget ne l'atteint pas : pour une cible de 48 px, la boîte
/// fait 48 px, et LA RANGÉE GRANDIT. C'est le prix, accepté (25/09/2026).
///
/// ⚠ DEUX PIÈGES, VÉRIFIÉS AU LOT 2 :
///   • Un parent à HAUTEUR FIXE qui laisse sa colonne libre (tuile de table,
///     `mainAxisExtent: 82`) : la rangée qui grandit fait DÉBORDER la tuile.
///     Là, ne pas envelopper — superposer une zone de 48 px (voir le ⋮ de
///     `restaurant_tables_page.dart`).
///   • Un parent à hauteur fixe qui CONTRAINT son enfant (puce de 38 px) : la
///     contrainte du parent l'emporte, la cible plafonne à sa hauteur, sans
///     erreur. Pas de casse — mais pas 48 non plus.
class TouchTarget extends StatelessWidget {
  /// Le geste. `null` : cible inerte (l'enfant garde son propre état désactivé).
  final VoidCallback? onTap;

  /// Le dessin, INCHANGÉ : il reste centré dans la zone agrandie. S'il porte
  /// son propre `InkWell`, un appui direct garde son ondulation ; un appui dans
  /// la marge déclenche le même geste, sans ondulation.
  final Widget child;

  /// Côté minimal de la zone au tactile.
  final double minSize;

  const TouchTarget({
    super.key,
    required this.onTap,
    required this.child,
    this.minSize = kMinTouchTarget,
  });

  @override
  Widget build(BuildContext context) {
    if (!isTouchPlatform) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
        child: Center(widthFactor: 1, heightFactor: 1, child: child),
      ),
    );
  }
}

/// Côté minimal d'une cible au doigt : 48 px (Material, `kMinInteractiveDimension`).
const double kMinTouchTarget = kMinInteractiveDimension;

/// L'appareil se pilote-t-il au DOIGT ?
///
/// Android ou iOS. Sur le web, Flutter déduit `defaultTargetPlatform` de
/// l'agent du navigateur : un téléphone y est reconnu comme tel.
///
/// LIMITE CONNUE, NON CONTOURNÉE (décision du 25/09/2026) : un iPad sous
/// Safari (iPadOS 13 et suivants) s'annonce comme un Mac. Il est traité comme
/// un ordinateur — densité de bureau, cibles non agrandies. Ne pas tenter de
/// le détecter autrement (taille d'écran, agent) : c'est un pari, et il
/// agrandirait aussi les petits écrans d'ordinateur.
bool get isTouchPlatform =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// `VisualDensity.compact` à la souris, standard au doigt — pour les
/// `IconButton` compacts des gestes fréquents : standard leur rend 48 px.
VisualDensity get compactUnlessTouch =>
    isTouchPlatform ? VisualDensity.standard : VisualDensity.compact;

/// `tapTargetSize` des boutons du thème : `padded` (zone de 48 px, dessin
/// inchangé) au doigt, `shrinkWrap` (densité de bureau) à la souris.
MaterialTapTargetSize get adaptiveTapTargetSize => isTouchPlatform
    ? MaterialTapTargetSize.padded
    : MaterialTapTargetSize.shrinkWrap;
