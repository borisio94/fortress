import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/app_localizations.dart';
import '../services/pin_service.dart';
import '../theme/app_theme.dart';

/// Dialog de configuration / modification du PIN propriétaire.
///
/// Détection automatique :
///  - Si aucun PIN n'est défini : flux "définir" (saisir × 2).
///  - Si un PIN existe        : flux "modifier" (ancien → nouveau → confirmer).
///
/// `Navigator.pop(true)` quand le PIN a été enregistré, `false` sinon.
class OwnerPinSetupDialog extends StatefulWidget {
  const OwnerPinSetupDialog({super.key});

  static Future<bool?> show(BuildContext context) => showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const OwnerPinSetupDialog(),
      );

  @override
  State<OwnerPinSetupDialog> createState() => _OwnerPinSetupDialogState();
}

enum _Step { verifyOld, enterNew, confirmNew }

class _OwnerPinSetupDialogState extends State<OwnerPinSetupDialog> {
  bool _initializing = true;
  bool _hasPin = false;
  _Step _step = _Step.enterNew;
  String _firstEntry = '';
  String _current    = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final has = await PinService.hasPIN();
    if (!mounted) return;
    setState(() {
      _hasPin = has;
      _step   = has ? _Step.verifyOld : _Step.enterNew;
      _initializing = false;
    });
  }

  void _onDigit(int d) {
    if (_current.length >= PinService.pinLength) return;
    setState(() {
      _current = '$_current$d';
      _error   = null;
    });
    HapticFeedback.selectionClick();
    if (_current.length == PinService.pinLength) {
      _onComplete();
    }
  }

  void _onBackspace() {
    if (_current.isEmpty) return;
    setState(() {
      _current = _current.substring(0, _current.length - 1);
      _error   = null;
    });
    HapticFeedback.selectionClick();
  }

  Future<void> _onComplete() async {
    final l10n = AppLocalizations.of(context)!;
    switch (_step) {
      case _Step.verifyOld:
        final ok = await PinService.verifyPIN(_current);
        if (!mounted) return;
        if (ok) {
          setState(() {
            _step    = _Step.enterNew;
            _current = '';
          });
        } else {
          HapticFeedback.heavyImpact();
          setState(() {
            _error   = l10n.ownerPinIncorrect;
            _current = '';
          });
        }
        break;
      case _Step.enterNew:
        setState(() {
          _firstEntry = _current;
          _step       = _Step.confirmNew;
          _current    = '';
        });
        break;
      case _Step.confirmNew:
        if (_current != _firstEntry) {
          HapticFeedback.heavyImpact();
          setState(() {
            _error      = l10n.pinMismatch;
            _firstEntry = '';
            _current    = '';
            _step       = _Step.enterNew;
          });
          return;
        }
        await PinService.setPIN(_current);
        if (!mounted) return;
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.pinChanged),
          behavior: SnackBarBehavior.floating,
        ));
        break;
    }
  }

  String _titleFor(AppLocalizations l10n) {
    switch (_step) {
      case _Step.verifyOld:  return l10n.pinSetupTitle;
      case _Step.enterNew:   return _hasPin ? l10n.pinChange : l10n.pinDefine;
      case _Step.confirmNew: return l10n.pinConfirmNew;
    }
  }

  String _subtitleFor(AppLocalizations l10n) {
    switch (_step) {
      case _Step.verifyOld:  return l10n.ownerPinSubtitle;
      case _Step.enterNew:   return l10n.pinEnterNew;
      case _Step.confirmNew: return l10n.pinConfirmNew;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final scheme   = theme.colorScheme;
    final semantic = theme.semantic;
    final l10n     = AppLocalizations.of(context)!;

    if (_initializing) {
      return const AlertDialog(
        content: SizedBox(
          width: 200, height: 80,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _titleFor(l10n),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _subtitleFor(l10n),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 18),
            // Dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(PinService.pinLength, (i) {
                final filled = i < _current.length;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    width: 12, height: 12,
                    decoration: BoxDecoration(
                      color: filled ? scheme.primary : Colors.transparent,
                      border: Border.all(
                        color: filled
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
            const SizedBox(height: 14),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 11.5,
                  color: semantic.danger,
                  fontWeight: FontWeight.w600,
                ),
              )
            else
              const SizedBox(height: 14),
            const SizedBox(height: 8),
            // Keypad
            _Keypad(onDigit: _onDigit, onBackspace: _onBackspace),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.commonCancel),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Keypad partagé (copie minimaliste) ─────────────────────────────────────
class _Keypad extends StatelessWidget {
  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;
  const _Keypad({required this.onDigit, required this.onBackspace});

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
            _Key(label: '0', onTap: () => onDigit(0)),
            const SizedBox(width: 12),
            _Key.icon(icon: Icons.backspace_outlined, onTap: onBackspace),
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
            _Key(label: '${ds[i]}', onTap: () => onDigit(ds[i])),
          ],
        ],
      );
}

class _Key extends StatelessWidget {
  final String? label;
  final IconData? iconData;
  final VoidCallback onTap;

  const _Key({required this.label, required this.onTap}) : iconData = null;
  const _Key.icon({required IconData icon, required this.onTap})
      : label    = null,
        iconData = icon;

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final scheme   = theme.colorScheme;
    final semantic = theme.semantic;
    return Material(
      color: semantic.trackMuted,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: semantic.borderSubtle, width: 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        splashColor: scheme.primary.withValues(alpha: 0.18),
        highlightColor: scheme.primary.withValues(alpha: 0.08),
        child: SizedBox(
          width: 64, height: 56,
          child: Center(
            child: iconData != null
                ? Icon(iconData, size: 20, color: scheme.onSurface)
                : Text(
                    label!,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
