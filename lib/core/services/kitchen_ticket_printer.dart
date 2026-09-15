import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../features/caisse/domain/entities/sale.dart';
import '../../shared/widgets/app_snack.dart';
import '../../features/caisse/domain/entities/sale_item.dart';
import 'round_routing.dart';

export 'round_routing.dart' show RoundRouting, ServiceStation;

/// Bon de cuisine d'une TOURNÉE.
///
/// Format ticket 80 mm, sans aucun prix : la cuisine a besoin de savoir quoi
/// préparer et pour qui, pas ce que ça coûte. Les quantités sont en gros
/// caractères — un bon se lit à bout de bras, au-dessus d'un plan de travail.
///
/// Même chemin que [InvoicePrinter] : `Printing.layoutPdf`, éprouvé par la
/// caisse. Sur web, le navigateur ouvre sa boîte d'impression ; si la popup
/// est bloquée, `layoutPdf` échoue et on le signale au lieu d'échouer en
/// silence — un bon perdu, c'est un plat qui ne sort jamais.
class KitchenTicketPrinter {
  KitchenTicketPrinter._();

  /// Imprime UN BON PAR POSTE concerné par la tournée.
  ///
  /// [tableName] est le repère physique du service (« T5 »), [round] le numéro
  /// de tournée sur ce compte.
  ///
  /// Une tournée qui mêle un plat et une bière produit deux bons : la cuisine
  /// ne doit pas recevoir la boisson, et le bar ne doit pas recevoir le plat.
  /// C'est le cas exact de l'apéritif commandé pendant la préparation.
  static Future<void> print({
    required BuildContext context,
    required String shopId,
    required Sale order,
    String? tableName,
    int round = 1,
  }) async {
    try {
      final byStation = RoundRouting.split(shopId, order.items);
      for (final entry in byStation.entries) {
        final bytes = await build(
          order: order,
          items: entry.value,
          station: entry.key,
          tableName: tableName,
          round: round,
        );
        await Printing.layoutPdf(
          onLayout: (_) async => bytes,
          name: 'bon-${entry.key.name}-${tableName ?? 'emporter'}-$round',
        );
      }
    } catch (e) {
      if (context.mounted) {
        AppSnack.error(context,
            'Bon de cuisine non imprimé : $e — vérifiez que les fenêtres '
            'surgissantes sont autorisées.');
      }
    }
  }

  /// Génère le PDF du bon. Séparé de l'impression pour être testable et
  /// réutilisable (aperçu, réimpression).
  static Future<Uint8List> build({
    required Sale order,
    required List<SaleItem> items,
    required ServiceStation station,
    String? tableName,
    int round = 1,
  }) async {
    final doc = pw.Document();
    final at = order.createdAt;
    final heure = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';

    doc.addPage(
      pw.Page(
        // 80 mm de large, hauteur libre : un rouleau thermique ne coupe pas
        // à une page A4.
        pageFormat: const PdfPageFormat(
          80 * PdfPageFormat.mm,
          double.infinity,
          marginAll: 5 * PdfPageFormat.mm,
        ),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            // Le poste en tête : un bon posé sur un plan de travail doit dire
            // d'un coup d'œil s'il est bien au bon endroit.
            pw.Text(station.label,
                style: const pw.TextStyle(fontSize: 11)),
            pw.Text(tableName ?? 'À EMPORTER',
                style: pw.TextStyle(
                    fontSize: 22, fontWeight: pw.FontWeight.bold)),
            if ((order.tabLabel ?? '').isNotEmpty)
              pw.Text(order.tabLabel!, style: const pw.TextStyle(fontSize: 13)),
            pw.SizedBox(height: 2),
            pw.Text('Tournée $round · $heure'
                '${order.covers != null ? ' · ${order.covers} couverts' : ''}',
                style: const pw.TextStyle(fontSize: 11)),
            pw.Divider(thickness: 1.5),
            for (final item in items) ...[
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  // La quantité d'abord et en gros : c'est l'information que
                  // le cuisinier lit en premier.
                  pw.SizedBox(
                    width: 28,
                    child: pw.Text('${item.quantity}×',
                        style: pw.TextStyle(
                            fontSize: 17, fontWeight: pw.FontWeight.bold)),
                  ),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(item.productName,
                            style: pw.TextStyle(
                                fontSize: 15,
                                fontWeight: pw.FontWeight.bold)),
                        if (item.variantName != null &&
                            item.variantName!.isNotEmpty)
                          pw.Text(item.variantName!,
                              style: const pw.TextStyle(fontSize: 11)),
                        // Les modificateurs sont des CONSIGNES de préparation
                        // (« sans piment », « bien cuit ») : les omettre ferait
                        // ressortir un plat non conforme.
                        for (final m in item.modifiers)
                          pw.Text('• $m',
                              style: const pw.TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 6),
            ],
            if ((order.notes ?? '').isNotEmpty) ...[
              pw.Divider(thickness: 1),
              pw.Text('NOTE : ${order.notes}',
                  style: pw.TextStyle(
                      fontSize: 13, fontWeight: pw.FontWeight.bold)),
            ],
          ],
        ),
      ),
    );
    return doc.save();
  }
}
