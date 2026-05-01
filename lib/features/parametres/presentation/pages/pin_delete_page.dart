import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/services/pin_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';

/// Page plein écran pour la suppression du code PIN propriétaire.
///
/// Remplace les anciens `DangerConfirmDialog` + `OwnerPinDialog` enchaînés.
/// Sur mobile, un dialogue contenant un `TextField` avec autofocus voit son
/// UI compromise quand le clavier système se déploie ; une page dédiée gère
/// correctement le scroll au-dessus du clavier (`resizeToAvoidBottomInset`).
///
/// Flux en 2 étapes affichées sur la même page :
///   1. Confirmation par saisie textuelle du mot-clé `PIN`.
///   2. Pavé numérique inline pour ré-saisir le code PIN actuel.
/// Au succès, `PinService.clearPIN()` est appelé et la page renvoie `true`.
class PinDeletePage extends StatefulWidget {
  final String shopId;
  const PinDeletePage({super.key, required this.shopId});

  @override
  State<PinDeletePage> createState() => _PinDeletePageState();
}

class _PinDeletePageState extends State<PinDeletePage>
    with SingleTickerProviderStateMixin {
  static const String _confirmKeyword = 'PIN';

  final _confirmCtrl = TextEditingController();
  bool _confirmMatches = false;
  bool _step2 = false;

  final List<int> _digits = [];
  bool _verifying = false;
  late final AnimationController _shake;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _confirmCtrl.addListener(_onConfirmChanged);
  }

  @override
  void dispose() {
    _confirmCtrl.removeListener(_onConfirmChanged);
    _confirmCtrl.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _onConfirmChanged() {
    final ok = _confirmCtrl.text.trim().toLowerCase() ==
        _confirmKeyword.toLowerCase();
    if (ok != _confirmMatches) setState(() => _confirmMatches = ok);
  }

  void _goToStep2() {
    if (!_confirmMatches) return;
    FocusScope.of(context).unfocus();
    setState(() => _step2 = true);
  }

  Future<void> _onDigit(int d) async {
    if (_verifying || PinService.isLocked()) return;
    if (_digits.length >= PinService.pinLength) return;
    setState(() => _digits.add(d));
    HapticFeedback.selectionClick();
    if (_digits.length == PinService.pinLength) {
      await _verify();
    }
  }

  void _onBackspace() {
    if (_verifying || PinService.isLocked()) return;
    if (_digits.isEmpty) return;
    setState(() => _digits.removeLast());
    HapticFeedback.selectionClick();
  }

  Future<void> _verify() async {
    setState(() => _verifying = true);
    final pin = _digits.join();
    final ok = await PinService.verifyPIN(pin);
    if (!mounted) return;
    if (ok) {
      await PinService.clearPIN();
      if (!mounted) return;
      AppSnack.success(context, context.l10n.pinRemoved);
      context.pop(true);
      return;
    }
    HapticFeedback.heavyImpact();
    await _shake.forward(from: 0);
    if (!mounted) return;
    setState(() {
      _digits.clear();
      _verifying = false;
    });
    if (PinService.isLocked() && mounted) {
      AppSnack.warning(context, context.l10n.ownerPinLocked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AppScaffold(
      shopId: widget.shopId,
      title: l.pinDelete,
      isRootPage: false,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _WarningBanner(message: l.pinDeleteWarning),
              const SizedBox(height: 20),
              _StepConfirm(
                controller: _confirmCtrl,
                keyword: _confirmKeyword,
                matches: _confirmMatches,
                locked: _step2,
                onContinue: _goToStep2,
              ),
              if (_step2) ...[
                const SizedBox(height: 24),
                _StepPin(
                  digits: _digits,
                  shake: _shake,
                  verifying: _verifying,
                  onDigit: _onDigit,
                  onBackspace: _onBackspace,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Bandeau d'avertissement ─────────────────────────────────────────────────

class _WarningBanner extends StatelessWidget {
  final String message;
  const _WarningBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.danger.withValues(alpha: 0.08),
        border: Border.all(color: semantic.danger.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: semantic.danger.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.warning_amber_rounded,
                color: semantic.danger, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Étape 1 : confirmation textuelle ────────────────────────────────────────

class _StepConfirm extends StatelessWidget {
  final TextEditingController controller;
  final String keyword;
  final bool matches;
  final bool locked;
  final VoidCallback onContinue;
  const _StepConfirm({
    required this.controller,
    required this.keyword,
    required this.matches,
    required this.locked,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final semantic = Theme.of(context).semantic;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepHeader(
            index: 1,
            title: l.dangerConfirmTypeToConfirm(keyword),
            done: locked,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            enabled: !locked,
            autofocus: !locked,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: l.dangerConfirmInputHint,
              isDense: true,
              suffixIcon: matches
                  ? Icon(Icons.check_circle_rounded,
                      color: semantic.success, size: 20)
                  : null,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (matches && !locked) ? onContinue : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: semantic.danger,
                foregroundColor: Colors.white,
                disabledBackgroundColor:
                    semantic.danger.withValues(alpha: 0.35),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: Text(
                locked ? l.dangerConfirmConfirm : 'Continuer',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Étape 2 : pavé PIN inline ───────────────────────────────────────────────

class _StepPin extends StatelessWidget {
  final List<int> digits;
  final AnimationController shake;
  final bool verifying;
  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;
  const _StepPin({
    required this.digits,
    required this.shake,
    required this.verifying,
    required this.onDigit,
    required this.onBackspace,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final locked = PinService.isLocked();
    final lockUntil = PinService.lockUntil();
    final attemptsLeft = PinService.attemptsRemaining();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepHeader(index: 2, title: l.ownerPinSubtitle, done: false),
          const SizedBox(height: 18),
          _Dots(filled: digits.length, total: PinService.pinLength,
              shake: shake),
          const SizedBox(height: 14),
          if (locked && lockUntil != null)
            _LockedBanner(until: lockUntil)
          else
            Center(
              child: Text(
                l.ownerPinAttemptsRemaining(attemptsLeft),
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
          const SizedBox(height: 18),
          _Keypad(
            enabled: !verifying && !locked,
            onDigit: onDigit,
            onBackspace: onBackspace,
          ),
        ],
      ),
    );
  }
}

// ─── Sous-widgets visuels ────────────────────────────────────────────────────

class _StepHeader extends StatelessWidget {
  final int index;
  final String title;
  final bool done;
  const _StepHeader({
    required this.index,
    required this.title,
    required this.done,
  });

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    final color = done ? semantic.success : AppColors.error;
    return Row(children: [
      Container(
        width: 24, height: 24,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: done
              ? Icon(Icons.check_rounded, size: 14, color: color)
              : Text('$index',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: color)),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(title,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary)),
      ),
    ]);
  }
}

class _Dots extends StatelessWidget {
  final int filled;
  final int total;
  final AnimationController shake;
  const _Dots({
    required this.filled,
    required this.total,
    required this.shake,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = theme.semantic;
    return AnimatedBuilder(
      animation: shake,
      builder: (_, child) {
        final t = shake.value;
        final dx = (t == 0)
            ? 0.0
            : 8.0 *
                (1 - t) *
                (((t * 4 * 3.14159).remainder(2 * 3.14159) < 3.14159)
                    ? 1
                    : -1);
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
        const SizedBox(height: 10),
        _row(context, [4, 5, 6]),
        const SizedBox(height: 10),
        _row(context, [7, 8, 9]),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 64, height: 56),
            const SizedBox(width: 12),
            _Key(label: '0', enabled: enabled, onTap: () => onDigit(0)),
            const SizedBox(width: 12),
            _Key.icon(
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
            _Key(
              label: '${ds[i]}',
              enabled: enabled,
              onTap: () => onDigit(ds[i]),
            ),
          ],
        ],
      );
}

class _Key extends StatelessWidget {
  final String? label;
  final IconData? iconData;
  final bool enabled;
  final VoidCallback onTap;

  const _Key({
    required this.label,
    required this.enabled,
    required this.onTap,
  }) : iconData = null;

  const _Key.icon({
    required IconData icon,
    required this.enabled,
    required this.onTap,
  })  : label = null,
        iconData = icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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

class _LockedBanner extends StatelessWidget {
  final DateTime until;
  const _LockedBanner({required this.until});

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    final l10n = AppLocalizations.of(context)!;
    final remain = until.difference(DateTime.now());
    final minutes = remain.inMinutes < 1 ? 1 : remain.inMinutes;

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
          Icon(Icons.lock_clock_rounded, size: 14, color: semantic.danger),
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
