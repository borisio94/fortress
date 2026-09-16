/// CLÉ DE COMPARAISON D'UN NOM SAISI À LA MAIN.
///
/// Deux noms désignent la même chose quand ils ne diffèrent que par la casse,
/// les accents ou les espaces : « Poulet  DG », « poulet dg » et « Poulet Dg »
/// sont le même plat — et c'est très exactement sous ces formes-là que les
/// doublons se créent, au fil du service, par deux personnes différentes.
///
/// Comparer les clés, jamais les chaînes brutes :
/// ```dart
/// if (nameKey(saisi) == nameKey(existant.name)) { … }
/// ```
///
/// La table d'accents couvre le français et les langues voisines. Elle est
/// écrite à la main plutôt que tirée d'un paquet de normalisation Unicode :
/// une dépendance de plus pour vingt-six caractères ne se justifiait pas, et la
/// table se lit d'un coup d'œil.
String nameKey(String raw) {
  const accents = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿ';
  const plain = 'aaaaaaceeeeiiiinooooouuuuyy';
  final buf = StringBuffer();
  for (final ch in raw.toLowerCase().trim().split('')) {
    final i = accents.indexOf(ch);
    buf.write(i >= 0 ? plain[i] : ch);
  }
  // Espaces internes réduits à un seul : la frappe double souvent la barre
  // d'espace, et « Poulet  DG » ne doit pas passer pour un autre plat.
  return buf.toString().replaceAll(RegExp(r'\s+'), ' ');
}
