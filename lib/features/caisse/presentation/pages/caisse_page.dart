import 'package:fortress/shared/widgets/app_snack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../bloc/caisse_bloc.dart';
import '../widgets/product_grid_widget.dart';
import '../widgets/cart_widget.dart';
import '../widgets/delivery_details_sheet.dart';
import '../../domain/usecases/order_receipt_usecase.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../domain/entities/sale.dart';
import '../../data/repositories/sale_local_datasource.dart';
import '../../../../core/services/document_service.dart';
import '../../../../core/services/whatsapp_service.dart';
import '../../../../core/services/invoice_storage_service.dart';
import '../../../../core/services/url_shortener_service.dart';
import '../../../../core/services/whatsapp/message_templates.dart';
import '../../../../core/services/danger_action_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/utils/phone_formatter.dart';
import '../../../parametres/data/shop_settings_store.dart';
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
  }

  bool get _isEcommerce {
    final shop = ref.read(currentShopProvider);
    return shop?.sector == 'ecommerce';
  }

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;

    return BlocListener<CaisseBloc, CaisseState>(
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
    if (isWide) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Container(
              color: theme.scaffoldBackgroundColor,
              child: PosProductPanel(shopId: shopId)),
        ),
        Container(width: 1, color: theme.semantic.borderSubtle),
        SizedBox(
          width: 280,
          child: CartWidget(shopId: shopId, isEcommerce: isEcommerce),
        ),
      ]);
    }
    return Container(
      color: theme.scaffoldBackgroundColor,
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
  }

  @override
  void dispose() {
    _filter.dispose();
    _searchCtrl.dispose();
    super.dispose();
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
                      ? AppColors.primary.withOpacity(0.10)
                      : AppColors.inputFill,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: _dateRange != null
                          ? AppColors.primary.withOpacity(0.4)
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
        child: _orders.isEmpty
            ? EmptyStateWidget(
                icon: Icons.inbox_outlined,
                title: _filter.index == 0
                    ? 'Aucune commande'
                    : 'Aucune commande ${_filters[_filter.index].$2.toLowerCase()}',
                subtitle: 'Les commandes que tu encaisses apparaîtront ici.',
              )
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
              final wasCompleted = order.status == SaleStatus.completed;
              final becomingCompleted =
                  status == SaleStatus.completed && !wasCompleted;

              // Quand la commande passe à "completed" → ouvrir le sheet de
              // détails livraison/expédition pour que l'opérateur capture
              // tout en une fois (mode, ville, adresse, agence d'expédition,
              // responsable, date). Le stock sera déduit de la bonne source
              // par updateOrderStatus (logique centralisée dans le datasource).
              if (becomingCompleted) {
                final res = await showDeliveryDetailsSheet(
                  context,
                  shopId:                 order.shopId,
                  initialPaymentMethod:   order.paymentMethod,
                  initialMode:            order.deliveryMode,
                  initialLocationId:      order.deliveryLocationId,
                  initialPersonName:      order.deliveryPersonName,
                  initialDeliveryCity:    order.deliveryCity,
                  initialDeliveryAddress: order.deliveryAddress,
                  initialShipmentCity:    order.shipmentCity,
                  initialShipmentAgency:  order.shipmentAgency,
                  initialShipmentHandler: order.shipmentHandler,
                  initialDate:            order.scheduledAt,
                );
                if (res == null) return; // annulé → ne rien changer
                await _ds.updateOrderDelivery(
                  order.id!,
                  paymentMethod:   res.paymentMethod,
                  mode:            res.mode,
                  locationId:      res.locationId,
                  personName:      res.personName,
                  deliveryCity:    res.deliveryCity,
                  deliveryAddress: res.deliveryAddress,
                  shipmentCity:    res.shipmentCity,
                  shipmentAgency:  res.shipmentAgency,
                  shipmentHandler: res.shipmentHandler,
                  scheduledAt:     res.date,
                );
              }

              await _ds.updateOrderStatus(order.id!, status);
              setState(() {});
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
    ]);
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
                  ? color.withOpacity(0.35)
                  : AppColors.divider),
          boxShadow: [BoxShadow(
              color: Colors.black.withOpacity(0.03),
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
                        color: color.withOpacity(0.12),
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
                '${widget.order.total.toStringAsFixed(0)} XAF',
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
                                color: AppColors.secondary.withOpacity(0.6)),
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
                                color: AppColors.error.withOpacity(0.6)),
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
                              color: AppColors.warning.withOpacity(0.6)),
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

  Future<void> _remindClient(BuildContext context) async {
    if ((widget.order.clientPhone ?? '').trim().isEmpty) {
      AppSnack.error(context,
          'Numéro WhatsApp du client manquant — '
          'ajoute-le dans la fiche client puis réessaie.');
      return;
    }
    setState(() => _sendingInvoice = true);
    try {
      final ok = await OrderReceiptUseCase.sendWhatsAppReminderWithPdf(
        widget.order,
        whatsapp: ref.read(whatsappServiceProvider),
      );
      if (!ok && context.mounted) {
        AppSnack.error(context,
            'Impossible d\'envoyer le rappel — vérifie ta connexion '
            'puis réessaie.');
      }
    } catch (e) {
      if (context.mounted) {
        AppSnack.error(context, 'Erreur lors de l\'envoi du rappel : $e');
      }
    } finally {
      if (mounted) setState(() => _sendingInvoice = false);
    }
  }

  /// Envoie la facture PDF d'une commande complétée par WhatsApp :
  /// 1. Génère le PDF (réutilise OrderReceiptUseCase.generatePdf)
  /// 2. Upload sur Supabase Storage bucket `factures` → signed URL 30 jours
  /// 3. Ouvre wa.me avec un message pré-rempli + lien
  Future<void> _sendInvoiceWhatsApp(BuildContext context) async {
    final order = widget.order;
    final phone = order.clientPhone ?? '';
    if (phone.trim().isEmpty) {
      AppSnack.error(context,
          'Numéro WhatsApp du client manquant — '
          'ajoute-le dans la fiche client puis réessaie.');
      return;
    }
    setState(() => _sendingInvoice = true);
    try {
      final shop  = LocalStorageService.getShop(order.shopId);
      final bytes = await OrderReceiptUseCase.generatePdf(order, shop: shop);
      final orderId = order.id
          ?? 'order_${order.createdAt.millisecondsSinceEpoch}';
      final longUrl = await InvoiceStorageService.uploadInvoice(
        shopId: order.shopId,
        orderId: orderId,
        bytes: bytes,
      );
      if (longUrl == null) {
        if (mounted) {
          AppSnack.error(context,
              'Upload de la facture échoué. Vérifie ta connexion '
              'puis réessaie.');
        }
        return;
      }
      // Raccourcit la signed URL (fallback silencieux à l'URL longue).
      final shortUrl = await UrlShortenerService.shorten(longUrl);
      // Style de message lu depuis les paramètres boutique.
      final styleKey = ShopSettingsStore(order.shopId)
          .read<String>('whatsapp_message_style', fallback: 'standard');
      final style = WhatsappMessageStyleX.fromKey(styleKey);
      // Construction du message via les templates centralisés.
      final msg = MessageTemplates.buildMessage(
        order:    order,
        shop:     shop,
        shortUrl: shortUrl,
        style:    style,
      );
      // Numéro normalisé pour wa.me.
      final wamePhone = PhoneFormatter.toWame(phone);
      final ok = await ref.read(whatsappServiceProvider)
          .sendMessage(wamePhone, msg);
      if (!ok && mounted) {
        AppSnack.error(context,
            'Impossible d\'ouvrir WhatsApp. La facture est uploadée — '
            'tu peux copier-coller manuellement le lien.');
      }
    } catch (e) {
      if (mounted) {
        AppSnack.error(context, 'Erreur envoi facture : $e');
      }
    } finally {
      if (mounted) setState(() => _sendingInvoice = false);
    }
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
                                ? AppColors.primary.withOpacity(0.5)
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
                      color: AppColors.primary.withOpacity(0.4)),
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
          BoxShadow(color: Colors.black.withOpacity(0.08),
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
                _line(previewW * 0.5, AppColors.primary.withOpacity(0.3)),
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
                        _line(18, AppColors.primary.withOpacity(0.2)),
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
                    _line(previewW * 0.25, AppColors.primary.withOpacity(0.4)),
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
                : (bgColor ?? color.withOpacity(0.1)),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
                color: disabled
                    ? AppColors.divider
                    : color.withOpacity(0.25)),
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
            color: current.color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: current.color.withOpacity(0.3)),
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

  String _money(double v) => '${v.toStringAsFixed(0)} XAF';

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
          if ((order.clientPhone ?? '').isNotEmpty) ...[
            const Icon(Icons.phone_rounded,
                size: 10, color: AppColors.textHint),
            const SizedBox(width: 3),
            Text(order.clientPhone!,
                style: const TextStyle(fontSize: 10,
                    color: AppColors.textHint)),
          ],
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
      color: color.withOpacity(0.06),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withOpacity(0.25)),
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

// ─── Dialog "raison" (annulation, reprogrammation) ──────────────────────────
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

  /// Ouvre le dialog et retourne la raison saisie (trim non vide), ou null
  /// si l'utilisateur annule.
  static Future<String?> ask(
    BuildContext context, {
    required String title,
    required String hint,
    required String confirmLabel,
    required Color confirmColor,
  }) =>
      showDialog<String>(
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
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(widget.title,
          style: const TextStyle(fontSize: 15,
              fontWeight: FontWeight.w800)),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLines: 3,
        minLines: 2,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: const TextStyle(fontSize: 12,
              color: AppColors.textHint),
          isDense: true,
          contentPadding: const EdgeInsets.all(12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.divider)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: widget.confirmColor, width: 1.5)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        ElevatedButton(
          onPressed: hasText
              ? () => Navigator.of(context).pop(_ctrl.text.trim())
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.confirmColor,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}