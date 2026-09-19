import 'employee_permission.dart';

/// LES POSTES DE L'ÉTABLISSEMENT — règles pures (hotfix_160).
///
/// La liste proposée à la création d'un compte vient de deux endroits :
///   * les postes DÉCLARÉS par la boutique (table `job_titles`, synchronisée) ;
///   * les libellés RÉELLEMENT portés par les comptes existants.
///
/// La seconde source n'est pas un doublon de la première : un compte peut
/// porter un poste supprimé de la liste depuis, ou créé sur un appareil dont
/// la synchronisation n'est pas encore passée. L'omettre ferait disparaître de
/// la liste déroulante la fonction de quelqu'un — c'est-à-dire l'effacer à la
/// première modification de sa fiche.
///
/// Aucune dépendance à Flutter, Hive ou Supabase : ces règles sont testées
/// telles quelles.
class JobTitles {
  const JobTitles._();

  /// Deux libellés désignent-ils le même poste ? Comparaison sur le texte
  /// nettoyé et sans casse : « serveur » et « Serveur » ne sont pas deux
  /// postes, et personne ne doit pouvoir créer le second parce que le premier
  /// a été saisi en minuscules.
  static bool same(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  /// Liste affichée : les postes déclarés, puis ceux que des comptes portent
  /// sans qu'ils soient déclarés.
  ///
  /// L'ordre des postes déclarés est CONSERVÉ (pas de tri alphabétique) : il
  /// reflète l'ordre dans lequel l'établissement les a créés, et un tri
  /// ferait sauter les entrées d'une place à l'autre à chaque ajout.
  static List<String> merge(
      Iterable<String> declared, Iterable<String> carried) {
    final out = <String>[];
    for (final raw in [...declared, ...carried]) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (out.any((e) => same(e, t))) continue;
      out.add(t);
    }
    return out;
  }

  /// Noms des personnes qui portent ce poste.
  ///
  /// [byPerson] associe un nom de personne à sa fonction. Sert à REFUSER la
  /// suppression d'un poste encore occupé : le retirer de la liste ne
  /// débaptiserait personne, et la fonction resterait affichée sur des fiches
  /// alors qu'elle n'existerait plus nulle part.
  static List<String> holders(String label, Map<String, String> byPerson) {
    final out = <String>[];
    byPerson.forEach((person, title) {
      if (same(title, label)) out.add(person);
    });
    return out;
  }

  /// Profil de droits d'un poste, tel qu'il est stocké (hotfix_161) : des
  /// clés `EmployeePermission.key` séparées par des virgules.
  ///
  /// `null` en entrée comme en sortie signifie « ce poste ne décide d'aucun
  /// accès » — à distinguer d'un profil VIDE, qui lui retire tout. Confondre
  /// les deux ferait décocher toutes les autorisations en choisissant un
  /// simple libellé de métier.
  static Set<EmployeePermission>? decodePerms(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final out = <EmployeePermission>{};
    for (final k in raw.split(',')) {
      // Une clé inconnue (droit retiré d'une version à l'autre) est ignorée :
      // elle ne doit pas rendre le poste entier illisible.
      final p = EmployeePermissionX.fromKey(k.trim());
      if (p != null) out.add(p);
    }
    return out;
  }

  static String encodePerms(Iterable<EmployeePermission> perms) =>
      perms.map((p) => p.key).join(',');

  /// Cherche le profil du poste [name] dans une table indexée par libellé.
  /// La recherche est insensible à la casse, comme partout ailleurs ici.
  static String? permsFor(Map<String, String> table, String name) {
    for (final e in table.entries) {
      if (same(e.key, name)) return e.value;
    }
    return null;
  }

  /// Phrase de refus de suppression, au bon nombre.
  static String inUseMessage(List<String> holders, String label) {
    if (holders.length == 1) {
      return '« $label » est la fonction de ${holders.first}. '
          'Changez-la d\'abord, ou renommez le poste.';
    }
    return '« $label » est la fonction de ${holders.length} personnes. '
        'Changez-la d\'abord, ou renommez le poste.';
  }
}
