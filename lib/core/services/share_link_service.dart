import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ═════════════════════════════════════════════════════════════════════════════
// ShareLinkService — génère une URL WhatsApp avec preview personnalisée (og:tags)
// en uploadant un HTML statique dans Supabase Storage public.
//
// Pourquoi pas une Edge Function ?
//   Cloudflare devant Supabase bloque les IPs des crawlers Facebook/WhatsApp
//   sur `/functions/v1/` avec un 403. Le diagnostic via le Facebook Sharing
//   Debugger a confirmé ce blocage. En revanche, `/storage/v1/object/public/`
//   passe sans souci → on uploade un fichier HTML statique dans un bucket
//   public et on partage cette URL.
//
// Pipeline :
//   1. Génère un token random 8 chars.
//   2. Insère une ligne dans `share_links` pour traçabilité (label, kind,
//      target_url, etc.).
//   3. Génère un HTML avec og:title/description/image/url + meta refresh
//      vers `target_url`.
//   4. Upload ce HTML dans `share-previews/<token>.html` (bucket public).
//   5. Retourne l'URL publique du fichier.
//
// Le HTML contient à la fois :
//   • og:tags pour les crawlers (WhatsApp, Facebook, etc.)
//   • meta refresh + JS redirect pour les vrais utilisateurs qui cliquent
//     sur la carte preview dans WhatsApp.
// ═════════════════════════════════════════════════════════════════════════════

class ShareLinkService {
  // Alphabet sans caractères ambigus (pas de 0/O/l/1).
  static const _alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

  // Image fallback si la boutique n'a pas de logo. WhatsApp refuse souvent
  // d'afficher une carte preview riche sans og:image.
  static const _fallbackImage =
      'https://fortress-pos.web.app/icons/Icon-512.png';

  static String _randomToken({int length = 8}) {
    final rng = Random.secure();
    final chars = List.generate(
        length, (_) => _alphabet[rng.nextInt(_alphabet.length)]);
    return chars.join();
  }

  static String _escapeHtml(String? s) {
    if (s == null) return '';
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// Construit le HTML statique avec og:tags + redirect client-side.
  static String _renderHtml({
    required String label,
    required String description,
    required String imageUrl,
    required String targetUrl,
  }) {
    final t = _escapeHtml(label);
    final d = _escapeHtml(description);
    final i = _escapeHtml(imageUrl);
    final u = _escapeHtml(targetUrl);
    // targetUrl pour le script doit être sérialisé en JSON pour échapper
    // les guillemets et caractères spéciaux.
    final uJson = jsonEncode(targetUrl);
    return '''<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>$t</title>
  <meta property="og:title" content="$t">
  <meta property="og:description" content="$d">
  <meta property="og:image" content="$i">
  <meta property="og:image:width" content="512">
  <meta property="og:image:height" content="512">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="Fortress POS">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="$t">
  <meta name="twitter:description" content="$d">
  <meta name="twitter:image" content="$i">
  <meta http-equiv="refresh" content="0; url=$u">
</head>
<body>
  <p><a href="$u">Ouvrir le document</a></p>
  <script>window.location.replace($uJson);</script>
</body>
</html>''';
  }

  /// Crée un lien de partage WhatsApp avec preview personnalisée.
  ///
  /// - [kind] : `invoice` / `order_reminder` / `catalogue` / `news` / `promo`.
  /// - [targetUrl] : URL finale (PDF Storage signé, page catalogue, ...).
  /// - [label] : libellé custom — apparaît en og:title.
  /// - [description] : sous-titre du preview (ex: nom boutique).
  /// - [imageUrl] : image preview (ex: logo boutique). Fallback logo Fortress.
  ///
  /// Retourne l'URL publique du HTML preview à envoyer dans WhatsApp.
  /// Retourne `null` en cas d'erreur réseau / DB / Storage.
  static Future<String?> create({
    required String kind,
    required String shopId,
    String? resourceId,
    required String targetUrl,
    required String label,
    String? description,
    String? imageUrl,
    Duration validity = const Duration(days: 30),
  }) async {
    final db = Supabase.instance.client;
    final effectiveImage =
        (imageUrl != null && imageUrl.trim().isNotEmpty)
            ? imageUrl
            : _fallbackImage;
    final effectiveDescription = description ?? '';

    for (var attempt = 0; attempt < 3; attempt++) {
      final token = _randomToken();
      try {
        // 1. Traçabilité dans share_links (utile pour analytics + cleanup).
        await db.from('share_links').insert({
          'token':        token,
          'kind':         kind,
          'shop_id':      shopId,
          'resource_id':  resourceId,
          'target_url':   targetUrl,
          'label':        label,
          'description':  description,
          'image_url':    imageUrl,
          'expires_at':   DateTime.now()
              .toUtc().add(validity).toIso8601String(),
        });

        // 2. Génération du HTML statique avec og:tags.
        final html = _renderHtml(
          label:       label,
          description: effectiveDescription,
          imageUrl:    effectiveImage,
          targetUrl:   targetUrl,
        );
        final bytes = Uint8List.fromList(utf8.encode(html));

        // 3. Upload dans le bucket public `share-previews`.
        final filePath = '$token.html';
        await db.storage.from('share-previews').uploadBinary(
          filePath,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'text/html; charset=utf-8',
            upsert:      false,
          ),
        );

        // 4. URL publique servie par Supabase Storage (pas bloquée par
        //    Cloudflare anti-bot, contrairement à `/functions/v1/`).
        final publicUrl = db.storage
            .from('share-previews')
            .getPublicUrl(filePath);
        return publicUrl;
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (!msg.contains('duplicate') &&
            !msg.contains('unique') &&
            !msg.contains('already exists')) {
          debugPrint('[ShareLink] échec création ($kind): $e');
          return null;
        }
        // Collision token (extrêmement improbable) → retry.
      }
    }
    debugPrint('[ShareLink] 3 collisions consécutives — abandon');
    return null;
  }
}
