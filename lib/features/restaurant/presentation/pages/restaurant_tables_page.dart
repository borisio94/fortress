import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/manager_gate.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
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
import '../widgets/table_form_sheet.dart';
import '../../domain/entities/restaurant_table.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/services/restaurant_tab_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/services/service_incident_service.dart';

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
        title: 'Couverts — ${table.name}');
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

  /// Sélecteur de couverts (+/−) borné par la capacité de la table.
  ///
  /// Sert à l'ouverture du service ET à l'ajustement en cours de repas, quand
  /// des convives s'en vont : [title] distingue les deux.
  Future<int?> _askCovers(RestaurantTable table, {String? title}) {
    var covers = table.covers ?? table.capacity;
    return showAdaptiveFormSheet<int>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final theme = Theme.of(ctx);
          return AdaptiveFormFrame(
            title: title ?? 'Ouvrir ${table.name}',
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

  /// Actions sur la TABLE — jamais sur la commande.
  ///
  /// Seule porte d'action du plan de salle depuis que la carte est devenue
  /// informative : elle ouvrait la prise de commande au tap, or toute commande
  /// passe par le Menu. Ce qui reste ici relève de la table elle-même.
  ///
  /// Le contenu suit l'état : une table LIBRE n'a ni addition à réclamer ni
  /// couverts à ajuster, mais elle peut être supprimée — ce qu'une table en
  /// service ne peut pas (on effacerait des additions ouvertes).
  Future<void> _showTableActions(RestaurantTable table) async {
    final theme = Theme.of(context);
    final free  = table.isFree;
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
            if (!free) ...[
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
              // Comptes de la table : consulter, TRANSFÉRER vers une autre
              // table, FUSIONNER. Ces deux opérations n'existent nulle part
              // ailleurs — elles étaient atteintes par le tap sur la carte,
              // elles se rangent naturellement ici.
              ListTile(
                leading: Icon(Icons.receipt_outlined,
                    color: theme.colorScheme.primary),
                title: const Text('Comptes de la table'),
                subtitle: const Text('Consulter, transférer, fusionner'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openTabs(
                      table,
                      RestaurantTabService.tabsForTable(
                          widget.shopId, table.id));
                },
              ),
              ListTile(
                leading: Icon(Icons.event_seat_outlined,
                    color: theme.colorScheme.primary),
                title: const Text('Des places se libèrent'),
                subtitle: Text(
                    '${table.covers ?? table.capacity} couverts sur '
                    '${table.capacity} — ajustez si des convives sont partis'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _editCovers(table);
                },
              ),
              ListTile(
                leading: Icon(Icons.check_circle_outline_rounded,
                    color: theme.semantic.success),
                title: const Text('Libérer la table'),
                subtitle: const Text('Remet la table en statut Libre'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _releaseTable(table);
                },
              ),
            ] else if (_canManageRoom)
              ListTile(
                leading: Icon(Icons.delete_outline_rounded,
                    color: theme.semantic.danger),
                title: const Text('Supprimer la table'),
                subtitle: const Text('Possible tant qu\'aucun service n\'y '
                    'est ouvert'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _deleteTable(table);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
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
      // Masqué quand il n'y a aucune table : l'état vide porte déjà son
      // bouton de création, et deux options d'ajout simultanées se
      // concurrenceraient à l'écran. Masqué aussi sans le droit de composer
      // la salle — proposer un bouton qui refuserait ensuite serait pire que
      // ne rien proposer (même parti pris que l'écran Menu).
      floatingActionButton: (tables.isEmpty || !canManage)
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
              subtitle: canManage
                  ? 'Créez vos tables pour composer le plan de salle '
                      'de votre établissement.'
                  // Sans le droit, l'état vide reste informatif : il dit ce
                  // qui manque et qui peut y remédier, sans bouton mort.
                  : 'Le plan de salle n\'a pas encore été composé. '
                      'Demandez au gérant d\'ajouter les tables.',
              actionLabel: canManage ? 'Créer une table' : null,
              onAction: canManage ? _createTable : null,
            )
          : Column(
              children: [
                const _StatusLegend(),
                Expanded(child: _buildGrid(tables, canManage)),
              ],
            ),
    );
  }

  Widget _buildGrid(List<RestaurantTable> tables, bool canManage) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Grille fluide : ~240 dp par carte (contre 150), 2 colonnes minimum
        // sur mobile. Le plan de salle se lit maintenant à distance — c'est un
        // tableau d'état posé sur un comptoir, plus une grille à parcourir de
        // près. Moins de colonnes, des cartes nettement plus grandes.
        final columns = (constraints.maxWidth / 240).floor().clamp(2, 6);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 1.05,
          ),
          itemCount: tables.length,
          itemBuilder: (_, i) => _TableCard(
            table: tables[i],
            canManage: canManage,
            // Actions sur la TABLE elle-même — addition, comptes, couverts,
            // libérer, supprimer — par un bouton explicite dans le coin. Il n'y
            // a PAS de renommage : le nom se fixe à la création et ne se
            // modifie nulle part. La carte, elle, ne réagit plus au tap : elle
            // ouvrait la prise de commande, et toute commande passe désormais
            // par le Menu.
            onActions: () => _showTableActions(tables[i]),
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
/// Carte d'état d'une table — INFORMATIVE.
///
/// Elle ne réagit plus au tap. Elle ouvrait la prise de commande, ce qui
/// faisait du plan de salle un second point d'entrée des commandes, alors que
/// tout passe désormais par le Menu (panier → « Type de commande »). Deux
/// chemins pour le même acte, c'est deux comportements qui divergent au
/// premier changement.
///
/// Seul le bouton d'actions en coin est cliquable, et il ne touche qu'à la
/// TABLE : addition, couverts, libération, suppression.
class _TableCard extends StatelessWidget {
  final RestaurantTable table;

  /// Droit de composer le plan de salle. Sur une table LIBRE, supprimer est la
  /// seule action du menu : sans ce droit, le bouton ⋮ n'aurait plus rien à
  /// proposer et disparaît — comme le fait déjà le menu d'un plat.
  final bool canManage;
  final VoidCallback onActions;

  const _TableCard({
    required this.table,
    required this.canManage,
    required this.onActions,
  });

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    // Statut DÉDUIT des commandes, pas seulement lu sur la table : une table
    // marquée « libre » alors qu'elle porte des commandes ouvertes (app fermée
    // entre la prise de commande et la mise à jour de la table) affichait un
    // état faux au service. Une réservation, elle, ne se déduit d'aucune
    // commande : ce statut reste celui de la table.
    final summary = RestaurantOrderService.tableSummary(table);
    final status = summary.count > 0 &&
            table.status == RestaurantTableStatus.libre
        ? RestaurantTableStatus.occupee
        : table.status;
    final accent = status.color(semantic);
    // Plats prêts au passe et pas encore apportés. C'est la SEULE information
    // du plan de salle qui appelle une action immédiate : elle prend donc la
    // bordure de la carte, pas une pastille discrète en coin.
    final waiting = RestaurantOrderService.waitingServiceFor(table).length;
    final border = waiting > 0 ? semantic.warning : accent;

    return Material(
      color: status.surface(semantic),
      borderRadius: BorderRadius.circular(14),
      // `StackFit.expand` : sans lui, le Stack se dimensionne sur son contenu
      // et le cadre bordé flottait au milieu d'une carte plus grande, le ⋮
      // tombant hors de la bordure. Le cadre doit occuper TOUTE la cellule.
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: border.withValues(alpha: waiting > 0 ? 1 : 0.45),
                width: waiting > 0 ? 2 : 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(status.icon, color: accent, size: 38),
              if (waiting > 0) ...[
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: semantic.warning,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                      waiting > 1 ? 'À SERVIR ($waiting)' : 'À SERVIR',
                      maxLines: 1,
                      style: AppTextStyles.microBold
                          .copyWith(color: Colors.white)),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                table.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.title.copyWith(color: accent),
              ),
              const SizedBox(height: 3),
              Text(
                status.label,
                style: AppTextStyles.bodySm.copyWith(color: accent),
              ),
              // Comptes ouverts + total en cours : c'est ce qu'un serveur
              // regarde en passant devant la table.
              if (summary.count > 0) ...[
                const SizedBox(height: 5),
                Text(
                  '${summary.count} commande'
                  '${summary.count > 1 ? 's' : ''} · '
                  '${CurrencyFormatter.format(summary.total)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmBold.copyWith(color: accent),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                // Table libre → on affiche la capacité (information utile pour
                // placer un groupe) ; en service → les couverts réels.
                table.isFree
                    ? '${table.capacity} places'
                    // En service, on annonce les places ENCORE LIBRES quand il
                    // y en a : c'est l'information qu'on cherche en plaçant un
                    // client, et une table de six occupée par deux personnes
                    // n'est pas une table pleine.
                    : _coversLabel(table),
                style: AppTextStyles.caption,
              ),
              if (status == RestaurantTableStatus.reservee &&
                  table.reservationTime != null)
                Text(
                  _hhmm(table.reservationTime!),
                  style: AppTextStyles.bodySmBold.copyWith(color: accent),
                ),
            ],
          ),
        ),
          // Seul élément cliquable de la carte, DANS le cadre bordé. Discret
          // mais toujours visible : enfoui derrière un appui long, il serait
          // introuvable sur le web.
          //
          // Une table en service garde toujours son menu — addition, comptes,
          // couverts, libération sont des gestes de SERVICE, ouverts à tous.
          if (!table.isFree || canManage)
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              onPressed: onActions,
              icon: Icon(Icons.more_vert_rounded, size: 18, color: accent),
              tooltip: 'Actions sur la table',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(
                  minWidth: 30, minHeight: 30),
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  /// Couverts d'une table en service, avec les places restantes.
  ///
  /// « 2 couverts · 4 libres » plutôt que « 2 couverts » : en salle, ce qu'on
  /// cherche du regard c'est où placer les clients qui entrent, pas combien
  /// sont déjà assis.
  static String _coversLabel(RestaurantTable table) {
    final covers = table.covers ?? table.capacity;
    final free = table.capacity - covers;
    if (free <= 0) return '$covers couverts';
    return '$covers couverts · $free libre${free > 1 ? 's' : ''}';
  }
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


/// Feuille des comptes d'une table (plan de salle — Lot 3).
///
/// Un compte = les commandes ouvertes qui partagent un libellé. Les deux
/// gestes de service sont ici : transférer un compte vers une autre table
/// (le client change de place, ou passe à emporter) et fusionner deux comptes
/// (ils paient finalement ensemble).
class _TabsSheet extends ConsumerStatefulWidget {
  final String shopId;
  final RestaurantTable table;
  final List<RestaurantTab> tabs;
  final List<RestaurantTable> allTables;

  const _TabsSheet({
    required this.shopId,
    required this.table,
    required this.tabs,
    required this.allTables,
  });

  @override
  ConsumerState<_TabsSheet> createState() => _TabsSheetState();
}

class _TabsSheetState extends ConsumerState<_TabsSheet> {
  late List<RestaurantTab> _tabs = widget.tabs;
  bool _busy = false;

  void _reload() => setState(() => _tabs =
      RestaurantTabService.tabsForTable(widget.shopId, widget.table.id));

  Future<void> _transfer(RestaurantTab tab) async {
    final others =
        widget.allTables.where((t) => t.id != widget.table.id).toList();
    final target = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (_) => AdaptiveFormFrame(
        title: 'Transférer la commande',
        subtitle: tab.displayLabel,
        icon: Icons.swap_horiz_rounded,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.takeout_dining_outlined),
              title: const Text('À emporter (sans table)'),
              onTap: () => Navigator.of(context).pop('__none__'),
            ),
            const Divider(height: 1),
            for (final t in others)
              ListTile(
                leading: const Icon(Icons.table_restaurant_outlined),
                title: Text(t.name),
                subtitle: Text(t.status.label),
                onTap: () => Navigator.of(context).pop(t.id),
              ),
          ]),
        ),
      ),
    );
    if (target == null || !mounted) return;
    setState(() => _busy = true);
    final applied = await RestaurantTabService.transferTab(
      shopId: widget.shopId,
      fromTableId: widget.table.id,
      label: tab.label,
      toTableId: target == '__none__' ? null : target,
    );
    // Le dernier compte vient peut-être de quitter cette table : elle doit
    // redevenir disponible immédiatement, sans geste supplémentaire.
    await RestaurantTableService.releaseIfEmpty(widget.table);
    if (!mounted) return;
    setState(() => _busy = false);
    // Le libellé a pu être renommé si la destination portait déjà ce nom : le
    // dire, sinon le serveur cherchera « Compte 1 » et trouvera « Compte 1 (2) ».
    if (applied != tab.label) {
      AppSnack.info(
          context,
          'Commande transférée sous « $applied » — ce nom était déjà pris '
          'à destination.');
    } else {
      AppSnack.success(context, 'Commande transférée.');
    }
    _reload();
  }

  /// Déclare un départ sans paiement sur ce compte.
  ///
  /// Les bons sont annulés — ils n'ont jamais été du chiffre d'affaires — et
  /// la matière des tournées envoyées en cuisine est enregistrée en perte.
  Future<void> _unpaid(RestaurantTab tab) async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.money_off_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Départ sans paiement ?',
      body: Text(
          '« ${tab.displayLabel} » · ${CurrencyFormatter.format(tab.total)}\n\n'
          'La commande sera annulée. La matière des plats déjà envoyés en '
          'cuisine sera enregistrée en perte (catégorie « Non payé ») — pas '
          'le prix de l\'addition, dont la marge n\'a jamais été gagnée.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Déclarer la perte',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await ServiceIncidentService.reportUnpaid(
      shopId: widget.shopId,
      orders: tab.orders,
      origin: '${widget.table.name} · ${tab.displayLabel}',
      declaredBy: LocalStorageService.getCurrentUser()?.id,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    AppSnack.success(context, 'Perte enregistrée.');
    _reload();
  }

  /// Annule une tournée DÉJÀ envoyée en cuisine, sous aval du gérant.
  ///
  /// Une tournée pas encore envoyée n'a rien engagé : elle se retire en
  /// modifiant la commande, sans perte et sans PIN. Une fois partie, la matière
  /// est consommée — d'où le code PIN (le geste permet d'encaisser puis
  /// d'annuler la ligne) et la perte enregistrée automatiquement.
  Future<void> _cancelRound(RestaurantTab tab) async {
    final sent = tab.orders
        .where((o) => o.sentToKitchen && o.status != SaleStatus.cancelled)
        .toList();
    if (sent.isEmpty) {
      AppSnack.info(
          context,
          'Aucune tournée envoyée sur cette commande — retirez les articles '
          'directement depuis la commande.');
      return;
    }

    final choice = await showAdaptiveFormSheet<({Sale order, String reason})>(
      context: context,
      builder: (_) => _CancelRoundSheet(
        tabLabel: tab.displayLabel,
        rounds: sent,
      ),
    );
    if (choice == null || !mounted) return;

    final ok = await ManagerGate.require(
      context: context,
      perms: ref.read(permissionsProvider(widget.shopId)),
      action: ManagerAction.cancelSentRound,
      shopId: widget.shopId,
      targetId: choice.order.id,
      targetLabel: '${widget.table.name} · ${tab.displayLabel}',
      details: {
        'reason': choice.reason,
        'total': choice.order.total,
        'items': choice.order.items.length,
      },
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    final loss = await ServiceIncidentService.cancelSentRound(
      shopId: widget.shopId,
      order: choice.order,
      reason: choice.reason,
      declaredBy: LocalStorageService.getCurrentUser()?.id,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    AppSnack.success(
        context,
        loss == null
            ? 'Tournée annulée.'
            : 'Tournée annulée — perte de '
                '${CurrencyFormatter.format(loss.amount.toDouble())} '
                'enregistrée.');
    _reload();
  }

  Future<void> _merge(RestaurantTab tab) async {
    final others = _tabs.where((t) => t.label != tab.label).toList();
    if (others.isEmpty) return;
    final target = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (_) => AdaptiveFormFrame(
        title: 'Fusionner la commande',
        subtitle: tab.displayLabel,
        icon: Icons.merge_rounded,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final t in others)
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(t.displayLabel),
                subtitle: Text('${t.itemCount} article'
                    '${t.itemCount > 1 ? 's' : ''} · '
                    '${CurrencyFormatter.format(t.total)}'),
                onTap: () => Navigator.of(context).pop(t.label),
              ),
          ]),
        ),
      ),
    );
    if (target == null || !mounted) return;
    setState(() => _busy = true);
    await RestaurantTabService.mergeTabs(
      shopId: widget.shopId,
      tableId: widget.table.id,
      sourceLabel: tab.label,
      targetLabel: target,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    AppSnack.success(context, 'Commandes fusionnées.');
    _reload();
  }

  /// Marque tous les bons prêts de ce compte comme apportés au client.
  ///
  /// Un compte peut porter plusieurs bons prêts (deux tournées terminées
  /// coup sur coup). Le serveur apporte le tout en une fois — lui demander un
  /// appui par bon n'apporterait rien et laisserait le signal allumé sur une
  /// table déjà servie.
  Future<void> _markServed(RestaurantTab tab) async {
    final pending = tab.waitingService;
    if (pending.isEmpty) return;
    setState(() => _busy = true);
    for (final order in pending) {
      await RestaurantOrderService.markServed(order);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    AppSnack.success(context, '${tab.displayLabel} — servie');
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final total = _tabs.fold<double>(0, (s, t) => s + t.total);

    return AdaptiveFormFrame(
      title: widget.table.name,
      subtitle: '${_tabs.length} commandes · ${CurrencyFormatter.format(total)}',
      icon: Icons.table_restaurant_rounded,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final tab in _tabs)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: sem.borderSubtle),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(tab.displayLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodyBold
                              .copyWith(color: cs.onSurface)),
                      Text(
                          '${tab.itemCount} article'
                          '${tab.itemCount > 1 ? 's' : ''} · '
                          '${tab.orderCount} bon'
                          '${tab.orderCount > 1 ? 's' : ''}',
                          style: AppTextStyles.caption),
                      if (tab.isWaitingService)
                        Text('Prête à servir',
                            style: AppTextStyles.captionHint
                                .copyWith(color: sem.warning)),
                    ],
                  ),
                ),
                // Bouton de SERVICE — il n'apparaît que sur les comptes dont
                // la cuisine a fini. Le placer en tête de rangée, avant le
                // total, le met sur le chemin du serveur qui vient de recevoir
                // l'alerte.
                if (tab.isWaitingService) ...[
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _markServed(tab),
                    icon: const Icon(Icons.room_service_outlined, size: 16),
                    label: const Text('Servie'),
                    style: FilledButton.styleFrom(
                      backgroundColor: sem.warning,
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(CurrencyFormatter.format(tab.total),
                    style:
                        AppTextStyles.bodyBold.copyWith(color: cs.primary)),
                PopupMenuButton<String>(
                  enabled: !_busy,
                  tooltip: 'Actions',
                  onSelected: (v) => switch (v) {
                    'transfer' => _transfer(tab),
                    'merge' => _merge(tab),
                    'cancel_round' => _cancelRound(tab),
                    _ => _unpaid(tab),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'transfer', child: Text('Transférer…')),
                    if (_tabs.length > 1)
                      const PopupMenuItem(
                          value: 'merge', child: Text('Fusionner…')),
                    const PopupMenuItem(
                        value: 'cancel_round',
                        child: Text('Annuler une tournée envoyée…')),
                    const PopupMenuItem(
                        value: 'unpaid',
                        child: Text('Départ sans payer…')),
                  ],
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// Choix de la tournée à annuler + motif.
///
/// Le motif est OBLIGATOIRE : il devient l'origine de la perte enregistrée, et
/// c'est la seule chose qui distingue, trois semaines plus tard, une erreur de
/// cuisine d'un client qui s'est ravisé.
class _CancelRoundSheet extends StatefulWidget {
  final String tabLabel;
  final List<Sale> rounds;

  const _CancelRoundSheet({required this.tabLabel, required this.rounds});

  @override
  State<_CancelRoundSheet> createState() => _CancelRoundSheetState();
}

class _CancelRoundSheetState extends State<_CancelRoundSheet> {
  late Sale _selected = widget.rounds.first;
  final _reason = TextEditingController();
  String? _err;

  /// Heure d'envoi du bon — le repère que le cuisinier et le serveur ont en
  /// tête pour distinguer deux tournées d'un même compte.
  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _reason.text.trim();
    if (reason.isEmpty) {
      setState(() => _err = 'Motif obligatoire');
      return;
    }
    Navigator.of(context).pop((order: _selected, reason: reason));
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;

    return AdaptiveFormFrame(
      title: 'Annuler une tournée envoyée',
      subtitle: widget.tabLabel,
      icon: Icons.cancel_schedule_send_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'La matière est déjà engagée : le coût des ingrédients sera '
              'enregistré en perte. Une validation du gérant est demandée.',
              style: AppTextStyles.captionHint,
            ),
            const SizedBox(height: 10),
            for (final r in widget.rounds)
              ListTile(
                contentPadding: EdgeInsets.zero,
                onTap: () => setState(() => _selected = r),
                leading: Icon(
                  _selected.id == r.id
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: _selected.id == r.id
                      ? cs.primary
                      : cs.onSurface.withValues(alpha: 0.35),
                ),
                title: Text(
                    '${r.items.length} article'
                    '${r.items.length > 1 ? 's' : ''} · '
                    '${CurrencyFormatter.format(r.total)}',
                    style: AppTextStyles.bodySmBold),
                subtitle: Text(
                    '${_hhmm(r.createdAt)} · '
                    '${r.items.map((i) => '${i.quantity}× ${i.productName}').join(', ')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.caption),
              ),
            const SizedBox(height: 6),
            TextField(
              controller: _reason,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Motif',
                hintText: 'Client parti, erreur de saisie, plat indisponible…',
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Annuler cette tournée',
              icon: Icons.block_rounded,
              fullWidth: true,
              color: cs.error,
              onTap: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
