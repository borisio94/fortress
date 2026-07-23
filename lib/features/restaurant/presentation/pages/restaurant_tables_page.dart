import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/restaurant_table_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../widgets/resto_empty_state.dart';
import '../../domain/entities/restaurant_table.dart';

/// Plan de salle — grille des tables colorées par statut (PR-1).
///
/// Offline-first : la lecture vient exclusivement de Hive via
/// [RestaurantTableService] ; le realtime Supabase repeuple Hive puis notifie
/// via `AppDatabase.addListener`, ce qui redéclenche un `setState` ici. Deux
/// appareils (tablette salle / téléphone serveur) restent donc synchronisés.
///
/// PR-1 se limite au cycle de vie de la TABLE (ouvrir un service, réserver,
/// demander l'addition, libérer). La prise de commande par table arrive en
/// PR-2 : le tap sur une table occupée ouvrira alors la commande en cours.
class RestaurantTablesPage extends StatefulWidget {
  final String shopId;

  const RestaurantTablesPage({super.key, required this.shopId});

  @override
  State<RestaurantTablesPage> createState() => _RestaurantTablesPageState();
}

class _RestaurantTablesPageState extends State<RestaurantTablesPage> {
  late final OnDataChanged _listener;

  @override
  void initState() {
    super.initState();
    _listener = (table, sid) {
      if (!mounted) return;
      if (table != 'restaurant_tables') return;
      // Filtre boutique : un push realtime d'une autre boutique du device ne
      // doit pas provoquer de rebuild ici.
      if (sid != widget.shopId) return;
      setState(() {});
    };
    AppDatabase.addListener(_listener);
    // Pull explicite à l'ouverture : la page peut être atteinte par deeplink
    // avant que `_initialPullForShop` n'ait terminé.
    AppDatabase.syncRestaurantTables(widget.shopId);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  List<RestaurantTable> get _tables =>
      RestaurantTableService.tablesForShop(widget.shopId);

  // ── Actions ─────────────────────────────────────────────────────────────

  /// Tap sur une table.
  ///
  /// Libre → ouverture d'un service (saisie des couverts).
  /// Occupée / addition / réservée → feuille d'actions sur le service courant.
  Future<void> _onTapTable(RestaurantTable table) async {
    if (table.isFree) {
      await _openService(table);
    } else if (table.status == RestaurantTableStatus.addition) {
      // Le client a demandé l'addition → on va droit à l'encaissement
      // plutôt qu'à la prise de commande (spec §7).
      _openBill(table);
    } else {
      // Table en service → commande en cours. Les actions sur la table
      // (addition, libérer) restent sur l'appui long.
      _openOrder(table);
    }
  }

  /// Ouvre l'addition de la table.
  void _openBill(RestaurantTable table) {
    context.push('/shop/${widget.shopId}/restaurant/addition/${table.id}');
  }

  /// Ouvre la prise de commande de la table.
  void _openOrder(RestaurantTable table) {
    context.push('/shop/${widget.shopId}/restaurant/table/${table.id}');
  }

  Future<void> _openService(RestaurantTable table) async {
    final covers = await _askCovers(table);
    if (covers == null || !mounted) return;
    final opened =
        await RestaurantTableService.openService(table: table, covers: covers);
    if (!mounted) return;
    // Enchaîne directement sur la prise de commande : ouvrir une table sans
    // rien commander n'a pas de sens en service.
    _openOrder(opened);
  }

  /// Sélecteur de couverts (+/−) borné par la capacité de la table.
  Future<int?> _askCovers(RestaurantTable table) {
    var covers = table.covers ?? table.capacity;
    return showAdaptiveFormSheet<int>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final theme = Theme.of(ctx);
          return AdaptiveFormFrame(
            title: 'Ouvrir ${table.name}',
            subtitle: 'Capacité ${table.capacity} personnes',
            icon: Icons.people_rounded,
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AppFieldLabel('Nombre de couverts'),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _StepperButton(
                        icon: Icons.remove_rounded,
                        // Un service à 0 couvert n'a pas de sens.
                        onTap: covers > 1
                            ? () => setSheetState(() => covers--)
                            : null,
                      ),
                      SizedBox(
                        width: 88,
                        child: Text(
                          '$covers',
                          textAlign: TextAlign.center,
                          style: AppTextStyles.display.copyWith(
                              color: theme.colorScheme.onSurface),
                        ),
                      ),
                      _StepperButton(
                        icon: Icons.add_rounded,
                        // Dépassement de capacité autorisé (tables jointes),
                        // mais plafonné pour éviter les saisies aberrantes.
                        onTap: covers < table.capacity + 6
                            ? () => setSheetState(() => covers++)
                            : null,
                      ),
                    ],
                  ),
                  if (covers > table.capacity) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Au-delà de la capacité de la table '
                      '(${table.capacity} places).',
                      style: AppTextStyles.caption
                          .copyWith(color: theme.semantic.warning),
                    ),
                  ],
                  const SizedBox(height: 20),
                  AppPrimaryButton(
                    label: 'Ouvrir la table',
                    icon: Icons.check_rounded,
                    fullWidth: true,
                    onTap: () => Navigator.of(ctx).pop(covers),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Actions disponibles sur une table en service.
  Future<void> _showTableActions(RestaurantTable table) async {
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text(table.name, style: AppTextStyles.subtitleBold),
            Text(table.status.label,
                style: AppTextStyles.captionHint),
            const SizedBox(height: 8),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.receipt_long_rounded,
                  color: theme.semantic.danger),
              title: Text(table.status == RestaurantTableStatus.addition
                  ? 'Voir l\'addition'
                  : 'Demander l\'addition'),
              subtitle: const Text('Récapitulatif, partage et encaissement'),
              onTap: () async {
                Navigator.of(ctx).pop();
                // Bascule le statut avant d'ouvrir : la table doit passer
                // en rouge sur le plan de salle dès que le client réclame
                // l'addition, même si le serveur n'encaisse pas tout de suite.
                if (table.status != RestaurantTableStatus.addition) {
                  await RestaurantTableService.requestBill(table);
                }
                if (mounted) _openBill(table);
              },
            ),
            ListTile(
              leading: Icon(Icons.check_circle_outline_rounded,
                  color: theme.semantic.success),
              title: const Text('Libérer la table'),
              subtitle: const Text('Remet la table en statut Libre'),
              onTap: () {
                Navigator.of(ctx).pop();
                RestaurantTableService.release(table);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Formulaire de création d'une table (nom + capacité).
  Future<void> _createTable() async {
    final nameCtrl = TextEditingController();
    final capCtrl = TextEditingController(text: '4');
    final suggested = RestaurantTableService.nextNumber(widget.shopId);
    nameCtrl.text = 'T$suggested';

    final created = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (ctx) => AdaptiveFormFrame(
        title: 'Nouvelle table',
        subtitle: 'Table n°$suggested',
        icon: Icons.restaurant_rounded,
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppFieldLabel('Nom de la table', required: true),
              const SizedBox(height: 8),
              AppField(
                controller: nameCtrl,
                hint: 'T$suggested',
                autofocus: true,
                prefixIcon: Icons.label_outline_rounded,
              ),
              const SizedBox(height: 16),
              const AppFieldLabel('Capacité (couverts)', required: true),
              const SizedBox(height: 8),
              AppField(
                controller: capCtrl,
                hint: '4',
                numbersOnly: true,
                keyboardType: TextInputType.number,
                prefixIcon: Icons.people_outline_rounded,
              ),
              const SizedBox(height: 20),
              AppPrimaryButton(
                label: 'Créer la table',
                icon: Icons.add_rounded,
                fullWidth: true,
                onTap: () => Navigator.of(ctx).pop(true),
              ),
            ],
          ),
        ),
      ),
    );

    if (created != true) {
      nameCtrl.dispose();
      capCtrl.dispose();
      return;
    }

    final name = nameCtrl.text.trim();
    // Capacité bornée : une saisie vide ou absurde retombe sur 4 plutôt que
    // de créer une table à 0 place (rendrait le sélecteur de couverts inerte).
    final capacity = (int.tryParse(capCtrl.text.trim()) ?? 4).clamp(1, 99);
    nameCtrl.dispose();
    capCtrl.dispose();

    await RestaurantTableService.addTable(
      shopId: widget.shopId,
      name: name.isEmpty ? 'T$suggested' : name,
      capacity: capacity,
    );
    if (!mounted) return;
    AppSnack.success(context, 'Table créée');
  }

  Future<void> _deleteTable(RestaurantTable table) async {
    if (!table.isFree) {
      AppSnack.error(context,
          'Impossible : ${table.name} est en cours de service.');
      return;
    }
    await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer ${table.name} ?',
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      confirmColor: Theme.of(context).semantic.danger,
      onConfirm: () =>
          RestaurantTableService.deleteTable(table.id, widget.shopId),
    );
  }

  // ── Rendu ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tables = _tables;
    return AppScaffold(
      title: 'Plan de salle',
      shopId: widget.shopId,
      // Masqué quand il n'y a aucune table : l'état vide porte déjà son
      // bouton de création, et deux options d'ajout simultanées se
      // concurrenceraient à l'écran.
      floatingActionButton: tables.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _createTable,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Table'),
            ),
      body: tables.isEmpty
          ? RestoEmptyState(
              icon: Icons.restaurant_rounded,
              title: 'Aucune table',
              subtitle: 'Créez vos tables pour composer le plan de salle '
                  'de votre établissement.',
              actionLabel: 'Créer une table',
              onAction: _createTable,
            )
          : Column(
              children: [
                const _StatusLegend(),
                Expanded(child: _buildGrid(tables)),
              ],
            ),
    );
  }

  Widget _buildGrid(List<RestaurantTable> tables) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Grille fluide : ~150 dp par carte, 2 colonnes minimum sur mobile.
        final columns = (constraints.maxWidth / 150).floor().clamp(2, 8);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.95,
          ),
          itemCount: tables.length,
          itemBuilder: (_, i) => _TableCard(
            table: tables[i],
            onTap: () => _onTapTable(tables[i]),
            // Appui long : actions sur la table elle-même. Sur une table en
            // service on propose addition/libération ; sur une table libre,
            // la seule action sensée est la suppression.
            onLongPress: () => tables[i].isFree
                ? _deleteTable(tables[i])
                : _showTableActions(tables[i]),
          ),
        );
      },
    );
  }
}

/// Légende des statuts, affichée en tête du plan de salle.
class _StatusLegend extends StatelessWidget {
  const _StatusLegend();

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Wrap(
        spacing: 14,
        runSpacing: 8,
        children: [
          for (final status in RestaurantTableStatus.values)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: status.color(semantic),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(status.label, style: AppTextStyles.captionHint),
              ],
            ),
        ],
      ),
    );
  }
}

/// Carte d'une table — couleur et icône dérivées du statut.
class _TableCard extends StatelessWidget {
  final RestaurantTable table;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _TableCard({
    required this.table,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    final accent = table.status.color(semantic);

    return Material(
      color: table.status.surface(semantic),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accent.withValues(alpha: 0.45)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(table.status.icon, color: accent, size: 26),
              const SizedBox(height: 6),
              Text(
                table.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.subtitleBold.copyWith(color: accent),
              ),
              const SizedBox(height: 2),
              Text(
                table.status.label,
                style: AppTextStyles.caption.copyWith(color: accent),
              ),
              const SizedBox(height: 4),
              Text(
                // Table libre → on affiche la capacité (information utile pour
                // placer un groupe) ; en service → les couverts réels.
                table.isFree
                    ? '${table.capacity} places'
                    : '${table.covers ?? table.capacity} couverts',
                style: AppTextStyles.captionHint,
              ),
              if (table.status == RestaurantTableStatus.reservee &&
                  table.reservationTime != null)
                Text(
                  _hhmm(table.reservationTime!),
                  style: AppTextStyles.microBold.copyWith(color: accent),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

/// Bouton rond +/− du sélecteur de couverts. `onTap: null` → désactivé.
class _StepperButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _StepperButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    return Material(
      color: enabled
          ? theme.colorScheme.primary.withValues(alpha: 0.10)
          : theme.semantic.trackMuted,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            icon,
            size: 22,
            color: enabled
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}
