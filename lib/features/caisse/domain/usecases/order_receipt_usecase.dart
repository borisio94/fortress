import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
export 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:open_filex/open_filex.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../entities/sale.dart';
import '../entities/sale_item.dart';
import '../../../../features/shop_selector/domain/entities/shop_summary.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../../../core/services/whatsapp_service.dart';
import '../../../../core/services/invoice_storage_service.dart';
import '../../../../core/services/url_shortener_service.dart';
import '../../../../core/utils/phone_formatter.dart';

class OrderReceiptUseCase {

  // ── Palette Fortress ────────────────────────────────────────────────────────
  static final _violet      = PdfColor.fromHex('#6C3FC7');
  static final _violetDark  = PdfColor.fromHex('#4E2A9A');
  static final _violetLight = PdfColor.fromHex('#F0EBFF');
  static final _violetMid   = PdfColor.fromHex('#EDE8FA');
  static final _white       = PdfColors.white;
  static final _grey100     = PdfColor.fromHex('#F9FAFB');
  static final _grey200     = PdfColor.fromHex('#E5E7EB');
  static final _grey500     = PdfColors.grey500;
  static final _grey700     = PdfColor.fromHex('#374151');
  static final _grey900     = PdfColor.fromHex('#111827');
  static final _green       = PdfColor.fromHex('#10B981');
  static final _orange      = PdfColor.fromHex('#F59E0B');

  // ── Générer le PDF ──────────────────────────────────────────────────────────
  static Future<Uint8List> generatePdf(Sale order, {
    ShopSummary? shop,
    String currency       = 'XAF',
    PdfPageFormat? pageFormat,
  }) async {
    // Récupérer la boutique depuis Hive si non fournie
    final s        = shop ?? LocalStorageService.getShop(order.shopId);
    final shopName = s?.name ?? 'Fortress';
    final shopPhone = s?.phone;
    final shopEmail = s?.email;
    final pdf      = pw.Document();
    final fmt      = NumberFormat('#,###', 'fr_FR');
    final pFormat  = pageFormat ?? PdfPageFormat.a4;
    final isTicket = (pFormat.availableWidth) < 200;

    pdf.addPage(pw.Page(
      pageFormat: pFormat,
      margin:     pw.EdgeInsets.zero,
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [

          // ════════════════════════════════════════════════════
          // BANDEAU EN-TÊTE VIOLET PLEIN
          // ════════════════════════════════════════════════════
          pw.Container(
            color: _violet,
            padding: pw.EdgeInsets.symmetric(
                horizontal: isTicket ? 12 : 32,
                vertical:   isTicket ? 14 : 28),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    // Nom boutique
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(shopName,
                            style: pw.TextStyle(
                                fontSize: isTicket ? 16 : 26,
                                fontWeight: pw.FontWeight.bold,
                                color: _white)),
                        if (shopPhone != null || shopEmail != null)
                          pw.SizedBox(height: 4),
                        if (shopPhone != null)
                          pw.Text(shopPhone,
                              style: pw.TextStyle(
                                  fontSize: 10,
                                  color: _white.shade(0.75))),
                        if (shopEmail != null)
                          pw.Text(shopEmail,
                              style: pw.TextStyle(
                                  fontSize: 10,
                                  color: _white.shade(0.75))),
                      ],
                    ),
                    // Badge FACTURE
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: pw.BoxDecoration(
                        color: _violetDark,
                        borderRadius: pw.BorderRadius.circular(6),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.end,
                        children: [
                          pw.Text('FACTURE',
                              style: pw.TextStyle(
                                  fontSize: isTicket ? 8 : 9,
                                  fontWeight: pw.FontWeight.bold,
                                  color: _white.shade(0.7),
                                  letterSpacing: 1.5)),
                          pw.SizedBox(height: 2),
                          pw.Text(
                              order.id?.replaceFirst('order_', '') ?? '—',
                              style: pw.TextStyle(
                                  fontSize: isTicket ? 10 : 12,
                                  fontWeight: pw.FontWeight.bold,
                                  color: _white)),
                        ],
                      ),
                    ),
                  ],
                ),
                if (!isTicket) ...[
                  pw.SizedBox(height: 20),
                  // Méta-infos dans le bandeau
                  pw.Row(children: [
                    _headerMeta('Date',
                        DateFormat('dd/MM/yyyy').format(order.createdAt)),
                    pw.SizedBox(width: 32),
                    _headerMeta('Heure',
                        DateFormat('HH:mm').format(order.createdAt)),
                    pw.SizedBox(width: 32),
                    _headerMeta('Statut', order.status.label),
                    if (order.clientName != null) ...[
                      pw.SizedBox(width: 32),
                      _headerMeta('Client', order.clientName!),
                    ],
                    if (order.clientPhone != null) ...[
                      pw.SizedBox(width: 32),
                      _headerMeta('Tél.', order.clientPhone!),
                    ],
                  ]),
                ],
              ],
            ),
          ),

          // ════════════════════════════════════════════════════
          // CORPS DU DOCUMENT
          // ════════════════════════════════════════════════════
          pw.Expanded(
            child: pw.Container(
              color: _white,
              padding: pw.EdgeInsets.fromLTRB(
                  isTicket ? 10 : 32,
                  isTicket ? 12 : 24,
                  isTicket ? 10 : 32,
                  isTicket ? 12 : 24),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [

                  // ── Méta-infos ticket ─────────────────────
                  if (isTicket) ...[
                    pw.Text(
                        DateFormat('dd/MM/yyyy HH:mm')
                            .format(order.createdAt),
                        style: pw.TextStyle(fontSize: 9, color: _grey500)),
                    if (order.clientName != null) ...[
                      pw.SizedBox(height: 3),
                      pw.Text('Client : ${order.clientName}',
                          style: pw.TextStyle(
                              fontSize: 9, fontWeight: pw.FontWeight.bold,
                              color: _grey700)),
                      if (order.clientPhone != null)
                        pw.Text('Tél : ${order.clientPhone}',
                            style: pw.TextStyle(
                                fontSize: 8, color: _grey500)),
                    ],
                    pw.SizedBox(height: 8),
                  ],

                  // ── Bloc Boutique + Client (A4/A5/A6) ─────
                  if (!isTicket && order.clientName != null) ...[
                    pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        // Infos boutique (émetteur)
                        pw.Expanded(child: pw.Container(
                          padding: const pw.EdgeInsets.all(10),
                          decoration: pw.BoxDecoration(
                            color: _grey100,
                            borderRadius: pw.BorderRadius.circular(6),
                            border: pw.Border.all(
                                color: _grey200, width: 0.5),
                          ),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text('DE',
                                  style: pw.TextStyle(
                                      fontSize: 7,
                                      color: _grey500,
                                      letterSpacing: 1.2,
                                      fontWeight: pw.FontWeight.bold)),
                              pw.SizedBox(height: 4),
                              pw.Text(shopName,
                                  style: pw.TextStyle(
                                      fontSize: 11,
                                      fontWeight: pw.FontWeight.bold,
                                      color: _grey900)),
                              if (shopPhone != null)
                                pw.Text(shopPhone!,
                                    style: pw.TextStyle(
                                        fontSize: 9, color: _grey700)),
                              if (shopEmail != null)
                                pw.Text(shopEmail!,
                                    style: pw.TextStyle(
                                        fontSize: 9, color: _grey700)),
                              if (s?.country != null)
                                pw.Text(s!.country,
                                    style: pw.TextStyle(
                                        fontSize: 9, color: _grey500)),
                            ],
                          ),
                        )),
                        pw.SizedBox(width: 12),
                        // Infos client (destinataire)
                        pw.Expanded(child: pw.Container(
                          padding: const pw.EdgeInsets.all(10),
                          decoration: pw.BoxDecoration(
                            color: _violetLight,
                            borderRadius: pw.BorderRadius.circular(6),
                            border: pw.Border.all(
                                color: _violet.shade(0.3), width: 0.5),
                          ),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text('À',
                                  style: pw.TextStyle(
                                      fontSize: 7,
                                      color: _violet,
                                      letterSpacing: 1.2,
                                      fontWeight: pw.FontWeight.bold)),
                              pw.SizedBox(height: 4),
                              pw.Text(order.clientName!,
                                  style: pw.TextStyle(
                                      fontSize: 11,
                                      fontWeight: pw.FontWeight.bold,
                                      color: _grey900)),
                              if (order.clientPhone != null)
                                pw.Text(order.clientPhone!,
                                    style: pw.TextStyle(
                                        fontSize: 9, color: _grey700)),
                              if (order.notes != null)
                                pw.Text(order.notes!,
                                    style: pw.TextStyle(
                                        fontSize: 8,
                                        color: _grey500,
                                        fontStyle: pw.FontStyle.italic)),
                            ],
                          ),
                        )),
                      ],
                    ),
                    pw.SizedBox(height: 16),
                  ],

                  // ── Titre section articles ────────────────
                  pw.Row(children: [
                    pw.Container(
                        width: 3, height: 14, color: _violet),
                    pw.SizedBox(width: 8),
                    pw.Text('Articles',
                        style: pw.TextStyle(
                            fontSize: isTicket ? 10 : 12,
                            fontWeight: pw.FontWeight.bold,
                            color: _grey900)),
                  ]),
                  pw.SizedBox(height: 8),

                  // ── En-tête tableau ────────────────────────
                  pw.Container(
                    color: _violet,
                    padding: pw.EdgeInsets.symmetric(
                        horizontal: isTicket ? 6 : 10,
                        vertical:   5),
                    child: isTicket
                        ? pw.Row(children: [
                      pw.Expanded(
                          child: pw.Text('Produit',
                              style: pw.TextStyle(
                                  color: _white,
                                  fontWeight: pw.FontWeight.bold,
                                  fontSize: 8))),
                      pw.SizedBox(width: 36,
                          child: pw.Text('Qté',
                              textAlign: pw.TextAlign.center,
                              style: pw.TextStyle(
                                  color: _white,
                                  fontWeight: pw.FontWeight.bold,
                                  fontSize: 8))),
                      pw.SizedBox(width: 52,
                          child: pw.Text('Total',
                              textAlign: pw.TextAlign.right,
                              style: pw.TextStyle(
                                  color: _white,
                                  fontWeight: pw.FontWeight.bold,
                                  fontSize: 8))),
                    ])
                        : pw.Row(children: [
                      pw.Expanded(flex: 4,
                          child: pw.Text('Produit',
                              style: pw.TextStyle(
                                  color: _white,
                                  fontWeight: pw.FontWeight.bold,
                                  fontSize: 10))),
                      pw.SizedBox(width: 50,
                          child: pw.Text('Qté',
                              textAlign: pw.TextAlign.center,
                              style: pw.TextStyle(
                                  color: _white,
                                  fontWeight: pw.FontWeight.bold,
                                  fontSize: 10))),
                      pw.SizedBox(width: 80,
                          child: pw.Text('Prix unit.',
                              textAlign: pw.TextAlign.right,
                              style: pw.TextStyle(
                                  color: _white,
                                  fontWeight: pw.FontWeight.bold,
                                  fontSize: 10))),
                      pw.SizedBox(width: 80,
                          child: pw.Text('Sous-total',
                              textAlign: pw.TextAlign.right,
                              style: pw.TextStyle(
                                  color: _white,
                                  fontWeight: pw.FontWeight.bold,
                                  fontSize: 10))),
                    ]),
                  ),

                  // ── Lignes articles ────────────────────────
                  ...order.items.asMap().entries.map((e) {
                    final i   = e.value;
                    final odd = e.key.isOdd;
                    return pw.Container(
                      color: odd ? _violetMid : _white,
                      padding: pw.EdgeInsets.symmetric(
                          horizontal: isTicket ? 6 : 10,
                          vertical:   isTicket ? 4 : 6),
                      child: isTicket
                          ? pw.Row(children: [
                        pw.Expanded(
                            child: pw.Text(i.productName,
                                style: const pw.TextStyle(
                                    fontSize: 9))),
                        pw.SizedBox(width: 36,
                            child: pw.Text('${i.quantity}',
                                textAlign: pw.TextAlign.center,
                                style: const pw.TextStyle(
                                    fontSize: 9))),
                        pw.SizedBox(width: 52,
                            child: pw.Text(
                                '${fmt.format(i.subtotal)}',
                                textAlign: pw.TextAlign.right,
                                style: pw.TextStyle(
                                    fontSize: 9,
                                    fontWeight:
                                    pw.FontWeight.bold))),
                      ])
                          : pw.Row(children: [
                        pw.Expanded(flex: 4,
                            child: pw.Column(
                              crossAxisAlignment:
                              pw.CrossAxisAlignment.start,
                              children: [
                                pw.Text(i.productName,
                                    style: pw.TextStyle(
                                        fontSize: 10,
                                        color: _grey900)),
                                if (i.variantName != null)
                                  pw.Text(i.variantName!,
                                      style: pw.TextStyle(
                                          fontSize: 9,
                                          color: _grey500)),
                              ],
                            )),
                        pw.SizedBox(width: 50,
                            child: pw.Text('${i.quantity}',
                                textAlign: pw.TextAlign.center,
                                style: pw.TextStyle(
                                    fontSize: 10,
                                    color: _grey700))),
                        pw.SizedBox(width: 80,
                            child: pw.Text(
                                '${fmt.format(i.effectivePrice)} $currency',
                                textAlign: pw.TextAlign.right,
                                style: pw.TextStyle(
                                    fontSize: 10,
                                    color: _grey700))),
                        pw.SizedBox(width: 80,
                            child: pw.Text(
                                '${fmt.format(i.subtotal)} $currency',
                                textAlign: pw.TextAlign.right,
                                style: pw.TextStyle(
                                    fontSize: 10,
                                    fontWeight: pw.FontWeight.bold,
                                    color: _grey900))),
                      ]),
                    );
                  }),

                  pw.SizedBox(height: 16),

                  // ── Récapitulatif ──────────────────────────
                  pw.Align(
                    alignment: pw.Alignment.centerRight,
                    child: pw.Container(
                      width: isTicket ? double.infinity : 240,
                      padding: const pw.EdgeInsets.all(12),
                      decoration: pw.BoxDecoration(
                        color: _violetLight,
                        borderRadius: pw.BorderRadius.circular(8),
                        border: pw.Border.all(
                            color: _violet.shade(0.3), width: 0.5),
                      ),
                      child: pw.Column(children: [
                        _recapRow('Sous-total',
                            '${fmt.format(order.subtotal)} $currency',
                            isTicket: isTicket),
                        if (order.discountAmount > 0)
                          _recapRow('Remise',
                              '- ${fmt.format(order.discountAmount)} $currency',
                              color: _orange, isTicket: isTicket),
                        if (order.taxRate > 0)
                          _recapRow(
                              'TVA (${order.taxRate.toStringAsFixed(0)}%)',
                              '${fmt.format(order.taxAmount)} $currency',
                              isTicket: isTicket),
                        pw.Container(
                            height: 0.5,
                            color: _violet,
                            margin: const pw.EdgeInsets.symmetric(
                                vertical: 6)),
                        _recapRow(
                          'TOTAL',
                          '${fmt.format(order.total)} $currency',
                          bold: true,
                          large: true,
                          color: _violet,
                          isTicket: isTicket,
                        ),
                      ]),
                    ),
                  ),

                  pw.Spacer(),

                  // ── Pied de page ───────────────────────────
                  pw.Container(
                    padding: pw.EdgeInsets.symmetric(
                        vertical: isTicket ? 8 : 14,
                        horizontal: 0),
                    decoration: pw.BoxDecoration(
                      border: pw.Border(
                          top: pw.BorderSide(
                              color: _grey200, width: 0.5)),
                    ),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.Text('Merci pour votre commande !',
                            style: pw.TextStyle(
                                fontSize: isTicket ? 9 : 11,
                                fontWeight: pw.FontWeight.bold,
                                color: _violet)),
                        pw.SizedBox(height: 3),
                        pw.Text(
                            'Fortress POS  •  ${DateFormat('dd/MM/yyyy').format(DateTime.now())}',
                            style: pw.TextStyle(
                                fontSize: 8,
                                color: _grey500)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ));

    return pdf.save();
  }

  // ── Relance WhatsApp à l'échéance ───────────────────────────────────────────
  /// Ouvre WhatsApp avec un message pré-rempli de rappel de livraison pour
  /// un client donné. L'utilisateur n'a qu'à tapper "Envoyer".
  ///
  /// Nécessite `order.clientPhone` renseigné. Retourne `false` s'il n'y a
  /// pas de téléphone client ou si WhatsApp ne peut pas être ouvert.
  ///
  /// [whatsapp] est injectable : le caller (typiquement une page Riverpod)
  /// passe `ref.read(whatsappServiceProvider)` pour profiter du provider
  /// actif (wa.me par défaut, Twilio/Meta plus tard). Si null, on tombe
  /// sur le default WameProvider — utile pour les services hors widget.
  static Future<bool> sendWhatsAppReminder(Sale order, {
    String currency = 'XAF',
    ShopSummary? shop,
    String? customMessage,
    WhatsappService? whatsapp,
  }) async {
    final phone = order.clientPhone ?? '';
    if (phone.trim().isEmpty) return false;

    final s        = shop ?? LocalStorageService.getShop(order.shopId);
    final shopName = s?.name ?? 'Fortress';
    final fmt      = NumberFormat('#,###', 'fr_FR');
    final clientName = order.clientName ?? 'Cher client';
    final total      = '${fmt.format(order.total)} $currency';

    final msg = customMessage ?? (
        'Bonjour $clientName,\n\n'
        'Nous vous rappelons votre commande chez $shopName pour un montant '
        'de $total, prévue aujourd\'hui.\n\n'
        'Êtes-vous disponible pour la livraison ?\n\n'
        'Merci et à bientôt 🙏');

    final svc = whatsapp
        ?? const WhatsappService(provider: WameProvider());
    return svc.sendMessage(phone, msg);
  }

  // ── Visualiser le PDF (aperçu natif) ─────────────────────────────────────────
  static Future<void> printOrShare(
      Sale order, BuildContext context, {
        String currency       = 'XAF',
        ShopSummary? shop,
        PdfPageFormat? pageFormat,
      }) async {
    final bytes = await generatePdf(order,
        shop: shop, currency: currency,
        pageFormat: pageFormat);
    // Sauvegarder dans un fichier temporaire
    final dir  = await getTemporaryDirectory();
    final file = File('${dir.path}/fortress_${order.id ?? 'recu'}.pdf');
    await file.writeAsBytes(bytes);
    // Ouvrir dans le visualiseur PDF natif (Windows, Android, iOS)
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done) {
      // Fallback : dialogue d'impression si pas de visualiseur PDF
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: 'fortress_${order.id ?? 'recu'}.pdf',
        format: pageFormat ?? PdfPageFormat.a4,
      );
    }
  }

  // ── Partager le PDF ─────────────────────────────────────────────────────────
  static Future<void> sharePdf(
      Sale order, {
        String currency       = 'XAF',
        ShopSummary? shop,
        PdfPageFormat? pageFormat,
      }) async {
    final s     = shop ?? LocalStorageService.getShop(order.shopId);
    final bytes = await generatePdf(order,
        shop: s, currency: currency,
        pageFormat: pageFormat);
    final dir  = await getTemporaryDirectory();
    final file = File('${dir.path}/fortress_${order.id ?? 'recu'}.pdf');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(file.path)],
        text: "Facture ${s?.name ?? 'Fortress'}");
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Ligne méta dans le bandeau violet (label + valeur en blanc)
  static pw.Widget _headerMeta(String label, String value) =>
      pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(label.toUpperCase(),
              style: pw.TextStyle(
                  fontSize: 7,
                  color: _white.shade(0.6),
                  letterSpacing: 0.8)),
          pw.SizedBox(height: 2),
          pw.Text(value,
              style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: _white)),
        ],
      );

  /// Ligne de récapitulatif (label + montant)
  static pw.Widget _recapRow(String label, String value, {
    bool bold       = false,
    bool large      = false,
    PdfColor? color,
    bool isTicket   = false,
  }) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(label,
                  style: pw.TextStyle(
                      fontSize: large ? (isTicket ? 10 : 12) : (isTicket ? 8 : 10),
                      fontWeight: bold
                          ? pw.FontWeight.bold : pw.FontWeight.normal,
                      color: color ?? _grey700)),
              pw.Text(value,
                  style: pw.TextStyle(
                      fontSize: large ? (isTicket ? 10 : 12) : (isTicket ? 8 : 10),
                      fontWeight: bold
                          ? pw.FontWeight.bold : pw.FontWeight.normal,
                      color: color ?? _grey900)),
            ]),
      );

  // ══ PDF de relance avec images ════════════════════════════════════════════

  /// Récupère l'URL de l'image d'un produit/variante DIRECTEMENT depuis
  /// Supabase. Utilisé en dernier recours quand le SaleItem ET le cache Hive
  /// local n'ont pas d'image — typiquement un employé sur un device frais
  /// qui relance une commande dont les images ont été ajoutées par l'admin
  /// ailleurs.
  ///
  /// Recherche en deux temps :
  ///   1. `products.id = id` (cas où SaleItem.productId est un product.id)
  ///   2. `products.variants @> [{"id": id}]` (cas où c'est un variant.id —
  ///      le pipeline d'ajout au panier passe le variant.id, pas le
  ///      product.id, cf. product_grid_widget.dart:150)
  ///
  /// Retourne `null` si pas trouvé ou erreur réseau (placeholder dessiné).
  static Future<String?> _fetchProductImageRemote(String id) async {
    final db = Supabase.instance.client;
    try {
      // 1. Match direct sur products.id.
      final r1 = await db
          .from('products')
          .select('image_url, variants')
          .eq('id', id)
          .maybeSingle()
          .timeout(const Duration(seconds: 6));
      if (r1 != null) {
        final url = _extractImageFromProductRow(r1, variantId: id);
        if (url != null) return url;
      }

      // 2. Match sur variants[].id via JSONB @> (le shape doit être un
      // tableau de maps, pas une map seule).
      final r2 = await db
          .from('products')
          .select('image_url, variants')
          .filter('variants', 'cs', '[{"id":"$id"}]')
          .limit(1)
          .timeout(const Duration(seconds: 6));
      if (r2 is List && r2.isNotEmpty) {
        final row = Map<String, dynamic>.from(r2.first as Map);
        final url = _extractImageFromProductRow(row, variantId: id);
        if (url != null) return url;
      }
      return null;
    } catch (e) {
      debugPrint('[ReminderImg] fetch produit Supabase échoué : $e');
      return null;
    }
  }

  /// Extrait l'image d'un row `products` : priorité à la variante matchée
  /// par [variantId], sinon première variante avec image, sinon image
  /// principale du produit.
  static String? _extractImageFromProductRow(
      Map<String, dynamic> row, {required String variantId}) {
    final raw = row['variants'];
    if (raw is List) {
      // Variante exacte
      for (final v in raw) {
        if (v is Map && v['id']?.toString() == variantId) {
          final u = v['image_url'] as String?;
          if (u != null && u.isNotEmpty) return u;
        }
      }
      // Première variante avec image
      for (final v in raw) {
        if (v is Map) {
          final u = v['image_url'] as String?;
          if (u != null && u.isNotEmpty) return u;
        }
      }
    }
    // Fallback image principale
    final main = row['image_url'] as String?;
    if (main != null && main.isNotEmpty) return main;
    return null;
  }

  /// Cherche dans tout le cache Hive `productsBox` un produit dont une
  /// variante porte l'ID [variantId]. Retourne `null` si rien.
  static Product? _findProductByVariantIdInHive(String variantId) {
    for (final raw in HiveBoxes.productsBox.values) {
      try {
        final m = Map<String, dynamic>.from(raw as Map);
        final variants = m['variants'] as List? ?? [];
        for (final v in variants) {
          if (v is Map && v['id']?.toString() == variantId) {
            return LocalStorageService.productFromMap(m);
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// À partir d'un produit et d'un variantId, retourne l'image de la
  /// variante matchée si présente, sinon mainImageUrl du produit.
  static String? _imageOfVariantOrFallback(Product p, String variantId) {
    final v = p.variants.where((x) => x.id == variantId).firstOrNull;
    if (v?.imageUrl != null && v!.imageUrl!.isNotEmpty) return v.imageUrl;
    return p.mainImageUrl;
  }

  /// Télécharge les bytes d'une image (URL http(s) ou chemin local).
  /// Retourne `null` en cas d'échec — le caller dessinera un placeholder.
  /// Timeout court (6 s) pour ne pas bloquer la génération du PDF.
  ///
  /// Logs verbeux : tag `[ReminderImg]` pour faciliter le debug.
  static Future<Uint8List?> _loadImageBytes(String? url) async {
    if (url == null || url.trim().isEmpty) {
      debugPrint('[ReminderImg] skip: url null/vide');
      return null;
    }
    final u = url.trim();
    try {
      if (u.startsWith('http://') || u.startsWith('https://')) {
        final r = await http
            .get(Uri.parse(u))
            .timeout(const Duration(seconds: 6));
        if (r.statusCode != 200) {
          debugPrint('[ReminderImg] HTTP ${r.statusCode} : $u');
          return null;
        }
        if (r.bodyBytes.isEmpty) {
          debugPrint('[ReminderImg] HTTP 200 mais 0 bytes : $u');
          return null;
        }
        debugPrint(
            '[ReminderImg] OK ${r.bodyBytes.length} bytes : $u');
        return r.bodyBytes;
      }
      final f = File(u);
      if (!f.existsSync()) {
        debugPrint('[ReminderImg] fichier local introuvable : $u');
        return null;
      }
      final bytes = await f.readAsBytes();
      debugPrint(
          '[ReminderImg] OK fichier local ${bytes.length} bytes : $u');
      return bytes;
    } catch (e) {
      debugPrint('[ReminderImg] échec ($u) : $e');
      return null;
    }
  }

  /// Génère un PDF A4 de RAPPEL de commande au **format catalogue** :
  /// header logo+nom boutique, grille 3 colonnes avec image carrée nette
  /// pour chaque produit commandé. Distinct de [generatePdf] (facture
  /// classique en colonne).
  ///
  /// Inspiré de `CataloguePdfBuilder` pour rester cohérent avec les
  /// catalogues partagés via WhatsApp.
  static Future<Uint8List> generateReminderPdf(Sale order, {
    ShopSummary? shop,
    String currency = 'XAF',
  }) async {
    final s         = shop ?? LocalStorageService.getShop(order.shopId);
    final shopName  = s?.name ?? 'Fortress';
    final shopPhone = s?.phone ?? '';
    final fmt       = NumberFormat('#,###', 'fr_FR');
    final pdf       = pw.Document(
      title:  '$shopName - Rappel de commande',
      author: shopName,
    );

    // Précharge logo + 1 image par item en parallèle.
    // Résolution d'URL en cascade pour chaque item (centralisation boutique
    // → un employé doit voir les images créées par l'admin/owner) :
    //   1. SaleItem.imageUrl (snapshot au moment de l'ajout)
    //   2. Cache Hive : Product.mainImageUrl
    //   3. Round-trip Supabase : SELECT image_url FROM products
    debugPrint('[ReminderPdf] Génération pour ${order.items.length} items');
    final resolvedUrls = await Future.wait(
      order.items.asMap().entries.map((e) async {
        final i  = e.key;
        final it = e.value;
        // 1. SaleItem
        if (it.imageUrl != null
            && it.imageUrl!.isNotEmpty
            && it.imageUrl != 'null') {
          debugPrint('[ReminderPdf]   item[$i] ${it.productName} '
              '→ imageUrl="${it.imageUrl}"');
          return it.imageUrl;
        }
        // ⚠️ SaleItem.productId est en pratique le variant.id (cf.
        // product_grid_widget.dart:150). Les fallbacks doivent chercher
        // par variant ID, pas par product ID.
        final id = it.productId;

        // 2a. Hive : produit dont l'ID match directement
        final pById = LocalStorageService.getProduct(id);
        if (pById != null) {
          final url = pById.mainImageUrl;
          if (url != null && url.isNotEmpty) {
            debugPrint('[ReminderPdf]   item[$i] ${it.productName} '
                '→ fallback Hive (par produit) "$url"');
            return url;
          }
        }
        // 2b. Hive : produit dont une variante porte cet ID
        final pByVariant = _findProductByVariantIdInHive(id);
        if (pByVariant != null) {
          final url = _imageOfVariantOrFallback(pByVariant, id);
          if (url != null && url.isNotEmpty) {
            debugPrint('[ReminderPdf]   item[$i] ${it.productName} '
                '→ fallback Hive (par variante) "$url"');
            return url;
          }
        }

        // 3. Round-trip Supabase
        final remoteUrl = await _fetchProductImageRemote(id);
        if (remoteUrl != null && remoteUrl.isNotEmpty) {
          debugPrint('[ReminderPdf]   item[$i] ${it.productName} '
              '→ fallback Supabase "$remoteUrl"');
          return remoteUrl;
        }
        debugPrint('[ReminderPdf]   item[$i] ${it.productName} '
            '→ aucune image trouvée nulle part');
        return null;
      }),
    );
    final logoFuture   = _loadImageBytes(s?.logoUrl);
    final itemImagesFuture = Future.wait(
      resolvedUrls.map(_loadImageBytes),
    );
    final logoBytes  = await logoFuture;
    final itemImages = await itemImagesFuture;
    final loaded = itemImages.where((b) => b != null).length;
    debugPrint(
        '[ReminderPdf] Images chargées : $loaded/${itemImages.length}'
        ' (logo: ${logoBytes != null ? "OK" : "absent"})');

    final now = DateTime.now();
    final dateStr = '${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')}/${now.year}';
    final dueStr = order.scheduledAt != null
        ? DateFormat('dd/MM à HH:mm', 'fr_FR')
            .format(order.scheduledAt!.toLocal())
        : '—';
    final ref = (order.id ?? '').length >= 6
        ? (order.id!).substring(order.id!.length - 6)
        : (order.id ?? '');

    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(24, 24, 24, 24),
      header: (ctx) => ctx.pageNumber == 1
          ? _reminderHeader(
              shopName: shopName,
              dateStr:  dateStr,
              logoBytes: logoBytes,
            )
          : pw.SizedBox.shrink(),
      footer: (ctx) => _reminderFooter(
        ctx:      ctx,
        contact:  shopPhone,
      ),
      build: (ctx) => [
        pw.SizedBox(height: 12),
        _reminderInfoBanner(
          clientName: order.clientName ?? 'cher client',
          ref:        ref,
          dueStr:     dueStr,
          totalStr:   '${fmt.format(order.total)} $currency',
        ),
        pw.SizedBox(height: 14),
        pw.Text('Détail de votre commande',
            style: pw.TextStyle(fontSize: 13,
                fontWeight: pw.FontWeight.bold,
                color: _grey900)),
        pw.SizedBox(height: 8),
        _reminderGrid(
          items:    order.items,
          images:   itemImages,
          fmt:      fmt,
          currency: currency,
        ),
        pw.SizedBox(height: 16),
        _reminderClosing(),
      ],
    ));
    return pdf.save();
  }

  // ─── Header (logo + nom + date) — calque catalogue ────────────────────────
  static pw.Widget _reminderHeader({
    required String     shopName,
    required String     dateStr,
    required Uint8List? logoBytes,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 14),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: _grey200, width: 0.6),
        ),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
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
                    child: pw.Text(_initialsOf(shopName),
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
                pw.Text(shopName,
                    style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                        color: _grey900)),
                pw.SizedBox(height: 2),
                pw.Text('Rappel de commande · $dateStr',
                    style: pw.TextStyle(fontSize: 10, color: _grey700)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Bandeau info client (réf, livraison prévue, total) ───────────────────
  static pw.Widget _reminderInfoBanner({
    required String clientName,
    required String ref,
    required String dueStr,
    required String totalStr,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: _violetLight,
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('Bonjour $clientName,',
              style: pw.TextStyle(fontSize: 12,
                  fontWeight: pw.FontWeight.bold, color: _grey900)),
          pw.SizedBox(height: 4),
          pw.Text(
              'Voici un récapitulatif des produits de votre commande.',
              style: pw.TextStyle(fontSize: 10, color: _grey700)),
          pw.SizedBox(height: 10),
          pw.Row(children: [
            _reminderInfoChip('Réf.',     ref.isEmpty ? '—' : ref),
            pw.SizedBox(width: 8),
            _reminderInfoChip('Livraison', dueStr),
            pw.SizedBox(width: 8),
            _reminderInfoChip('Total',    totalStr, highlight: true),
          ]),
        ],
      ),
    );
  }

  static pw.Widget _reminderInfoChip(String label, String value,
      {bool highlight = false}) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: pw.BoxDecoration(
        color: highlight ? _violet : _white,
        borderRadius: pw.BorderRadius.circular(6),
        border: pw.Border.all(color: _grey200, width: 0.6),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(label,
              style: pw.TextStyle(
                  fontSize: 8,
                  color: highlight
                      ? PdfColor.fromHex('#E0D6FF')
                      : _grey700)),
          pw.SizedBox(height: 1),
          pw.Text(value,
              style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: highlight ? _white : _grey900)),
        ],
      ),
    );
  }

  // ─── Grille 3 colonnes (style catalogue) ──────────────────────────────────
  static pw.Widget _reminderGrid({
    required List<SaleItem>      items,
    required List<Uint8List?>    images,
    required NumberFormat        fmt,
    required String              currency,
  }) {
    if (items.isEmpty) {
      return pw.Center(
        child: pw.Text('Aucun produit dans cette commande.',
            style: pw.TextStyle(fontSize: 11, color: _grey500)),
      );
    }
    const cols = 3;
    final rows = <pw.Widget>[];
    for (var i = 0; i < items.length; i += cols) {
      final children = <pw.Widget>[];
      for (var j = 0; j < cols; j++) {
        final idx = i + j;
        if (idx < items.length) {
          children.add(pw.Expanded(
            child: _reminderItemCard(
              item:       items[idx],
              imageBytes: images[idx],
              fmt:        fmt,
              currency:   currency,
            ),
          ));
        } else {
          children.add(pw.Expanded(child: pw.SizedBox.shrink()));
        }
        if (j < cols - 1) children.add(pw.SizedBox(width: 8));
      }
      rows.add(pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: children,
        ),
      ));
    }
    return pw.Column(children: rows);
  }

  /// Carte produit format catalogue — image carrée en grand, nom, qty, prix.
  static pw.Widget _reminderItemCard({
    required SaleItem    item,
    required Uint8List?  imageBytes,
    required NumberFormat fmt,
    required String      currency,
  }) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        color: _white,
        border: pw.Border.all(color: _grey200, width: 0.6),
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
                  color: _grey100,
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
                        child: pw.Text(_initialsOf(item.productName),
                            style: pw.TextStyle(
                                fontSize: 24,
                                fontWeight: pw.FontWeight.bold,
                                color: _grey500)),
                      ),
              ),
            ),
            pw.Positioned(
              top: 6, right: 6,
              child: pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                    horizontal: 7, vertical: 3),
                decoration: pw.BoxDecoration(
                  color: _violet,
                  borderRadius: pw.BorderRadius.circular(20),
                ),
                child: pw.Text('×${item.quantity}',
                    style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        color: _white)),
              ),
            ),
          ]),
          pw.Padding(
            padding: const pw.EdgeInsets.all(8),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(item.productName,
                    maxLines: 2,
                    overflow: pw.TextOverflow.clip,
                    style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: _grey900)),
                if ((item.variantName ?? '').isNotEmpty) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(item.variantName!,
                      maxLines: 1,
                      overflow: pw.TextOverflow.clip,
                      style: pw.TextStyle(
                          fontSize: 9,
                          fontWeight: pw.FontWeight.bold,
                          color: _violet)),
                ],
                pw.SizedBox(height: 4),
                pw.Text('${fmt.format(item.effectivePrice)} $currency',
                    style: pw.TextStyle(
                        fontSize: 11,
                        fontWeight: pw.FontWeight.bold,
                        color: _violetDark)),
                pw.SizedBox(height: 2),
                pw.Text(
                    'Sous-total ${fmt.format(item.subtotal)} $currency',
                    style: pw.TextStyle(
                        fontSize: 8, color: _grey700)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Encart de fin ───────────────────────────────────────────────────────
  static pw.Widget _reminderClosing() {
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: _grey100,
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('Etes-vous toujours disponible pour la livraison ?',
              style: pw.TextStyle(
                  fontSize: 11,
                  color: _grey900,
                  fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          pw.Text(
              'Repondez-nous via WhatsApp pour confirmer ou reprogrammer.',
              style: pw.TextStyle(fontSize: 10, color: _grey700)),
        ],
      ),
    );
  }

  static pw.Widget _reminderFooter({
    required pw.Context ctx,
    required String     contact,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(color: _grey200, width: 0.6),
        ),
      ),
      child: pw.Row(children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Pour toute question, contactez-nous sur WhatsApp.',
                  style: pw.TextStyle(fontSize: 9, color: _grey700)),
              if (contact.isNotEmpty)
                pw.Text(contact,
                    style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: _grey900)),
            ],
          ),
        ),
        pw.Text('Page ${ctx.pageNumber}/${ctx.pagesCount}',
            style: pw.TextStyle(fontSize: 9, color: _grey500)),
      ]),
    );
  }

  static String _initialsOf(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    final a = parts.first[0].toUpperCase();
    final b = parts.length > 1 && parts[1].isNotEmpty
        ? parts[1][0].toUpperCase()
        : '';
    return '$a$b';
  }

  /// Orchestre la relance complète : génère le PDF avec images, l'upload
  /// sur Supabase Storage, raccourcit l'URL et envoie un message WhatsApp
  /// avec le lien.
  ///
  /// Retourne `true` si le message WhatsApp a été ouvert avec succès.
  /// Retourne `false` si numéro client manquant, upload échoué, ou WhatsApp
  /// non disponible (le caller doit afficher une erreur).
  static Future<bool> sendWhatsAppReminderWithPdf(Sale order, {
    String currency = 'XAF',
    ShopSummary? shop,
    WhatsappService? whatsapp,
  }) async {
    final phone = order.clientPhone ?? '';
    if (phone.trim().isEmpty) return false;

    final s        = shop ?? LocalStorageService.getShop(order.shopId);
    final shopName = s?.name ?? 'Fortress';
    final fmt      = NumberFormat('#,###', 'fr_FR');
    final clientName = order.clientName ?? 'Cher client';
    final total      = '${fmt.format(order.total)} $currency';

    // 1. PDF avec images
    final bytes = await generateReminderPdf(order,
        shop: s, currency: currency);

    // 2. Upload (path distinct des factures pour ne pas écraser).
    final orderId = order.id
        ?? 'order_${order.createdAt.millisecondsSinceEpoch}';
    final longUrl = await InvoiceStorageService.uploadInvoice(
      shopId:  order.shopId,
      orderId: 'reminder_$orderId',
      bytes:   bytes,
    );
    if (longUrl == null) return false;

    // 3. Raccourcir l'URL (silencieux si échec → URL longue).
    final shortUrl = await UrlShortenerService.shorten(longUrl);

    // 4. Message WhatsApp.
    final msg =
        'Bonjour $clientName,\n\n'
        'Petit rappel pour votre commande chez $shopName '
        '(total : $total).\n\n'
        'Le détail complet de la commande est dans ce PDF :\n$shortUrl\n\n'
        'Êtes-vous disponible pour la livraison ? '
        'Merci et à bientôt 🙏';

    final wamePhone = PhoneFormatter.toWame(phone);
    final svc = whatsapp
        ?? const WhatsappService(provider: WameProvider());
    return svc.sendMessage(wamePhone, msg);
  }
}