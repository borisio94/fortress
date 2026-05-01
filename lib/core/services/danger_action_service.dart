import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../i18n/app_localizations.dart';
import '../permisions/app_permissions.dart';
import '../widgets/danger_confirm_dialog.dart';
import '../widgets/lock_blocked_dialog.dart';
import '../widgets/owner_pin_dialog.dart';
import 'pin_service.dart';

// ─── Catalogue des actions destructives ─────────────────────────────────────

/// Toutes les actions destructives orchestrées par [DangerActionService].
/// Chaque valeur porte ses règles métier (PIN requis ? quel rôle ?) via
/// l'extension [DangerActionX] plus bas.
enum DangerAction {
  deleteShop,
  deleteAdmin,
  demoteAdmin,
  cancelSale,
  deleteProduct,
  deleteClient,
}

extension DangerActionX on DangerAction {
  /// Clé persistée en base (table `danger_action_logs.action`).
  String get key => switch (this) {
        DangerAction.deleteShop    => 'delete_shop',
        DangerAction.deleteAdmin   => 'delete_admin',
        DangerAction.demoteAdmin   => 'demote_admin',
        DangerAction.cancelSale    => 'cancel_sale',
        DangerAction.deleteProduct => 'delete_product',
        DangerAction.deleteClient  => 'delete_client',
      };

  /// Le PIN propriétaire est-il exigé après la saisie de confirmation ?
  bool get requiresOwnerPin => switch (this) {
        DangerAction.deleteShop    => true,
        DangerAction.deleteAdmin   => true,
        DangerAction.demoteAdmin   => true,
        DangerAction.cancelSale    => false,
        DangerAction.deleteProduct => false,
        DangerAction.deleteClient  => false,
      };

  /// L'utilisateur courant a-t-il le droit d'invoquer cette action ?
  ///
  /// Owner → tout. L'admin "principal" (perm `shopFullEdit`, un seul par
  /// boutique, désigné par le owner) peut exécuter `deleteAdmin` et
  /// `demoteAdmin`. La suppression de la boutique reste owner-only.
  bool canExecute(AppPermissions perms) => switch (this) {
        DangerAction.deleteShop    => perms.isOwner,
        DangerAction.deleteAdmin   => perms.isOwner || perms.canDoFullShopEdit,
        DangerAction.demoteAdmin   => perms.isOwner || perms.canDoFullShopEdit,
        DangerAction.cancelSale    => perms.canDeleteOrder,
        DangerAction.deleteProduct => perms.canDeleteProduct,
        DangerAction.deleteClient  => perms.canDeleteClient,
      };
}

// ─── Service ────────────────────────────────────────────────────────────────

/// Orchestre l'exécution sécurisée d'une [DangerAction] :
///   1. Vérifie les permissions via `permissionsProvider`.
///   2. Affiche le [DangerConfirmDialog] (saisie obligatoire de [confirmText]).
///   3. Si l'action exige le PIN : affiche [OwnerPinDialog].
///   4. Exécute [onConfirmed] si tout est validé.
///   5. Log systématiquement la tentative (succès OU échec) dans la table
///      `danger_action_logs` (best-effort — un échec de log n'empêche pas
///      l'action).
///
/// Retourne `true` si l'action a été exécutée, `false` sinon.
class DangerActionService {
  static Future<bool> execute({
    required BuildContext context,
    required AppPermissions perms,
    required DangerAction action,
    required String shopId,
    required String targetId,
    required String targetLabel,
    required String confirmText,
    required String title,
    required String description,
    required List<String> consequences,
    required Future<void> Function() onConfirmed,
  }) async {
    final l10n = AppLocalizations.of(context)!;

    // ── 1. Permissions ──────────────────────────────────────────────────
    if (!action.canExecute(perms)) {
      _showSnack(context, l10n.permissionDenied);
      await _logBestEffort(
        shopId:       shopId,
        action:       action,
        targetId:     targetId,
        targetLabel:  targetLabel,
        success:      false,
        errorMessage: 'permission_denied',
      );
      return false;
    }

    // ── 1.5. Verrou PIN actif ? On bloque AVANT toute saisie. ──────────
    if (action.requiresOwnerPin && PinService.isLocked()) {
      await LockBlockedDialog.show(context);
      await _logBestEffort(
        shopId:       shopId,
        action:       action,
        targetId:     targetId,
        targetLabel:  targetLabel,
        success:      false,
        errorMessage: 'pin_locked_at_entry',
      );
      return false;
    }

    // ── 2. DangerConfirmDialog (saisie nom obligatoire) ────────────────
    final confirmed = await DangerConfirmDialog.show(
      context:      context,
      title:        title,
      description:  description,
      consequences: consequences,
      confirmText:  confirmText,
      onConfirmed:  () {},
    );
    if (confirmed != true) {
      await _logBestEffort(
        shopId:       shopId,
        action:       action,
        targetId:     targetId,
        targetLabel:  targetLabel,
        success:      false,
        errorMessage: 'cancelled_at_confirm',
      );
      return false;
    }
    if (!context.mounted) return false;

    // ── 3. OwnerPinDialog si requis ─────────────────────────────────────
    if (action.requiresOwnerPin) {
      if (!await PinService.hasPIN()) {
        if (context.mounted) {
          _showSnack(context, l10n.dangerCriticalNoPinConfigured);
        }
        await _logBestEffort(
          shopId:       shopId,
          action:       action,
          targetId:     targetId,
          targetLabel:  targetLabel,
          success:      false,
          errorMessage: 'no_pin_configured',
        );
        return false;
      }
      if (!context.mounted) return false;

      var pinOk     = false;
      var pinFailed = false;
      await OwnerPinDialog.show(
        context: context,
        title:   title,
        onSuccess: () => pinOk     = true,
        onFailed:  () => pinFailed = true,
      );
      if (!pinOk) {
        if (pinFailed && context.mounted) {
          _showSnack(context, l10n.ownerPinLocked);
        }
        await _logBestEffort(
          shopId:       shopId,
          action:       action,
          targetId:     targetId,
          targetLabel:  targetLabel,
          success:      false,
          errorMessage: pinFailed ? 'pin_locked' : 'pin_cancelled',
        );
        return false;
      }
    }

    // ── 4. Exécution ───────────────────────────────────────────────────
    try {
      await onConfirmed();
      await _logBestEffort(
        shopId:      shopId,
        action:      action,
        targetId:    targetId,
        targetLabel: targetLabel,
        success:     true,
      );
      return true;
    } catch (e) {
      await _logBestEffort(
        shopId:       shopId,
        action:       action,
        targetId:     targetId,
        targetLabel:  targetLabel,
        success:      false,
        errorMessage: e.toString(),
      );
      rethrow;
    }
  }

  // ── Logger best-effort ────────────────────────────────────────────────
  static Future<void> _logBestEffort({
    required String      shopId,
    required DangerAction action,
    required String      targetId,
    required String      targetLabel,
    required bool        success,
    String?              errorMessage,
  }) async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;
      await Supabase.instance.client.from('danger_action_logs').insert({
        'shop_id':       shopId.isEmpty ? null : shopId,
        'user_id':       user.id,
        'user_email':    user.email,
        'action':        action.key,
        'target_id':     targetId,
        'target_label':  targetLabel,
        'success':       success,
        'error_message': errorMessage,
      });
    } catch (e) {
      // Silencieux : un échec d'audit ne doit jamais bloquer l'utilisateur.
      debugPrint('[DangerLog] échec insertion: $e');
    }
  }

  static void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:  Text(message),
      behavior: SnackBarBehavior.floating,
    ));
  }
}
