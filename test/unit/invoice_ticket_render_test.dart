import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/invoice_service.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';
import 'package:fortress/features/shop_selector/domain/entities/shop_summary.dart';
import 'package:pdf/pdf.dart';

/// RENDU du ticket 80 mm — le test qui compte.
///
/// `generatePdf` attrape toute exception de composition et renvoie un PDF
/// VIDE plutôt que de planter. C'est un bon réflexe en production — le
/// service ne s'arrête pas parce qu'une facture ne s'imprime pas — mais cela
/// rend l'échec silencieux : une mise en page cassée sort un fichier de 0
/// octet, et personne ne le voit avant que le client ne réclame son reçu.
///
/// La hauteur infinie du rouleau est précisément le genre de contrainte qui
/// fait lever certaines combinaisons de widgets PDF. D'où ce test : on ne
/// vérifie pas l'esthétique, on vérifie qu'il sort des octets.
void main() {
  ShopSummary shop() => const ShopSummary(
        id: 'shop_1',
        name: 'My Resto',
        currency: 'XAF',
        country: 'Cameroun',
        sector: 'restaurant',
        phone: '+237600000000',
        email: 'resto@example.com',
      );

  Sale sale(List<SaleItem> items) => Sale(
        id: 'order_1785711293828',
        shopId: 'shop_1',
        items: items,
        paymentMethod: PaymentMethod.cash,
        status: SaleStatus.completed,
        createdAt: DateTime.utc(2026, 8, 3, 12, 30),
        clientName: 'Awa',
        clientPhone: '+237611111111',
      );

  SaleItem item(String name, int qty, double price) => SaleItem(
        productId: 'p_$name',
        productName: name,
        unitPrice: price,
        priceBuy: 0,
        quantity: qty,
      );

  test('le ticket 80 mm produit un PDF non vide', () async {
    final bytes = await InvoiceService.generatePdf(
      sale: sale([
        item('Riz sauce tomate viande', 2, 2000),
        item('Jus naturel', 1, 500),
      ]),
      shop: shop(),
    );
    expect(bytes, isNotEmpty,
        reason: 'un PDF vide = la composition a levé et generatePdf l\'a '
            'silencieusement avalée');
    // En-tête de fichier PDF : garantit que ce sont bien des octets de PDF et
    // pas un tampon quelconque.
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('un nom de plat très long ne casse pas la composition', () async {
    // Sur 198 pt utiles, un libellé à rallonge est le cas qui déborde.
    final bytes = await InvoiceService.generatePdf(
      sale: sale([
        item('Riz sauté aux crevettes, sauce d\'arachide maison et '
            'plantain mûr accompagné de légumes de saison', 1, 4500),
      ]),
      shop: shop(),
    );
    expect(bytes, isNotEmpty);
  });

  test('une commande sans article sort quand même un ticket', () async {
    final bytes = await InvoiceService.generatePdf(
      sale: sale(const []),
      shop: shop(),
    );
    expect(bytes, isNotEmpty);
  });

  test('la facture A4 reste générable — la bascule n\'a rien cassé', () async {
    final bytes = await InvoiceService.generatePdf(
      sale: sale([item('Ndolé', 1, 2000)]),
      shop: shop(),
      format: PdfPageFormat.a4,
    );
    expect(bytes, isNotEmpty);
  });
}
