/// FENÊTRES DE TEMPS — la convention de bornes, en un seul endroit.
///
/// DEMI-OUVERTE : `[from, to)`. Le début appartient à la fenêtre, la fin
/// appartient à la SUIVANTE.
///
/// Vingt-deux sites comparaient une date à une fenêtre, et la convention
/// dominante était inclusive des deux côtés. Or les fenêtres s'enchaînent —
/// « Hier » finit à minuit, « Aujourd'hui » commence à minuit — et une vente
/// enregistrée à exactement 00:00:00.000 tombait donc dans les DEUX. Il suffit
/// d'une commande transférée à minuit pile pour qu'un total cesse d'être
/// juste, sans que rien ne le signale.
///
/// Demi-ouverte, les périodes se succèdent sans trou ni recouvrement : le
/// double comptage devient impossible PAR CONSTRUCTION, et non par vigilance
/// à chaque nouveau site de comparaison.
///
/// Écrit ici, dans le noyau, et non à côté de `DashRange` : quatre services de
/// `core/` appliquent la même règle, et leur faire importer une couche
/// `features/` inverserait les dépendances.
library;

/// Cet instant tombe-t-il dans `[from, to)` ?
bool withinWindow(DateTime at, DateTime from, DateTime to) =>
    !at.isBefore(from) && at.isBefore(to);

/// Même règle, pour des bornes FACULTATIVES.
///
/// `null` veut dire « pas de borne de ce côté » — et non « borne à
/// maintenant » : sans date de fin, on veut tout ce qui suit.
bool withinOptionalBounds(DateTime at, {DateTime? from, DateTime? to}) =>
    (from == null || !at.isBefore(from)) && (to == null || at.isBefore(to));
