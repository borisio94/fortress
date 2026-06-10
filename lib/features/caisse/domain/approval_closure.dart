/// Réconciliation d'une vente « à choisir sur place » au moment de la clôture.
///
/// Une telle vente RÉSERVE plusieurs articles (le livreur les emporte) ; à son
/// retour, le client en a gardé certains, le reste revient. Ce calcul garantit
/// l'INVARIANT anti-perte de stock : pour chaque article,
///
///     gardé + retourné == réservé
///
/// → rien n'est perdu (tout le réservé est soit vendu, soit remis en stock) et
/// rien n'est compté en double (le gardé est borné à ce qui a été réservé).
///
/// Logique PURE (aucun I/O) → testée unitairement. Le moteur de stock
/// (Phase 1b) appelle ce calcul puis applique : `gardé` = vente définitive,
/// `retourné` = remise en stock.
class ApprovalClosure {
  ApprovalClosure._();

  /// [reserved] : quantité réservée par article (clé = id article/variante).
  /// [kept]     : quantité gardée (vendue) saisie à la clôture, par article.
  ///
  /// Le gardé est borné à `[0, réservé]` (jamais négatif, jamais > réservé) ;
  /// le retourné est déduit automatiquement (`réservé − gardé`).
  static ApprovalReconciliation reconcile({
    required Map<String, int> reserved,
    required Map<String, int> kept,
  }) {
    final keptOut = <String, int>{};
    final returnedOut = <String, int>{};
    reserved.forEach((id, res) {
      if (res <= 0) return; // rien à réconcilier pour cet article
      final raw = kept[id] ?? 0;
      final k = raw < 0 ? 0 : (raw > res ? res : raw); // borne [0, res]
      keptOut[id] = k;
      returnedOut[id] = res - k;
    });
    return ApprovalReconciliation(kept: keptOut, returned: returnedOut);
  }
}

/// Résultat de [ApprovalClosure.reconcile] : pour chaque article réservé, la
/// quantité vendue ([kept]) et la quantité remise en stock ([returned]).
class ApprovalReconciliation {
  final Map<String, int> kept; // vendu (reste sorti du stock)
  final Map<String, int> returned; // remis en stock disponible

  const ApprovalReconciliation({required this.kept, required this.returned});

  /// Total des unités vendues.
  int get totalKept => kept.values.fold(0, (s, v) => s + v);

  /// Total des unités remises en stock.
  int get totalReturned => returned.values.fold(0, (s, v) => s + v);

  /// Articles effectivement gardés (quantité > 0) — la vente finale.
  Map<String, int> get keptNonZero =>
      {for (final e in kept.entries) if (e.value > 0) e.key: e.value};

  /// Articles à remettre en stock (quantité > 0).
  Map<String, int> get returnedNonZero =>
      {for (final e in returned.entries) if (e.value > 0) e.key: e.value};
}
