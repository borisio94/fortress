/// Synthèse de la dette partenaire d'UNE commande, dérivée du livre de
/// comptes ([PartnerLedgerEntry] filtrées par `orderId`).
///
/// Calculée en une seule passe pour toutes les commandes visibles
/// (cf. `PartnerLedgerService.debtByOrder`) — jamais un appel par
/// commande.
///
/// Convention :
///   * [amount]        = dette brute enregistrée pour la commande (somme
///     des entrées négatives `deliveryOwed`/`partnerCharge`, en valeur
///     absolue, ≥ 0).
///   * [isCompensated] = `true` si des encaissements/versements liés à la
///     même commande (entrées positives : `saleCollected`, `remittance`)
///     couvrent au moins cette dette → la bannière ne doit plus s'afficher.
class PartnerDebtInfo {
  final double amount;
  final bool   isCompensated;

  const PartnerDebtInfo({
    required this.amount,
    required this.isCompensated,
  });

  /// Dette réellement à afficher : strictement positive ET non compensée.
  bool get isOutstanding => amount > 0 && !isCompensated;
}
