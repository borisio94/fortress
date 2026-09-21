// Ouvrir sa caisse le lendemain, sans réseau.
//
// La connexion hors ligne (`_offlineLogin`) cherche le compte dans la boîte
// Hive `users`, puis compare le mot de passe caché dans SecureStorage. Or la
// purge de déconnexion vide `users`, tandis que `clearTokens` NE supprime PAS
// le mot de passe.
//
// Les deux moitiés du mécanisme étaient donc purgées en désaccord : on gardait
// ce qui a un coût de sécurité — un mot de passe en clair —, on perdait ce qui
// a la valeur d'usage. Un commerçant qui se déconnectait le soir ne pouvait
// plus ouvrir sa caisse le lendemain matin sans réseau.
//
// RÈGLE RETENUE (branche A, 21/09/2026) : l'appareil garde de quoi rouvrir la
// session du DERNIER compte connecté, et rien de plus. Les autres comptes
// s'effacent, et le mot de passe du précédent part dès qu'un autre se
// connecte.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/storage/logout_purge_policy.dart';

const _u1 = 'uid-awa';
const _u2 = 'uid-boris';
const _u3 = 'uid-clarisse';
const _all = [_u1, _u2, _u3];

void main() {
  group('Le dernier compte connecté', () {
    test('reste connaissable après une déconnexion', () {
      // LE test rouge : aujourd'hui la boîte est vidée, `_offlineLogin` ne
      // trouve plus personne et rend « Email ou mot de passe incorrect » —
      // sur des identifiants pourtant justes.
      final kept =
          userKeysToKeepOnLogout(allUserIds: _all, currentUserId: _u1);
      expect(kept, {_u1});
    });
  });

  group('Et rien de plus', () {
    test('les autres comptes de l\'appareil sont effacés', () {
      final kept =
          userKeysToKeepOnLogout(allUserIds: _all, currentUserId: _u1);
      expect(kept.contains(_u2), isFalse);
      expect(kept.contains(_u3), isFalse);
    });

    test('aucun compte connu ne survit si le compte courant est inconnu', () {
      // Session déjà nettoyée, purge rejouée, crash entre deux : on n'invente
      // pas un « dernier compte » au hasard.
      final kept =
          userKeysToKeepOnLogout(allUserIds: _all, currentUserId: null);
      expect(kept, isEmpty);
    });

    test('un compte absent de la boîte n\'est pas inventé', () {
      final kept = userKeysToKeepOnLogout(
          allUserIds: _all, currentUserId: 'uid-fantome');
      expect(kept, isEmpty);
    });

    test('une boîte vide reste vide', () {
      final kept =
          userKeysToKeepOnLogout(allUserIds: const [], currentUserId: _u1);
      expect(kept, isEmpty);
    });
  });
}
