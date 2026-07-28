import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../features/caisse/data/repositories/sale_local_datasource.dart';
import '../../features/caisse/domain/entities/sale.dart';
import '../../features/caisse/domain/entities/sale_item.dart';
import '../../features/restaurant/domain/entities/loss.dart';
import '../storage/local_storage_service.dart';
import 'loss_service.dart';
import 'recipe_service.dart';
import 'restaurant_order_service.dart';

/// Incidents de service — le chaînon qui manquait entre la salle et le module
/// Pertes (Lot E).
///
/// Le parcours nominal (commander → envoyer → servir → encaisser) ne dit rien
/// de ce qui arrive quand ça se passe mal. Or c'est là que l'argent se perd, et
/// sans trace le bénéfice affiché est faux.
///
/// LE MONTANT DÉPEND DE L'INCIDENT — c'est le point à ne pas se tromper :
///
///   * **Plat annulé après envoi** ou **plat raté** → on perd la MATIÈRE, pas
///     la recette. Le plat n'a jamais été vendu, donc il n'est jamais entré
///     dans le chiffre d'affaires : compter son prix de vente gonflerait la
///     perte d'une marge qu'on n'a jamais encaissée.
///
///   * **Client parti sans payer** → on perd le MONTANT DE L'ADDITION. La
///     commande est encaissée côté application (elle compte donc dans le
///     chiffre d'affaires) ; la perte doit l'annuler en entier, matière ET
///     marge.
class ServiceIncidentService {
  ServiceIncidentService._();

  static final SaleLocalDatasource _ds = SaleLocalDatasource();

  /// Coût matières d'une liste d'articles.
  ///
  /// Fiche recette si elle existe, sinon le coût matière saisi sur le plat
  /// (`priceBuy`) — exactement la règle du reporting, pour que la perte et le
  /// coût des ventes parlent la même langue.
  static double materialCostOf(String shopId, List<SaleItem> items) {
    var total = 0.0;
    for (final item in items) {
      total += unitMaterialCost(shopId, item) * item.quantity;
    }
    return total;
  }

  /// Coût matières d'UNE unité de l'article.
  static double unitMaterialCost(String shopId, SaleItem item) {
    try {
      final recipe = RecipeService.recipeCost(shopId, item.productId);
      if (recipe > 0) return recipe;
      final p = LocalStorageService.getProduct(item.productId);
      return p?.priceBuy ?? item.priceBuy;
    } catch (_) {
      return item.priceBuy;
    }
  }

  /// Annule une tournée DÉJÀ ENVOYÉE en cuisine et enregistre la matière
  /// perdue.
  ///
  /// Une tournée pas encore envoyée n'a rien engagé : elle se retire sans
  /// perte, et cette méthode ne doit pas être utilisée pour ce cas.
  static Future<Loss?> cancelSentRound({
    required String shopId,
    required Sale order,
    required String reason,
    String? declaredBy,
  }) async {
    try {
      await _ds.updateOrder(order.copyWith(status: SaleStatus.cancelled));
    } catch (e) {
      debugPrint('[Incident] annulation tournée err: $e');
      return null;
    }

    // La tournée est PARTIE en cuisine : les ingrédients ont été prélevés et
    // le plat jeté. Le stock doit donc bouger comme s'il avait été vendu —
    // sinon l'inventaire annonce une matière que la poubelle a déjà emportée,
    // et la réconciliation la retrouve en écart au lieu de la voir ici.
    // La perte ci-dessous, elle, ne porte que le versant financier.
    await RestaurantOrderService.consumeStockFor(shopId, order.items);

    final amount = materialCostOf(shopId, order.items).round();
    if (amount <= 0) return null;
    return LossService.record(
      shopId: shopId,
      description: 'Tournée annulée après envoi — '
          '${order.items.length} article${order.items.length > 1 ? 's' : ''}',
      amount: amount,
      category: 'reste_invendu',
      origin: reason,
      declaredBy: declaredBy,
    );
  }

  /// Déclare un plat raté, à refaire. Le client sera bien servi, mais la
  /// matière du premier plat est perdue.
  ///
  /// La commande n'est PAS modifiée : le client paiera son plat, une seule
  /// fois. Seule la matière consommée en trop est enregistrée.
  static Future<Loss?> reportBadDish({
    required String shopId,
    required SaleItem item,
    int quantity = 1,
    String origin = '',
    String? declaredBy,
  }) async {
    final amount = (unitMaterialCost(shopId, item) * quantity).round();
    if (amount <= 0) return null;
    return LossService.record(
      shopId: shopId,
      description: '${item.productName} — plat refait (×$quantity)',
      amount: amount,
      category: 'plat_mal_fait',
      origin: origin,
      declaredBy: declaredBy,
    );
  }

  /// Déclare un départ sans paiement sur un compte.
  ///
  /// Les commandes sont clôturées (le service a bien eu lieu, la matière est
  /// consommée) et la perte porte le TOTAL — c'est elle qui annule le chiffre
  /// d'affaires que la clôture vient d'enregistrer.
  static Future<Loss?> reportUnpaid({
    required String shopId,
    required List<Sale> orders,
    required String origin,
    String? declaredBy,
  }) async {
    if (orders.isEmpty) return null;
    var total = 0.0;
    for (final o in orders) {
      total += o.total;
      try {
        await _ds.updateOrder(
            o.copyWith(status: SaleStatus.cancelled));
      } catch (e) {
        debugPrint('[Incident] clôture impayé err: $e');
      }
    }
    final amount = total.round();
    if (amount <= 0) return null;
    return LossService.record(
      shopId: shopId,
      description: 'Addition non réglée — '
          '${orders.length} bon${orders.length > 1 ? 's' : ''}',
      amount: amount,
      category: 'non_paye',
      origin: origin,
      declaredBy: declaredBy,
    );
  }

  /// Catégorie de perte attendue pour chaque incident — exposée pour que les
  /// tests verrouillent la correspondance avec le CHECK SQL de `losses`.
  @visibleForTesting
  static const Map<String, String> categories = {
    'annulation_apres_envoi': 'reste_invendu',
    'plat_rate': 'plat_mal_fait',
    'depart_sans_payer': 'non_paye',
  };
}
