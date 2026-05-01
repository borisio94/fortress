import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../shared/widgets/app_snack.dart';

/// Service partagé pour l'export de fichiers (CSV, …) via le plugin de
/// partage natif. Utilisé par Finances pour le journal des pertes et,
/// à terme, tout autre export tabulaire.
class ExportService {
  const ExportService._();

  /// Sérialise [rows] en CSV puis propose le partage natif.
  ///
  /// * [filename] — nom de fichier sans extension (un timestamp y est ajouté).
  /// * [header]   — première ligne (noms de colonnes).
  /// * [rows]     — lignes de données. Chaque valeur est convertie en string
  ///   via `toString()` puis échappée selon RFC 4180.
  /// * [subject]  — sujet/titre pour la feuille de partage (email, etc.).
  ///
  /// Affiche un snack info si [rows] est vide.
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

    final buf = StringBuffer()..writeln(header.map(_csvCell).join(','));
    for (final row in rows) {
      buf.writeln(row.map(_csvCell).join(','));
    }

    try {
      final dir = await getTemporaryDirectory();
      final ts  = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/${filename}_$ts.csv');
      await file.writeAsString(buf.toString());
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv')],
        subject: subject ?? filename,
      );
    } catch (e) {
      if (context.mounted) {
        AppSnack.error(context, 'Erreur export : $e');
      }
    }
  }

  /// Échappement RFC 4180 : guillemets doubles + quote si virgule, guillemet
  /// ou saut de ligne dans la valeur.
  static String _csvCell(Object? v) {
    if (v == null) return '';
    final s = v.toString();
    final needsQuotes =
        s.contains(',') || s.contains('"') || s.contains('\n');
    final escaped = s.replaceAll('"', '""');
    return needsQuotes ? '"$escaped"' : escaped;
  }
}
