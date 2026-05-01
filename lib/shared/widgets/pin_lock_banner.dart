import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/services/pin_service.dart';
import '../../core/theme/app_theme.dart';

/// Bannière globale affichée tant que [PinService.isLocked] est `true`.
///
/// - S'auto-rafraîchit chaque seconde et disparaît automatiquement à
///   expiration du verrou — pas besoin d'écouter d'événement externe.
/// - Couleur warning du thème (jamais d'hex hardcodé).
/// - Hauteur 0 quand non verrouillé → aucun impact visuel hors verrouillage.
class PinLockBanner extends StatefulWidget {
  const PinLockBanner({super.key});

  @override
  State<PinLockBanner> createState() => _PinLockBannerState();
}

class _PinLockBannerState extends State<PinLockBanner> {
  Timer? _ticker;
  Duration _remaining = Duration.zero;
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  void _refresh() {
    final until = PinService.lockUntil();
    if (until == null) {
      if (_locked && mounted) {
        setState(() {
          _locked    = false;
          _remaining = Duration.zero;
        });
      }
      return;
    }
    final remain = until.difference(DateTime.now());
    if (remain.isNegative || remain == Duration.zero) {
      if (_locked && mounted) {
        setState(() {
          _locked    = false;
          _remaining = Duration.zero;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _locked    = true;
        _remaining = remain;
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_locked) return const SizedBox.shrink();

    final theme    = Theme.of(context);
    final scheme   = theme.colorScheme;
    final semantic = theme.semantic;
    final l10n     = AppLocalizations.of(context)!;
    final minutes  = _remaining.inMinutes < 1 ? 1 : _remaining.inMinutes;

    return Material(
      color: semantic.warning.withValues(alpha: 0.12),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(children: [
            Icon(Icons.lock_clock_rounded,
                size: 16, color: semantic.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.pinLockBannerMessage(minutes),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
