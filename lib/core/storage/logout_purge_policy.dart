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
