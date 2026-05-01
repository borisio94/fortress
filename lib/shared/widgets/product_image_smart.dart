import 'dart:io';

import 'package:flutter/material.dart';

/// Widget intelligent pour afficher une image de produit.
///
/// Gère trois cas selon le format de [url] :
///   - http:// ou https:// → [Image.network] avec spinner et fallback
///   - chemin local (file path) → [Image.file] (image fraîchement
///     sélectionnée via image_picker, pas encore uploadée sur Supabase)
///   - null ou vide → affiche directement [fallback]
///
/// À utiliser PARTOUT où l'on affiche une image de produit, pour que les
/// produits créés hors ligne (image non encore uploadée) restent visibles.
class ProductImageSmart extends StatelessWidget {
  final String? url;
  final Widget  fallback;
  final BoxFit  fit;
  final double? width;
  final double? height;
  final int?    cacheWidth;

  const ProductImageSmart({
    super.key,
    required this.url,
    required this.fallback,
    this.fit        = BoxFit.cover,
    this.width      = double.infinity,
    this.height     = double.infinity,
    this.cacheWidth = 400,
  });

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u == null || u.isEmpty) return fallback;

    if (u.startsWith('http://') || u.startsWith('https://')) {
      return Image.network(
        u,
        fit:        fit,
        width:      width,
        height:     height,
        cacheWidth: cacheWidth,
        loadingBuilder: (ctx, child, progress) {
          if (progress == null) return child;
          return Container(
            color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Theme.of(ctx).colorScheme.outlineVariant,
              ),
            ),
          );
        },
        errorBuilder: (_, __, ___) => fallback,
      );
    }

    return Image.file(
      File(u),
      fit:    fit,
      width:  width,
      height: height,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}
