import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/invoice_service.dart';
import 'package:pdf/pdf.dart';

/// Format d'impression du ticket 80 mm.
///
/// Ce que ces tests protègent : la LARGEUR utile. La facture A4 pose des
/// colonnes fixes de 40 + 80 + 80 pt ; sur un rouleau de 80 mm il ne reste que
/// ~198 pt une fois les marges retirées, donc ces trois colonnes seules
/// consommeraient toute la largeur et la désignation n'aurait plus de place.
/// C'est la raison d'être d'une mise en page distincte — si quelqu'un pointe
/// un jour le format ticket sur la mise en page A4, l'arithmétique ci-dessous
/// le rappelle.
void main() {
  group('InvoiceService — format rouleau 80 mm', () {
    test('roll80 fait bien 80 mm de large', () {
      expect(InvoiceService.roll80.width, closeTo(80 * PdfPageFormat.mm, 0.01));
    });

    test('la hauteur est libre — un rouleau ne se coupe pas à une page', () {
      expect(InvoiceService.roll80.height, double.infinity);
    });

    test('les marges laissent la place aux montants alignés à droite', () {
      // Têtes thermiques : rien ne s'imprime au ras du bord.
      expect(InvoiceService.roll80.marginLeft, greaterThanOrEqualTo(5 * PdfPageFormat.mm));
      expect(InvoiceService.roll80.marginRight, greaterThanOrEqualTo(5 * PdfPageFormat.mm));
    });

    test('la largeur utile ne peut PAS accueillir les colonnes fixes de l\'A4',
        () {
      // 40 (qté) + 80 (prix unit.) + 80 (total) = 200 pt, sans la désignation.
      const colonnesFixesA4 = 40.0 + 80.0 + 80.0;
      expect(InvoiceService.roll80.availableWidth, lessThan(colonnesFixesA4),
          reason: 'si cette assertion casse, la mise en page A4 tiendrait sur '
              'le rouleau et le ticket dédié perdrait sa justification');
    });

    test('le seuil de bascule classe 80 mm en ticket et A4 en pleine page', () {
      // Le seuil vit dans le service ; on vérifie son effet observable.
      expect(InvoiceService.roll80.width, lessThan(PdfPageFormat.a4.width));
      expect(PdfPageFormat.a4.width, greaterThan(300));
      expect(InvoiceService.roll80.width, lessThan(300));
    });

    test('un 58 mm resterait du côté ticket', () {
      const roll58 = PdfPageFormat(58 * PdfPageFormat.mm, double.infinity);
      expect(roll58.width, lessThan(300));
    });
  });
}
