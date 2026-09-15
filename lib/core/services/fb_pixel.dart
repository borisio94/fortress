// Pixel Facebook (Meta) — façade multiplateforme.
//
// Ce fichier est le STUB par défaut (mobile / desktop) : aucune dépendance
// web, toutes les fonctions sont des no-op. L'implémentation réelle vit dans
// `fb_pixel_web.dart` et n'est compilée que sur le web grâce à l'import
// conditionnel côté consommateur :
//
//   import 'fb_pixel.dart'
//       if (dart.library.html) 'fb_pixel_web.dart';
//
// Règle produit : le pixel ne s'active QUE sur les pages publiques
// `/catalogue/:shopId`, jamais sur les pages internes Fortress, et uniquement
// si le commerçant a connecté un ID de pixel. Voir CataloguePage.

/// Injecte le script du Pixel Meta (init + PageView) dans le `<head>`.
/// No-op hors web, si [pixelId] est vide, ou si déjà injecté.
void initFacebookPixel(String pixelId) {}

/// Remonte un évènement standard Meta (`ViewContent`, `AddToCart`,
/// `Purchase`…). No-op hors web ou si le pixel n'a pas été injecté.
void trackFacebookEvent(String event, [Map<String, Object?>? params]) {}
