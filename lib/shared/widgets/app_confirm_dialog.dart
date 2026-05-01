import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Dialog de confirmation réutilisable
/// Remplace tous les AlertDialog inline identiques dans l'app
class AppConfirmDialog extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final Widget? body;
  final String cancelLabel;
  final String confirmLabel;
  final Color? confirmColor;
  final dynamic Function() onConfirm;

  const AppConfirmDialog({
    super.key,
    required this.icon,
    this.iconColor,
    required this.title,
    this.body,
    required this.cancelLabel,
    required this.confirmLabel,
    this.confirmColor,
    required this.onConfirm,
  });

  static Future<bool?> show({
    required BuildContext context,
    required IconData icon,
    Color? iconColor,
    required String title,
    Widget? body,
    required String cancelLabel,
    required String confirmLabel,
    Color? confirmColor,
    required dynamic Function() onConfirm,
  }) => showDialog<bool>(
    context: context,
    builder: (_) => AppConfirmDialog(
      icon: icon, iconColor: iconColor, title: title, body: body,
      cancelLabel: cancelLabel, confirmLabel: confirmLabel,
      confirmColor: confirmColor, onConfirm: onConfirm,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final color = iconColor ?? AppColors.error;
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      actionsPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      title: Row(children: [
        Container(width: 28, height: 28,
            decoration: BoxDecoration(
                color: color.withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(icon, size: 14, color: color)),
        const SizedBox(width: 8),
        Expanded(child: Text(title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
      ]),
      content: body,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF6B7280),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
          child: Text(cancelLabel),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: confirmColor ?? AppColors.error,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              elevation: 0,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: () async {
            Navigator.of(context).pop(true);
            final result = onConfirm();
            if (result is Future) await result;
          },
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}