import 'package:flutter/material.dart';
import '../../core/storage/hive_boxes.dart';
import '../../core/theme/app_colors.dart';

/// Bouton flottant **draggable** (déplaçable au doigt) — l'utilisateur peut
/// le repositionner s'il masque un élément du contenu. La position est
/// persistée dans Hive (clé `draggable_fab_<storageKey>`) pour rester là
/// au prochain accès à la page.
///
/// Style : icône au centre dans un carré aux coins arrondis, fond
/// `AppColors.primary` à 55 % d'opacité (laisse voir ce qui est derrière).
///
/// Usage typique :
/// ```dart
/// AppScaffold(
///   shopId: shopId,
///   title: '...',
///   body: DraggableFabContainer(
///     storageKey: 'inventaire',
///     onTap: _addProduct,
///     tooltip: 'Ajouter un produit',
///     child: ListView(...),
///   ),
/// );
/// ```
class DraggableFabContainer extends StatefulWidget {
  /// Contenu de la page (la liste, le formulaire, etc.) — rendu en
  /// dessous du FAB. Le FAB flotte par-dessus.
  final Widget child;
  /// Callback du tap (rapide — ne se déclenche pas si l'utilisateur
  /// drag).
  final VoidCallback onTap;
  /// Icône affichée au centre du bouton.
  final IconData icon;
  /// Clé unique par page pour persister la position. Ex: `'inventaire'`,
  /// `'clients'`. Si vide, la position n'est pas persistée.
  final String storageKey;
  /// Tooltip optionnel (long-press sur mobile, hover sur desktop).
  final String? tooltip;
  /// Taille du bouton. Par défaut 56×56 (taille FAB Material standard).
  final double size;

  const DraggableFabContainer({
    super.key,
    required this.child,
    required this.onTap,
    this.icon = Icons.add_rounded,
    required this.storageKey,
    this.tooltip,
    this.size = 56,
  });

  @override
  State<DraggableFabContainer> createState() =>
      _DraggableFabContainerState();
}

class _DraggableFabContainerState extends State<DraggableFabContainer> {
  /// Position courante. `null` = utiliser la position par défaut
  /// (bottom-right) lors du 1ᵉʳ build.
  Offset? _position;

  String get _hiveKey => 'draggable_fab_${widget.storageKey}';

  @override
  void initState() {
    super.initState();
    _loadPosition();
  }

  void _loadPosition() {
    if (widget.storageKey.isEmpty) return;
    try {
      final raw = HiveBoxes.settingsBox.get(_hiveKey);
      if (raw is Map) {
        final dx = (raw['dx'] as num?)?.toDouble();
        final dy = (raw['dy'] as num?)?.toDouble();
        if (dx != null && dy != null) {
          _position = Offset(dx, dy);
        }
      }
    } catch (_) {/* fail silent — position revient au défaut */}
  }

  void _savePosition(Offset pos) {
    if (widget.storageKey.isEmpty) return;
    try {
      HiveBoxes.settingsBox.put(_hiveKey, {'dx': pos.dx, 'dy': pos.dy});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      // Position par défaut : coin bottom-right avec marge 16 px.
      final defaultPos = Offset(
        constraints.maxWidth  - widget.size - 16,
        constraints.maxHeight - widget.size - 16,
      );
      final pos = _position ?? defaultPos;
      // Clamp pour s'assurer que le FAB reste visible quand l'écran
      // change de taille (rotation, redimensionnement web).
      final clamped = Offset(
        pos.dx.clamp(0.0, constraints.maxWidth  - widget.size),
        pos.dy.clamp(0.0, constraints.maxHeight - widget.size),
      );
      return Stack(children: [
        widget.child,
        Positioned(
          left: clamped.dx,
          top:  clamped.dy,
          child: _DraggableFabButton(
            icon: widget.icon,
            size: widget.size,
            tooltip: widget.tooltip,
            onTap: widget.onTap,
            onDrag: (delta) {
              setState(() {
                final next = Offset(
                  (clamped.dx + delta.dx).clamp(
                      0.0, constraints.maxWidth  - widget.size),
                  (clamped.dy + delta.dy).clamp(
                      0.0, constraints.maxHeight - widget.size),
                );
                _position = next;
              });
            },
            onDragEnd: () {
              if (_position != null) _savePosition(_position!);
            },
          ),
        ),
      ]);
    });
  }
}

/// Le bouton lui-même — séparé pour clarté, pas exposé en dehors.
class _DraggableFabButton extends StatelessWidget {
  final IconData         icon;
  final double           size;
  final String?          tooltip;
  final VoidCallback     onTap;
  final ValueChanged<Offset> onDrag;
  final VoidCallback     onDragEnd;
  const _DraggableFabButton({
    required this.icon,
    required this.size,
    required this.onTap,
    required this.onDrag,
    required this.onDragEnd,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final btn = GestureDetector(
      onPanUpdate: (d) => onDrag(d.delta),
      onPanEnd:    (_) => onDragEnd(),
      onTap: onTap,
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(
          // Background primary à 55 % — on voit le contenu derrière.
          color: AppColors.primary.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(icon, size: size * 0.5, color: Colors.white),
      ),
    );
    return tooltip != null
        ? Tooltip(message: tooltip!, child: btn)
        : btn;
  }
}
