import 'package:flutter/foundation.dart';

import '../../../features/caisse/domain/entities/sale.dart';
import '../../../features/caisse/domain/entities/sale_item.dart';

/// Reconstruit un `Sale` complet depuis la Map Hive `orders_box` pour les
/// besoins de l'UI alertes (modal + banner).
///
/// Pourquoi pas `SaleModel.fromMap(map).toEntity()` ?
///   * `SaleModel` a été pensé pour le pipeline caisse (création/encaissement)
///     et omet volontairement plusieurs champs côté commande e-commerce :
///     `client_name`, `scheduled_at`, `delivery_address`, `delivery_city`,
///     `delivery_mode`, `notes`, `tax_rate`, `fees`.
///   * Toucher `SaleModel` pour les rajouter risque de casser les call sites
///     existants (encaissement, exports, factures). On préfère un helper
///     dédié à la couche présentation alertes.
///
/// Tolérant aux champs absents : silencieux + valeurs par défaut. Retourne
/// `null` si la map est trop incomplète pour produire un `Sale` valide.
Sale? hydrateOrderForAlert(Map<String, dynamic> m) {
  try {
    final id = m['id'] as String?;
    final shopId = m['shop_id'] as String? ?? '';
    if (id == null || shopId.isEmpty) return null;

    final itemsRaw = m['items'] as List? ?? const [];
    final items = itemsRaw.map((i) {
      final im = Map<String, dynamic>.from(i as Map);
      return SaleItem(
        productId:   im['product_id']    as String? ?? '',
        productName: im['product_name']  as String? ?? '',
        variantName: im['variant_name']  as String?,
        unitPrice:   (im['unit_price']   as num?)?.toDouble() ?? 0,
        quantity:    (im['quantity']     as num?)?.toInt() ?? 0,
        customPrice: (im['custom_price'] as num?)?.toDouble(),
        discount:    (im['discount']     as num?)?.toDouble() ?? 0,
        imageUrl:    im['image_url']     as String?,
      );
    }).toList();

    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v);
      return null;
    }

    return Sale(
      id:                  id,
      shopId:              shopId,
      items:               items,
      discountAmount:      (m['discount_amount'] as num?)?.toDouble() ?? 0,
      taxRate:             (m['tax_rate']        as num?)?.toDouble() ?? 0,
      fees:                (m['fees'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      paymentMethod:       PaymentMethod.values.firstWhere(
          (p) => p.name == (m['payment_method'] as String?),
          orElse: () => PaymentMethod.cash),
      status:              SaleStatus.values.firstWhere(
          (s) => s.name == (m['status'] as String?),
          orElse: () => SaleStatus.scheduled),
      clientId:            m['client_id']    as String?,
      clientName:          m['client_name']  as String?,
      clientPhone:         m['client_phone'] as String?,
      notes:               m['notes']        as String?,
      createdAt:           parseDate(m['created_at']) ?? DateTime.now(),
      scheduledAt:         parseDate(m['scheduled_at']),
      syncedToCloud:       m['synced_to_cloud'] as bool? ?? true,
      deliveryMode:        DeliveryModeX.fromKey(
          m['delivery_mode'] as String?),
      deliveryLocationId:  m['delivery_location_id'] as String?,
      deliveryPersonName:  m['delivery_person_name'] as String?,
      deliveryAddress:     m['delivery_address']     as String?,
      deliveryCity:        m['delivery_city']        as String?,
    );
  } catch (e) {
    debugPrint('[hydrateOrderForAlert] error: $e');
    return null;
  }
}
