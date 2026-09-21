/// RÉACTION AUX ÉVÈNEMENTS DE SESSION VENANT D'AILLEURS — règles pures.
///
/// `AuthBloc` s'abonne à `onAuthStateChange` pour réagir aux changements de
/// session qu'il n'a pas provoqués : une autre session qui expulse celle-ci,
/// un `SessionValidator` qui force un signOut.
///
/// Il n'écoutait que `signedOut`, et ce silence enfermait dehors. L'application
/// démarre hors ligne avec un jeton expiré : `_onCheck` lit `session.isExpired`,
/// conclut `AuthUnauthenticated`, l'écran de connexion s'affiche. Le
/// rafraîchissement automatique de gotrue continue de tourner toutes les dix
/// secondes. Le réseau revient, le rafraîchissement réussit, la session
/// redevient parfaitement valable — et personne n'écoute `tokenRefreshed`.
///
/// `AuthCheckRequested` n'est envoyé qu'une fois, dans le constructeur du bloc,
/// et n'est jamais rejoué. L'utilisateur ressaisit donc des identifiants alors
/// que sa session est redevenue bonne.
library;

import 'package:supabase_flutter/supabase_flutter.dart' show AuthChangeEvent;

/// Ce que l'application fait d'un évènement de session qu'elle n'a pas provoqué.
enum AuthReaction {
  /// Ne rien faire.
  none,

  /// Dérouler la déconnexion (purge, révocation, redirection vers /login).
  logout,

  /// Réexaminer la session : peut-être est-elle redevenue utilisable.
  recheck,
}

/// Que faire de [event] ?
///
/// [alreadySignedOut] : l'application se sait DÉJÀ déconnectée.
/// [logoutInProgress] : c'est notre propre déconnexion qui est en cours — son
/// handler fait déjà tout le nettoyage, le relayer le ferait deux fois.
/// [hasValidSession] : une session utilisable existe à cet instant.
AuthReaction authReactionTo({
  required AuthChangeEvent event,
  required bool alreadySignedOut,
  required bool logoutInProgress,
  required bool hasValidSession,
}) {
  if (logoutInProgress) return AuthReaction.none;

  // ── JETON RAFRAÎCHI — le seul évènement qui puisse ROUVRIR la porte ──
  //
  // Et uniquement quand on se croit déconnecté. Réexaminer alors qu'on est
  // déjà connecté rejouerait `syncOnLogin` à chaque rafraîchissement
  // automatique — toutes les heures, pour rien. La borne n'est pas une
  // précaution de style : c'est elle qui rend la règle tenable.
  //
  // `hasValidSession` est vérifié en plus de l'évènement : un rafraîchissement
  // peut aboutir sans rendre la session utilisable, et rouvrir sur rien
  // renverrait l'utilisateur à l'écran de connexion dans la foulée.
  if (event == AuthChangeEvent.tokenRefreshed) {
    return alreadySignedOut && hasValidSession
        ? AuthReaction.recheck
        : AuthReaction.none;
  }

  // ── SIGN-OUT VENU D'AILLEURS ────────────────────────────────────────
  if (event != AuthChangeEvent.signedOut) return AuthReaction.none;
  return alreadySignedOut ? AuthReaction.none : AuthReaction.logout;
}
