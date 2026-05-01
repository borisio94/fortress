import 'package:flutter/material.dart';

/// Niveau de force d'un mot de passe.
///
/// Mapping couleur :
/// - [weak]       → rouge   (mauvais)
/// - [acceptable] → orange  (acceptable)
/// - [strong]     → vert    (bon)
enum PasswordStrengthLevel { empty, weak, acceptable, strong }

class PasswordStrength {
  /// Score brut 0-100. Sert à dimensionner la barre de progression.
  final int score;
  final PasswordStrengthLevel level;

  const PasswordStrength({required this.score, required this.level});

  static const empty = PasswordStrength(
      score: 0, level: PasswordStrengthLevel.empty);
}

/// Politique unique de mot de passe utilisée partout dans l'app
/// (register, forgot password, employee creation, profil).
///
/// Critères pondérés :
///   - longueur ≥ 8       → +25
///   - longueur ≥ 12      → +15 (bonus cumulable)
///   - 1 majuscule        → +15
///   - 1 minuscule        → +10
///   - 1 chiffre          → +15
///   - 1 caractère spécial → +20
///
/// Paliers :
///   < 40   → weak       (rouge)
///   40-69  → acceptable (orange)
///   ≥ 70   → strong     (vert)
class PasswordPolicy {
  /// Longueur minimale absolue pour pouvoir soumettre le formulaire,
  /// indépendamment du score.
  static const int minLength = 8;

  /// Calcule le score et le niveau du mot de passe.
  static PasswordStrength evaluate(String password) {
    if (password.isEmpty) return PasswordStrength.empty;

    var score = 0;
    if (password.length >= 8) score += 25;
    if (password.length >= 12) score += 15;
    if (RegExp(r'[A-Z]').hasMatch(password)) score += 15;
    if (RegExp(r'[a-z]').hasMatch(password)) score += 10;
    if (RegExp(r'[0-9]').hasMatch(password)) score += 15;
    if (RegExp(r'''[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\\/`~';]''')
        .hasMatch(password)) score += 20;

    final level = score < 40
        ? PasswordStrengthLevel.weak
        : (score < 70
            ? PasswordStrengthLevel.acceptable
            : PasswordStrengthLevel.strong);

    return PasswordStrength(score: score.clamp(0, 100), level: level);
  }

  /// Retourne un message d'erreur si le mot de passe ne satisfait pas
  /// les exigences minimales pour soumettre. Null si OK.
  ///
  /// Note : on accepte un mot de passe "weak" (score < 40) tant qu'il
  /// satisfait la longueur minimale — on prévient juste l'utilisateur
  /// via la barre. Refuser tout en-dessous de "acceptable" serait trop
  /// strict pour les comptes existants.
  static String? validate(String password) {
    if (password.isEmpty) return 'Mot de passe requis';
    if (password.length < minLength) {
      return 'Minimum $minLength caractères';
    }
    return null;
  }

  /// Variante plus stricte (super admins, comptes sensibles) :
  /// exige au minimum le niveau acceptable.
  static String? validateStrict(String password) {
    final base = validate(password);
    if (base != null) return base;
    final s = evaluate(password);
    if (s.level == PasswordStrengthLevel.weak) {
      return 'Mot de passe trop faible — ajoutez majuscule, chiffre, caractère spécial';
    }
    return null;
  }
}

/// Couleurs canoniques pour l'affichage de la force.
/// Utilise le thème si disponible, sinon des constantes raisonnables.
class PasswordStrengthColors {
  final Color weak;
  final Color acceptable;
  final Color strong;
  final Color empty;

  const PasswordStrengthColors({
    required this.weak,
    required this.acceptable,
    required this.strong,
    required this.empty,
  });

  /// Palette par défaut alignée avec AppColors.
  factory PasswordStrengthColors.fallback() => const PasswordStrengthColors(
        weak: Color(0xFFEF4444), // rouge
        acceptable: Color(0xFFF59E0B), // orange
        strong: Color(0xFF10B981), // vert
        empty: Color(0xFFE5E7EB),
      );

  Color colorFor(PasswordStrengthLevel level) {
    switch (level) {
      case PasswordStrengthLevel.weak:
        return weak;
      case PasswordStrengthLevel.acceptable:
        return acceptable;
      case PasswordStrengthLevel.strong:
        return strong;
      case PasswordStrengthLevel.empty:
        return empty;
    }
  }
}

/// Libellés FR pour les niveaux. Centralisés pour éviter la duplication.
String passwordStrengthLabelFr(PasswordStrengthLevel level) {
  switch (level) {
    case PasswordStrengthLevel.weak:
      return 'Mauvais';
    case PasswordStrengthLevel.acceptable:
      return 'Acceptable';
    case PasswordStrengthLevel.strong:
      return 'Bon';
    case PasswordStrengthLevel.empty:
      return '';
  }
}
