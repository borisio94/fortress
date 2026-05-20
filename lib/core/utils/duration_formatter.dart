/// Helpers de formatage de durée pour l'UI alertes.
///
/// Utilisés par la modale + le banner de commandes programmées pour afficher
/// un compteur live cohérent ("dans 1h 47min", "dans 12min", "depuis 5min").
class DurationFormatter {
  DurationFormatter._();

  /// Formate `delta` en chaîne courte sans signe ni préfixe :
  ///   * `≥ 1h`   → "Xh Ymin"   (ex: "1h 47min", "3h 0min")
  ///   * `< 1h`   → "Xmin"      (ex: "47min", "1min")
  ///   * `< 1min` → "<1min"     (évite "0min" trompeur)
  ///
  /// **Toujours non-négatif** : utilise `delta.abs()` au cas où l'appelant
  /// passe une durée négative. Le signe / la formulation ("dans" vs
  /// "depuis") est la responsabilité du caller via `i18n.scheduledAlert*`.
  static String compact(Duration delta) {
    final secs = delta.abs().inSeconds;
    if (secs < 60) return '<1min';
    final totalMin = secs ~/ 60;
    if (totalMin < 60) return '${totalMin}min';
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    return '${h}h ${m}min';
  }
}
