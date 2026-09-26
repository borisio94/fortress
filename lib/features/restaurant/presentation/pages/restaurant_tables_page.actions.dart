part of 'restaurant_tables_page.dart';

// Le MENU D'ACTIONS d'une table — sorti de
// `_RestaurantTablesPageState._showTableActions` le 26/09/2026 (lot « classes
// géantes »). Quelles actions proposer se décide dans le domaine
// (`tableActionsFor`, sous test) ; cette feuille les affiche et rend celle qui
// est choisie ; la page l'exécute.

/// La feuille d'actions d'une table : son nom, son statut, puis [actions].
///
/// Rend la [TableAction] choisie, `null` si la feuille est fermée.
class _TableActionsSheet extends StatelessWidget {
  final RestaurantTable table;
  final List<TableAction> actions;

  const _TableActionsSheet({required this.table, required this.actions});

  Widget _tile(BuildContext context, TableAction a) {
    final theme = Theme.of(context);
    void pick() => Navigator.of(context).pop(a);
    return switch (a) {
      TableAction.bill => ListTile(
          leading:
              Icon(Icons.receipt_long_rounded, color: theme.semantic.danger),
          title: Text(table.status == RestaurantTableStatus.addition
              ? 'Voir l\'addition'
              : 'Demander l\'addition'),
          subtitle: const Text('Récapitulatif, partage et encaissement'),
          onTap: pick,
        ),
      // Comptes de la table : consulter, TRANSFÉRER vers une autre table,
      // FUSIONNER. Ces deux opérations n'existent nulle part ailleurs — elles
      // étaient atteintes par le tap sur la carte, elles se rangent
      // naturellement ici.
      TableAction.tabs => ListTile(
          leading:
              Icon(Icons.receipt_outlined, color: theme.colorScheme.primary),
          title: const Text('Comptes de la table'),
          subtitle: const Text('Consulter, transférer, fusionner'),
          onTap: pick,
        ),
      TableAction.covers => ListTile(
          leading: Icon(Icons.event_seat_outlined,
              color: theme.colorScheme.primary),
          title: const Text('Des places se libèrent'),
          subtitle: Text(
              '${table.covers ?? table.capacity} couverts sur '
              '${table.capacity} — ajustez si des convives sont partis'),
          onTap: pick,
        ),
      TableAction.release => ListTile(
          leading: Icon(Icons.check_circle_outline_rounded,
              color: theme.semantic.success),
          title: const Text('Libérer la table'),
          subtitle: const Text('Remet la table en statut Libre'),
          onTap: pick,
        ),
      TableAction.cancelReservation => ListTile(
          leading:
              Icon(Icons.event_busy_outlined, color: theme.semantic.warning),
          title: const Text('Annuler la réservation'),
          subtitle: Text('Retenue pour '
              '${_hhmmOf(table.reservationTime)}'
              '${(table.reservationName ?? '').trim().isEmpty
                  ? ''
                  : ' — ${table.reservationName!.trim()}'}'),
          onTap: pick,
        ),
      TableAction.reserve => ListTile(
          leading: Icon(Icons.access_time_rounded,
              color: theme.colorScheme.primary),
          title: const Text('Réserver la table'),
          subtitle: const Text('Retenue jusqu\'à l\'arrivée du client'),
          onTap: pick,
        ),
      TableAction.delete => ListTile(
          leading:
              Icon(Icons.delete_outline_rounded, color: theme.semantic.danger),
          title: const Text('Supprimer la table'),
          subtitle: const Text('Possible tant qu\'aucun service n\'y '
              'est ouvert'),
          onTap: pick,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Text(table.name, style: AppTextStyles.subtitleBold),
          // `displayStatus` : une réservation périmée s'annonce « Libre »,
          // comme partout ailleurs.
          Text(table.displayStatus.label, style: AppTextStyles.captionHint),
          const SizedBox(height: 8),
          const Divider(height: 1),
          for (final a in actions) _tile(context, a),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
