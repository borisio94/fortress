import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/sa_notifications.dart';
import 'package:fortress/core/services/activity_actions.dart';

/// Vérifie le catalogue des événements notifiés au super-admin :
/// les événements « entrants » clés (compte, paiement, boutique) déclenchent
/// une notification ; les actions de routine non ; et chaque action notifiable
/// est cohérente avec le catalogue d'audit (donc journalisée + catégorisée).
void main() {
  group('SaNotifications', () {
    test('les événements clés sont notifiables au SA', () {
      for (final a in const [
        'user_signup', 'subscription_activated', 'subscription_cancelled',
        'shop_created', 'shop_deleted', 'user_deleted', 'account_deleted',
      ]) {
        expect(SaNotifications.isNotifiable(a), isTrue, reason: a);
      }
    });

    test('les actions de routine ne notifient PAS le SA', () {
      for (final a in const [
        'product_updated', 'stock_adjusted', 'client_created', 'user_login',
        'expense_created', 'order_delivered',
      ]) {
        expect(SaNotifications.isNotifiable(a), isFalse, reason: a);
      }
    });

    test('toute action notifiable est connue du catalogue d\'audit', () {
      for (final a in SaNotifications.actions) {
        expect(ActivityActions.isKnown(a), isTrue,
            reason: '"$a" notifiable mais absente d\'ActivityActions '
                '(donc non catégorisée dans l\'historique)');
      }
    });

    test('chaque action notifiable a un libellé non vide', () {
      for (final a in SaNotifications.actions) {
        expect(SaNotifications.labelFor(a).trim(), isNotEmpty, reason: a);
      }
    });

    test('action inconnue → non notifiable', () {
      expect(SaNotifications.isNotifiable('action_inexistante_xyz'), isFalse);
    });
  });
}
