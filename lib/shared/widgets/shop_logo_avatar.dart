import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/utils/shop_monogram.dart';
import '../../core/widgets/fortress_logo.dart';

/// Avatar de boutique. Trois replis, dans cet ordre.
///
///   1. [logoUrl] — le logo posé par la boutique. Il passe toujours devant :
///      c'est le seul des trois qui soit un choix.
///   2. Le MONOGRAMME tiré de [shopName]. Il identifie la boutique, là où le
///      pictogramme générique n'identifiait rien.
///   3. Le logo Fortress, quand le nom ne donne aucune lettre — nom vide,
///      ponctuation seule, émojis. Une pastille vide serait pire.
///
/// Le monogramme est arrivé parce que l'avatar affichait le bouclier Fortress
/// dès qu'aucun logo n'était posé, c'est-à-dire presque toujours : le même
/// dessin pour toutes les boutiques, à 34 dp. La règle d'extraction vit dans
/// `shop_monogram.dart`, avec ses tests.
///
/// [shopName] est FACULTATIF, et son absence rétablit exactement le
/// comportement d'avant : les appelants qui ne le passent pas retombent sur le
/// bouclier. Aucun écran ne change sans l'avoir demandé.
///
/// Deux variantes via [variant] :
///   * `light` — fond clair (drawer en mode clair).
///   * `dark`  — fond foncé (drawer sombre, header violet de Paramètres).
class ShopLogoAvatar extends StatelessWidget {
  final String? logoUrl;

  /// Nom de la boutique, source du monogramme. `null` → bouclier Fortress.
  final String? shopName;

  final double size;
  final ShopLogoAvatarVariant variant;

  const ShopLogoAvatar({
    super.key,
    this.logoUrl,
    this.shopName,
    this.size = 40,
    this.variant = ShopLogoAvatarVariant.light,
  });

  bool get _isDark => variant == ShopLogoAvatarVariant.dark;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size / 4);
    final bgColor = _isDark
        ? Colors.white.withValues(alpha: 0.18)
        : AppColors.primarySurface;
    final borderColor = _isDark
        ? Colors.white.withValues(alpha: 0.40)
        : AppColors.primary.withValues(alpha: 0.20);
    final url = logoUrl?.trim() ?? '';

    if (url.isEmpty) {
      return _fallback(context, bgColor, borderColor, radius);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: radius,
        border: Border.all(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        // Si l'image est en cours / impossible à charger, on retombe sur le
        // repli. Le placeholder pendant le 1er fetch l'affiche aussi pour
        // éviter un flash vide.
        placeholder: (_, __) => Center(child: _inner(context)),
        errorWidget: (_, __, ___) => Center(child: _inner(context)),
      ),
    );
  }

  Widget _fallback(
          BuildContext context, Color bg, Color border, BorderRadius radius) =>
      Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: radius,
          border: Border.all(color: border),
        ),
        alignment: Alignment.center,
        child: _inner(context),
      );

  /// Le contenu du repli : monogramme si le nom en donne un, bouclier sinon.
  Widget _inner(BuildContext context) {
    final mono = shopMonogram(shopName);
    if (mono != null) return _monogram(context, mono);
    return _logo();
  }

  /// Monogramme sur la pastille teintée — même idiome que les avatars clients
  /// de l'app : une lettre colorée sur `primarySurface`.
  ///
  /// La taille suit celle du conteneur plutôt qu'un échelon de la grille typo,
  /// et c'est assumé : l'avatar est appelé à 34, 36, 40 et 52 dp, et un pas
  /// fixe déborderait au plus petit ou flotterait au plus grand. C'est la même
  /// raison qui fait dimensionner le bouclier à 60 % juste en dessous.
  ///
  /// Deux lettres tiennent dans moins de place qu'une : le facteur baisse,
  /// sans quoi « CA » déborderait là où « C » respire.
  Widget _monogram(BuildContext context, String mono) => Text(
        mono,
        maxLines: 1,
        style: AppTextStyles.bodyBold.copyWith(
          fontSize: size * (mono.length > 1 ? 0.34 : 0.44),
          height: 1,
          color: _isDark ? Colors.white : AppColors.primary,
        ),
      );

  /// Logo Fortress dimensionné pour rester à ~60 % du conteneur.
  Widget _logo() {
    final inner = size * 0.60;
    return _isDark ? FortressLogo.dark(size: inner) : FortressLogo(size: inner);
  }
}

enum ShopLogoAvatarVariant { light, dark }
