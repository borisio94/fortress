// ─────────────────────────────────────────────────────────────────────────────
// SchemaMigrator — Migrations versionnées appliquées sur les Maps des entités
// désérialisées depuis Hive ou Supabase.
//
// Pourquoi : quand on faire évoluer une entité (renommage de champ, ajout
// de valeur par défaut, nouveau format, etc.), les anciennes données
// stockées doivent rester lisibles SANS que l'utilisateur final ait à
// supprimer puis recréer ses données. Ce migrator applique les
// transformations nécessaires AU MOMENT DE LA LECTURE, de manière
// idempotente et automatique.
//
// Convention :
//   * Chaque entité déclare une `static final SchemaMigrator` avec un
//     `currentVersion` (commence à 1) et un registre de `steps`.
//   * `steps[N]` est une fonction qui transforme un map en version N
//     vers la version N+1. Doit être pure et idempotente.
//   * Le map sérialisé porte un champ `schema_version` (int). S'il est
//     absent → traité comme `v1` (legacy avant l'introduction du pattern).
//   * Au `fromMap` de l'entité : on appelle `_migrator.migrate(raw)` AVANT
//     de parser. Au `toMap` : on stamp `schema_version: currentVersion`.
//
// Exemple d'usage :
//
// ```dart
// class Product {
//   static final _migrator = SchemaMigrator(
//     currentVersion: 2,
//     steps: {
//       1: (m) {
//         // v1 → v2 : split `full_name` en `first_name` + `last_name`
//         final full = (m['full_name'] as String?) ?? '';
//         final parts = full.split(' ');
//         m['first_name'] = parts.first;
//         m['last_name']  = parts.length > 1
//             ? parts.sublist(1).join(' ') : '';
//         m.remove('full_name');
//         return m;
//       },
//     },
//   );
// }
// ```
//
// Persistance vs réapplication :
//   * Le map retourné par `migrate()` contient toujours
//     `schema_version: currentVersion`. Si tu écris CE map dans Hive,
//     la migration devient persistée → ne se re-applique plus à la
//     prochaine lecture.
//   * Sinon (lecture pure depuis Supabase sans write-back), la migration
//     se re-applique à chaque lecture. C'est OK car idempotent — au pire
//     un peu de CPU gaspillé. À optimiser si la migration est coûteuse.
//
// Supabase / multi-device :
//   * Si tu veux que les autres devices voient la migration sans la
//     ré-appliquer, ajoute `schema_version` à la colonne Supabase et
//     pousse le map migré (`bgUpsert`). Sinon chaque device migre
//     localement (idempotent, safe).
// ─────────────────────────────────────────────────────────────────────────────

class SchemaMigrator {
  /// Version cible. Bump ce nombre quand tu introduis une nouvelle
  /// transformation, et ajoute la step correspondante dans `steps`.
  final int currentVersion;

  /// Step fonctions indexées par la **version de départ**.
  /// `steps[N]` doit transformer un map v(N) en v(N+1). Les keys
  /// manquantes (gaps) sont silencieusement skippées — utile si une
  /// version intermédiaire n'a pas besoin de transformation structurelle.
  final Map<int, Map<String, dynamic> Function(Map<String, dynamic>)> steps;

  const SchemaMigrator({
    required this.currentVersion,
    this.steps = const {},
  });

  /// True si [raw] doit être migré pour atteindre [currentVersion].
  bool needsMigration(Map raw) {
    final v = (raw['schema_version'] as int?) ?? 1;
    return v < currentVersion;
  }

  /// Applique toutes les migrations nécessaires pour amener [raw] à
  /// [currentVersion]. Retourne une **copie** du map (raw n'est pas muté).
  /// Le map retourné porte `schema_version: currentVersion`.
  ///
  /// Idempotent : si [raw] est déjà à la bonne version, retourne juste
  /// une copie sans modification métier.
  Map<String, dynamic> migrate(Map<String, dynamic> raw) {
    var m = Map<String, dynamic>.from(raw);
    int v = (m['schema_version'] as int?) ?? 1;
    while (v < currentVersion) {
      final step = steps[v];
      if (step != null) {
        m = step(m);
      }
      v++;
    }
    m['schema_version'] = currentVersion;
    return m;
  }
}
