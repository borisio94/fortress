// ═════════════════════════════════════════════════════════════════════════════
// ArrivalCostingService — valorisation d'un arrivage groupé (e-commerce).
//
// PROBLÈME RÉSOLU
// Un arrivage arrive en UN SEUL BLOC : plusieurs modèles différents, et des
// frais (transport, douane, manutention) qui portent sur le lot entier et
// non sur un produit précis. Le catalogue, lui, ne sait porter un coût que
// produit par produit (`Product.priceBuy` / `ProductVariant.priceBuy`).
// Ce service fait le pont : il éclate le coût du lot en un coût de revient
// unitaire par ligne, puis l'absorbe dans le coût du produit.
//
// RÈGLE DE RÉPARTITION — PAR PIÈCE
// Les frais sont divisés à parts égales sur le nombre total de PIÈCES du
// lot, jamais au prorata de leur valeur : une pièce transportée supporte le
// même transport et la même douane qu'une autre, qu'elle soit chère ou bon
// marché.
//
//     frais_par_pièce   = Σ frais / Σ pièces
//     coût_revient(i)   = prix_achat_unitaire(i) + frais_par_pièce
//
// Exemple (10 pièces, 15 000 F de transport + douane → 1 500 F/pièce) :
//     Montre A · 3 × 5 000  →  6 500 F/pièce
//     Montre B · 5 × 8 000  →  9 500 F/pièce
//     Montre C · 2 × 3 000  →  4 500 F/pièce
//
// ABSORPTION DANS LE COÛT PRODUIT — MOYENNE PONDÉRÉE
// Le stock déjà présent a son propre coût. Le nouveau `priceBuy` mélange
// les deux au prorata des quantités (CUMP) :
//
//     priceBuy = (stock × priceBuy + qté_reçue × coût_revient)
//                / (stock + qté_reçue)
//
// ⚠ NE PAS DOUBLE-COMPTER. Ce coût est absorbé dans `priceBuy` UNIQUEMENT.
// Il ne doit jamais être écrit en plus dans `Product.customsFee` ni dans
// `Product.expenses` (le dashboard les rajoute par unité, cf.
// dashboard_providers), ni saisi comme `Expense` — l'achat sortirait deux
// fois : une fois en coût de revient, une fois en charge.
// ═════════════════════════════════════════════════════════════════════════════

/// Ligne soumise à la répartition. `key` est un identifiant libre (en
/// pratique `ReceptionItem.id`) qui permet de retrouver le résultat.
class ArrivalLine {
  final String key;
  final int    quantity;
  final double unitCost;

  const ArrivalLine({
    required this.key,
    required this.quantity,
    this.unitCost = 0,
  });
}

/// Ligne valorisée : sa part de frais et son coût de revient unitaire.
class CostedArrivalLine {
  final String key;
  final int    quantity;
  final double unitCost;
  final double feePerPiece;

  const CostedArrivalLine({
    required this.key,
    required this.quantity,
    required this.unitCost,
    required this.feePerPiece,
  });

  /// Coût de revient unitaire = prix d'achat + part de frais.
  double get landedUnitCost => unitCost + feePerPiece;

  /// Part des frais du lot supportée par la ligne entière.
  double get feeShare  => feePerPiece * quantity;

  /// Valeur marchandise de la ligne (hors frais).
  double get goodsTotal => unitCost * quantity;

  /// Coût total de la ligne, frais compris.
  double get lineTotal  => landedUnitCost * quantity;
}

/// Résultat complet de la valorisation d'un lot.
class ArrivalCosting {
  final List<CostedArrivalLine> lines;
  final int    totalPieces;
  final double goodsTotal;
  final double feesTotal;
  final double feePerPiece;

  const ArrivalCosting({
    required this.lines,
    required this.totalPieces,
    required this.goodsTotal,
    required this.feesTotal,
    required this.feePerPiece,
  });

  /// Coût total du lot = marchandise + frais.
  double get grandTotal => goodsTotal + feesTotal;

  CostedArrivalLine? lineFor(String key) {
    for (final l in lines) {
      if (l.key == key) return l;
    }
    return null;
  }

  static const ArrivalCosting empty = ArrivalCosting(
    lines: [], totalPieces: 0, goodsTotal: 0, feesTotal: 0, feePerPiece: 0);
}

class ArrivalCostingService {
  const ArrivalCostingService._();

  /// Répartit [feesTotal] sur les pièces de [lines] et renvoie le coût de
  /// revient unitaire de chaque ligne.
  ///
  /// Les lignes à quantité nulle ou négative sont ignorées (elles ne
  /// supportent aucun frais et ne diluent pas la répartition). Aucun
  /// arrondi n'est appliqué : le total des parts est exactement égal aux
  /// frais saisis, quel qu'il soit.
  static ArrivalCosting compute({
    required List<ArrivalLine> lines,
    double feesTotal = 0,
  }) {
    final kept = lines.where((l) => l.quantity > 0).toList();
    if (kept.isEmpty) {
      return ArrivalCosting(
        lines: const [], totalPieces: 0, goodsTotal: 0,
        feesTotal: feesTotal, feePerPiece: 0);
    }

    final totalPieces = kept.fold<int>(0, (s, l) => s + l.quantity);
    final fees        = feesTotal.isFinite && feesTotal > 0 ? feesTotal : 0.0;
    final feePerPiece = fees / totalPieces;

    final costed = kept.map((l) => CostedArrivalLine(
      key:         l.key,
      quantity:    l.quantity,
      unitCost:    l.unitCost < 0 ? 0 : l.unitCost,
      feePerPiece: feePerPiece,
    )).toList();

    return ArrivalCosting(
      lines:       costed,
      totalPieces: totalPieces,
      goodsTotal:  costed.fold(0.0, (s, l) => s + l.goodsTotal),
      feesTotal:   fees,
      feePerPiece: feePerPiece,
    );
  }

  /// Coût unitaire après imputation de frais sur du stock DÉJÀ entré
  /// (bon de « frais seuls » : facture de transport ou quittus de douane
  /// reçu après la marchandise).
  ///
  /// C'est une ADDITION, pas une moyenne : aucune unité neuve n'entre, donc
  /// rien ne se mélange. Chaque pièce déjà comptée supporte simplement sa
  /// part — c'est exactement ce qu'un arrivage aurait fait si la facture
  /// était arrivée à temps.
  static double surchargedUnitCost({
    required double currentUnitCost,
    required double feePerPiece,
  }) {
    if (!feePerPiece.isFinite || feePerPiece <= 0) return currentUnitCost;
    final base = currentUnitCost > 0 ? currentUnitCost : 0.0;
    return base + feePerPiece;
  }

  /// Moyenne pondérée sur un ENSEMBLE de vagues déjà valorisées —
  /// `unitCost` de chaque ligne portant son coût de revient.
  ///
  ///     prix_revient = Σ (qté_i × coût_revient_i) / Σ qté_i
  ///
  /// C'est le recalcul « à partir de l'historique », par opposition à
  /// [weightedAverageUnitCost] qui absorbe UNE vague dans un coût déjà
  /// établi. La différence compte dès qu'on corrige le passé : une moyenne
  /// appliquée incrémentalement ne sait pas retirer la contribution d'une
  /// vague qu'on modifie ou supprime, et le prix dérive un peu plus à
  /// chaque correction. Rejouer l'ensemble redonne toujours le prix qu'on
  /// aurait eu sans l'erreur.
  ///
  /// Renvoie `null` si aucune vague ne porte de quantité : l'appelant doit
  /// alors laisser le prix existant intact plutôt que de le remettre à 0.
  static double? averageOverWaves(Iterable<ArrivalLine> waves) {
    var pieces = 0;
    var value  = 0.0;
    for (final w in waves) {
      if (w.quantity <= 0) continue;
      pieces += w.quantity;
      value  += w.unitCost * w.quantity;
    }
    if (pieces <= 0) return null;
    return value / pieces;
  }

  /// Coût unitaire moyen pondéré après absorption d'un arrivage.
  ///
  /// Cas particuliers :
  ///   * `incomingQty <= 0` → rien n'entre, le coût actuel est conservé.
  ///   * stock actuel nul ou coût actuel jamais renseigné (`<= 0`) → le
  ///     coût entrant devient le coût du produit. Sans ça, un produit au
  ///     `priceBuy` à 0 (jamais valorisé) tirerait la moyenne vers le bas
  ///     et sous-estimerait durablement le coût de revient.
  static double weightedAverageUnitCost({
    required int    currentQty,
    required double currentUnitCost,
    required int    incomingQty,
    required double incomingUnitCost,
  }) {
    if (incomingQty <= 0) return currentUnitCost;
    final qty = currentQty > 0 ? currentQty : 0;
    if (qty == 0 || currentUnitCost <= 0) return incomingUnitCost;
    return (qty * currentUnitCost + incomingQty * incomingUnitCost)
        / (qty + incomingQty);
  }
}
