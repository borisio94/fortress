import 'dart:io' show File;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Image produit unifiée — `BoxFit.cover` + ratio fixe (1:1 par défaut),
/// placeholder neutre, skeleton de chargement.
///
/// À utiliser PARTOUT où une image produit est rendue (caisse, inventaire,
/// panier, transferts, locations). Centralise le rendu pour que toutes les
/// surfaces aient la même apparence quel que soit le format source uploadé.
///
/// Trois modes de dimensionnement :
///   * `width` ET `height` fournis → SizedBox de cette taille (thumbnails).
///   * Sinon → AspectRatio de [aspectRatio] (cards de grille).
///
/// Comportement d'affichage :
///   * URL HTTPS → CachedNetworkImage (cache disque persistant, dispo offline).
///   * Chemin local non-web → Image.file (image fraîchement picked).
///   * Web + chemin local OU url null/vide → placeholder.
///   * Chargement → skeleton (CircularProgressIndicator sur fond neutre).
///   * Erreur → placeholder.
///
/// Le placeholder est volontairement uniforme (icône + fond `trackMuted`),
/// pas d'initiales/dégradés — la cohérence visuelle prime.
class ProductImageCard extends StatelessWidget {
  final String? imageUrl;
  /// Largeur explicite. Si `null`, le widget prend la largeur du parent et
  /// utilise [aspectRatio] pour calculer la hauteur.
  final double? width;
  /// Hauteur explicite (idem).
  final double? height;
  /// Ratio appliqué quand width/height ne sont pas tous deux fournis.
  /// Défaut 1:1 (carré) — convention photo produit e-commerce.
  final double aspectRatio;
  /// Coins arrondis appliqués via ClipRRect. Si `null`, pas de clip
  /// (BoxFit.cover ne déborde pas du SizedBox/AspectRatio parent).
  final BorderRadius? borderRadius;
  /// Mode "remplit le parent" : retourne `SizedBox.expand(child: content)`
  /// au lieu d'`AspectRatio`. Indispensable quand l'image doit occuper
  /// tout un `Stack`/`Positioned.fill` parent dont l'`AspectRatio` est
  /// imposé à l'extérieur (ex: ProductGridCard refonte overlay 3:4 — si
  /// on garde l'AspectRatio interne 1:1, l'image se centre et laisse des
  /// bandes vides en haut/bas du 3:4).
  final bool fillParent;

  const ProductImageCard({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.aspectRatio = 1.0,
    this.borderRadius,
    this.fillParent = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dpr   = MediaQuery.of(context).devicePixelRatio;

    // LayoutBuilder pour récupérer la taille logique réelle de l'image
    // (les cards de grille via AspectRatio n'ont pas de width/height
    // explicite). Sans ça, on ne sait pas dimensionner le décodage et
    // l'image est décodée à sa taille intrinsèque source — sur-pixelisée
    // si l'upload était trop petit, ou gaspillage mémoire si trop grand.
    Widget content = LayoutBuilder(builder: (_, c) {
      final logical = c.maxWidth.isFinite && c.maxWidth > 0
          ? c.maxWidth
          : (width ?? height ?? 200.0);
      // Décodage cible : taille logique × DPR, borné [400, 1600].
      // < 400 : pixelisation visible sur les cards de catalogue rétina.
      // > 1600 : la source PNG produit fait 1600 px max (cf.
      //   image_validation.dart maxOutputSize), inutile d'allouer
      //   un buffer plus grand que la source réelle.
      final cachePx = (logical * dpr).clamp(400.0, 1600.0).toInt();
      return _content(theme, cachePx);
    });

    // ClipRRect uniquement si coins arrondis demandés. BoxFit.cover de
    // l'image ne déborde pas du SizedBox/AspectRatio parent — pas besoin
    // d'un ClipRect inconditionnel comme avant (qui existait pour contenir
    // le Transform.scale(1.2) desktop désormais supprimé).
    if (borderRadius != null) {
      content = ClipRRect(borderRadius: borderRadius!, child: content);
    }

    if (fillParent) {
      return SizedBox.expand(child: content);
    }
    if (width != null && height != null) {
      return SizedBox(width: width, height: height, child: content);
    }
    return AspectRatio(aspectRatio: aspectRatio, child: content);
  }

  // ── Sélection de la source (réseau / fichier / placeholder) ─────────────
  Widget _content(ThemeData theme, int cachePx) {
    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return _placeholder(theme);
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return _network(theme, url, cachePx);
    }
    if (kIsWeb) {
      // Pas d'accès aux fichiers locaux du device sur web ; les images
      // tout juste picked transitent en Uint8List et sont uploadées avant
      // affichage (cf. HANDOFF compat web).
      return _placeholder(theme);
    }
    return _file(theme, url, cachePx);
  }

  // ── Image distante ──────────────────────────────────────────────────────
  // Mobile : `CachedNetworkImage` pour le cache disque persistant (offline).
  // Web    : `Image.network` direct — `CachedNetworkImage` a des soucis
  //          connus sur Flutter web (CORS, décodage memCacheWidth) qui
  //          masquent silencieusement l'image. Le navigateur a son propre
  //          cache HTTP, donc on perd peu.
  Widget _network(ThemeData theme, String url, int cachePx) {
    if (kIsWeb) {
      return Image.network(
        url,
        fit:           BoxFit.cover,
        width:         double.infinity,
        height:        double.infinity,
        cacheWidth:    cachePx,
        cacheHeight:   cachePx,
        filterQuality: FilterQuality.high,
        loadingBuilder: (_, child, p) =>
            p == null ? child : _skeleton(theme),
        errorBuilder:  (_, __, ___) => _placeholder(theme),
      );
    }
    return CachedNetworkImage(
      imageUrl:       url,
      cacheKey:       url,
      memCacheWidth:  cachePx,
      memCacheHeight: cachePx,
      fit:            BoxFit.cover,
      width:          double.infinity,
      height:         double.infinity,
      filterQuality:  FilterQuality.high,
      fadeInDuration: const Duration(milliseconds: 200),
      placeholder:    (_, __) => _skeleton(theme),
      errorWidget:    (_, __, ___) => _placeholder(theme),
    );
  }

  // ── Image fichier local (mobile uniquement, jamais web) ─────────────────
  Widget _file(ThemeData theme, String path, int cachePx) {
    return Image.file(
      File(path),
      fit:           BoxFit.cover,
      width:         double.infinity,
      height:        double.infinity,
      cacheWidth:    cachePx,
      cacheHeight:   cachePx,
      filterQuality: FilterQuality.high,
      errorBuilder:  (_, __, ___) => _placeholder(theme),
    );
  }

  // ── Placeholder uniforme : icône produit centrée sur fond neutre ────────
  Widget _placeholder(ThemeData theme) {
    final sem = theme.semantic;
    return LayoutBuilder(builder: (_, c) {
      final base = c.maxWidth.isFinite && c.maxWidth > 0
          ? c.maxWidth
          : (c.maxHeight.isFinite ? c.maxHeight : 40);
      final iconSize = (base * 0.4).clamp(14.0, 64.0);
      return Container(
        color:     sem.trackMuted,
        alignment: Alignment.center,
        child: Icon(
          Icons.inventory_2_rounded,
          size:  iconSize,
          color: sem.borderSubtle,
        ),
      );
    });
  }

  // ── Skeleton de chargement : spinner discret sur fond neutre ────────────
  Widget _skeleton(ThemeData theme) {
    final sem = theme.semantic;
    return Container(
      color:     sem.trackMuted,
      alignment: Alignment.center,
      child: SizedBox(
        width:  18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color:       sem.borderSubtle,
        ),
      ),
    );
  }
}
