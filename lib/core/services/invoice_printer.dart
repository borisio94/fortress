import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../features/caisse/domain/entities/sale.dart';
import '../../features/caisse/domain/usecases/order_receipt_usecase.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';
import '../../shared/widgets/app_snack.dart';
import 'invoice_service.dart';

/// Impression / partage d'une facture, avec repli.
///
/// Extrait du chemin déjà éprouvé de la caisse : `Printing.layoutPdf` en
/// premier (imprimante ou aperçu système), puis partage des bytes via
/// `share_plus` quand l'impression n'est pas disponible — c'est le cas sur
/// web quand la popup est bloquée, situation courante ici puisque l'app est
/// utilisée en web.
///
/// Placé dans `core/services` (couche partagée) plutôt que dupliqué dans le
/// module restaurant : c'est de la plomberie, pas de l'UI sectorielle.
class InvoicePrinter {
  InvoicePrinter._();

  /// Génère la facture de [sale] et propose impression puis partage.
  ///
  /// Ne lève jamais : toute erreur est remontée par un snack. [shop] peut
  /// être null (cache Hive froid) → repli sur le template historique.
  static Future<void> printOrShare({
    required BuildContext context,
    required Sale sale,
    required ShopSummary? shop,
  }) async {
    final label = sale.id ?? 'commande';
    try {
      await Printing.layoutPdf(
        name: 'Facture-$label',
        onLayout: (_) => shop != null
            ? InvoiceService.generatePdf(sale: sale, shop: shop)
            : OrderReceiptUseCase.generatePdf(sale, shop: shop),
      );
      return;
    } catch (_) {
      // Impression indisponible → on bascule sur le partage de fichier.
    }
    if (!context.mounted) return;
    try {
      final bytes = shop != null
          ? await InvoiceService.generatePdf(sale: sale, shop: shop)
          : await OrderReceiptUseCase.generatePdf(sale, shop: shop);
      if (bytes.isEmpty) {
        if (context.mounted) {
          AppSnack.error(context, 'Erreur génération facture');
        }
        return;
      }
      final filename = 'facture_$label.pdf';
      await Share.shareXFiles(
        [XFile.fromData(bytes, name: filename, mimeType: 'application/pdf')],
        subject: filename,
      );
    } catch (e) {
      if (context.mounted) AppSnack.error(context, 'Erreur facture : $e');
    }
  }
}
