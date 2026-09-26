import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../features/caisse/domain/entities/sale.dart';
import '../../features/restaurant/domain/entities/payment.dart';
import '../../features/restaurant/domain/order_author.dart';
import '../../features/restaurant/domain/resto_ticket.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';
import '../database/app_database.dart';
import '../utils/currency_formatter.dart';
import 'payment_service.dart';
import 'restaurant_table_service.dart';

/// LE TICKET DE CAISSE DU RESTAURANT, dessiné (26/09/2026).
///
/// Ce qu'il dit vit dans `RestoTicket` (domaine, testable sans PDF) ; ici, le
/// seul dessin. Trois règles, parce qu'il s'imprime sur papier THERMIQUE :
///
///   * TOUT EN NOIR. Pas de couleur de marque, pas de gris : sur une tête
///     thermique, une teinte sort tramée et devient illisible. La hiérarchie
///     passe par la taille et la graisse ;
///   * PAS DE LOGO, pour la même raison ;
///   * la police INTER embarquée (400 et 700, ~136 Ko). La police PDF par
///     défaut, Helvetica, n'a pas le signe moins « − » (U+2212) : la remise
///     s'imprimait sans son signe.
///
/// Largeurs : 80 mm (`InvoiceService.roll80`) et 58 mm. Sous
/// [_narrowBelow], le total et le nom descendent d'un cran — à 14 pt,
/// « 1 234 567 FCFA » ne tient plus à côté de « TOTAL » sur 141,7 pt utiles.
class RestoTicketPdf {
  const RestoTicketPdf._();

  /// Entre 58 mm (164 pt) et 80 mm (227 pt).
  static const double _narrowBelow = 190;

  static pw.ThemeData? _theme;

  /// Inter, chargée une fois. `null` si les fichiers manquent : le ticket
  /// sort alors en Helvetica plutôt que de ne pas sortir.
  static Future<pw.ThemeData?> _loadTheme() async {
    if (_theme != null) return _theme;
    try {
      final regular = await rootBundle.load('assets/fonts/Inter-400.ttf');
      final bold = await rootBundle.load('assets/fonts/Inter-700.ttf');
      return _theme = pw.ThemeData.withFont(
        base: pw.Font.ttf(regular),
        bold: pw.Font.ttf(bold),
      );
    } catch (e) {
      debugPrint('[RestoTicketPdf] police Inter indisponible : $e');
      return null;
    }
  }

  /// Ce que le ticket lit hors de la vente, dans les caches LOCAUX — lecture
  /// synchrone, hors ligne, comme l'addition. Chaque source échoue seule :
  /// une table introuvable n'empêche pas le serveur de s'afficher.
  static RestoTicketFacts resolveFacts(Sale sale, {DateTime? now}) {
    String? tableName;
    String? server;
    var payments = const <Payment>[];
    try {
      final id = sale.tableId;
      if (id != null && id.isNotEmpty) {
        tableName = RestaurantTableService.tableById(id)?.name;
      }
    } catch (_) {}
    try {
      final member =
          AppDatabase.cachedMember(sale.shopId, sale.createdByUserId ?? '');
      final profile = member?['profiles'];
      server = serverLabelFor(
        userId: sale.createdByUserId,
        name: profile is Map ? profile['name'] as String? : null,
        email: profile is Map ? profile['email'] as String? : null,
      );
    } catch (_) {}
    try {
      final id = sale.id;
      if (id != null && id.isNotEmpty) {
        payments = PaymentService.forOrder(sale.shopId, id);
      }
    } catch (_) {}
    return RestoTicketFacts(
      tableName: tableName,
      serverName: server,
      payments: payments,
      printedAt: now ?? DateTime.now(),
    );
  }

  /// Le montant tel que `CurrencyFormatter` l'écrit, à UN caractère près :
  /// son espace fine insécable (U+202F) n'existe ni dans Helvetica ni dans
  /// Inter. Elle devient l'espace insécable ordinaire (U+00A0), que les deux
  /// polices dessinent — le montant ne se coupe toujours pas.
  static String money(double v) =>
      CurrencyFormatter.format(v).replaceAll(' ', ' ');

  static Future<pw.Page> page({
    required Sale sale,
    required ShopSummary shop,
    required PdfPageFormat format,
    RestoTicketFacts? facts,
  }) async {
    final t = RestoTicket.from(
      sale: sale,
      shop: shop,
      facts: facts ?? resolveFacts(sale),
      money: money,
    );
    final narrow = format.width < _narrowBelow;
    final theme = await _loadTheme();
    return pw.Page(
      pageFormat: format,
      theme: theme,
      build: (_) => _body(t, narrow: narrow),
    );
  }

  static const _ink = PdfColors.black;

  static pw.TextStyle _s(double size, {bool bold = false}) => pw.TextStyle(
        fontSize: size,
        color: _ink,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      );

  static pw.Widget _body(RestoTicket t, {required bool narrow}) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        // ── En-tête ────────────────────────────────────────────────
        pw.Text(t.shopName,
            textAlign: pw.TextAlign.center,
            style: _s(narrow ? 11 : 13, bold: true)),
        pw.SizedBox(height: 2),
        pw.Text(t.activity,
            textAlign: pw.TextAlign.center, style: _s(7.5)),
        if (t.phone != null)
          pw.Text(t.phone!, textAlign: pw.TextAlign.center, style: _s(7.5)),
        pw.SizedBox(height: 6),

        // ── Identification : filet plein dessus, pointillé dessous ──
        _solid(),
        pw.SizedBox(height: 4),
        for (final p in t.ident) _pair(p),
        pw.SizedBox(height: 4),
        _dotted(),

        // ── Articles ───────────────────────────────────────────────
        for (final i in t.items) _item(i),
        _dotted(),
        pw.SizedBox(height: 2),

        // ── Totaux ─────────────────────────────────────────────────
        for (final a in t.adjustments) _amount(a, size: 8),
        pw.SizedBox(height: 3),
        _solid(width: 1.2),
        pw.SizedBox(height: 3),
        _amount(TicketAmount('TOTAL', t.total),
            size: narrow ? 12 : 14, bold: true),

        // ── Règlement, dans son propre bloc ───────────────────────
        if (t.settlement.isNotEmpty) ...[
          pw.SizedBox(height: 6),
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            decoration: pw.BoxDecoration(
                border: pw.Border.all(color: _ink, width: 0.8)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                for (final a in t.settlement)
                  _amount(a, size: 9, bold: a.label != 'Rendu'),
              ],
            ),
          ),
        ],

        if (t.note != null) ...[
          pw.SizedBox(height: 6),
          pw.Text(t.note!, style: _s(8)),
        ],

        // ── Pied ───────────────────────────────────────────────────
        pw.SizedBox(height: 10),
        for (var k = 0; k < t.footer.length; k++)
          pw.Text(t.footer[k],
              textAlign: pw.TextAlign.center,
              style: _s(k == 0 ? 8.5 : 7, bold: k == 0)),
        // La lame de coupe tombe quelques millimètres sous la dernière ligne.
        pw.SizedBox(height: 14),
      ],
    );
  }

  static pw.Widget _solid({double width = 1}) =>
      pw.Container(height: width, color: _ink);

  static pw.Widget _dotted() => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Container(
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              bottom: pw.BorderSide(
                  color: _ink, width: 0.6, style: pw.BorderStyle.dotted),
            ),
          ),
        ),
      );

  /// Gauche qui se replie, droite qui garde sa largeur.
  static pw.Widget _pair(TicketPair p) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(child: pw.Text(p.left ?? '', style: _s(8))),
            if (p.right != null) ...[
              pw.SizedBox(width: 6),
              pw.Text(p.right!, style: _s(8)),
            ],
          ],
        ),
      );

  static pw.Widget _item(TicketItem i) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(child: pw.Text(i.name, style: _s(9, bold: true))),
                pw.SizedBox(width: 6),
                pw.Text(i.total, style: _s(9, bold: true)),
              ],
            ),
            pw.SizedBox(height: 1),
            pw.Text(i.detail, style: _s(7.5)),
          ],
        ),
      );

  static pw.Widget _amount(TicketAmount a,
          {required double size, bool bold = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(child: pw.Text(a.label, style: _s(size, bold: bold))),
            pw.SizedBox(width: 6),
            pw.Text(a.value, style: _s(size, bold: bold)),
          ],
        ),
      );
}
