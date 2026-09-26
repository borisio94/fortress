/// UNE CATÉGORIE PAR NOM, quelle que soit la façon de l'écrire.
///
/// La catégorie d'un plat est une chaîne libre (`products.category_id` porte
/// le NOM, il n'y a pas d'entité). « Plats » et « plats » faisaient donc deux
/// onglets au Menu — alors que les noms de PLATS, eux, sont dédoublonnés sans
/// casse ni accents par `nameKey`. Les catégories suivent désormais la même
/// règle, avec la même fonction.
///
/// Rien n'est réécrit en base : on REGROUPE à la lecture. Retirer ce
/// regroupement rendrait les onglets exactement tels qu'ils étaient.
library;

import '../../../core/utils/name_key.dart';

/// Libellé retenu pour chaque clé `nameKey`, à partir des catégories
/// rencontrées (une entrée par plat, ou une par catégorie déclarée).
///
/// Le libellé est l'orthographe LA PLUS PORTÉE — celle que la salle a
/// réellement adoptée ; à égalité, la première dans l'ordre alphabétique, pour
/// que deux appareils affichent le même onglet. Vides et `null` ignorés.
Map<String, String> categoryLabels(Iterable<String?> raw) {
  final uses = <String, Map<String, int>>{};
  for (final c in raw) {
    final label = c?.trim() ?? '';
    if (label.isEmpty) continue;
    final forms = uses.putIfAbsent(nameKey(label), () => {});
    forms[label] = (forms[label] ?? 0) + 1;
  }
  return {
    for (final e in uses.entries)
      e.key: (e.value.entries.toList()
            ..sort((a, b) => b.value != a.value
                ? b.value.compareTo(a.value)
                : a.key.compareTo(b.key)))
          .first
          .key,
  };
}

/// Même catégorie, à la casse, aux accents et aux espaces près ?
bool sameCategory(String? a, String? b) =>
    a != null && b != null && nameKey(a) == nameKey(b);
