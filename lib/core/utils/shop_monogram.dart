/// LE MONOGRAMME D'UNE BOUTIQUE.
///
/// L'avatar du tiroir affichait le bouclier Fortress dès qu'aucun logo n'était
/// posé — c'est-à-dire presque toujours. Le même dessin pour toutes les
/// boutiques, à 34 dp : un pictogramme qui n'identifie rien.
///
/// Un monogramme, lui, dit de quelle boutique il s'agit. Et il ne remplace
/// aucun choix de l'utilisateur : le logo, quand il existe, passe toujours
/// devant.
///
/// LE BOUCLIER RESTE LE REPLI, et c'est la règle qui compte ici. Un nom vide,
/// fait d'espaces, de ponctuation ou d'émojis ne produit aucune lettre —
/// afficher une pastille vide serait pire que le pictogramme générique. Cette
/// fonction rend donc `null` plutôt que d'inventer un caractère.
library;

/// Les initiales d'un nom de boutique, ou `null` s'il n'en donne aucune.
///
/// DEUX LETTRES QUAND LE NOM A DEUX MOTS, une sinon : « Chez Awa » donne
/// « CA », « Fortress » donne « F ». Au-delà de deux, le monogramme cesse
/// d'être lisible à 34 dp.
///
/// Seules les LETTRES et les CHIFFRES comptent. Un nom comme « ★ Resto ★ »
/// rend « R », pas « ★ » — et « 24/7 Shop » rend « 2S », parce qu'un chiffre
/// initial est parfaitement lisible et fréquent dans les enseignes.
String? shopMonogram(String? name) {
  final words = (name ?? '')
      // Espaces, tirets et tirets bas séparent des MOTS. La barre oblique,
      // non : « 24/7 Shop » est une enseigne en deux mots, et la découper en
      // trois donnerait « 27 », qui ne désigne rien.
      .split(RegExp(r'[\s\-_]+'))
      .map(_firstAlnum)
      .whereType<String>()
      .toList();
  if (words.isEmpty) return null;
  if (words.length == 1) return words.first;
  return words[0] + words[1];
}

/// Le premier caractère alphanumérique d'un mot, en majuscule, ou `null`.
String? _firstAlnum(String word) {
  for (final c in word.split('')) {
    if (RegExp(r'[0-9a-zA-ZÀ-ÖØ-öø-ÿ]').hasMatch(c)) return c.toUpperCase();
  }
  return null;
}
