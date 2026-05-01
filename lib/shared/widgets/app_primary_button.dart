import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AppPrimaryButton — bouton principal de l'app (pleine largeur)
//
// Remplace : _CreateBtn (create_shop), _SignInBtn (login),
//            _CreateBtn (register), _CreateBtn (product_form)
//
// Toujours : fond sombre #0F172A, hover violet, disabled gris
// ─────────────────────────────────────────────────────────────────────────────

class AppPrimaryButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool isLoading;
  final bool enabled;
  final VoidCallback onTap;
  final double height;
  final Color? color;

  const AppPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.isLoading = false,
    this.enabled = true,
    required this.onTap,
    this.height = 43,
    this.color,
  });

  @override
  State<AppPrimaryButton> createState() => _AppPrimaryButtonState();
}

class _AppPrimaryButtonState extends State<AppPrimaryButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && !widget.isLoading;
    final base   = widget.color ?? const Color(0xFF0F172A);
    final hover  = widget.color ?? AppColors.primary;

    return MouseRegion(
      onEnter: (_) { if (active) setState(() => _hovered = true); },
      onExit:  (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        height: widget.height,
        decoration: BoxDecoration(
          color: !active
              ? const Color(0xFFCBD5E1)
              : _hovered ? hover : base,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: active ? widget.onTap : null,
            borderRadius: BorderRadius.circular(8),
            child: Center(
              child: widget.isLoading
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.icon != null) ...[
                          Icon(widget.icon, size: 16, color: Colors.white),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          widget.label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: active
                                ? Colors.white
                                : Colors.white.withOpacity(0.6),
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Bouton icon badge (AppBar) ───────────────────────────────────────────────

class AppIconBadge extends StatelessWidget {
  final IconData icon;
  final int count;
  final VoidCallback onTap;
  final String? tooltip;

  const AppIconBadge({
    super.key,
    required this.icon,
    this.count = 0,
    required this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(icon, size: 22, color: const Color(0xFF374151)),
            if (count > 0)
              Positioned(
                top: -4, right: -4,
                child: Container(
                  constraints:
                      const BoxConstraints(minWidth: 16, minHeight: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: AppColors.error,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    style: const TextStyle(
                        fontSize: 9,
                        color: Colors.white,
                        fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    if (tooltip != null) return Tooltip(message: tooltip!, child: btn);
    return btn;
  }
}

// ─── Bouton icon dans un container (shop_list, create_shop) ──────────────────

class AppOutlineIconButton extends StatelessWidget {
  final IconData icon;
  final String? tooltip;
  final VoidCallback onTap;

  const AppOutlineIconButton({
    super.key,
    required this.icon,
    this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Icon(icon, size: 18, color: const Color(0xFF374151)),
      ),
    );
    if (tooltip != null) return Tooltip(message: tooltip!, child: btn);
    return btn;
  }
}
