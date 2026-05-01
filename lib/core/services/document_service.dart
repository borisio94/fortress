import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
export 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:http/http.dart' as http;
import '../../features/caisse/domain/entities/sale.dart';
import '../../features/inventaire/domain/entities/product.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';
import '../../features/crm/domain/entities/client.dart';
import '../storage/local_storage_service.dart';
import '../utils/currency_formatter.dart';

/// Formats de facture supportés.
enum InvoiceFormat {
  a4('A4'),
  thermal58('Ticket 58mm'),
  thermal80('Ticket 80mm');
  final String label;
  const InvoiceFormat(this.label);

  PdfPageFormat get pageFormat => switch (this) {
    InvoiceFormat.a4        => PdfPageFormat.a4,
    InvoiceFormat.thermal58 => const PdfPageFormat(58 * PdfPageFormat.mm, double.infinity,
        marginAll: 4 * PdfPageFormat.mm),
    InvoiceFormat.thermal80 => const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity,
        marginAll: 5 * PdfPageFormat.mm),
  };
}

/// Service centralisé pour la génération de documents, impression et partage.
class DocumentService {

  // ════════════════════════════════════════════════════════════════════════════
  // 1. GÉNÉRATION PDF
  // ════════════════════════════════════════════════════════════════════════════

  /// Génère une facture PDF en bytes.
  static Future<Uint8List> generateInvoice(Sale order, {
    InvoiceFormat format = InvoiceFormat.a4,
    PdfPageFormat? pageFormat,
    ShopSummary? shop,
    String currency = 'XAF',
  }) async {
    final s         = shop ?? LocalStorageService.getShop(order.shopId);
    final shopName  = s?.name ?? 'Fortress';
    final shopPhone = s?.phone;
    final shopEmail = s?.email;
    final pdf       = pw.Document();
    final fmt       = NumberFormat('#,###', 'fr_FR');
    final pFormat   = pageFormat ?? format.pageFormat;
    final isTicket  = pFormat.width < 250;

    pdf.addPage(pw.Page(
      pageFormat: pFormat,
      margin: pw.EdgeInsets.zero,
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // ── Bandeau en-tête violet ──────────────────────────────────
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
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(shopName,
                            style: pw.TextStyle(
                                fontSize: isTicket ? 16 : 26,
                                fontWeight: pw.FontWeight.bold,
                                color: _white)),
                        if (shopPhone != null)
                          pw.Text(shopPhone,
                              style: pw.TextStyle(fontSize: 10,
                                  color: _white.shade(0.75))),
                        if (shopEmail != null)
                          pw.Text(shopEmail,
                              style: pw.TextStyle(fontSize: 10,
                                  color: _white.shade(0.75))),
                      ],
                    ),
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: pw.BoxDecoration(
                          color: _violetDark,
                          borderRadius: pw.BorderRadius.circular(6)),
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
                              order.id?.replaceFirst('order_', '').replaceFirst('sale_', '') ?? '—',
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
                  pw.Row(children: [
                    _headerMeta('Date', DateFormat('dd/MM/yyyy').format(order.createdAt)),
                    pw.SizedBox(width: 32),
                    _headerMeta('Heure', DateFormat('HH:mm').format(order.createdAt)),
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

          // ── Corps ───────────────────────────────────────────────────
          pw.Expanded(child: pw.Container(
            color: _white,
            padding: pw.EdgeInsets.fromLTRB(
                isTicket ? 10 : 32, isTicket ? 12 : 24,
                isTicket ? 10 : 32, isTicket ? 12 : 24),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                // Méta ticket
                if (isTicket) ...[
                  pw.Text(DateFormat('dd/MM/yyyy HH:mm').format(order.createdAt),
                      style: pw.TextStyle(fontSize: 9, color: _grey500)),
                  if (order.clientName != null) ...[
                    pw.SizedBox(height: 3),
                    pw.Text('Client : ${order.clientName}',
                        style: pw.TextStyle(fontSize: 9,
                            fontWeight: pw.FontWeight.bold, color: _grey700)),
                  ],
                  pw.SizedBox(height: 8),
                ],
                // Bloc boutique/client A4
                if (!isTicket && order.clientName != null) ...[
                  pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                    pw.Expanded(child: _infoBox('DE', [
                      shopName,
                      if (shopPhone != null) shopPhone,
                      if (shopEmail != null) shopEmail,
                    ], _grey100, _grey200)),
                    pw.SizedBox(width: 12),
                    pw.Expanded(child: _infoBox('À', [
                      order.clientName!,
                      if (order.clientPhone != null) order.clientPhone!,
                      if (order.notes != null) order.notes!,
                    ], _violetLight, _violet.shade(0.3))),
                  ]),
                  pw.SizedBox(height: 16),
                ],

                // Titre section
                pw.Row(children: [
                  pw.Container(width: 3, height: 14, color: _violet),
                  pw.SizedBox(width: 8),
                  pw.Text('Articles', style: pw.TextStyle(
                      fontSize: isTicket ? 10 : 12,
                      fontWeight: pw.FontWeight.bold, color: _grey900)),
                ]),
                pw.SizedBox(height: 8),

                // En-tête tableau
                _tableHeader(isTicket, currency),

                // Lignes
                ...order.items.asMap().entries.map((e) =>
                    _tableRow(e.value, e.key.isOdd, isTicket, currency, fmt)),

                // Frais de commande
                if (order.totalFees > 0) ...[
                  pw.SizedBox(height: 6),
                  ...order.fees.map((f) {
                    final label  = f['label']?.toString() ?? 'Frais';
                    final amount = (f['amount'] as num?)?.toDouble() ?? 0;
                    return pw.Container(
                      padding: pw.EdgeInsets.symmetric(
                          horizontal: isTicket ? 6 : 10, vertical: 3),
                      child: pw.Row(children: [
                        pw.Expanded(child: pw.Text(label,
                            style: pw.TextStyle(fontSize: isTicket ? 8 : 9,
                                color: _grey500, fontStyle: pw.FontStyle.italic))),
                        pw.Text('${fmt.format(amount)} $currency',
                            style: pw.TextStyle(fontSize: isTicket ? 8 : 9,
                                color: _grey700)),
                      ]),
                    );
                  }),
                ],

                pw.SizedBox(height: 16),

                // Récap
                pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Container(
                    width: isTicket ? double.infinity : 240,
                    padding: const pw.EdgeInsets.all(12),
                    decoration: pw.BoxDecoration(
                        color: _violetLight,
                        borderRadius: pw.BorderRadius.circular(8),
                        border: pw.Border.all(color: _violet.shade(0.3), width: 0.5)),
                    child: pw.Column(children: [
                      _recapRow('Sous-total', '${fmt.format(order.subtotal)} $currency', isTicket: isTicket),
                      if (order.totalFees > 0)
                        _recapRow('Frais', '${fmt.format(order.totalFees)} $currency', isTicket: isTicket),
                      if (order.discountAmount > 0)
                        _recapRow('Remise', '- ${fmt.format(order.discountAmount)} $currency',
                            color: _orange, isTicket: isTicket),
                      if (order.taxRate > 0)
                        _recapRow('TVA (${order.taxRate.toStringAsFixed(0)}%)',
                            '${fmt.format(order.taxAmount)} $currency', isTicket: isTicket),
                      pw.Container(height: 0.5, color: _violet,
                          margin: const pw.EdgeInsets.symmetric(vertical: 6)),
                      _recapRow('TOTAL', '${fmt.format(order.total)} $currency',
                          bold: true, large: true, color: _violet, isTicket: isTicket),
                      pw.SizedBox(height: 4),
                      _recapRow('Paiement', _paymentLabel(order.paymentMethod),
                          isTicket: isTicket),
                    ]),
                  ),
                ),

                pw.Spacer(),

                // Pied de page
                pw.Container(
                  padding: pw.EdgeInsets.symmetric(vertical: isTicket ? 8 : 14),
                  decoration: pw.BoxDecoration(
                      border: pw.Border(top: pw.BorderSide(color: _grey200, width: 0.5))),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.center,
                    children: [
                      pw.Text('Merci pour votre commande !',
                          style: pw.TextStyle(
                              fontSize: isTicket ? 9 : 11,
                              fontWeight: pw.FontWeight.bold, color: _violet)),
                      pw.SizedBox(height: 3),
                      pw.Text('Fortress POS  •  ${DateFormat('dd/MM/yyyy').format(DateTime.now())}',
                          style: pw.TextStyle(fontSize: 8, color: _grey500)),
                    ],
                  ),
                ),
              ],
            ),
          )),
        ],
      ),
    ));
    return pdf.save();
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 2. IMPRESSION
  // ════════════════════════════════════════════════════════════════════════════

  /// Dialogue d'impression natif.
  static Future<void> printInvoice(Sale order, {
    InvoiceFormat format = InvoiceFormat.a4,
    PdfPageFormat? pageFormat,
    ShopSummary? shop,
  }) async {
    final pf = pageFormat ?? format.pageFormat;
    final bytes = await generateInvoice(order, pageFormat: pf, shop: shop);
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: 'facture_${order.id ?? 'commande'}.pdf',
      format: pf,
    );
  }

  /// Aperçu PDF (ouvre dans le visualiseur natif).
  static Future<void> previewInvoice(Sale order, BuildContext context, {
    InvoiceFormat format = InvoiceFormat.a4,
    PdfPageFormat? pageFormat,
    ShopSummary? shop,
  }) async {
    final pf = pageFormat ?? format.pageFormat;
    final bytes = await generateInvoice(order, pageFormat: pf, shop: shop);
    final file  = await _saveTempPdf(bytes, order.id);
    try {
      final result = await OpenFilex.open(file.path);
      if (result.type == ResultType.done) return;
    } catch (_) {}
    // Fallback : dialogue d'impression
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: 'facture_${order.id ?? 'commande'}.pdf',
      format: pf,
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ════════════════════════════════════════════════════════════════════════════
  // 3. PARTAGE FACTURE PDF
  // ════════════════════════════════════════════════════════════════════════════

  /// Partage la facture PDF via le share sheet natif (mobile) ou sauvegarde locale (desktop).
  static Future<void> shareInvoice(Sale order, {
    InvoiceFormat format = InvoiceFormat.a4,
    PdfPageFormat? pageFormat,
    ShopSummary? shop,
  }) async {
    final s     = shop ?? LocalStorageService.getShop(order.shopId);
    final bytes = await generateInvoice(order,
        pageFormat: pageFormat ?? format.pageFormat, shop: s);
    final file  = await _saveTempPdf(bytes, order.id);
    final caption = '🧾 Facture ${s?.name ?? "Fortress"} — ${CurrencyFormatter.format(order.total)}';

    if (_isDesktop) {
      try {
        final dl   = await _downloadsDir;
        final name = 'facture_${order.id ?? 'commande'}'.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
        final dest = File('${dl.path}/$name.pdf');
        await file.copy(dest.path);
        try { await OpenFilex.open(dest.path); } catch (_) {}
      } catch (_) {
        try { await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'facture.pdf'); } catch (_) {}
      }
    } else {
      try {
        await Share.shareXFiles([XFile(file.path)], text: caption);
      } catch (_) {
        try { await Share.share(caption); } catch (_) {}
      }
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // 4. PARTAGE PRODUITS
  // ════════════════════════════════════════════════════════════════════════════

  /// Partager un seul produit (image + texte).
  static Future<void> shareProduct(Product product, {String? shopId}) async {
    final shop = shopId != null ? LocalStorageService.getShop(shopId) : null;
    final msg  = _productMessage(product, shop);
    final img  = await _resolveImage(product);

    if (img != null) {
      await Share.shareXFiles([XFile(img.path)], text: msg);
    } else {
      await Share.share(msg);
    }
  }

  /// Partager plusieurs produits avec images.
  static Future<void> shareProducts(List<Product> products, {String? shopId}) async {
    final shop    = shopId != null ? LocalStorageService.getShop(shopId) : null;
    final limited = products.take(10).toList();
    final msg     = _catalogMessage(limited, shop);

    final files = <XFile>[];
    for (final p in limited) {
      final img = await _resolveImage(p);
      if (img != null) files.add(XFile(img.path));
    }
    if (files.isNotEmpty) {
      await Share.shareXFiles(files, text: msg);
    } else {
      await Share.share(msg);
    }
  }

  /// Partager un catalogue à une liste de clients via le share sheet natif.
  static Future<void> shareToClients({
    required List<Product> products,
    required List<Client> recipients,
    String? shopId,
    String? message,
  }) async {
    final shop = shopId != null ? LocalStorageService.getShop(shopId) : null;
    final msg = message ?? _catalogMessage(products.take(10).toList(), shop);
    await Share.share(msg);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // MESSAGES TEXTE
  // ════════════════════════════════════════════════════════════════════════════

  static String _productMessage(Product p, ShopSummary? shop) {
    final buf = StringBuffer();
    if (shop != null) buf.writeln('🛍️ ${shop.name}\n');
    buf.writeln('✨ ${p.name}');
    if (p.priceSellPos > 0) buf.writeln('💰 Prix : ${CurrencyFormatter.format(p.priceSellPos)}');
    buf.writeln('📦 Stock : ${p.totalStock} disponible${p.totalStock > 1 ? 's' : ''}');
    if (p.description != null && p.description!.isNotEmpty) buf.writeln('📝 ${p.description}');
    buf.writeln('\nContactez-nous pour commander !');
    if (shop?.phone != null) buf.writeln('📞 ${shop!.phone}');
    return buf.toString();
  }

  static String _catalogMessage(List<Product> products, ShopSummary? shop) {
    final buf = StringBuffer();
    buf.writeln('🛍️ ${shop?.name ?? "Nos produits"} — Nouveautés\n');
    for (final p in products) {
      final price = p.priceSellPos > 0
          ? CurrencyFormatter.format(p.priceSellPos) : 'Sur demande';
      buf.writeln('✨ ${p.name} — $price');
      if (p.description != null && p.description!.isNotEmpty) {
        final desc = p.description!.length > 60
            ? '${p.description!.substring(0, 57)}…' : p.description!;
        buf.writeln('   $desc');
      }
    }
    buf.writeln('\n📦 Disponible maintenant en boutique');
    buf.writeln('📞 Contactez-nous pour commander !');
    if (shop != null) {
      buf.write('\n_${shop.name}');
      if (shop.phone != null) buf.write(' • ${shop.phone}');
      buf.writeln('_');
    }
    return buf.toString();
  }

  /// Génère le message catalogue (accessible publiquement pour l'aperçu).
  static String buildCatalogMessage(List<Product> products, {String? shopId}) {
    final shop = shopId != null ? LocalStorageService.getShop(shopId) : null;
    return _catalogMessage(products.take(10).toList(), shop);
  }

  static String _paymentLabel(PaymentMethod m) => switch (m) {
    PaymentMethod.cash        => 'Espèces',
    PaymentMethod.mobileMoney => 'Mobile Money',
    PaymentMethod.card        => 'Carte bancaire',
    PaymentMethod.credit      => 'Crédit',
  };

  // ════════════════════════════════════════════════════════════════════════════
  // HELPERS PDF
  // ════════════════════════════════════════════════════════════════════════════

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
  static final _orange      = PdfColor.fromHex('#F59E0B');

  static pw.Widget _headerMeta(String label, String value) =>
      pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(label, style: pw.TextStyle(fontSize: 8, color: _white.shade(0.6),
            letterSpacing: 0.8, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text(value, style: pw.TextStyle(fontSize: 11,
            fontWeight: pw.FontWeight.bold, color: _white)),
      ]);

  static pw.Widget _infoBox(String title, List<String> lines,
      PdfColor bg, PdfColor border) =>
      pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(color: bg,
            borderRadius: pw.BorderRadius.circular(6),
            border: pw.Border.all(color: border, width: 0.5)),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(title, style: pw.TextStyle(fontSize: 7, color: _grey500,
                letterSpacing: 1.2, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            ...lines.map((l) => pw.Text(l,
                style: pw.TextStyle(fontSize: 10, color: _grey700))),
          ],
        ),
      );

  static pw.Widget _tableHeader(bool isTicket, String currency) =>
      pw.Container(
        color: _violet,
        padding: pw.EdgeInsets.symmetric(
            horizontal: isTicket ? 6 : 10, vertical: 5),
        child: isTicket
            ? pw.Row(children: [
                pw.Expanded(child: pw.Text('Produit', style: pw.TextStyle(color: _white, fontWeight: pw.FontWeight.bold, fontSize: 8))),
                pw.SizedBox(width: 36, child: pw.Text('Qté', textAlign: pw.TextAlign.center, style: pw.TextStyle(color: _white, fontWeight: pw.FontWeight.bold, fontSize: 8))),
                pw.SizedBox(width: 52, child: pw.Text('Total', textAlign: pw.TextAlign.right, style: pw.TextStyle(color: _white, fontWeight: pw.FontWeight.bold, fontSize: 8))),
              ])
            : pw.Row(children: [
                pw.Expanded(flex: 4, child: pw.Text('Produit', style: pw.TextStyle(color: _white, fontWeight: pw.FontWeight.bold, fontSize: 10))),
                pw.SizedBox(width: 50, child: pw.Text('Qté', textAlign: pw.TextAlign.center, style: pw.TextStyle(color: _white, fontWeight: pw.FontWeight.bold, fontSize: 10))),
                pw.SizedBox(width: 80, child: pw.Text('Prix unit.', textAlign: pw.TextAlign.right, style: pw.TextStyle(color: _white, fontWeight: pw.FontWeight.bold, fontSize: 10))),
                pw.SizedBox(width: 80, child: pw.Text('Sous-total', textAlign: pw.TextAlign.right, style: pw.TextStyle(color: _white, fontWeight: pw.FontWeight.bold, fontSize: 10))),
              ]),
      );

  static pw.Widget _tableRow(dynamic item, bool odd, bool isTicket,
      String currency, NumberFormat fmt) {
    final i = item as dynamic;
    return pw.Container(
      color: odd ? _violetMid : _white,
      padding: pw.EdgeInsets.symmetric(
          horizontal: isTicket ? 6 : 10, vertical: isTicket ? 4 : 6),
      child: isTicket
          ? pw.Row(children: [
              pw.Expanded(child: pw.Text(i.productName, style: const pw.TextStyle(fontSize: 9))),
              pw.SizedBox(width: 36, child: pw.Text('${i.quantity}', textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 9))),
              pw.SizedBox(width: 52, child: pw.Text('${fmt.format(i.subtotal)}', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
            ])
          : pw.Row(children: [
              pw.Expanded(flex: 4, child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text(i.productName, style: pw.TextStyle(fontSize: 10, color: _grey900)),
                if (i.variantName != null) pw.Text(i.variantName!, style: pw.TextStyle(fontSize: 9, color: _grey500)),
              ])),
              pw.SizedBox(width: 50, child: pw.Text('${i.quantity}', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 10, color: _grey700))),
              pw.SizedBox(width: 80, child: pw.Text('${fmt.format(i.effectivePrice)} $currency', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 10, color: _grey700))),
              pw.SizedBox(width: 80, child: pw.Text('${fmt.format(i.subtotal)} $currency', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _grey900))),
            ]),
    );
  }

  static pw.Widget _recapRow(String label, String value, {
    bool bold = false, bool large = false, PdfColor? color, bool isTicket = false,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 2),
    child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Text(label, style: pw.TextStyle(
          fontSize: (isTicket ? 8 : 10) + (large ? 2 : 0),
          color: color ?? _grey700,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      pw.Text(value, style: pw.TextStyle(
          fontSize: (isTicket ? 9 : 11) + (large ? 2 : 0),
          color: color ?? _grey900,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
    ]),
  );

  // ════════════════════════════════════════════════════════════════════════════
  // HELPERS PLATEFORME
  // ════════════════════════════════════════════════════════════════════════════

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static Future<File> _saveTempPdf(Uint8List bytes, String? id) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/facture_${id ?? 'commande'}.pdf');
    await file.writeAsBytes(bytes);
    return file;
  }

  static Future<Directory> get _downloadsDir async {
    if (Platform.isWindows) {
      final dl = Directory('${Platform.environment['USERPROFILE']}\\Downloads');
      if (await dl.exists()) return dl;
    }
    if (Platform.isLinux || Platform.isMacOS) {
      final dl = Directory('${Platform.environment['HOME']}/Downloads');
      if (await dl.exists()) return dl;
    }
    return await getTemporaryDirectory();
  }

  static Future<File?> _resolveImage(Product product) async {
    final urls = <String>[
      if (product.mainImageUrl != null) product.mainImageUrl!,
      ...product.variants
          .where((v) => v.imageUrl != null && v.imageUrl!.isNotEmpty)
          .map((v) => v.imageUrl!),
    ];
    for (final url in urls) {
      try {
        if (url.startsWith('http')) {
          final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
          if (resp.statusCode != 200) continue;
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/share_${product.id ?? 'p'}.jpg');
          await file.writeAsBytes(resp.bodyBytes);
          return file;
        } else {
          final local = File(url);
          if (await local.exists()) {
            final dir = await getTemporaryDirectory();
            final dest = File('${dir.path}/share_${product.id ?? 'p'}.jpg');
            return await local.copy(dest.path);
          }
        }
      } catch (_) {}
    }
    return null;
  }
}
