import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';

// ═════════════════════════════════════════════════════════════════════════════
// ShareLinkService — crée un lien de partage WhatsApp avec preview
// personnalisée (titre, description, image).
//
// Flow :
//   1. `create(...)` insère une ligne dans `share_links` (token random 8 chars).
//   2. Retourne l'URL Edge Function `share-preview/<token>` qui :
//        • renvoie HTML avec og:tags pour les crawlers WhatsApp/FB/etc.
//        • redirige 302 vers `targetUrl` pour les vrais navigateurs.
//
// Le résultat est une URL qui, dans WhatsApp, génère une carte de prévisualisation
// avec le `label` comme titre — le client n'a plus à voir l'URL longue dans le
// texte du message.
// ═════════════════════════════════════════════════════════════════════════════

class ShareLinkService {
  // Alphabet sans caractères ambigus (pas de 0/O/l/1) pour éviter les
  // confusions à l'oeil si quelqu'un voit le token quelque part.
  static const _alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

  static String _randomToken({int length = 8}) {
    final rng = Random.secure();
    final chars = List.generate(length,
        (_) => _alphabet[rng.nextInt(_alphabet.length)]);
    return chars.join();
  }

  /// Crée une ligne `share_links` + retourne l'URL share-preview à envoyer
  /// via WhatsApp.
  ///
  /// - [kind] : `invoice` / `order_reminder` / `catalogue` / `news` / `promo`.
  /// - [targetUrl] : URL finale (PDF Storage signé, page catalogue, ...).
  /// - [label] : libellé custom qui apparaîtra en titre du preview WhatsApp.
  /// - [description] : sous-titre du preview (optionnel).
  /// - [imageUrl] : image du preview (optionnel, ex: logo boutique).
  /// - [validity] : durée de vie du lien.
  ///
  /// Retourne `null` en cas d'erreur réseau / DB.
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
    // Quelques tentatives en cas de collision improbable.
    for (var attempt = 0; attempt < 3; attempt++) {
      final token = _randomToken();
      try {
        await db.from('share_links').insert({
          'token':        token,
          'kind':         kind,
          'shop_id':      shopId,
          'resource_id':  resourceId,
          'target_url':   targetUrl,
          'label':        label,
          'description':  description,
          'image_url':    imageUrl,
          'expires_at':   DateTime.now().toUtc()
              .add(validity).toIso8601String(),
        });
        return _previewUrl(token);
      } catch (e) {
        // Collision PK : retry. Autre erreur : abandonner.
        final msg = e.toString().toLowerCase();
        if (!msg.contains('duplicate') && !msg.contains('unique')) {
          debugPrint('[ShareLink] échec création ($kind): $e');
          return null;
        }
      }
    }
    debugPrint('[ShareLink] 3 collisions consécutives — abandon');
    return null;
  }

  static String _previewUrl(String token) =>
      '${SupabaseConfig.url}/functions/v1/share-preview/$token';
}
