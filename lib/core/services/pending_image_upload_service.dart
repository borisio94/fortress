import 'package:flutter/foundation.dart';

import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import '../../features/inventaire/domain/entities/product.dart';
import 'storage_service.dart';

/// File d'attente persistante des uploads d'images produit (PNG).
///
/// Pourquoi ce service existe (bug "image disparaît après save sur 3G") :
///   * `_doSaveProduct` enregistre le `Product` en Hive immédiatement
///     avec `imageUrl = null`, puis lance l'upload Supabase en
///     `Future.microtask` avant la navigation. Sur 3G un upload PNG
///     1,5 Mo prend 20-30 s — si l'utilisateur ferme l'onglet ou
///     navigue ailleurs entre-temps, le microtask meurt et les bytes
///     en mémoire JS sont perdus. L'image disparaît silencieusement,
///     plus aucun retry possible.
///
/// Solution : persister les bytes + métadonnées dans `pendingImageUploadsBox`.
/// Un worker (`flush`) tente l'upload + l'update produit, retire l'entry
/// si OK, incrémente `attempts` sinon. Le worker est appelé :
///   * juste après `enqueue` (cas connexion rapide → presque
///     instantané, comme l'ancien microtask) ;
///   * au démarrage via `AppDatabase.init()` (si user a fermé pendant
///     upload, retry au boot suivant) ;
///   * à la reconnexion via `AppDatabase._onNetworkRestored()`.
///
/// Cap FIFO à `_maxEntries = 50` (drop oldest) : sur connexion vraiment
/// pourrie l'utilisateur peut accumuler en attente, mais 50 × 2 Mo =
/// 100 Mo max — limite acceptable IndexedDB sur web.
///
/// Abandon après `_maxAttempts = 10` tentatives : on supprime l'entry
/// pour ne pas garder une queue infinie sur des erreurs durables (RLS,
/// 23502, 42501…). Pas d'écriture dans `sync_errors` côté serveur — on
/// log juste en `debugPrint`, l'utilisateur verra que l'image n'apparait
/// pas et pourra ré-uploader manuellement via la fiche produit.
class PendingImageUploadService {
  static const int _maxEntries  = 50;
  static const int _maxAttempts = 10;

  static bool _busy = false;

  /// Ajoute une image à la file d'attente. Retourne immédiatement.
  /// Le worker `flush()` doit être appelé séparément (ou laissé tourner
  /// au prochain démarrage / reconnexion).
  ///
  /// `name` est le chemin complet de destination dans Supabase Storage
  /// (ex: `shops/<shopId>/products/<ts>_<variantIdx>`). Le caller le
  /// construit pour garantir l'unicité — ce service ne le réécrit pas.
  ///
  /// `isPrimary=true` (défaut) → l'URL retournée va remplir
  /// `variants[variantIdx].imageUrl`. `false` → l'URL est ajoutée à
  /// `variants[variantIdx].secondaryImageUrls`.
  static Future<void> enqueue({
    required String     shopId,
    required String     productId,
    required int        variantIdx,
    required Uint8List  bytes,
    required String     name,
    String              mimeType  = 'image/png',
    bool                isPrimary = true,
  }) async {
    final box = HiveBoxes.pendingImageUploadsBox;
    // Cap FIFO : drop l'oldest si dépassement. Les uploads les plus
    // anciens sont aussi les moins importants (l'utilisateur a déjà
    // bougé sur d'autres produits depuis).
    if (box.length >= _maxEntries) {
      final oldestKey = box.keys.first;
      await box.delete(oldestKey);
      debugPrint('[PendingImage] Cap $_maxEntries atteint → drop $oldestKey');
    }
    await box.add({
      'shop_id':     shopId,
      'product_id':  productId,
      'variant_idx': variantIdx,
      'bytes':       bytes,
      'name':        name,
      'mime_type':   mimeType,
      'is_primary':  isPrimary,
      'attempts':    0,
      'queued_at':   DateTime.now().toIso8601String(),
    });
    debugPrint('[PendingImage] +1 Enqueued: $name '
        '(${(bytes.length / 1024).toStringAsFixed(0)} Ko)');
  }

  /// Tente d'uploader toutes les entries en attente. Idempotent — un
  /// second appel concurrent return immédiatement via `_busy`. À appeler
  /// au démarrage (`AppDatabase.init`), à la reconnexion (`_onNetworkRestored`)
  /// et juste après chaque `enqueue` (pour le cas connexion rapide où
  /// l'upload est quasi-instantané).
  static Future<void> flush() async {
    if (_busy) return;
    _busy = true;
    int success = 0, failed = 0, abandoned = 0;
    try {
      final box = HiveBoxes.pendingImageUploadsBox;
      final keys = box.keys.toList();
      if (keys.isEmpty) return;
      debugPrint('[PendingImage] 🚀 Flush ${keys.length} entry(s)');

      for (final key in keys) {
        final raw = box.get(key);
        if (raw == null) { await box.delete(key); continue; }
        final entry = Map<String, dynamic>.from(raw);
        final attempts = (entry['attempts'] as int?) ?? 0;

        if (attempts >= _maxAttempts) {
          await box.delete(key);
          abandoned++;
          debugPrint('[PendingImage] ⛔ Abandon après $attempts tentatives: '
              '${entry['name']}');
          continue;
        }

        try {
          final ok = await _processEntry(entry);
          if (ok) {
            await box.delete(key);
            success++;
          } else {
            entry['attempts'] = attempts + 1;
            entry['last_retry'] = DateTime.now().toIso8601String();
            await box.put(key, entry);
            failed++;
          }
        } catch (e) {
          entry['attempts']   = attempts + 1;
          entry['last_retry'] = DateTime.now().toIso8601String();
          entry['last_error'] = e.toString();
          await box.put(key, entry);
          failed++;
          debugPrint('[PendingImage] ⚠️ Erreur key=$key '
              'tentative ${attempts + 1}/$_maxAttempts: $e');
        }
      }
      debugPrint('[PendingImage] ✅ Flush: '
          '$success OK · $failed retry · $abandoned abandons');
    } finally {
      _busy = false;
    }
  }

  /// Upload + met à jour le `Product` en Hive. Retourne `true` si l'entry
  /// peut être supprimée (succès OU orphan invalide), `false` pour retry.
  static Future<bool> _processEntry(Map<String, dynamic> entry) async {
    final shopId     = entry['shop_id']     as String? ?? '';
    final productId  = entry['product_id']  as String? ?? '';
    final variantIdx = (entry['variant_idx'] as int?) ?? 0;
    final isPrimary  = (entry['is_primary'] as bool?) ?? true;
    final name       = entry['name']        as String? ?? '';
    final mimeType   = (entry['mime_type']  as String?) ?? 'image/png';
    final bytes      = _readBytes(entry['bytes']);

    if (bytes == null || bytes.isEmpty || name.isEmpty
        || shopId.isEmpty || productId.isEmpty) {
      debugPrint('[PendingImage] Entry invalide (bytes/name/ids manquants) → drop');
      return true;
    }

    // 1. Upload Supabase Storage. Si throw → caller catch + incrémente attempts.
    final url = await StorageService.uploadImageBytes(
        bytes, name: name, mimeType: mimeType);

    // 2. Update Product en Hive (déclenche aussi un upsert Supabase via
    //    saveProduct, donc l'imageUrl propage à tous les devices via realtime).
    final products = AppDatabase.getProductsForShop(shopId);
    Product? product;
    for (final p in products) {
      if (p.id == productId) { product = p; break; }
    }
    if (product == null) {
      debugPrint('[PendingImage] ⚠️ Product $productId introuvable '
          '(supprimé ?) — orphan upload, entry retirée');
      return true;
    }
    if (variantIdx >= product.variants.length) {
      debugPrint('[PendingImage] ⚠️ variantIdx $variantIdx hors bornes '
          '(${product.variants.length} variantes) — entry retirée');
      return true;
    }

    final variants = List<ProductVariant>.from(product.variants);
    if (isPrimary) {
      // Si une ancienne image distante existait, on la supprime du
      // bucket pour ne pas accumuler des orphans (cohérent avec ce que
      // faisait l'ancien `_doSaveProduct` au moment du pick).
      final oldUrl = variants[variantIdx].imageUrl;
      if (StorageService.isRemoteUrl(oldUrl)) {
        StorageService.deleteImage(oldUrl!);
      }
      variants[variantIdx] = variants[variantIdx].copyWith(imageUrl: url);
    } else {
      final newSec = List<String>.from(
          variants[variantIdx].secondaryImageUrls);
      newSec.add(url);
      variants[variantIdx] =
          variants[variantIdx].copyWith(secondaryImageUrls: newSec);
    }

    ProductVariant? mainVariant;
    for (final v in variants) {
      if (v.isMain) { mainVariant = v; break; }
    }
    mainVariant ??= variants.isNotEmpty ? variants.first : null;

    final updated = product.copyWith(
      imageUrl: mainVariant?.imageUrl ?? product.imageUrl,
      variants: variants,
    );
    await AppDatabase.saveProduct(updated);
    return true;
  }

  /// Hive sérialise les `Uint8List` dans les `Map` values, et la lecture
  /// peut renvoyer un `List<int>` (côté web) ou un `Uint8List` (natif)
  /// selon la version du backend. On normalise.
  static Uint8List? _readBytes(dynamic raw) {
    if (raw is Uint8List) return raw;
    if (raw is List)      return Uint8List.fromList(List<int>.from(raw));
    return null;
  }

  /// Nombre d'entries en attente. Utile pour UI badge éventuel.
  static int get pendingCount {
    try { return HiveBoxes.pendingImageUploadsBox.length; }
    catch (_) { return 0; }
  }
}
