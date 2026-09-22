/// ON N'ENCAISSE PAS DEUX FOIS LA MÊME ADDITION.
///
/// Rien ne l'empêchait au-delà du parcours. `caisse_page` masque le bouton
/// « Encaisser » quand la commande est déjà `completed` — et c'était le SEUL
/// garde-fou. Le service, lui, acceptait de rejouer la clôture.
///
/// CE QUI EST DÉJÀ PROTÉGÉ, et qu'il ne faut pas re-protéger : la couche
/// données est idempotente à dessein. `SaleStatusTransitions.canTransition`
/// accepte `from == to` (`sale.dart:176`) parce que `updateOrderStatus` garde
/// chacun de ses effets — le livre partenaire par `oldStatus != completed`, la
/// compensation de stock par un `if (oldStatus == status) return` explicite,
/// et le drapeau persistant `stock_reserved`. Réémettre `completed` n'y bouge
/// ni le stock ni les écritures partenaire.
///
/// CE QUI NE L'ÉTAIT PAS, et c'est là que l'argent se perd :
///
///   * `PaymentService.recordSplit` forge un identifiant neuf à chaque appel
///     (`payment_service.dart:213`). Un second encaissement écrit donc une
///     SECONDE ligne de règlement pour la même addition — et la clôture de
///     caisse les somme (`cash_closure_service.dart:189`). Le fond attendu
///     monte d'un montant que personne n'a reçu, et le caissier passe pour
///     manquant.
///   * `consumeStockFor` décrémente une seconde fois le décompte du jour.
///
/// LE CAS N'EST PAS THÉORIQUE. Le plan de salle est explicitement prévu pour
/// deux appareils — « tablette salle / téléphone serveur ». Le premier
/// encaisse ; le second, dont Hive n'a pas encore reçu la mise à jour, voit
/// toujours le bouton et le touche.
///
/// C'est pourquoi la garde vit ICI, dans le service, et lit l'état RÉEL du
/// stockage : un garde d'écran ne protège que l'écran qui le porte.
library;

import '../../caisse/domain/entities/sale.dart';

/// Cette commande a-t-elle déjà été encaissée ?
///
/// Seul `completed` compte. `cancelled`, `refused` et `refunded` sont déjà
/// refusés en amont par la table des transitions, qui ne leur laisse aucune
/// sortie vers `completed` — les rejouer ici doublerait une règle au lieu de
/// la renforcer.
bool isAlreadySettled(SaleStatus status) =>
    status == SaleStatus.completed;

/// Refus d'un second encaissement.
///
/// Porte un message déjà rédigé pour l'opérateur : `settleRestaurantOrder` et
/// `bill_page` rattrapent les exceptions métier et les affichent telles
/// quelles, comme celles de `updateOrderStatus`.
class DejaEncaisseeException implements Exception {
  const DejaEncaisseeException();

  String get code => 'deja_encaissee';

  String get message =>
      'Cette addition a déjà été encaissée — peut-être depuis un autre '
      'appareil. Rien n\'a été enregistré une seconde fois.';

  @override
  String toString() => message;
}
