/// CE QUE LA DÉCONNEXION EFFACE — règles pures.
///
/// La purge de déconnexion est un dispositif ANTI-FUITE : sur un appareil
/// partagé, les produits, prix d'achat, clients et paniers d'un compte ne
/// doivent pas survivre au suivant. Elle vide donc toutes les boîtes Hive et
/// ne conserve qu'une poignée de préférences liées à l'APPAREIL.
///
/// UNE BOÎTE N'EST PAS COMME LES AUTRES. `offline_queue_box` ne porte pas des
/// données consultables : elle porte des ÉCRITURES QUI NE SONT JAMAIS PARTIES.
/// Les vider ne ferme aucune fuite — la ligne n'existe nulle part ailleurs —,
/// ça les perd. Une vente saisie hors ligne disparaît de l'appareil qui l'a
/// saisie, et donc de partout.
///
/// CE N'EST PAS UN CAS DE BORD. La déconnexion volontaire prévient et propose
/// de synchroniser (`_SyncBeforeLogoutSheet`). Mais un `signedOut` EXTERNE —
/// jeton de rafraîchissement révoqué, session expulsée par la limite de
/// sessions — passe par `auth_bloc` sans aucune garde : ni avertissement, ni
/// tentative d'envoi. Cela annulait les trois lots du 19 au 21/09/2026, qui
/// avaient précisément protégé cette file contre l'abandon.
///
/// LE REMPART DOIT TENIR MALGRÉ TOUT, et c'est la partie qu'on oublie.
/// Conserver la file sans rien d'autre DÉPLACERAIT la fuite : les opérations
/// du compte précédent resteraient en file et partiraient sous la session du
/// suivant. Le rempart de rechange existe déjà — le login purge tout quand
/// `local_data_owner_id` désigne quelqu'un d'autre — mais cette clé était
/// elle-même effacée par la purge, donc la garde lisait `null` et ne se
/// déclenchait jamais. Elle désigne l'APPAREIL, pas la session : elle survit.
library;

/// Les boîtes Hive vidées à la déconnexion.
///
/// [queueHasPendingOps] décide du sort de la file, et d'elle seule. Une file
/// VIDE est purgée comme le reste : la conserver ferait grossir la boîte d'une
/// session à l'autre sans que rien ne la reprenne jamais.
Set<String> boxesToClearOnLogout({
  required Iterable<String> allBoxes,
  required bool queueHasPendingOps,
  String queueBox = 'offline_queue_box',
}) {
  final out = allBoxes.toSet();
  if (queueHasPendingOps) out.remove(queueBox);
  return out;
}

/// Clé qui nomme le compte propriétaire des données locales de cet appareil.
///
/// Lue au login par la garde anti-fuite : si elle désigne quelqu'un d'autre
/// que celui qui se connecte, tout est purgé AVANT de charger le nouveau
/// compte. C'est ce qui rend sûre la conservation de la file.
const String kLocalDataOwnerKey = 'local_data_owner_id';

/// Les clés de `settings` conservées à la déconnexion.
///
/// [deviceKeys] sont les préférences d'appareil — thème, taille de texte,
/// langue, dernier e-mail. On y ajoute le propriétaire des données locales,
/// qui n'est pas une préférence mais relève de la même portée : il décrit
/// l'appareil, pas la session, et doit survivre à celle-ci pour que la garde
/// du login puisse encore décider.
Set<String> settingKeysToKeepOnLogout(Set<String> deviceKeys) =>
    {...deviceKeys, kLocalDataOwnerKey};

/// Les comptes dont la fiche reste lisible dans `users` après la déconnexion.
///
/// EXACTEMENT UN, ou aucun : le dernier compte connecté. C'est ce qui rend la
/// connexion hors ligne possible le lendemain d'une déconnexion.
///
/// POURQUOI IL EN FAUT UN. `_offlineLogin` cherche le compte dans cette boîte,
/// puis compare le mot de passe caché dans SecureStorage. La purge vidait la
/// boîte, tandis que `clearTokens` ne supprime PAS le mot de passe : on gardait
/// ce qui a un coût de sécurité, on perdait ce qui a la valeur d'usage. Un
/// commerçant déconnecté le soir ne rouvrait pas sa caisse sans réseau le
/// lendemain — et son mot de passe en clair restait quand même sur l'appareil.
///
/// POURQUOI PAS PLUS D'UN. La boîte peut contenir les comptes de plusieurs
/// personnes ayant utilisé l'appareil. N'en garder qu'un borne ce qui reste
/// lisible, et interdit à un autre compte de se connecter hors ligne ici : il
/// ne sera pas trouvé. Quand un autre compte se connecte EN LIGNE, la garde
/// anti-fuite purge ce reliquat et efface son mot de passe.
///
/// On n'invente jamais de « dernier compte » : sans [currentUserId] connu, ou
/// s'il ne figure pas dans la boîte, rien n'est conservé.
Set<String> userKeysToKeepOnLogout({
  required Iterable<String> allUserIds,
  required String? currentUserId,
}) {
  if (currentUserId == null || currentUserId.isEmpty) return const {};
  return allUserIds.contains(currentUserId) ? {currentUserId} : const {};
}
