/// LE MOTIF D'UNE REMISE, ET CE QU'IL DEVIENT.
///
/// `bill_page` EXIGE un motif pour accorder une remise : le bouton refuse de
/// valider tant que le champ est vide. Ce motif partait dans
/// `ManagerGate.require(details: …)`, donc dans `activity_logs` — et
/// `applyDiscount` n'écrivait que le montant sur la commande.
///
/// Un champ imposé au serveur, invisible partout ensuite : ni sur l'addition,
/// ni sur la facture, ni dans les rapports. Il coûtait du temps et ne rendait
/// rien.
///
/// POURQUOI PAS RELIRE `activity_logs` : le journal n'est pas lisible hors
/// ligne, et un restaurant travaille hors ligne. `ActivityLogService.log`
/// passe par `bgInsert`, qui écrit dans la FILE D'ATTENTE et pas dans Hive ;
/// la boîte locale n'est remplie que par `syncActivityLogs`, en tirant depuis
/// le serveur. Une remise accordée pendant une coupure aurait son motif nulle
/// part de lisible jusqu'au retour du réseau. Il doit voyager AVEC la commande
/// — d'où `orders.discount_reason` (hotfix_181).
library;

/// Le motif à écrire sur la commande, ou `null` s'il n'y a rien à écrire.
///
/// RETIRER LA REMISE EMPORTE SON MOTIF. Sans cette règle, « geste commercial »
/// resterait collé à une addition qui ne porte plus aucune remise — et se
/// lirait sur la facture, où il ne voudrait plus rien dire. `bill_page` traite
/// déjà le montant nul comme un retrait (« Remise retirée »), le motif doit
/// suivre le même sort.
///
/// Un motif vide ou blanc vaut absence : le formulaire l'interdit, mais les
/// appels programmatiques et les commandes antérieures au hotfix_181 ne
/// passent pas par lui.
String? discountReasonFor({required double amount, required String reason}) {
  if (amount <= 0) return null;
  final trimmed = reason.trim();
  return trimmed.isEmpty ? null : trimmed;
}
