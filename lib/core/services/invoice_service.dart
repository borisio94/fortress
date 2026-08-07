import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../features/caisse/domain/entities/sale.dart';
import '../../features/caisse/domain/entities/sale_item.dart';
import '../../features/caisse/domain/invoice_theme.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';
import '../utils/currency_formatter.dart';
import 'logo_color_extractor.dart';
import 'logo_storage_service.dart';

/// Génération de la facture PDF A4 personnalisée — logo de la
/// boutique + palette dérivée. Lecture seule (aucune écriture
/// Supabase). Le caller récupère les bytes et les passe à
/// `printing.layoutPdf` (aperçu/impression) ou à `share_plus`
/// (partage).
///
/// La spec (couleurs, tailles, layout) vit dans `InvoiceTheme` —
/// rien n'est codé en dur dans ce service en dehors des libellés
/// français de la mise en page (« Facturer à », « TOTAL TTC », etc.).
class InvoiceService {
  const InvoiceService._();

  /// Génère la facture PDF de [sale] selon l'identité visuelle de
  /// [shop]. Charge le logo depuis le cache Hive si présent, sinon
  /// tente un fetch HTTP. Si tout échoue → PDF sans logo + couleurs
  /// fallback. Cette méthode ne lève jamais — toute erreur est
  /// journalisée et le PDF est retourné vide (Uint8List(0)) en cas
  /// d'échec total de la composition.
  /// Rouleau thermique 80 mm, hauteur libre — le format d'impression par
  /// DÉFAUT. Un rouleau ne se coupe pas à une page : la hauteur est infinie et
  /// le ticket s'allonge avec le nombre d'articles.
  ///
  /// Marge de 6 mm : les têtes thermiques n'impriment pas jusqu'au bord, et
  /// une marge trop mince fait rogner les montants alignés à droite.
  static const PdfPageFormat roll80 = PdfPageFormat(
    80 * PdfPageFormat.mm,
    double.infinity,
    marginAll: 6 * PdfPageFormat.mm,
  );

  /// En dessous de cette largeur, la mise en page bascule sur le ticket.
  /// 80 mm valent ~227 pt : le seuil laisse passer un 58 mm sans ambiguïté et
  /// exclut l'A4 (595 pt).
  static const double _ticketMaxWidth = 300;

  /// [format] : `roll80` par défaut. Passer `PdfPageFormat.a4` pour la
  /// facture pleine page (mise en page distincte, conservée intacte).
  static Future<Uint8List> generatePdf({
    required Sale sale,
    required ShopSummary shop,
    PdfPageFormat format = roll80,
  }) async {
    // 1. Charger les bytes du logo (cache → fetch). Si null, on
    //    génère sans logo (fallback gracieux).
    Uint8List? logoBytes;
    try {
      logoBytes = await LogoStorageService.fetchBytes(
          shopId: shop.id, url: shop.logoUrl);
    } catch (e) {
      debugPrint('[InvoiceService] logo fetch : $e');
      logoBytes = null;
    }
    // 2. Si le logo vient d'être chargé pour la première fois, on
    //    s'assure que les couleurs sont extraites (idempotent).
    if (logoBytes != null) {
      final cached = LogoColorExtractor.cached(shop.id);
      // Heuristique : si les couleurs cachées sont au fallback
      // (#1A1A1A + #555555) et qu'on a maintenant un logo, on
      // tente l'extraction. Sinon on garde le cache.
      final isFallback =
          cached.primary  == LogoColorExtractor.defaultPrimary &&
          cached.secondary == LogoColorExtractor.defaultSecondary;
      if (isFallback) {
        await LogoColorExtractor.extractAndCache(
            shopId: shop.id, bytes: logoBytes);
      }
    }
    final theme = InvoiceTheme.fromCache(
        shopId: shop.id, logoBytes: logoBytes);
    try {
      final doc = pw.Document();
      doc.addPage(format.width < _ticketMaxWidth
          ? _buildTicketPage(
              sale: sale, shop: shop, theme: theme, format: format)
          : _buildPage(sale: sale, shop: shop, theme: theme));
      return doc.save();
    } catch (e, st) {
      debugPrint('[InvoiceService] genération PDF échouée : $e\n$st');
      return Uint8List(0);
    }
  }

  // ══ TICKET 80 mm ════════════════════════════════════════════════
  //
  // Mise en page ENTIÈREMENT distincte de l'A4, et non un A4 rétréci. Sur
  // 198 pt utiles, le tableau à quatre colonnes de la facture pleine page est
  // impossible : ses seules colonnes fixes (qté 40 + prix 80 + total 80) les
  // consomment déjà toutes, ne laissant rien à la désignation.
  //
  // Le ticket adopte donc la convention des caisses : une ligne par article
  // pour son nom, une seconde pour « qté × prix » à gauche et le total à
  // droite. Tout est aligné sur la pleine largeur, rien n'est mis côte à côte.
  //
  // Ce qui disparaît par rapport à l'A4, volontairement : le bloc de garantie
  // (un an sur un plat n'a pas de sens, et il coûterait 3 cm de papier à
  // chaque service) et la numérotation des pages (un rouleau n'en a qu'une).

  static pw.Page _buildTicketPage({
    required Sale          sale,
    required ShopSummary   shop,
    required InvoiceTheme  theme,
    required PdfPageFormat format,
  }) {
    final infos = [
      if ((sale.clientPhone ?? '').trim().isNotEmpty) sale.clientPhone!.trim(),
      if ((sale.deliveryAddress ?? '').trim().isNotEmpty)
        sale.deliveryAddress!.trim(),
    ].join(' · ');
    final client = (sale.clientName ?? '').trim();
    final contact = [
      if ((shop.phone ?? '').isNotEmpty) 'Tél : ${shop.phone}',
      if ((shop.email ?? '').isNotEmpty) shop.email,
    ].where((s) => s != null && s.toString().trim().isNotEmpty).join('\n');

    return pw.Page(
      pageFormat: format,
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // ── En-tête centré ───────────────────────────────────────
          if (theme.logoBytes != null) ...[
            pw.Center(
              child: pw.Container(
                constraints: const pw.BoxConstraints(
                    maxWidth: 90, maxHeight: 50),
                child: pw.Image(pw.MemoryImage(theme.logoBytes!),
                    fit: pw.BoxFit.contain),
              ),
            ),
            pw.SizedBox(height: 6),
          ],
          pw.Center(
            child: pw.Text(shop.name,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                    fontSize: 13,
                    fontWeight: pw.FontWeight.bold,
                    color: theme.primary)),
          ),
          if (contact.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Center(
              child: pw.Text(contact,
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(
                      fontSize: 7.5, color: InvoiceTheme.textSecondary)),
            ),
          ],
          pw.SizedBox(height: 6),
          pw.Container(height: 1, color: theme.primary),
          pw.SizedBox(height: 5),
          pw.Center(
            child: pw.Text(_invoiceMeta(sale),
                style: const pw.TextStyle(
                    fontSize: 8, color: InvoiceTheme.textPrimary)),
          ),
          if (client.isNotEmpty || infos.isNotEmpty) ...[
            pw.SizedBox(height: 4),
            pw.Center(
              child: pw.Text(
                  [if (client.isNotEmpty) client, if (infos.isNotEmpty) infos]
                      .join('\n'),
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(
                      fontSize: 8, color: InvoiceTheme.textSecondary)),
            ),
          ],
          pw.SizedBox(height: 6),
          _ticketDivider(),

          // ── Articles ─────────────────────────────────────────────
          for (final item in sale.items) _ticketItem(item, shop),

          _ticketDivider(),
          pw.SizedBox(height: 3),

          // ── Totaux ───────────────────────────────────────────────
          _ticketLine('Sous-total', _money(sale.subtotal, shop), size: 8),
          if (sale.discountAmount > 0)
            _ticketLine('Remise', '− ${_money(sale.discountAmount, shop)}',
                size: 8, color: theme.secondary),
          if (sale.taxRate > 0)
            _ticketLine('TVA (${sale.taxRate.toStringAsFixed(1)} %)',
                _money(sale.taxAmount, shop), size: 8),
          if (sale.deliveryFeeToFix)
            _ticketLine('Livraison', 'À confirmer', size: 8)
          else if ((sale.deliveryPrice ?? 0) > 0)
            _ticketLine('Livraison', _money(sale.deliveryPrice!, shop),
                size: 8),
          ...sale.fees
              .where((f) => ((f['amount'] as num?)?.toDouble() ?? 0) > 0)
              .map((f) {
            final lbl = (f['label'] as String?)?.trim();
            return _ticketLine(
                (lbl == null || lbl.isEmpty) ? 'Frais' : lbl,
                _money((f['amount'] as num?)?.toDouble() ?? 0, shop),
                size: 8);
          }),
          pw.SizedBox(height: 3),
          pw.Container(height: 1, color: theme.primary),
          pw.SizedBox(height: 3),
          _ticketLine('TOTAL', _money(sale.total, shop),
              size: 12, color: theme.primary, bold: true),
          if (sale.amountPaid > 0)
            _ticketLine('Payé', _money(sale.amountPaid, shop), size: 8),
          if (sale.amountDue > 0)
            _ticketLine('Reste dû', _money(sale.amountDue, shop),
                size: 9, color: theme.secondary, bold: true),

          if ((sale.notes ?? '').trim().isNotEmpty) ...[
            pw.SizedBox(height: 6),
            _ticketDivider(),
            pw.Text(sale.notes!.trim(),
                style: const pw.TextStyle(
                    fontSize: 8, color: InvoiceTheme.textPrimary)),
          ],

          // ── Pied ─────────────────────────────────────────────────
          pw.SizedBox(height: 8),
          pw.Center(
            child: pw.Text('Merci pour votre confiance',
                style: pw.TextStyle(
                    fontSize: 8.5,
                    fontWeight: pw.FontWeight.bold,
                    color: theme.primary)),
          ),
          pw.SizedBox(height: 2),
          pw.Center(
            child: pw.Text('Édité depuis Fortress POS',
                style: const pw.TextStyle(
                    fontSize: 7, color: InvoiceTheme.footerBrand)),
          ),
          // Marge basse : la lame de coupe tombe quelques millimètres sous la
          // dernière ligne imprimée, sans quoi elle tranche le texte.
          pw.SizedBox(height: 14),
        ],
      ),
    );
  }

  /// Un article : nom sur sa ligne, « qté × prix unitaire » et total sur la
  /// suivante. La quantité reste visible même à 1 — le client vérifie ce
  /// qu'on lui a compté, pas seulement ce qu'il doit.
  static pw.Widget _ticketItem(SaleItem item, ShopSummary shop) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(_itemLabel(item),
              style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                  color: InvoiceTheme.textPrimary)),
          pw.SizedBox(height: 1),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                  '${item.quantity} × ${_money(item.effectivePrice, shop)}',
                  style: const pw.TextStyle(
                      fontSize: 8, color: InvoiceTheme.textSecondary)),
              pw.Text(_money(item.subtotal, shop),
                  style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                      color: InvoiceTheme.textPrimary)),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _ticketLine(
    String label,
    String value, {
    required double size,
    PdfColor? color,
    bool bold = false,
  }) {
    final style = pw.TextStyle(
      fontSize: size,
      color: color ?? InvoiceTheme.textSecondary,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    );
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Expanded(child: pw.Text(label, style: style)),
          pw.Text(value, style: style),
        ],
      ),
    );
  }

  static pw.Widget _ticketDivider() => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child:
            pw.Container(height: 0.5, color: InvoiceTheme.divider),
      );

  // ── Page A4 unique avec MultiPage pour gérer les longues listes ──

  static pw.Page _buildPage({
    required Sale         sale,
    required ShopSummary  shop,
    required InvoiceTheme theme,
  }) {
    // `pageTheme` SEUL : le paquet `pdf` interdit de le combiner à
    // `pageFormat` / `margin` et le vérifie par une assertion. Les deux
    // étaient passés ici, ce qui faisait échouer la composition — et
    // `generatePdf` avalant l'exception, la facture A4 sortait VIDE. Invisible
    // en release, où les assertions sont retirées ; systématique en debug et
    // en test. Le format et les marges vivent donc uniquement dans le thème.
    return pw.MultiPage(
      // Fond page constant via PageTheme — ne dépend pas du logo.
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        buildBackground: (_) => pw.FullPage(
          ignoreMargins: true,
          child: pw.Container(color: InvoiceTheme.pageBackground),
        ),
      ),
      header: (ctx) => ctx.pageNumber == 1
          ? _header(sale: sale, shop: shop, theme: theme)
          : pw.SizedBox(height: 12),
      footer: (ctx) => _footer(shop: shop, theme: theme,
          pageNumber: ctx.pageNumber, pagesCount: ctx.pagesCount),
      build: (ctx) => [
        pw.SizedBox(height: 8),
        _clientBlock(sale: sale, theme: theme),
        pw.SizedBox(height: 14),
        _itemsTable(sale: sale, shop: shop, theme: theme),
        pw.SizedBox(height: 10),
        _totalsBlock(sale: sale, shop: shop, theme: theme),
        if ((sale.notes ?? '').trim().isNotEmpty) ...[
          pw.SizedBox(height: 14),
          _notesBlock(sale.notes!.trim(), theme),
        ],
        pw.SizedBox(height: 14),
        _warrantyBlock(theme),
      ],
    );
  }

  // ── En-tête : logo + nom + ligne « FACTURE N° + date » ─────────

  static pw.Widget _header({
    required Sale         sale,
    required ShopSummary  shop,
    required InvoiceTheme theme,
  }) {
    final shopAddress = [
      if ((shop.phone ?? '').isNotEmpty) 'Tél : ${shop.phone}',
      if ((shop.email ?? '').isNotEmpty) shop.email,
      shop.country,
    ].where((s) => s != null && s.toString().trim().isNotEmpty)
     .join(' · ');
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (theme.logoBytes != null)
              pw.Container(
                margin: const pw.EdgeInsets.only(right: 14),
                constraints: const pw.BoxConstraints(
                  maxWidth: 80, maxHeight: 80,
                ),
                child: pw.Image(
                  pw.MemoryImage(theme.logoBytes!),
                  fit: pw.BoxFit.contain,
                ),
              ),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(shop.name,
                      style: pw.TextStyle(
                          fontSize: 18,
                          fontWeight: pw.FontWeight.bold,
                          color: theme.primary)),
                  if (shopAddress.isNotEmpty) ...[
                    pw.SizedBox(height: 3),
                    pw.Text(shopAddress,
                        style: const pw.TextStyle(
                            fontSize: 10,
                            color: InvoiceTheme.textSecondary)),
                  ],
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 10),
        pw.Container(height: 1, color: theme.primary),
        pw.SizedBox(height: 10),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text('FACTURE',
                style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 1.5,
                    color: theme.primary)),
            pw.Text(_invoiceMeta(sale),
                style: const pw.TextStyle(
                    fontSize: 10, color: InvoiceTheme.textPrimary)),
          ],
        ),
      ],
    );
  }

  static String _invoiceMeta(Sale sale) {
    final id = (sale.id ?? '').isEmpty
        ? '—'
        : (sale.id!.length > 8
            ? sale.id!.substring(0, 8).toUpperCase()
            : sale.id!.toUpperCase());
    final d = sale.createdAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${two(d.day)}/${two(d.month)}/${d.year}';
    return 'N° $id  ·  $date';
  }

  // ── Bloc client ───────────────────────────────────────────────

  static pw.Widget _clientBlock({
    required Sale         sale,
    required InvoiceTheme theme,
  }) {
    final name = (sale.clientName ?? '').trim();
    final infos = [
      if ((sale.clientPhone ?? '').trim().isNotEmpty) sale.clientPhone!.trim(),
      if ((sale.deliveryCity ?? '').trim().isNotEmpty) sale.deliveryCity!.trim(),
      if ((sale.deliveryAddress ?? '').trim().isNotEmpty) sale.deliveryAddress!.trim(),
    ].join(' · ');
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('FACTURER À',
            style: pw.TextStyle(
                fontSize: 9,
                letterSpacing: 1.0,
                color: theme.secondary,
                fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text(name.isEmpty ? '—' : name,
            style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: InvoiceTheme.textPrimary)),
        if (infos.isNotEmpty) ...[
          pw.SizedBox(height: 2),
          pw.Text(infos,
              style: const pw.TextStyle(
                  fontSize: 10, color: InvoiceTheme.textSecondary)),
        ],
      ],
    );
  }

  // ── Tableau articles ──────────────────────────────────────────

  static pw.Widget _itemsTable({
    required Sale         sale,
    required ShopSummary  shop,
    required InvoiceTheme theme,
  }) {
    final items = sale.items;
    return pw.Table(
      columnWidths: const {
        0: pw.FlexColumnWidth(5),
        1: pw.FixedColumnWidth(40),
        2: pw.FixedColumnWidth(80),
        3: pw.FixedColumnWidth(80),
      },
      children: [
        // Header — fond blanc, texte noir + ligne basse primary (1.2 pt)
        // pour conserver l'accent thème sans aplat coloré. La signature
        // visuelle reste : seul un trait fin marque la limite header/body,
        // ce qui laisse la couleur primaire comme accent et non comme bloc.
        pw.TableRow(
          decoration: pw.BoxDecoration(
            color: InvoiceTheme.pageBackground,
            border: pw.Border(
              bottom: pw.BorderSide(color: theme.primary, width: 1.2),
            ),
          ),
          children: [
            _headerCell('Désignation', pw.TextAlign.left),
            _headerCell('Qté',         pw.TextAlign.center),
            _headerCell('Prix unit.',  pw.TextAlign.right),
            _headerCell('Total',       pw.TextAlign.right),
          ],
        ),
        // Body rows (alternance)
        for (var i = 0; i < items.length; i++)
          pw.TableRow(
            decoration: pw.BoxDecoration(
              color: i.isEven
                  ? InvoiceTheme.pageBackground
                  : InvoiceTheme.rowAltBackground,
            ),
            children: [
              _bodyCell(_itemLabel(items[i]),
                  align: pw.TextAlign.left, bold: true),
              _bodyCell('${items[i].quantity}',
                  align: pw.TextAlign.center),
              _bodyCell(_money(items[i].effectivePrice, shop),
                  align: pw.TextAlign.right),
              _bodyCell(_money(items[i].subtotal, shop),
                  align: pw.TextAlign.right),
            ],
          ),
      ],
    );
  }

  static pw.Widget _headerCell(String text, pw.TextAlign align) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: pw.Text(
          text,
          textAlign: align,
          style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              letterSpacing: 0.4,
              color: InvoiceTheme.textPrimary),
        ),
      );

  static pw.Widget _bodyCell(String text,
      {required pw.TextAlign align, bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
          fontSize: 10,
          color: InvoiceTheme.textPrimary,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  static String _itemLabel(SaleItem item) {
    final base = item.productName;
    final variant = (item.variantName ?? '').trim();
    return variant.isEmpty ? base : '$base — $variant';
  }

  // ── Totaux ────────────────────────────────────────────────────

  static pw.Widget _totalsBlock({
    required Sale         sale,
    required ShopSummary  shop,
    required InvoiceTheme theme,
  }) {
    final hasDiscount = sale.discountAmount > 0;
    final hasDue      = sale.amountDue > 0;
    final hasPaid     = sale.amountPaid > 0;
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.end,
      children: [
        pw.SizedBox(
          width: 240,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              _totalLine('Sous-total', _money(sale.subtotal, shop),
                  size: 10, color: InvoiceTheme.textSecondary),
              if (hasDiscount)
                _totalLine('Remise', '− ${_money(sale.discountAmount, shop)}',
                    size: 10, color: theme.secondary),
              if (sale.taxRate > 0)
                _totalLine('TVA (${sale.taxRate.toStringAsFixed(1)} %)',
                    _money(sale.taxAmount, shop),
                    size: 10, color: InvoiceTheme.textSecondary),
              // Frais de livraison par quartier (PR-2/3). Le TOTAL TTC inclut
              // déjà ce montant ; ligne dédiée pour le détail client.
              if (sale.deliveryFeeToFix)
                _totalLine('Livraison', 'À confirmer',
                    size: 10, color: InvoiceTheme.textSecondary)
              else if ((sale.deliveryPrice ?? 0) > 0)
                _totalLine('Livraison', _money(sale.deliveryPrice!, shop),
                    size: 10, color: InvoiceTheme.textSecondary),
              // Autres dépenses supplémentaires (emballage…) — chacune
              // s'ajoute au total facturé au client.
              ...sale.fees
                  .where((f) => ((f['amount'] as num?)?.toDouble() ?? 0) > 0)
                  .map((f) {
                    final lbl = (f['label'] as String?)?.trim();
                    return _totalLine(
                        (lbl == null || lbl.isEmpty) ? 'Frais' : lbl,
                        _money((f['amount'] as num?)?.toDouble() ?? 0, shop),
                        size: 10, color: InvoiceTheme.textSecondary);
                  }),
              pw.SizedBox(height: 4),
              pw.Container(height: 1, color: InvoiceTheme.divider),
              pw.SizedBox(height: 4),
              _totalLine('TOTAL TTC', _money(sale.total, shop),
                  size: 14,
                  color: theme.primary,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 0.5),
              if (hasPaid)
                _totalLine('Paiement reçu', _money(sale.amountPaid, shop),
                    size: 10, color: InvoiceTheme.textSecondary),
              if (hasDue)
                _totalLine('Reste dû', _money(sale.amountDue, shop),
                    size: 11,
                    color: theme.secondary,
                    fontWeight: pw.FontWeight.bold),
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _totalLine(
    String label,
    String value, {
    required double size,
    required PdfColor color,
    pw.FontWeight fontWeight = pw.FontWeight.normal,
    double letterSpacing = 0.0,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label,
              style: pw.TextStyle(
                  fontSize: size,
                  color: color,
                  fontWeight: fontWeight,
                  letterSpacing: letterSpacing)),
          pw.Text(value,
              style: pw.TextStyle(
                  fontSize: size,
                  color: color,
                  fontWeight: fontWeight)),
        ],
      ),
    );
  }

  // ── Notes éventuelles ─────────────────────────────────────────

  static pw.Widget _notesBlock(String notes, InvoiceTheme theme) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: InvoiceTheme.divider, width: 0.5),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('NOTES',
              style: pw.TextStyle(
                  fontSize: 8,
                  letterSpacing: 1.0,
                  color: theme.secondary,
                  fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 3),
          pw.Text(notes,
              style: const pw.TextStyle(
                  fontSize: 10, color: InvoiceTheme.textPrimary)),
        ],
      ),
    );
  }

  // ── Garantie ──────────────────────────────────────────────────
  // Mention de garantie 1 an apposée sur chaque facture (preuve d'achat).

  static pw.Widget _warrantyBlock(InvoiceTheme theme) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: theme.primary, width: 0.6),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('GARANTIE 1 AN',
              style: pw.TextStyle(
                  fontSize: 8,
                  letterSpacing: 1.0,
                  color: theme.primary,
                  fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 3),
          pw.Text(
              'Vos articles sont garantis 1 an à compter de la date d\'achat '
              '(défauts de fabrication). Conservez cette facture comme preuve '
              'd\'achat pour bénéficier de la garantie.',
              style: const pw.TextStyle(
                  fontSize: 9, color: InvoiceTheme.textSecondary)),
        ],
      ),
    );
  }

  // ── Pied de page ──────────────────────────────────────────────

  static pw.Widget _footer({
    required ShopSummary  shop,
    required InvoiceTheme theme,
    required int pageNumber,
    required int pagesCount,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(height: 0.5, color: theme.primary),
        pw.SizedBox(height: 6),
        pw.Center(
          child: pw.Text('Merci pour votre confiance',
              style: pw.TextStyle(
                  fontSize: 9,
                  color: theme.primary,
                  fontWeight: pw.FontWeight.bold)),
        ),
        pw.SizedBox(height: 2),
        pw.Center(
          child: pw.Text(
              'Édité depuis Fortress POS',
              style: const pw.TextStyle(
                  fontSize: 8, color: InvoiceTheme.footerBrand)),
        ),
        if (pagesCount > 1) ...[
          pw.SizedBox(height: 2),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text('Page $pageNumber / $pagesCount',
                style: const pw.TextStyle(
                    fontSize: 8, color: InvoiceTheme.footerSubtle)),
          ),
        ],
      ],
    );
  }

  // ── Helpers ───────────────────────────────────────────────────

  /// Formatage monétaire selon le format de la boutique. On utilise le
  /// `CurrencyFormatter` qui suit déjà la devise active (XAF par
  /// défaut) — pas de symbole codé en dur dans la facture.
  static String _money(double v, ShopSummary shop) {
    return CurrencyFormatter.format(v);
  }
}
