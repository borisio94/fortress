/// Synthèse de la dette partenaire d'UNE commande, dérivée du livre de
/// comptes ([PartnerLedgerEntry] filtrées par `orderId`).
///
/// Calculée en une seule passe pour toutes les commandes visibles
/// (cf. `PartnerLedgerService.debtByOrder`) — jamais un appel par
/// commande.
///
/// Convention :
///   * [amount]        = RESTE DÛ par la boutique pour la commande, après
///     imputation FIFO des crédits du partenaire (cf.
///     `PartnerLedgerService.computeOrderDebts`), ≥ 0. Ce n'est plus le
///     frais d'origine : un frais réglé à moitié affiche la moitié restante.
///   * [isCompensated] = `true` si ce reste est nul à la tolérance d'arrondi
///     près → la bannière ne doit plus s'afficher.
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
