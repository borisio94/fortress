// Une session qui redevient valable doit rouvrir la porte.
//
// `AuthBloc` s'abonne à `onAuthStateChange` pour réagir aux changements de
// session venus d'AILLEURS — une autre session qui expulse celle-ci, un
// `SessionValidator` qui force un signOut. Il n'écoute que `signedOut`.
//
// LE SCÉNARIO QUI COINCE. L'application démarre hors ligne avec un jeton
// expiré : `_onCheck` lit `session.isExpired`, conclut `AuthUnauthenticated`,
// l'écran de connexion s'affiche. Le rafraîchissement automatique de gotrue
// continue de tourner toutes les dix secondes. Le réseau revient, le
// rafraîchissement réussit, la session redevient parfaitement valable —
// et `tokenRefreshed` n'est écouté par personne.
//
// L'écran de connexion reste affiché. `AuthCheckRequested` n'est envoyé qu'une
// fois, dans le constructeur du bloc, et n'est jamais rejoué. L'utilisateur
// doit ressaisir des identifiants alors que sa session est redevenue bonne.
//
// RÈGLE RETENUE : un rafraîchissement réussi pendant qu'on se croit déconnecté
// déclenche un RÉEXAMEN de la session — et seulement dans ce cas. Réexaminer
// alors qu'on est déjà connecté rejouerait `syncOnLogin` à chaque
// rafraîchissement, c'est-à-dire toutes les heures, pour rien.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthChangeEvent;
import 'package:fortress/features/auth/domain/auth_state_reaction.dart';

AuthReaction react(
  AuthChangeEvent e, {
  bool signedOut = false,
  bool logoutInProgress = false,
  bool validSession = true,
}) =>
    authReactionTo(
      event: e,
      alreadySignedOut: signedOut,
      logoutInProgress: logoutInProgress,
      hasValidSession: validSession,
    );

void main() {
  group('Un jeton rafraîchi', () {
    test('rouvre la session quand on se croyait déconnecté', () {
      // LE test rouge : aujourd'hui l'évènement est ignoré et l'écran de
      // connexion reste affiché sur une session redevenue valable.
      expect(react(AuthChangeEvent.tokenRefreshed, signedOut: true),
          AuthReaction.recheck);
    });

    test('ne fait rien si l\'on est déjà connecté', () {
      // Sans cette borne, `syncOnLogin` serait rejoué à chaque
      // rafraîchissement automatique — toutes les heures, pour rien.
      expect(react(AuthChangeEvent.tokenRefreshed), AuthReaction.none);
    });

    test('ne fait rien si la session reste inutilisable', () {
      expect(
          react(AuthChangeEvent.tokenRefreshed,
              signedOut: true, validSession: false),
          AuthReaction.none);
    });

    test('ne fait rien pendant une déconnexion en cours', () {
      expect(
          react(AuthChangeEvent.tokenRefreshed,
              signedOut: true, logoutInProgress: true),
          AuthReaction.none);
    });
  });

  group('La déconnexion externe ne bouge pas', () {
    test('un signOut venu d\'ailleurs déroule la déconnexion', () {
      expect(react(AuthChangeEvent.signedOut), AuthReaction.logout);
    });

    test('notre propre déconnexion n\'est pas rejouée', () {
      expect(react(AuthChangeEvent.signedOut, logoutInProgress: true),
          AuthReaction.none);
    });

    test('un signOut alors qu\'on est déjà déconnecté ne fait rien', () {
      expect(
          react(AuthChangeEvent.signedOut, signedOut: true),
          AuthReaction.none);
    });
  });

  group('Les autres évènements restent ignorés', () {
    test('aucun n\'est relayé, quel que soit l\'état', () {
      const autres = [
        AuthChangeEvent.initialSession,
        AuthChangeEvent.signedIn,
        AuthChangeEvent.userUpdated,
        AuthChangeEvent.passwordRecovery,
        AuthChangeEvent.mfaChallengeVerified,
      ];
      for (final e in autres) {
        for (final so in [true, false]) {
          expect(react(e, signedOut: so), AuthReaction.none,
              reason: '$e ne doit rien déclencher (signedOut=$so)');
        }
      }
    });
  });
}
