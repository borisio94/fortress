import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import '../services/pin_service.dart';
import 'danger_confirm_dialog.dart';
import 'owner_pin_dialog.dart';

/// Helper pour les actions critiques (Niveau 3) : enchaîne d'abord
/// [DangerConfirmDialog] (saisie obligatoire d'un nom), puis [OwnerPinDialog]
/// (PIN propriétaire 4 chiffres). Si l'une des deux étapes est annulée ou
/// échoue, [onConfirmed] n'est pas appelé.
///
/// Si aucun PIN propriétaire n'a été configuré, affiche une SnackBar
/// explicative et redirige vers les paramètres au lieu d'exécuter l'action.
class DangerCriticalConfirm {
  /// Affiche le combo. Renvoie `true` si les deux étapes ont réussi.
  ///
  /// [onConfirmed] est exécuté APRÈS le succès des deux étapes.
  /// Aucun catch interne — laissez l'appelant gérer ses erreurs.
  static Future<bool> show({
    required BuildContext context,
    required String title,
    required String description,
    required List<String> consequences,
    required String confirmText,
    required Future<void> Function() onConfirmed,
  }) async {
    final l10n = AppLocalizations.of(context)!;

    // Pré-condition : un PIN doit exister.
    if (!await PinService.hasPIN()) {
      if (!context.mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.dangerCriticalNoPinConfigured,
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return false;
    }

    if (!context.mounted) return false;

    // Étape 1 : confirmation par saisie de nom.
    final step1 = await DangerConfirmDialog.show(
      context: context,
      title: title,
      description: description,
      consequences: consequences,
      confirmText: confirmText,
      onConfirmed: () {}, // pas d'action ici — on ne l'exécute qu'après le PIN
    );
    if (step1 != true) return false;
    if (!context.mounted) return false;

    // Étape 2 : PIN propriétaire.
    var pinOk = false;
    var pinFailed = false;
    await OwnerPinDialog.show(
      context: context,
      title: title,
      onSuccess: () => pinOk = true,
      onFailed:  () => pinFailed = true,
    );
    if (!pinOk) {
      if (pinFailed && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.ownerPinLocked),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    // Les deux étapes OK → exécution.
    await onConfirmed();
    return true;
  }
}
