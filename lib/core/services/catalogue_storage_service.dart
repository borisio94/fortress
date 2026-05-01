import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ═════════════════════════════════════════════════════════════════════════════
// CatalogueStorageService — upload des PDF de catalogue produit vers
// Supabase Storage (bucket public `catalogues`).
//
// Convention de chemin :
//   {shopId}/{timestamp}.pdf         (catalogue standard)
//   {shopId}/promo-{timestamp}.pdf   (catalogue promotion — étape 6)
//
// Format PDF (et non HTML) car Supabase Storage convertit volontairement
// `text/html` en `text/plain` quand servi depuis un bucket public (mesure
// anti-XSS), ce qui empêche le rendu côté navigateur. Les `application/pdf`
// ne souffrent pas de cette restriction → le destinataire WhatsApp ouvre
// directement le PDF avec aperçu inline natif.
//
// L'URL n'est pas devinable (UUID shopId + timestamp ms), mais elle ne
// contient pas de token cryptographique. Une expiration applicative
// (cleanup périodique des anciens fichiers) peut être ajoutée plus tard.
// ═════════════════════════════════════════════════════════════════════════════

class CatalogueStorageService {
  static final _storage = Supabase.instance.client.storage;
  static const _bucket  = 'catalogues';

  /// Upload [bytes] (PDF) dans `{shopId}/{filename}` et retourne l'URL
  /// publique. Retourne `null` si l'upload échoue (offline, RLS refusé…).
  ///
  /// [filename] doit se terminer par `.pdf`. Si null, on en génère un
  /// à partir d'un timestamp.
  static Future<String?> uploadCatalogue({
    required String shopId,
    required Uint8List bytes,
    String? filename,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final fname = filename ?? '$ts.pdf';
    return _upload(shopId: shopId, filename: fname,
        bytes: bytes, contentType: 'application/pdf');
  }

  /// Upload une image PNG d'aperçu (généralement la 1ʳᵉ page du PDF
  /// catalogue rasterisée). Sert à WhatsApp pour générer un preview de
  /// la conversation — sans cette image, WhatsApp ne montre pas d'aperçu
  /// pour un lien PDF.
  static Future<String?> uploadCover({
    required String shopId,
    required Uint8List pngBytes,
    String? filename,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final fname = filename ?? '$ts-cover.png';
    return _upload(shopId: shopId, filename: fname,
        bytes: pngBytes, contentType: 'image/png');
  }

  static Future<String?> _upload({
    required String shopId,
    required String filename,
    required Uint8List bytes,
    required String contentType,
  }) async {
    final path = '$shopId/$filename';
    try {
      await _storage.from(_bucket).uploadBinary(
        path,
        bytes,
        fileOptions: FileOptions(
          contentType: contentType,
          upsert: true,
        ),
      );
      final url = _storage.from(_bucket).getPublicUrl(path);
      debugPrint('[CatalogueStorage] $path → $url');
      return url;
    } catch (e) {
      debugPrint('[CatalogueStorage] Upload échoué ($filename) : $e');
      return null;
    }
  }
}
