import 'package:flutter/material.dart';
import '../../core/theme/app_text_styles.dart';

/// Affiche un bottom sheet de **formulaire** verrouillé : ne se ferme pas
/// par tap-outside ni par swipe-down. La seule façon de le fermer est de
/// taper sur le bouton X (cf. [FormSheetHeader]) ou via `Navigator.pop`.
///
/// Évite les pertes de saisie accidentelles sur les formulaires longs
/// (ClientFormSheet, ProductForm, etc.).
Future<T?> showFormSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  Color? backgroundColor,
  ShapeBorder? shape,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: backgroundColor ?? Colors.white,
    shape: shape ??
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
    builder: builder,
  );
}

/// Header standard pour les formulaires modaux : titre à gauche +
/// IconButton X aligné à droite. À placer en première position dans la
/// `Column` du sheet/dialog.
///
/// Pour les sheets multi-step où chaque étape a son propre titre, passer
/// `title` dynamiquement et `subtitle` pour l'indicateur d'étape.
class FormSheetHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onClose;
  final IconData? icon;
  final Color? iconColor;
  /// Actions optionnelles affichées à gauche du bouton X (ex: bouton
  /// supprimer en mode édition). Le X reste toujours en dernière position.
  final List<Widget>? trailing;

  const FormSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onClose,
    this.icon,
    this.iconColor,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(children: [
        if (icon != null) ...[
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: (iconColor ?? theme.colorScheme.primary).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: iconColor ?? theme.colorScheme.primary),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: AppTextStyles.label.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: AppTextStyles.caption.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...trailing!,
        // Bouton fermer compact (36×36) — l'IconButton Material standard
        // fait 48×48 et peut être poussé hors écran sur mobile étroit.
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onClose ?? () => Navigator.of(context).pop(),
          child: Container(
            width: 36, height: 36,
            alignment: Alignment.center,
            child: Icon(Icons.close_rounded,
                size: 22,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
          ),
        ),
      ]),
    );
  }
}
