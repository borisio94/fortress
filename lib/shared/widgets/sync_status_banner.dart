import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/theme/app_colors.dart';

/// État résumé du sync pour l'UI :
///   * `errorsCount` : nombre d'erreurs permanentes journalisées (sync_errors)
///   * `stuckCount`  : ops critiques (orders/sales/expenses) bloquées ≥ 10 essais
///   * `pendingCount`: ops en queue (informatif)
class SyncStatus {
  final int errorsCount;
  final int stuckCount;
  final int pendingCount;
  const SyncStatus({
    required this.errorsCount,
    required this.stuckCount,
    required this.pendingCount,
  });

  /// Critère d'affichage de la bannière "Synchro incomplète" :
  ///   - `stuckCount > 0`  → ops critiques bloquées : signal toujours valide.
  ///   - `errorsCount > 0 && pendingCount > 0` → erreurs ET ops en attente :
  ///     la sync est réellement incomplète.
  ///
  /// On NE déclenche PAS sur `errorsCount > 0` seul : une liste d'erreurs
  /// sans aucune op en attente représente des erreurs déjà résolues ou
  /// abandonnées, pas un état de sync incomplet actuel. La feuille de
  /// détails reste accessible si le user veut auditer ces erreurs
  /// passées (via un futur point d'entrée Paramètres).
  bool get hasFailure =>
      stuckCount > 0 || (errorsCount > 0 && pendingCount > 0);
}

/// Provider qui poll AppDatabase toutes les 3 s. Léger : appels Hive
/// synchrones, pas d'I/O réseau.
final syncStatusProvider = StreamProvider<SyncStatus>((ref) async* {
  SyncStatus snapshot() => SyncStatus(
        errorsCount:  AppDatabase.getSyncErrors().length,
        stuckCount:   AppDatabase.stuckCriticalOpsCount,
        pendingCount: AppDatabase.pendingOpsCount,
      );
  yield snapshot();
  await for (final _ in Stream.periodic(const Duration(seconds: 3))) {
    yield snapshot();
  }
});

/// Banner orange visible **même en ligne** quand des ops Supabase ont
/// échoué de manière permanente OU sont bloquées depuis longtemps.
///
/// Sans ça, un utilisateur qui croit ses actions synchronisées peut
/// continuer à travailler en local pendant que Supabase n'a pas reçu
/// ses ventes/transferts/etc. — divergence silencieuse.
///
/// Tap → sheet listant les erreurs avec actions Réessayer / Vider la queue.
/// Complémentaire du `OfflineBanner` (qui ne s'affiche QUE hors ligne).
class SyncStatusBanner extends ConsumerWidget {
  const SyncStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider).valueOrNull;
    if (status == null || !status.hasFailure) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => _showSheet(context, ref, status),
      child: Container(
        width: double.infinity,
        color: const Color(0xFFF59E0B), // ambre
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(children: [
          const Icon(Icons.sync_problem_rounded,
              color: Colors.white, size: 15),
          const SizedBox(width: 8),
          Expanded(child: Text(
            _label(status),
            style: const TextStyle(
                color: Colors.white, fontSize: 12,
                fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          )),
          const Icon(Icons.chevron_right_rounded,
              color: Colors.white70, size: 16),
        ]),
      ),
    );
  }

  String _label(SyncStatus s) {
    final parts = <String>[];
    if (s.stuckCount > 0) {
      parts.add('${s.stuckCount} vente(s)/dépense(s) bloquée(s)');
    }
    if (s.errorsCount > 0) {
      parts.add('${s.errorsCount} erreur(s) de sync');
    }
    return 'Synchro incomplète — ${parts.join(" · ")}';
  }

  void _showSheet(BuildContext context, WidgetRef ref, SyncStatus s) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _SyncErrorsSheet(initial: s),
    );
  }
}

class _SyncErrorsSheet extends ConsumerStatefulWidget {
  final SyncStatus initial;
  const _SyncErrorsSheet({required this.initial});
  @override
  ConsumerState<_SyncErrorsSheet> createState() => _SyncErrorsSheetState();
}

class _SyncErrorsSheetState extends ConsumerState<_SyncErrorsSheet> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final errors = AppDatabase.getSyncErrors();
    final stuck  = AppDatabase.stuckCriticalOpsCount;
    final pend   = AppDatabase.pendingOpsCount;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
            Center(child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                  color: const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(2)),
            )),
            const SizedBox(height: 14),
            const Text('Synchronisation',
                style: TextStyle(fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A))),
            const SizedBox(height: 4),
            Text('$pend op(s) en attente · $stuck bloquée(s) · '
                '${errors.length} erreur(s)',
                style: const TextStyle(fontSize: 12,
                    color: Color(0xFF6B7280))),
            const SizedBox(height: 12),
            if (errors.isEmpty && stuck == 0)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text(
                  'Aucune erreur récente. La queue se vide automatiquement.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                  textAlign: TextAlign.center)),
              )
            else
              Flexible(child: ListView.separated(
                shrinkWrap: true,
                itemCount: errors.length,
                separatorBuilder: (_, __) => const Divider(
                    height: 1, color: Color(0xFFF0F0F0)),
                itemBuilder: (_, i) {
                  final e = Map<String, dynamic>.from(errors[i]);
                  final t = e['time'] as String?;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('${e['table'] ?? '?'} · ${e['op'] ?? '?'}',
                          style: const TextStyle(fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A))),
                      const SizedBox(height: 2),
                      Text(e['error']?.toString() ?? '',
                          maxLines: 3, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11,
                              color: Color(0xFF6B7280))),
                      if (t != null) ...[
                        const SizedBox(height: 2),
                        Text(t.substring(0, 19).replaceAll('T', ' '),
                            style: const TextStyle(fontSize: 10,
                                color: Color(0xFF9CA3AF))),
                      ],
                    ]),
                  );
                },
              )),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: _busy ? null : _retryAll,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Tout réessayer',
                    style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(color: AppColors.primary),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
              )),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(
                onPressed: _busy ? null : _confirmDiscard,
                icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                label: const Text('Vider la queue',
                    style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
              )),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _retryAll() async {
    setState(() => _busy = true);
    try {
      await AppDatabase.resetQueueRetries();
      await AppDatabase.flushOfflineQueue();
      // Purger les erreurs résolues : on garde celles qui ré-échoueront
      // au prochain cycle (le _logSyncError ré-écrit les permanentes).
      try { await AppDatabase.clearSyncErrors(); } catch (_) {}
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vider la queue ?'),
        content: const Text(
            'Toutes les opérations en attente seront SUPPRIMÉES sans être '
            'envoyées à Supabase. Action destructive — préférez "Tout '
            'réessayer" si possible.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Vider')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await AppDatabase.clearSyncQueue();
      try { await AppDatabase.clearSyncErrors(); } catch (_) {}
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        Navigator.of(context).pop();
      }
    }
  }
}
