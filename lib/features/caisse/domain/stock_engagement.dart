import 'entities/sale.dart';

/// Décide du mouvement de stock à appliquer lorsqu'une vente NORMALE
/// (non « à choisir sur place ») change de statut.
///
/// MODÈLE — « stock engagé » : le stock d'une commande est physiquement sorti
/// des disponibles dès que la marchandise quitte le point de vente. C'est le
/// cas quand la commande est :
///   * `processing` — confiée à un livreur / partenaire (en tournée), OU
///   * `completed`  — encaissée et remise au client.
///
/// Avant ce modèle, le stock ne sortait qu'à `completed` : une commande
/// `processing` (déjà partie en livraison) restait comptée disponible →
/// risque de survente. On réserve donc désormais le stock dès `processing`.
///
/// Le flag persistant [SaleStatus] + `stock_reserved` (paramètre [reserved])
/// indique si le stock est DÉJÀ sorti pour cette commande. Combiné avec
/// l'ancien statut, il rend la décision idempotente ET rétro-compatible avec
/// les données antérieures (qui n'ont jamais posé le flag) :
///   * une commande venant de `completed` avait forcément son stock sorti
///     (ancien modèle + ventes POS directes) → pas besoin du flag pour elle ;
///   * une commande `processing` legacy (flag absent) n'avait PAS son stock
///     sorti → il le sera naturellement à sa prochaine transition engageante.
///
/// Logique PURE (aucun I/O) → testée unitairement sur toute la matrice de
/// transitions. Le datasource appelle [decide] puis applique le mouvement et
/// persiste le nouveau flag.
class StockEngagement {
  StockEngagement._();

  /// Vrai si le statut implique que le stock doit être sorti des disponibles.
  static bool engagesStock(SaleStatus s) =>
      s == SaleStatus.processing || s == SaleStatus.completed;

  /// Décide l'action de stock pour une vente normale passant de [oldStatus]
  /// à [newStatus]. [reserved] = valeur courante du flag « stock déjà sorti ».
  static StockDecision decide({
    required SaleStatus oldStatus,
    required SaleStatus newStatus,
    required bool reserved,
  }) {
    // Stock physiquement sorti AVANT cette transition :
    //   - flag posé (réservé à l'envoi sous le nouveau modèle), OU
    //   - ancien statut `completed` (ancien modèle / vente POS directe / data
    //     legacy sans flag : la sortie se faisait à l'encaissement).
    final wasOut = reserved || oldStatus == SaleStatus.completed;
    final wantOut = engagesStock(newStatus);

    if (wantOut && !wasOut) {
      // La marchandise part (ou est encaissée) sans avoir déjà été sortie.
      return const StockDecision(StockAction.decrement, reserved: true);
    }
    if (!wantOut && wasOut) {
      // Retour en arrière (reprogrammation, annulation, refus, remboursement)
      // alors que le stock était sorti → on le restitue.
      return const StockDecision(StockAction.restore, reserved: false);
    }
    // Aucun changement d'engagement (ex: processing→completed déjà réservé,
    // ou scheduled→cancelled jamais sorti) → on aligne juste le flag.
    return StockDecision(StockAction.none, reserved: wantOut && wasOut);
  }
}

/// Action de stock à appliquer suite à une transition de statut.
enum StockAction {
  /// Aucun mouvement de stock.
  none,

  /// Sortir le stock des disponibles (la marchandise part / est vendue).
  decrement,

  /// Remettre le stock en disponible (retour / annulation / remboursement).
  restore,
}

/// Résultat de [StockEngagement.decide] : l'action à appliquer et la nouvelle
/// valeur du flag `stock_reserved` à persister sur la commande.
class StockDecision {
  final StockAction action;
  final bool reserved;
  const StockDecision(this.action, {required this.reserved});
}
