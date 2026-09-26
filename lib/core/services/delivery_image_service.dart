import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../utils/currency_formatter.dart';
import '../../features/caisse/domain/entities/sale.dart';
import '../../features/caisse/domain/entities/sale_item.dart';
import '../../features/inventaire/domain/entities/product.dart';

/// Génère une **fiche de livraison VISUELLE** à partager dans un groupe
/// WhatsApp : une **grille de photos produits** (2 par ligne, quantité +
/// nom + prix) en haut, puis le **message texte du template** (toutes les
/// infos : client, lieu, date, total à percevoir…) en bas — le tout dans
/// une SEULE image.
///
/// Pourquoi une image (et pas un lien) : un groupe WhatsApp n'est pas
/// adressable par lien, et un lien oblige le livreur à booter toute l'app
/// web. Une image se colle directement dans la conversation, hors-ligne,
/// sur tous les téléphones.
///
/// Implémentation : on compose un PDF (le package `pdf` embarque les bytes
/// d'image directement → aucun problème de « canvas taint » CORS sur web,
/// contrairement à une capture RepaintBoundary), puis on rasterise la page
/// en PNG (`Printing.raster`). Si la rasterisation échoue (rare), on retombe
/// sur le partage du PDF.
class DeliveryImageService {
  const DeliveryImageService._();

  // Palette fiche (indépendante du thème runtime — valeurs PdfColor alignées
  // sur la marque violette de l'app).
  static const _ink     = PdfColor.fromInt(0xFF111827);
  static const _muted   = PdfColor.fromInt(0xFF6B7280);
  static const _brand   = PdfColor.fromInt(0xFF6C3FC7);
  static const _photoBg = PdfColor.fromInt(0xFFF3F4F6);
  static const _white   = PdfColors.white;

  /// Résultat : bytes + drapeau PNG (false = repli PDF).
  ///
  /// L'image ne contient QUE la partie visuelle produits (en-tête + cartes
  /// produits) — le texte WhatsApp est envoyé séparément (copié à part) pour
  /// rester du vrai texte sous l'image dans la conversation.
  static Future<({Uint8List bytes, bool isPng})?> generate({
    required Sale order,
    required String shopName,
    required List<Product> products,
  }) async {
    // 1. Pré-charge + compresse les photos de chaque article.
    final photos = await _loadPhotos(order.items, products);

    // 2. Résout le SKU à afficher pour chaque article (variante prioritaire,
    //    sinon SKU produit, sinon repli sur le nom).
    final skus = _resolveSkus(order.items, products);

    // 3. Compose le PDF (1 page, hauteur dynamique).
    final pdfBytes = await _composePdf(
      order: order,
      shopName: shopName,
      photos: photos,
      skus: skus,
    );
    if (pdfBytes.isEmpty) return null;

    // 4. Rasterise la page 1 en PNG (image inline WhatsApp). Repli PDF si KO.
    try {
      await for (final page in Printing.raster(pdfBytes, dpi: 160)) {
        final png = await page.toPng();
        return (bytes: png, isPng: true);
      }
    } catch (e) {
      debugPrint('[DeliveryImage] raster PNG échouée, repli PDF : $e');
    }
    return (bytes: pdfBytes, isPng: false);
  }

  // ── Chargement des photos ──────────────────────────────────────────────
  static Future<Map<int, Uint8List?>> _loadPhotos(
      List<SaleItem> items, List<Product> products) async {
    final byId = <String, Product>{};
    final variantParent = <String, String>{};
    for (final p in products) {
      final id = p.id;
      if (id != null && id.isNotEmpty) byId[id] = p;
      for (final v in p.variants) {
        final vid = v.id;
        if (vid != null && vid.isNotEmpty && id != null) {
          variantParent[vid] = id;
        }
      }
    }
    final out = <int, Uint8List?>{};
    for (var i = 0; i < items.length; i++) {
      final url = _resolveImageUrl(items[i], byId, variantParent);
      out[i] = (url == null || url.isEmpty) ? null : await _fetchThumb(url);
    }
    return out;
  }

  /// Photo de l'article : snapshot variante stocké sur le SaleItem d'abord
  /// (le plus fidèle à ce qui a été commandé), sinon image du produit résolu.
  static String? _resolveImageUrl(SaleItem it, Map<String, Product> byId,
      Map<String, String> variantParent) {
    final snap = (it.imageUrl ?? '').trim();
    if (snap.isNotEmpty) return snap;
    final prod = byId[it.productId] ?? byId[variantParent[it.productId] ?? ''];
    return prod?.mainImageUrl;
  }

  /// Télécharge la photo et la redimensionne (≤ 480 px, JPEG 80) pour ne pas
  /// alourdir le PDF/PNG. Ne lève jamais ; retourne null en cas d'échec.
  static Future<Uint8List?> _fetchThumb(String url) async {
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final decoded = img.decodeImage(res.bodyBytes);
      if (decoded == null) return null;
      final largest =
          decoded.width > decoded.height ? decoded.width : decoded.height;
      final resized = largest > 480
          ? img.copyResize(decoded,
              width:  decoded.width >= decoded.height ? 480 : null,
              height: decoded.height > decoded.width ? 480 : null,
              interpolation: img.Interpolation.linear)
          : decoded;
      return Uint8List.fromList(img.encodeJpg(resized, quality: 80));
    } catch (e) {
      debugPrint('[DeliveryImage] fetch photo échoué : $e');
      return null;
    }
  }

  // ── Composition PDF ─────────────────────────────────────────────────────
  static Future<Uint8List> _composePdf({
    required Sale order,
    required String shopName,
    required Map<int, Uint8List?> photos,
    required Map<int, String> skus,
  }) async {
    try {
      final items = order.items;
      const w = 600.0;
      // Hauteur dynamique : en-tête + lignes de grille (2 cards/ligne, grande
      // image partageant équitablement la largeur).
      final gridRows = (items.length / 2).ceil();
      final h = 92.0                 // en-tête
          + gridRows * 304.0         // cards produits
          + 24.0;                    // marge basse
      final doc = pw.Document();
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(w, h),
        margin: pw.EdgeInsets.zero,
        build: (ctx) => pw.Container(
          color: _white,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              _header(shopName, order),
              pw.SizedBox(height: 10),
              _productGrid(items, photos, skus),
            ],
          ),
        ),
      ));
      return await doc.save();
    } catch (e, st) {
      debugPrint('[DeliveryImage] compose PDF échouée : $e\n$st');
      return Uint8List(0);
    }
  }

  // En-tête : libellé « COMMANDE À LIVRER » + boutique + nb articles.
  // (Le titre dynamique NOUVELLE/RELANCÉE reste dans le texte du template,
  // via {{titre_livraison}}.)
  static pw.Widget _header(String shopName, Sale order) {
    const title = 'COMMANDE À LIVRER';
    return pw.Container(
      color: _brand,
      padding: const pw.EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(title,
                  style: pw.TextStyle(
                      color: _white,
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                      letterSpacing: 1.0)),
              pw.SizedBox(height: 2),
              pw.Text(shopName,
                  style: const pw.TextStyle(color: _white, fontSize: 12)),
            ],
          ),
          pw.Container(
            padding:
                const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: pw.BoxDecoration(
              color: _white,
              borderRadius: pw.BorderRadius.circular(20),
            ),
            child: pw.Text('${_totalQty(order)} article(s)',
                style: pw.TextStyle(
                    color: _brand,
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // Grille produits : 2 cards par ligne, largeur partagée équitablement.
  static pw.Widget _productGrid(List<SaleItem> items,
      Map<int, Uint8List?> photos, Map<int, String> skus) {
    final rows = <pw.Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      rows.add(pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(child: _productCell(items[i], photos[i], skus[i])),
            pw.SizedBox(width: 14),
            if (i + 1 < items.length)
              pw.Expanded(
                  child: _productCell(items[i + 1], photos[i + 1], skus[i + 1]))
            else
              pw.Expanded(child: pw.SizedBox()),
          ],
        ),
      ));
    }
    return pw.Column(children: rows);
  }

  // Card produit : grande image + badge quantité en haut à droite ; SKU +
  // prix à la base.
  static pw.Widget _productCell(SaleItem it, Uint8List? photo, String? sku) {
    final label = (sku ?? '').trim().isNotEmpty ? sku!.trim() : it.productName;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Stack(
          children: [
            pw.ClipRRect(
              horizontalRadius: 14,
              verticalRadius: 14,
              child: pw.Container(
                width: double.infinity,
                height: 230,
                color: _photoBg,
                child: photo != null
                    ? pw.Image(pw.MemoryImage(photo), fit: pw.BoxFit.cover)
                    : pw.Center(
                        child: pw.Text('photo',
                            style: const pw.TextStyle(
                                color: _muted, fontSize: 11))),
              ),
            ),
            // Badge quantité — en haut à droite, par-dessus l'image.
            pw.Positioned(
              top: 10,
              right: 10,
              child: pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                decoration: pw.BoxDecoration(
                  color: _brand,
                  borderRadius: pw.BorderRadius.circular(12),
                ),
                child: pw.Text('x${it.quantity}',
                    style: pw.TextStyle(
                        color: _white,
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold)),
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Text(label,
            maxLines: 2,
            style: pw.TextStyle(
                color: _ink, fontSize: 15, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text(_priceLine(it),
            style: pw.TextStyle(
                color: _brand,
                fontSize: 14,
                fontWeight: pw.FontWeight.bold)),
      ],
    );
  }

  // Résout le SKU à afficher par article : SKU de la variante commandée si
  // présent, sinon SKU du produit parent, sinon repli sur le nom du produit.
  static Map<int, String> _resolveSkus(
      List<SaleItem> items, List<Product> products) {
    final byId = <String, Product>{};
    final variantParent = <String, String>{};
    for (final p in products) {
      final id = p.id;
      if (id != null && id.isNotEmpty) byId[id] = p;
      for (final v in p.variants) {
        final vid = v.id;
        if (vid != null && vid.isNotEmpty && id != null) {
          variantParent[vid] = id;
        }
      }
    }
    final out = <int, String>{};
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      String sku = '';
      final parentId = variantParent[it.productId];
      if (parentId != null) {
        final parent = byId[parentId];
        if (parent != null) {
          for (final v in parent.variants) {
            if (v.id == it.productId) {
              sku = (v.sku ?? '').trim();
              break;
            }
          }
          if (sku.isEmpty) sku = (parent.sku ?? '').trim();
        }
      } else {
        sku = (byId[it.productId]?.sku ?? '').trim();
      }
      out[i] = sku.isNotEmpty ? sku : it.productName;
    }
    return out;
  }

  /// Ligne prix par produit : « PU » seul si qté 1, sinon « PU x N = total ».
  static String _priceLine(SaleItem it) {
    final unit = CurrencyFormatter.format(it.effectivePrice);
    if (it.quantity <= 1) return unit;
    return '$unit  x ${it.quantity}  =  ${CurrencyFormatter.format(it.subtotal)}';
  }

  // ── Helpers ──────────────────────────────────────────────────────────
  static int _totalQty(Sale order) =>
      order.items.fold(0, (s, it) => s + it.quantity);
}
