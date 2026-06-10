import 'package:flutter/widgets.dart';

/// Une étape d'un tutoriel guidé, rendue dans une carte modale
/// (cf. `tutorial_overlay.dart` — approche « modal guidé », option A).
@immutable
class TutorialStep {
  final String title;
  final String description;
  final IconData icon;

  const TutorialStep({
    required this.title,
    required this.description,
    required this.icon,
  });
}
