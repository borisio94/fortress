/// VERDICT SUR UNE ERREUR DE SYNCHRONISATION — règles pures.
///
/// La file hors-ligne doit trancher, à chaque échec : cette écriture peut-elle
/// encore aboutir, ou l'insister est-il sans espoir ? Une erreur jugée
/// définitive fait abandonner l'opération — sauf sur une table protégée, où
/// elle la fait seulement journaliser (`sync_protected_tables.dart`).
///
/// Neuf codes Postgres ne se résolvent jamais en réessayant. Le dixième, si.
library;

import 'sync_protected_tables.dart';

/// Une erreur définitive : réessayer la même charge utile ne changera pas la
/// réponse du serveur.
///
/// [table] n'est consulté que pour la clé étrangère, seul code dont le verdict
/// dépende de ce qu'on écrit.
bool isDefinitiveSyncError(String err, String table) {
  // ── 23503 : CLÉ ÉTRANGÈRE — TEMPORAIRE, et c'est délibéré ───────────────
  //
  // NE REMETS PAS CE CODE DANS LA LISTE CI-DESSOUS en croyant réparer un
  // oubli. Il y était, et l'y laisser était le contresens.
  //
  // Les neuf autres codes décrivent une écriture INVALIDE : colonne absente,
  // contrainte violée, droit refusé. Rien de ce que le client peut faire n'y
  // changera quoi que ce soit. 23503 dit autre chose : « la ligne parente
  // n'est pas là ». C'est une question d'ORDRE D'ARRIVÉE, pas de validité —
  // et le parent peut très bien arriver au vidage suivant.
  //
  // POURQUOI ÇA COMPTE ICI, concrètement : `stock_movements`, `receptions` et
  // `incidents` sont protégées depuis le 19/09/2026, mais leurs parents —
  // `products`, `purchase_orders`, `suppliers` — ne le sont pas. Un parent
  // abandonné après dix tentatives laisse derrière lui un enfant que la base
  // refusera à chaque envoi. Abandonner l'enfant aussi, c'est perdre le
  // journal de stock — que `reconcileShop` LIT pour reconstruire les
  // quantités. Un journal amputé reconstruit un stock faux, puis l'écrit.
  //
  // L'EXCEPTION S'ARRÊTE AUX TABLES PROTÉGÉES, et cette borne n'est pas
  // décorative : ailleurs, une op réellement invalide se rejouerait sans fin
  // sur une table que rien ne surveille, et la file grossirait pour un cas de
  // bord. Sur une table protégée, au contraire, la chaîne de visibilité
  // existe déjà — l'op emporte sa cause serveur dès le premier échec, entre
  // dans le journal à la troisième tentative, et rejoint les opérations
  // bloquées de l'écran de synchronisation à la dixième, où elle peut être
  // abandonnée à la main.
  //
  // CE QUE ÇA NE FAIT PAS : sur une table protégée, l'op restait déjà en file
  // quand 23503 était classée définitive. Ce verdict ne change donc pas son
  // sort — il rend la règle vraie, et le journal moins bavard.
  if (err.contains('23503')) return !kProtectedSyncTables.contains(table);

  return err.contains('23505') || // duplicate key
      err.contains('42501') || // permission denied
      err.contains('42502') || // insufficient privilege
      err.contains('23502') || // not null violation
      // ── DÉRIVE DE SCHÉMA ────────────────────────────────────────────
      // Client et base ne s'accordent plus. Réessayer la même charge
      // utile ne changera jamais la réponse : seule une migration le
      // peut. Ces trois cas tombaient jusqu'ici dans « erreur
      // temporaire », d'où dix rejeux inutiles suivis du log aveugle
      // « Abandoned after 10 retries » — un message qui a déjà fait
      // conclure à tort à un succès, alors que l'écriture était perdue.
      //
      // Vécu deux fois : le CHECK `stock_movements.type` (hotfix_176) et
      // la catégorie `storage` absente du CHECK `expenses` (hotfix_177).
      //
      // Sur une table protégée cela ne change PAS le sort de l'op — elle
      // reste en file dans les deux cas. Ce qui change est le journal : la
      // vraie cause serveur est écrite dès le PREMIER échec, au lieu
      // d'attendre la 3ᵉ tentative.
      err.contains('23514') || // violation de contrainte CHECK
      err.contains('42703') || // colonne inconnue (code Postgres brut)
      // PostgREST n'expose pas toujours le code brut : pour une colonne
      // absente de son cache de schéma, il répond PGRST204. Couvrir les
      // deux formes supprime la dépendance à celle qui arrive.
      err.contains('PGRST204') ||
      // RAISE EXCEPTION métier (PL/pgSQL) — codes émis intentionnellement
      // par les RPC pour signaler une règle de domaine violée
      // (delete_sale → suppression_statut_invalide, motif_required, …).
      // Réessayer la même charge utile ne changera jamais la réponse.
      err.contains('P0001') || // raise_exception
      err.contains('P0002'); // no_data_found
}
