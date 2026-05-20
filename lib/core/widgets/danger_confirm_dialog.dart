import 'package:flutter/material.dart';

import '../../shared/widgets/adaptive_form_frame.dart';
import '../i18n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Dialogue de confirmation pour les actions destructives.
///
/// Force l'utilisateur à saisir manuellement [confirmText] (nom de l'objet à
/// supprimer, par ex.) pour activer le bouton de confirmation. La comparaison
/// est insensible à la casse et aux espaces de bord.
///
/// 100% piloté par le thème : aucune couleur hex hardcodée. Toutes les
/// couleurs viennent de `Theme.of(context).semantic` ou du `ColorScheme`.
class DangerConfirmDialog extends StatefulWidget {
  final String title;
  final String description;
  final List<String> consequences;
  final String confirmText;
  final VoidCallback onConfirmed;

  const DangerConfirmDialog({
    super.key,
    required this.title,
    required this.description,
    required this.consequences,
    required this.confirmText,
    required this.onConfirmed,
  });

  /// Helper pour afficher le sheet. Renvoie `true` si confirmé,
  /// `false` ou `null` sinon. (Anciennement un AlertDialog ; converti en
  /// bottom sheet verrouillé pour cohérence UX — bouton X intégré, pas de
  /// tap-outside, expérience identique sur mobile et desktop.)
  static Future<bool?> show({
    required BuildContext context,
    required String title,
    required String description,
    required List<String> consequences,
    required String confirmText,
    required VoidCallback onConfirmed,
  }) => showAdaptiveFormSheet<bool>(
        context: context,
        builder: (_) => DangerConfirmDialog(
          title: title,
          description: description,
          consequences: consequences,
          confirmText: confirmText,
          onConfirmed: onConfirmed,
        ),
      );

  @override
  State<DangerConfirmDialog> createState() => _DangerConfirmDialogState();
}

class _DangerConfirmDialogState extends State<DangerConfirmDialog> {
  final _ctrl = TextEditingController();
  bool _matches = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_revalidate);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_revalidate);
    _ctrl.dispose();
    super.dispose();
  }

  void _revalidate() {
    final ok = _ctrl.text.trim().toLowerCase() ==
        widget.confirmText.trim().toLowerCase();
    if (ok != _matches) setState(() => _matches = ok);
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final scheme   = theme.colorScheme;
    final semantic = theme.semantic;
    final l10n     = AppLocalizations.of(context)!;

    return AdaptiveFormFrame(
      title:     widget.title,
      icon:      Icons.warning_amber_rounded,
      iconColor: semantic.danger,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.description,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.6),
                height: 1.45,
              ),
            ),
            if (widget.consequences.isNotEmpty) ...[
              const SizedBox(height: 14),
              _ConsequencesBanner(items: widget.consequences),
            ],
            const SizedBox(height: 14),
            Text(
              l10n.dangerConfirmTypeToConfirm(widget.confirmText),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _ctrl,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: l10n.dangerConfirmInputHint,
                isDense: true,
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                  ),
                  child: Text(l10n.dangerConfirmCancel),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: _matches
                      ? () {
                          Navigator.of(context).pop(true);
                          widget.onConfirmed();
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: semantic.danger,
                    foregroundColor: scheme.onError,
                    disabledBackgroundColor:
                        semantic.danger.withValues(alpha: 0.35),
                    disabledForegroundColor:
                        scheme.onError.withValues(alpha: 0.85),
                    minimumSize: const Size(0, 44),
                  ),
                  child: Text(l10n.dangerConfirmConfirm),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Bandeau listant les conséquences de l'action destructive.
class _ConsequencesBanner extends StatelessWidget {
  final List<String> items;
  const _ConsequencesBanner({required this.items});

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final scheme   = theme.colorScheme;
    final semantic = theme.semantic;
    final l10n     = AppLocalizations.of(context)!;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: semantic.warning.withValues(alpha: 0.10),
        border: Border.all(color: semantic.warning.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.info_outline_rounded,
                size: 14, color: semantic.warning),
            const SizedBox(width: 6),
            Expanded(child: Text(
              l10n.dangerConfirmConsequencesTitle,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: semantic.warning,
                letterSpacing: 0.2,
              ),
            )),
          ]),
          const SizedBox(height: 6),
          ...items.map((c) => Padding(
            padding: const EdgeInsets.only(top: 3, left: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Container(
                    width: 3, height: 3,
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  c,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.75),
                    height: 1.4,
                  ),
                )),
              ],
            ),
          )),
        ],
      ),
    );
  }
}
