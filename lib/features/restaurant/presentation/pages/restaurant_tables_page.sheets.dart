part of 'restaurant_tables_page.dart';

// Les feuilles de la table : comptes, annulation d'une tournée.

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

  /// AJOUTER DES PLATS à ce compte, sans refaire la prise de commande.
  ///
  /// Même geste que depuis l'addition, atteignable une étape plus tôt : le
  /// serveur qui passe devant la table n'a pas à ouvrir l'addition — donc à
  /// voir un bouton « Encaisser » — pour ajouter un café.
  void _addDishes(RestaurantTab tab) {
    // Le routeur est capturé AVANT le pop : après lui, ce `context` est
    // démonté et `context.go` ne trouverait plus rien.
    final router = GoRouter.of(context);
    ref.read(orderAttachProvider.notifier).aim(
          tableId: widget.table.id,
          tableName: widget.table.name,
          // Le libellé BRUT — voir `_addDishes` de l'addition : `displayLabel`
          // rendrait « Sans nom » et ouvrirait un second compte.
          tabLabel: tab.label.trim(),
        );
    Navigator.of(context).pop();
    router.go('/shop/${widget.shopId}/inventaire');
  }

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
                                .copyWith(color: sem.warningText)),
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
                        AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
                PopupMenuButton<String>(
                  enabled: !_busy,
                  tooltip: 'Actions',
                  onSelected: (v) => switch (v) {
                    'add' => _addDishes(tab),
                    'transfer' => _transfer(tab),
                    'merge' => _merge(tab),
                    'cancel_round' => _cancelRound(tab),
                    _ => _unpaid(tab),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'add', child: Text('Ajouter des plats…')),
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
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
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
