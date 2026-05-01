import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/app_localizations.dart';
import '../services/pin_service.dart';
import '../theme/app_theme.dart';

/// Dialogue de saisie du PIN propriétaire (4 chiffres).
///
/// - Affiche 4 indicateurs de progression et un pavé numérique 3×4.
/// - Vérifie le code via [PinService] : `onSuccess` quand le PIN est correct,
///   `onFailed` après [PinService.maxAttempts] échecs (le service verrouille
///   alors automatiquement pendant [PinService.lockDuration]).
/// - Si le service est déjà verrouillé à l'ouverture, le clavier est
///   désactivé et le minuteur restant est affiché.
/// - 100% piloté par le thème : aucune couleur hex.
class OwnerPinDialog extends StatefulWidget {
  final String title;
  final VoidCallback onSuccess;
  final VoidCallback onFailed;

  const OwnerPinDialog({
    super.key,
    required this.title,
    required this.onSuccess,
    required this.onFailed,
  });

  static Future<bool?> show({
    required BuildContext context,
    required String title,
    required VoidCallback onSuccess,
    required VoidCallback onFailed,
  }) => showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => OwnerPinDialog(
          title: title,
          onSuccess: onSuccess,
          onFailed: onFailed,
        ),
      );

  /// Helper pour les actions Niveau 2 : exige le PIN avant d'exécuter
  /// [onConfirmed]. Retourne `true` si l'action a été déclenchée.
  ///
  /// Si aucun PIN n'a été configuré, affiche une SnackBar explicative
  /// et n'exécute pas l'action.
  static Future<bool> guard({
    required BuildContext context,
    required String title,
    required Future<void> Function() onConfirmed,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    if (!await PinService.hasPIN()) {
      if (!context.mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.dangerCriticalNoPinConfigured),
        behavior: SnackBarBehavior.floating,
      ));
      return false;
    }
    if (!context.mounted) return false;
    var ok = false;
    var failed = false;
    await show(
      context: context,
      title: title,
      onSuccess: () => ok = true,
      onFailed:  () => failed = true,
    );
    if (failed && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.ownerPinLocked),
        behavior: SnackBarBehavior.floating,
      ));
    }
    if (!ok) return false;
    await onConfirmed();
    return true;
  }

  @override
  State<OwnerPinDialog> createState() => _OwnerPinDialogState();
}

class _OwnerPinDialogState extends State<OwnerPinDialog>
    with SingleTickerProviderStateMixin {
  final List<int> _digits = [];
  late final AnimationController _shake;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  Future<void> _onTapDigit(int d) async {
    if (_checking || PinService.isLocked()) return;
    if (_digits.length >= PinService.pinLength) return;
    setState(() => _digits.add(d));
    HapticFeedback.selectionClick();
    if (_digits.length == PinService.pinLength) {
      await _submit();
    }
  }

  void _onBackspace() {
    if (_checking || PinService.isLocked()) return;
    if (_digits.isEmpty) return;
    setState(() => _digits.removeLast());
    HapticFeedback.selectionClick();
  }

  Future<void> _submit() async {
    setState(() => _checking = true);
    final pin = _digits.join();
    final ok  = await PinService.verifyPIN(pin);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      widget.onSuccess();
      return;
    }
    // Échec : shake + reset.
    HapticFeedback.heavyImpact();
    await _shake.forward(from: 0);
    if (!mounted) return;
    setState(() {
      _digits.clear();
      _checking = false;
    });
    // Verrouillé après cet échec → fermer et notifier.
    if (PinService.isLocked()) {
      Navigator.of(context).pop(false);
      widget.onFailed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final scheme   = theme.colorScheme;
    final l10n     = AppLocalizations.of(context)!;

    final locked          = PinService.isLocked();
    final attemptsLeft    = PinService.attemptsRemaining();
    final lockUntil       = PinService.lockUntil();

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.ownerPinSubtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 18),
            _PinDots(
              filled: _digits.length,
              total: PinService.pinLength,
              shake: _shake,
            ),
            const SizedBox(height: 18),
            if (locked)
              _LockedBanner(until: lockUntil!)
            else
              Text(
                l10n.ownerPinAttemptsRemaining(attemptsLeft),
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            const SizedBox(height: 14),
            _Keypad(
              enabled: !locked && !_checking,
              onDigit: _onTapDigit,
              onBackspace: _onBackspace,
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.cancel),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Dots (4 indicateurs) ───────────────────────────────────────────────────
class _PinDots extends StatelessWidget {
  final int filled;
  final int total;
  final AnimationController shake;
  const _PinDots({
    required this.filled,
    required this.total,
    required this.shake,
  });

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final scheme   = theme.colorScheme;
    final semantic = theme.semantic;
    return AnimatedBuilder(
      animation: shake,
      builder: (_, child) {
        // Oscillation horizontale ±8px sur la durée totale.
        final t  = shake.value;
        final dx = (t == 0)
            ? 0.0
            : 8.0 * (1 - t) *
                (((t * 4 * 3.14159).remainder(2 * 3.14159) < 3.14159) ? 1 : -1);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(total, (i) {
          final isFilled = i < filled;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              width: 12, height: 12,
              decoration: BoxDecoration(
                color: isFilled ? scheme.primary : Colors.transparent,
                border: Border.all(
                  color: isFilled
                      ? scheme.primary
                      : semantic.borderSubtle,
                  width: 1.5,
                ),
                shape: BoxShape.circle,
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ─── Keypad 3×4 ─────────────────────────────────────────────────────────────
class _Keypad extends StatelessWidget {
  final bool enabled;
  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;
  const _Keypad({
    required this.enabled,
    required this.onDigit,
    required this.onBackspace,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _row(context, [1, 2, 3]),
        const SizedBox(height: 8),
        _row(context, [4, 5, 6]),
        const SizedBox(height: 8),
        _row(context, [7, 8, 9]),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 64, height: 56),
            const SizedBox(width: 12),
            _KeypadKey(
              label: '0',
              enabled: enabled,
              onTap: () => onDigit(0),
            ),
            const SizedBox(width: 12),
            _KeypadKey.icon(
              icon: Icons.backspace_outlined,
              enabled: enabled,
              onTap: onBackspace,
            ),
          ],
        ),
      ],
    );
  }

  Widget _row(BuildContext context, List<int> ds) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < ds.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            _KeypadKey(
              label: '${ds[i]}',
              enabled: enabled,
              onTap: () => onDigit(ds[i]),
            ),
          ],
        ],
      );
}

class _KeypadKey extends StatelessWidget {
  final String? label;
  final IconData? iconData;
  final bool enabled;
  final VoidCallback onTap;

  const _KeypadKey({
    required this.label,
    required this.enabled,
    required this.onTap,
  }) : iconData = null;

  const _KeypadKey.icon({
    required IconData icon,
    required this.enabled,
    required this.onTap,
  })  : label    = null,
        iconData = icon;

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final scheme   = theme.colorScheme;
    final semantic = theme.semantic;

    return Material(
      color: enabled
          ? semantic.trackMuted
          : semantic.trackMuted.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: semantic.borderSubtle, width: 1),
      ),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        splashColor: scheme.primary.withValues(alpha: 0.18),
        highlightColor: scheme.primary.withValues(alpha: 0.08),
        child: SizedBox(
          width: 64, height: 56,
          child: Center(
            child: iconData != null
                ? Icon(iconData,
                    size: 20,
                    color: enabled
                        ? scheme.onSurface
                        : scheme.onSurface.withValues(alpha: 0.4))
                : Text(
                    label!,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: enabled
                          ? scheme.onSurface
                          : scheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── Bandeau "verrouillé" ───────────────────────────────────────────────────
class _LockedBanner extends StatelessWidget {
  final DateTime until;
  const _LockedBanner({required this.until});

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final semantic = theme.semantic;
    final l10n     = AppLocalizations.of(context)!;
    final remain   = until.difference(DateTime.now());
    final minutes  = remain.inMinutes < 1 ? 1 : remain.inMinutes;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: semantic.danger.withValues(alpha: 0.10),
        border: Border.all(color: semantic.danger.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_clock_rounded,
              size: 14, color: semantic.danger),
          const SizedBox(width: 6),
          Text(
            l10n.ownerPinLockedUntil(minutes),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: semantic.danger,
            ),
          ),
        ],
      ),
    );
  }
}
