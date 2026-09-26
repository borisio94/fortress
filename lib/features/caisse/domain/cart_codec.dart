/// LE PANIER, ÉCRIT ET RELU SANS RIEN PERDRE.
///
/// Sur le web, un F5 vidait le panier : rien ne le persistait. `saveCart` et
/// `loadCart` existaient pourtant dans `sale_local_datasource` — sans un seul
/// appelant, ni l'un ni l'autre.
///
/// ET ILS NE SE PARLAIENT PAS. L'écriture posait dix clés
/// (`product_name`, `unit_price`, `quantity`…) ; la lecture en cherchait
/// quatre, sous d'autres noms (`name`, `price`, `qty`). Trois des quatre
/// n'existaient pas dans ce qui avait été écrit, et `e['name'] as String` sur
/// un `null` LÈVE une erreur de type. Ce n'était donc pas une fonctionnalité à
/// brancher : c'était une paire cassée qui n'avait jamais tourné.
///
/// Et même avec les bons noms, six champs manquaient à la relecture —
/// `customPrice` en tête, c'est-à-dire LE PRIX NÉGOCIÉ d'un plat, puis
/// `priceBuy`, dont dépend toute la marge. Un panier restauré aurait vendu au
/// prix catalogue un plat remisé, sans que personne ne voie l'écart.
///
/// D'où ce fichier : UN SEUL endroit qui décrit la correspondance, dans les
/// deux sens, et un test qui exige l'aller-retour à l'identique. Les clés sont
/// celles de `_itemToMap` — le panier écrit par l'une se relit par l'autre.
library;

import 'entities/sale_item.dart';

/// Une ligne de panier, vers sa forme stockée.
Map<String, dynamic> cartItemToMap(SaleItem i) => {
      'product_id': i.productId,
      'product_name': i.productName,
      'unit_price': i.unitPrice,
      'price_buy': i.priceBuy,
      'custom_price': i.customPrice,
      'quantity': i.quantity,
      'discount': i.discount,
      'image_url': i.imageUrl,
      'variant_name': i.variantName,
      'modifiers': i.modifiers,
    };

/// Une ligne stockée, vers sa ligne de panier.
///
/// TOLÉRANT SUR CE QUI MANQUE, JAMAIS SUR CE QUI COMPTE. Un panier écrit par
/// une version antérieure peut ne pas porter toutes les clés : les absentes
/// retombent sur le défaut de `SaleItem`. Mais `product_id` et `quantity` ne
/// se devinent pas — sans eux, la ligne ne désigne plus rien, et c'est le
/// `null` qui doit remonter, pas un article fantôme à zéro.
SaleItem? cartItemFromMap(Map<String, dynamic> m) {
  final id = m['product_id'];
  final qty = m['quantity'];
  if (id is! String || id.isEmpty || qty is! num) return null;
  return SaleItem(
    productId: id,
    productName: (m['product_name'] as String?) ?? '',
    variantName: m['variant_name'] as String?,
    imageUrl: m['image_url'] as String?,
    unitPrice: (m['unit_price'] as num?)?.toDouble() ?? 0,
    customPrice: (m['custom_price'] as num?)?.toDouble(),
    priceBuy: (m['price_buy'] as num?)?.toDouble() ?? 0,
    quantity: qty.toInt(),
    discount: (m['discount'] as num?)?.toDouble() ?? 0,
    modifiers: cartModifiersFromRaw(m['modifiers']),
  );
}

/// Normalise les options de menu d'une ligne.
///
/// La valeur arrive en `List<Map>` (Hive), en `List<dynamic>` (JSON), ou
/// absente. Même normalisation que `_modifiersFromRaw` côté commandes : une
/// ligne de panier et une ligne de vente décrivent la même chose.
List<Map<String, dynamic>> cartModifiersFromRaw(dynamic raw) {
  if (raw is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final e in raw) {
    if (e is Map) out.add(Map<String, dynamic>.from(e));
  }
  return out;
}

/// La clé Hive du panier d'UNE boutique.
///
/// La clé était `'cart'`, littérale et unique pour tout l'appareil. Un
/// propriétaire à deux boutiques aurait restauré le panier de l'autre —
/// et, en restauration, envoyé en cuisine des plats d'une autre carte.
String cartKeyFor(String shopId) => 'cart_$shopId';
