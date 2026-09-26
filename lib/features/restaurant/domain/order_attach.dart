/// AJOUTER DES PLATS À UNE TABLE DÉJÀ OUVERTE.
///
/// Un client commande un dessert après le plat. Jusqu'ici, le seul chemin
/// était de refaire la prise de commande entière — panier, « Commander », type
/// de service, choix de la table, couverts, envoi — pour un seul article. Cinq
/// questions dont quatre avaient déjà leur réponse.
///
/// LE PIÈGE QUE CE FICHIER EXISTE POUR FERMER.
///
/// La prise de commande écrit les couverts de la table ainsi :
/// `tableCovers: _seated(table) + _covers`, avec sa raison écrite — asseoir
/// trois convives à une table qui en portait cinq doit donner huit, pas trois.
/// C'est juste pour une NOUVELLE tablée.
///
/// Rejoué tel quel pour un dessert, il ajouterait un couvert à chaque article
/// commandé en cours de repas. Une table de quatre qui commande trois cafés
/// afficherait sept convives, le plan de salle la donnerait pleine, et
/// `computeSeating` compterait des places occupées par personne. Le raccourci
/// aurait donc faussé exactement ce qu'il devait accélérer.
///
/// LES DEUX CAS SONT DISTINCTS, ET UN SEUL CHIFFRE LES SÉPARE : les convives
/// que cette commande APPORTE. Une nouvelle tablée en apporte ; un dessert
/// n'en apporte aucun — ils sont déjà assis, déjà comptés.
library;

/// Les couverts à écrire, sur la commande et sur la table.
///
/// [seated] — les convives déjà assis à cette table. Zéro si elle est libre.
/// [newCovers] — la tablée saisie à la prise de commande. Ignoré en ajout.
///
/// `orderCovers` est ce que porte la commande : il sert au bon de cuisine
/// (« 4 couverts ») et au partage de l'addition. En ajout, il reprend les
/// convives assis — ce dessert EST pour ces gens-là — plutôt que zéro, qui
/// ferait imprimer « 0 couverts » sur le bon.
///
/// `tableCovers` est ce que porte la table, et c'est lui qui alimente le plan
/// de salle. En ajout, il ne bouge pas. C'est tout l'objet de ce fichier.
({int orderCovers, int tableCovers}) coversForTableOrder({
  required bool attaching,
  required int seated,
  required int newCovers,
}) {
  if (attaching) {
    // Plancher à 1 : une table occupée dont les couverts n'ont jamais été
    // renseignés rendrait `seated == 0`, et le bon de cuisine annoncerait
    // « 0 couverts » à un cuisinier qui a du monde en salle.
    final s = seated < 1 ? 1 : seated;
    return (orderCovers: s, tableCovers: seated);
  }
  return (orderCovers: newCovers, tableCovers: seated + newCovers);
}
