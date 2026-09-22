/// CE QU'ON FAIT DE QUELQU'UN QUI VIENT DE CRÉER SON COMPTE ET SA BOUTIQUE.
///
/// Aujourd'hui : on le déconnecte. Il ressaisit les identifiants qu'il vient
/// de choisir, trente secondes plus tôt, et c'est son premier contact avec
/// l'application.
///
/// LA RAISON EST BONNE, LE REMÈDE EST TROP LARGE. L'essai de 14 jours est créé
/// par un déclencheur SQL — `create_trial_subscription` — au moment où la ligne
/// `shops` est insérée. Enchaîner directement appelait parfois `get_user_plan`
/// AVANT que l'essai y soit visible, et le compte neuf tombait sur un paywall
/// « Expiré ». La déconnexion évitait ça, en payant le prix fort : la session
/// était valide, on la jetait par précaution.
///
/// Ce qu'il fallait, c'est REDEMANDER. Un essai qui n'est pas encore visible le
/// devient ; celui qui ne le devient jamais signale un vrai problème — une
/// table `plans` sans ligne `trial`, par exemple — et là, seulement là, il faut
/// renvoyer vers l'écran de connexion.
library;

/// Combien de fois on redemande le plan avant de renoncer.
///
/// Cinq, et pas plus : au-delà, ce n'est plus une course de réplication, c'est
/// une absence. Continuer ferait attendre sans rien changer.
const int kTrialLookupAttempts = 5;

/// Plafond du délai entre deux tentatives.
///
/// Sans lui, le doublement mènerait à des attentes de plusieurs secondes sur
/// les derniers essais, alors que l'utilisateur regarde un bouton qui tourne.
const Duration kTrialLookupMaxDelay = Duration(seconds: 2);

/// Délai avant la tentative suivante — 250 ms, puis le double, plafonné.
///
/// Croissant parce que la première tentative échoue pour une raison qui se
/// résout en quelques centaines de millisecondes, et que s'obstiner au même
/// rythme ne ferait que multiplier les appels sans laisser au serveur le temps
/// de rattraper.
Duration trialLookupDelay(int attempt) {
  final ms = 250 * (1 << attempt);
  return ms >= kTrialLookupMaxDelay.inMilliseconds
      ? kTrialLookupMaxDelay
      : Duration(milliseconds: ms);
}

/// L'essai est-il visible ?
///
/// Les deux conditions comptent. `hasPlan` seul laisserait passer un plan
/// `expired`, qui est précisément ce que le paywall affichait.
bool trialIsVisible({required bool hasPlan, required bool isActive}) =>
    hasPlan && isActive;

/// Ce qu'on fait de l'utilisateur, une fois sa boutique créée.
enum PostSignUpOutcome {
  /// Il entre. Sa session est valide et son essai est visible.
  enter,

  /// On redemande le plan après un délai : l'essai n'est pas encore arrivé.
  retry,

  /// On renonce : déconnexion et retour à l'écran de connexion, où le plan
  /// sera relu depuis zéro.
  signOutAndAskLogin,
}

/// [attempt] : le numéro de la lecture qu'on vient de faire, à partir de 0.
///
/// L'ESSAI VISIBLE L'EMPORTE SUR LE COMPTEUR. Sinon la dernière lecture —
/// celle qui réussit enfin — serait jetée au motif qu'on avait décidé de
/// renoncer à ce tour-là.
PostSignUpOutcome postSignUpOutcome({
  required bool trialVisible,
  required int attempt,
}) {
  if (trialVisible) return PostSignUpOutcome.enter;
  return attempt < kTrialLookupAttempts
      ? PostSignUpOutcome.retry
      : PostSignUpOutcome.signOutAndAskLogin;
}
