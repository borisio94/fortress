import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/order_actions.dart';

/// L'HABILLAGE DES ACTIONS DE COMMANDE.
///
/// Séparé de la règle, comme `service_tab_visuals` l'est de `service_tabs` :
/// `order_actions.dart` ne connaît ni `IconData` ni `Color`, et reste du Dart
/// pur testable sans Flutter.
extension OrderActionVisuals on OrderAction {
  /// L'icône, identique à celle que portait le bouton d'origine.
  IconData get icon => switch (this) {
        OrderAction.closeApprovalRound => Icons.fact_check_outlined,
        OrderAction.cancelApprovalRound => Icons.cancel_outlined,
        OrderAction.advanceStatus => Icons.point_of_sale_rounded,
        OrderAction.cancelOrRefuse => Icons.do_not_disturb_on_outlined,
        OrderAction.reopenPaidSale => Icons.undo_rounded,
        OrderAction.invoicePdf => Icons.picture_as_pdf_rounded,
        OrderAction.invoiceWhatsApp => Icons.send_rounded,
        OrderAction.collectBalance => Icons.payments_outlined,
        OrderAction.relaunchClient => Icons.notifications_active_outlined,
        OrderAction.editFees => Icons.local_shipping_outlined,
        OrderAction.editOrder => Icons.edit_rounded,
        OrderAction.deleteOrder => Icons.delete_outline_rounded,
      };

  /// La teinte, reprise du bouton d'origine.
  ///
  /// Les destructives passent par `semantic.danger` plutôt que par
  /// `AppColors.error` : elles sont désormais groupées en bas de la feuille et
  /// doivent tenir sur les huit palettes, en clair comme en sombre.
  Color color(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return switch (this) {
      OrderAction.cancelApprovalRound ||
      OrderAction.cancelOrRefuse ||
      OrderAction.deleteOrder =>
        sem.dangerText,
      OrderAction.reopenPaidSale || OrderAction.collectBalance =>
        sem.warningText,
      OrderAction.invoiceWhatsApp || OrderAction.relaunchClient =>
        AppColors.whatsapp,
      OrderAction.advanceStatus => AppColors.secondary,
      _ => AppColors.primary,
    };
  }
}
