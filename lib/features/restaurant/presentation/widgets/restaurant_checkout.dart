import 'package:flutter/material.dart';

import '../../../../core/services/daily_menu_service.dart';
import '../../../../core/services/invoice_printer.dart';
import '../../../../core/services/payment_service.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/restaurant_table_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_snack.dart';
import 'payment_sheet.dart';

// `placeAndPayRestaurantOrder` (prise de commande + encaissement enchaînés)
// a été SUPPRIMÉE avec le bouton « Payer » du panier, le 2026-08-04 : on
// commande, puis on encaisse depuis la page Commandes. Ne reste que
// l'encaissement d'une commande existante, ci-dessous.

/// ENCAISSEMENT d'une commande DÉJÀ CRÉÉE — Module 8 du flux.
///
/// Le seul geste demandé est le MODE DE RÈGLEMENT ; la commande passe ensuite
/// directement à « payée ». Rien d'autre n'est réclamé, parce que rien d'autre
/// n'existe ici : pas de client CRM à confirmer, pas de date de livraison à
/// planifier, pas de « qui a encaissé ? » entre la boutique et un partenaire —
/// ces questions viennent du circuit e-commerce, où une commande voyage.
/// Au restaurant, le client est devant le comptoir.
///
/// Retourne `true` si le règlement a été validé, `false` si l'opérateur a
/// renoncé — la commande reste alors intacte et encaissable plus tard.
Future<bool> settleRestaurantOrder({
  required BuildContext context,
  required Sale order,
}) async {
  // Reste dû arrondi à l'unité : le FCFA n'a pas de centimes, et un reliquat
  // de 0,4 F empêcherait l'addition de tomber juste.
  final due = (order.total - order.amountPaid).round();
  final split = await showAdaptiveFormSheet<PaymentSplit>(
    context: context,
    builder: (_) => PaymentSheet(
      due: due < 0 ? 0 : due,
      subtitle: _subtitleFor(order),
    ),
  );
  if (split == null) return false;

  final shopId = order.shopId;
  try {
    Sale? settled;
    // Ce que le décompte du jour a perdu, s'il a perdu quelque chose. Il est
    // rendu par les deux chemins de clôture, et il faut le DIRE : ce décompte
    // est local à l'appareil, personne d'autre ne le verra.
    DailyConsumeReport stock;
    final tableId = order.tableId;
    final table =
        tableId == null ? null : RestaurantTableService.tableById(tableId);
    if (table != null) {
      // En salle : clôture + libération conditionnelle de la table (elle peut
      // porter d'autres comptes).
      final res = await RestaurantOrderService.settleAndRelease(
        order: order,
        table: table,
        // Soldée → `null` force « entièrement payé » et absorbe les décimales
        // d'un total non entier. Sinon on transmet l'encaissé réel, qui laisse
        // la différence en créance.
        amountPaid:
            split.isSettled ? null : (order.amountPaid + split.applied),
        method: split.dominantMethod,
      );
      settled = res.order;
      stock = res.stock;
    } else {
      stock = await RestaurantOrderService.collectTakeaway(
        order,
        amountPaid:
            split.isSettled ? null : (order.amountPaid + split.applied),
        method: split.dominantMethod,
      );
      settled = order;
    }

    // Règlements enregistrés APRÈS la clôture : si celle-ci lève (transition
    // interdite, stock insuffisant), aucune ligne de paiement ne doit rester
    // derrière une commande non encaissée.
    final orderId = order.id;
    if (orderId != null && orderId.isNotEmpty) {
      await PaymentService.recordSplit(
        shopId: shopId,
        orderId: orderId,
        split: split,
      );
    }

    if (!context.mounted) return true;
    AppSnack.success(
        context,
        split.change > 0
            ? 'Encaissée — rendre '
                '${CurrencyFormatter.format(split.change.toDouble())}'
            : 'Commande encaissée');

    // APRÈS le succès, et pas à sa place : la vente a bien eu lieu, le client
    // a payé. Ce qui suit est un avertissement sur la réserve, pas un échec.
    final warn = oversoldMessage(stock, order.items);
    if (warn != null && context.mounted) AppSnack.warning(context, warn);

    // Facture après encaissement, comme sur l'addition de table.
    if (settled != null && context.mounted) {
      await InvoicePrinter.printOrShare(
        context: context,
        sale: settled,
        shop: LocalStorageService.getShop(shopId),
      );
    }
    return true;
  } catch (e) {
    // `updateOrderStatus` lève des exceptions métier au message déjà rédigé
    // pour l'utilisateur (transition interdite, stock insuffisant).
    if (context.mounted) AppSnack.error(context, e.toString());
    // L'encaissement a échoué : la commande n'est pas payée, l'appelant ne
    // doit pas la traiter comme telle.
    return false;
  }
}

/// Repère affiché en sous-titre de la feuille d'encaissement : le caissier
/// doit voir QUELLE addition il encaisse, pas un identifiant.
String _subtitleFor(Sale order) {
  final tab = (order.tabLabel ?? '').trim();
  final tableId = order.tableId;
  final table =
      tableId == null ? null : RestaurantTableService.tableById(tableId);
  if (table != null) {
    return tab.isEmpty ? table.name : '${table.name} · $tab';
  }
  final name = (order.clientName ?? '').trim();
  if (name.isEmpty) return tab.isEmpty ? 'À emporter' : tab;
  return tab.isEmpty ? name : '$name · $tab';
}
