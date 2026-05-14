import 'package:fortress/shared/widgets/app_snack.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../bloc/caisse_bloc.dart';
import '../../../dashboard/data/dashboard_providers.dart';
import '../widgets/product_grid_widget.dart';
import '../widgets/cart_widget.dart';
import '../widgets/add_order_expense_dialog.dart';
import '../widgets/order_processing_sheet.dart';
import '../widgets/order_completion_sheet.dart';
import '../widgets/record_acompte_dialog.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import '../../domain/usecases/order_receipt_usecase.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../shared/widgets/order_source_badge.dart';
import '../../../../shared/widgets/view_filter_chip_bar.dart';
import '../widgets/transfer_delivery_sheet.dart';
import '../widgets/transfer_history_section.dart';
import '../../data/repositories/delivery_transfer_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/app_permissions.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../domain/entities/sale.dart';
import '../../data/repositories/sale_local_datasource.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/external_launcher.dart';
import '../../../../core/services/partner_ledger_service.dart';
import '../../../parametres/domain/entities/partner_ledger_entry.dart';
import '../../../../core/services/document_service.dart';
import '../../../../core/services/invoice_storage_service.dart';
import '../../../../core/services/url_shortener_service.dart';
import '../../../../core/services/danger_action_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/utils/phone_formatter.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../crm/data/models/client_model.dart';

class CaissePage extends ConsumerStatefulWidget {
  final String shopId;
  /// Optionnel : ouvrir immédiatement la commande d'id donné en mode édition.
  /// Utilisé depuis la page Dépenses pour qu'un tap sur un frais de commande
  /// ouvre la commande source pour la modifier.
  final String? editOrderId;

  /// Optionnel : pré-sélectionner un client dans le panier au démarrage.
  /// Utilisé depuis la fiche client (CRM > Nouvelle commande) pour conserver
  /// le contexte client dans le panier.
  final String? preselectedClientId;
  const CaissePage({super.key, required this.shopId, this.editOrderId,
      this.preselectedClientId});
  @override
  ConsumerState<CaissePage> createState() => _CaissePageState();
}

class _CaissePageState extends ConsumerState<CaissePage> {

  @override
  void initState() {
    super.initState();
    // Auto-édition d'une commande passée en query param (?edit=<orderId>)
    final editId = widget.editOrderId;
    if (editId != null && editId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final orders = SaleLocalDatasource().getOrders(widget.shopId);
        final target = orders.where((o) => o.id == editId).firstOrNull;
        if (target == null) {
          AppSnack.error(context,
              'Commande introuvable — elle a peut-être été supprimée');
          return;
        }
        context.read<CaisseBloc>().add(LoadOrderForEdit(target));
      });
    }

    // Pré-sélection client passée en query param (?clientId=<id>)
    // Utilisé depuis la fiche client (CRM > Nouvelle commande).
    final preClientId = widget.preselectedClientId;
    if (preClientId != null && preClientId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final raw = HiveBoxes.clientsBox.get(preClientId);
        if (raw == null) return;
        final client = ClientModel
            .fromMap(Map<String, dynamic>.from(raw))
            .toEntity();
        context.read<CaisseBloc>().add(SetSelectedClient(client));
      });
    }

    // Phase 2 — propage la vue "Partenaire X" du dashboard vers le panier.
    // Si l'utilisateur consulte le dashboard avec le filtre Flash Livraison
    // Douala et clique Caisse, on pré-positionne le mode livraison sur ce
    // partenaire pour que la vente utilise son stock. On ne touche que si
    // le panier est vierge (pas d'articles ni de mode déjà choisi) — sinon
    // on respecte la sélection en cours.
    //
    // À l'entrée Vente, si le filtre dashboard est `null` (Globale), on le
    // force à `'_base'` : Globale n'est pas affichée sur la barre Vente
    // (pas de sens en vente), donc on doit avoir un onglet actif cohérent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final dashFilter = ref.read(dashViewFilterProvider);
      if (dashFilter == null) {
        ref.read(dashViewFilterProvider.notifier).state = '_base';
        return;
      }
      if (dashFilter == '_base') return;
      final bloc = context.read<CaisseBloc>();
      if (bloc.state.items.isNotEmpty) return;
      if (bloc.state.deliveryMode != null) return;
      if ((bloc.state.deliveryLocationId ?? '').isNotEmpty) return;
      bloc.add(SetDeliveryMode(
          mode: DeliveryMode.partner, locationId: dashFilter));
    });
  }

  bool get _isEcommerce {
    final shop = ref.read(currentShopProvider);
    return shop?.sector == 'ecommerce';
  }

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;

    // Note : la `ViewFilterChipBar` (Boutique / Partenaires) côté Vente est
    // un FILTRE VISUEL pur. Elle ne dispatche plus `SetDeliveryMode` — sinon
    // elle force `deliveryMode=inHouse` sans `deliveryCity`, ce qui faisait
    // échouer `_validateDelivery` au moment du Save (snackbar « Ville de
    // livraison requise »). Le mode + ville restent pilotés par la sheet
    // « Détails de livraison » du panier (action utilisateur explicite).
    return MultiBlocListener(
      listeners: [
        BlocListener<CaisseBloc, CaisseState>(
        listenWhen: (prev, curr) =>
            prev.saleCompleted   != curr.saleCompleted   ||
            prev.orderSaved      != curr.orderSaved      ||
            (curr.error != null && prev.error != curr.error),
        listener: (context, state) {
          // Erreur (stock insuffisant, client manquant, etc.) → snackbar
          if (state.error != null && state.error!.isNotEmpty) {
            AppSnack.error(context, state.error!);
          }
          if (state.saleCompleted && state.lastCompletedSale == null) {
            // saleCompleted SANS lastCompletedSale = ancien flux ProcessSale
            // Si lastCompletedSale existe, c'est le flux CompleteSale
            // qui est géré par la PaymentPage → ne pas interférer
            AppSnack.success(context,
                '${l.boutiqueTitle} — commande encaissée');
            context.read<CaisseBloc>().add(ClearCart());
          }
          if (state.orderSaved == true) {
            // Vider le panier immédiatement
            context.read<CaisseBloc>().add(ClearCart());
            final bloc = context.read<CaisseBloc>();
            final isEdit = bloc.state.editingOrderId != null;
            AppSnack.success(context,
                isEdit
                    ? 'Commande mise à jour !'
                    : 'Commande enregistrée et programmée !');
            // Bascule vers la page Commandes (anciennement onglet,
            // désormais route shell dédiée /caisse/orders).
            Future.microtask(() {
              if (mounted) {
                context.go('/shop/${widget.shopId}/caisse/orders');
              }
            });
          }
        },
        ),
      ],
      child: _PrincipalTab(
          shopId:     widget.shopId,
          isEcommerce: _isEcommerce,
          onNewOrder: () => _showNewOrder(context, l)),
    );
  }

  void _showNewOrder(BuildContext context, AppLocalizations l) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius:
          BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, sc) => BlocProvider.value(
          value: context.read<CaisseBloc>(),
          child: ProductPickerSheet(shopId: widget.shopId),
        ),
      ),
    );
  }
}

// ─── Layout principal Caisse ──────────────────────────────────────────────────
/// Desktop : split produits (Expanded) + panier 280px FIXE, **toujours visible**
/// (cartouche vide _EmptyCart si aucun article). Mobile : grille produits
/// pleine largeur. Le panier mobile s'ouvre via l'icône topbar (bottom sheet
/// CartWidget) — cf. AdaptiveScaffold._CartBadgeBtn. Le FAB historique a été
/// retiré pour éviter le doublon avec l'icône topbar.
class _PrincipalTab extends StatelessWidget {
  final String       shopId;
  final bool         isEcommerce;
  final VoidCallback onNewOrder;
  const _PrincipalTab({required this.shopId,
    required this.isEcommerce, required this.onNewOrder});

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final isWide = MediaQuery.of(context).size.width > 800;
    // Fond identique aux autres pages (dashboard, inventaire) — repose sur
    // le `scaffoldBackgroundColor` du thème pour cohérence visuelle. La
    // chaleur vient des cards (ombre tintée primary sur ProductGridCard),
    // pas d'un dégradé global.
    final bg = theme.scaffoldBackgroundColor;
    if (isWide) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: ColoredBox(
              color: bg,
              child: PosProductPanel(shopId: shopId)),
        ),
        Container(width: 1, color: theme.semantic.borderSubtle),
        SizedBox(
          width: 380,
          child: CartWidget(shopId: shopId, isEcommerce: isEcommerce),
        ),
      ]);
    }
    return ColoredBox(
      color: bg,
      child: PosProductPanel(shopId: shopId),
    );
  }
}

// ─── Page Commandes (anciennement _OrdersTab) ────────────────────────────────
/// Liste des commandes brouillon / programmées / encaissées avec filtres,
/// recherche, plage de dates et actions inline (statut, édition, suppression).
///
/// Anciennement le 2ᵉ onglet d'un TabController dans CaissePage. Désormais
/// route shell autonome `/shop/:shopId/caisse/orders` (cf. app_router.dart),
/// embarquée dans `OrdersPage` (orders_page.dart).
class OrdersTab extends ConsumerStatefulWidget {
  final String shopId;
  const OrdersTab({super.key, required this.shopId});
  @override
  ConsumerState<OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends ConsumerState<OrdersTab>
    with SingleTickerProviderStateMixin {
  late TabController _filter;
  final _ds = SaleLocalDatasource();
  // Recherche libre (client, téléphone, id, ville livraison/expédition,
  // agence). Insensible à la casse / accents.
  final _searchCtrl = TextEditingController();
  String _query = '';
  // Plage de dates [du / au] — bornes inclusives sur la date de création
  // pour les commandes encaissées, sur la date de livraison sinon.
  DateTimeRange? _dateRange;

  static const _filters = [
    ('all',        'Toutes'),
    ('scheduled',  'Programmée'),
    ('processing', 'En cours'),
    ('completed',  'Complétée'),
    ('cancelled',  'Annulée'),
    ('refused',    'Refusée'),
  ];

  @override
  void initState() {
    super.initState();
    _filter = TabController(length: _filters.length, vsync: this);
    _filter.addListener(() => setState(() {}));
    _searchCtrl.addListener(() {
      final q = _searchCtrl.text.trim();
      if (q != _query) setState(() => _query = q);
    });
    // Listener AppDatabase : rafraîchit la liste dès qu'une commande est
    // créée / mise à jour (SaveOrder dans le panier émet
    // `notifyOrderChange` après le put Hive). Sans ça, l'opérateur devait
    // pull-to-refresh manuellement pour voir sa commande tout juste
    // enregistrée.
    AppDatabase.addListener(_onDataChanged);
  }

  void _onDataChanged(String table, String shopId) {
    if (!mounted) return;
    if (table == 'orders' && shopId == widget.shopId) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDataChanged);
    _filter.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Pull-to-refresh : re-fetch toutes les tables métier depuis Supabase
  /// puis force un rebuild (le getter `_orders` relit Hive à jour).
  Future<void> _pullAndReload() async {
    await AppDatabase.pullAllForShop(widget.shopId);
    if (mounted) setState(() {});
  }

  String _normalize(String s) => s
      .toLowerCase()
      .replaceAll('à', 'a').replaceAll('â', 'a').replaceAll('ä', 'a')
      .replaceAll('é', 'e').replaceAll('è', 'e').replaceAll('ê', 'e').replaceAll('ë', 'e')
      .replaceAll('î', 'i').replaceAll('ï', 'i')
      .replaceAll('ô', 'o').replaceAll('ö', 'o')
      .replaceAll('ù', 'u').replaceAll('û', 'u').replaceAll('ü', 'u')
      .replaceAll('ç', 'c');

  bool _matches(Sale o, String q) {
    final hay = [
      o.id ?? '',
      o.clientName ?? '',
      o.clientPhone ?? '',
      o.deliveryCity ?? '',
      o.deliveryAddress ?? '',
      o.shipmentCity ?? '',
      o.shipmentAgency ?? '',
      o.shipmentHandler ?? '',
      o.deliveryPersonName ?? '',
      o.notes ?? '',
    ].map(_normalize).join(' ');
    return hay.contains(_normalize(q));
  }

  List<Sale> get _orders {
    final all = _ds.getOrders(widget.shopId);
    final key = _filters[_filter.index].$1;
    var list = key == 'all'
        ? all
        : all.where((o) => o.status.name == key).toList();
    // Filtre par créateur : un employé sans `canViewAllOrders` ne voit
    // que ses propres commandes (createdByUserId == self) ET les
    // commandes au statut `completed` (= validées par un supérieur).
    final perms = ref.read(permissionsProvider(widget.shopId));
    if (!perms.canViewAllOrders) {
      final me = Supabase.instance.client.auth.currentUser?.id;
      list = list.where((o) =>
          o.createdByUserId == me
          || o.status == SaleStatus.completed).toList();
    }
    // Filtre vue dashboard.
    // Principe métier : chaque commande est rattachée à un LIEU d'émission
    // (boutique principale OU dépôt partenaire), via `o.deliveryLocationId`
    // qui est désormais TOUJOURS rempli (cf. SetDeliveryMode bloc handler).
    //   * Vue Globale (viewFilter == null) → toutes les commandes
    //   * Vue Boutique (viewFilter == '_base') → commandes émises depuis
    //     la stock_location de cette boutique (pas seulement "loc null")
    //   * Vue Partenaire X → commandes émises depuis X
    //
    // Fallback `byPartner` (delivery_transfers) garde son rôle pour les
    // commandes redirigées via une livraison effective postérieure.
    // Compat héritée : les commandes avant ce sprint n'ont pas de
    // deliveryLocationId — elles sont considérées "boutique" (rattachées
    // à shopLocation) tant qu'aucun transfer ne les redirige ailleurs.
    final viewFilter = ref.watch(dashViewFilterProvider);
    if (viewFilter != null) {
      final byPartner    = orderToPartnerLocId(widget.shopId);
      final shopLoc      = AppDatabase.getShopLocation(widget.shopId);
      final shopLocId    = shopLoc?.id;
      list = list.where((o) {
        final id = o.id;
        if (id == null) return false;
        // Lieu effectif : champ Sale d'abord, transfer en fallback.
        final loc = (o.deliveryLocationId ?? '').isNotEmpty
            ? o.deliveryLocationId
            : byPartner[id];
        if (viewFilter == '_base') {
          // Vue Boutique = (a) lieu = shopLocation.id, ou (b) anciennes
          // commandes sans lieu et sans transfer (compat rétro).
          if (loc == null) return true;
          return loc == shopLocId;
        }
        // Vue Partenaire X = lieu == X.
        return loc == viewFilter;
      }).toList();
    }
    final r = _dateRange;
    if (r != null) {
      // Pour l'onglet "Complétée" on filtre sur la date d'encaissement
      // (createdAt), sinon sur la date de livraison programmée.
      final useCreated = key == 'completed';
      final start = DateTime(r.start.year, r.start.month, r.start.day);
      final end   = DateTime(r.end.year, r.end.month, r.end.day,
          23, 59, 59, 999);
      list = list.where((o) {
        final ref = useCreated ? o.createdAt : o.scheduledAt;
        if (ref == null) return false;
        return !ref.isBefore(start) && !ref.isAfter(end);
      }).toList();
    }
    if (_query.isNotEmpty) {
      list = list.where((o) => _matches(o, _query)).toList();
    }
    return list;
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _dateRange ?? DateTimeRange(
          start: now.subtract(const Duration(days: 7)), end: now),
      firstDate: now.subtract(const Duration(days: 365 * 3)),
      lastDate:  now.add(const Duration(days: 365)),
      locale: const Locale('fr', 'FR'),
    );
    if (picked != null) setState(() => _dateRange = picked);
  }

  String _formatRange(DateTimeRange r) {
    String d(DateTime x) =>
        '${x.day.toString().padLeft(2, '0')}/${x.month.toString().padLeft(2, '0')}';
    return '${d(r.start)} → ${d(r.end)}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // ── Onglets « Vue » : Globale / Boutique / Partenaires ──────────
      // Le filtre s'applique aux lignes via `orderToPartnerLocId` plus haut
      // dans `_orders` (cf. ref.watch(dashViewFilterProvider)).
      ViewFilterChipBar(shopId: widget.shopId, useTabs: true),

      // ── Filtres ─────────────────────────────────────────────
      Container(
        color: Colors.white,
        child: TabBar(
          controller: _filter,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor:           AppColors.primary,
          unselectedLabelColor: AppColors.textHint,
          indicatorColor:       AppColors.primary,
          indicatorWeight:      2,
          labelStyle: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600),
          tabs: _filters
              .map((f) => Tab(text: f.$2))
              .toList(),
        ),
      ),
      const Divider(height: 1, color: Color(0xFFF0F0F0)),

      // ── Recherche + filtre plage de dates ────────────────────
      Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(children: [
          // Barre de recherche
          SizedBox(
            height: 36,
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Rechercher (client, téléphone, ville, agence…)',
                hintStyle: const TextStyle(fontSize: 12,
                    color: AppColors.textHint),
                prefixIcon: const Icon(Icons.search_rounded,
                    size: 16, color: AppColors.textHint),
                suffixIcon: _query.isEmpty ? null : IconButton(
                  icon: const Icon(Icons.close_rounded,
                      size: 14, color: AppColors.textHint),
                  splashRadius: 16,
                  onPressed: () => _searchCtrl.clear(),
                ),
                contentPadding: EdgeInsets.zero,
                filled: true, fillColor: AppColors.inputFill,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.divider)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppColors.primary)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Plage de dates
          Row(children: [
            InkWell(
              onTap: _pickDateRange,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _dateRange != null
                      ? AppColors.primary.withValues(alpha:0.10)
                      : AppColors.inputFill,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: _dateRange != null
                          ? AppColors.primary.withValues(alpha:0.4)
                          : AppColors.divider),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.event_rounded, size: 12,
                      color: _dateRange != null
                          ? AppColors.primary
                          : AppColors.textSecondary),
                  const SizedBox(width: 5),
                  Text(
                      _dateRange == null
                          ? 'Filtrer par date'
                          : _formatRange(_dateRange!),
                      style: TextStyle(fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _dateRange != null
                              ? AppColors.primary
                              : AppColors.textSecondary)),
                ]),
              ),
            ),
            if (_dateRange != null) ...[
              const SizedBox(width: 6),
              InkWell(
                onTap: () => setState(() => _dateRange = null),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded,
                      size: 14, color: AppColors.textHint),
                ),
              ),
            ],
            const Spacer(),
            Text('${_orders.length} résultat${_orders.length > 1 ? 's' : ''}',
                style: const TextStyle(fontSize: 10,
                    color: AppColors.textHint,
                    fontWeight: FontWeight.w600)),
          ]),
        ]),
      ),
      const Divider(height: 1, color: Color(0xFFF0F0F0)),

      // ── Liste commandes ──────────────────────────────────────
      Expanded(
        child: RefreshIndicator(
          onRefresh: _pullAndReload,
          child: _orders.isEmpty
            ? ListView(children: [EmptyStateWidget(
                icon: Icons.inbox_outlined,
                title: _filter.index == 0
                    ? 'Aucune commande'
                    : 'Aucune commande ${_filters[_filter.index].$2.toLowerCase()}',
                subtitle: 'Les commandes que tu encaisses apparaîtront ici.',
              )])
            : ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: _orders.length,
          separatorBuilder: (_, __) =>
          const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final perms = ref.watch(permissionsProvider(widget.shopId));
            return _OrderCard(
            order:    _orders[i],
            canCancel: perms.canCancelSale,
            canDelete: perms.canDeleteOrder,
            canEdit:   perms.canEditOrder,
            onUpdate: (status) async {
              // Garde défensive : annulation/remboursement requièrent
              // salesCancel même si le menu est filtré côté UI.
              if ((status == SaleStatus.cancelled
                      || status == SaleStatus.refunded)
                  && !perms.canCancelSale) {
                AppSnack.error(context,
                    'Action réservée : annuler ou rembourser une vente '
                    'requiert la permission "sales.cancel".');
                return;
              }
              final order = _orders[i];
              final wasScheduled  = order.status == SaleStatus.scheduled;
              final wasProcessing = order.status == SaleStatus.processing;
              final becomingProcessing = status == SaleStatus.processing
                  && wasScheduled;
              final becomingCompleted = status == SaleStatus.completed
                  && order.status != SaleStatus.completed;

              // Transition scheduled → processing : sheet B (paiement + mode
              // de livraison). Le mode par défaut suit le lieu d'origine de
              // la commande (partner si dépôt partenaire, inHouse si
              // boutique principale) — conforme au principe métier "tout
              // est rattaché à un lieu".
              if (becomingProcessing) {
                final defaultMode = _modeForOrderLocation(order);
                final res = await showOrderProcessingSheet(
                  context,
                  defaultMode:          defaultMode,
                  initialPaymentMethod: order.paymentMethod,
                  initialPersonName:    order.deliveryPersonName,
                  originLocationName:   _locationNameOf(order),
                  orderTotal:           order.total,
                  amountAlreadyPaid:    order.amountPaid,
                );
                if (res == null) return; // annulé → pas de changement
                await _ds.updateOrderDelivery(
                  order.id!,
                  paymentMethod: res.paymentMethod,
                  mode:          res.mode,
                  // locationId conservé (= lieu d'origine de la commande)
                  locationId:    order.deliveryLocationId,
                  personName:    res.personName,
                );
                // Si l'opérateur a saisi un nouvel encaissement dans le
                // sheet, propager via recordPayment (qui dérive auto
                // payment_status : partial / paid selon ratio total).
                if (res.amountPaidTotal != null) {
                  await _ds.recordPayment(
                      order.id!, res.amountPaidTotal!);
                }
              }

              // Transition processing/scheduled → completed : sheet C
              // (frais de livraison/emballage inclus dans le montant payé).
              // Date d'encaissement antidatable via le picker du sheet.
              DateTime? completedAt;
              if (becomingCompleted) {
                // Si on saute scheduled → completed direct (raccourci POS),
                // collecter aussi paiement+mode AVANT les frais. Sinon
                // les valeurs déjà saisies au sheet B sont préservées.
                if (!wasProcessing && wasScheduled) {
                  final defaultMode = _modeForOrderLocation(order);
                  final pres = await showOrderProcessingSheet(
                    context,
                    defaultMode:          defaultMode,
                    initialPaymentMethod: order.paymentMethod,
                    initialPersonName:    order.deliveryPersonName,
                    originLocationName:   _locationNameOf(order),
                    orderTotal:           order.total,
                    amountAlreadyPaid:    order.amountPaid,
                  );
                  if (pres == null) return;
                  await _ds.updateOrderDelivery(
                    order.id!,
                    paymentMethod: pres.paymentMethod,
                    mode:          pres.mode,
                    locationId:    order.deliveryLocationId,
                    personName:    pres.personName,
                  );
                  if (pres.amountPaidTotal != null) {
                    await _ds.recordPayment(
                        order.id!, pres.amountPaidTotal!);
                  }
                }
                if (!context.mounted) return;
                // Re-lire l'ordre AVANT le sheet C : si Sheet B vient de
                // changer le mode (ex: pickup → partner), il faut que le
                // défaut "Qui a encaissé ?" reflète ce nouveau mode.
                final freshForSheet = _ds.getOrderById(order.id!) ?? order;
                final isPartnerNow =
                    freshForSheet.deliveryMode == DeliveryMode.partner;
                final partnerName = isPartnerNow
                    ? _locationNameOf(freshForSheet)
                    : null;
                // Solde courant du partenaire AVANT cette complétion :
                // affiché dans le sheet pour rendre visible la compensation
                // automatique (dette croisée). 0 si pas de partenaire.
                final balanceBefore = isPartnerNow
                        && (freshForSheet.deliveryLocationId ?? '').isNotEmpty
                    ? PartnerLedgerService.balanceForPartner(
                        freshForSheet.shopId,
                        freshForSheet.deliveryLocationId!)
                    : null;
                final fres = await showOrderCompletionSheet(
                  context,
                  initialFees: freshForSheet.fees
                      .map((f) => OrderFee(
                            id:     f['id']?.toString() ?? '',
                            label:  f['label']?.toString() ?? '',
                            amount: (f['amount'] as num?)?.toDouble() ?? 0,
                          ))
                      .toList(),
                  defaultCollectedBy: isPartnerNow
                      ? CollectedBy.partnerNotRemitted
                      : CollectedBy.boutique,
                  partnerName: partnerName,
                  partnerBalanceBefore: balanceBefore,
                  // Si la commande est déjà entièrement payée à la
                  // boutique, on désactive le radio "Partenaire a
                  // encaissé" — impossible sémantiquement. Empêche un
                  // faux saleCollected (bug rapporté).
                  orderAlreadyFullyPaid: freshForSheet.isFullyPaid,
                );
                if (fres == null) return; // annulé
                final fresh = _ds.getOrderById(order.id!) ?? order;
                final updated = fresh.copyWith(fees: fres.fees
                    .map((f) => {
                          'id': f.id,
                          'label': f.label,
                          'amount': f.amount,
                        })
                    .toList());
                await _ds.updateOrder(updated);
                // Génère les mouvements partenaires associés à la completion.
                await _generatePartnerLedgerEntries(
                    order: updated, fees: fres.fees,
                    collectedBy: fres.collectedBy);
                completedAt = fres.completedAt;
              }

              await _ds.updateOrderStatus(order.id!, status,
                  completedAt: completedAt);
              if (mounted) setState(() {});
            },
            onCancelWithReason: (reason) async {
              await _ds.cancelOrderWithReason(_orders[i].id!, reason);
              if (mounted) setState(() {});
            },
            onReschedule: (newDate, reason) async {
              await _ds.rescheduleOrder(_orders[i].id!, newDate, reason);
              if (mounted) setState(() {});
            },
            onDelete: () async {
              await _ds.deleteOrder(_orders[i].id!);
              setState(() {});
            },
          );
          },
        ),
        ),
      ),
    ]);
  }

  /// Mode de livraison par défaut au passage scheduled → processing.
  /// Suit le lieu d'origine de la commande :
  ///   * dépôt partenaire → partner
  ///   * boutique principale (type shop) → inHouse (livraison équipe)
  ///   * lieu inconnu → pickup (fallback safe)
  /// L'opérateur peut toujours surcharger dans le sheet B.
  DeliveryMode _modeForOrderLocation(Sale order) {
    final locId = order.deliveryLocationId;
    if (locId == null || locId.isEmpty) return DeliveryMode.pickup;
    try {
      final raw = HiveBoxes.stockLocationsBox.get(locId);
      if (raw == null) return DeliveryMode.pickup;
      final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
      return loc.type == StockLocationType.partner
          ? DeliveryMode.partner
          : DeliveryMode.inHouse;
    } catch (_) {
      return DeliveryMode.pickup;
    }
  }

  /// Renvoie le nom du lieu d'origine de la commande (pour affichage
  /// confirmation dans Sheet B). Null si le lieu est introuvable.
  String? _locationNameOf(Sale order) {
    final locId = order.deliveryLocationId;
    if (locId == null || locId.isEmpty) return null;
    try {
      final raw = HiveBoxes.stockLocationsBox.get(locId);
      if (raw == null) return null;
      final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
      return loc.name;
    } catch (_) { return null; }
  }

  /// Génère les mouvements partenaires consécutifs à la completion d'une
  /// commande. Cas couverts (cf. modèle des dettes croisées) :
  ///   * partenaire a encaissé (collectedBy=partnerNotRemitted)
  ///       → +(total - frais_dûs_au_partenaire) au compte partenaire
  ///   * livraison faite par un partenaire (deliveryMode=partner)
  ///       → -frais_livraison au compte partenaire
  /// Le partenaire ciblé est `deliveryLocationId` quand il s'agit d'un
  /// dépôt partenaire ; sinon on ne crée rien (cas boutique pure).
  Future<void> _generatePartnerLedgerEntries({
    required Sale order,
    required List<OrderFee> fees,
    required CollectedBy collectedBy,
  }) async {
    final partnerId = order.deliveryLocationId;
    if (partnerId == null || partnerId.isEmpty) return;
    StockLocation? loc;
    try {
      final raw = HiveBoxes.stockLocationsBox.get(partnerId);
      if (raw != null) {
        loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
      }
    } catch (_) {}
    final isPartnerLoc = loc?.type == StockLocationType.partner;

    // Idempotence : si la commande a déjà des mouvements (ex: re-completion
    // après une annulation), on les efface pour repartir sur un état sain.
    await PartnerLedgerService.removeForOrder(order.shopId, order.id!);

    final feesTotal  = fees.fold<double>(0, (s, f) => s + f.amount);
    final orderTotal = order.total;
    // Acompte boutique déjà versé avant la livraison (hotfix_065). Le
    // partenaire n'encaisse que le SOLDE (total − acompte), donc il ne
    // nous doit que ce solde, pas le total brut. Pour les commandes
    // legacy pré-hotfix, amountPaid = 0 → comportement inchangé.
    final amountPaidBefore = order.amountPaid;

    // Defense in depth : si la commande est déjà entièrement payée à la
    // boutique (amount_paid >= total), il est IMPOSSIBLE que le partenaire
    // ait encaissé quoi que ce soit. On force la branche Cas B (deliveryOwed
    // pour les frais), même si l'opérateur a coché "Partenaire a encaissé"
    // par erreur. Sans ce garde-fou, on créerait une fausse créance
    // saleCollected (cf. bug rapporté quand amount_paid n'était pas
    // correctement persistante après refresh).
    final orderAlreadyFullyPaid = amountPaidBefore >= orderTotal
        && orderTotal > 0;
    final effectiveCollectedBy = orderAlreadyFullyPaid
        ? CollectedBy.boutique
        : collectedBy;

    // Cas A : encaissement par le partenaire — crédite le partenaire (le
    // partenaire NOUS DOIT cet argent jusqu'au versement).
    if (effectiveCollectedBy == CollectedBy.partnerNotRemitted && isPartnerLoc) {
      // Si le partenaire a aussi assuré la livraison (mode partner), on
      // déduit directement les frais du montant qu'il nous doit (il a déjà
      // sa rémunération en main, on n'a plus qu'à recevoir le net).
      final livreurAussi = order.deliveryMode == DeliveryMode.partner;
      final soldeEncaisseParPartenaire =
          (orderTotal - amountPaidBefore).clamp(0, double.infinity);
      final netDu = livreurAussi
          ? (soldeEncaisseParPartenaire - feesTotal)
              .clamp(0, double.infinity)
          : soldeEncaisseParPartenaire;
      if (netDu > 0) {
        await PartnerLedgerService.addEntry(
          shopId:            order.shopId,
          partnerLocationId: partnerId,
          type:              PartnerLedgerEntryType.saleCollected,
          amount:            netDu.toDouble(),
          orderId:           order.id,
          note: amountPaidBefore > 0
              ? 'Solde encaissé par le partenaire '
                '(acompte de ${amountPaidBefore.toStringAsFixed(0)} '
                'déjà versé à la boutique)'
              : (livreurAussi
                  ? 'Vente encaissée (frais livraison déjà retenus)'
                  : 'Vente encaissée par le partenaire'),
        );
      }
      return;
    }

    // Cas B : livraison par le partenaire mais encaissement boutique →
    // la boutique DOIT les frais de livraison au partenaire.
    // Inclut le cas orderAlreadyFullyPaid (commande prépayée à la boutique).
    if (order.deliveryMode == DeliveryMode.partner
        && isPartnerLoc
        && feesTotal > 0) {
      await PartnerLedgerService.addEntry(
        shopId:            order.shopId,
        partnerLocationId: partnerId,
        type:              PartnerLedgerEntryType.deliveryOwed,
        amount:            -feesTotal,
        orderId:           order.id,
        note:              'Frais de livraison à verser au partenaire',
      );
    }
  }
}

// ─── Carte commande (expandable) ─────────────────────────────────────────────
class _OrderCard extends ConsumerStatefulWidget {
  final Sale   order;
  final void Function(SaleStatus) onUpdate;
  /// Annule la commande avec une raison fournie par l'opérateur.
  final Future<void> Function(String reason) onCancelWithReason;
  /// Reprogramme une commande "en cours" vers une nouvelle date avec raison.
  final Future<void> Function(DateTime newDate, String reason) onReschedule;
  final VoidCallback onDelete;
  /// True si l'utilisateur peut annuler/rembourser une vente
  /// (permission salesCancel = admin/owner par défaut).
  final bool canCancel;
  /// True si l'utilisateur peut supprimer une commande
  /// (permission caisseEditOrders en mode delete).
  final bool canDelete;
  /// True si l'utilisateur peut éditer une commande déjà créée
  /// (permission caisseEditOrders).
  final bool canEdit;
  const _OrderCard({required this.order,
    required this.onUpdate,
    required this.onCancelWithReason,
    required this.onReschedule,
    required this.onDelete,
    required this.canCancel,
    required this.canDelete,
    required this.canEdit});
  @override
  ConsumerState<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends ConsumerState<_OrderCard> {
  bool _expanded = false;
  bool _sendingInvoice = false;

  /// Somme absolue des dépenses enregistrées comme dette envers le
  /// partenaire-livreur pour CETTE commande (entrées `deliveryOwed`
  /// négatives liées via `orderId`). Lue depuis partner_ledger à chaque
  /// build (Hive synchrone, coût négligeable pour <quelques milliers
  /// d'entrées). Retourne 0 si pas de partenaire ou pas de dette.
  double get _orderDebtToPartner {
    final partnerId = widget.order.deliveryLocationId;
    if (partnerId == null || partnerId.isEmpty) return 0;
    final orderId = widget.order.id;
    if (orderId == null) return 0;
    final entries = PartnerLedgerService.entriesForShop(
        widget.order.shopId, partnerLocationId: partnerId);
    var sum = 0.0;
    for (final e in entries) {
      if (e.orderId != orderId) continue;
      if (e.type != PartnerLedgerEntryType.deliveryOwed) continue;
      // deliveryOwed est stockée en négatif (boutique doit). Pour le
      // bandeau on veut le montant absolu de la dette.
      if (e.amount < 0) sum += e.amount.abs();
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final s     = widget.order.status;
    final color = s.color;
    final client = widget.order.clientName;

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: _expanded
                  ? color.withValues(alpha:0.35)
                  : AppColors.divider),
          boxShadow: [BoxShadow(
              color: Colors.black.withValues(alpha:0.03),
              blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── Ligne résumé (toujours visible) ───────────────
            Row(children: [
              // Partie gauche — prend tout l'espace disponible
              Expanded(
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                        color: color.withValues(alpha:0.12),
                        borderRadius: BorderRadius.circular(6)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(_statusLabel(s),
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: color)),
                      // Marqueur "reprogrammée" : icône repeat à côté du
                      // libellé pour différencier visuellement les commandes
                      // qui ont été déplacées dans le temps.
                      if (s == SaleStatus.scheduled
                          && (widget.order.rescheduleReason ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(Icons.event_repeat_rounded,
                              size: 10, color: color),
                        ),
                    ]),
                  ),
                  // Pastille statut paiement (cf. hotfix_065) — affichée
                  // uniquement si la commande n'est pas annulée/refusée
                  // (ces statuts rendent le paiement non pertinent).
                  if (s != SaleStatus.cancelled
                      && s != SaleStatus.refused) ...[
                    const SizedBox(width: 4),
                    _PaymentStatusPill(status: widget.order.paymentStatus),
                  ],
                  // Badge "Web" / "WhatsApp" — ne s'affiche que si source != 'pos'.
                  if (widget.order.source != 'pos') ...[
                    const SizedBox(width: 5),
                    OrderSourceBadge(source: widget.order.source),
                  ],
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _formatDate(widget.order.createdAt),
                      style: const TextStyle(
                          fontSize: 10, color: AppColors.textHint),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.order.scheduledAt != null) ...[
                    const SizedBox(width: 5),
                    Container(
                      width: 3, height: 3,
                      decoration: const BoxDecoration(
                          color: Color(0xFFDDDDDD),
                          shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 5),
                    Icon(Icons.event_rounded,
                        size: 11, color: AppColors.warning),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text('Livré ${_formatDate(widget.order.scheduledAt!)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AppColors.warning)),
                    ),
                  ],
                  if (client != null) ...[
                    const SizedBox(width: 5),
                    Container(
                      width: 3, height: 3,
                      decoration: const BoxDecoration(
                          color: Color(0xFFDDDDDD),
                          shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 5),
                    Icon(Icons.person_outline_rounded,
                        size: 11, color: AppColors.textHint),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(client,
                          style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF374151),
                              fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1),
                    ),
                  ],
                ]),
              ),
              // Partie droite fixe — prix + chevron collés à droite
              const SizedBox(width: 8),
              Text(
                CurrencyFormatter.format(widget.order.total),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: AppColors.primary),
              ),
              const SizedBox(width: 6),
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 220),
                child: Icon(Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: _expanded ? color : const Color(0xFFBBBBBB)),
              ),
            ]),

            // ── Bandeau dette enregistrée envers le partenaire ────
            // Affiché si la commande a des dépenses supplémentaires
            // enregistrées comme dette envers son partenaire-livreur.
            // Compensée automatiquement au prochain encaissement
            // (saleCollected) du partenaire via le solde signé du ledger.
            if (_orderDebtToPartner > 0) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: AppColors.error.withValues(alpha: 0.2),
                      width: 0.5),
                ),
                child: Row(children: [
                  Icon(Icons.attach_money_rounded,
                      size: 12, color: AppColors.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        'Dette partenaire : '
                        '${CurrencyFormatter.format(_orderDebtToPartner)} '
                        '— compensée au prochain versement',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.error),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ),
            ],

            // ── Bandeau « Reste à payer » (cf. hotfix_065) ─────
            // Toujours visible (hors zone expansion) si la commande a un
            // solde non encaissé et un statut pertinent. Tap → ouvre
            // directement RecordAcompteDialog (raccourci sans déplier).
            if (widget.order.amountDue > 0
                && s != SaleStatus.cancelled
                && s != SaleStatus.refused
                && s != SaleStatus.refunded) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: () => _recordAcompte(context),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: AppColors.warning.withValues(alpha: 0.25),
                        width: 0.5),
                  ),
                  child: Row(children: [
                    Icon(Icons.payments_outlined,
                        size: 12, color: AppColors.warning),
                    const SizedBox(width: 6),
                    Text(
                        widget.order.amountPaid > 0
                            ? 'Reste ${CurrencyFormatter.format(
                                widget.order.amountDue)} à encaisser'
                            : 'Encaisser ${CurrencyFormatter.format(
                                widget.order.amountDue)}',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.warning)),
                    const Spacer(),
                    Text('Enregistrer →',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: AppColors.warning
                                .withValues(alpha: 0.85))),
                  ]),
                ),
              ),
            ],

            // ── Détails expandés ───────────────────────────────
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 220),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  const Divider(height: 1, color: AppColors.inputFill),
                  const SizedBox(height: 8),

                  // Articles
                  ...widget.order.items.map((i) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(children: [
                      Container(
                        width: 20, height: 20,
                        decoration: BoxDecoration(
                          color: AppColors.primarySurface,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Center(
                          child: Text('${i.quantity}',
                              style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.primary)),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(i.productName,
                            style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF374151)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                  )),

                  // Notes
                  if (widget.order.notes != null) ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.notes_rounded,
                          size: 11, color: AppColors.textHint),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(widget.order.notes!,
                            style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.textHint,
                                fontStyle: FontStyle.italic)),
                      ),
                    ]),
                  ],

                  const SizedBox(height: 8),
                  const Divider(height: 1, color: AppColors.inputFill),
                  const SizedBox(height: 8),

                  // ── Détails complets (paiement, livraison, expédition,
                  //    décomposition financière). Visible dans l'expand.
                  _OrderDetailsBlock(order: widget.order),
                  const SizedBox(height: 8),
                  const Divider(height: 1, color: AppColors.inputFill),
                  const SizedBox(height: 8),

                  // Relance WhatsApp : visible pour les commandes non finalisées
                  // dont la date de livraison est atteinte (ou dépassée).
                  if (_canRemindClient()) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _sendingInvoice
                            ? null
                            : () => _remindClient(context),
                        icon: _sendingInvoice
                            ? const SizedBox(
                                width: 14, height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF25D366)),
                              )
                            : const Icon(Icons.phonelink_ring_rounded,
                                size: 15),
                        label: Text(
                            _sendingInvoice
                                ? 'Préparation du rappel…'
                                : 'Relancer via WhatsApp',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF25D366),
                          side: const BorderSide(color: Color(0xFF25D366)),
                          padding:
                              const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // ── Transfert au livreur (cf. hotfix_049) ──────────
                  // Affiché pour toute commande "scheduled" si le user a
                  // la permission. Ouvre un sheet 2 étapes (destinataire
                  // + aperçu éditable) qui appelle la RPC atomique
                  // `transfer_order_to_delivery`.
                  if (widget.order.status == SaleStatus.scheduled
                      && _permsForOrder().canTransferDelivery) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _openTransferDeliverySheet(context),
                        icon: const Icon(Icons.local_shipping_rounded,
                            size: 14),
                        label: Text(context.l10n.deliveryTransferBtn,
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w700)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF25D366),
                          side: const BorderSide(
                              color: Color(0xFF25D366), width: 1.2),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // ── Actions client ─────────────────────────────────
                  // Pour une commande "programmée" arrivée à échéance
                  // (date du jour ou passée) : raccourcis "validée" /
                  // "annulée par client".
                  if (_canConfirmClient()) ...[
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => widget.onUpdate(SaleStatus.processing),
                          icon: const Icon(Icons.check_circle_outline_rounded,
                              size: 14),
                          label: const Text('Validée par client',
                              style: TextStyle(fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.secondary,
                            side: BorderSide(
                                color: AppColors.secondary.withValues(alpha:0.6)),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _askCancelReason(context),
                          icon: const Icon(Icons.cancel_outlined, size: 14),
                          label: const Text('Annulée par client',
                              style: TextStyle(fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.error,
                            side: BorderSide(
                                color: AppColors.error.withValues(alpha:0.6)),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                  ],

                  // Pour une commande "en cours" : reprogrammer si
                  // empêchement (boutique ou client).
                  if (_canReschedule()) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _askReschedule(context),
                        icon: const Icon(Icons.event_repeat_rounded, size: 14),
                        label: const Text('Reprogrammer la commande',
                            style: TextStyle(fontSize: 11,
                                fontWeight: FontWeight.w700)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.warning,
                          side: BorderSide(
                              color: AppColors.warning.withValues(alpha:0.6)),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Actions
                  Row(children: [
                    Expanded(
                      child: _StatusMenu(
                          current: s, onSelect: widget.onUpdate,
                          canCancel: widget.canCancel),
                    ),
                    const SizedBox(width: 6),
                    if (widget.order.status == SaleStatus.completed) ...[
                      _ActionBtn(
                        icon: Icons.picture_as_pdf_rounded,
                        color: AppColors.primary,
                        tooltip: 'Imprimer / PDF',
                        onTap: () => DocumentService.previewInvoice(widget.order, context),
                      ),
                      const SizedBox(width: 6),
                      _ActionBtn(
                        icon: _sendingInvoice
                            ? Icons.hourglass_top_rounded
                            : Icons.send_rounded,
                        color: const Color(0xFF25D366),
                        tooltip: 'Envoyer la facture par WhatsApp',
                        onTap: _sendingInvoice
                            ? null
                            : () => _sendInvoiceWhatsApp(context),
                      ),
                      const SizedBox(width: 6),
                      _ActionBtn(
                        icon: Icons.share_rounded,
                        color: const Color(0xFF3B82F6),
                        tooltip: 'Partager',
                        onTap: () => _showFormatPicker(context),
                      ),
                      const SizedBox(width: 6),
                      // Bouton "Ajouter dépense en dette" — visible
                      // uniquement si livraison partenaire ET commande
                      // déjà entièrement encaissée. Crée une entrée
                      // deliveryOwed négative dans le partner_ledger.
                      if (widget.order.deliveryMode == DeliveryMode.partner
                          && (widget.order.deliveryLocationId ?? '').isNotEmpty
                          && widget.order.isFullyPaid) ...[
                        _ActionBtn(
                          icon: Icons.attach_money_rounded,
                          color: AppColors.warning,
                          bgColor: const Color(0xFFFFF7ED),
                          tooltip: 'Ajouter une dépense en dette partenaire',
                          onTap: () => _addOrderExpense(context),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ],
                    // Bouton "Enregistrer un acompte" — visible si commande
                    // en attente de paiement (pas annulée/refusée/refunded)
                    // ET solde dû > 0. Permet à l'opérateur d'enregistrer
                    // un encaissement boutique partiel avant la livraison ;
                    // le partner_ledger calculera ensuite uniquement le
                    // solde réellement encaissé par le partenaire.
                    if (widget.order.amountDue > 0
                        && widget.order.status != SaleStatus.cancelled
                        && widget.order.status != SaleStatus.refused
                        && widget.order.status != SaleStatus.refunded) ...[
                      _ActionBtn(
                        icon: Icons.payments_outlined,
                        color: AppColors.warning,
                        bgColor: const Color(0xFFFFF7ED),
                        tooltip: 'Enregistrer un acompte',
                        onTap: () => _recordAcompte(context),
                      ),
                      const SizedBox(width: 6),
                    ],
                    // Bouton "Relancer le client" — visible UNIQUEMENT pour
                    // les commandes en cours / programmées (pas après
                    // completed/cancelled/refused/refunded).
                    if (widget.order.status == SaleStatus.scheduled ||
                        widget.order.status == SaleStatus.processing) ...[
                      _ActionBtn(
                        icon: Icons.notifications_active_outlined,
                        color: const Color(0xFF25D366),
                        tooltip: context.l10n.orderRelaunchBtn,
                        onTap: () => _relaunchClient(context),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (widget.canEdit) ...[
                      _ActionBtn(
                        icon: Icons.edit_rounded,
                        color: AppColors.primary,
                        bgColor: AppColors.primarySurface,
                        tooltip: 'Modifier la commande',
                        onTap: () => _showEditOrder(context),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (widget.canDelete)
                      _ActionBtn(
                        icon: Icons.delete_outline_rounded,
                        color: AppColors.error,
                        bgColor: const Color(0xFFFEF2F2),
                        tooltip: 'Supprimer',
                        onTap: () => _confirmDelete(context),
                      ),
                  ]),
                  // Historique des transferts au livreur (cf. hotfix_049).
                  // S'affiche en lecture seule + bouton "Renvoyer" par row.
                  if (widget.order.id != null)
                    TransferHistorySection(orderId: widget.order.id!),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    final now = DateTime.now();
    if (d.day == now.day && d.month == now.month)
      return "Auj. ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}";
    return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')} '
        '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
  }

  /// Conditions pour proposer la relance WhatsApp :
  /// - Commande non finalisée (scheduled ou processing).
  /// - Téléphone client renseigné.
  /// - Date de livraison atteinte ou dans moins de 24h.
  bool _canRemindClient() {
    final o = widget.order;
    final status = o.status;
    if (status != SaleStatus.scheduled && status != SaleStatus.processing) {
      return false;
    }
    if ((o.clientPhone ?? '').trim().isEmpty) return false;
    final due = o.scheduledAt;
    if (due == null) return false;
    final diff = due.difference(DateTime.now());
    // Visible dès que la date est dans moins de 24h OU dépassée
    return diff.inHours <= 24;
  }

  /// Relance avec lien de suivi — ouvre WhatsApp **synchrone** dans le tick
  /// du clic, avec un message contenant le lien `/track/<order_id>` qui
  /// permet au client de voir sa commande et la valider en un clic
  /// (status `scheduled` → `processing`).
  ///
  /// Pas d'`await` avant `window.open` : sur web le user gesture serait
  /// perdu et le popup bloqué silencieusement. Le lien de tracking est
  /// construit synchrone à partir de l'order id (rien à uploader).
  void _remindClient(BuildContext context) {
    final order = widget.order;
    final phone = (order.clientPhone ?? '').trim();
    if (phone.isEmpty) {
      AppSnack.error(context,
          'Numéro WhatsApp du client manquant — '
          'ajoute-le dans la fiche client puis réessaie.');
      return;
    }
    final p = PhoneFormatter.toWame(phone).replaceAll(RegExp(r'[^\d]'), '');
    if (p.isEmpty) {
      AppSnack.error(context, 'Numéro WhatsApp invalide.');
      return;
    }
    if (order.id == null) {
      AppSnack.error(context,
          'Cette commande n\'a pas encore été synchronisée. '
          'Réessaie dans un instant.');
      return;
    }
    final shop = LocalStorageService.getShop(order.shopId);
    final shopName = shop?.name ?? 'Fortress';
    final clientName = order.clientName ?? 'Cher client';
    final totalStr = CurrencyFormatter.format(order.total);
    // Lien de suivi public — le client y verra sa commande et pourra la
    // valider en un tap. La RPC `validate_order_by_client` bascule alors
    // le statut vers `processing` (cf. hotfix_057_order_tracking.sql).
    final trackUrl = 'https://fortress-pos.web.app/track/${order.id}';
    final msg =
        'Bonjour $clientName,\n\n'
        'Petit rappel pour votre commande chez $shopName '
        '(total : $totalStr).\n\n'
        'Voir et valider votre commande :\n$trackUrl\n\n'
        'Merci et à bientôt 🙏';
    final url = 'https://wa.me/$p?text=${Uri.encodeComponent(msg)}';

    openExternal(url).then((ok) {
      if (!ok && context.mounted) {
        AppSnack.error(context,
            'Impossible d\'ouvrir WhatsApp. Autorisez les pop-ups dans le navigateur.');
      }
    });
  }

  /// Relance le client par WhatsApp avec la liste des produits commandés
  /// + le total. Le propriétaire complète/envoie depuis son WhatsApp.
  ///
  /// Volontairement **synchrone** jusqu'à `launchUrl` : sur web, n'importe
  /// quel `await` avant l'ouverture rompt le user gesture et le navigateur
  /// bloque silencieusement la nouvelle fenêtre wa.me.
  /// Enregistre une dépense additionnelle sur une commande complétée et
  /// entièrement payée par le client. La dépense est inscrite comme dette
  /// envers le partenaire-livreur (entrée `deliveryOwed` négative dans le
  /// partner_ledger). Compensée automatiquement au prochain encaissement
  /// du partenaire via le solde signé du ledger.
  Future<void> _addOrderExpense(BuildContext context) async {
    final res = await AddOrderExpenseDialog.show(context, widget.order);
    if (res == null || !mounted) return;
    final partnerId = widget.order.deliveryLocationId;
    if (partnerId == null || partnerId.isEmpty) return;
    await PartnerLedgerService.addEntry(
      shopId:            widget.order.shopId,
      partnerLocationId: partnerId,
      type:              PartnerLedgerEntryType.deliveryOwed,
      amount:            -res.amount, // négatif = boutique doit au partenaire
      orderId:           widget.order.id,
      note:              res.label,
    );
    if (mounted) setState(() {});
    if (mounted) {
      AppSnack.success(context,
          'Dépense de ${CurrencyFormatter.format(res.amount)} '
          'enregistrée en dette — compensée au prochain versement');
    }
  }

  /// Ouvre RecordAcompteDialog. À la confirmation, persiste le nouveau
  /// `amountPaid` cumulé via SaleLocalDatasource.recordPayment (qui dérive
  /// `payment_status` automatiquement : partial si < total, paid si =>).
  Future<void> _recordAcompte(BuildContext context) async {
    final newAmount = await RecordAcompteDialog.show(context, widget.order);
    if (newAmount == null || !mounted) return;
    await SaleLocalDatasource()
        .recordPayment(widget.order.id!, newAmount);
    if (mounted) setState(() {});
    if (mounted) {
      AppSnack.success(context,
          newAmount >= widget.order.total
              ? 'Commande totalement encaissée'
              : 'Acompte enregistré');
    }
  }

  void _relaunchClient(BuildContext context) {
    final order = widget.order;
    final phone = (order.clientPhone ?? '').trim();
    if (phone.isEmpty) {
      AppSnack.error(context,
          'Numéro WhatsApp du client manquant — '
          'ajoute-le dans la fiche client puis réessaie.');
      return;
    }
    final firstName = (order.clientName ?? '')
        .trim().split(RegExp(r'\s+')).first;
    final reference = order.id ?? order.createdAt.millisecondsSinceEpoch
        .toRadixString(16).toUpperCase().substring(0, 6);
    final items = order.items.map((it) {
      final qty   = it.quantity;
      final name  = it.productName;
      final total = CurrencyFormatter.format(it.unitPrice * qty);
      return '• ${qty}× $name — $total';
    }).join('\n');
    final totalStr = CurrencyFormatter.format(order.total);
    final msg = context.l10n.orderRelaunchMessage(
      firstName: firstName.isEmpty ? 'cher client' : firstName,
      reference: reference,
      items:     items.isEmpty ? '—' : items,
      total:     totalStr,
    );
    final p = PhoneFormatter.toWame(phone).replaceAll(RegExp(r'[^\d]'), '');
    if (p.isEmpty) {
      AppSnack.error(context, 'Numéro WhatsApp invalide.');
      return;
    }
    final url = 'https://wa.me/$p?text=${Uri.encodeComponent(msg)}';
    // `openExternal` utilise `window.open` synchrone sur web (bypass des
    // popup blockers) et `url_launcher` natif sur mobile/desktop.
    openExternal(url).then((ok) {
      if (!ok && context.mounted) {
        AppSnack.error(context,
            'Impossible d\'ouvrir WhatsApp. Autorisez les pop-ups dans le navigateur.');
      }
    });
  }

  /// Envoie la facture PDF d'une commande complétée par WhatsApp.
  ///
  /// Même contrainte que `_remindClient` : sur web, l'ouverture de wa.me doit
  /// se faire dans le tick du clic (sinon popup blocker). On ouvre donc
  /// WhatsApp **synchrone** avec un message court, et on upload le PDF en
  /// arrière-plan → lien copié dans le presse-papier pour collage dans le
  /// chat.
  void _sendInvoiceWhatsApp(BuildContext context) {
    final order = widget.order;
    final phone = (order.clientPhone ?? '').trim();
    if (phone.isEmpty) {
      AppSnack.error(context,
          'Numéro WhatsApp du client manquant — '
          'ajoute-le dans la fiche client puis réessaie.');
      return;
    }
    final p = PhoneFormatter.toWame(phone).replaceAll(RegExp(r'[^\d]'), '');
    if (p.isEmpty) {
      AppSnack.error(context, 'Numéro WhatsApp invalide.');
      return;
    }
    final shop = LocalStorageService.getShop(order.shopId);
    final shopName = shop?.name ?? 'Fortress';
    final clientName = order.clientName ?? 'Cher client';
    final totalStr = CurrencyFormatter.format(order.total);
    // Message court — sans lien (sera collé après par l'utilisateur).
    final msg =
        'Bonjour $clientName,\n\n'
        'Merci pour votre achat chez $shopName '
        '(total : $totalStr).\n\n'
        'Votre facture PDF arrive dans un instant. À bientôt 🙏';
    final url = 'https://wa.me/$p?text=${Uri.encodeComponent(msg)}';

    // 1. Ouverture SYNCHRONE de WhatsApp dans le tick du clic.
    openExternal(url).then((ok) {
      if (!ok && context.mounted) {
        AppSnack.error(context,
            'Impossible d\'ouvrir WhatsApp. Autorisez les pop-ups dans le navigateur.');
      }
    });

    // 2. En arrière-plan : génération + upload du PDF, copie du lien
    //    dans le presse-papier, snackbar pour informer l'utilisateur.
    setState(() => _sendingInvoice = true);
    () async {
      try {
        final bytes = await OrderReceiptUseCase.generatePdf(order, shop: shop);
        final orderId = order.id
            ?? 'order_${order.createdAt.millisecondsSinceEpoch}';
        final longUrl = await InvoiceStorageService.uploadInvoice(
          shopId:  order.shopId,
          orderId: orderId,
          bytes:   bytes,
        );
        if (longUrl == null) {
          if (mounted) {
            AppSnack.error(context,
                'Upload de la facture échoué — vérifie ta connexion.');
          }
          return;
        }
        final shortUrl = await UrlShortenerService.shorten(longUrl);
        await Clipboard.setData(ClipboardData(text: shortUrl));
        if (mounted) {
          AppSnack.success(context,
              'Lien de la facture copié — colle-le dans le chat WhatsApp.');
        }
      } catch (e) {
        if (mounted) {
          AppSnack.error(context, 'Erreur envoi facture : $e');
        }
      } finally {
        if (mounted) setState(() => _sendingInvoice = false);
      }
    }();
  }

  /// Conditions pour afficher les raccourcis "Validée par client" /
  /// "Annulée par client" : commande programmée ET date de livraison
  /// atteinte (jour J ou passée).
  bool _canConfirmClient() {
    final o = widget.order;
    if (o.status != SaleStatus.scheduled) return false;
    final due = o.scheduledAt;
    if (due == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 23, 59, 59);
    return !due.isAfter(today);
  }

  /// "Reprogrammer" : disponible uniquement quand la commande est en cours.
  bool _canReschedule() => widget.order.status == SaleStatus.processing;

  /// Permissions de l'utilisateur pour le shop de cette commande.
  AppPermissions _permsForOrder() =>
      ref.read(permissionsProvider(widget.order.shopId));

  /// Ouvre le sheet de transfert au livreur (cf. hotfix_049).
  Future<void> _openTransferDeliverySheet(BuildContext context) async {
    final shop = LocalStorageService.getShop(widget.order.shopId);
    final ok = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => TransferDeliverySheet(
        order:    widget.order,
        shopId:   widget.order.shopId,
        shopName: shop?.name ?? '',
      ),
    );
    if (ok == true && context.mounted) {
      // Rafraîchit l'écran : la commande est passée à processing via la RPC.
      // Le realtime listener mettra Hive à jour, mais on déclenche aussi un
      // refresh local pour retour visuel immédiat.
      AppDatabase.notifyOrderChange(widget.order.shopId);
      // Invalide la liste de transferts pour que la nouvelle row s'affiche
      // immédiatement dans l'historique sous la fiche.
      if (widget.order.id != null) {
        ref.invalidate(orderDeliveryTransfersProvider(widget.order.id!));
      }
    }
  }

  /// Libellé du statut, avec sous-statut "Reprogrammée" pour les commandes
  /// programmées dont la `rescheduleReason` est renseignée.
  String _statusLabel(SaleStatus s) {
    if (s == SaleStatus.scheduled
        && (widget.order.rescheduleReason ?? '').isNotEmpty) {
      return 'Reprogrammée';
    }
    return s.label;
  }

  /// Demande une raison (texte libre) puis annule la commande via le
  /// callback parent. Bloque la validation tant que la raison est vide.
  Future<void> _askCancelReason(BuildContext context) async {
    final reason = await _ReasonDialog.ask(
      context,
      title: 'Annulation de la commande',
      hint: 'Pourquoi la commande est-elle annulée ?',
      confirmLabel: 'Annuler la commande',
      confirmColor: AppColors.error,
    );
    if (reason == null) return;
    await widget.onCancelWithReason(reason);
  }

  /// Demande une nouvelle date + raison puis reprogramme via le callback.
  Future<void> _askReschedule(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.order.scheduledAt
          ?.isAfter(now) == true
              ? widget.order.scheduledAt!
              : now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      locale: const Locale('fr', 'FR'),
    );
    if (picked == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
          widget.order.scheduledAt
              ?? DateTime(picked.year, picked.month, picked.day, 14)),
    );
    if (!context.mounted) return;
    final newDate = DateTime(picked.year, picked.month, picked.day,
        time?.hour ?? 14, time?.minute ?? 0);
    final reason = await _ReasonDialog.ask(
      context,
      title: 'Reprogrammer la commande',
      hint: 'Empêchement client / boutique — précise la raison.',
      confirmLabel: 'Reprogrammer',
      confirmColor: AppColors.warning,
    );
    if (reason == null) return;
    await widget.onReschedule(newDate, reason);
  }

  void _showEditOrder(BuildContext context) {
    // Avertissement si commande complétée
    if (widget.order.status == SaleStatus.completed) {
      showDialog(
        context: context,
        builder: (dc) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.warning_amber_rounded,
                  size: 18, color: AppColors.warning),
            ),
            const SizedBox(width: 10),
            const Text('Commande complétée',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ]),
          content: const Text(
              'Cette commande a déjà été complétée. '
                  'La modifier peut affecter la comptabilité. '
                  'Continuer quand même ?',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dc).pop(),
                child: const Text('Annuler',
                    style: TextStyle(color: AppColors.textSecondary))),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dc).pop();
                _openEditSheet(context);
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.warning,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: const Text('Modifier quand même'),
            ),
          ],
        ),
      );
    } else {
      _openEditSheet(context);
    }
  }

  void _openEditSheet(BuildContext context) {
    // 1. Pré-remplir le bloc AVANT de naviguer
    context.read<CaisseBloc>().add(LoadOrderForEdit(widget.order));

    // 2. Naviguer vers la page Caisse principale (route shell). Anciennement
    //    on basculait sur le tab Principal du TabController interne — depuis
    //    l'extraction de OrdersPage, c'est une route distincte.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      context.go('/shop/${widget.order.shopId}/caisse');
    });
  }

  void _showFormatPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _FormatPickerSheet(order: widget.order),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final id = widget.order.id ?? '';
    final saleRef = id.length >= 6
        ? id.substring(id.length - 6)
        : (id.isEmpty ? 'commande' : id);
    final clientName = widget.order.clientName;
    await DangerActionService.execute(
      context:      context,
      perms:        ref.read(permissionsProvider(widget.order.shopId)),
      action:       DangerAction.cancelSale,
      shopId:       widget.order.shopId,
      targetId:     id,
      targetLabel:  clientName != null && clientName.isNotEmpty
          ? '$clientName · $saleRef'
          : saleRef,
      title:        'Supprimer cette commande',
      description:  clientName != null && clientName.isNotEmpty
          ? 'Commande de $clientName · réf. $saleRef'
          : 'Réf. $saleRef',
      consequences: const [
        'La commande est définitivement supprimée.',
        'Le stock réservé sera libéré.',
      ],
      confirmText:  saleRef,
      onConfirmed:  () async => widget.onDelete(),
    );
  }
}

// ─── Sélecteur de format d'impression ────────────────────────────────────────
class _FormatPickerSheet extends StatefulWidget {
  final Sale order;
  const _FormatPickerSheet({required this.order});
  @override
  State<_FormatPickerSheet> createState() => _FormatPickerSheetState();
}

class _FormatPickerSheetState extends State<_FormatPickerSheet> {

  static const _formats = [
    _PaperFormat('A4',        'Standard international',   210, 297, Icons.description_outlined, false),
    _PaperFormat('A5',        'Demi A4 — compact',        148, 210, Icons.description_outlined, false),
    _PaperFormat('A6',        'Carte postale',             105, 148, Icons.description_outlined, false),
    _PaperFormat('Ticket 80', 'Ticket caisse 80mm',         80, 200, Icons.receipt_outlined,     true),
    _PaperFormat('Ticket 58', 'Ticket caisse 58mm',         58, 160, Icons.receipt_outlined,     true),
    _PaperFormat('Ticket 57', 'Rouleau standard POS 57mm',  57, 140, Icons.receipt_outlined,     true),
  ];

  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final fmt = _formats[_selected];
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF8F7FF),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [

        // ── Poignée ─────────────────────────────────────────
        Container(
          margin: const EdgeInsets.only(top: 12, bottom: 4),
          width: 36, height: 4,
          decoration: BoxDecoration(
              color: const Color(0xFFDDD9F0),
              borderRadius: BorderRadius.circular(2)),
        ),

        // ── Titre ───────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.print_rounded,
                  size: 18, color: AppColors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Format d'impression",
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary)),
                  const Text('Choisissez le format de votre reçu',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textHint)),
                ],
              ),
            ),
          ]),
        ),

        // ── Corps : aperçu + liste ───────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FormatPreview(order: widget.order, format: fmt),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  children: _formats.asMap().entries.map((e) {
                    final i   = e.key;
                    final f   = e.value;
                    final sel = i == _selected;
                    return GestureDetector(
                      onTap: () => setState(() => _selected = i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 9),
                        decoration: BoxDecoration(
                          color: sel
                              ? AppColors.primarySurface
                              : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: sel
                                ? AppColors.primary.withValues(alpha:0.5)
                                : const Color(0xFFE8E8EE),
                            width: sel ? 1.5 : 1,
                          ),
                        ),
                        child: Row(children: [
                          Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                              color: sel
                                  ? AppColors.primary
                                  : AppColors.inputFill,
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Icon(f.icon, size: 14,
                                color: sel
                                    ? Colors.white
                                    : AppColors.textHint),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(f.name,
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: sel
                                            ? AppColors.primary
                                            : AppColors.textPrimary)),
                                Text(f.description,
                                    style: const TextStyle(
                                        fontSize: 9,
                                        color: AppColors.textHint)),
                              ],
                            ),
                          ),
                          Text(
                            '${f.widthMm}×${f.heightMm}mm',
                            style: TextStyle(
                                fontSize: 9,
                                color: sel
                                    ? AppColors.primary
                                    : const Color(0xFFBBBBBB),
                                fontWeight: FontWeight.w600),
                          ),
                          if (sel) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.check_circle_rounded,
                                size: 14, color: AppColors.primary),
                          ],
                        ]),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),

        // ── Boutons action ───────────────────────────────────
        Padding(
          padding: EdgeInsets.fromLTRB(
              16, 0, 16, 16 + MediaQuery.of(context).padding.bottom),
          child: Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.visibility_rounded, size: 16),
                label: const Text('Visualiser'),
                onPressed: () {
                  Navigator.of(context).pop();
                  // Printing.layoutPdf ouvre un aperçu natif
                  // avec options d'impression/export intégrées
                  DocumentService.previewInvoice(
                      widget.order, context,
                      pageFormat: _formats[_selected].toPdfFormat());
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.share_rounded, size: 16),
                label: const Text('Partager'),
                onPressed: () {
                  Navigator.of(context).pop();
                  DocumentService.shareInvoice(
                      widget.order,
                      pageFormat: _formats[_selected].toPdfFormat());
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: BorderSide(
                      color: AppColors.primary.withValues(alpha:0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}


// ─── Aperçu visuel du format ──────────────────────────────────────────────────
class _FormatPreview extends StatelessWidget {
  final Sale         order;
  final _PaperFormat format;
  const _FormatPreview({required this.order, required this.format});

  @override
  Widget build(BuildContext context) {
    // Ratio largeur/hauteur du format
    final ratio    = format.widthMm / format.heightMm;
    final previewW = format.isTicket ? 70.0 : 90.0;
    final previewH = (previewW / ratio).clamp(100.0, 240.0);

    return Container(
      width:  previewW,
      height: previewH,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha:0.08),
              blurRadius: 8, offset: const Offset(0, 3)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        // En-tête violet
        Container(
          color: AppColors.primary,
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Center(
            child: Text('REÇU',
                style: TextStyle(
                    fontSize: format.isTicket ? 6 : 7,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 1.5)),
          ),
        ),
        // Lignes simulées
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _line(previewW * 0.5, AppColors.primary.withValues(alpha:0.3)),
                const SizedBox(height: 4),
                _line(previewW * 0.35, AppColors.divider),
                const SizedBox(height: 6),
                // Lignes articles
                ...List.generate(
                    order.items.length.clamp(1, format.isTicket ? 3 : 4),
                        (_) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(children: [
                        Expanded(child: _line(double.infinity,
                            AppColors.divider)),
                        const SizedBox(width: 4),
                        _line(18, AppColors.primary.withValues(alpha:0.2)),
                      ]),
                    )),
                const Spacer(),
                // Ligne total
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Row(children: [
                    _line(previewW * 0.25, AppColors.primary.withValues(alpha:0.4)),
                    const Spacer(),
                    _line(previewW * 0.3, AppColors.primary),
                  ]),
                ),
              ],
            ),
          ),
        ),
        // Nom format en bas
        Container(
          color: const Color(0xFFF8F7FF),
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Center(
            child: Text(format.name,
                style: TextStyle(
                    fontSize: 7,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary)),
          ),
        ),
      ]),
    );
  }

  Widget _line(double w, Color color) => Container(
    width: w == double.infinity ? null : w,
    height: 4,
    decoration: BoxDecoration(
        color: color, borderRadius: BorderRadius.circular(2)),
  );
}

// ─── Modèle format papier ─────────────────────────────────────────────────────
class _PaperFormat {
  final String   name;
  final String   description;
  final double   widthMm;
  final double   heightMm;
  final IconData icon;
  final bool     isTicket;
  const _PaperFormat(this.name, this.description,
      this.widthMm, this.heightMm, this.icon, this.isTicket);

  PdfPageFormat toPdfFormat() {
    const mmPt = 2.8346456692913385;
    return PdfPageFormat(
      widthMm * mmPt,
      heightMm * mmPt,
      marginAll: isTicket ? 8 * mmPt : 20 * mmPt,
    );
  }
}

// ─── Pastille statut paiement (cf. hotfix_065) ──────────────────────────────
//
// Affichée à côté du status workflow sur chaque card commande. Couleur et
// label dérivés de l'enum PaymentStatus (rouge = unpaid, orange = partial,
// vert = paid, gris = refunded). Self-cohérent avec le partner_ledger qui
// utilise les mêmes conventions.
class _PaymentStatusPill extends StatelessWidget {
  final PaymentStatus status;
  const _PaymentStatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = status.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.5),
      ),
      child: Text(status.label,
          style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: color)),
    );
  }
}

// ─── Bouton action icône ─────────────────────────────────────────────────────
class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final Color?   bgColor;
  final String   tooltip;
  /// `null` désactive visuellement le bouton (icône grisée + tap inopérant).
  final VoidCallback? onTap;
  const _ActionBtn({required this.icon, required this.color,
    this.bgColor, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30, height: 30,
          decoration: BoxDecoration(
            color: disabled
                ? AppColors.divider
                : (bgColor ?? color.withValues(alpha:0.1)),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
                color: disabled
                    ? AppColors.divider
                    : color.withValues(alpha:0.25)),
          ),
          child: Icon(icon,
              size: 15,
              color: disabled ? AppColors.textHint : color),
        ),
      ),
    );
  }
}

// ─── Menu changement de statut ────────────────────────────────────────────────
class _StatusMenu extends StatelessWidget {
  final SaleStatus current;
  final void Function(SaleStatus) onSelect;
  /// Si false, les statuts `cancelled` et `refused` sont retirés du menu
  /// (l'utilisateur n'a pas la permission `salesCancel`).
  final bool canCancel;
  const _StatusMenu({
    required this.current,
    required this.onSelect,
    this.canCancel = false,
  });

  static const _allOptions = [
    SaleStatus.scheduled,
    SaleStatus.processing,
    SaleStatus.completed,
    SaleStatus.cancelled,
    SaleStatus.refused,
  ];

  List<SaleStatus> get _options => canCancel
      ? _allOptions
      : _allOptions
          .where((s) =>
              s != SaleStatus.cancelled && s != SaleStatus.refused)
          .toList();

  @override
  Widget build(BuildContext context) =>
      PopupMenuButton<SaleStatus>(
        onSelected: onSelect,
        color: Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
        elevation: 3,
        itemBuilder: (_) => _options
            .map((s) => PopupMenuItem(
          value: s,
          padding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 6),
          child: Row(children: [
            Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                    color: s.color,
                    shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text(s.label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: s == current
                        ? FontWeight.w700
                        : FontWeight.normal,
                    color: s == current
                        ? s.color
                        : const Color(0xFF374151))),
            if (s == current) ...[
              const Spacer(),
              Icon(Icons.check_rounded,
                  size: 14, color: s.color),
            ],
          ]),
        ))
            .toList(),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: current.color.withValues(alpha:0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: current.color.withValues(alpha:0.3)),
          ),
          child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                    width: 7, height: 7,
                    decoration: BoxDecoration(
                        color: current.color,
                        shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(current.label,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: current.color)),
                const SizedBox(width: 4),
                Icon(Icons.keyboard_arrow_down_rounded,
                    size: 14, color: current.color),
              ]),
        ),
      );
}

// ─── Détails complets d'une commande (paiement, livraison, finance) ─────────
class _OrderDetailsBlock extends StatelessWidget {
  final Sale order;
  const _OrderDetailsBlock({required this.order});

  String _paymentLabel(PaymentMethod m) => switch (m) {
    PaymentMethod.cash        => 'Espèces',
    PaymentMethod.mobileMoney => 'Mobile Money',
    PaymentMethod.card        => 'Carte bancaire',
    PaymentMethod.credit      => 'Crédit',
  };

  IconData _paymentIcon(PaymentMethod m) => switch (m) {
    PaymentMethod.cash        => Icons.payments_rounded,
    PaymentMethod.mobileMoney => Icons.phone_android_rounded,
    PaymentMethod.card        => Icons.credit_card_rounded,
    PaymentMethod.credit      => Icons.handshake_rounded,
  };

  IconData _deliveryIcon(DeliveryMode? m) => switch (m) {
    DeliveryMode.pickup   => Icons.store_rounded,
    DeliveryMode.inHouse  => Icons.delivery_dining_rounded,
    DeliveryMode.partner  => Icons.local_shipping_rounded,
    DeliveryMode.shipment => Icons.flight_takeoff_rounded,
    null                  => Icons.help_outline_rounded,
  };

  String _formatAt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year} · '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  String _money(double v) => CurrencyFormatter.format(v);

  @override
  Widget build(BuildContext context) {
    final hasShipment = order.deliveryMode == DeliveryMode.shipment;
    final isPickup    = order.deliveryMode == DeliveryMode.pickup;
    final feesTotal = order.fees.fold<double>(
        0, (s, f) => s + ((f['amount'] as num?)?.toDouble() ?? 0));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ─── Paiement ─────────────────────────────────────────────
        _DetailRow(
          icon: _paymentIcon(order.paymentMethod),
          label: 'Paiement',
          value: _paymentLabel(order.paymentMethod),
        ),

        // ─── Livraison ────────────────────────────────────────────
        const SizedBox(height: 6),
        _DetailRow(
          icon: _deliveryIcon(order.deliveryMode),
          label: 'Livraison',
          value: order.deliveryMode?.labelFr ?? 'Non renseigné',
        ),
        if (!isPickup) ...[
          if ((order.deliveryCity ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            _DetailRow(
              icon: Icons.location_city_rounded,
              label: 'Ville',
              value: order.deliveryCity!,
            ),
          ],
          if ((order.deliveryAddress ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            _DetailRow(
              icon: Icons.place_outlined,
              label: 'Adresse',
              value: order.deliveryAddress!,
            ),
          ],
          if ((order.deliveryPersonName ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            _DetailRow(
              icon: Icons.badge_outlined,
              label: order.deliveryMode == DeliveryMode.partner
                  ? 'Contact partenaire'
                  : 'Livreur',
              value: order.deliveryPersonName!,
            ),
          ],
          if (order.scheduledAt != null) ...[
            const SizedBox(height: 4),
            _DetailRow(
              icon: Icons.event_rounded,
              label: 'Date livraison',
              value: _formatAt(order.scheduledAt!),
            ),
          ],
        ],

        // ─── Expédition (si shipment) ─────────────────────────────
        if (hasShipment) ...[
          const SizedBox(height: 6),
          if ((order.shipmentCity ?? '').isNotEmpty)
            _DetailRow(
              icon: Icons.outbox_rounded,
              label: 'Ville d\'origine',
              value: order.shipmentCity!,
            ),
          if ((order.shipmentAgency ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            _DetailRow(
              icon: Icons.business_rounded,
              label: 'Agence',
              value: order.shipmentAgency!,
            ),
          ],
          if ((order.shipmentHandler ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            _DetailRow(
              icon: Icons.person_pin_circle_outlined,
              label: 'Responsable envoi',
              value: order.shipmentHandler!,
            ),
          ],
        ],

        // ─── Raisons (annulation / reprogrammation) ───────────────
        if ((order.cancellationReason ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          _ReasonBanner(
            icon: Icons.cancel_outlined,
            color: AppColors.error,
            label: 'Annulée par le client',
            text: order.cancellationReason!,
          ),
        ],
        if ((order.rescheduleReason ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          _ReasonBanner(
            icon: Icons.event_repeat_rounded,
            color: AppColors.warning,
            label: 'Commande reprogrammée',
            text: order.rescheduleReason!,
          ),
        ],

        // ─── Décomposition financière ─────────────────────────────
        const SizedBox(height: 8),
        const Divider(height: 1, color: AppColors.inputFill),
        const SizedBox(height: 6),
        _MoneyLine(label: 'Sous-total', value: _money(order.subtotal)),
        if (order.discountAmount > 0)
          _MoneyLine(
              label: 'Remise',
              value: '- ${_money(order.discountAmount)}',
              color: AppColors.warning),
        if (order.taxRate > 0)
          _MoneyLine(
              label: 'TVA (${order.taxRate.toStringAsFixed(
                  order.taxRate % 1 == 0 ? 0 : 1)}%)',
              value: _money(order.taxAmount)),
        if (feesTotal > 0)
          _MoneyLine(
              label: 'Frais (absorbés)',
              value: _money(feesTotal),
              color: AppColors.textHint),
        const SizedBox(height: 4),
        _MoneyLine(
            label: 'Total facturé',
            value: _money(order.total),
            bold: true),

        // ─── Détail des frais (si plusieurs lignes) ───────────────
        if (order.fees.length > 1) ...[
          const SizedBox(height: 6),
          for (final f in order.fees)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Row(children: [
                const Icon(Icons.subdirectory_arrow_right_rounded,
                    size: 10, color: AppColors.textHint),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(f['label']?.toString() ?? '',
                      style: const TextStyle(fontSize: 10,
                          color: AppColors.textHint)),
                ),
                Text(_money(((f['amount'] as num?)?.toDouble() ?? 0)),
                    style: const TextStyle(fontSize: 10,
                        color: AppColors.textHint)),
              ]),
            ),
        ],

        // ─── Référence + numéro client ────────────────────────────
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.tag_rounded, size: 10, color: AppColors.textHint),
          const SizedBox(width: 4),
          Expanded(
            child: Text(order.id ?? '',
                style: const TextStyle(fontSize: 10,
                    color: AppColors.textHint,
                    fontFamily: 'monospace'),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if ((order.clientPhone ?? '').isNotEmpty)
            // Tap → ouvre WhatsApp avec le numéro du client (digits only).
            // wa.me ignore les + et tirets, donc on nettoie. Si aucune
            // boutique WhatsApp n'est associée, l'OS retombe sur le
            // composeur natif. Pattern aligné sur les autres deep-links
            // de la fiche (cf. _waUri dans share_catalog_dialog).
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () {
                final digits = order.clientPhone!
                    .replaceAll(RegExp(r'[^0-9]'), '');
                if (digits.isEmpty) return;
                openExternal('https://wa.me/$digits');
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 2, vertical: 1),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.phone_rounded,
                      size: 10, color: AppColors.primary),
                  const SizedBox(width: 3),
                  Text(order.clientPhone!,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                          decoration: TextDecoration.underline,
                          decorationColor:
                              AppColors.primary.withValues(alpha: 0.5))),
                ]),
              ),
            ),
        ]),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DetailRow({
    required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 12, color: AppColors.textSecondary),
      const SizedBox(width: 6),
      SizedBox(
        width: 110,
        child: Text(label,
            style: const TextStyle(fontSize: 10,
                color: AppColors.textHint,
                fontWeight: FontWeight.w500)),
      ),
      Expanded(
        child: Text(value,
            style: const TextStyle(fontSize: 11,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600)),
      ),
    ],
  );
}

class _MoneyLine extends StatelessWidget {
  final String label, value;
  final Color? color;
  final bool bold;
  const _MoneyLine({
    required this.label, required this.value,
    this.color, this.bold = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label,
          style: TextStyle(
              fontSize: bold ? 12 : 10,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              color: color ?? (bold
                  ? AppColors.textPrimary
                  : AppColors.textSecondary))),
      Text(value,
          style: TextStyle(
              fontSize: bold ? 13 : 11,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              color: color ?? (bold
                  ? AppColors.primary
                  : AppColors.textPrimary))),
    ]),
  );
}

// ─── Bannière qui affiche une raison (annulation, reprogrammation) ─────────
class _ReasonBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String text;
  const _ReasonBanner({
    required this.icon,
    required this.color,
    required this.label,
    required this.text,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: color.withValues(alpha:0.06),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha:0.25)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 10,
                      fontWeight: FontWeight.w800, color: color)),
              const SizedBox(height: 2),
              Text(text,
                  style: const TextStyle(fontSize: 11,
                      color: AppColors.textPrimary,
                      fontStyle: FontStyle.italic)),
            ],
          ),
        ),
      ],
    ),
  );
}

// ─── Bottom sheet "raison" (annulation, reprogrammation) ────────────────────
// Refonte UX : remplace l'ancien AlertDialog par un FormSheet verrouillé
// (pas de tap-outside ni de swipe-down) avec bouton X intégré au header.
class _ReasonDialog extends StatefulWidget {
  final String title;
  final String hint;
  final String confirmLabel;
  final Color confirmColor;
  const _ReasonDialog({
    required this.title,
    required this.hint,
    required this.confirmLabel,
    required this.confirmColor,
  });

  /// Ouvre le sheet et retourne la raison saisie (trim non vide), ou null
  /// si l'utilisateur ferme via X / Annuler.
  static Future<String?> ask(
    BuildContext context, {
    required String title,
    required String hint,
    required String confirmLabel,
    required Color confirmColor,
  }) =>
      showAdaptiveFormSheet<String>(
        context: context,
        builder: (_) => _ReasonDialog(
          title: title,
          hint: hint,
          confirmLabel: confirmLabel,
          confirmColor: confirmColor,
        ),
      );

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _ctrl.text.trim().isNotEmpty;
    return AdaptiveFormFrame(
      title: widget.title,
      icon: Icons.edit_note_rounded,
      iconColor: widget.confirmColor,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                maxLines: 4,
                minLines: 3,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: const TextStyle(
                      fontSize: 12, color: AppColors.textHint),
                  isDense: true,
                  filled: true,
                  fillColor: const Color(0xFFF9FAFB),
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          BorderSide(color: AppColors.divider)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          BorderSide(color: AppColors.divider)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: widget.confirmColor, width: 1.5)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton(
                  onPressed: hasText
                      ? () => Navigator.of(context).pop(_ctrl.text.trim())
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: widget.confirmColor,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFFE5E7EB),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                  child: Text(widget.confirmLabel,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}