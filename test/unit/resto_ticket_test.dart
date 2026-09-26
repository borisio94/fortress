// LE TICKET DE CAISSE DU RESTAURANT (26/09/2026) — ce qu'il dit.
//
// La règle vérifiée ici avant toute autre : une ligne dont la donnée manque
// N'EXISTE PAS. Le dessin est vérifié à part (resto_ticket_pdf_test.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';
import 'package:fortress/features/restaurant/domain/entities/payment.dart';
import 'package:fortress/features/restaurant/domain/resto_ticket.dart';
import 'package:fortress/features/shop_selector/domain/entities/shop_summary.dart';

String money(double v) => '${v.round()} F';

const shop = ShopSummary(
  id: 's',
  name: 'Reobotffod',
  currency: 'XAF',
  country: 'Cameroun',
  sector: 'restaurant',
  phone: '6 99 00 00 00',
);

Sale sale({
  String id = 'order_1785711293828',
  String orderType = 'dine_in',
  int? covers = 2,
  String? tabLabel,
  double discount = 0,
  String? reason,
  double amountPaid = 0,
  PaymentMethod method = PaymentMethod.cash,
}) =>
    Sale(
      id: id,
      shopId: 's',
      items: const [
        SaleItem(
            productId: 'a',
            productName: 'Poulet DG',
            unitPrice: 2500,
            priceBuy: 0,
            quantity: 1),
        SaleItem(
            productId: 'b',
            productName: 'Jus naturel',
            unitPrice: 500,
            priceBuy: 0,
            quantity: 2),
      ],
      paymentMethod: method,
      status: SaleStatus.completed,
      createdAt: DateTime(2026, 9, 26, 14, 52),
      orderType: orderType,
      covers: covers,
      tabLabel: tabLabel,
      discountAmount: discount,
      discountReason: reason,
      amountPaid: amountPaid,
    );

Payment pay(String method, int amount, {int change = 0}) => Payment(
      id: 'p$method$amount',
      shopId: 's',
      orderId: 'order_1785711293828',
      createdAt: DateTime(2026, 9, 26, 14, 53),
      method: method,
      amount: amount,
      changeGiven: change,
    );

RestoTicket build(Sale s,
        {String? table, String? server, List<Payment> payments = const []}) =>
    RestoTicket.from(
      sale: s,
      shop: shop,
      facts: RestoTicketFacts(
        tableName: table,
        serverName: server,
        payments: payments,
        printedAt: DateTime(2026, 9, 26, 14, 53),
      ),
      money: money,
    );

List<String> identTexts(RestoTicket t) =>
    [for (final p in t.ident) ...[p.left, p.right]].whereType<String>().toList();

void main() {
  group('en-tête', () {
    test('nom en capitales, « Restaurant » seul, téléphone', () {
      final t = build(sale());
      expect(t.shopName, 'REOBOTFFOD');
      expect(t.activity, 'Restaurant',
          reason: 'la ville n’existe pas, le pays n’en est pas une');
      expect(t.phone, 'Tél. 6 99 00 00 00');
    });

    test('sans téléphone, pas de ligne', () {
      final t = RestoTicket.from(
        sale: sale(),
        shop: const ShopSummary(
            id: 's',
            name: 'X',
            currency: 'XAF',
            country: 'Cameroun',
            sector: 'restaurant'),
        facts: RestoTicketFacts(printedAt: DateTime(2026)),
        money: money,
      );
      expect(t.phone, isNull);
    });
  });

  group('identification', () {
    test('complète : réf., table, date, heure, couverts, serveur, canal', () {
      final t = build(sale(tabLabel: 'M. Ali'), table: 'Table 2', server: 'Awa');
      expect(t.ident.map((p) => [p.left, p.right]).toList(), [
        ['Réf. 293828', 'Table 2 · M. Ali'],
        ['26/09/2026 · 14:52', '2 couverts'],
        ['Servi par Awa', 'Sur place'],
      ]);
    });

    test('la référence : les 6 DERNIERS caractères, jamais « ORDER_17 »', () {
      expect(RestoTicket.shortRef('order_1785711293828'), '293828');
      expect(RestoTicket.shortRef('3f9a1c2e-0000-4000-8000-00000000abcd'),
          '00ABCD');
      expect(RestoTicket.shortRef('abc'), 'ABC');
      expect(RestoTicket.shortRef(null), isNull);
      expect(identTexts(build(sale())).join(' '), isNot(contains('ORDER')));
    });

    test('sans serveur, sans table, sans couverts : les données disparaissent, '
        'pas les lignes qui en ont d’autres', () {
      final t = build(sale(covers: null, orderType: 'takeaway'));
      expect(t.ident.map((p) => [p.left, p.right]).toList(), [
        ['Réf. 293828', null],
        ['26/09/2026 · 14:52', null],
        [null, 'À emporter'],
      ]);
      final all = identTexts(t).join(' ');
      expect(all, isNot(contains('Servi par')));
      expect(all, isNot(contains('couvert')));
      expect(all, isNot(contains('Table')));
    });

    test('un couvert : singulier', () {
      expect(identTexts(build(sale(covers: 1))), contains('1 couvert'));
    });

    test('les canaux, et un canal inconnu ne s’écrit pas', () {
      expect(RestoTicket.channelLabel('dine_in'), 'Sur place');
      expect(RestoTicket.channelLabel('takeaway'), 'À emporter');
      expect(RestoTicket.channelLabel('delivery'), 'Livraison');
      expect(RestoTicket.channelLabel('drive'), isNull);
    });
  });

  group('lignes et totaux', () {
    test('nom, « qté × prix » dessous, total à droite', () {
      final t = build(sale());
      expect(t.items.map((i) => [i.name, i.detail, i.total]).toList(), [
        ['Poulet DG', '1 × 2500 F', '2500 F'],
        ['Jus naturel', '2 × 500 F', '1000 F'],
      ]);
    });

    test('remise avec son motif, signe moins U+2212', () {
      final t = build(sale(discount: 500, reason: 'fidélité'));
      final remise = t.adjustments.firstWhere((a) => a.label.startsWith('Remise'));
      expect(remise.label, 'Remise · fidélité');
      expect(remise.value, '− 500 F');
      expect(t.total, '3000 F');
    });

    test('sans remise, pas de ligne ; sans motif, « Remise » seul', () {
      expect(build(sale()).adjustments.map((a) => a.label), ['Sous-total']);
      expect(build(sale(discount: 500)).adjustments.last.label, 'Remise');
    });
  });

  group('règlement', () {
    test('espèces : ce que le client a TENDU, puis le rendu', () {
      final t = build(sale(discount: 500), payments: [pay('cash', 3000, change: 2000)]);
      expect(t.settlement.map((a) => [a.label, a.value]).toList(), [
        ['Espèces', '5000 F'],
        ['Rendu', '2000 F'],
      ]);
    });

    test('plusieurs règlements, listés ; pas de rendu hors espèces', () {
      final t = build(sale(), payments: [
        pay('mtn_money', 2000),
        pay('cash', 1500, change: 500),
      ]);
      expect(t.settlement.map((a) => [a.label, a.value]).toList(), [
        ['MTN Money', '2000 F'],
        ['Espèces', '2000 F'],
        ['Rendu', '500 F'],
      ]);
    });

    test('sans règlement enregistré : le montant encaissé et son mode', () {
      final t = build(sale(amountPaid: 3500, method: PaymentMethod.card));
      expect(t.settlement.map((a) => [a.label, a.value]).toList(), [
        ['Carte', '3500 F'],
      ]);
    });

    test('rien d’encaissé : un reste dû seul, jamais un « Payé 0 »', () {
      final t = build(sale());
      expect(t.settlement.map((a) => a.label), ['Reste dû']);
    });

    test('la commande d’AVANT l’encaissement (à emporter) : les règlements '
        'enregistrés font foi, pas de faux « Reste dû »', () {
      // `amountPaid` vaut encore 0 : c'est l'objet que `restaurant_checkout`
      // imprime. Payée en entier par ses règlements.
      final t = build(sale(), payments: [pay('cash', 3500)]);
      expect(t.settlement.map((a) => a.label), ['Espèces']);
    });

    test('réglée en partie : le reste dû, calculé sur les règlements', () {
      final t = build(sale(), payments: [pay('orange_money', 2000)]);
      expect(t.settlement.map((a) => [a.label, a.value]).toList(), [
        ['Orange Money', '2000 F'],
        ['Reste dû', '1500 F'],
      ]);
    });
  });

  test('pied : merci, puis l’heure d’édition — PAS de NIU (le champ n’existe '
      'pas)', () {
    final t = build(sale());
    expect(t.footer, [
      'Merci de votre visite',
      'Édité depuis Fortress POS · 26/09 14:53',
    ]);
    expect(t.footer.join(' '), isNot(contains('NIU')));
  });
}
