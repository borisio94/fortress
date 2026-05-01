import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AppSnack — helper centralisé pour tous les SnackBar de l'app
//
// Remplace les 9 occurrences de showSnackBar(SnackBar(...)) inline
// Usage :
//   AppSnack.success(context, 'Produit enregistré !');
//   AppSnack.error(context, 'Erreur: $e');
//   AppSnack.warning(context, 'Attention...');
//   AppSnack.info(context, 'Information...');
//
// Les erreurs et warnings émettent aussi un signal sonore (alert système) +
// vibration haptique pour prévenir l'utilisateur sans qu'il ait à regarder
// l'écran.
// ─────────────────────────────────────────────────────────────────────────────

class AppSnack {
  static void success(BuildContext context, String message) =>
      _show(context, message, AppColors.secondary, Icons.check_circle_outline);

  static void error(BuildContext context, String message) {
    _alert();
    _show(context, message, AppColors.error, Icons.error_outline_rounded);
  }

  static void warning(BuildContext context, String message) {
    _alert();
    _show(context, message, const Color(0xFFF59E0B),
        Icons.warning_amber_rounded);
  }

  static void info(BuildContext context, String message) =>
      _show(context, message, AppColors.primary, Icons.info_outline_rounded);

  /// Émet un bip système + vibration pour signaler une erreur. Ne bloque
  /// jamais : si la plateforme ne supporte pas le son/haptique, on ignore.
  static void _alert() {
    try { SystemSound.play(SystemSoundType.alert); } catch (_) {}
    try { HapticFeedback.heavyImpact(); } catch (_) {}
  }

  /// Déclenche le bip d'alerte sans afficher de SnackBar — utilisable depuis
  /// les couches non-UI (services, repositories) via un appel direct.
  static void playErrorSound() => _alert();

  static void _show(
    BuildContext context,
    String message,
    Color color,
    IconData icon, {
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 10),
          Expanded(
              child: Text(message,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13))),
        ]),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        duration: duration,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
      ));
  }
}
