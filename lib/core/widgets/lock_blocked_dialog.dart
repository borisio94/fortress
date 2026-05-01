import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import '../services/pin_service.dart';
import '../theme/app_theme.dart';

/// Dialogue affiché quand l'utilisateur tente une action sensible alors que
/// [PinService.isLocked] est `true` (3 échecs PIN consécutifs).
///
/// - Countdown rafraîchi chaque seconde tant que le verrou est actif.
/// - Se ferme automatiquement à expiration du verrou.
/// - Bouton « Fermer » uniquement (pas de bypass possible).
/// - 100% piloté par le thème — aucune couleur hex.
class LockBlockedDialog extends StatefulWidget {
  const LockBlockedDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const LockBlockedDialog(),
      );

  @override
  State<LockBlockedDialog> createState() => _LockBlockedDialogState();
}

class _LockBlockedDialogState extends State<LockBlockedDialog> {
  Timer? _ticker;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _refresh();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  void _refresh() {
    final until = PinService.lockUntil();
    if (until == null) {
      _ticker?.cancel();
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final remain = until.difference(DateTime.now());
    if (remain.isNegative || remain == Duration.zero) {
      _ticker?.cancel();
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (mounted) setState(() => _remaining = remain);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _formatCountdown(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final scheme   = theme.colorScheme;
    final semantic = theme.semantic;
    final l10n     = AppLocalizations.of(context)!;

    final minutes = _remaining.inMinutes < 1 ? 1 : _remaining.inMinutes;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Icône lock dans cercle danger ────────────────────────
            Container(
              width: 56, height: 56,
              decoration: BoxDecoration(
                color: semantic.danger.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.lock_clock_rounded,
                  size: 28, color: semantic.danger),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.lockBlockedTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.lockBlockedBody(minutes),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.65),
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            // ── Countdown pill ───────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                color: semantic.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: semantic.danger.withValues(alpha: 0.30)),
              ),
              child: Text(
                _formatCountdown(_remaining),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: semantic.danger,
                  letterSpacing: 1.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}
