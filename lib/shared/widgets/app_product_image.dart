import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Widget image produit avec cache offline automatique.
///
/// • URL https://... → CachedNetworkImage (cache disque, disponible offline)
/// • Chemin local    → Image.file
/// • null/vide       → placeholder icône
class AppProductImage extends StatelessWidget {
  final String? imageUrl;
  final double  width;
  final double  height;
  final BoxFit  fit;
  final Widget? placeholder;
  final BorderRadius? borderRadius;

  const AppProductImage({
    super.key,
    required this.imageUrl,
    this.width  = 44,
    this.height = 44,
    this.fit    = BoxFit.cover,
    this.placeholder,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    Widget child;

    if (url == null || url.isEmpty) {
      child = _placeholder();
    } else if (url.startsWith('http://') || url.startsWith('https://')) {
      // Image distante → cache automatique sur disque
      child = CachedNetworkImage(
        imageUrl: url,
        width:  width,
        height: height,
        fit:    fit,
        placeholder: (_, __) => _loading(),
        errorWidget: (_, __, ___) => _placeholder(),
        // Garder le cache 30 jours
        cacheKey: url,
      );
    } else {
      // Chemin local (création offline ou image temporaire)
      final file = File(url);
      child = Image.file(
        file,
        width:  width,
        height: height,
        fit:    fit,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: child);
    }
    return child;
  }

  Widget _placeholder() => SizedBox(
    width: width, height: height,
    child: placeholder ?? Container(
      color: const Color(0xFFF3F4F6),
      child: const Icon(Icons.image_outlined,
          color: Color(0xFFD1D5DB), size: 20),
    ),
  );

  Widget _loading() => SizedBox(
    width: width, height: height,
    child: Container(
      color: const Color(0xFFF9FAFB),
      child: const Center(
        child: SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: Color(0xFFD1D5DB)),
        ),
      ),
    ),
  );
}