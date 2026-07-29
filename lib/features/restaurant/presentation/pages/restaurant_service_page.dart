import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/kitchen_ticket_printer.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/restaurant_tab_service.dart';
import '../../../../core/services/restaurant_table_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../features/caisse/domain/entities/sale_item.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/restaurant_table.dart';
import '../widgets/menu_item_tile.dart';
import '../widgets/order_recap_panel.dart';
import '../widgets/resto_surfaces.dart';

/// Écran de SERVICE — le poste de travail du caissier.
///
/// L'application est tenue à la caisse uniquement : les serveuses viennent y
/// dicter les commandes. Le caissier est donc un goulot d'étranglement, et ce
/// qui compte n'est pas « un écran par rôle » mais le NOMBRE DE GESTES entre
/// le moment où la serveuse parle et celui où c'est enregistré.
///
/// D'où deux volets sur un seul écran, sans navigation :
///   * à gauche l'état du restaurant (tables + comptes à emporter) ;
///   * à droite le compte sur lequel on travaille.
///
/// Toucher une table à gauche charge son compte à droite. Le parcours d'une
/// serveuse tient en quatre gestes : table → plats → Envoyer.
class RestaurantServicePage extends StatefulWidget {
  final String shopId;
  const RestaurantServicePage({super.key, required this.shopId});

  @override
  State<RestaurantServicePage> createState() => _RestaurantServicePageState();
}

class _RestaurantServicePageState extends State<RestaurantServicePage> {
  late final OnDataChanged _listener;

  /// Table sélectionnée. `null` = volet « À emporter ».
  RestaurantTable? _table;

  /// Compte en cours. Vide = compte sans nom.
  String _tab = '';

  final List<SaleItem> _lines = [];
  int _covers = 1;
  String? _category;
  bool _saving = false;

  /// Tournée en attente du compte courant, si elle existe déjà en base.
  Sale? _pending;

  @override
  void initState() {
    super.initState();
    _listener = (table, shopId) {
      if (!mounted) return;
      if (shopId != widget.shopId && shopId != '_all') return;
      setState(() {});
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  List<RestaurantTable> get _tables =>
      RestaurantTableService.tablesForShop(widget.shopId);

  List<Product> get _products => LocalStorageService.getProductsForShop(
        widget.shopId,
      ).where((p) => p.isActive).toList();

  List<String> get _categories {
    final set = <String>{};
    for (final p in _products) {
      final c = p.categoryId;
      if (c != null && c.isNotEmpty) set.add(c);
    }
    return set.toList()..sort();
  }

  List<Product> get _visibleProducts => _category == null
      ? _products
      : _products.where((p) => p.categoryId == _category).toList();

  /// Charge le compte [tab] de [table] dans le volet de droite.
  void _select(RestaurantTable? table, String tab) {
    final pending = table == null
        ? null
        : RestaurantOrderService.pendingRoundFor(table, tabLabel: tab);
    setState(() {
      _table = table;
      _tab = tab;
      _pending = pending;
      _covers = (pending?.covers ?? table?.covers ?? 1)
          .clamp(1, table?.capacity ?? 99);
      _lines
        ..clear()
        ..addAll(pending?.items ?? const []);
    });
  }

  void _addProduct(Product p) {
    final id = p.id;
    if (id == null) return;
    setState(() {
      final i = _lines.indexWhere((l) => l.productId == id);
      if (i >= 0) {
        _lines[i] = _lines[i].copyWith(quantity: _lines[i].quantity + 1);
      } else {
        _lines.add(RestaurantOrderService.buildItem(
          productId: id,
          productName: p.name,
          unitPrice: p.priceSellPos,
          priceBuy: p.priceBuy,
          imageUrl: p.mainImageUrl,
        ));
      }
    });
  }

  void _changeQty(int index, int delta) {
    setState(() {
      final next = _lines[index].quantity + delta;
      if (next <= 0) {
        _lines.removeAt(index);
      } else {
        _lines[index] = _lines[index].copyWith(quantity: next);
      }
    });
  }

  double get _total =>
      _lines.fold<double>(0, (s, l) => s + l.subtotal);

  /// Enregistre la tournée, et l'envoie en cuisine si demandé.
  Future<void> _save({bool send = false}) async {
    final table = _table;
    if (table == null) {
      AppSnack.error(context, 'Choisissez une table.');
      return;
    }
    if (_lines.isEmpty) {
      AppSnack.error(context, 'Ajoutez au moins un article.');
      return;
    }
    setState(() => _saving = true);
    try {
      final order = await RestaurantOrderService.saveTableOrder(
        table: table,
        items: List.of(_lines),
        covers: _covers,
        existing: _pending,
        tabLabel: _tab.isEmpty ? null : _tab,
      );
      if (send) {
        // Numéro calculé AVANT l'envoi : une fois figée, la tournée compte
        // dans le total et le numéro serait décalé.
        final round =
            RestaurantOrderService.roundNumberFor(table, tabLabel: _tab);
        await RestaurantOrderService.sendRound(order);
        if (!mounted) return;
        await KitchenTicketPrinter.print(
          context: context,
          shopId: widget.shopId,
          order: order,
          tableName: table.name,
          round: round,
        );
      }
      if (!mounted) return;
      AppSnack.success(
          context, send ? 'Tournée envoyée en cuisine' : 'Tournée enregistrée');
      // Après un envoi la tournée est figée : on repart d'un panneau vide,
      // prêt pour l'apéritif demandé pendant la préparation.
      _select(RestaurantTableService.tableById(table.id) ?? table,
          send ? _tab : _tab);
    } catch (e) {
      if (mounted) AppSnack.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Libellés de comptes à afficher : ceux qui portent déjà des commandes,
  /// PLUS celui qui vient d'être ouvert et qui n'a encore rien.
  List<String> _visibleTabLabels(List<RestaurantTab> tabs) {
    final labels = [
      for (final t in tabs.where((t) => !t.isUnnamed)) t.label,
    ];
    if (_tab.isNotEmpty && !labels.contains(_tab)) labels.add(_tab);
    return labels;
  }

  /// Ouvre un nouveau compte sur la table courante.
  Future<void> _newTab() async {
    final table = _table;
    if (table == null) return;
    final ctrl = TextEditingController(
        text: 'Compte ${RestaurantTabService.tabsForTable(widget.shopId, table.id).length + 1}');
    final label = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (ctx) => AdaptiveFormFrame(
        title: 'Nouveau compte',
        subtitle: table.name,
        icon: Icons.receipt_long_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AppField(
              controller: ctrl,
              hint: 'Compte 2, M. Ali…',
              autofocus: true,
            ),
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Ouvrir',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            ),
          ]),
        ),
      ),
    );
    ctrl.dispose();
    if (label == null || label.isEmpty || !mounted) return;
    _select(table, label);
    if (!mounted) return;
    // Le compte est vide par construction : le dire, sinon on croit que rien
    // ne s'est passé.
    AppSnack.success(
        context, '« $label » ouvert — ajoutez ses plats puis enregistrez');
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Service',
      body: LayoutBuilder(builder: (_, c) {
        // Sous 900 px les deux volets côte à côte deviendraient illisibles :
        // on bascule sur un volet unique — la salle, puis le compte.
        if (c.maxWidth < 900) {
          return _table == null
              ? _buildFloor()
              : Column(children: [
                  _buildContextBar(back: true),
                  Expanded(child: _buildOrderPane(showHeader: false)),
                ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(width: 360, child: _buildFloor()),
          VerticalDivider(
              width: 1, color: Theme.of(context).semantic.borderSubtle),
          Expanded(child: _buildOrderPane(showHeader: true)),
        ]);
      }),
    );
  }

  // ── Volet gauche : état du restaurant ────────────────────────────────

  Widget _buildFloor() {
    final tables = _tables;
    final takeaway =
        RestaurantTabService.tabsForTable(widget.shopId, null);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('SALLE', style: AppTextStyles.microBold),
        const SizedBox(height: 8),
        for (final t in tables) _FloorRow(
          title: t.name,
          subtitle: _floorSubtitle(t),
          selected: _table?.id == t.id,
          accent: t.status.color(Theme.of(context).semantic),
          onTap: () => _select(t, ''),
        ),
        const SizedBox(height: 16),
        Text('À EMPORTER', style: AppTextStyles.microBold),
        const SizedBox(height: 8),
        if (takeaway.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text('Aucun compte à emporter',
                style: AppTextStyles.caption),
          )
        else
          for (final tab in takeaway)
            _FloorRow(
              title: tab.displayLabel,
              subtitle: '${tab.itemCount} article'
                  '${tab.itemCount > 1 ? 's' : ''} · '
                  '${CurrencyFormatter.format(tab.total)}',
              selected: false,
              accent: Theme.of(context).colorScheme.primary,
              onTap: () {},
            ),
      ],
    );
  }

  String _floorSubtitle(RestaurantTable t) {
    final s = RestaurantOrderService.tableSummary(t);
    if (s.count == 0) return '${t.status.label} · ${t.capacity} places';
    return '${s.count} compte${s.count > 1 ? 's' : ''} · '
        '${CurrencyFormatter.format(s.total)}';
  }

  // ── Volet droit : le compte en cours ─────────────────────────────────

  /// Feuille d'actions sur la table sélectionnée.
  ///
  /// Encaisser, ajuster les places, libérer : ces trois gestes n'existaient que
  /// dans le plan de salle, qui n'a aucune entrée de menu. Depuis l'écran de
  /// service — le seul réellement accessible — une table ouverte ne pouvait
  /// plus être rendue.
  Future<void> _tableActions(RestaurantTable table) async {
    final theme = Theme.of(context);
    final tabs = RestaurantTabService.tabsForTable(widget.shopId, table.id);
    final total = tabs.fold<double>(0, (s, t) => s + t.total);
    final free = table.capacity - (table.covers ?? table.capacity);

    final action = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: table.name,
        subtitle: tabs.isEmpty
            ? 'Aucun compte ouvert'
            : '${tabs.length} compte${tabs.length > 1 ? 's' : ''} · '
                '${CurrencyFormatter.format(total)}',
        icon: Icons.table_restaurant_rounded,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (tabs.isNotEmpty)
              ListTile(
                leading: Icon(Icons.receipt_long_rounded,
                    color: theme.semantic.danger),
                title: const Text('Addition / encaisser'),
                subtitle: const Text('Récapitulatif, partage et paiement'),
                onTap: () => Navigator.of(sheetCtx).pop('bill'),
              ),
            if (!table.isFree)
              ListTile(
                leading: Icon(Icons.event_seat_outlined,
                    color: theme.colorScheme.primary),
                title: const Text('Des places se libèrent'),
                subtitle: Text('${table.covers ?? table.capacity} convives sur '
                    '${table.capacity} places'
                    '${free > 0 ? ' · $free libre${free > 1 ? 's' : ''}' : ''}'),
                onTap: () => Navigator.of(sheetCtx).pop('covers'),
              ),
            if (_pending != null && !_pending!.sentToKitchen)
              ListTile(
                leading: Icon(Icons.remove_shopping_cart_outlined,
                    color: theme.semantic.danger),
                title: const Text('Annuler la tournée en cours'),
                subtitle: const Text('Pas encore envoyée — aucune perte'),
                onTap: () => Navigator.of(sheetCtx).pop('cancel_round'),
              ),
            if (tabs.isNotEmpty)
              ListTile(
                leading: Icon(Icons.swap_horiz_rounded,
                    color: theme.colorScheme.primary),
                title: const Text('Gérer les comptes'),
                subtitle: const Text('Transférer, fusionner, annuler une '
                    'tournée, départ sans payer'),
                // Ces gestes vivent dans le plan de salle, qui n'a pas d'entrée
                // de menu (l'écran de service le remplace, par choix produit).
                // Cette passerelle les rend atteignables sans dupliquer un
                // écran entier dans la navigation.
                onTap: () => Navigator.of(sheetCtx).pop('tabs'),
              ),
            ListTile(
              leading: Icon(Icons.check_circle_outline_rounded,
                  color: theme.semantic.success),
              title: const Text('Libérer la table'),
              subtitle: Text(tabs.isEmpty
                  ? 'Remet la table en statut Libre'
                  : 'Les comptes ouverts restent encaissables'),
              onTap: () => Navigator.of(sheetCtx).pop('release'),
            ),
          ]),
        ),
      ),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case 'bill':
        context.push(
            '/shop/${widget.shopId}/restaurant/addition/${table.id}');
      case 'covers':
        await _editCovers(table);
      case 'tabs':
        context.push('/shop/${widget.shopId}/restaurant/tables');
      case 'cancel_round':
        await _cancelPendingRound(table);
      case 'release':
        await _releaseTable(table, tabs, total);
    }
  }

  /// Annule la tournée en attente du compte courant.
  ///
  /// Rien n'a été envoyé en cuisine : aucune matière engagée, donc ni perte à
  /// déclarer ni code gérant à demander. Le motif reste obligatoire — c'est le
  /// garde-fou d'annulation commun à toutes les commandes.
  Future<void> _cancelPendingRound(RestaurantTable table) async {
    final pending = _pending;
    if (pending == null) return;
    final ctrl = TextEditingController();
    final reason = await showAdaptiveFormSheet<String>(
      context: context,
      builder: (ctx) => AdaptiveFormFrame(
        title: 'Annuler la tournée',
        subtitle: '${table.name} · '
            '${CurrencyFormatter.format(pending.total)}',
        icon: Icons.remove_shopping_cart_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
                'Cette tournée n\'est pas partie en cuisine : rien n\'a été '
                'préparé, aucune perte ne sera enregistrée.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 12),
            AppField(
              controller: ctrl,
              hint: 'Motif : client parti, erreur de saisie…',
              autofocus: true,
            ),
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Annuler la tournée',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            ),
          ]),
        ),
      ),
    );
    ctrl.dispose();
    if (reason == null || reason.isEmpty || !mounted) return;
    try {
      await RestaurantOrderService.cancelPendingRound(pending, reason: reason);
      if (!mounted) return;
      final fresh = RestaurantTableService.tableById(table.id);
      setState(() {
        _table = fresh;
        _lines.clear();
        _pending = null;
      });
      AppSnack.success(context, 'Tournée annulée');
    } catch (e) {
      if (mounted) AppSnack.error(context, e.toString());
    }
  }

  /// Ajuste les couverts sans libérer la table (des convives sont partis).
  Future<void> _editCovers(RestaurantTable table) async {
    var covers = table.covers ?? table.capacity;
    final chosen = await showAdaptiveFormSheet<int>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => AdaptiveFormFrame(
          title: 'Couverts — ${table.name}',
          subtitle: 'Capacité ${table.capacity} personnes',
          icon: Icons.event_seat_outlined,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                  iconSize: 32,
                  onPressed: covers > 1
                      ? () => setSheet(() => covers -= 1)
                      : null,
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text('$covers', style: AppTextStyles.title),
                ),
                IconButton(
                  iconSize: 32,
                  onPressed: covers < table.capacity
                      ? () => setSheet(() => covers += 1)
                      : null,
                  icon: const Icon(Icons.add_circle_outline_rounded),
                ),
              ]),
              const SizedBox(height: 6),
              // On saisit le nombre de convives QUI RESTENT, pas le nombre de
              // places qu'on libère. Sans ce rappel chiffré en direct, on ne
              // sait pas dans quel sens tourne le compteur.
              Text(
                  table.capacity - covers > 0
                      ? '$covers convive${covers > 1 ? 's' : ''} à table · '
                          '${table.capacity - covers} place'
                          '${table.capacity - covers > 1 ? 's' : ''} libre'
                          '${table.capacity - covers > 1 ? 's' : ''}'
                      : 'Table complète — aucune place libre',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.captionHint),
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Enregistrer',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: () => Navigator.of(sheetCtx).pop(covers),
              ),
            ]),
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final updated =
        await RestaurantTableService.updateCovers(table, chosen);
    if (!mounted) return;
    setState(() {
      _table = updated;
      _covers = updated.covers ?? updated.capacity;
    });
    final left = updated.capacity - (updated.covers ?? updated.capacity);
    AppSnack.success(
        context,
        left > 0
            ? '${updated.name} — $left place${left > 1 ? 's' : ''} libre'
                '${left > 1 ? 's' : ''}'
            : '${updated.name} — table complète');
  }

  /// Libère la table. Les comptes ouverts ne sont pas perdus : ils quittent le
  /// plan de salle mais restent encaissables — le dire, sinon le serveur croit
  /// avoir effacé de l'argent.
  Future<void> _releaseTable(
      RestaurantTable table, List<RestaurantTab> tabs, double total) async {
    if (tabs.isNotEmpty) {
      final ok = await AppConfirmDialog.show(
        context: context,
        icon: Icons.warning_amber_rounded,
        iconColor: Theme.of(context).semantic.warning,
        title: 'Libérer avec des comptes ouverts ?',
        body: Text('${tabs.length} compte${tabs.length > 1 ? 's' : ''} '
            'non réglé${tabs.length > 1 ? 's' : ''} · '
            '${CurrencyFormatter.format(total)}\n\n'
            'Ces additions restent encaissables depuis Commandes, mais '
            'quittent le plan de salle.'),
        cancelLabel: 'Annuler',
        confirmLabel: 'Libérer quand même',
        onConfirm: () {},
      );
      if (ok != true || !mounted) return;
    }
    await RestaurantTableService.release(table);
    if (!mounted) return;
    setState(() {
      _table = null;
      _tab = '';
      _lines.clear();
    });
    AppSnack.success(context, '${table.name} libérée');
  }

  Widget _buildContextBar({bool back = false}) {
    final table = _table;
    final cs = Theme.of(context).colorScheme;
    final tabs = table == null
        ? <RestaurantTab>[]
        : RestaurantTabService.tabsForTable(widget.shopId, table.id);
    return Container(
      color: restoGlassFill(context),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(children: [
        if (back)
          IconButton(
            onPressed: () => setState(() => _table = null),
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(table?.name ?? 'Service',
                  style:
                      AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
              // Sélecteur de compte : c'est lui qui dit sur quelle addition
              // on travaille. Sans lui, deux clients d'une même table se
              // mélangeraient.
              if (table != null)
                Wrap(spacing: 6, children: [
                  _TabChip(
                      label: 'Compte principal',
                      selected: _tab.isEmpty,
                      onTap: () => _select(table, '')),
                  // Un compte n'est PAS une entité stockée : c'est le
                  // regroupement des commandes qui portent le même libellé
                  // (cf. RestaurantTabService). Un compte qu'on vient d'ouvrir
                  // n'a donc encore aucune commande, et n'apparaissait nulle
                  // part — « Ouvrir » semblait sans effet alors que le compte
                  // était bel et bien sélectionné. On ajoute donc le compte
                  // COURANT à la liste tant qu'il n'a rien à lui.
                  for (final label in _visibleTabLabels(tabs))
                    _TabChip(
                        label: label,
                        selected: _tab == label,
                        onTap: () => _select(table, label)),
                  _TabChip(
                      label: '+ Compte',
                      selected: false,
                      onTap: _newTab),
                ]),
            ],
          ),
        ),
        if (table != null) ...[
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Retirer un couvert',
            onPressed: _covers > 1
                ? () => setState(() => _covers -= 1)
                : null,
            icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
          ),
          Text('$_covers', style: AppTextStyles.bodyBold),
          IconButton(
            tooltip: 'Ajouter un couvert',
            onPressed: _covers < table.capacity
                ? () => setState(() => _covers += 1)
                : null,
            icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
          ),
          // Actions de table (addition, places, libération). Elles vivaient
          // uniquement dans le plan de salle — un écran qu'AUCUNE entrée de
          // menu n'atteint. Une table ouverte devenait donc impossible à
          // libérer depuis l'interface accessible.
          IconButton(
            tooltip: 'Actions sur la table',
            onPressed: () => _tableActions(table),
            icon: const Icon(Icons.more_vert_rounded, size: 20),
          ),
        ],
      ]),
    );
  }

  Widget _buildOrderPane({required bool showHeader}) {
    if (_table == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Choisissez une table à gauche pour prendre une commande.',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySecondary,
          ),
        ),
      );
    }
    final cats = _categories;
    return Column(children: [
      if (showHeader) _buildContextBar(),
      if (cats.isNotEmpty)
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            children: [
              _TabChip(
                  label: 'Tout',
                  selected: _category == null,
                  onTap: () => setState(() => _category = null)),
              for (final c in cats)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _TabChip(
                      label: c,
                      selected: _category == c,
                      onTap: () => setState(() => _category = c)),
                ),
            ],
          ),
        ),
      Expanded(child: _buildGrid()),
      OrderRecapPanel(
        lines: _lines,
        total: _total,
        saving: _saving,
        alreadySent: false,
        onChangeQuantity: _changeQty,
        onSave: () => _save(),
        onSendToKitchen: () => _save(send: true),
      ),
    ]);
  }

  Widget _buildGrid() {
    final products = _visibleProducts;
    if (products.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Aucun plat dans cette catégorie.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySecondary),
        ),
      );
    }
    return LayoutBuilder(builder: (_, c) {
      final columns = (c.maxWidth / 190).floor().clamp(2, 6);
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.45,
        ),
        itemCount: products.length,
        itemBuilder: (_, i) {
          final p = products[i];
          return MenuItemTile(
            name: p.name,
            price: p.priceSellPos,
            imageUrl: p.mainImageUrl,
            hasModifiers: false,
            onAdd: () => _addProduct(p),
            onLongPress: () => _addProduct(p),
          );
        },
      );
    });
  }
}

/// Ligne du volet gauche : une table, ou un compte à emporter.
class _FloorRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _FloorRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.14)
            : restoGlassFill(context),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: selected ? cs.primary : restoGlassBorder(context),
                  width: selected ? 1.5 : 1),
            ),
            child: Row(children: [
              Container(
                width: 5,
                height: 30,
                decoration: BoxDecoration(
                    color: accent, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyBold
                            .copyWith(color: cs.onSurface)),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.caption),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Puce de sélection compacte (compte ou catégorie).
class _TabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.14)
              : sem.trackMuted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? cs.primary : sem.borderSubtle),
        ),
        child: Text(label,
            style: AppTextStyles.caption.copyWith(
                color: selected ? cs.primary : cs.onSurface,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      ),
    );
  }
}
