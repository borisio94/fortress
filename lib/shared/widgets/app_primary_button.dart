import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/theme/app_theme.dart';

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
  /// `true` → pleine largeur + hauteur fixe [height] (ancien comportement,
  /// ex. bouton de connexion). `false` (défaut) → dimensionné au contenu avec
  /// padding compact H10/V3 (demande utilisateur : boutons proportionnels).
  final bool fullWidth;

  const AppPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.isLoading = false,
    this.enabled = true,
    required this.onTap,
    this.height = 43,
    this.color,
    this.fullWidth = false,
  });

  @override
  State<AppPrimaryButton> createState() => _AppPrimaryButtonState();
}

class _AppPrimaryButtonState extends State<AppPrimaryButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && !widget.isLoading;
    // En clair : fond sombre signature (#0F172A). En sombre, ce navy serait
    // quasi invisible sur le scaffold slate → on bascule sur la couleur
    // primaire de la palette (lisible sur fond sombre).
    final base   = widget.color ??
        (AppColors.isDark ? AppColors.primary : const Color(0xFF0F172A));
    final hover  = widget.color ?? AppColors.primary;

    final fw = widget.fullWidth;
    final label = Text(
      widget.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: AppTextStyles.label.copyWith(
        color: active ? Colors.white : Colors.white.withValues(alpha: 0.6),
        letterSpacing: 0.3,
      ),
    );
    final content = widget.isLoading
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
              // En pleine largeur le label peut déborder → Flexible+ellipsis.
              // En taille contenu, le bouton épouse le texte (pas de Flexible,
              // sinon contrainte de largeur non bornée).
              fw ? Flexible(child: label) : label,
            ],
          );

    return MouseRegion(
      onEnter: (_) { if (active) setState(() => _hovered = true); },
      onExit:  (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: fw ? double.infinity : null,
        height: fw ? widget.height : null,
        decoration: BoxDecoration(
          color: !active
              ? (AppColors.isDark
                  ? const Color(0xFF475569)   // slate-600 lisible en sombre
                  : const Color(0xFFCBD5E1))
              : _hovered ? hover : base,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: active ? widget.onTap : null,
            borderRadius: BorderRadius.circular(8),
            child: fw
                ? Center(child: content)
                : Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 3),
                    child: content,
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

  /// Rendu en POINT plutôt qu'en compteur — `false` par défaut : rien ne
  /// change pour les appelants existants (e-commerce, panier).
  ///
  /// Un « 4 » sur fond rouge annonce une erreur ; un point ambre annonce
  /// quelque chose à voir, et le compte exact se lit en ouvrant. Utilisé par
  /// les notifications du restaurant.
  ///
  /// Point `warning` CERCLÉ de `warningText` : l'ambre seul ne fait que
  /// 2,15:1 sur blanc, sous le seuil de 3:1 d'un signal non textuel, et c'est
  /// ce point qui porte seul l'information. Le cercle (7:1) lui donne un bord
  /// net sans inventer de couleur. En sombre, l'ambre passe seul (8,8:1).
  final bool dot;

  const AppIconBadge({
    super.key,
    required this.icon,
    this.count = 0,
    required this.onTap,
    this.tooltip,
    this.dot = false,
  });

  @override
  Widget build(BuildContext context) {
    // Suit la couleur de l'IconTheme ambiant (AppBar.actionsIconTheme en mobile,
    // IconButtonTheme/onSurface en desktop) pour rester cohérent avec le
    // hamburger / back button.
    final iconColor = IconTheme.of(context).color
        ?? Theme.of(context).colorScheme.onSurface;
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(icon, size: 22, color: iconColor),
            if (count > 0 && dot)
              Positioned(
                top: -1, right: -1,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: Theme.of(context).semantic.warning,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: Theme.of(context).semantic.warningText,
                        width: 1.5),
                  ),
                ),
              )
            else if (count > 0)
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
                    style: AppTextStyles.micro.copyWith(
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
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).semantic.borderSubtle),
        ),
        child: Icon(icon, size: 18,
            color: Theme.of(context).colorScheme.onSurface),
      ),
    );
    if (tooltip != null) return Tooltip(message: tooltip!, child: btn);
    return btn;
  }
}
