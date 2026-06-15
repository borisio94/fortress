import 'package:flutter/widgets.dart';

/// ════════════════════════════════════════════════════════════════════════
/// TOKENS DE DIMENSION FORTRESS — espacements & rayons, source unique.
///
/// Pendant des 7 échelons de `AppTextStyles` mais pour l'espace et les coins.
/// Objectif : supprimer les valeurs magiques dispersées (4, 6, 8, 10, 12, 14,
/// 16, 20, 24…) qui rendent la densité et les rayons « bricolés » d'un écran
/// à l'autre. On choisit le token le plus proche du besoin.
///
/// Échelle d'espacement = grille 4-pt (multiples de 4), alignée sur l'usage
/// déjà majoritaire du repo.
/// ════════════════════════════════════════════════════════════════════════
class AppSpacing {
  AppSpacing._();

  static const double xxs  = 2;
  static const double xs   = 4;
  static const double sm   = 8;
  static const double md   = 12;
  static const double lg   = 16;
  static const double xl   = 20;
  static const double xxl  = 24;
  static const double xxxl = 32;
}

/// Rayons de bordure canoniques — alignent inputs / boutons / puces / cards /
/// dialogues / bottom-sheets. Le thème (`app_theme.dart`) utilise déjà
/// 12 (inputs/boutons), 16 (cards/dialogues), 20 (sheets) : ces tokens les
/// nomment pour que les widgets feature s'y calent au lieu de réinventer.
class AppRadius {
  AppRadius._();

  static const double xs   = 6;   // micro-éléments
  static const double sm   = 8;   // inputs, petits boutons, puces compactes
  static const double md   = 12;  // boutons, cards compactes
  static const double lg   = 16;  // cards, dialogues
  static const double xl   = 20;  // bottom sheets
  static const double pill = 999; // chips / pills arrondis

  // Raccourcis BorderRadius prêts à l'emploi (évite `BorderRadius.circular(x)`).
  static const BorderRadius smR   = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdR   = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgR   = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlR   = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillR = BorderRadius.all(Radius.circular(pill));
}
