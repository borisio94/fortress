import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Calque « repère de tap » pour le mode démo / enregistrement d'écran.
///
/// Quand [enabled] est vrai, écoute CHAQUE appui (au niveau des événements
/// pointeur bruts, donc sur tous les éléments : boutons, listes, dialogues,
/// zones vides…) et dessine un cercle qui s'agrandit puis s'efface, EXACTEMENT
/// à l'endroit touché. Observateur passif : il n'absorbe pas le tap, l'app
/// fonctionne normalement. Désactivé : passe-plat (zéro surcoût).
class DemoTapIndicator extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final Color color;
  const DemoTapIndicator({
    super.key,
    required this.child,
    required this.enabled,
    required this.color,
  });

  @override
  State<DemoTapIndicator> createState() => _DemoTapIndicatorState();
}

class _DemoTapIndicatorState extends State<DemoTapIndicator>
    with SingleTickerProviderStateMixin {
  static const Duration _ringDuration = Duration(milliseconds: 700);
  // Déplacement max (px) toléré pour considérer un appui comme un TAP. Au-delà,
  // c'est un scroll / glissement → aucun cercle.
  static const double _moveSlop = 14.0;

  final List<_Tap> _taps = [];
  // Appuis en cours : pointerId → position initiale + a-t-il bougé ?
  final Map<int, _Pending> _pending = {};
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    final now = DateTime.now();
    _taps.removeWhere((t) => now.difference(t.at) >= _ringDuration);
    if (_taps.isEmpty) _ticker.stop();
    if (mounted) setState(() {});
  }

  void _onPointerDown(PointerDownEvent e) {
    if (!widget.enabled) return;
    _pending[e.pointer] = _Pending(e.localPosition);
  }

  void _onPointerMove(PointerMoveEvent e) {
    final p = _pending[e.pointer];
    if (p == null || p.moved) return;
    if ((e.localPosition - p.downPos).distance > _moveSlop) {
      p.moved = true; // devient un scroll → ne marquera pas de tap
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final p = _pending.remove(e.pointer);
    if (p == null || p.moved) return; // scroll/glissement → ignoré
    // Vrai tap : cercle à l'endroit de l'appui, au relâchement.
    _taps.add(_Tap(p.downPos, DateTime.now()));
    if (!_ticker.isActive) _ticker.start();
    if (mounted) setState(() {});
  }

  void _onPointerCancel(PointerCancelEvent e) => _pending.remove(e.pointer);

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _TapPainter(_taps, widget.color, _ringDuration),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tap {
  final Offset pos;
  final DateTime at;
  _Tap(this.pos, this.at);
}

/// Appui en cours : sert à distinguer un TAP d'un SCROLL (a-t-il bougé ?).
class _Pending {
  final Offset downPos;
  bool moved = false;
  _Pending(this.downPos);
}

class _TapPainter extends CustomPainter {
  final List<_Tap> taps;
  final Color color;
  final Duration duration;
  _TapPainter(this.taps, this.color, this.duration);

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    final totalMs = duration.inMilliseconds;
    for (final tap in taps) {
      final ms = now.difference(tap.at).inMilliseconds;
      final t = (ms / totalMs).clamp(0.0, 1.0);
      final ease = Curves.easeOut.transform(t);
      final radius = 14.0 + 38.0 * ease; // s'agrandit
      final op = (1.0 - t); // s'efface

      // Disque tendre au centre (point de contact).
      canvas.drawCircle(
        tap.pos,
        radius * 0.45,
        Paint()..color = color.withValues(alpha: 0.22 * op),
      );
      // Liseré blanc (contraste sur fonds colorés) juste sous l'anneau.
      canvas.drawCircle(
        tap.pos,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..color = Colors.white.withValues(alpha: 0.55 * op),
      );
      // Anneau coloré principal.
      canvas.drawCircle(
        tap.pos,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = color.withValues(alpha: 0.95 * op),
      );
    }
  }

  @override
  bool shouldRepaint(_TapPainter oldDelegate) => true;
}
