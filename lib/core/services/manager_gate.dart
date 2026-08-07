import 'package:flutter/material.dart';

import '../permisions/app_permissions.dart';
import '../widgets/lock_blocked_dialog.dart';
import '../widgets/owner_pin_dialog.dart';
import '../../shared/widgets/app_snack.dart';
import 'activity_log_service.dart';
import 'pin_service.dart';

/// Gestes de service qui exigent l'aval du gérant (Lot A).
///
/// Ce sont les points par lesquels l'argent sort d'un restaurant sans qu'un
/// plat sorte : annuler une tournée déjà partie en cuisine, remiser une
/// addition, et défaire une vente déjà encaissée. Laissés libres, ils
/// permettent d'encaisser au comptant puis d'effacer la ligne.
enum ManagerAction {
  /// Annulation d'une tournée DÉJÀ envoyée en cuisine (matière engagée).
  cancelSentRound,

  /// Remise appliquée sur une addition.
  discountBill,

  /// Retour en arrière sur une vente DÉJÀ ENCAISSÉE (repasser en programmée).
  ///
  /// C'est la troisième porte, et la plus large : elle restitue le stock, le
  /// paiement et les écritures partenaire. Sous simple permission elle ne
  /// laissait aucune trace de QUI avait autorisé le geste — or c'est
  /// exactement le scénario qu'on cherche à couvrir : la commande a été payée
  /// en espèces, puis la ligne disparaît.
  reopenPaidSale,
}

extension ManagerActionX on ManagerAction {
  /// Action journalisée dans `activity_logs` — doit exister dans
  /// [ActivityActions], sinon elle serait invisible dans tous les filtres de
  /// l'historique.
  String get logAction => switch (this) {
        ManagerAction.cancelSentRound => 'round_cancelled',
        ManagerAction.discountBill => 'bill_discounted',
        ManagerAction.reopenPaidSale => 'paid_sale_reopened',
      };

  String get title => switch (this) {
        ManagerAction.cancelSentRound => 'Annuler une tournée envoyée',
        ManagerAction.discountBill => 'Remise sur l\'addition',
        ManagerAction.reopenPaidSale => 'Défaire une vente encaissée',
      };

  bool canExecute(AppPermissions perms) => switch (this) {
        ManagerAction.cancelSentRound => perms.canCancelSale,
        ManagerAction.discountBill => perms.canApplyDiscount,
        ManagerAction.reopenPaidSale => perms.canCancelSale,
      };
}

/// Code PIN gérant sur les actions sensibles du service.
///
/// Écart ASSUMÉ vs la spec, qui demandait une colonne `employees.manager_pin` :
/// Fortress a déjà un PIN propriétaire ([PinService]) haché en SHA-256 + sel,
/// verrouillé 15 min après trois échecs et synchronisé entre appareils via
/// `profiles`. Un second PIN stocké en clair sur `employees` aurait été une
/// régression de sécurité pour la même fonction.
///
/// Différence VOLONTAIRE avec [OwnerPinDialog.guard] : quand AUCUN PIN n'est
/// configuré, l'action passe (avec un rappel) au lieu d'être refusée. Bloquer
/// une annulation en plein service parce qu'un réglage manque paralyserait la
/// salle — et le personnel contournerait par un chemin non tracé, ce qui est
/// exactement ce qu'on cherche à éviter. La permission, elle, reste exigée.
class ManagerGate {
  ManagerGate._();

  /// Demande l'aval du gérant. Retourne `true` si l'action peut se poursuivre.
  ///
  /// [targetLabel] est ce que lira le gérant dans l'historique (« Table 5 ·
  /// Compte 1 »), [details] ce qui doit rester chiffré (montant, motif).
  static Future<bool> require({
    required BuildContext context,
    required AppPermissions perms,
    required ManagerAction action,
    required String shopId,
    String? targetId,
    String? targetLabel,
    Map<String, dynamic>? details,
  }) async {
    if (!action.canExecute(perms)) {
      AppSnack.error(context,
          'Vous n\'avez pas le droit d\'effectuer cette action.');
      return false;
    }

    // Verrou actif : on bloque AVANT toute saisie, comme DangerActionService.
    if (PinService.isLocked()) {
      await LockBlockedDialog.show(context);
      return false;
    }
    if (!context.mounted) return false;

    if (await PinService.hasPIN()) {
      if (!context.mounted) return false;
      var ok = false;
      var failed = false;
      await OwnerPinDialog.show(
        context: context,
        title: action.title,
        onSuccess: () => ok = true,
        onFailed: () => failed = true,
      );
      if (!ok) {
        if (failed && context.mounted) {
          AppSnack.error(context,
              'Trop de tentatives — code PIN verrouillé 15 minutes.');
        }
        return false;
      }
    } else if (context.mounted) {
      AppSnack.info(
          context,
          'Aucun code PIN gérant configuré : cette action n\'est pas '
          'protégée. Réglages → Sécurité pour en définir un.');
    }

    // Journalisé APRÈS l'aval et AVANT l'exécution : ce qui compte est qu'un
    // gérant a autorisé le geste, pas qu'il ait abouti techniquement.
    await ActivityLogService.log(
      action: action.logAction,
      targetType: 'order',
      targetId: targetId,
      targetLabel: targetLabel,
      shopId: shopId,
      details: details,
    );
    return true;
  }
}
