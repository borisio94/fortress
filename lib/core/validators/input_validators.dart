import 'password_policy.dart';

/// Validators centralisés pour les formulaires d'authentification et de
/// création/édition d'utilisateur. Une seule source de vérité — toutes les
/// pages doivent passer par ici plutôt que de redéfinir leurs regex.
class InputValidators {
  InputValidators._();

  // ── Email ─────────────────────────────────────────────────────────────────
  /// RFC 5322 simplifié — couvre 99,9 % des cas réels.
  static final RegExp _emailRegex = RegExp(
    r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$',
  );

  static String? email(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Email requis';
    if (!_emailRegex.hasMatch(v)) return 'Email invalide';
    return null;
  }

  // ── Nom ──────────────────────────────────────────────────────────────────
  /// Alphanumérique (toutes langues), espaces, apostrophes, tirets. 2 min.
  /// Les chiffres sont autorisés pour couvrir les noms commerciaux et les
  /// identifiants type "Boutique 2", "Jean-Marc 3".
  static final RegExp _nameRegex =
      RegExp(r"^[a-zA-Z0-9À-ÿĀ-ſ\s'\-]+$");

  static String? name(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Nom requis';
    if (v.length < 2) return 'Nom trop court';
    if (v.length > 60) return 'Nom trop long (60 max)';
    if (!_nameRegex.hasMatch(v)) {
      return 'Caractères non autorisés';
    }
    return null;
  }

  // ── Mot de passe (délègue à PasswordPolicy) ──────────────────────────────
  static String? password(String? value) =>
      PasswordPolicy.validate(value ?? '');

  /// Variante stricte — refuse les mots de passe weak.
  static String? passwordStrict(String? value) =>
      PasswordPolicy.validateStrict(value ?? '');

  // ── Confirmation mot de passe ─────────────────────────────────────────────
  static String? Function(String?) confirmPassword(
      String Function() getOriginal) {
    return (value) {
      final v = value ?? '';
      if (v.isEmpty) return 'Confirmation requise';
      if (v != getOriginal()) return 'Les mots de passe ne correspondent pas';
      return null;
    };
  }
}
