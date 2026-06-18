/// Résultat d'un partage de fiche de livraison (cf. `delivery_share.dart` /
/// `delivery_share_web.dart`). Sert au caller à afficher le bon message.
enum DeliveryShareOutcome {
  /// Image copiée dans le presse-papier (web) → l'utilisateur colle (Ctrl+V)
  /// dans son groupe WhatsApp.
  copied,

  /// Repli : l'image a été téléchargée (navigateur sans accès presse-papier
  /// image) → l'utilisateur l'envoie manuellement dans son groupe.
  downloaded,

  /// Repli mobile/desktop natif : fenêtre de partage native ouverte.
  shared,

  /// Échec total (ni copie, ni téléchargement, ni partage).
  failed,
}
