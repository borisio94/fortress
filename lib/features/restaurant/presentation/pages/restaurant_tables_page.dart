import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/manager_gate.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../core/services/restaurant_table_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../widgets/resto_fab.dart';
import '../widgets/resto_empty_state.dart';
import '../../domain/room_headline.dart';
import '../../domain/table_actions.dart';
import '../widgets/table_covers_sheet.dart';
import '../widgets/table_form_sheet.dart';
import '../widgets/table_reservation_sheet.dart';
import '../../domain/entities/restaurant_table.dart';
import '../../domain/table_service_age.dart';
import '../../../../shared/providers/order_attach_provider.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/services/restaurant_tab_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/services/service_incident_service.dart';
import '../../../../core/widgets/touch_target.dart';
import '../widgets/resto_section_header.dart';
import '../widgets/state_stripe.dart';
import '../widgets/table_status_visuals.dart';

part 'restaurant_tables_page.card.dart';
part 'restaurant_tables_page.sheets.dart';
part 'restaurant_tables_page.actions.dart';

/// Plan de salle — grille des tables colorées par statut (PR-1).
///
/// Offline-first : la lecture vient exclusivement de Hive via
/// [RestaurantTableService] ; le realtime Supabase repeuple Hive puis notifie
/// via `AppDatabase.addListener`, ce qui redéclenche un `setState` ici. Deux
/// appareils (tablette salle / téléphone serveur) restent donc synchronisés.
///
/// L'écran se limite au cycle de vie de la TABLE : demander l'addition,
/// consulter les comptes, ajuster les couverts, libérer, créer et supprimer.
/// La prise de commande, elle, passe entièrement par le Menu.
///
/// ─── QUI PEUT COMPOSER LE PLAN DE SALLE ────────────────────────────────────
///
/// L'écran reste OUVERT à tout membre : c'est l'écran de service de la salle,
/// un serveur doit y lire l'état des tables. Mais COMPOSER le plan — créer une
/// table, en supprimer une — demande `canEditShopInfo` : le plan de salle est
/// une propriété de l'établissement, au même titre que son nom ou ses horaires,
/// pas un geste de service.
///
/// Rien ne le gardait, ni ici, ni la route, ni le service : n'importe quel
/// membre pouvait supprimer une table — et la suppression est dure.
///
/// Aucun des trois préréglages de restauration (serveur, caissier, cuisinier)
/// ne porte cette permission ; le gérant peut la déléguer explicitement.
class RestaurantTablesPage extends ConsumerStatefulWidget {
  final String shopId;

  const RestaurantTablesPage({super.key, required this.shopId});

  @override
  ConsumerState<RestaurantTablesPage> createState() =>
      _RestaurantTablesPageState();
}

class _RestaurantTablesPageState
    extends ConsumerState<RestaurantTablesPage> {
  late final OnDataChanged _listener;

  /// Droit de composer le plan de salle — créer et supprimer une table.
  ///
  /// Les deux ensemble, à dessein : on ne laisse pas quelqu'un créer ce qu'il
  /// ne pourra pas corriger. Lu à la demande plutôt que mémorisé, pour suivre
  /// un changement de rôle sans recharger l'écran.
  bool get _canManageRoom =>
      ref.read(permissionsProvider(widget.shopId)).canEditShopInfo;

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

  // Le tap sur une table ouvrait ici la prise de commande (service, choix du
  // compte, écran de commande). Retiré : la carte est devenue informative, et
  // toute commande passe par le Menu. Ne subsistent que les actions sur la
  // TABLE, derrière le bouton ⋮ de la carte.

  /// Libère la table, en annonçant ce qui reste à encaisser.
  ///
  /// Libérer détache les commandes encore ouvertes : elles survivent, mais quittent
  /// le plan de salle. Le faire en silence ferait disparaître de l'argent du
  /// champ de vision du serveur — d'où la confirmation chiffrée.
  Future<void> _releaseTable(RestaurantTable table) async {
    final tabs = RestaurantTabService.tabsForTable(widget.shopId, table.id);
    if (tabs.isNotEmpty) {
      final total = tabs.fold<double>(0, (s, t) => s + t.total);
      final ok = await AppConfirmDialog.show(
        context: context,
        icon: Icons.warning_amber_rounded,
        iconColor: Theme.of(context).semantic.warning,
        title: 'Libérer avec des commandes ouvertes ?',
        body: Text(
            '${tabs.length} commande${tabs.length > 1 ? 's' : ''} '
            'non réglé${tabs.length > 1 ? 's' : ''} · '
            '${CurrencyFormatter.format(total)}\n\n'
            'Ces additions ne seront pas perdues : elles restent encaissables '
            'depuis Commandes, mais quittent le plan de salle.'),
        cancelLabel: 'Annuler',
        confirmLabel: 'Libérer quand même',
        onConfirm: () {},
      );
      if (ok != true) return;
    }
    await RestaurantTableService.release(table);
    if (mounted) setState(() {});
  }

  /// Feuille des commandes d'une table : consulter, transférer, fusionner.
  Future<void> _openTabs(
      RestaurantTable table, List<RestaurantTab> tabs) async {
    await showAdaptiveFormSheet<void>(
      context: context,
      builder: (_) => _TabsSheet(
        shopId: widget.shopId,
        table: table,
        tabs: tabs,
        allTables: RestaurantTableService.tablesForShop(widget.shopId),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Ouvre l'addition de la table.
  void _openBill(RestaurantTable table) {
    context.push('/shop/${widget.shopId}/restaurant/addition/${table.id}');
  }

  /// Des convives sont partis (ou arrivés) : on ajuste les couverts SANS
  /// libérer la table.
  ///
  /// C'est ce qui permet de placer deux clients sur une table de six déjà
  /// entamée — courant quand on partage les grandes tables. Libérer la table
  /// entière ferait disparaître l'addition des clients restés assis.
  Future<void> _editCovers(RestaurantTable table) async {
    final covers = await _askCovers(table,
        title: 'Couverts — ${table.name}',
        confirmLabel: 'Enregistrer les couverts');
    if (covers == null || !mounted) return;
    final updated = await RestaurantTableService.updateCovers(table, covers);
    if (!mounted) return;
    setState(() {});
    final free = updated.capacity - (updated.covers ?? updated.capacity);
    AppSnack.success(
        context,
        free > 0
            ? '${updated.name} — $free place${free > 1 ? 's' : ''} libre'
                '${free > 1 ? 's' : ''}'
            : '${updated.name} — table complète');
  }

  // `_openService` (saisie des couverts puis prise de commande) a disparu avec
  // le tap sur la carte : c'est la feuille « Type de commande » du Menu qui
  // ouvre désormais le service en posant la table et ses couverts.

  /// Sélecteur de couverts (+/−) borné par la capacité de la table — la
  /// feuille `TableCoversSheet`.
  Future<int?> _askCovers(RestaurantTable table,
      {String? title, String? confirmLabel}) {
    return showAdaptiveFormSheet<int>(
      context: context,
      builder: (_) => TableCoversSheet(
          table: table, title: title, confirmLabel: confirmLabel),
    );
  }

  /// Actions sur la TABLE — jamais sur la commande.
  ///
  /// Seule porte d'action du plan de salle depuis que la carte est devenue
  /// informative : elle ouvrait la prise de commande au tap, or toute commande
  /// passe par le Menu. Ce qui reste ici relève de la table elle-même.
  ///
  /// Le choix des actions selon l'état de la table est dans le domaine
  /// (`tableActionsFor`) ; la feuille `_TableActionsSheet` les affiche.
  Future<void> _showTableActions(RestaurantTable table) async {
    final theme = Theme.of(context);
    final action = await showModalBottomSheet<TableAction>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _TableActionsSheet(
        table: table,
        actions: tableActionsFor(table, canManageRoom: _canManageRoom),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case TableAction.bill:
        // Bascule le statut avant d'ouvrir : la table doit passer en rouge
        // sur le plan de salle dès que le client réclame l'addition, même si
        // le serveur n'encaisse pas tout de suite.
        if (table.status != RestaurantTableStatus.addition) {
          await RestaurantTableService.requestBill(table);
        }
        if (mounted) _openBill(table);
      case TableAction.tabs:
        _openTabs(
            table, RestaurantTabService.tabsForTable(widget.shopId, table.id));
      case TableAction.covers:
        _editCovers(table);
      case TableAction.release:
        _releaseTable(table);
      case TableAction.cancelReservation:
        _cancelReservation(table);
      case TableAction.reserve:
        _reserveTable(table);
      case TableAction.delete:
        _deleteTable(table);
    }
  }

  /// Formulaire de création d'une table.
  ///
  /// Le formulaire vit dans `table_form_sheet.dart`, et cet écran est son SEUL
  /// appelant. L'écran de mise en route n'ouvre pas ce formulaire : il pousse
  /// vers cette page, qui reste donc l'unique endroit où une table se crée.
  Future<void> _createTable() async {
    // Filet, en plus du bouton qui n'est pas rendu : une méthode de State reste
    // appelable autrement que par son bouton.
    if (!_canManageRoom) return;
    final outcome =
        await showTableForm(context: context, shopId: widget.shopId);
    if (outcome == null || !mounted) return;
    setState(() {});
    if (outcome == TableWriteOutcome.ok) {
      AppSnack.success(context, 'Table créée');
    } else {
      // La table est partie au push, mais elle n'est PAS dans la grille : le
      // dire, plutôt que de laisser chercher une table qu'on vient d'annoncer.
      AppSnack.warning(
          context,
          'Table enregistrée, mais pas sur cet appareil. '
          'Elle apparaîtra après synchronisation.');
    }
  }

  /// Pose une réservation sur une table libre.
  ///
  /// GESTE DE SERVICE, ouvert à tout membre — pas de `canEditShopInfo` : un
  /// client appelle, le serveur qui décroche note. Exiger le droit de composer
  /// la salle obligerait à déranger le gérant pour un coup de fil.
  Future<void> _reserveTable(RestaurantTable table) async {
    final outcome =
        await showTableReservationSheet(context: context, table: table);
    if (outcome == null || !mounted) return;
    setState(() {});
    if (outcome == TableWriteOutcome.ok) {
      AppSnack.success(context, '${table.name} réservée');
    } else {
      AppSnack.warning(
          context,
          'Réservation enregistrée, mais pas sur cet appareil. '
          'Elle apparaîtra après synchronisation.');
    }
  }

  /// Annule une réservation VIVANTE — la table redevient libre tout de suite.
  ///
  /// Une réservation périmée n'a pas besoin de ce geste : la table est déjà
  /// libre aux yeux de l'app, la courtoisie ayant fait son office.
  Future<void> _cancelReservation(RestaurantTable table) async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.event_busy_outlined,
      iconColor: Theme.of(context).semantic.warning,
      title: 'Annuler la réservation ?',
      body: Text(
        '${table.name} était retenue pour '
        '${_hhmmOf(table.reservationTime)}'
        '${(table.reservationName ?? '').trim().isEmpty ? '' : ' au nom de '
            '${table.reservationName!.trim()}'}.\n\n'
        'La table redevient libre immédiatement.',
      ),
      cancelLabel: 'Garder',
      confirmLabel: 'Annuler la réservation',
      confirmColor: Theme.of(context).semantic.warning,
      onConfirm: () {},
    );
    if (ok != true) return;
    final result = await RestaurantTableService.release(table);
    if (!mounted) return;
    setState(() {});
    if (result.outcome == TableWriteOutcome.ok) {
      AppSnack.success(context, 'Réservation annulée — ${table.name} est libre');
    } else {
      AppSnack.warning(
          context,
          'Réservation annulée, mais cet appareil n\'a pas pu enregistrer le '
          'changement. Il s\'appliquera après synchronisation.');
    }
  }

  Future<void> _deleteTable(RestaurantTable table) async {
    // Même filet. La suppression est DURE : elle ne doit pas dépendre du seul
    // rendu d'une entrée de menu.
    if (!_canManageRoom) return;
    if (!table.isFree) {
      AppSnack.error(context,
          'Impossible : ${table.name} est en cours de service.');
      return;
    }
    // Ce que la table a servi, dit AVANT de la retirer. Une table libre peut
    // n'avoir jamais servi, ou avoir porté deux cents additions : la même
    // question posée sans ce chiffre appelle la même réponse dans les deux cas.
    final served = RestaurantOrderService.servedCountFor(table);
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer ${table.name} ?',
      body: Text(
        served == 0
            ? '${table.name} n\'a encore servi aucune commande.\n\n'
                'Elle quitte le plan de salle ; son numéro redevient '
                'disponible.'
            : '${table.name} a servi $served commande'
                '${served > 1 ? 's' : ''}.\n\n'
                'Elle quitte le plan de salle, mais son historique reste '
                'intact : les commandes gardent son nom. Son numéro redevient '
                'disponible.',
      ),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      confirmColor: Theme.of(context).semantic.danger,
      onConfirm: () {},
    );
    if (ok != true) return;
    final outcome =
        await RestaurantTableService.deleteTable(table.id, widget.shopId);
    if (!mounted) return;
    setState(() {});
    // Le service dit ce qui s'est passé : annoncer une suppression qui n'a pas
    // eu lieu laisserait chercher une table encore à l'écran.
    switch (outcome) {
      case TableWriteOutcome.ok:
        AppSnack.success(context, '${table.name} retirée du plan de salle');
      case TableWriteOutcome.notStoredLocally:
        AppSnack.warning(
            context,
            '${table.name} a été retirée, mais cet appareil n\'a pas pu '
            'enregistrer le changement. Il s\'appliquera après '
            'synchronisation.');
      case TableWriteOutcome.notFound:
        AppSnack.error(context, 'Suppression impossible : table introuvable.');
    }
  }

  // ── Rendu ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tables = _tables;
    // `watch` et non `read` ici : le rendu DÉPEND du droit, il doit se refaire
    // si le rôle change (arrivée des permissions après un deep-link).
    final canManage =
        ref.watch(permissionsProvider(widget.shopId)).canEditShopInfo;
    return AppScaffold(
      title: 'Plan de salle',
      shopId: widget.shopId,
      // LE BOUTON FLOTTANT, seul appel de création (cf. `RestoFab`). Absent
      // sans le droit de composer la salle — proposer un bouton qui refuserait
      // ensuite serait pire que ne rien proposer — et sur une salle vide, dont
      // l'état vide porte son propre bouton.
      floatingActionButton: (tables.isEmpty || !canManage)
          ? null
          : RestoFab(tooltip: 'Ajouter une table', onPressed: _createTable),
      // Salle vide : l'en-tête reste — le NOM de la page ne dépend pas de
      // son contenu (lot Shell, 25/09/2026).
      body: tables.isEmpty
          ? Column(children: [
              const RestoSectionHeader(
                  title: 'Plan de salle', subtitle: 'aucune table'),
              Expanded(
                child: RestoEmptyState(
                  icon: Icons.restaurant_rounded,
                  title: 'Aucune table',
                  subtitle: canManage
                      ? 'Créez vos tables pour composer le plan de salle '
                          'de votre établissement.'
                      // Sans le droit, l'état vide reste informatif : il dit ce
                      // qui manque et qui peut y remédier, sans bouton mort.
                      : 'Le plan de salle n\'a pas encore été composé. '
                          'Demandez au gérant d\'ajouter les tables.',
                  actionLabel: canManage ? 'Créer une table' : null,
                  onAction: canManage ? _createTable : null,
                ),
              ),
            ])
          : _buildRoom(tables, canManage),
    );
  }

  Widget _buildRoom(List<RestaurantTable> tables, bool canManage) {
    // Les commandes et comptes sont lus UNE fois par table, ici, et servent à
    // la carte ET à l'en-tête : les deux ne peuvent donc pas se contredire.
    final views = [
      for (final t in tables) _TableView.of(widget.shopId, t),
    ];
    final headline = roomHeadline([
      for (final v in views)
        (
          capacity: v.table.capacity,
          covers: v.table.covers,
          inService: v.inService,
        ),
    ]);
    return LayoutBuilder(
      builder: (context, constraints) {
        // ~150 dp par carte : cinq colonnes là où il y en avait trois. La
        // carte ne porte plus que quatre lignes de texte, qui ne demandent pas
        // un carré.
        final columns = (constraints.maxWidth / 150).floor().clamp(2, 8);
        return Column(children: [
          _RoomHeader(
            headline: headline,
            // La légende n'a sa place À DROITE que si la ligne est large ;
            // sinon elle passe sous le décompte.
            wide: constraints.maxWidth >= kRoomLegendBesideMin,
          ),
          Expanded(
            child: GridView.builder(
              // En bas : la place du bouton flottant quand il est là (80 = 48
              // + 16 + 16, cf. `kRestoFabClearance`), 16 sinon.
              padding: EdgeInsets.fromLTRB(
                  16, 4, 16, canManage ? kRestoFabClearance : 16),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                // HAUTEUR FIXE, pas un ratio : quatre lignes font 82 px quelle
                // que soit la largeur de colonne. Un ratio redonnait un carré
                // de 245 px sur tablette.
                mainAxisExtent: 82,
              ),
              itemCount: views.length,
              itemBuilder: (_, i) => _TableCard(
                      view: views[i],
                      // Actions sur la TABLE elle-même — addition, comptes,
                      // couverts, réserver, libérer, supprimer. La carte, elle,
                      // ne réagit pas au tap : toute commande passe par le Menu.
                      onActions: () => _showTableActions(views[i].table),
                    ),
            ),
          ),
        ]);
      },
    );
  }
}

/// Heure d'une réservation, `HH:mm` — ou la mention qu'elle n'est pas connue.
String _hhmmOf(DateTime? d) => d == null
    ? 'une heure non précisée'
    : '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
