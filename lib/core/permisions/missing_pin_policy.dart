/// QUAND AUCUN CODE PIN GÉRANT N'EST CONFIGURÉ.
///
/// Trois gestes laissent l'argent sortir d'un restaurant sans qu'un plat
/// sorte : annuler une tournée déjà partie en cuisine, remiser une addition,
/// défaire une vente encaissée. `ManagerGate` les couvre — mais seulement si
/// un PIN existe. Sans PIN, l'action PASSE, avec un simple message.
///
/// ON NE BLOQUE PAS, ET C'EST DÉLIBÉRÉ. Refuser une annulation en plein
/// service parce qu'un réglage manque paralyserait la salle, et le personnel
/// contournerait par un chemin non tracé — exactement ce qu'on cherche à
/// éviter. La permission, elle, reste exigée, et le geste reste journalisé
/// dans les deux cas : la trace existe toujours, elle n'est simplement pas
/// AUTORISÉE par quelqu'un.
///
/// CE QUI MANQUAIT : rien n'invitait jamais à définir ce code. Le message
/// arrivait APRÈS que l'argent soit sorti, et renvoyait chercher « Réglages →
/// Sécurité » à la main. Une boutique neuve restait donc indéfiniment dans cet
/// état, et le seul signal tombait trop tard.
library;

/// Ce qu'on fait de quelqu'un qui franchit une porte non protégée.
enum MissingPinResponse {
  /// Lui proposer de définir le code SUR-LE-CHAMP, sans navigation. C'est le
  /// seul instant où l'on sait que la protection servirait à quelque chose :
  /// l'argent est en train de sortir.
  offerSetup,

  /// Ne rien lui dire.
  staySilent,
}

/// À qui propose-t-on de définir le code ?
///
/// AU PROPRIÉTAIRE SEULEMENT. `PinService` pousse le code sur `profiles` :
/// c'est le PIN DU PROPRIÉTAIRE, pas un code d'établissement. Le proposer à un
/// gérant délégué reviendrait à lui faire poser le code de quelqu'un d'autre.
///
/// ET ON NE DIT RIEN AUX AUTRES. Le message actuel — « cette action n'est pas
/// protégée » — apprend à un délégué que la porte est ouverte, sans qu'il
/// puisse la fermer. C'est le seul usage qu'il peut en faire. Le propriétaire,
/// lui, l'apprendra par le journal d'activité, qui porte déjà le geste, son
/// montant et son motif.
MissingPinResponse missingPinResponse({required bool isShopOwner}) =>
    isShopOwner
        ? MissingPinResponse.offerSetup
        : MissingPinResponse.staySilent;
