/// LES TABLES QUI NE DOIVENT JAMAIS PERDRE UNE ÉCRITURE — règles pures.
///
/// La file de synchronisation hors-ligne abandonne une opération dans deux
/// cas : après dix tentatives, ou immédiatement sur une erreur permanente. Une
/// op abandonnée reste dans Hive sur l'appareil qui l'a saisie et n'existe
/// nulle part ailleurs — c'est de la perte de données, pas un calcul faux.
///
/// UNE SEULE LISTE, TROIS PRÉDICATS. Le code portait trois listes distinctes,
/// écrites à trois endroits, et elles avaient divergé :
///
///   * `partner_ledger_entries` survivait aux erreurs permanentes mais était
///     supprimée après dix tentatives — protection à moitié effective ;
///   * `restaurant_tables` était protégée des deux abandons mais n'alertait
///     jamais l'utilisateur, donc disparaissait de son attention.
///
/// Rien ne documentait ces écarts. Trois listes qui doivent dire la même chose
/// finissent toujours par ne plus la dire, et un test le vérifie désormais
/// pour toute table.
///
/// CE QUE ÇA COÛTE, et c'est assumé : une op définitivement invalide reste en
/// file et se rejoue à chaque vidage. Sans moyen d'en abandonner une seule, la
/// protection concentrerait la perte au lieu de l'étaler — « Vider la queue »
/// les perdrait toutes d'un coup. C'est pourquoi l'écran de synchronisation
/// (`sync_status_banner`, `AppDatabase.pendingOps`, `discardOp`) est arrivé
/// AVANT cette liste, et non après.
library;

/// Toute table qui porte de l'argent, ou qui sert à en calculer.
///
/// Le critère n'est pas l'importance ressentie : il suffit qu'un chiffre du
/// bilan ou de la caisse en dépende. Une table absente d'ici voit ses écritures
/// abandonnées sans bruit.
///
/// Cf. la section 11 de `docs/fortress-definition-financiere-restaurant.md`.
const Set<String> kProtectedSyncTables = {
  // ── Ventes et encaissement ──────────────────────────────────────────
  'orders',
  'sales',
  'payments',
  'cash_closures',
  'bottle_deposits',

  // ── Dépenses et charges ─────────────────────────────────────────────
  // `expenses` est l'e-commerce, `daily_expenses` le restaurant : deux tables
  // distinctes, deux boîtes Hive distinctes. Seule la première était protégée,
  // et la proximité des noms faisait croire que l'autre l'était aussi.
  'expenses',
  'daily_expenses',
  'fixed_charges',
  'receptions',

  // ── Personnel ───────────────────────────────────────────────────────
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

  // ── Matière et stock ────────────────────────────────────────────────
  // `stock_movements` et `receptions` sont PARTAGÉES avec l'e-commerce. Les
  // exclure aurait protégé les boutiques en production d'une file qui grossit,
  // au prix de leur laisser perdre des mouvements de stock en silence —
  // hotfix_176 a montré que le scénario est réel, pas théorique.
  'ingredients',
  'recipe_ingredients',
  'losses',
  'incidents',
  'stock_movements',
  'stock_items',
  'restaurant_activities',

  // ── Structure et tiers ──────────────────────────────────────────────
  // Le plan de salle n'est pas financier, il est le point d'ancrage de toutes
  // les commandes en salle (hotfix_180) : une création abandonnée après dix
  // essais n'existerait que sur l'appareil qui l'a saisie, puis plus nulle
  // part après le premier resync — et les commandes rattachées avec elle.
  'restaurant_tables',
  'partner_ledger_entries',
};

/// Cette écriture survit-elle à une ERREUR PERMANENTE ?
///
/// Une erreur permanente — colonne absente, contrainte violée, droit refusé —
/// ne se résout pas en réessayant. Le réflexe par défaut est donc de jeter
/// l'op. Pour une table d'argent, jeter en silence est pire que garder : la
/// ligne reste consultable sur cet appareil, l'écran de synchronisation la
/// montre, et l'utilisateur peut l'abandonner lui-même en connaissance de
/// cause.
bool survivesPermanentError(String table) =>
    kProtectedSyncTables.contains(table);

/// Cette écriture survit-elle au PLAFOND DE DIX TENTATIVES ?
///
/// Sans plafond, une file se remplirait à l'infini sur des erreurs réelles.
/// Avec lui, une vente perdue est du cash perdu. Les tables protégées sont donc
/// réessayées indéfiniment — et c'est précisément ce qui rend l'écran de
/// synchronisation nécessaire : quelqu'un doit pouvoir trancher.
bool survivesRetryCap(String table) => kProtectedSyncTables.contains(table);

/// Cette écriture, bloquée, DOIT-ELLE ALERTER l'utilisateur ?
///
/// Le troisième prédicat est celui qu'on oublie, et son absence annule les deux
/// autres : une op qui survit sans que personne ne le sache est une op perdue
/// avec un délai. C'est lui qui alimente la bannière « Synchro incomplète ».
bool countsAsStuck(String table) => kProtectedSyncTables.contains(table);
