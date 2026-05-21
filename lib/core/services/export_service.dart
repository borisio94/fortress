import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../shared/widgets/app_snack.dart';
import 'export_models.dart';

/// Service partagé d'export — CSV + PDF — cross-platform (web + mobile).
///
/// Pas de `path_provider` ni de `dart:io.File` : on construit les bytes
/// en mémoire (Uint8List) puis on passe par `XFile.fromData` →
/// `Share.shareXFiles`. Sur web, share_plus convertit en Blob et
/// déclenche un download (ou Web Share API si dispo) ; sur mobile, il
/// écrit en temp avant de présenter le sheet de partage natif. C'est ce
/// qui permet à l'export de fonctionner sur le build web Firebase
/// Hosting (le `path_provider` crash sinon).
class ExportService {
  const ExportService._();

  // ── API publique nouvelle (PR exports) ───────────────────────────

  /// CSV UTF-8 avec BOM (Excel/LibreOffice détectent l'encodage tout
  /// seuls). Échappement RFC 4180. Nom de fichier construit depuis
  /// `config.filenameBase(now)` + extension.
  static Future<void> exportToCsv(
    BuildContext context, {
    required ExportConfig config,
    required List<String> header,
    required List<List<Object?>> rows,
    String? emptyMessage,
  }) async {
    if (rows.isEmpty) {
      AppSnack.info(context,
          emptyMessage ?? 'Aucune donnée à exporter');
      return;
    }
    final csv = _buildCsv(header, rows);
    // UTF-8 BOM = 0xEF 0xBB 0xBF — sans ça, les accents sont cassés à
    // l'ouverture dans Excel Windows.
    final bytes = Uint8List.fromList(
        <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);
    final filename = '${config.filenameBase(DateTime.now())}.csv';
    try {
      await _share(
        bytes:           bytes,
        filenameWithExt: filename,
        mimeType:        'text/csv',
        subject:         filename,
      );
    } catch (e) {
      if (context.mounted) AppSnack.error(context, 'Erreur export : $e');
    }
  }

  /// PDF A4 paysage avec en-tête (titre type + scope + nom boutique +
  /// date) et pagination. Le table prend toute la largeur restante,
  /// les lignes débordent sur les pages suivantes via `pw.MultiPage`.
  static Future<void> exportToPdf(
    BuildContext context, {
    required ExportConfig config,
    required List<String> header,
    required List<List<Object?>> rows,
    String? emptyMessage,
  }) async {
    if (rows.isEmpty) {
      AppSnack.info(context,
          emptyMessage ?? 'Aucune donnée à exporter');
      return;
    }
    final bytes = await _buildPdf(
        config: config, header: header, rows: rows);
    final filename = '${config.filenameBase(DateTime.now())}.pdf';
    try {
      await _share(
        bytes:           bytes,
        filenameWithExt: filename,
        mimeType:        'application/pdf',
        subject:         filename,
      );
    } catch (e) {
      if (context.mounted) AppSnack.error(context, 'Erreur export : $e');
    }
  }

  // ── Compat legacy (Finances → losses_journal_widget) ─────────────
  //
  // Conserve l'API historique pour ne pas casser l'appel existant.
  // Migre quand le journal des pertes adoptera le nouveau scope selector.

  static Future<void> shareCsv(
    BuildContext context, {
    required String filename,
    required List<String> header,
    required List<List<Object?>> rows,
    String? subject,
    String? emptyMessage,
  }) async {
    if (rows.isEmpty) {
      AppSnack.info(context,
          emptyMessage ?? 'Aucune donnée à exporter');
      return;
    }
    final csv = _buildCsv(header, rows);
    final bytes = Uint8List.fromList(
        <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final fullName = '${filename}_$ts.csv';
    try {
      await _share(
        bytes:           bytes,
        filenameWithExt: fullName,
        mimeType:        'text/csv',
        subject:         subject ?? filename,
      );
    } catch (e) {
      if (context.mounted) AppSnack.error(context, 'Erreur export : $e');
    }
  }

  // ── Internals ───────────────────────────────────────────────────

  static String _buildCsv(
      List<String> header, List<List<Object?>> rows) {
    final buf = StringBuffer()..writeln(header.map(_csvCell).join(','));
    for (final row in rows) {
      buf.writeln(row.map(_csvCell).join(','));
    }
    return buf.toString();
  }

  /// Échappement RFC 4180 : guillemets doubles + quote si virgule,
  /// guillemet ou saut de ligne dans la valeur.
  static String _csvCell(Object? v) {
    if (v == null) return '';
    final s = v.toString();
    final needsQuotes =
        s.contains(',') || s.contains('"') || s.contains('\n');
    final escaped = s.replaceAll('"', '""');
    return needsQuotes ? '"$escaped"' : escaped;
  }

  static Future<Uint8List> _buildPdf({
    required ExportConfig config,
    required List<String> header,
    required List<List<Object?>> rows,
  }) async {
    final doc = pw.Document();
    final now = DateTime.now();
    final dateStr = '${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')}/${now.year}';
    const primary = PdfColor.fromInt(0xFF6C3FC7);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.fromLTRB(24, 28, 24, 28),
        header: (ctx) => _pdfHeader(config, dateStr),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 8),
          child: pw.Text(
            'Page ${ctx.pageNumber} / ${ctx.pagesCount}',
            style: const pw.TextStyle(
                fontSize: 9, color: PdfColors.grey600),
          ),
        ),
        build: (ctx) => [
          pw.TableHelper.fromTextArray(
            headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 9,
              color: PdfColors.white,
            ),
            headerDecoration: const pw.BoxDecoration(color: primary),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellAlignment: pw.Alignment.centerLeft,
            cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 6, vertical: 4),
            headers: header,
            data: rows
                .map((r) => r.map((c) => c?.toString() ?? '').toList())
                .toList(),
          ),
        ],
      ),
    );
    return doc.save();
  }

  static pw.Widget _pdfHeader(ExportConfig config, String dateStr) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 12),
      padding: const pw.EdgeInsets.only(bottom: 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(
            color: PdfColors.grey300, width: 0.5)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        mainAxisAlignment:  pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Fortress POS',
                  style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold, fontSize: 14)),
              pw.SizedBox(height: 2),
              pw.Text('${config.type.labelFr} — ${config.scopeLabel}',
                  style: const pw.TextStyle(fontSize: 10)),
              if (config.shopName != null && config.shopName!.isNotEmpty)
                pw.Text(config.shopName!,
                    style: const pw.TextStyle(
                        fontSize: 10, color: PdfColors.grey700)),
            ],
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('Exporté le $dateStr',
                  style: const pw.TextStyle(
                      fontSize: 9, color: PdfColors.grey700)),
            ],
          ),
        ],
      ),
    );
  }

  static Future<void> _share({
    required Uint8List bytes,
    required String filenameWithExt,
    required String mimeType,
    String? subject,
  }) async {
    // XFile.fromData : sur web, share_plus convertit en Blob et
    // déclenche un download (ou Web Share API si dispo). Sur mobile,
    // écrit en temp file via le platform channel — aucun appel à
    // path_provider requis depuis ce code.
    final xfile = XFile.fromData(
        bytes, name: filenameWithExt, mimeType: mimeType);
    await Share.shareXFiles([xfile], subject: subject ?? filenameWithExt);
  }
}
