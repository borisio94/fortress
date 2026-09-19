import 'dart:io' show File;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/services/storage_service.dart';
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
      // Décodage cible sur la SEULE largeur : taille logique × DPR, borné
      // [400, 1600]. On ne contraint volontairement PAS la hauteur — fournir
      // width ET height à `ResizeImage` (politique `exact` par défaut)
      // décoderait le bitmap à un carré strict en ignorant le ratio source,
      // déformant les photos non carrées AVANT le BoxFit.cover. En ne
      // passant que la largeur, la hauteur est calculée proportionnellement
      // → ratio préservé, recadrage propre par cover.
      // Borné [160, 1600]. Plancher BAS (160) volontaire : les TRÈS petites
      // vignettes (liste produits ~48-64 px, swatches) doivent recevoir une
      // image proche de leur taille. Un plancher haut (ex. 400) sur-provisionne
      // la source → downscale à fort ratio → flou sur web/CanvasKit (pas de
      // mipmaps). La résolution rétina des GRANDES cards reste couverte par
      // `logical × dpr` (qui dépasse 400 dès qu'une card est grande × DPR>1).
      // > 1600 : la source produit fait ~1600 px max (image_validation), inutile
      //   d'allouer un buffer plus grand.
      final cachePx = (logical * dpr).clamp(160.0, 1600.0).toInt();
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
  // `CachedNetworkImage` partout (mobile + web) — cache persistant via
  // `flutter_cache_manager` (fichiers sur mobile, IndexedDB sur web). Sans
  // ce cache côté web, le simple `Image.network` n'a aucune persistance :
  // l'`ImageCache` Flutter est en mémoire et est vidé à chaque reload, et
  // le seul cache HTTP du navigateur ne suffit pas (hard refresh ou
  // Cache-Control faible → re-décodage des bytes → placeholder qui s'affiche
  // au démarrage tant que l'image n'est pas re-téléchargée).
  //
  // `memCacheWidth` est volontairement omis sur web : le décodage
  // canvas-based de Flutter web ne le respecte pas de manière fiable et
  // peut renvoyer une frame vide silencieusement. Sur mobile/desktop, on
  // le garde — économie mémoire ×4 typique (source 1600 px → cible 400 px).
  Widget _network(ThemeData theme, String url, int cachePx) {
    // On charge une image REDIMENSIONNÉE CÔTÉ SERVEUR (transform Supabase) à
    // une largeur PROCHE de l'affichage réel [cachePx], au lieu de l'image
    // brute ~1600 px réduite en une passe (flou web/CanvasKit à fort ratio).
    // « Bucketée » par pas de 160 px (plancher 160) pour limiter la
    // fragmentation cache/CDN tout en collant à la taille des petites vignettes.
    final renderW = ((cachePx / 160).ceil() * 160).clamp(160, 1600);
    final tUrl    = StorageService.thumbUrl(url, width: renderW);
    return CachedNetworkImage(
      imageUrl:       tUrl,
      cacheKey:       tUrl,
      memCacheWidth:  kIsWeb ? null : cachePx,
      fit:            BoxFit.cover,
      width:          double.infinity,
      height:         double.infinity,
      filterQuality:  FilterQuality.high,
      fadeInDuration: const Duration(milliseconds: 200),
      placeholder:    (_, __) => _skeleton(theme),
      // Repli sur l'image brute si le transform échoue (endpoint indispo). Si
      // l'URL n'est pas du stockage Supabase, `thumbUrl` la renvoie telle
      // quelle (tUrl == url) → repli direct sur le placeholder.
      errorWidget:    tUrl == url
          ? (_, __, ___) => _placeholder(theme)
          : (_, __, ___) => _networkRaw(theme, url, cachePx),
    );
  }

  /// Repli : image brute (sans transform serveur), même cache disque.
  Widget _networkRaw(ThemeData theme, String url, int cachePx) {
    return CachedNetworkImage(
      imageUrl:       url,
      cacheKey:       url,
      memCacheWidth:  kIsWeb ? null : cachePx,
      fit:            BoxFit.cover,
      width:          double.infinity,
      height:         double.infinity,
      filterQuality:  FilterQuality.high,
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
