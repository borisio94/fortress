/// GÉOMÉTRIE DE LA GRILLE DU MENU — règles pures, sans Flutter.
///
/// La grille calcule la HAUTEUR de chaque tuile à partir de ce qu'elle porte,
/// ligne par ligne ; la tuile, elle, rend ces lignes. Les deux doivent tomber
/// juste au pixel, sans quoi le bloc texte déborde ou laisse un trou. Tant que
/// le calcul vivait au milieu du widget, rien n'empêchait l'un de changer sans
/// l'autre : il vit ici, sous test, et le widget le lit.
library;

/// Largeur SOUS laquelle une colonne cesse d'être lisible. Les colonnes se
/// déduisent de ce plancher, jamais de seuils d'écran : 4 colonnes dès ~860 dp
/// de contenu, 2 sur téléphone.
const double kMenuColMin = 200;

/// Nombre de colonnes : 2 au minimum (téléphone), 8 au plus.
///
/// Plafond à HUIT : au-delà de ~1 700 dp, une grille qui cesse d'ajouter des
/// colonnes élargit ses tuiles, et la photo — bornée en hauteur — tourne à la
/// bannière.
const int kMenuColsMin = 2;
const int kMenuColsMax = 8;

/// Écart entre tuiles, dans les deux sens.
const double kMenuGap = 14;

/// Hauteur de photo : un RATIO de la largeur, borné aux deux bouts.
///
/// Ni le ratio seul — 300 dp de haut sur une tuile large — ni une hauteur
/// fixe, qui donnerait un carré sur téléphone et un timbre-poste sur tablette.
/// Plafond à 150 (et non plus 168) : la photo est désormais le bloc entier de
/// la tuile, sans carte autour, et à 168 elle écrasait le nom et le prix.
const double kMenuPhotoRatio = 0.78;
const double kMenuPhotoMin = 104;
const double kMenuPhotoMax = 150;

/// Bloc texte sous la photo — ses marges et ses lignes, dans l'ordre du rendu.
///
/// Chaque ligne est `taille × interligne` de son échelon typographique :
/// nom `bodySmBold` (12 × 1,45), état `micro` (10 × 1,3), prix `subtitle`
/// (16 × 1,35). Changer un échelon dans la tuile SANS le changer ici fait
/// déborder le texte : c'est ce que le test verrouille.
const double kMenuTextTop = 8;
const double kMenuNameToState = 2;
const double kMenuStateToPrice = 2;
const double kMenuTextBottom = 4;

typedef MenuGridLayout = ({int cols, double tileWidth, double photoHeight});

/// Colonnes, largeur de tuile et hauteur de photo pour [inner] dp de contenu
/// (marges latérales déjà retirées).
MenuGridLayout menuGridLayout(double inner) {
  final cols = (inner / kMenuColMin).floor().clamp(kMenuColsMin, kMenuColsMax);
  final w = (inner - kMenuGap * (cols - 1)) / cols;
  final photo = (w * kMenuPhotoRatio).clamp(kMenuPhotoMin, kMenuPhotoMax);
  return (cols: cols, tileWidth: w, photoHeight: photo.toDouble());
}

/// Hauteur totale d'une tuile. [scale] applique le facteur de police de
/// l'utilisateur (`TextScaler.scale`) : le texte grandit, la photo non.
///
/// La ligne d'état est RÉSERVÉE même quand le plat est disponible : c'est ce
/// qui garde la même hauteur d'une tuile à l'autre.
double menuTileHeight(double photoHeight, double Function(double) scale) =>
    photoHeight +
    kMenuTextTop +
    scale(12) * 1.45 + // nom
    kMenuNameToState +
    scale(10) * 1.3 + // état, réservé
    kMenuStateToPrice +
    scale(16) * 1.35 + // prix
    kMenuTextBottom;
