// LE TICKET DU RESTAURANT, DESSINÉ (26/09/2026).
//
// On vérifie ce qui ne se voit qu'à l'impression : qu'il sort des octets aux
// deux largeurs de rouleau, qu'AUCUN caractère n'échappe à la police (le « − »
// de la remise ne s'imprimait pas en Helvetica), et que l'e-commerce garde
// son ticket.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/invoice_service.dart';
import 'package:fortress/core/services/resto_ticket_pdf.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';
import 'package:fortress/features/shop_selector/domain/entities/shop_summary.dart';
import 'package:pdf/pdf.dart';

ShopSummary shop(String sector) => ShopSummary(
      id: 's',
      name: 'Reobotffod',
      currency: 'XAF',
      country: 'Cameroun',
      sector: sector,
      phone: '6 99 00 00 00',
    );

final sale = Sale(
  id: 'order_1785711293828',
  shopId: 's',
  items: const [
    SaleItem(
        productId: 'a',
        productName: 'Riz sauté aux crevettes, sauce d’arachide maison et '
            'plantain mûr',
        unitPrice: 4500,
        priceBuy: 0,
        quantity: 1),
    SaleItem(
        productId: 'b',
        productName: 'Jus naturel',
        unitPrice: 500,
        priceBuy: 0,
        quantity: 2),
  ],
  paymentMethod: PaymentMethod.cash,
  status: SaleStatus.completed,
  createdAt: DateTime(2026, 9, 26, 14, 52),
  orderType: 'dine_in',
  covers: 2,
  discountAmount: 500,
  discountReason: 'fidélité',
  amountPaid: 1234567,
);

/// Le 58 mm de l'autre chantier (`InvoiceService.roll58`), recopié : ce lot
/// ne dépend pas de fichiers non commités.
const roll58 = PdfPageFormat(58 * PdfPageFormat.mm, double.infinity,
    marginAll: 4 * PdfPageFormat.mm);

/// Compose en capturant les avertissements du paquet `pdf`.
Future<(Uint8List, List<String>)> compose(
    ShopSummary s, PdfPageFormat format) async {
  final logs = <String>[];
  final bytes = await runZoned(
    () => InvoiceService.generatePdf(sale: sale, shop: s, format: format),
    zoneSpecification:
        ZoneSpecification(print: (_, __, ___, line) => logs.add(line)),
  );
  return (bytes, logs);
}

void main() {
  for (final (name, format) in [
    ('80 mm', InvoiceService.roll80),
    ('58 mm', roll58),
  ]) {
    test('$name : un PDF, en Inter, sans caractère hors police', () async {
      final (bytes, logs) = await compose(shop('restaurant'), format);
      expect(bytes, isNotEmpty, reason: 'composition avalée par generatePdf');
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
      expect(logs.where((l) => l.contains('Unable to find a font')), isEmpty,
          reason: logs.join('\n'));
      expect(latin1.decode(bytes, allowInvalid: true), contains('Inter'));
    });
  }

  test('le montant : l’espace fine U+202F devient U+00A0, les deux polices '
      'la dessinent', () {
    final m = RestoTicketPdf.money(3500);
    expect(m.contains(' '), isFalse);
    expect(m.replaceAll(' ', ' '), '3 500 FCFA');
  });

  test('l’e-commerce garde SON ticket : Helvetica, pas Inter', () async {
    final (bytes, _) = await compose(shop('ecommerce'), InvoiceService.roll80);
    expect(bytes, isNotEmpty);
    final raw = latin1.decode(bytes, allowInvalid: true);
    expect(raw, contains('Helvetica'));
    expect(raw, isNot(contains('Inter')));
  });
}
