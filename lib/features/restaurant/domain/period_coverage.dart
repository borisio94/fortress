/// CE QUE COUVRE UNE PÉRIODE — règles pures, sans Flutter.
///
/// Le nom ne suffit pas. « Mois » a longtemps valu trente jours glissants sans
/// que personne le sache ; « Année » vaut aujourd'hui les douze derniers mois,
/// pas l'année civile. Le sélecteur écrit donc, à côté de chaque nom, les
/// dates qu'il va réellement prendre : c'est la seule formulation qui ne peut
/// pas mentir, puisqu'elle est calculée depuis la même fenêtre que les
/// chiffres (`rangeFor`).
library;

import '../../dashboard/data/dashboard_providers.dart';

const _months = [
  'janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin',
  'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.',
];

String _day(int d) => d == 1 ? '1er' : '$d';

/// « 24 sept. » — avec l'année seulement si elle n'est pas celle en cours.
String formatCoverageDay(DateTime d, {required DateTime now}) {
  final base = '${_day(d.day)} ${_months[d.month - 1]}';
  return d.year == now.year ? base : '$base ${d.year}';
}

/// Plage de JOURS lisible : « 1er → 24 sept. », « 18 août → 24 sept. »,
/// « 24 sept. » pour un jour seul.
///
/// [range] est DEMI-OUVERTE (`[from, to)`, cf. `DashRange.contains`) : le
/// dernier jour affiché est donc la veille de `to`.
String formatCoverageRange(DashRange range, {required DateTime now}) {
  final first = DateTime(range.from.year, range.from.month, range.from.day);
  final last = DateTime(range.to.year, range.to.month, range.to.day - 1);
  if (!last.isAfter(first)) return formatCoverageDay(first, now: now);

  final lastLabel = formatCoverageDay(last, now: now);
  // Même mois, même année : le mois ne s'écrit qu'une fois, à la fin.
  if (first.year == last.year && first.month == last.month) {
    return '${_day(first.day)} → $lastLabel';
  }
  // Années différentes : les deux bornes portent la leur, sinon « 1er oct. →
  // 24 sept. » se lirait comme un intervalle à l'envers.
  if (first.year != last.year) {
    final l = '${_day(last.day)} ${_months[last.month - 1]} ${last.year}';
    return '${_day(first.day)} ${_months[first.month - 1]} ${first.year} → $l';
  }
  return '${formatCoverageDay(first, now: now)} → $lastLabel';
}

/// Ce que couvre [period], écrit pour la feuille de choix.
///
/// « 7 derniers jours » plutôt que des dates pour la semaine : c'est ce qu'on
/// cherche à savoir (glissante ou calendaire ?), et des dates ne le disent
/// qu'à qui fait le calcul.
String periodCoverage(DashPeriod period, DashRange range,
    {required DateTime now}) {
  if (period == DashPeriod.week) return '7 derniers jours';
  return formatCoverageRange(range, now: now);
}
