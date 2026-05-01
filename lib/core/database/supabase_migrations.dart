import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:supabase_flutter/supabase_flutter.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Migrations Supabase — pousse le SQL canonique (supabase/migrations/*.sql)
// via la fonction exec_sql. Pré-requis : bootstrap.sql exécuté une fois.
//
// Suivi par fichier dans la table app_migrations (une ligne par fichier
// appliqué). Les nouvelles migrations sont détectées et exécutées une seule
// fois, indépendamment des anciennes.
// ═══════════════════════════════════════════════════════════════════════════

class SupabaseMigrations {
  static const _chunkSeparator = '-- @@CHUNK@@';

  /// Liste ordonnée des fichiers de migration à appliquer.
  static const _migrationAssets = [
    'supabase/migrations/001_activity_and_rpcs.sql',
    'supabase/migrations/002_shop_admin_activity_policy.sql',
    'supabase/migrations/003_activity_logs_realtime.sql',
    'supabase/migrations/004_orders_completed_at.sql',
    'supabase/migrations/005_orders_fees.sql',
    'supabase/migrations/006_expenses.sql',
    'supabase/migrations/007_purge_activity_logs.sql',
    'supabase/migrations/008_clients_address.sql',
  ];

  static Future<void> runIfNeeded() async {
    try {
      final db = Supabase.instance.client;

      // Pré-check : `exec_sql` est verrouillé aux super-admins depuis
      // hotfix_040. Pour les utilisateurs normaux, on ne tente même pas
      // (sinon une erreur 42501 est loggée pour chaque chunk).
      // Les migrations seront appliquées manuellement par un super-admin
      // depuis le SQL Editor.
      if (!await _canRunMigrations(db)) {
        debugPrint('[Migrations] Skip — exec_sql réservé aux super-admins '
            '(comportement attendu, app fonctionne normalement)');
        return;
      }

      // Bootstrap de la table de suivi (idempotent).
      final tracked = await _appliedMigrations(db);

      for (final asset in _migrationAssets) {
        if (tracked.contains(asset)) continue;
        debugPrint('[Migrations] Application de $asset');
        final sql = await rootBundle.loadString(asset);
        final chunks = sql
            .split(_chunkSeparator)
            .map((c) => c.trim())
            .where((c) => c.isNotEmpty)
            .toList();
        for (var i = 0; i < chunks.length; i++) {
          debugPrint('[Migrations] $asset chunk ${i + 1}/${chunks.length}');
          await db.rpc('exec_sql', params: {'sql': chunks[i]});
        }
        await _markApplied(db, asset);
      }
      debugPrint('[Migrations] OK');
    } catch (e) {
      // Si malgré le pré-check on tombe sur le 42501 (race condition
      // ou cache stale), on l'avale silencieusement.
      final msg = e.toString();
      if (msg.contains('exec_sql réservé') || msg.contains('42501')) {
        debugPrint('[Migrations] Skip — privilèges insuffisants');
      } else {
        debugPrint('[Migrations] Erreur: $e');
      }
    }
  }

  /// Test léger : peut-on appeler `exec_sql` ? Évite de logguer N erreurs
  /// 42501 quand l'utilisateur n'est pas super-admin (comportement normal
  /// depuis hotfix_040).
  static Future<bool> _canRunMigrations(SupabaseClient db) async {
    try {
      await db.rpc('exec_sql', params: {'sql': 'SELECT 1'});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Crée la table de suivi si absente et retourne les migrations déjà appliquées.
  /// Rétro-compat : si l'ancienne installation a déjà activity_logs mais pas
  /// app_migrations, on marque 001 comme appliquée automatiquement.
  static Future<Set<String>> _appliedMigrations(SupabaseClient db) async {
    try {
      await db.rpc('exec_sql', params: {
        'sql': 'CREATE TABLE IF NOT EXISTS app_migrations ('
               'name TEXT PRIMARY KEY, '
               'applied_at TIMESTAMPTZ NOT NULL DEFAULT now())',
      });
      final rows = await db.from('app_migrations').select('name') as List;
      final applied = rows.map((r) => r['name'] as String).toSet();
      // Rétro-marque 001 si activity_logs existe déjà (installation pré-002).
      if (!applied.contains(_migrationAssets.first)
          && await _activityLogsExists(db)) {
        await _markApplied(db, _migrationAssets.first);
        applied.add(_migrationAssets.first);
      }
      return applied;
    } catch (e) {
      debugPrint('[Migrations] _appliedMigrations erreur: $e');
      return {};
    }
  }

  static Future<void> _markApplied(SupabaseClient db, String name) async {
    try {
      await db.from('app_migrations')
          .upsert({'name': name}, onConflict: 'name');
    } catch (e) {
      debugPrint('[Migrations] _markApplied erreur: $e');
    }
  }

  /// PostgREST ne permet pas d'interroger information_schema directement :
  /// on teste donc la table par une SELECT légère. Une erreur "relation
  /// does not exist" signale son absence.
  static Future<bool> _activityLogsExists(SupabaseClient db) async {
    try {
      await db.from('activity_logs').select('id').limit(1);
      return true;
    } catch (_) {
      return false;
    }
  }
}
