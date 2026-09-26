/// LA TABLE A CHANGÉ PENDANT QU'ON REMPLISSAIT LE FORMULAIRE.
///
/// Deux serveurs travaillent sur le même plan de salle. Le temps réel est
/// branché pour ça — `app_database.dart` le dit à l'endroit même : *« Realtime
/// INDISPENSABLE ici : deux appareils manipulent le même plan de salle
/// simultanément »*. Ils se voient donc, à la latence près.
///
/// CE QUI NE SE VOIT PAS, C'EST L'INSTANT DE LA VALIDATION. La feuille de
/// prise de commande travaille sur l'objet `RestaurantTable` capturé à son
/// OUVERTURE. Entre-temps, l'autre serveur a pu ouvrir la même table.
///
/// Le scénario, en clair : B choisit Table 4, alors libre. A l'ouvre pour
/// 4 couverts pendant que B compose sa sélection. B valide — et la prise de
/// commande calcule `couverts déjà assis + nouvelle tablée` sur l'instantané,
/// où la table était encore libre. Elle écrit donc `0 + 3 = 3`. **Les quatre
/// couverts de A disparaissent**, sans un mot.
///
/// CE QUI SE PERD, ET CE QUI NE SE PERD PAS. Les deux commandes survivent :
/// ce sont des `Sale` distincts, et le regroupement par compte les montre
/// toutes les deux. C'est l'état de SALLE qui se perd — les couverts, l'heure
/// d'ouverture, le pointeur de commande. Pas d'argent, mais un plan de salle
/// qui ment sur le nombre de places libres, et un service qui place des
/// clients sur des chaises occupées.
///
/// LE REMÈDE N'EST PAS UN VERROU. Relire la ligne vive au moment de la
/// validation suffit à écrire le bon chiffre ; refuser la commande ne ferait
/// que bloquer un service pour un écart que l'on sait corriger. Mais l'écart
/// doit se DIRE : un chiffre qui change tout seul sans explication est ce qui
/// fait cesser de croire un écran.
library;

/// Ce qu'il faut annoncer quand la table a bougé sous la feuille.
///
/// `null` — le cas normal — signifie que rien n'a changé, et alors on ne dit
/// rien : un message à chaque commande cesserait d'être lu au bout d'un
/// service.
///
/// [seatedBefore] est le nombre de convives que la feuille croyait assis
/// quand elle s'est ouverte ; [seatedAfter] celui de la ligne relue à la
/// validation.
String? tableDriftMessage({
  required String tableName,
  required int seatedBefore,
  required int seatedAfter,
}) {
  if (seatedAfter == seatedBefore) return null;
  if (seatedAfter > seatedBefore) {
    // LE CAS QUI PERDAIT DES COUVERTS. Quelqu'un a ouvert ou agrandi la table
    // pendant la saisie. On le dit avec le chiffre RETENU, pas avec l'écart :
    // le serveur a besoin de savoir ce que la table porte maintenant, pas de
    // calculer une différence.
    return '$tableName a été ouverte entre-temps : elle porte désormais '
        '$seatedAfter couverts.';
  }
  // La table s'est VIDÉE pendant la saisie — un encaissement, une libération.
  // Plus rare, et moins grave, mais tout aussi silencieux : la commande part
  // sur une table que quelqu'un vient de rendre disponible.
  return '$tableName a été libérée entre-temps : elle ne portait plus que '
      '$seatedAfter couverts quand la commande est partie.';
}
