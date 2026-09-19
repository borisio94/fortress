// Tests unitaires du DeliveryMessageBuilder — variables titre_livraison
// (dynamique selon reschedule) et reference (référence courte commande).
// Dart pur : pas de Hive ni Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';
import 'package:fortress/features/caisse/domain/services/delivery_message_builder.dart';
import 'package:fortress/features/parametres/domain/entities/delivery_template.dart';

DeliveryTemplate _tpl(String body) => DeliveryTemplate(
      id: 't1',
      shopId: 'shop1',
      name: 'Test',
      body: body,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

Sale _sale({String? id, String? rescheduleReason}) => Sale(
      id: id,
      shopId: 'shop1',
      paymentMethod: PaymentMethod.cash,
      createdAt: DateTime(2024, 1, 1, 10, 0),
      rescheduleReason: rescheduleReason,
      items: const [
        SaleItem(
          productId: 'p1',
          productName: 'Montre',
          unitPrice: 12000,
          quantity: 1,
        ),
      ],
    );

void main() {
  group('titre_livraison — statut dynamique', () {
    test('commande NON reprogrammée → NOUVELLE LIVRAISON', () {
      final msg = DeliveryMessageBuilder.build(
        template: _tpl('{{titre_livraison}}'),
        sale: _sale(),
        shopName: 'Ma Boutique',
      );
      expect(msg, 'NOUVELLE LIVRAISON');
    });

    test('commande reprogrammée → LIVRAISON RELANCÉE', () {
      final msg = DeliveryMessageBuilder.build(
        template: _tpl('{{titre_livraison}}'),
        sale: _sale(rescheduleReason: 'client absent'),
        shopName: 'Ma Boutique',
      );
      expect(msg, 'LIVRAISON RELANCÉE');
    });

    test('rescheduleReason vide/espaces → NOUVELLE LIVRAISON', () {
      final msg = DeliveryMessageBuilder.build(
        template: _tpl('{{titre_livraison}}'),
        sale: _sale(rescheduleReason: '   '),
        shopName: 'Ma Boutique',
      );
      expect(msg, 'NOUVELLE LIVRAISON');
    });
  });

  group('reference — référence courte', () {
    test('UUID → 6 derniers caractères majuscules', () {
      final msg = DeliveryMessageBuilder.build(
        template: _tpl('{{reference}}'),
        sale: _sale(id: 'abcdef12-3456-7890-aaaa-bbbbccc12345'),
        shopName: 'Ma Boutique',
      );
      expect(msg, 'C12345');
    });

    test('id null → fallback non vide (hash date)', () {
      final msg = DeliveryMessageBuilder.build(
        template: _tpl('{{reference}}'),
        sale: _sale(id: null),
        shopName: 'Ma Boutique',
      );
      expect(msg.trim(), isNotEmpty);
    });
  });

  test('drop-ligne : ligne titre + ligne reference rendues ensemble', () {
    final msg = DeliveryMessageBuilder.build(
      template: _tpl('🚚 {{titre_livraison}}\n🧾 N° {{reference}}'),
      sale: _sale(id: 'abcdef12-3456-7890-aaaa-bbbbccc12345'),
      shopName: 'Ma Boutique',
    );
    expect(msg, '🚚 NOUVELLE LIVRAISON\n🧾 N° C12345');
  });
}
