import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import 'form_sheet.dart';

/// Bottom sheet de confirmation réutilisable.
/// Remplace tous les AlertDialog Yes/No identiques dans l'app.
///
/// Le nom de la classe est conservé (`AppConfirmDialog`) pour ne pas
/// casser les call sites — mais l'implémentation est désormais un bottom
/// sheet verrouillé (cf. showFormSheet) avec bouton X intégré.
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
  }) =>
      showFormSheet<bool>(
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
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FormSheetHeader(
              title: title,
              icon: icon,
              iconColor: color,
            ),
            const Divider(height: 1, color: Color(0xFFF0F0F0)),
            if (body != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Align(
                    alignment: Alignment.centerLeft, child: body!),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  20, body != null ? 16 : 14, 20, 14),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      foregroundColor: const Color(0xFF6B7280),
                    ),
                    child: Text(cancelLabel),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: confirmColor ?? AppColors.error,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () async {
                      Navigator.of(context).pop(true);
                      final result = onConfirm();
                      if (result is Future) await result;
                    },
                    child: Text(confirmLabel),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
