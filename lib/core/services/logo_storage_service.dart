import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage/hive_boxes.dart';

/// Upload / fetch / cache du logo d'une boutique.
///
/// Bucket : `shop_logos` (public — cf. `supabase/hotfix_087_shop_logos_bucket.sql`).
/// Convention de chemin : `{shopId}/logo.png` (overwrite à chaque upload).
///
/// Cache local : `settingsBox['logo_bytes_$shopId']` (Uint8List) +
/// `settingsBox['logo_url_$shopId']` (String). Le cache survit aux
/// reloads navigateur et alimente le PDF facture instantanément sans
/// re-fetch réseau.
class LogoStorageService {
  static final _storage = Supabase.instance.client.storage;
  static const _bucket  = 'shop_logos';

  /// Cible de compression — 200 KB max à l'upload pour rester sous la
  /// limite du bucket et éviter d'alourdir le PDF facture (le logo est
  /// embarqué en base64 dans le doc).
  static const int _maxBytes = 200 * 1024;
  /// Plus grande dimension après resize. 512px = lisible jusqu'à 4× le
  /// rendu papier d'une facture A4 — suffisant pour de l'impression
  /// haute qualité sans bouffer la file.
  static const int _maxDimension = 512;

  // ── API publique ────────────────────────────────────────────────

  /// Compresse [rawBytes], upload vers Supabase et persiste cache + URL.
  ///
  /// Retourne `null` UNIQUEMENT quand la compression échoue (image
  /// indécodable ou trop lourde même en JPEG 70 après resize 512 px).
  /// Toute autre erreur (bucket manquant, policy RLS, CORS, réseau) est
  /// **propagée** au caller : sans ça, le snack UI affichait toujours
  /// « Logo trop volumineux ou format non supporté », même quand la
  /// vraie cause était côté infra Supabase — diagnostic impossible.
  static Future<String?> uploadLogo({
    required String shopId,
    required Uint8List rawBytes,
  }) async {
    final compressed = _compress(rawBytes);
    if (compressed == null) {
      debugPrint('[LogoStorage] compression échouée '
          '(image indécodable ou > 200 KB en JPEG 70)');
      return null;
    }
    final path = '$shopId/logo.png';
    try {
      await _storage.from(_bucket).uploadBinary(
        path,
        compressed.bytes,
        fileOptions: FileOptions(
          contentType: compressed.mimeType,
          upsert: true,
        ),
      );
    } catch (e) {
      debugPrint('[LogoStorage] uploadBinary échoué : $e');
      rethrow;
    }
    // Cache-buster : sans `?v=<ts>` le navigateur (et `Image.network`
    // côté Flutter web) sert l'ancien logo depuis son cache HTTP, et
    // l'utilisateur a l'impression que le changement n'a pas été pris
    // en compte. La timestamp invalide aussi le cache CDN Supabase.
    final base = _storage.from(_bucket).getPublicUrl(path);
    final v    = DateTime.now().millisecondsSinceEpoch;
    final url  = '$base?v=$v';
    // Persiste bytes + URL côté local pour usage immédiat (PDF facture,
    // preview paramètres) sans re-fetch.
    await _cacheBytes(shopId, compressed.bytes);
    await _cacheUrl(shopId, url);
    return url;
  }

  /// Supprime le logo côté Storage + nettoie le cache local. Retourne
  /// true si le remove serveur a réussi (le cache local est toujours
  /// purgé même si l'opération réseau échoue — permet de retomber sur
  /// l'apparence « pas de logo » en attendant le rejet sync).
  static Future<bool> deleteLogo(String shopId) async {
    await _evictCache(shopId);
    try {
      await _storage.from(_bucket).remove(['$shopId/logo.png']);
      return true;
    } catch (e) {
      debugPrint('[LogoStorage] suppression échouée : $e');
      return false;
    }
  }

  /// Renvoie les bytes du logo si dispo : cache local d'abord, sinon
  /// fetch HTTP depuis [url] (puis cache). Renvoie `null` si tout
  /// échoue (offline + pas de cache). Aucune exception ne sort de
  /// cette méthode — toute erreur est journalisée.
  static Future<Uint8List?> fetchBytes({
    required String shopId,
    String? url,
  }) async {
    // 1. Cache local d'abord — synchronous, gratuit, marche offline.
    final cached = cachedBytes(shopId);
    if (cached != null) return cached;
    // 2. Fetch réseau si URL fournie.
    if (url == null || url.isEmpty) return null;
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) {
        debugPrint('[LogoStorage] fetch HTTP ${res.statusCode} : $url');
        return null;
      }
      final bytes = res.bodyBytes;
      await _cacheBytes(shopId, bytes);
      return bytes;
    } catch (e) {
      debugPrint('[LogoStorage] fetch échoué : $e');
      return null;
    }
  }

  /// Accès synchrone au cache — utilisé par les widgets preview et le
  /// pipeline PDF pour ne pas await quand le cache est déjà chaud.
  static Uint8List? cachedBytes(String shopId) {
    try {
      final raw = HiveBoxes.settingsBox.get('logo_bytes_$shopId');
      if (raw is Uint8List) return raw;
      if (raw is List<int>) return Uint8List.fromList(raw);
      if (raw is List) return Uint8List.fromList(raw.cast<int>());
      return null;
    } catch (_) {
      return null;
    }
  }

  /// URL publique cachée localement (avec cache-buster).
  /// Utilisée par `Image.network` quand on veut afficher en preview
  /// sans bytes en mémoire.
  static String? cachedUrl(String shopId) {
    try {
      return HiveBoxes.settingsBox.get('logo_url_$shopId') as String?;
    } catch (_) {
      return null;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────

  static Future<void> _cacheBytes(String shopId, Uint8List bytes) async {
    try {
      await HiveBoxes.settingsBox.put('logo_bytes_$shopId', bytes);
    } catch (e) {
      debugPrint('[LogoStorage] cacheBytes : $e');
    }
  }

  static Future<void> _cacheUrl(String shopId, String url) async {
    try {
      await HiveBoxes.settingsBox.put('logo_url_$shopId', url);
    } catch (e) {
      debugPrint('[LogoStorage] cacheUrl : $e');
    }
  }

  static Future<void> _evictCache(String shopId) async {
    try {
      await HiveBoxes.settingsBox.delete('logo_bytes_$shopId');
      await HiveBoxes.settingsBox.delete('logo_url_$shopId');
      // On purge aussi les couleurs dominantes — elles seront ré-extraites
      // au prochain upload.
      await HiveBoxes.settingsBox.delete('logo_color_primary_$shopId');
      await HiveBoxes.settingsBox.delete('logo_color_secondary_$shopId');
    } catch (e) {
      debugPrint('[LogoStorage] evictCache : $e');
    }
  }

  /// Décode, resize au plus grand côté <= [_maxDimension], puis encode
  /// en visant <= [_maxBytes]. PNG d'abord (préserve la transparence
  /// pour les logos sur fond clair) ; si trop volumineux, dégrade vers
  /// JPEG quality 85 puis 70.
  static _Compressed? _compress(Uint8List input) {
    final decoded = img.decodeImage(input);
    if (decoded == null) return null;
    final largest = decoded.width > decoded.height
        ? decoded.width
        : decoded.height;
    final resized = largest > _maxDimension
        ? img.copyResize(
            decoded,
            width:  decoded.width  >= decoded.height ? _maxDimension : null,
            height: decoded.height >  decoded.width  ? _maxDimension : null,
            interpolation: img.Interpolation.linear,
          )
        : decoded;
    // 1er essai : PNG (lossless, transparence).
    final png = Uint8List.fromList(img.encodePng(resized));
    if (png.length <= _maxBytes) {
      return _Compressed(bytes: png, mimeType: 'image/png');
    }
    // 2e essai : JPEG 85 (perd la transparence mais accepte les photos).
    final jpg85 = Uint8List.fromList(img.encodeJpg(resized, quality: 85));
    if (jpg85.length <= _maxBytes) {
      return _Compressed(bytes: jpg85, mimeType: 'image/jpeg');
    }
    // 3e essai : JPEG 70 (dernier recours avant abandon).
    final jpg70 = Uint8List.fromList(img.encodeJpg(resized, quality: 70));
    if (jpg70.length <= _maxBytes) {
      return _Compressed(bytes: jpg70, mimeType: 'image/jpeg');
    }
    // Image vraiment trop lourde même en JPEG 70 → on refuse. Le caller
    // affiche un snack invitant à utiliser un logo plus simple.
    return null;
  }
}

class _Compressed {
  final Uint8List bytes;
  final String    mimeType;
  const _Compressed({required this.bytes, required this.mimeType});
}
