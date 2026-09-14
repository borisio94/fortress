/// Ce qu'une commande représente pour le résultat de la boutique, déduit de
/// son statut.
///
/// SOURCE UNIQUE de cette règle. Elle était écrite DEUX FOIS, mot pour mot,
/// dans `dashboard_providers.dart` (le moteur principal et le calcul de
/// tendance) — et l'export des commandes, lui, ne la connaissait pas du
/// tout : il sortait le montant d'une commande annulée exactement comme
/// celui d'une vente encaissée. Sommer la colonne « Montant » d'un export
/// donnait donc un nombre qui ne correspondait à aucune grandeur du tableau
/// de bord.
///
/// Trois copies auraient été le bug de demain : il suffit qu'un statut soit
/// ajouté à l'une et oubliée dans les autres pour que deux écrans affichent
/// deux vérités. Ce fichier vit dans `core/` parce que `features/dashboard`
/// et `features/caisse` doivent y accéder sans dépendre l'un de l'autre.
enum OrderRevenueClass {
  /// Vente encaissée — entre dans le chiffre d'affaires.
  revenue,

  /// Commande perdue — remboursée, annulée ou refusée. Entre dans les
  /// pertes, à sa valeur faciale.
  loss,

  /// Ni l'un ni l'autre : programmée, en cours. Le tableau de bord ne la
  /// somme NULLE PART, et c'est délibéré — ce n'est pas du chiffre
  /// d'affaires à venir, seulement une commande dont l'issue est inconnue.
  /// Aucun total ne doit donc être produit pour cette famille : il ne
  /// pourrait s'accorder avec rien.
  pending,
}

/// Classe un statut de commande. Tout statut inconnu est `pending` — jamais
/// `revenue` : un statut qu'on ne sait pas lire ne doit pas gonfler le
/// chiffre d'affaires.
OrderRevenueClass classifyOrderStatus(String? status) => switch (status) {
      'completed' => OrderRevenueClass.revenue,
      'refunded' || 'cancelled' || 'refused' => OrderRevenueClass.loss,
      _ => OrderRevenueClass.pending,
    };

extension OrderRevenueClassX on OrderRevenueClass {
  /// Libellé court pour les exports. Volontairement bref : il occupe une
  /// colonne de tableau, pas une phrase.
  String get labelFr => switch (this) {
        OrderRevenueClass.revenue => 'CA',
        OrderRevenueClass.loss    => 'Perte',
        OrderRevenueClass.pending => 'En attente',
      };
}
