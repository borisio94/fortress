import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';

// ═════════════════════════════════════════════════════════════════════════════
// ShortLinkService — raccourcisseur d'URL maison.
//
// Pipeline :
//   1. `createShortLink(longUrl, linkType)` appelle le RPC `generate_short_slug`
//      qui renvoie un slug 6 chars unique.
//   2. INSERT dans la table `short_links` avec long_url + link_type + expires_at.
//   3. Retourne `https://<projet>.supabase.co/functions/v1/r/<slug>` — au clic
//      du client, la fonction `r` résout slug → 302 vers long_url et incrémente
//      le compteur de clics.
//
// linkType : `invoice` / `order_reminder` / `catalogue` / `news` / `promo`.
// ═════════════════════════════════════════════════════════════════════════════

class ShortLinkService {
  /// Base URL de la fonction `r` (raccourcisseur).
  static String get _baseUrl =>
      '${SupabaseConfig.url}/functions/v1/r';

  /// Crée un lien court. Retourne `null` en cas d'erreur réseau / DB.
  ///
  /// - [longUrl]   : URL longue cible (typiquement une URL signée Storage).
  /// - [linkType]  : étiquette pour les analytics (cf. enum dans la doc).
  /// - [expiresIn] : durée de vie. `null` = jamais.
  static Future<String?> createShortLink({
    required String longUrl,
    required String linkType,
    Duration? expiresIn,
  }) async {
    final db = Supabase.instance.client;
    try {
      final slug = await db.rpc('generate_short_slug') as String;
      final expiresAt = expiresIn != null
          ? DateTime.now().toUtc().add(expiresIn).toIso8601String()
          : null;
      await db.from('short_links').insert({
        'slug':       slug,
        'long_url':   longUrl,
        'link_type':  linkType,
        'expires_at': expiresAt,
      });
      return '$_baseUrl/$slug';
    } catch (e) {
      debugPrint('[ShortLink] échec création ($linkType): $e');
      return null;
    }
  }
}
