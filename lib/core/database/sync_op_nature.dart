/// NATURE D'UNE OPÉRATION DE SYNCHRONISATION — règles pures.
///
/// Une opération en file porte un nom de TABLE : `daily_expenses`,
/// `staff_penalties`, `recipe_ingredients`. Ces noms sont exacts et
/// inutilisables devant un commerçant.
///
/// La bannière disait « N vente(s)/dépense(s) bloquée(s) », ce qui tenait tant
/// que trois tables seulement étaient surveillées. Dès qu'on en protège une
/// vingtaine, la phrase devient fausse — un pointage n'est ni une vente ni une
/// dépense — et la solution évidente, nommer la table, donnerait
/// « staff_penalties bloquée » à quelqu'un qui cherche sa recette du jour.
///
/// Sept natures couvrent tout, et une table inconnue retombe sur [autres]
/// plutôt que sur son nom technique.
library;

/// Ce qu'une opération bloquée représente pour celui qui la lit.
enum SyncOpNature {
  ventes('Ventes et commandes'),
  caisse('Argent de la caisse'),
  depenses('Dépenses et achats'),
  personnel('Personnel'),
  stock('Stock et recettes'),
  salle('Plan de salle'),
  partenaires('Partenaires'),
  autres('Autres');

  const SyncOpNature(this.label);

  /// Libellé affichable tel quel, au singulier collectif.
  final String label;
}

/// Tables regroupées par nature.
///
/// L'ordre des entrées n'a aucune importance : la recherche se fait par
/// appartenance. Ce qui compte, c'est qu'AUCUNE table surveillée ne manque —
/// une table absente d'ici s'affichera « Autres », ce qui est acceptable mais
/// moins utile.
const Map<SyncOpNature, Set<String>> kSyncNatureTables = {
  SyncOpNature.ventes: {'orders', 'sales'},
  SyncOpNature.caisse: {'payments', 'cash_closures', 'bottle_deposits'},
  SyncOpNature.depenses: {
    'expenses',
    'daily_expenses',
    'fixed_charges',
    'receptions',
  },
  SyncOpNature.personnel: {
    'payroll',
    'salary_advances',
    'time_records',
    'staff_penalties',
    'staff_absences',
    'staff_contests',
    'staff_ratings',
    'employees',
    'job_titles',
    'staff_settings',
  },
  SyncOpNature.stock: {
    'stock_movements',
    'stock_items',
    'ingredients',
    'recipe_ingredients',
    'losses',
    'incidents',
    'restaurant_activities',
    'products',
    'purchase_orders',
  },
  SyncOpNature.salle: {'restaurant_tables'},
  SyncOpNature.partenaires: {'partner_ledger_entries'},
};

/// Nature d'une table. [SyncOpNature.autres] si elle n'est pas répertoriée.
///
/// JAMAIS le nom de la table en repli : un libellé technique devant un
/// commerçant est pire qu'un libellé vague.
SyncOpNature syncNatureOf(String table) {
  for (final entry in kSyncNatureTables.entries) {
    if (entry.value.contains(table)) return entry.key;
  }
  return SyncOpNature.autres;
}

/// Compte les opérations par nature, de la plus nombreuse à la moins.
///
/// Rend une liste et non une map : l'ordre d'affichage est une décision de
/// cette fonction, pas de l'écran qui la consomme.
List<({SyncOpNature nature, int count})> syncCountsByNature(
    Iterable<String> tables) {
  final totals = <SyncOpNature, int>{};
  for (final t in tables) {
    final n = syncNatureOf(t);
    totals[n] = (totals[n] ?? 0) + 1;
  }
  final out = [
    for (final e in totals.entries) (nature: e.key, count: e.value),
  ]..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      // À égalité, l'ordre de l'énumération : stable d'un affichage à l'autre,
      // sinon deux natures ex æquo permuteraient à chaque rafraîchissement.
      return byCount != 0 ? byCount : a.nature.index.compareTo(b.nature.index);
    });
  return out;
}
