import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:path/path.dart' as p;

// ─────────────────────────────────────────────────────────────────────────────
// StorageService — Upload d'images vers Supabase Storage
//
// Bucket : "product-images" (public)
// URL publique : https://<project>.supabase.co/storage/v1/object/public/product-images/<path>
//
// Si l'upload échoue (offline) → retourne le chemin local en fallback
// ─────────────────────────────────────────────────────────────────────────────

class StorageService {
  static final _storage = Supabase.instance.client.storage;
  static const _bucket  = 'product-images';

  /// Upload une image vers Supabase Storage
  /// Retourne l'URL publique si succès, ou le chemin local en fallback
  static Future<String> uploadImage(File file, {required String name}) async {
    try {
      final ext      = p.extension(file.path).toLowerCase().replaceAll('.', '');
      final mimeType = ext == 'png' ? 'image/png' : 'image/jpeg';
      final path     = '$name.${ext.isEmpty ? 'jpg' : ext}';

      await _storage.from(_bucket).upload(
        path,
        file,
        fileOptions: FileOptions(contentType: mimeType, upsert: true),
      );

      final url = _storage.from(_bucket).getPublicUrl(path);
      debugPrint('[Storage] Image uploadée: $url');
      return url;

    } catch (e) {
      debugPrint('[Storage] Upload échoué: $e — fallback local');
      // Fallback : sauvegarder localement si Supabase Storage indisponible
      return await _saveLocally(file, name: name);
    }
  }

  /// Upload plusieurs images en parallèle
  static Future<List<String>> uploadImages(
      List<File> files, {required String prefix}) async {
    final futures = files.asMap().entries.map((e) =>
        uploadImage(e.value, name: '${prefix}_${e.key}'));
    return Future.wait(futures);
  }

  /// Supprimer une image de Supabase Storage
  static Future<void> deleteImage(String url) async {
    try {
      if (!url.contains(_bucket)) return;
      // Extraire le path depuis l'URL publique
      final uri    = Uri.parse(url);
      final parts  = uri.pathSegments;
      final idx    = parts.indexOf(_bucket);
      if (idx == -1 || idx + 1 >= parts.length) return;
      final path = parts.sublist(idx + 1).join('/');
      await _storage.from(_bucket).remove([path]);
      debugPrint('[Storage] Image supprimée: $path');
    } catch (e) {
      debugPrint('[Storage] Suppression échouée: $e');
    }
  }

  /// Sauvegarder localement en fallback
  static Future<String> _saveLocally(File source, {required String name}) async {
    try {
      final dir = Directory.systemTemp;
      final dest = File('${dir.path}/$name.jpg');
      await source.copy(dest.path);
      return dest.path;
    } catch (_) {
      return source.path; // dernier recours : chemin original
    }
  }

  /// Vérifier si une URL est une URL Supabase Storage (publique)
  static bool isRemoteUrl(String? url) =>
      url != null && (url.startsWith('http://') || url.startsWith('https://'));

  /// Vérifier si une URL est un chemin local
  static bool isLocalPath(String? url) =>
      url != null && !isRemoteUrl(url) && url.isNotEmpty;
}