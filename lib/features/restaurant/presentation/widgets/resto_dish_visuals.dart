import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../../../shared/widgets/product_image_card.dart';
import 'resto_surfaces.dart';

/// Ce que partagent les écrans qui MONTRENT des plats — le tableau de bord et
/// la carte.
///
/// Extrait du tableau de bord, où ces deux-là étaient privés : la refonte de
/// l'écran Menu en avait besoin, et deux copies auraient divergé dès la
/// première retouche — un plat sans photo n'aurait plus eu la même couleur
/// d'un écran à l'autre, ce qui est précisément ce que la dérivation cherche à
/// éviter.

/// Teinte stable d'un plat, dérivée de son NOM.
///
/// `hashCode` suffit : on ne cherche pas une répartition parfaite des teintes,
/// seulement qu'un plat garde SA couleur. Saturation et clarté sont prises sur
/// l'accent de la boutique, donc la famille de couleurs reste celle du thème.
///
/// Exposée — et non recopiée — parce que deux écrans s'en servent avec des
/// FORMES différentes : le tableau de bord pose l'initiale dans un cercle de
/// 62 px, la carte du menu la pose sur un aplat plein cadre. Seule la teinte
/// est commune, et deux copies auraient divergé dès la première retouche : le
/// même plat n'aurait plus eu la même couleur d'un écran à l'autre, ce qui est
/// exactement ce que la dérivation cherche à éviter.
Color restoDishTint(BuildContext context, Product product) {
  final hue = (product.name.hashCode.abs() % 360).toDouble();
  final base = HSLColor.fromColor(Theme.of(context).colorScheme.primary);
  return HSLColor.fromAHSL(1, hue, 0.35, base.lightness).toColor();
}

/// Lettre qui représente un plat sans photo. `?` si le nom est vide — un plat
/// peut être enregistré à la hâte et renommé après.
String restoDishInitial(Product product) {
  final name = product.name.trim();
  return name.isEmpty ? '?' : name.characters.first.toUpperCase();
}

/// Contenu d'une vignette de plat : sa photo, ou son INITIALE.
///
/// Un plat sans photo tombait sur le placeholder générique de
/// [ProductImageCard] — le même pour tous, ce qui rendait deux plats sans photo
/// indistinguables dans une rangée. L'initiale les sépare, et la teinte dérivée
/// du nom fait que le même plat garde la même couleur d'un écran à l'autre.
///
/// À poser dans un `ClipOval` ou un `ClipRRect` par l'appelant : ce widget
/// remplit l'espace qu'on lui donne, il ne décide pas de sa forme.
class RestoDishAvatar extends StatelessWidget {
  final Product product;

  /// Taille de l'initiale. Le tableau de bord la montre dans 62 px, la carte
  /// dans 70 : l'échelon typographique suit, sinon la lettre flotte dans un
  /// cercle trop grand.
  final TextStyle? initialStyle;

  const RestoDishAvatar({
    super.key,
    required this.product,
    this.initialStyle,
  });

  @override
  Widget build(BuildContext context) {
    final url = product.mainImageUrl;
    if (url != null && url.isNotEmpty) {
      return ProductImageCard(
        imageUrl: url,
        fillParent: true,
        borderRadius: BorderRadius.zero,
      );
    }
    final tint = restoDishTint(context, product);
    return ColoredBox(
      color: tint.withValues(alpha: 0.18),
      child: Center(
        child: Text(restoDishInitial(product),
            style: (initialStyle ?? AppTextStyles.subtitleBold)
                .copyWith(color: tint)),
      ),
    );
  }
}

/// Surface d'une carte des écrans restaurant.
///
/// Translucide, bordure de 0,5 px — posée sur le motif du fond sans le
/// masquer. Elle a remplacé le relief à trois ombres, dessiné à l'époque pour
/// se détacher d'une PHOTO : le fond dessiné n'a plus besoin qu'on crie
/// par-dessus.
///
/// PAS de flou d'arrière-plan, et c'est délibéré : ces écrans portent huit
/// cartes à la fois, et `RestoGlassPanel` documente déjà que le
/// `BackdropFilter` coûte cher sur le web dès qu'il se répète. La
/// translucidité du remplissage suffit à laisser deviner le motif.
BoxDecoration restoCardSurface(BuildContext context, {double radius = 17}) =>
    BoxDecoration(
      color: restoGlassFill(context),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: restoGlassBorder(context), width: 0.5),
    );
