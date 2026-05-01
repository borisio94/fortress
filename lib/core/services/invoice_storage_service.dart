import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ═════════════════════════════════════════════════════════════════════════════
// InvoiceStorageService — upload des PDF de factures vers Supabase Storage.
//
// Bucket : "factures" (privé — créé via supabase/hotfix_031_factures_bucket.sql)
//
// Convention de chemin : {shop_id}/{order_id}.pdf
// → cloisonne par boutique : les RLS storage policies n'autorisent l'accès
//   qu'aux membres de la boutique correspondant au préfixe du chemin.
//
// Diffusion : on retourne une `signed URL` à durée limitée (30 jours par
// défaut) — le destinataire WhatsApp ouvre le lien sans authentification,
// et le lien expire automatiquement passé ce délai.
// ═════════════════════════════════════════════════════════════════════════════

class InvoiceStorageService {
  static final _storage = Supabase.instance.client.storage;
  static const _bucket  = 'factures';

  /// Durée de validité d'une signed URL — 30 jours.
  static const Duration _signedUrlTtl = Duration(days: 30);

  /// Upload [bytes] (PDF) à `{shopId}/{orderId}.pdf` et retourne une
  /// signed URL valide [_signedUrlTtl]. `upsert: true` → si la facture est
  /// régénérée, le fichier précédent est remplacé sans erreur.
  ///
  /// Retourne `null` si l'upload OU la génération de l'URL échoue
  /// (par exemple offline) — le caller doit gérer le fallback.
  static Future<String?> uploadInvoice({
    required String shopId,
    required String orderId,
    required Uint8List bytes,
  }) async {
    final path = '$shopId/$orderId.pdf';
    try {
      await _storage.from(_bucket).uploadBinary(
        path,
        bytes,
        fileOptions: const FileOptions(
          contentType: 'application/pdf',
          upsert: true,
        ),
      );
      final url = await _storage.from(_bucket).createSignedUrl(
        path, _signedUrlTtl.inSeconds);
      debugPrint('[InvoiceStorage] Facture uploadée : $path → $url');
      return url;
    } catch (e) {
      debugPrint('[InvoiceStorage] Upload/signed URL échoué : $e');
      return null;
    }
  }

  /// Re-génère une signed URL pour une facture déjà uploadée.
  /// Utile si le lien partagé a expiré et que l'opérateur veut renvoyer
  /// la même facture au client sans re-uploader.
  static Future<String?> refreshSignedUrl({
    required String shopId,
    required String orderId,
  }) async {
    try {
      return await _storage.from(_bucket).createSignedUrl(
        '$shopId/$orderId.pdf', _signedUrlTtl.inSeconds);
    } catch (e) {
      debugPrint('[InvoiceStorage] refreshSignedUrl échoué : $e');
      return null;
    }
  }

  /// Supprime la facture (cleanup manuel ou suppression de commande).
  static Future<bool> deleteInvoice({
    required String shopId,
    required String orderId,
  }) async {
    try {
      await _storage.from(_bucket).remove(['$shopId/$orderId.pdf']);
      return true;
    } catch (e) {
      debugPrint('[InvoiceStorage] Suppression échouée : $e');
      return false;
    }
  }
}
