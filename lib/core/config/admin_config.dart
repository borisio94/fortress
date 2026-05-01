// ─── Configuration administrative ──────────────────────────────────────────
//
// Placeholder pour les paramètres admin qui ne dépendent pas du runtime
// (numéro de support, URL d'aide, etc.). À migrer plus tard vers une table
// `app_config` Supabase pour pouvoir les modifier sans redéploiement.
// ───────────────────────────────────────────────────────────────────────────

class AdminConfig {
  /// Numéro WhatsApp du support pour activer un abonnement.
  /// Format E.164 sans `+` ni espaces (requis par https://wa.me/).
  /// → À remplacer par le vrai numéro avant production.
  /// Exemple : '237600000000' pour +237 600 000 000.
  static const String whatsappAdminNumber = '237600000000';

  /// True tant que le numéro ci-dessus est un placeholder.
  /// Permet à l'UI d'afficher un avertissement temporaire si besoin.
  static bool get isWhatsappPlaceholder =>
      whatsappAdminNumber == '237600000000';
}
