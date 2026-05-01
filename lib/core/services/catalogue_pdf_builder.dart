import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../features/inventaire/domain/entities/product.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';
import 'catalogue_html_builder.dart' show CataloguePromo;

// ═════════════════════════════════════════════════════════════════════════════
// CataloguePdfBuilder — génère un PDF présentant une sélection de produits
// sous forme de catalogue partageable.
//
// Format A4, identité visuelle Fortress (violet) :
//   • Header     : logo boutique + nom + date
//   • Bandeau    : promo (optionnel) avec titre + remise + date limite
//   • Grille     : cartes produit (image + nom + prix + stock + variantes)
//   • Footer     : "Pour commander, contactez-nous sur WhatsApp" + numéro
//
// Les images des produits sont téléchargées en parallèle (bucket Supabase
// public `product-images`) puis embarquées dans le PDF. Échec image →
// placeholder avec initiales (jamais d'erreur fatale).
// ═════════════════════════════════════════════════════════════════════════════

class CataloguePdfBuilder {
  // Palette Fortress (alignée sur OrderReceiptUseCase pour cohérence).
  static final _violet      = PdfColor.fromHex('#6C3FC7');
  static final _violetDark  = PdfColor.fromHex('#4E2A9A');
  static final _violetLight = PdfColor.fromHex('#F0EBFF');
  static final _grayBorder  = PdfColor.fromHex('#E5E7EB');
  static final _grayText    = PdfColor.fromHex('#6B7280');
  static final _grayMuted   = PdfColor.fromHex('#9CA3AF');
  static final _greenStock  = PdfColor.fromHex('#065F46');
  static final _greenBg     = PdfColor.fromHex('#ECFDF5');
  static final _redStock    = PdfColor.fromHex('#991B1B');
  static final _redBg       = PdfColor.fromHex('#FEF2F2');
  static final _promoRed    = PdfColor.fromHex('#DC2626');
  static final _promoBg     = PdfColor.fromHex('#FEF3C7');
  static final _white       = PdfColor.fromHex('#FFFFFF');
  static final _textPrimary = PdfColor.fromHex('#0F172A');

  /// Génère un PDF (`Uint8List`) à partir d'une sélection de produits.
  /// Chaque variante d'un produit devient une **carte distincte** dans le
  /// catalogue (image variante si dispo, sinon image produit). Un produit
  /// sans variante donne 1 seule carte.
  static Future<Uint8List> build({
    required ShopSummary shop,
    required List<Product> products,
    CataloguePromo? promo,
    String? whatsappContact,
    String currency = 'XAF',
    DateTime? generatedAt,
  }) async {
    final fmt = NumberFormat('#,###', 'fr_FR');
    final at  = generatedAt ?? DateTime.now();
    final dateStr = '${at.day.toString().padLeft(2, '0')}/'
        '${at.month.toString().padLeft(2, '0')}/${at.year}';

    // Aplatir : chaque produit → 1 entrée par variante (ou 1 entrée tout
    // court si pas de variante).
    final entries = <_Entry>[];
    for (final p in products) {
      if (p.variants.isEmpty) {
        entries.add(_Entry(product: p));
      } else {
        for (final v in p.variants) {
          entries.add(_Entry(product: p, variant: v));
        }
      }
    }

    // Précharge les images en parallèle : logo + 1 image par entrée.
    final logoFuture = _fetchImage(shop.logoUrl);
    final entryImageFutures = entries
        .map((e) => _fetchImage(e.imageUrl))
        .toList();
    final logo = await logoFuture;
    final entryImages = await Future.wait(entryImageFutures);

    final pdf = pw.Document(
      title: '${shop.name} - Catalogue',
      author: shop.name,
      subject: 'Catalogue produits',
    );

    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(24, 24, 24, 24),
      header: (ctx) => ctx.pageNumber == 1
          ? _header(shop: shop, dateStr: dateStr, logoBytes: logo)
          : pw.SizedBox.shrink(),
      footer: (ctx) => _footer(
          ctx: ctx, contact: whatsappContact),
      build: (ctx) => [
        if (promo != null) ...[
          pw.SizedBox(height: 8),
          _promoBanner(promo),
        ],
        pw.SizedBox(height: 16),
        _grid(
          entries: entries,
          images: entryImages,
          fmt: fmt,
          currency: currency,
          promo: promo,
        ),
      ],
    ));

    return pdf.save();
  }

  // ─── Header ─────────────────────────────────────────────────────────────

  static pw.Widget _header({
    required ShopSummary shop,
    required String dateStr,
    required Uint8List? logoBytes,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 14),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: _grayBorder, width: 0.6),
        ),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          // Logo carré (image ou fallback initiales)
          pw.Container(
            width: 48, height: 48,
            decoration: pw.BoxDecoration(
              color: _violetLight,
              borderRadius: pw.BorderRadius.circular(10),
            ),
            child: logoBytes != null
                ? pw.ClipRRect(
                    horizontalRadius: 10,
                    verticalRadius: 10,
                    child: pw.Image(pw.MemoryImage(logoBytes),
                        fit: pw.BoxFit.cover),
                  )
                : pw.Center(
                    child: pw.Text(_initials(shop.name),
                        style: pw.TextStyle(
                            fontWeight: pw.FontWeight.bold,
                            fontSize: 16, color: _violet)),
                  ),
          ),
          pw.SizedBox(width: 12),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(shop.name,
                    style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                        color: _textPrimary)),
                pw.SizedBox(height: 2),
                pw.Text('Catalogue · $dateStr',
                    style: pw.TextStyle(fontSize: 10, color: _grayText)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Bandeau promo ──────────────────────────────────────────────────────

  static pw.Widget _promoBanner(CataloguePromo promo) {
    final until = promo.validUntil == null
        ? null
        : 'jusqu\'au ${promo.validUntil!.day.toString().padLeft(2, '0')}/'
            '${promo.validUntil!.month.toString().padLeft(2, '0')}/'
            '${promo.validUntil!.year}';
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: _promoBg,
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Row(children: [
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: pw.BoxDecoration(
            color: _promoRed,
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Text('PROMO',
              style: pw.TextStyle(fontSize: 10,
                  fontWeight: pw.FontWeight.bold, color: _white)),
        ),
        pw.SizedBox(width: 10),
        pw.Expanded(
          child: pw.Text(promo.title,
              style: pw.TextStyle(fontSize: 13,
                  fontWeight: pw.FontWeight.bold)),
        ),
        pw.Text('-${promo.discountPercent}%',
            style: pw.TextStyle(fontSize: 16,
                fontWeight: pw.FontWeight.bold, color: _promoRed)),
        if (until != null) ...[
          pw.SizedBox(width: 8),
          pw.Text(until,
              style: pw.TextStyle(fontSize: 9, color: _grayText)),
        ],
      ]),
    );
  }

  // ─── Grille (3 colonnes) ────────────────────────────────────────────────

  static pw.Widget _grid({
    required List<_Entry> entries,
    required List<Uint8List?> images,
    required NumberFormat fmt,
    required String currency,
    CataloguePromo? promo,
  }) {
    if (entries.isEmpty) {
      return pw.Center(
        child: pw.Text('Aucun produit dans ce catalogue.',
            style: pw.TextStyle(fontSize: 11, color: _grayMuted)),
      );
    }
    const cols = 3;
    final rows = <pw.Widget>[];
    for (var i = 0; i < entries.length; i += cols) {
      final children = <pw.Widget>[];
      for (var j = 0; j < cols; j++) {
        final idx = i + j;
        if (idx < entries.length) {
          children.add(pw.Expanded(
            child: _entryCard(
              entry: entries[idx],
              imageBytes: images[idx],
              fmt: fmt,
              currency: currency,
              isPromo: _isHighlighted(entries[idx], promo),
            ),
          ));
        } else {
          children.add(pw.Expanded(child: pw.SizedBox.shrink()));
        }
        if (j < cols - 1) {
          children.add(pw.SizedBox(width: 8));
        }
      }
      rows.add(pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: children),
      ));
    }
    return pw.Column(children: rows);
  }

  static bool _isHighlighted(_Entry e, CataloguePromo? promo) {
    if (promo == null) return false;
    if (promo.highlightProductIds.isEmpty) return true;
    if (e.variant?.id != null
        && promo.highlightProductIds.contains(e.variant!.id)) return true;
    if (e.product.id != null
        && promo.highlightProductIds.contains(e.product.id)) return true;
    return false;
  }

  // ─── Carte produit ──────────────────────────────────────────────────────

  /// Carte d'une entrée du catalogue (1 produit ou 1 variante précise).
  /// Affichage : image (variante en priorité, sinon produit), titre
  /// "Produit — Variante" si variante, prix de la variante, stock.
  static pw.Widget _entryCard({
    required _Entry entry,
    required Uint8List? imageBytes,
    required NumberFormat fmt,
    required String currency,
    bool isPromo = false,
  }) {
    final stock = entry.stock;
    final price = entry.price;
    return pw.Container(
      decoration: pw.BoxDecoration(
        color: _white,
        border: pw.Border.all(color: _grayBorder, width: 0.6),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Stack(children: [
            pw.AspectRatio(
              aspectRatio: 1,
              child: pw.Container(
                decoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('#F9FAFB'),
                  borderRadius: const pw.BorderRadius.only(
                    topLeft:  pw.Radius.circular(8),
                    topRight: pw.Radius.circular(8),
                  ),
                ),
                child: imageBytes != null
                    ? pw.ClipRRect(
                        horizontalRadius: 8,
                        verticalRadius: 8,
                        child: pw.Image(pw.MemoryImage(imageBytes),
                            fit: pw.BoxFit.cover),
                      )
                    : pw.Center(
                        child: pw.Text(_initials(entry.product.name),
                            style: pw.TextStyle(
                                fontSize: 24,
                                fontWeight: pw.FontWeight.bold,
                                color: _grayMuted)),
                      ),
              ),
            ),
            if (isPromo)
              pw.Positioned(
                top: 6, left: 6,
                child: pw.Container(
                  padding: const pw.EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: pw.BoxDecoration(
                    color: _promoRed,
                    borderRadius: pw.BorderRadius.circular(3),
                  ),
                  child: pw.Text('PROMO',
                      style: pw.TextStyle(fontSize: 8,
                          fontWeight: pw.FontWeight.bold, color: _white)),
                ),
              ),
          ]),
          pw.Padding(
            padding: const pw.EdgeInsets.all(8),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(entry.displayName,
                    maxLines: 2,
                    overflow: pw.TextOverflow.clip,
                    style: pw.TextStyle(fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: _textPrimary)),
                pw.SizedBox(height: 4),
                pw.Text('${fmt.format(price)} $currency',
                    style: pw.TextStyle(fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                        color: _violetDark)),
                pw.SizedBox(height: 6),
                _smallBadge(
                  text: 'Stock: $stock',
                  color: stock <= 0 ? _redStock : _greenStock,
                  bg:    stock <= 0 ? _redBg    : _greenBg,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _smallBadge({
    required String text,
    required PdfColor color,
    required PdfColor bg,
  }) =>
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: pw.BoxDecoration(
          color: bg,
          borderRadius: pw.BorderRadius.circular(3),
        ),
        child: pw.Text(text,
            style: pw.TextStyle(fontSize: 8,
                fontWeight: pw.FontWeight.bold, color: color)),
      );

  // ─── Footer ─────────────────────────────────────────────────────────────

  static pw.Widget _footer({
    required pw.Context ctx,
    required String? contact,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(color: _grayBorder, width: 0.6),
        ),
      ),
      child: pw.Row(children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Pour commander, contactez-nous sur WhatsApp.',
                  style: pw.TextStyle(fontSize: 9, color: _grayText)),
              if ((contact ?? '').isNotEmpty)
                pw.Text(contact!,
                    style: pw.TextStyle(fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: _textPrimary)),
            ],
          ),
        ),
        pw.Text('Page ${ctx.pageNumber}/${ctx.pagesCount}',
            style: pw.TextStyle(fontSize: 9, color: _grayMuted)),
      ]),
    );
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

  /// Télécharge une image et renvoie ses bytes. `null` si l'URL est nulle/
  /// vide ou si la requête échoue (offline, 404, format non supporté…).
  /// Timeout court pour ne pas bloquer la génération du PDF si une image
  /// ne répond pas.
  static Future<Uint8List?> _fetchImage(String? url) async {
    if (url == null || url.trim().isEmpty) return null;
    try {
      final resp = await http.get(Uri.parse(url))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) {
        debugPrint('[CataloguePdf] Image ${resp.statusCode} : $url');
        return null;
      }
      return resp.bodyBytes;
    } catch (e) {
      debugPrint('[CataloguePdf] Échec image $url : $e');
      return null;
    }
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    final first = parts.first[0].toUpperCase();
    final second = parts.length > 1 && parts[1].isNotEmpty
        ? parts[1][0].toUpperCase() : '';
    return '$first$second';
  }
}

// ─── Entrée du catalogue (1 produit, ou 1 variante d'un produit) ─────────
class _Entry {
  final Product product;
  final ProductVariant? variant;
  const _Entry({required this.product, this.variant});

  /// Titre affiché : "Produit — Variante" si variante, sinon "Produit".
  String get displayName => variant != null
      ? '${product.name} — ${variant!.name}'
      : product.name;

  /// Image : variante si elle a la sienne, sinon image principale du produit.
  String? get imageUrl =>
      (variant?.imageUrl != null && variant!.imageUrl!.isNotEmpty)
          ? variant!.imageUrl
          : product.mainImageUrl;

  /// Prix : variante si > 0, sinon variante principale, sinon prix produit.
  double get price {
    final v = variant?.priceSellPos;
    if (v != null && v > 0) return v;
    final main = product.variants.where((x) => x.isMain).firstOrNull
        ?? (product.variants.isNotEmpty ? product.variants.first : null);
    return main?.priceSellPos ?? product.priceSellPos;
  }

  /// Stock : variante si fournie, sinon stock total agrégé.
  int get stock => variant?.stockAvailable ?? product.totalStock;
}
