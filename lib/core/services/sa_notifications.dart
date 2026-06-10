// ═════════════════════════════════════════════════════════════════════════════
// Catalogue des événements NOTIFIABLES au super-admin.
//
// Le SA reçoit une notification (cloche du panneau + feed) à chaque événement
// « entrant » important de la plateforme : création de compte, paiement /
// abonnement, nouvelle boutique, suppressions. Ces événements sont déjà
// journalisés dans `activity_logs` — ce catalogue définit lesquels remontent
// en NOTIFICATION (vs simple log consultable).
//
// Pur Dart (aucun import Flutter) → testable
// (test/unit/sa_notifications_test.dart).
//
// RÈGLE : ajouter ici toute nouvelle action que le SA doit voir notifiée.
// ═════════════════════════════════════════════════════════════════════════════

class SaNotifications {
  SaNotifications._();

  /// Actions (de `activity_logs.action`) qui génèrent une notification SA.
  static const Set<String> actions = {
    'user_signup',            // nouvelle inscription / compte créé
    'subscription_activated', // paiement / abonnement activé
    'subscription_cancelled', // abonnement annulé
    'shop_created',           // nouvelle boutique
    'shop_deleted',           // boutique supprimée
    'account_deleted',        // compte auto-supprimé
    'user_deleted',           // compte supprimé
  };

  static bool isNotifiable(String action) => actions.contains(action);

  /// Libellé court orienté SA (pour le feed de notifications).
  static String labelFor(String action) {
    switch (action) {
      case 'user_signup':            return 'Nouveau compte créé';
      case 'subscription_activated': return 'Paiement / abonnement activé';
      case 'subscription_cancelled': return 'Abonnement annulé';
      case 'shop_created':           return 'Nouvelle boutique créée';
      case 'shop_deleted':           return 'Boutique supprimée';
      case 'account_deleted':        return 'Compte supprimé';
      case 'user_deleted':           return 'Compte supprimé';
      default:                       return action.replaceAll('_', ' ');
    }
  }
}
