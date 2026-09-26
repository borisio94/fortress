import '../../caisse/domain/entities/sale.dart';
import '../../caisse/domain/usecases/delete_sale_usecase.dart';

/// CE QU'ON PEUT FAIRE D'UNE COMMANDE, ET QUAND.
///
/// Les douze conditions d'affichage de la rangée d'actions, extraites TELLES
/// QUELLES de `_OrderCardState._buildRestoCard` le 2026-09-23. Pas une
/// n'est modifiée : même ordre, mêmes opérateurs, mêmes bornes.
///
/// POURQUOI LES SORTIR. La carte et la feuille « Plus d'actions » doivent
/// proposer exactement le même jeu — deux listes écrites à deux endroits
/// divergent au premier ajout. Et douze conditions imbriquées dans un `Row` de
/// 200 lignes n'étaient vérifiables par rien : cet écran n'a aucun test de
/// widget.
///
/// L'ORDRE DE LA LISTE EST CELUI DE LA RANGÉE, délibérément. Il n'a jamais été
/// écrit nulle part, mais c'est celui que l'usage a fixé ; le rendre
/// « logique » ferait chercher.
enum OrderAction {
  /// Tournée « à choisir sur place » : clôturer.
  closeApprovalRound('Clôturer la tournée'),

  /// Tournée « à choisir sur place » : annuler.
  cancelApprovalRound('Annuler la tournée', destructive: true),

  /// L'évènement qui fait avancer la commande — le bouton principal.
  advanceStatus('Encaisser & finaliser'),

  /// Annuler ou refuser une commande non finalisée.
  cancelOrRefuse('Annuler ou refuser', destructive: true),

  /// Défaire une vente encaissée (retour en « programmée »).
  ///
  /// SEULE ACTION DE CETTE RANGÉE PASSANT PAR `ManagerGate` — voir [pinGated].
  reopenPaidSale('Repasser en programmée', pinGated: true),

  /// Facture PDF brandée.
  invoicePdf('Facture (PDF avec logo)'),

  /// Envoi de la facture par WhatsApp.
  invoiceWhatsApp('Envoyer la facture par WhatsApp'),

  /// Reste dû sur une commande non soldée.
  collectBalance('Enregistrer un acompte'),

  /// Relance du client.
  relaunchClient('Relancer le client'),

  /// Frais de livraison et dette partenaire — JAMAIS en restauration.
  editFees('Modifier les frais (livraison…)'),

  /// Édition des articles — JAMAIS en restauration (voir `orderActionsFor`).
  editOrder('Modifier la commande'),

  /// Suppression définitive.
  deleteOrder('Supprimer', destructive: true);

  const OrderAction(this.label, {this.destructive = false, this.pinGated = false});

  /// Le libellé, désormais TOUJOURS rendu.
  ///
  /// Ces actions n'étaient que des icônes de 30 px. Elles portaient un
  /// `Tooltip`, ce qui demande un survol ou un appui long : sur une tablette
  /// en plein service, personne ne le découvre.
  final String label;

  /// Sort de l'argent ou détruit une donnée — séparée par un filet, en bas.
  final bool destructive;

  /// L'action passe par `ManagerGate`, donc PAR UN PIN GÉRANT — **si la
  /// boutique en a posé un**.
  ///
  /// ⚠ CE DRAPEAU NE SUFFIT PAS À AFFICHER LE BADGE. `ManagerGate.require`
  /// n'ouvre `OwnerPinDialog` que `if (await PinService.hasPIN())` ; sans PIN
  /// configuré, il propose une création au propriétaire et laisse passer un
  /// délégué. Annoncer « PIN » sur une boutique qui n'en a pas serait aussi
  /// faux que de ne pas l'annoncer là où il est exigé — le site d'appel doit
  /// donc croiser ce drapeau avec l'état réel du PIN.
  final bool pinGated;
}

/// LES ACTIONS DISPONIBLES, dans l'ordre de la rangée.
///
/// Paramètres groupés : l'état de la commande, puis les permissions, puis le
/// contexte. Tous nommés — dix booléens positionnels seraient illisibles et
/// inversables en silence.
List<OrderAction> orderActionsFor({
  // ── L'état de la commande ────────────────────────────────────────────
  required SaleStatus status,
  required bool isApprovalSale,
  required double amountDue,
  required double amountPaid,
  required String? source,
  // ── Les permissions ──────────────────────────────────────────────────
  required bool canCancel,
  required bool canEdit,
  required bool canDelete,
  // ── Le contexte ──────────────────────────────────────────────────────
  required bool isResto,
  required bool canConfirmClient,
}) {
  final ouverte =
      status == SaleStatus.scheduled || status == SaleStatus.processing;
  final out = <OrderAction>[];

  if (isApprovalSale && ouverte) {
    // Tournée en cours : le stock est géré par close/cancelApprovalOrder, donc
    // les transitions génériques sont remplacées par deux actions dédiées.
    out.add(OrderAction.closeApprovalRound);
    out.add(OrderAction.cancelApprovalRound);
  } else {
    // `_buildStatusAction` rend un BOUTON sur ces deux cas seulement ; ailleurs
    // il rend une pastille en lecture seule, qui n'est pas une action et n'a
    // donc rien à faire dans cette liste.
    if ((status == SaleStatus.scheduled && !canConfirmClient) ||
        status == SaleStatus.processing) {
      out.add(OrderAction.advanceStatus);
    }
    if (canCancel && ouverte && !canConfirmClient) {
      out.add(OrderAction.cancelOrRefuse);
    }
  }

  if (status == SaleStatus.completed) {
    if (canCancel) out.add(OrderAction.reopenPaidSale);
    out.add(OrderAction.invoicePdf);
    out.add(OrderAction.invoiceWhatsApp);
  }

  // ⚠ CETTE CONDITION EST CELLE DE HEAD, délibérément.
  //
  // Un autre chantier la resserrait sur `status == completed` sous le libellé
  // « Encaisser le solde », dans l'arbre de travail et non commité. L'extraire
  // aurait embarqué son changement métier dans ce lot. Elle reste donc celle
  // du dépôt ; le resserrement se fera ICI, en une ligne, quand ce chantier
  // sera relu et commité.
  if (amountDue > 0 &&
      status != SaleStatus.cancelled &&
      status != SaleStatus.refused &&
      status != SaleStatus.refunded) {
    out.add(OrderAction.collectBalance);
  }

  if (ouverte && source != 'web') {
    out.add(OrderAction.relaunchClient);
  }

  if (!isResto &&
      canEdit &&
      status != SaleStatus.cancelled &&
      status != SaleStatus.refused &&
      status != SaleStatus.refunded) {
    out.add(OrderAction.editFees);
  }

  // JAMAIS EN RESTAURATION (26/09/2026). L'action chargeait la commande dans
  // le panier puis menait à la caisse e-commerce ; or « Commander », au
  // restaurant, ignore la commande en cours de modification et en CRÉE une
  // nouvelle (feuille « Type de commande » → envoi en cuisine) : l'originale
  // restait, la commande était DUPLIQUÉE — second bon en cuisine, montant
  // compté deux fois. Au restaurant, une commande se complète par ses propres
  // gestes (ajout de plats à la table, annulation d'une tournée).
  if (!isResto && canEdit && status != SaleStatus.completed) {
    out.add(OrderAction.editOrder);
  }

  // hotfix_084 : le bouton n'apparaît que sur un statut supprimable et une
  // commande jamais encaissée. Le set vient du use case — l'y dupliquer
  // rouvrirait le risque de perte sèche de stock qu'il documente.
  if (canDelete &&
      DeleteSaleUseCase.allowedStatuses.contains(status) &&
      amountPaid <= 0) {
    out.add(OrderAction.deleteOrder);
  }

  return out;
}

/// L'ENCAISSEMENT (« Encaisser & finaliser ») est-il proposé sur cette
/// commande de restaurant ?
///
/// C'est EXACTEMENT la condition du bouton de la carte dépliée, lue à la même
/// source : [orderActionsFor] ne pose [OrderAction.advanceStatus] que là où
/// `_buildStatusAction` rend un bouton (commande programmée sans confirmation
/// client en attente, ou en cours), et jamais sur une tournée « à choisir »,
/// qui a sa propre clôture. En restauration, ce bouton est l'encaissement.
///
/// Le lien « Encaisser & finaliser » de la tuile de grille s'y adosse : il ne
/// peut donc apparaître que là où le bouton déplié existe déjà.
bool settleOffered(List<OrderAction> actions, {required bool isResto}) =>
    isResto && actions.contains(OrderAction.advanceStatus);
