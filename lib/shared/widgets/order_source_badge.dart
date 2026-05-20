import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/theme/app_text_styles.dart';

/// Badge visuel discret indiquant l'origine d'une commande (`source` =
/// `'pos'` | `'web'` | `'whatsapp'`).
///
/// • `pos` (défaut) → ne rend RIEN (canal historique, on évite le bruit
///   visuel sur les milliers de commandes existantes).
/// • `web` → pastille teal avec icône globe.
/// • `whatsapp` → pastille verte WhatsApp.
///
/// Composant volontairement léger et stateless. Tooltip i18n.
class OrderSourceBadge extends StatelessWidget {
  final String source;
  final double scale;

  const OrderSourceBadge({
    super.key,
    required this.source,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (source == 'web') {
      return _Pill(
        label:   l.orderSourceBadgeWeb,
        icon:    Icons.public_rounded,
        color:   const Color(0xFF0EA5E9),
        tooltip: l.orderSourceWebTooltip,
        scale:   scale,
      );
    }
    if (source == 'whatsapp') {
      return _Pill(
        label:   l.orderSourceBadgeWhatsApp,
        icon:    Icons.chat_rounded,
        color:   const Color(0xFF25D366),
        tooltip: l.orderSourceWhatsAppTooltip,
        scale:   scale,
      );
    }
    return const SizedBox.shrink();
  }
}

class _Pill extends StatelessWidget {
  final String   label;
  final IconData icon;
  final Color    color;
  final String   tooltip;
  final double   scale;
  const _Pill({
    required this.label,
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: 6 * scale, vertical: 2 * scale),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10 * scale),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10 * scale, color: color),
            SizedBox(width: 3 * scale),
            Text(label,
                style: AppTextStyles.micro.copyWith(
                    fontSize: 9 * scale,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                    color: color)),
          ],
        ),
      ),
    );
  }
}
