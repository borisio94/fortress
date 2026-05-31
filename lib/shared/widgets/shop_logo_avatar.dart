import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/fortress_logo.dart';

/// Avatar de boutique : affiche `logoUrl` si présent, sinon fallback sur
/// le logo Fortress. Utilisé dans le drawer header et le profile header
/// de la page Paramètres pour identifier visuellement la boutique active.
///
/// Trois variantes via [variant] :
///   * `light` — fond clair (drawer en mode clair) → fallback `FortressLogo`.
///   * `dark`  — fond foncé (drawer mode sombre, header gradient violet de
///               Paramètres) → fallback `FortressLogo.dark`.
class ShopLogoAvatar extends StatelessWidget {
  final String? logoUrl;
  final double size;
  final ShopLogoAvatarVariant variant;

  const ShopLogoAvatar({
    super.key,
    this.logoUrl,
    this.size = 40,
    this.variant = ShopLogoAvatarVariant.light,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size / 4);
    final bgColor = variant == ShopLogoAvatarVariant.dark
        ? Colors.white.withValues(alpha: 0.18)
        : AppColors.primarySurface;
    final borderColor = variant == ShopLogoAvatarVariant.dark
        ? Colors.white.withValues(alpha: 0.40)
        : AppColors.primary.withValues(alpha: 0.20);
    final url = logoUrl?.trim() ?? '';

    if (url.isEmpty) {
      return _fallback(bgColor, borderColor, radius);
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
        // Si l'image est en cours / impossible à charger, on retombe sur
        // le logo Fortress par défaut. Le placeholder pendant le 1er fetch
        // affiche aussi le fallback pour éviter un flash vide.
        placeholder: (_, __) => Center(child: _innerLogo()),
        errorWidget: (_, __, ___) => Center(child: _innerLogo()),
      ),
    );
  }

  Widget _fallback(Color bg, Color border, BorderRadius radius) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: radius,
          border: Border.all(color: border),
        ),
        alignment: Alignment.center,
        child: _innerLogo(),
      );

  /// Logo Fortress (white-on-dark ou colored-on-light) dimensionné pour
  /// rester à ~60% de la taille du conteneur, lisible sans déborder.
  Widget _innerLogo() {
    final inner = size * 0.60;
    return variant == ShopLogoAvatarVariant.dark
        ? FortressLogo.dark(size: inner)
        : FortressLogo(size: inner);
  }
}

enum ShopLogoAvatarVariant { light, dark }
