// Une déconnexion ne jette pas le travail qui n'est pas parti.
//
// La purge de déconnexion est un dispositif ANTI-FUITE : sur un appareil
// partagé, les produits, prix d'achat, clients et paniers d'un compte ne
// doivent pas survivre au suivant. Elle vide donc toutes les boîtes Hive.
//
// Elle vide aussi `offline_queue_box`, et c'est une faute : cette boîte ne
// porte pas des données consultées, elle porte des ÉCRITURES QUI NE SONT
// JAMAIS PARTIES. Les vider, c'est les perdre — sur l'appareil qui les a
// saisies, et donc partout.
//
// CE N'EST PAS UN CAS DE BORD. La déconnexion volontaire prévient et propose
// de synchroniser (`_SyncBeforeLogoutSheet`). Mais un `signedOut` EXTERNE —
// jeton de rafraîchissement révoqué, session expulsée — passe par
// `auth_bloc` sans aucune garde : ni avertissement, ni tentative d'envoi. La
// caisse du jour part avec.
//
// Cela annulait les trois lots de synchronisation du 19 au 21/09/2026, qui
// avaient précisément protégé cette file contre l'abandon.
//
// LE REMPART ANTI-FUITE DOIT TENIR MALGRÉ TOUT. Conserver la file sans rien
// d'autre déplacerait la fuite au lieu de la fermer : c'est
// `local_data_owner_id` qui doit désormais survivre, pour que le login d'un
// AUTRE compte purge ce qui reste avant de charger le sien.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/storage/logout_purge_policy.dart';

/// Un échantillon représentatif de `HiveBoxes._allBoxes`.
const _boxes = <String>[
  'cart_box',
  'settings_box',
  'offline_queue_box',
  'shops_box',
  'users_box',
  'products_box',
  'orders_box',
  'daily_expenses_box',
];

/// Les clés de préférences d'appareil conservées aujourd'hui.
const _deviceKeys = <String>{
  'last_login_email',
  'text_scale',
  'app_theme_mode',
  'app_locale',
  'onboarding_seen',
};

void main() {
  group('La file d\'envoi', () {
    test('survit à une déconnexion quand des écritures attendent', () {
      // LE test rouge. Trois ventes saisies hors ligne, une session expulsée :
      // aujourd'hui elles disparaissent sans un mot.
      final cleared = boxesToClearOnLogout(
          allBoxes: _boxes, queueHasPendingOps: true);
      expect(cleared.contains('offline_queue_box'), isFalse,
          reason: 'des écritures non envoyées seraient perdues');
    });

    test('est vidée quand elle ne contient plus rien', () {
      // Le revers : une file vide n'a aucune raison d'être conservée, sinon
      // la boîte s'accumule d'une session à l'autre sans jamais être reprise.
      final cleared = boxesToClearOnLogout(
          allBoxes: _boxes, queueHasPendingOps: false);
      expect(cleared.contains('offline_queue_box'), isTrue);
    });
  });

  group('Le rempart anti-fuite tient', () {
    test('toutes les autres boîtes sont vidées, file pleine ou non', () {
      for (final pending in [true, false]) {
        final cleared = boxesToClearOnLogout(
            allBoxes: _boxes, queueHasPendingOps: pending);
        for (final b in _boxes) {
          if (b == 'offline_queue_box') continue;
          expect(cleared.contains(b), isTrue,
              reason: '« $b » doit être vidée (pending=$pending)');
        }
      }
    });

    test('le propriétaire des données locales SURVIT à la déconnexion', () {
      // Sans lui, la garde du login (« previousOwner != userId → purge ») est
      // aveugle : elle lit null et ne se déclenche jamais. C'est exactement ce
      // qui rend la conservation de la file sûre — ou dangereuse.
      final kept = settingKeysToKeepOnLogout(_deviceKeys);
      expect(kept.contains('local_data_owner_id'), isTrue,
          reason: 'la garde anti-fuite du login ne pourrait plus se déclencher');
    });

    test('les préférences d\'appareil restent conservées', () {
      final kept = settingKeysToKeepOnLogout(_deviceKeys);
      for (final k in _deviceKeys) {
        expect(kept.contains(k), isTrue);
      }
    });

    test('aucune clé de compte ne se glisse dans les conservées', () {
      final kept = settingKeysToKeepOnLogout(_deviceKeys);
      for (final k in ['current_user_id', 'my_perms_shop1', 'members_shop1']) {
        expect(kept.contains(k), isFalse, reason: '« $k » est liée au compte');
      }
    });
  });
}
