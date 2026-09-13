import 'package:fortress/shared/widgets/app_snack.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/stock_item_service.dart';
import '../../../restaurant/presentation/widgets/courier_sheet.dart';
import '../../../restaurant/presentation/widgets/packaging_sheet.dart';
import '../../../restaurant/presentation/widgets/restaurant_checkout.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../bloc/caisse_bloc.dart';
import '../../../dashboard/data/dashboard_providers.dart';
import '../widgets/product_grid_widget.dart';
import '../widgets/cart_widget.dart';
import '../widgets/order_processing_sheet.dart';
import '../widgets/order_completion_sheet.dart';
import '../widgets/order_fees_sheet.dart';
import '../widgets/record_acompte_dialog.dart';
import '../widgets/delete_sale_dialog.dart';
import '../../domain/usecases/delete_sale_usecase.dart';
import '../../../onboarding/presentation/widgets/first_sale_tooltip.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import '../../domain/usecases/order_receipt_usecase.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../shared/widgets/order_source_badge.dart';
import '../../../../shared/widgets/view_filter_chip_bar.dart';
import '../widgets/copy_delivery_message_sheet.dart';
import '../widgets/approval_closure_sheet.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/app_permissions.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/export_models.dart';
import '../../../../core/services/export_service.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../core/config/app_modes.dart';
import '../../../../core/config/restaurant_mode.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../shared/widgets/export_scope_selector.dart';
import '../../data/exports/orders_export_source.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../domain/entities/sale.dart';
import '../../data/repositories/sale_local_datasource.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/external_launcher.dart';
import '../../../../core/services/partner_ledger_service.dart';
import '../../../parametres/domain/entities/partner_debt_info.dart';
import '../../../parametres/domain/entities/partner_ledger_entry.dart';
import '../../../../core/services/document_service.dart';
import '../../../../core/services/invoice_service.dart';
import '../../../../core/services/invoice_storage_service.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/services/short_link_service.dart';
import '../../../../core/services/url_shortener_service.dart';
import '../../../../core/services/whatsapp/whatsapp_template_renderer.dart';
import '../../../parametres/domain/entities/whatsapp_template.dart';
import '../../../parametres/presentation/providers/whatsapp_template_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/services/manager_gate.dart';
import '../../../../core/utils/phone_formatter.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../crm/data/models/client_model.dart';
import '../../../restaurant/presentation/widgets/resto_surfaces.dart';

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
      if (ref.read(dashViewFilterProvider) == null) {
        ref.read(dashViewFilterProvider.notifier).state = '_base';
      }
      _applyDefaultCartLocation();
    });
  }

  /// Rattache le panier au lieu par défaut pour que le bouton « Enregistrer la
  /// commande » ne soit JAMAIS grisé faute de lieu :
  /// - vue Partenaire → lieu du partenaire sélectionné ;
  /// - vue Boutique   → lieu de la boutique ACTIVE (`widget.shopId`).
  /// Ré-appliqué au démarrage ET dès que le lieu redevient vide (après un
  /// ClearCart : vente passée, panier vidé, retour sur la page). Sans ça,
  /// `deliveryLocationId` restait null après coup → bouton grisé.
  void _applyDefaultCartLocation() {
    if (!mounted) return;
    final bloc = context.read<CaisseBloc>();
    if ((bloc.state.deliveryLocationId ?? '').isNotEmpty) return; // déjà rattaché
    final dashFilter = ref.read(dashViewFilterProvider);
    if (dashFilter != null && dashFilter != '_base') {
      bloc.add(SetDeliveryMode(
          mode: DeliveryMode.partner, locationId: dashFilter));
    } else {
      final shopLoc = AppDatabase.getShopLocation(widget.shopId);
      if (shopLoc != null) bloc.add(SetCartLocation(shopLoc.id));
    }
  }

  /// Détermine le secteur de façon DÉTERMINISTE depuis la boutique de CETTE
  /// page (`widget.shopId`), pas depuis la boutique « courante » du provider
  /// qui peut être null/différente au 1er build → bug critique : le panier
  /// affichait « Encaisser » (vente immédiate, décrément stock) au lieu de
  /// « Enregistrer la commande ». Fallback Hive par id si le provider n'a pas
  /// encore résolu. Le `ref.watch(currentShopProvider)` dans build() assure la
  /// reconstruction dès que la boutique se charge.
  bool get _isEcommerce {
    // Mode e-commerce unique (réversible : kEcommerceOnlyMode) → toujours
    // « Enregistrer la commande », jamais « Encaisser ».
    if (kEcommerceOnlyMode) return true;
    final cur  = ref.read(currentShopProvider);
    final shop = (cur != null && cur.id == widget.shopId)
        ? cur
        : LocalStorageService.getShop(widget.shopId);
    return shop?.sector == 'ecommerce';
  }

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;
    // Réactif : la page se reconstruit dès que la boutique courante se charge,
    // pour que `_isEcommerce` (et donc le bouton panier Encaisser/Enregistrer)
    // reflète le bon secteur même si le provider était null au 1er build.
    ref.watch(currentShopProvider);

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
            // Montant repris de `state`, l'instantané immuable reçu par
            // l'écouteur : le ClearCart ci-dessus ne le modifie pas.
            AppSnack.success(context,
                isEdit
                    ? 'Commande mise à jour · '
                      '${CurrencyFormatter.format(state.total)}'
                    : 'Commande enregistrée et programmée · '
                      '${CurrencyFormatter.format(state.total)}');
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
        // Le lieu vient de redevenir vide (ClearCart : vente passée, panier
        // vidé, retour sur la page) → re-rattacher au lieu par défaut pour que
        // le bouton « Enregistrer la commande » reste actif sans actualiser.
        BlocListener<CaisseBloc, CaisseState>(
          listenWhen: (prev, curr) =>
              (prev.deliveryLocationId ?? '').isNotEmpty &&
              (curr.deliveryLocationId ?? '').isEmpty,
          listener: (context, _) {
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => _applyDefaultCartLocation());
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
      backgroundColor: Theme.of(context).colorScheme.surface,
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
    // Bannière tooltip 1ʳᵉ vente (PR-3 onboarding) — self-gated : se rend
    // SizedBox.shrink() si déjà vue OU si une vente complétée existe déjà
    // pour cette boutique. Insérée en haut sans toucher au CaisseBloc.
    final tooltip = FirstSaleTooltipBanner(shopId: shopId);
    if (isWide) {
      return Column(children: [
        tooltip,
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
          ]),
        ),
      ]);
    }
    // Restauration : mise en page mobile inchangée.
    if (isRestaurantShop(shopId)) {
      return Column(children: [
        tooltip,
        Expanded(
          child: ColoredBox(
            color: bg,
            child: PosProductPanel(shopId: shopId),
          ),
        ),
      ]);
    }
    return Column(children: [
      tooltip,
      Expanded(child: _MobileCaisseTabs(
          shopId: shopId, isEcommerce: isEcommerce, background: bg)),
    ]);
  }
}

enum _CaisseTab { panier, produits }

/// Caisse mobile (e-commerce) : bascule Panier / Produits sans quitter l'écran.
/// `IndexedStack` garde les deux vivants : la recherche et le défilement de la
/// grille produits survivent à un aller-retour sur le panier.
class _MobileCaisseTabs extends StatefulWidget {
  final String shopId;
  final bool   isEcommerce;
  final Color  background;
  const _MobileCaisseTabs({required this.shopId,
    required this.isEcommerce, required this.background});

  @override
  State<_MobileCaisseTabs> createState() => _MobileCaisseTabsState();
}

class _MobileCaisseTabsState extends State<_MobileCaisseTabs> {
  // Produits par défaut : c'est là que la vente commence.
  _CaisseTab _tab = _CaisseTab.produits;

  @override
  Widget build(BuildContext context) => Column(children: [
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: BlocBuilder<CaisseBloc, CaisseState>(
        buildWhen: (p, c) => p.itemCount != c.itemCount,
        builder: (context, state) => Row(children: [
          _PillTab(label: 'Panier (${state.itemCount})',
              active: _tab == _CaisseTab.panier,
              onTap: () => setState(() => _tab = _CaisseTab.panier)),
          const SizedBox(width: 6),
          _PillTab(label: 'Produits',
              active: _tab == _CaisseTab.produits,
              onTap: () => setState(() => _tab = _CaisseTab.produits)),
        ]),
      ),
    ),
    Expanded(
      child: IndexedStack(index: _tab.index, children: [
        CartWidget(shopId: widget.shopId, isEcommerce: widget.isEcommerce),
        ColoredBox(color: widget.background,
            child: PosProductPanel(shopId: widget.shopId)),
      ]),
    ),
  ]);
}

/// Onglet en pilule. Sans état : l'onglet actif est décidé par le parent.
class _PillTab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _PillTab({required this.label, required this.active,
    required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      // Zone tactile : sans hauteur minimale la pilule ne ferait que ~25 px.
      constraints: const BoxConstraints(minHeight: 32),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: active
            ? AppColors.primary.withValues(alpha: 0.15)
            : AppColors.inputFill,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: active
            ? AppColors.primary.withValues(alpha: 0.4)
            : Theme.of(context).semantic.borderSubtle),
      ),
      child: Text(label,
          style: AppTextStyles.captionBold.copyWith(
              color: active ? AppColors.primary : AppColors.textSecondary)),
    ),
  );
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
  // Filtre « En retard / à planifier » actif (toggle via la pastille). Quand
  // vrai, la liste n'affiche QUE les commandes programmées en retard > 6h ou
  // sans heure de livraison — celles que le radar d'alertes ne couvre plus
  // (fenêtre overdue de 6h) ou pas du tout (scheduledAt absent).
  bool _lateFilter = false;
  // Filtre « Versement partenaire en attente » actif (toggle via la puce).
  // Quand vrai, la liste n'affiche QUE les commandes livrées par un
  // partenaire qui a encaissé pour le compte de la boutique et n'a pas
  // encore reversé (cf. PartnerLedgerService.pendingRemittanceByOrder).
  bool _remitFilter = false;

  /// Au-delà de cette ancienneté après l'heure prévue, une commande
  /// programmée sort du radar d'alertes sonores (cf. windowBackMs = 6h dans
  /// ScheduledOrderAlertService) → on la rapatrie dans la pastille persistante.
  static const _lateThreshold = Duration(hours: 6);

  /// La détection « versement partenaire en attente » ne s'applique QU'AUX
  /// commandes créées à partir de cette date (déploiement de la
  /// fonctionnalité, 2026-06-21). Les commandes historiques étaient soldées
  /// via les dettes partenaires GLOBALES — les inclure ferait apparaître de
  /// fausses dettes « à verser » sur des commandes déjà réglées (correctif).
  static final DateTime _remitTrackingSince = DateTime.utc(2026, 6, 21);

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
    // 'partner_ledger_entries' inclus : un INSERT/UPDATE/DELETE de dette
    // partenaire (Realtime OU mutation locale) doit recalculer la bannière
    // « Dette partenaire » sous les commandes (sinon elle reste statique).
    if ((table == 'orders' || table == 'partner_ledger_entries')
        && shopId == widget.shopId) {
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

  /// Index de l'onglet filtre correspondant à un statut. `null` si pas
  /// d'onglet dédié (cas `refunded`) — on laisse alors l'onglet courant.
  /// Doit rester synchronisé avec `_filters` (l'ordre est : Toutes,
  /// Programmée, En cours, Complétée, Annulée, Refusée).
  int? _tabIndexForStatus(SaleStatus s) => switch (s) {
    SaleStatus.scheduled  => 1,
    SaleStatus.processing => 2,
    SaleStatus.completed  => 3,
    SaleStatus.cancelled  => 4,
    SaleStatus.refused    => 5,
    SaleStatus.refunded   => null,
  };

  /// Ouvre le scope selector puis génère le CSV/PDF des commandes.
  /// La permission `canExportOrders` est déjà vérifiée par le bouton qui
  /// appelle cette méthode (le bouton n'est rendu que si l'utilisateur
  /// a la permission). On n'attend donc pas l'autorisation ici.
  Future<void> _openExport() async {
    if (!mounted) return;
    final shop = LocalStorageService.getShop(widget.shopId);
    final partners =
        OrdersExportSource.partnerLocationsForShop(widget.shopId);
    final config = await ExportScopeSelector.show(
      context,
      type:             ExportType.orders,
      shopId:           widget.shopId,
      shopName:         shop?.name,
      partnerLocations: partners,
    );
    if (!mounted || config == null) return;
    final rows = OrdersExportSource.collect(config.scope);
    if (rows.isEmpty) {
      AppSnack.info(context, 'Aucune commande dans ce périmètre');
      return;
    }
    if (config.format == ExportFormat.csv) {
      await ExportService.exportToCsv(
        context,
        config: config,
        header: OrdersExportSource.header,
        rows:   rows,
      );
    } else {
      await ExportService.exportToPdf(
        context,
        config: config,
        header: OrdersExportSource.header,
        rows:   rows,
      );
    }
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

  /// Socle commun à l'onglet courant ET au comptage par onglet
  /// (cf. `_countsByStatus`) : toutes les commandes du shop filtrées par
  /// créateur (employé restreint) + vue dashboard. N'applique NI le filtre
  /// de statut, NI la date, NI la recherche.
  List<Sale> get _baseList {
    var list = _ds.getOrders(widget.shopId);
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
    return list;
  }

  /// Applique au socle `base` le filtre de statut (`key`), la plage de
  /// dates puis la recherche. Le filtre date porte sur la date
  /// d'encaissement pour l'onglet « Complétée » (createdAt), sinon sur la
  /// date de livraison programmée (scheduledAt).
  List<Sale> _listForStatus(String key, List<Sale> base) {
    var list = key == 'all'
        ? base
        : base.where((o) => o.status.name == key).toList();
    final r = _dateRange;
    if (r != null) {
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

  /// Nombre de commandes par onglet — mêmes filtres vue/créateur/date/
  /// recherche que la liste courante — pour les pastilles du TabBar.
  Map<String, int> _countsByStatus(List<Sale> base) =>
      { for (final f in _filters) f.$1: _listForStatus(f.$1, base).length };

  /// Commandes programmées « En retard / à planifier » (cf. pastille) :
  ///   * en retard > 6h : `scheduled` dont `scheduledAt` est antérieur à
  ///     (maintenant − 6h) → hors de la fenêtre du radar d'alertes ;
  ///   * à planifier     : `scheduled` SANS `scheduledAt` → jamais surveillé.
  /// La recherche libre courante s'applique aussi (cohérent avec la liste).
  List<Sale> _lateUnplanned(List<Sale> base) {
    final cutoff = DateTime.now().subtract(_lateThreshold);
    var list = base.where((o) {
      if (o.status != SaleStatus.scheduled) return false;
      final s = o.scheduledAt;
      if (s == null) return true;          // à planifier
      return s.isBefore(cutoff);           // en retard > 6h
    }).toList();
    if (_query.isNotEmpty) {
      list = list.where((o) => _matches(o, _query)).toList();
    }
    // Plus en retard d'abord ; les « à planifier » (sans date) en tête.
    list.sort((a, b) {
      final sa = a.scheduledAt, sb = b.scheduledAt;
      if (sa == null && sb == null) return 0;
      if (sa == null) return -1;
      if (sb == null) return 1;
      return sa.compareTo(sb);
    });
    return list;
  }

  /// Commandes « Versement partenaire en attente » : le partenaire a encaissé
  /// pour le compte de la boutique et n'a pas encore reversé (clés de
  /// [pending]). La recherche libre courante s'applique aussi. Triées du plus
  /// récent au plus ancien.
  List<Sale> _pendingRemitList(List<Sale> base, Map<String, double> pending) {
    var list = base
        .where((o) => o.id != null && pending.containsKey(o.id))
        .toList();
    if (_query.isNotEmpty) {
      list = list.where((o) => _matches(o, _query)).toList();
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// Puce/bannière du filtre « Versement partenaire en attente ». Tap =
  /// bascule `_remitFilter` (affiche uniquement ces commandes). Même style
  /// que `_lateBanner` pour la cohérence visuelle.
  Widget _remitBanner(int count, double total) {
    final active = _remitFilter;
    const color = AppColors.info;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: InkWell(
        onTap: () => setState(() => _remitFilter = !_remitFilter),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: color.withValues(alpha: active ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: color.withValues(alpha: active ? 0.6 : 0.25)),
          ),
          child: Row(children: [
            Icon(active
                    ? Icons.filter_alt_rounded
                    : Icons.account_balance_wallet_rounded,
                size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Versement partenaire en attente : $count · '
                '${CurrencyFormatter.format(total)}',
                style: AppTextStyles.bodySmBold.copyWith(color: color),
              ),
            ),
            Text(active ? 'Tout voir' : 'Filtrer',
                style: AppTextStyles.captionBold.copyWith(color: color)),
            Icon(active ? Icons.close_rounded : Icons.chevron_right_rounded,
                size: 16, color: color),
          ]),
        ),
      ),
    );
  }

  /// (en retard, à planifier) — pour le libellé de la pastille.
  (int, int) _lateCounts(List<Sale> base) {
    final cutoff = DateTime.now().subtract(_lateThreshold);
    var late = 0, unplanned = 0;
    for (final o in base) {
      if (o.status != SaleStatus.scheduled) continue;
      final s = o.scheduledAt;
      if (s == null) {
        unplanned++;
      } else if (s.isBefore(cutoff)) {
        late++;
      }
    }
    return (late, unplanned);
  }

  /// Pastille persistante d'attention sur les livraisons à traiter. Tap =
  /// bascule le filtre `_lateFilter` (affiche uniquement ces commandes).
  Widget _lateBanner(int late, int unplanned) {
    final parts = <String>[
      if (late > 0) '$late en retard',
      if (unplanned > 0) '$unplanned à planifier',
    ];
    final active = _lateFilter;
    final color = late > 0 ? AppColors.error : AppColors.warning;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: InkWell(
        onTap: () => setState(() => _lateFilter = !_lateFilter),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: color.withValues(alpha: active ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: color.withValues(alpha: active ? 0.6 : 0.25)),
          ),
          child: Row(children: [
            Icon(active ? Icons.filter_alt_rounded : Icons.notifications_active_rounded,
                size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Livraisons à traiter : ${parts.join(' · ')}',
                style: AppTextStyles.bodySmBold.copyWith(color: color),
              ),
            ),
            Text(active ? 'Tout voir' : 'Filtrer',
                style: AppTextStyles.captionBold.copyWith(color: color)),
            Icon(active ? Icons.close_rounded : Icons.chevron_right_rounded,
                size: 16, color: color),
          ]),
        ),
      ),
    );
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

  /// Onglet du TabBar : libellé + pastille compteur. La pastille n'apparaît
  /// que si l'onglet contient au moins une commande.
  Widget _tabLabel(String text, int count, bool selected) {
    final color = selected ? AppColors.primary : AppColors.textHint;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(text),
      if (count > 0) ...[
        const SizedBox(width: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: selected ? 0.14 : 0.10),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text('$count',
              style: AppTextStyles.microBold.copyWith(color: color)),
        ),
      ],
    ]);
  }

  /// Bandeau de synthèse de la sélection courante : total facturé et reste
  /// à encaisser. Masqué quand la liste est vide (rien à résumer).
  Widget _summaryBar(double totalCA, double totalDue) {
    final sem = Theme.of(context).semantic;
    Widget cell(IconData icon, String label, String value, Color color) =>
        Expanded(
          child: Row(children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 7),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: AppTextStyles.micro
                        .copyWith(color: AppColors.textSecondary)),
                Text(value,
                    style: AppTextStyles.bodySmBold
                        .copyWith(color: color, fontWeight: FontWeight.w800)),
              ],
            ),
          ]),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.12)),
      ),
      child: Row(children: [
        cell(Icons.account_balance_wallet_outlined, 'Total facturé',
            CurrencyFormatter.format(totalCA), AppColors.primary),
        Container(width: 1, height: 28, color: sem.borderSubtle),
        const SizedBox(width: 12),
        cell(Icons.payments_outlined, 'Reste à encaisser',
            CurrencyFormatter.format(totalDue),
            totalDue > 0 ? AppColors.warning : sem.success),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Dette partenaire pour TOUTES les commandes visibles, en une seule
    // passe Hive (offline-first) au build de la liste — pas un calcul par
    // card. Recalculé quand le ledger change (cf. _onDataChanged écoute
    // 'partner_ledger_entries').
    // Socle filtré une fois pour la liste, le bandeau de synthèse et les
    // compteurs d'onglets.
    final base    = _baseList;
    final counts  = _countsByStatus(base);
    // Pastille « En retard / à planifier » : commandes programmées hors radar.
    final (lateCount, unplannedCount) = _lateCounts(base);
    final hasLate  = lateCount > 0 || unplannedCount > 0;
    final showLate = _lateFilter && hasLate;
    // Versement partenaire en attente, par commande (une passe ledger Hive).
    // Garde-fou « nouvelles commandes » basé sur la date de l'ÉCRITURE
    // (cf. `since`) : les commandes historiques (écritures anciennes) restent
    // exclues, MAIS une ancienne commande repassée en programmée puis
    // re-finalisée (écriture fraîche) participe bien à la logique « à verser ».
    final pendingRemit = PartnerLedgerService.pendingRemittanceByOrder(
        widget.shopId,
        base.map((o) => o.id).whereType<String>(),
        since: _remitTrackingSince);
    final remitCount = pendingRemit.length;
    final remitTotal = pendingRemit.values.fold<double>(0, (s, v) => s + v);
    final hasRemit   = remitCount > 0;
    final showRemit  = _remitFilter && hasRemit;
    final orders   = showRemit
        ? _pendingRemitList(base, pendingRemit)
        : showLate
            ? _lateUnplanned(base)
            : _listForStatus(_filters[_filter.index].$1, base);
    final orderDebts = PartnerLedgerService.debtByOrder(
        widget.shopId, orders.map((o) => o.id).whereType<String>());
    // Synthèse de la sélection courante : total facturé + reste à encaisser.
    final totalCA  = orders.fold<double>(0, (s, o) => s + o.total);
    final totalDue = orders.fold<double>(0, (s, o) => s + o.amountDue);
    return Column(children: [
      // ── Onglets « Vue » : Globale / Boutique / Partenaires ──────────
      // Le filtre s'applique aux lignes via `orderToPartnerLocId` plus haut
      // dans `_orders` (cf. ref.watch(dashViewFilterProvider)).
      ViewFilterChipBar(shopId: widget.shopId, useTabs: true),

      // ── Filtres ─────────────────────────────────────────────
      Container(
        // Opacité des cartes en restauration : ces bandeaux de filtres
        // étaient les derniers aplats pleins de la page.
        color: restoDecorActive
            ? restoGlassFill(context)
            : Theme.of(context).colorScheme.surface,
        child: TabBar(
          controller: _filter,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor:           AppColors.primary,
          unselectedLabelColor: AppColors.textHint,
          indicatorColor:       AppColors.primary,
          indicatorWeight:      2,
          labelStyle: AppTextStyles.bodySmBold,
          tabs: [
            for (var i = 0; i < _filters.length; i++)
              Tab(child: _tabLabel(_filters[i].$2,
                  counts[_filters[i].$1] ?? 0, _filter.index == i)),
          ],
        ),
      ),
      Divider(height: 1, color: Theme.of(context).semantic.borderSubtle),

      // ── Pastille « Livraisons à traiter » (en retard > 6h / à planifier) ──
      if (hasLate) _lateBanner(lateCount, unplannedCount),

      // ── Puce « Versement partenaire en attente » (filtre séparé) ──────────
      if (hasRemit) _remitBanner(remitCount, remitTotal),

      // ── Recherche + filtres sur UNE ligne (densité) ──────────
      // Recherche extensible + filtre date + export en icônes compactes
      // (au lieu de 2 lignes). La plage de dates active affiche son libellé.
      Container(
        color: restoDecorActive
            ? restoGlassFill(context)
            : Theme.of(context).colorScheme.surface,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(children: [
          // Barre de recherche (prend tout l'espace restant)
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _searchCtrl,
                style: AppTextStyles.bodySm,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Rechercher (client, téléphone, ville…)',
                  hintStyle: AppTextStyles.bodySm
                      .copyWith(color: AppColors.textHint),
                  prefixIcon: Icon(Icons.search_rounded,
                      size: 16, color: AppColors.textHint),
                  suffixIcon: _query.isEmpty ? null : IconButton(
                    icon: Icon(Icons.close_rounded,
                        size: 14, color: AppColors.textHint),
                    splashRadius: 16,
                    onPressed: () => _searchCtrl.clear(),
                  ),
                  contentPadding: EdgeInsets.zero,
                  filled: true, fillColor: AppColors.inputFill,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                          color: Theme.of(context).semantic.borderSubtle)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppColors.primary)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Filtre date — icône seule (inactif) ou puce avec plage (actif).
          Tooltip(
            message: _dateRange == null
                ? 'Filtrer par date' : _formatRange(_dateRange!),
            child: InkWell(
              onTap: _pickDateRange,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                height: 38,
                padding: EdgeInsets.symmetric(
                    horizontal: _dateRange != null ? 10 : 9),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _dateRange != null
                      ? AppColors.primary.withValues(alpha: 0.10)
                      : AppColors.inputFill,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: _dateRange != null
                          ? AppColors.primary.withValues(alpha: 0.4)
                          : Theme.of(context).semantic.borderSubtle),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.event_rounded, size: 16,
                      color: _dateRange != null
                          ? AppColors.primary : AppColors.textSecondary),
                  if (_dateRange != null) ...[
                    const SizedBox(width: 5),
                    Text(_formatRange(_dateRange!),
                        style: AppTextStyles.captionBold
                            .copyWith(color: AppColors.primary)),
                    const SizedBox(width: 3),
                    InkWell(
                      onTap: () => setState(() => _dateRange = null),
                      child: Icon(Icons.close_rounded,
                          size: 14, color: AppColors.textHint),
                    ),
                  ],
                ]),
              ),
            ),
          ),
          // Export — icône seule.
          if (ref.watch(permissionsProvider(widget.shopId))
              .canExportOrders) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'Exporter',
              child: InkWell(
                onTap: _openExport,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  height: 38, width: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.4)),
                  ),
                  child: Icon(Icons.download_rounded,
                      size: 16, color: AppColors.primary),
                ),
              ),
            ),
          ],
        ]),
      ),
      Divider(height: 1, color: Theme.of(context).semantic.borderSubtle),

      // ── Synthèse de la sélection (total facturé + reste à encaisser) ──
      if (orders.isNotEmpty) ...[
        const SizedBox(height: 8),
        _summaryBar(totalCA, totalDue),
      ],

      // ── Liste commandes ──────────────────────────────────────
      Expanded(
        child: RefreshIndicator(
          onRefresh: _pullAndReload,
          child: orders.isEmpty
            ? ListView(children: [EmptyStateWidget(
                icon: Icons.inbox_outlined,
                title: _filter.index == 0
                    ? 'Aucune commande'
                    : 'Aucune commande ${_filters[_filter.index].$2.toLowerCase()}',
                subtitle: 'Les commandes que tu encaisses apparaîtront ici.',
              )])
            : ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: orders.length,
          separatorBuilder: (_, __) =>
          const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final perms = ref.watch(permissionsProvider(widget.shopId));
            return _OrderCard(
            order:    orders[i],
            debt:     orderDebts[orders[i].id],
            // Versement partenaire encore attendu pour cette commande (null
            // = rien à recevoir). Affiche un bandeau + un bouton de marquage.
            pendingRemittance: pendingRemit[orders[i].id],
            canCancel: perms.canCancelSale,
            // Suppression : permission + statut éligible. La règle de statut
            // (scheduled/processing/refused/cancelled, non encaissée) est
            // centralisée dans DeleteSaleUseCase.allowedStatuses et appliquée
            // sur le bouton lui-même (_OrderCard) — cohérent use case + RPC.
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
              final order = orders[i];
              final wasScheduled  = order.status == SaleStatus.scheduled;
              final wasProcessing = order.status == SaleStatus.processing;
              final becomingProcessing = status == SaleStatus.processing
                  && wasScheduled;
              final becomingCompleted = status == SaleStatus.completed
                  && order.status != SaleStatus.completed;

              // ── RESTAURATION : encaissement DIRECT ────────────────────
              //
              // Une seule question — le mode de règlement — puis la commande
              // passe à « payée ». On court-circuite ici tout le parcours
              // e-commerce qui suit (feuille « Qui a encaissé ? », frais de
              // complétion, écritures partenaire, mode de livraison) : ces
              // étapes existent parce qu'une commande e-commerce VOYAGE, avec
              // un livreur et parfois un dépôt partenaire. Au restaurant, le
              // client est devant le comptoir.
              //
              // `settleRestaurantOrder` clôture lui-même la commande, libère
              // la table s'il y a lieu et enregistre les règlements — d'où le
              // `return` : repasser dans `updateOrderStatus` plus bas
              // rejouerait la transition sur une vente déjà complétée.
              if (becomingCompleted && isRestaurantShop(order.shopId)) {
                final paid = await settleRestaurantOrder(
                    context: context, order: order);
                if (!paid) return;                   // renoncé ou échec
                AppDatabase.notifyProductChange(order.shopId);
                ActivityLogService.log(
                  action:      'order_delivered',
                  targetType:  'order',
                  targetId:    order.id,
                  targetLabel: order.clientName ?? 'Commande',
                  shopId:      order.shopId,
                  details: {
                    'from':  order.status.name,
                    'to':    status.name,
                    'total': order.total,
                    'context': 'encaissement restaurant',
                  },
                );
                if (!mounted) return;
                final idx = _tabIndexForStatus(status);
                if (_filter.index != 0 && idx != null && _filter.index != idx) {
                  _filter.animateTo(idx);
                }
                setState(() {});
                return;
              }

              // Repasser Complétée → Programmée (correction d'erreur /
              // re-finalisation). Action sensible (réservée admin) : confirme,
              // PURGE les écritures partenaire de la commande, puis laisse le
              // datasource restituer le stock + remettre le paiement à zéro.
              final revertingToScheduled = status == SaleStatus.scheduled
                  && order.status == SaleStatus.completed;
              if (revertingToScheduled) {
                if (!perms.canCancelSale) {
                  AppSnack.error(context,
                      'Action réservée : repasser une commande complétée en '
                      'programmée requiert la permission "sales.cancel".');
                  return;
                }
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (dc) => AlertDialog(
                    backgroundColor: Theme.of(context).colorScheme.surface,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    title: const Text('Repasser en programmée ?',
                        style: AppTextStyles.subtitleBold),
                    content: Text(
                        'La commande redeviendra « programmée » : le stock '
                        'sera restitué, le paiement remis à zéro et les '
                        'écritures partenaire liées (encaissement, frais) '
                        'seront annulées. À utiliser pour corriger une erreur '
                        'puis re-finaliser.',
                        style: AppTextStyles.bodySecondary),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dc).pop(false),
                        child: Text('Annuler',
                            style: TextStyle(color: AppColors.textSecondary)),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.warning,
                            foregroundColor: Colors.white,
                            elevation: 0),
                        onPressed: () => Navigator.of(dc).pop(true),
                        child: const Text('Repasser en programmée'),
                      ),
                    ],
                  ),
                );
                if (ok != true) return;
                // Purge les mouvements partenaires de la commande (saleCollected
                // /deliveryOwed/remittance/charge liés) — la commande repart
                // d'un état neutre pour être re-finalisée proprement.
                await PartnerLedgerService.removeForOrder(
                    order.shopId, order.id!);
              }

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
              // VENTE À CRÉDIT — total réellement encaissé du client à la
              // clôture (null = clôture « entièrement payé », historique).
              double? amountPaidOnComplete;
              // ARG-2 — qui a physiquement encaissé. Déclaré ici, hors du
              // bloc de clôture, pour rester lisible à l'appel de
              // `updateOrderStatus` plus bas (même motif que ci-dessus).
              bool collectedByPartner = false;
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
                // Aucun dépôt partenaire → l'encaissement est forcément fait
                // par la boutique : on NE demande PAS « Qui a encaissé ? ».
                final hasPartners = OrdersExportSource
                    .partnerLocationsForShop(freshForSheet.shopId).isNotEmpty;
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
                  // Option « Partenaire a encaissé » (+ bandeau bleu « à
                  // verser ») UNIQUEMENT si la commande est livrée par un
                  // partenaire. Livraison équipe boutique / retrait sur place
                  // → encaissement forcément boutique.
                  allowPartnerCollected: isPartnerNow && hasPartners,
                  // Récap encaissement + vente à crédit (boutique encaisseuse).
                  orderTotal:       freshForSheet.total,
                  amountPaidBefore: freshForSheet.amountPaid,
                );
                if (fres == null) return; // annulé
                amountPaidOnComplete = fres.amountPaidTotal;
                final fresh = _ds.getOrderById(order.id!) ?? order;
                final updated = fresh.copyWith(fees: fres.fees
                    .map((f) => {
                          'id': f.id,
                          'label': f.label,
                          'amount': f.amount,
                        })
                    .toList());
                await _ds.updateOrder(updated);
                // Traçabilité (règle métier) : frais saisis à la complétion.
                if (fres.fees.isNotEmpty) {
                  ActivityLogService.log(
                    action:      'order_fees_updated',
                    targetType:  'order',
                    targetId:    order.id,
                    targetLabel: order.clientName ?? 'Commande',
                    shopId:      order.shopId,
                    details: {
                      'context': 'completion',
                      'fees': fres.fees.map((f) =>
                          {'label': f.label, 'amount': f.amount}).toList(),
                      'total_fees':
                          fres.fees.fold<double>(0, (s, f) => s + f.amount),
                    },
                  );
                }
                // Génère les mouvements partenaires associés à la completion.
                await _generatePartnerLedgerEntries(
                    order: updated, fees: fres.fees,
                    collectedBy: fres.collectedBy);
                completedAt = fres.completedAt;
                collectedByPartner =
                    fres.collectedBy == CollectedBy.partnerNotRemitted;
              }

              // Livraison refusée par le client : le partenaire-livreur a
              // tout de même effectué la course → la boutique lui doit les
              // frais. On le propose à l'opérateur (transition vers refused
              // uniquement, livraison partenaire).
              if (status == SaleStatus.refused
                  && order.status != SaleStatus.refused
                  && order.deliveryMode == DeliveryMode.partner
                  && (order.deliveryLocationId ?? '').isNotEmpty) {
                await _chargeRefusedDeliveryFee(order);
              }

              await _ds.updateOrderStatus(order.id!, status,
                  completedAt: completedAt,
                  amountPaidOnComplete: amountPaidOnComplete,
                  collectedByPartner: collectedByPartner);
              // (La libération de table du restaurant vivait ici. Elle est
              // remontée dans `settleRestaurantOrder`, qui court-circuite tout
              // ce parcours : ce point n'est plus atteint en restauration.)
              // R6 — à la finalisation, le stock a déjà été décrémenté dans
              // updateOrderStatus (StockEngagement → StockService.sale). On
              // force en plus une notification produit pour que TOUT écran
              // affichant le stock (grille caisse, inventaire, catalogue) se
              // rafraîchisse immédiatement, sans rechargement.
              if (becomingCompleted) {
                AppDatabase.notifyProductChange(order.shopId);
              }
              // Audit du changement de statut (annulation/remboursement
              // tracés spécifiquement ; autres transitions = générique).
              ActivityLogService.log(
                action: switch (status) {
                  SaleStatus.cancelled => 'order_cancelled',
                  SaleStatus.refunded  => 'order_refunded',
                  SaleStatus.completed => 'order_delivered',
                  _                    => 'order_status_changed',
                },
                targetType:  'order',
                targetId:    order.id,
                targetLabel: order.clientName ?? 'Commande',
                shopId:      order.shopId,
                details: {
                  'from':  order.status.name,
                  'to':    status.name,
                  'total': order.total,
                },
              );
              if (!mounted) return;
              // Auto-switch vers l'onglet du nouveau statut si on est
              // sur un filtre dédié — sans ça la commande disparaissait
              // de l'onglet d'origine et l'opérateur croyait que la
              // transition avait été annulée (« ça revient à programmée »).
              // On laisse l'onglet « Toutes » tranquille : il liste déjà
              // tous les statuts. Pour `refunded`, pas d'onglet dédié →
              // on retombe sur « Toutes ».
              final newIdx = _tabIndexForStatus(status);
              if (_filter.index != 0
                  && newIdx != null
                  && _filter.index != newIdx) {
                _filter.animateTo(newIdx);
              }
              AppSnack.success(context,
                  'Commande passée à « ${status.label} »');
              setState(() {});
            },
            onCancelWithReason: (reason) async {
              // Garde défensive, comme sur `onUpdate` plus haut : annuler une
              // commande requiert salesCancel. Elle manquait ICI seulement,
              // et ce n'était pas une simple redondance d'UI.
              //
              // Les deux portes d'annulation de la carte sont MUTUELLEMENT
              // EXCLUSIVES via `_canConfirmClient()` : le bouton « Annuler ou
              // refuser » (gardé par `canCancel`) ne s'affiche QUE tant que la
              // commande n'est pas à échéance ; passée l'échéance, c'est la
              // paire « Validée / Annulée par client » qui prend sa place — et
              // celle-là n'était gardée par rien. La protection était donc
              // inversée par rapport au risque : présente avant l'échéance,
              // absente le jour où la commande est effectivement traitée.
              //
              // Placée sur le callback parent, cette garde ferme les TROIS
              // chemins d'un coup — ils convergent tous vers
              // `widget.onCancelWithReason`.
              if (!perms.canCancelSale) {
                AppSnack.error(context,
                    'Action réservée : annuler une commande requiert la '
                    'permission "sales.cancel".');
                return;
              }
              final o = orders[i];
              await _ds.cancelOrderWithReason(o.id!, reason);
              ActivityLogService.log(
                action: 'order_cancelled',
                targetType: 'order', targetId: o.id,
                targetLabel: o.clientName ?? 'Commande',
                shopId: o.shopId,
                details: {'reason': reason, 'total': o.total},
              );
              if (mounted) setState(() {});
            },
            onReschedule: (newDate, reason) async {
              final o = orders[i];
              await _ds.rescheduleOrder(o.id!, newDate, reason);
              ActivityLogService.log(
                action: 'order_rescheduled',
                targetType: 'order', targetId: o.id,
                targetLabel: o.clientName ?? 'Commande',
                shopId: o.shopId,
                details: {'reason': reason,
                          'new_date': newDate.toIso8601String()},
              );
              if (mounted) setState(() {});
            },
            onDelete: (reason) async {
              // hotfix_084 : soft-delete sécurisé via DeleteSaleUseCase.
              // Le use case valide statut + amountPaid + motif côté Hive,
              // marque Hive immédiatement, restaure le stock localement et
              // pousse la RPC `delete_sale` (online direct ou queue offline).
              // Les exceptions DeleteSaleException sont propagées au dialog
              // qui les affiche en place.
              await DeleteSaleUseCase()
                  .call(orderId: orders[i].id!, reason: reason);
              if (mounted) setState(() {});
            },
            // Rebuild parent → `_orders` relit Hive → card reçoit une Sale
            // fraîche (bandeau « Reste à payer » disparaît une fois soldé).
            onChanged: () { if (mounted) setState(() {}); },
            // Clôture d'une tournée « à choisir sur place » : réconcilie le
            // stock réservé (gardé = vendu, reste = remis en stock).
            onCloseApproval: (res) async {
              final o = orders[i];
              await _ds.closeApprovalOrder(o.id!, res.kept,
                  amountPaid: res.amountPaidTotal);
              // Suites de la finalisation, identiques à une complétion
              // classique (la clôture court-circuite `updateOrderStatus`
              // pour ne pas rejouer le stock, mais le VOLET FINANCIER doit
              // bien avoir lieu) : écritures du livre partenaire + frais de
              // livraison dus + rafraîchissement des stocks à l'écran.
              final fresh = _ds.getOrderById(o.id!);
              if (fresh != null && fresh.status == SaleStatus.completed) {
                await _generatePartnerLedgerEntries(
                  order: fresh,
                  fees: fresh.fees
                      .map((f) => OrderFee(
                            id:     f['id']?.toString() ?? '',
                            label:  f['label']?.toString() ?? '',
                            amount: (f['amount'] as num?)?.toDouble() ?? 0,
                          ))
                      .toList(),
                  collectedBy: res.collectedBy,
                );
                final dp = fresh.deliveryPrice ?? 0;
                if (fresh.deliveryMode == DeliveryMode.partner
                    && (fresh.deliveryLocationId ?? '').isNotEmpty
                    && dp > 0) {
                  await PartnerLedgerService.syncOrderDeliveryFee(
                    shopId:            fresh.shopId,
                    partnerLocationId: fresh.deliveryLocationId!,
                    orderId:           o.id!,
                    feesTotal:         dp,
                  );
                }
                AppDatabase.notifyProductChange(o.shopId);
              }
              ActivityLogService.log(
                action: 'approval_closed',
                targetType: 'order', targetId: o.id,
                targetLabel: o.clientName ?? 'Commande',
                shopId: o.shopId,
                details: {
                  'kept_total':
                      res.kept.values.fold<int>(0, (s, v) => s + v),
                  'amount_paid':  res.amountPaidTotal,
                  'collected_by': res.collectedBy.name,
                },
              );
              if (mounted) setState(() {});
            },
            // Annulation d'une tournée : restaure tout le stock réservé.
            onCancelApproval: () async {
              final o = orders[i];
              await _ds.cancelApprovalOrder(o.id!,
                  reason: 'annulation tournée');
              ActivityLogService.log(
                action: 'approval_cancelled',
                targetType: 'order', targetId: o.id,
                targetLabel: o.clientName ?? 'Commande',
                shopId: o.shopId,
                details: const {'reason': 'annulation tournée'},
              );
              if (mounted) setState(() {});
            },
            // Marquage manuel « versement partenaire reçu » : enregistre un
            // `remittance` dans le livre partenaire qui solde le montant
            // encore dû pour cette commande (source unique de vérité).
            onRemitReceived: () async {
              final o = orders[i];
              final amount = pendingRemit[o.id] ?? 0;
              final partnerId = o.deliveryLocationId;
              if (amount <= 0 || partnerId == null || partnerId.isEmpty) return;
              await PartnerLedgerService.markOrderRemittanceReceived(
                shopId:            o.shopId,
                partnerLocationId: partnerId,
                orderId:           o.id!,
                amount:            amount,
              );
              ActivityLogService.log(
                action: 'partner_remittance_received',
                targetType: 'order', targetId: o.id,
                targetLabel: o.clientName ?? 'Commande',
                shopId: o.shopId,
                details: {'amount': amount, 'partner_location_id': partnerId},
              );
              if (mounted) {
                AppSnack.success(context, 'Versement partenaire enregistré.');
                setState(() {});
              }
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
    // après une annulation), on efface les écritures AUTO-générées
    // (saleCollected/deliveryOwed) pour repartir sur un état sain — mais on
    // PRÉSERVE les versements reçus (`remittance`) et charges manuelles
    // (`partnerCharge`) : de l'argent réellement encaissé ne doit jamais être
    // détruit par une re-complétion (sinon le bandeau « versement en attente »
    // réapparaît à tort).
    await PartnerLedgerService.removeForOrder(order.shopId, order.id!,
        keepReceived: true);

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
    // partenaire NOUS DOIT cet argent jusqu'au versement). Conditionné à une
    // LIVRAISON PARTENAIRE : sans livraison partenaire (équipe boutique,
    // retrait sur place…), aucun encaissement partenaire possible → pas de
    // bandeau bleu « à verser ».
    if (effectiveCollectedBy == CollectedBy.partnerNotRemitted
        && isPartnerLoc
        && order.deliveryMode == DeliveryMode.partner) {
      final livreurAussi = order.deliveryMode == DeliveryMode.partner;
      final soldeEncaisseParPartenaire =
          (orderTotal - amountPaidBefore).clamp(0, double.infinity).toDouble();
      // saleCollected = montant BRUT encaissé par le partenaire (sans déduire
      // les frais). Les frais sont une écriture `deliveryOwed` SÉPARÉE — ainsi
      // éditer les frais de la commande recalcule en direct le montant « à
      // verser » (cf. PartnerLedgerService.syncOrderDeliveryFee), au lieu de
      // les figer dans saleCollected.
      if (soldeEncaisseParPartenaire > 0) {
        await PartnerLedgerService.addEntry(
          shopId:            order.shopId,
          partnerLocationId: partnerId,
          type:              PartnerLedgerEntryType.saleCollected,
          amount:            soldeEncaisseParPartenaire,
          orderId:           order.id,
          note: amountPaidBefore > 0
              ? 'Solde encaissé par le partenaire '
                '(acompte de ${amountPaidBefore.toStringAsFixed(0)} '
                'déjà versé à la boutique)'
              : 'Vente encaissée par le partenaire',
        );
      }
      // Frais de livraison retenus par le partenaire sur ce qu'il reverse.
      if (livreurAussi && feesTotal > 0) {
        await PartnerLedgerService.addEntry(
          shopId:            order.shopId,
          partnerLocationId: partnerId,
          type:              PartnerLedgerEntryType.deliveryOwed,
          amount:            -feesTotal,
          orderId:           order.id,
          note:              'Frais de livraison déduits du versement',
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

  /// Livraison refusée par le client alors que le partenaire-livreur s'est
  /// déplacé. Propose à l'opérateur d'enregistrer les frais de course dus
  /// au partenaire en `partnerCharge` / `failedDelivery` (négatif). Le
  /// montant est pré-rempli avec les frais déjà saisis sur la commande
  /// (souvent 0 si elle n'a jamais été complétée) puis ajustable.
  Future<void> _chargeRefusedDeliveryFee(Sale order) async {
    final partnerId = order.deliveryLocationId;
    if (partnerId == null || partnerId.isEmpty) return;
    StockLocation? loc;
    try {
      final raw = HiveBoxes.stockLocationsBox.get(partnerId);
      if (raw != null) {
        loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
      }
    } catch (_) {}
    if (loc?.type != StockLocationType.partner) return;

    final defaultFee = order.fees
        .fold<double>(0, (s, f) => s + ((f['amount'] as num?)?.toDouble() ?? 0));
    final ctrl = TextEditingController(
        text: defaultFee > 0 ? defaultFee.toStringAsFixed(0) : '');

    final amount = await showAdaptiveFormSheet<double>(
      context: context,
      builder: (ctx) => AdaptiveFormFrame(
        title: 'Livraison refusée',
        icon: Icons.local_shipping_outlined,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                      'Le client a refusé mais ${loc?.name ?? 'le partenaire'} '
                      's\'est déplacé. Frais de course à lui devoir ?',
                      style: AppTextStyles.body
                          .copyWith(color: AppColors.textHint)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    decoration: InputDecoration(
                      isDense: true,
                      suffixText: 'FCFA',
                      hintText: 'Montant',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(0.0),
                    child: const Text('Aucun frais'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      final v = double.tryParse(
                          ctrl.text.trim().replaceAll(',', '.'));
                      Navigator.of(ctx).pop(v ?? 0.0);
                    },
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary),
                    child: const Text('Enregistrer la charge'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (amount == null || amount <= 0) return;

    await PartnerLedgerService.addEntry(
      shopId:            order.shopId,
      partnerLocationId: partnerId,
      type:              PartnerLedgerEntryType.partnerCharge,
      category:          PartnerChargeCategory.failedDelivery,
      amount:            -amount,
      orderId:           order.id,
      note:              'Livraison refusée par le client',
    );
    if (mounted) {
      AppSnack.success(context,
          'Frais de course (${CurrencyFormatter.format(amount)}) '
          'enregistrés en dette partenaire.');
    }
  }
}

// ─── Carte commande (expandable) ─────────────────────────────────────────────
class _OrderCard extends ConsumerStatefulWidget {
  final Sale   order;
  /// Dette partenaire de cette commande, calculée groupée par le parent
  /// (une passe Hive). Null = aucune entrée ledger pour la commande.
  final PartnerDebtInfo? debt;
  /// Montant que le partenaire-livreur a encaissé pour le compte de la
  /// boutique et n'a pas encore reversé (cf.
  /// `PartnerLedgerService.pendingRemittanceByOrder`). Null/0 = rien en
  /// attente. Déclenche l'indication + le bouton « Versement reçu ».
  final double? pendingRemittance;
  final void Function(SaleStatus) onUpdate;
  /// Annule la commande avec une raison fournie par l'opérateur.
  final Future<void> Function(String reason) onCancelWithReason;
  /// Reprogramme une commande "en cours" vers une nouvelle date avec raison.
  final Future<void> Function(DateTime newDate, String reason) onReschedule;
  /// Callback de suppression sécurisée. Reçoit le motif validé par
  /// l'utilisateur (≥ 10 caractères) et doit appeler `DeleteSaleUseCase`.
  /// Peut lever une [DeleteSaleException] — le dialog l'affiche en place
  /// sans se fermer.
  final Future<void> Function(String reason) onDelete;
  /// Appelé après une mutation interne de la card qui ne passe pas par
  /// onUpdate/onDelete (ex: enregistrement d'un acompte/solde). Le parent
  /// fait alors un setState → le getter `_orders` relit Hive et la card
  /// est reconstruite avec une `Sale` fraîche (sinon le bandeau « Reste à
  /// payer » garde l'ancien solde et ne disparaît pas une fois soldé).
  final VoidCallback? onChanged;
  /// True si l'utilisateur peut annuler/rembourser une vente
  /// (permission salesCancel = admin/owner par défaut).
  final bool canCancel;
  /// True si l'utilisateur peut supprimer une commande
  /// (permission caisseEditOrders en mode delete).
  final bool canDelete;
  /// True si l'utilisateur peut éditer une commande déjà créée
  /// (permission caisseEditOrders).
  final bool canEdit;
  /// Clôture d'une tournée « à choisir sur place » : reçoit la map
  /// `{ productId: quantité gardée }` saisie dans le sheet de clôture et doit
  /// appeler `SaleLocalDatasource.closeApprovalOrder`.
  final Future<void> Function(ApprovalClosureResult result) onCloseApproval;
  /// Annulation d'une tournée « à choisir sur place » : restaure tout le
  /// stock réservé (`cancelApprovalOrder`).
  final Future<void> Function() onCancelApproval;
  /// Marque le versement partenaire reçu pour cette commande (cf.
  /// `PartnerLedgerService.markOrderRemittanceReceived`).
  final Future<void> Function()? onRemitReceived;
  const _OrderCard({required this.order,
    this.debt,
    this.pendingRemittance,
    required this.onUpdate,
    required this.onCancelWithReason,
    required this.onReschedule,
    required this.onDelete,
    this.onChanged,
    required this.canCancel,
    required this.canDelete,
    required this.canEdit,
    required this.onCloseApproval,
    required this.onCancelApproval,
    this.onRemitReceived});
  @override
  ConsumerState<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends ConsumerState<_OrderCard> {
  bool _expanded = false;
  bool _sendingInvoice = false;

  // Pré-génération de la facture : déclenchée à l'expand de la card pour
  // que l'envoi WhatsApp ait l'URL courte prête au moment du clic.
  // Évite le problème de user-gesture web (Chrome bloque les pop-ups si
  // on `await` entre le clic et `wa.me`). Tant que l'URL n'est pas prête,
  // `_sendInvoiceWhatsApp` retombe sur le flow legacy (msg court +
  // presse-papier).
  String? _invoiceShortUrl;
  bool    _preparingInvoice = false;

  @override
  void initState() {
    super.initState();
    // Fiabilise l'envoi de facture : (1) seed les templates WhatsApp si
    // absents (sinon getDefault renvoie null → ancien message générique),
    // (2) pré-génère la facture dès qu'une commande terminée avec un
    // client téléphone est affichée → au clic « Envoyer », on est en
    // Cas 1 (template + lien) et non sur le fallback sans lien.
    final o = widget.order;
    final hasPhone = (o.clientPhone ?? '').trim().isNotEmpty;
    if (o.status == SaleStatus.completed && hasPhone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(whatsappTemplateRepositoryProvider)
            .seedDefaultsIfMissing(o.shopId);
        _prepareInvoice();
      });
    }
  }


  @override
  Widget build(BuildContext context) {
    final s     = widget.order.status;
    final color = s.color;
    final client = widget.order.clientName;
    final sem   = Theme.of(context).semantic;

    return GestureDetector(
      onTap: () {
        setState(() => _expanded = !_expanded);
        if (_expanded) _prepareInvoice();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: _expanded
                  ? color.withValues(alpha:0.35)
                  : sem.borderSubtle),
          boxShadow: [BoxShadow(
              color: Colors.black.withValues(alpha:0.03),
              blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── Ligne résumé (toujours visible) — disposition « card client »
            //    avatar à gauche · nom + méta empilés · montant à droite.
            Row(children: [
              _ClientAvatar(name: client ?? 'Client de passage', size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                  Text(client ?? 'Client de passage',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.captionBold.copyWith(
                          color: Theme.of(context).colorScheme.onSurface)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6, runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Statut (+ marqueur "reprogrammée")
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                            color: color.withValues(alpha:0.12),
                            borderRadius: BorderRadius.circular(6)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(_statusLabel(s),
                              style: AppTextStyles.microBold
                                  .copyWith(color: color)),
                          if (s == SaleStatus.scheduled
                              && (widget.order.rescheduleReason ?? '').isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(Icons.event_repeat_rounded,
                                  size: 10, color: color),
                            ),
                        ]),
                      ),
                      // ÉTAT DE SERVICE (restauration) — « En cuisine »,
                      // « Prête », « Servie ». Le statut commercial seul
                      // (« Programmée ») ne dit rien de l'avancement du plat :
                      // deux commandes programmées peuvent être, l'une encore
                      // au piano, l'autre déjà sur la table.
                      ..._channelChip(),
                      ..._serviceStateChip(),
                      // Chip « À choisir sur place » — visible uniquement
                      // pour les ventes d'approbation (tournée à réconcilier).
                      if (widget.order.isApprovalSale)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.fact_check_outlined,
                                size: 10, color: AppColors.primary),
                            const SizedBox(width: 3),
                            Text('À choisir',
                                style: AppTextStyles.microBold
                                    .copyWith(color: AppColors.primary)),
                          ]),
                        ),
                      // Pastille statut paiement (hors annulée/refusée).
                      if (s != SaleStatus.cancelled
                          && s != SaleStatus.refused)
                        _PaymentStatusPill(status: widget.order.paymentStatus),
                      // Badge "Web"/"WhatsApp" si source != 'pos'.
                      if (widget.order.source != 'pos')
                        OrderSourceBadge(source: widget.order.source),
                      Text(_formatDate(widget.order.createdAt),
                          style: AppTextStyles.micro),
                      if (widget.order.scheduledAt != null)
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.event_rounded,
                              size: 11, color: AppColors.warning),
                          const SizedBox(width: 3),
                          Text('Livré ${_formatDate(widget.order.scheduledAt!)}',
                              style: AppTextStyles.micro.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.warning)),
                        ]),
                    ],
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              // Montant + chevron à droite.
              Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                Text(
                  CurrencyFormatter.format(widget.order.total),
                  style: AppTextStyles.bodyBold.copyWith(
                      fontWeight: FontWeight.w900,
                      color: AppColors.primary),
                ),
                const SizedBox(height: 2),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: Icon(Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: _expanded ? color : AppColors.textHint),
                ),
              ]),
            ]),

            // ── Bandeau dette enregistrée envers le partenaire ────
            // Synchronisé : `widget.debt` est calculé groupé par le parent
            // (une passe Hive) et recalculé sur tout changement ledger
            // (Realtime/local via _onDataChanged). Masqué dès que la dette
            // est compensée (encaissement/versement lié à la commande) ou
            // nulle — plus jamais statique.
            if (widget.debt != null && widget.debt!.isOutstanding) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: sem.dangerSurface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: sem.danger.withValues(alpha: 0.2),
                      width: 0.5),
                ),
                child: Row(children: [
                  Icon(Icons.attach_money_rounded,
                      size: 12, color: sem.danger),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        'Dette partenaire : '
                        '${CurrencyFormatter.format(widget.debt!.amount)} '
                        '— compensée au prochain versement',
                        style: AppTextStyles.captionBold
                            .copyWith(color: sem.dangerText),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ),
            ],

            // Bandeau « Encaisser / Reste à payer » RETIRÉ de la carte
            // repliée (densité) — l'action reste accessible via l'icône
            // « Enregistrer un acompte » dans le dépliage de la commande.

            // ── Bandeau « Versement partenaire en attente » ───────
            // Toujours visible (hors zone expansion) : la commande a été
            // livrée par un partenaire qui a encaissé pour le compte de la
            // boutique mais n'a pas encore reversé (dérivé du livre
            // partenaire). Tap → confirme et enregistre le versement reçu.
            if ((widget.pendingRemittance ?? 0) > 0) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: () => _confirmRemitReceived(context),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.info.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: AppColors.info.withValues(alpha: 0.3),
                        width: 0.5),
                  ),
                  child: Row(children: [
                    const Icon(Icons.account_balance_wallet_outlined,
                        size: 12, color: AppColors.info),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          'Versement partenaire en attente : '
                          '${CurrencyFormatter.format(widget.pendingRemittance!)}',
                          style: AppTextStyles.captionBold
                              .copyWith(color: AppColors.info),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 6),
                    Text('Marquer reçu →',
                        style: AppTextStyles.microBold.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppColors.info.withValues(alpha: 0.85))),
                  ]),
                ),
              ),
            ],

            // Bandeau « Frais de livraison à fixer » RETIRÉ de la carte
            // repliée (densité) — l'action est désormais dans la feuille
            // « Actions » (« Fixer les frais de livraison »).

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
                  Divider(height: 1, color: AppColors.inputFill),
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
                              style: AppTextStyles.microBold.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.primary)),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(i.productName,
                            style: AppTextStyles.captionHint
                                .copyWith(color: AppColors.textSecondary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                  )),

                  // Notes
                  if (widget.order.notes != null) ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(Icons.notes_rounded,
                          size: 11, color: AppColors.textHint),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(widget.order.notes!,
                            style: AppTextStyles.micro.copyWith(
                                fontStyle: FontStyle.italic)),
                      ),
                    ]),
                  ],

                  const SizedBox(height: 8),
                  Divider(height: 1, color: AppColors.inputFill),
                  const SizedBox(height: 8),

                  // ── Détails complets (paiement, livraison, expédition,
                  //    décomposition financière). Visible dans l'expand.
                  _OrderDetailsBlock(order: widget.order),
                  const SizedBox(height: 8),
                  Divider(height: 1, color: AppColors.inputFill),
                  const SizedBox(height: 8),

                  // ── Actions contextuelles regroupées (feuille « Actions ») ─
                  // Allège la carte : les actions secondaires (Copier message,
                  // Relancer, Transférer, Reprogrammer, Rupture…) passent dans
                  // une feuille au lieu d'occuper plusieurs lignes (densité).
                  //
                  // MASQUÉ EN RESTAURATION : tout ce qu'il regroupait y est
                  // soit sans objet — relancer un client assis à sa table,
                  // reprogrammer une commande qu'on prépare à l'instant —,
                  // soit devenu un bouton à part entière (emballer, livreur).
                  // Il ne restait qu'une porte vers une feuille vide ou
                  // trompeuse.
                  if (!_isResto && _contextualActions(context).isNotEmpty) ...[
                    _WideActionButton(
                      icon: Icons.more_horiz_rounded,
                      label: 'Actions',
                      color: AppColors.primary,
                      onPressed: () => _showActionsSheet(
                          context, _contextualActions(context)),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Actions client à échéance : Validée / Annulée — paire
                  // pleine largeur (Expanded), volontairement hors du Wrap.
                  if (_canConfirmClient()) ...[
                    Row(children: [
                      Expanded(
                        child: _WideActionButton(
                          icon: Icons.check_circle_outline_rounded,
                          label: 'Validée par client',
                          color: AppColors.secondary,
                          onPressed: () =>
                              widget.onUpdate(SaleStatus.processing),
                        ),
                      ),
                      // La moitié « Annulée » SEULEMENT est conditionnée :
                      // annuler requiert salesCancel, valider non. Une
                      // validation client n'est pas un geste d'annulation et
                      // reste ouverte à tout opérateur — gouverner les deux
                      // boutons par la même condition aurait empêché de
                      // confirmer une commande arrivée à échéance.
                      //
                      // Sans la permission, le bouton DISPARAÎT au lieu de
                      // faire saisir un motif pour refuser ensuite. La garde
                      // du callback parent reste la frontière qui compte ;
                      // celle-ci évite seulement de promettre un geste
                      // impossible.
                      if (widget.canCancel) ...[
                        const SizedBox(width: 6),
                        Expanded(
                          child: _WideActionButton(
                            icon: Icons.cancel_outlined,
                            label: 'Annulée par client',
                            color: AppColors.error,
                            onPressed: () => _askCancelReason(context),
                          ),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 8),
                  ],

                  // Avancement du SERVICE (restauration) — envoyé en cuisine,
                  // prêt, servi. Ces trois évènements n'avaient plus aucune
                  // porte depuis que l'écran de service a quitté le menu : une
                  // fois la cuisine terminée, le bon sortait de l'écran Cuisine
                  // et plus personne ne pouvait le déclarer prêt ni servi.
                  ..._buildServiceProgress(context, s),
                  // EMBALLAGE — bouton direct, au moment où il sert.
                  ..._buildPackagingAction(context, s),
                  // LIVREUR — commandes à livrer uniquement.
                  ..._buildCourierAction(context, s),

                  // Actions
                  Row(children: [
                    // Tournée « à choisir sur place » en cours : le stock est
                    // géré par close/cancelApprovalOrder, on n'expose donc PAS
                    // le menu de transition générique (qui re-décrémenterait /
                    // restaurerait le stock à tort). À la place : 2 actions
                    // dédiées (clôturer / annuler la tournée).
                    if (widget.order.isApprovalSale
                        && (s == SaleStatus.scheduled
                            || s == SaleStatus.processing)) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _closeApproval(context),
                          icon: const Icon(Icons.fact_check_outlined,
                              size: 16),
                          label: const Text('Clôturer la tournée'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.primary,
                            side: BorderSide(
                                color: AppColors.primary
                                    .withValues(alpha: 0.5)),
                            padding:
                                const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _ActionBtn(
                        icon: Icons.cancel_outlined,
                        color: AppColors.error,
                        bgColor: AppColors.error.withValues(alpha: 0.12),
                        tooltip: 'Annuler la tournée',
                        onTap: () => _cancelApproval(context),
                      ),
                      const SizedBox(width: 6),
                    ] else ...[
                      // Plus de menu déroulant de statut : un bouton
                      // d'évènement contextuel (avancer la commande) +
                      // une pastille lecture seule pour les états terminaux.
                      // Desktop : bouton dimensionné au CONTENU (pas étiré sur
                      // toute la largeur) + Spacer pour garder les icônes à
                      // droite. Mobile : pleine largeur (confort tactile).
                      if (MediaQuery.of(context).size.width > 800) ...[
                        _buildStatusAction(s),
                        const Spacer(),
                      ] else
                        Expanded(child: _buildStatusAction(s)),
                      // Annuler / Refuser (évènements négatifs) — commandes
                      // non finalisées, hors paire « Annulée par client »
                      // déjà affichée à échéance.
                      if (widget.canCancel
                          && (s == SaleStatus.scheduled
                              || s == SaleStatus.processing)
                          && !_canConfirmClient()) ...[
                        const SizedBox(width: 6),
                        _ActionBtn(
                          icon: Icons.do_not_disturb_on_outlined,
                          color: AppColors.error,
                          bgColor: AppColors.error.withValues(alpha: 0.12),
                          tooltip: 'Annuler ou refuser',
                          onTap: () => _askCancelOrRefuse(context),
                        ),
                      ],
                      const SizedBox(width: 6),
                    ],
                    if (widget.order.status == SaleStatus.completed) ...[
                      // Repasser en programmée (correction / re-finalisation) —
                      // réservé admin. Restitue stock + paiement + écritures
                      // partenaire via l'évènement onUpdate(scheduled).
                      if (widget.canCancel) ...[
                        _ActionBtn(
                          icon: Icons.undo_rounded,
                          color: AppColors.warning,
                          bgColor: AppColors.warning.withValues(alpha: 0.12),
                          tooltip: 'Repasser en programmée',
                          onTap: () => _reopenPaidSale(context),
                        ),
                        const SizedBox(width: 6),
                      ],
                      _ActionBtn(
                        icon: Icons.picture_as_pdf_rounded,
                        color: AppColors.primary,
                        tooltip: 'Facture (PDF avec logo)',
                        onTap: () => _previewBrandedInvoice(context),
                      ),
                      const SizedBox(width: 6),
                      _ActionBtn(
                        icon: (_sendingInvoice || _preparingInvoice)
                            ? Icons.hourglass_top_rounded
                            : Icons.send_rounded,
                        color: AppColors.whatsapp,
                        tooltip: _preparingInvoice
                            ? 'Préparation de la facture…'
                            : 'Envoyer la facture par WhatsApp',
                        onTap: (_sendingInvoice || _preparingInvoice)
                            ? null
                            : () => _sendInvoiceWhatsApp(context),
                      ),
                      const SizedBox(width: 6),
                      // NB : l'ancien bouton « $ » (dépense en dette
                      // partenaire) a été fusionné dans le sheet « Modifier
                      // les frais » (icône fourgonnette) — un seul point
                      // d'entrée pour tous les coûts d'une commande.
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
                        bgColor: AppColors.warning.withValues(alpha: 0.12),
                        tooltip: 'Enregistrer un acompte',
                        onTap: () => _recordAcompte(context),
                      ),
                      const SizedBox(width: 6),
                    ],
                    // Bouton "Relancer le client" — visible UNIQUEMENT pour
                    // les commandes en cours / programmées (pas après
                    // completed/cancelled/refused/refunded). Exclu pour les
                    // commandes web : elles ont déjà le bouton large dédié
                    // « Relancer le client » plus haut.
                    if ((widget.order.status == SaleStatus.scheduled ||
                            widget.order.status == SaleStatus.processing)
                        && widget.order.source != 'web') ...[
                      _ActionBtn(
                        icon: Icons.notifications_active_outlined,
                        color: AppColors.whatsapp,
                        tooltip: context.l10n.orderRelaunchBtn,
                        onTap: () => _relaunchClient(context),
                      ),
                      const SizedBox(width: 6),
                    ],
                    // Bouton "Modifier les frais" — disponible même après
                    // complétion (les frais de livraison sont souvent connus
                    // APRÈS la livraison). Aucun verrouillage des frais ;
                    // seuls les articles sont figés une fois la commande
                    // complétée (cf. _onSaveOrder). Masqué sur annulée/
                    // refusée/remboursée (frais sans objet).
                    // Masqué en restauration : ce sheet porte les frais de
                    // LIVRAISON et la dette partenaire, deux notions sans
                    // objet quand le client emporte lui-même sa commande.
                    if (!_isResto
                        && widget.canEdit
                        && widget.order.status != SaleStatus.cancelled
                        && widget.order.status != SaleStatus.refused
                        && widget.order.status != SaleStatus.refunded) ...[
                      _ActionBtn(
                        icon: Icons.local_shipping_outlined,
                        color: AppColors.primary,
                        bgColor: AppColors.primarySurface,
                        tooltip: 'Modifier les frais (livraison…)',
                        onTap: () => _editFees(context),
                      ),
                      const SizedBox(width: 6),
                    ],
                    // Édition des articles interdite sur une commande déjà
                    // complétée (les articles sont figés). Les frais restent
                    // modifiables via le bouton dédié ci-dessus.
                    if (widget.canEdit
                        && widget.order.status != SaleStatus.completed) ...[
                      _ActionBtn(
                        icon: Icons.edit_rounded,
                        color: AppColors.primary,
                        bgColor: AppColors.primarySurface,
                        tooltip: 'Modifier la commande',
                        onTap: () => _showEditOrder(context),
                      ),
                      const SizedBox(width: 6),
                    ],
                    // hotfix_084 : le bouton n'apparaît que si la commande
                    // est éligible (statut ouvert non-payé). Évite à
                    // l'opérateur de cliquer pour se voir refuser dans le
                    // dialog — sécurise aussi par construction puisque le
                    // use case et la RPC enforce les mêmes règles.
                    if (widget.canDelete
                        && DeleteSaleUseCase.allowedStatuses
                            .contains(widget.order.status)
                        && widget.order.amountPaid <= 0)
                      _ActionBtn(
                        icon: Icons.delete_outline_rounded,
                        color: AppColors.error,
                        bgColor: AppColors.error.withValues(alpha: 0.12),
                        tooltip: 'Supprimer',
                        onTap: () => _confirmDelete(context),
                      ),
                  ]),
                  // Historique des transferts retiré : l'envoi se fait
                  // désormais manuellement via copier-coller dans WhatsApp,
                  // plus aucune trace ne transite par l'app.
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

  /// Actions secondaires contextuelles d'une commande — regroupées dans la
  /// feuille « Actions » pour alléger la carte (densité). La liste dépend du
  /// statut/permissions ; vide → aucun bouton « Actions » affiché.
  List<_OrderActionItem> _contextualActions(BuildContext context) {
    final o = widget.order;
    final s = o.status;
    final hasPhone = (o.clientPhone ?? '').trim().isNotEmpty;
    final list = <_OrderActionItem>[];

    // L'emballage a QUITTÉ cette liste : il a son propre bouton sur la carte
    // (`_buildPackagingAction`), affiché au moment où il sert. Et la feuille
    // « Actions » elle-même ne s'ouvre plus en restauration.
    if (_canRemindClient()) {
      list.add(_OrderActionItem(
          icon: Icons.phonelink_ring_rounded,
          label: 'Relancer via WhatsApp (lien de suivi)',
          color: AppColors.whatsapp,
          onTap: () => _remindClient(context)));
    }
    // Disponible tant que la commande est active (Programmée OU En cours) :
    // le client peut confirmer via le lien web (→ En cours) et il faut alors
    // pouvoir envoyer le message au livreur/partenaire.
    if (!_isResto
        && (s == SaleStatus.scheduled || s == SaleStatus.processing)
        && _permsForOrder().canTransferDelivery) {
      list.add(_OrderActionItem(
          icon: Icons.content_copy_rounded,
          label: 'Copier message livraison',
          color: AppColors.whatsapp,
          onTap: () => _openCopyDeliveryMessage(context)));
    }
    if (o.source == 'web'
        && (s == SaleStatus.scheduled || s == SaleStatus.processing)
        && hasPhone) {
      list.add(_OrderActionItem(
          icon: Icons.notifications_active_outlined,
          label: 'Relancer le client',
          color: AppColors.whatsapp,
          onTap: () => _relaunchClient(context)));
    }
    if (_canReschedule()) {
      list.add(_OrderActionItem(
          icon: Icons.event_repeat_rounded,
          label: 'Reprogrammer la commande',
          color: AppColors.warning,
          onTap: () => _askReschedule(context)));
    }
    if (!_isResto
        && widget.canEdit
        && s == SaleStatus.scheduled
        && OrdersExportSource
            .partnerLocationsForShop(o.shopId).isNotEmpty) {
      list.add(_OrderActionItem(
          icon: Icons.move_up_rounded,
          label: 'Transférer à un partenaire',
          color: AppColors.primary,
          onTap: () => _transferToPartner(context)));
    }
    if ((s == SaleStatus.scheduled || s == SaleStatus.processing)
        && hasPhone) {
      list.add(_OrderActionItem(
          icon: Icons.error_outline_rounded,
          label: 'Article en rupture — prévenir le client',
          color: AppColors.error,
          onTap: () => _notifyOutOfStock(context)));
    }
    // Commande web dont le prix de livraison reste à fixer (quartier non
    // répertorié) — remplace le bandeau retiré de la carte repliée.
    if (!_isResto && o.deliveryFeeToFix) {
      list.add(_OrderActionItem(
          icon: Icons.local_shipping_outlined,
          label: 'Fixer les frais de livraison',
          color: AppColors.warning,
          onTap: () => _fixDeliveryFee(context)));
    }
    return list;
  }

  /// Boutique de RESTAURATION — commande prise sur place, emportée par le
  /// client lui-même. Tout ce qui relève de la livraison (étape « en cours »,
  /// frais de course, transfert à un partenaire, refus à la porte) est retiré
  /// de la carte : ce sont des gestes qui n'auront jamais lieu ici, et chacun
  /// d'eux est une occasion de se tromper.
  ///
  /// Déduit du SECTEUR de la boutique portant la commande — pas d'un provider
  /// réactif, qui pouvait rendre une valeur périmée et faire apparaître le
  /// mauvais bouton d'encaissement.
  bool get _isResto => isRestaurantShop(widget.order.shopId);

  /// Feuille listant les actions contextuelles. Tap → ferme + exécute.
  void _showActionsSheet(
      BuildContext context, List<_OrderActionItem> actions) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textHint.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text('Actions de la commande',
                  style: AppTextStyles.subtitleBold),
            ),
            for (final a in actions)
              ListTile(
                leading: Icon(a.icon, color: a.color, size: 22),
                title: Text(a.label,
                    style: AppTextStyles.body
                        .copyWith(color: AppColors.textPrimary)),
                onTap: () { Navigator.of(ctx).pop(); a.onTap(); },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
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
    // le statut vers `processing` (cf. hotfix_173).
    //
    // Le lien porte le JETON, pas l'identifiant : celui-ci est devinable par
    // énumération sur les commandes créées dans l'app, et il exposait nom,
    // téléphone, panier et adresse de n'importe quelle commande (hotfix_171).
    // Repli sur l'id tant que la commande n'a pas été synchronisée — elle
    // reste alors lisible, mais le client ne pourra pas la valider.
    final trackKey = order.trackingToken ?? order.id;
    final trackUrl = 'https://fortress-pos.web.app/track/$trackKey';
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
  /// Ouvre RecordAcompteDialog. À la confirmation, persiste le nouveau
  /// `amountPaid` cumulé via SaleLocalDatasource.recordPayment (qui dérive
  /// `payment_status` automatiquement : partial si < total, paid si =>).
  Future<void> _recordAcompte(BuildContext context) async {
    final newAmount = await RecordAcompteDialog.show(context, widget.order);
    if (newAmount == null || !mounted) return;
    final ok = await SaleLocalDatasource()
        .recordPayment(widget.order.id!, newAmount);
    // Rafraîchir via le parent (relit Hive → Sale fraîche → le bandeau
    // « Reste à payer » disparaît dès que le solde est réglé). Le simple
    // setState local ne suffit pas : il reconstruit la card avec
    // `widget.order` encore périmé.
    widget.onChanged?.call();
    if (mounted) setState(() {});
    if (!mounted) return;
    // Le succès n'est annoncé QUE s'il a eu lieu. Le message partait
    // auparavant sans rien vérifier : quand l'enregistrement échouait, la
    // confirmation s'affichait quand même et l'argent encaissé n'était noté
    // nulle part.
    //
    // Distinguer l'échec du succès impose DEUX appels (`error` / `success`),
    // là où le code d'origine n'en avait qu'un. L'analyseur signale donc ici
    // une remarque `use_build_context_synchronously` de plus qu'avant —
    // assumée : c'est un `info`, ce fichier en compte une vingtaine
    // d'identiques, et la supprimer exigerait de choisir aussi la fonction à
    // appeler, au prix de la lisibilité. Prévenir d'un encaissement perdu
    // vaut mieux qu'une remarque de moins.
    final message = !ok
        ? 'Acompte NON enregistré — commande introuvable. '
            'Rafraîchissez la liste et réessayez.'
        : (newAmount >= widget.order.total
            ? 'Commande totalement encaissée'
            : 'Acompte enregistré');
    if (ok) {
      AppSnack.success(context, message);
      return;
    }
    AppSnack.error(context, message);
  }

  /// Ouvre l'éditeur de frais (livraison/emballage). Disponible à tout
  /// moment, y compris après complétion (le coût de livraison est souvent
  /// connu après coup). Persiste les nouveaux frais via `updateOrder` et
  /// trace le changement dans `activity_logs` (qui/quoi/quand).
  ///
  /// Fusion de l'ancien bouton « $ » : pour une commande complétée, livrée
  /// par un partenaire et déjà entièrement payée, le sheet propose en plus une
  /// section « Dépense à régler au partenaire ». Si l'opérateur la renseigne,
  /// on écrit une entrée `deliveryOwed` négative dans le partner_ledger
  /// (compensée au prochain versement) — exactement comme le faisait l'ancien
  /// `AddOrderExpenseDialog`, mais depuis un point d'entrée unique.
  Future<void> _editFees(BuildContext context) async {
    final order = widget.order;
    final before = order.fees
        .map((f) => OrderFee(
              id: f['id']?.toString() ?? '',
              label: f['label']?.toString() ?? '',
              amount: (f['amount'] as num?)?.toDouble() ?? 0,
            ))
        .toList();

    final result = await showOrderFeesSheet(
      context,
      initialFees: before,
      initialDeliveryPrice: (order.deliveryPrice ?? 0).round(),
      showDeliveryPrice: order.deliveryMode != DeliveryMode.pickup,
    );
    if (result == null || !mounted) return; // annulé

    final newFees = result.fees
        .map((f) => {'id': f.id, 'label': f.label, 'amount': f.amount})
        .toList();
    final updated = order.copyWith(fees: newFees);
    await SaleLocalDatasource().updateOrder(updated);
    // Prix de livraison FACTURÉ au client → entre dans le total à payer ET sur
    // la facture (Sale.deliveryPrice). Écriture ciblée après l'upsert des frais.
    if (order.deliveryMode != DeliveryMode.pickup && order.id != null) {
      await SaleLocalDatasource().setDeliveryPrice(
          order.id!, result.deliveryPrice);
    }

    // Traçabilité (règle métier) : qui a modifié les frais, et le détail
    // avant/après — consultable dans le journal d'activité.
    ActivityLogService.log(
      action:      'order_fees_updated',
      targetType:  'order',
      targetId:    order.id,
      targetLabel: order.clientName ?? 'Commande',
      shopId:      order.shopId,
      details: {
        'before': before.map((f) =>
            {'label': f.label, 'amount': f.amount}).toList(),
        'after': result.fees.map((f) =>
            {'label': f.label, 'amount': f.amount}).toList(),
        'total_fees_before':
            before.fold<double>(0, (s, f) => s + f.amount),
        'total_fees_after':
            result.fees.fold<double>(0, (s, f) => s + f.amount),
      },
    );

    // Commande livrée par un partenaire et pas encore reversée : répercuter les
    // frais sur le livre partenaire (deliveryOwed resynchronisé). Couvre les
    // DEUX cas, de façon cohérente avec la complétion (_generatePartnerLedgerEntries) :
    //   • partenaire a encaissé (non reversé) → les frais sont déduits du
    //     montant « à verser » (le bandeau bleu se recalcule en direct) ;
    //   • boutique a encaissé → la boutique DOIT ces frais au partenaire, donc
    //     ils sont déduits de ce qu'il doit verser sur ses autres commandes.
    // C'est ce qui remplace l'ancien bouton « Dépense à régler au partenaire » :
    // un seul point de saisie (les frais) sert les deux usages.
    // (Pas touché si déjà reversé : un versement reçu fige la commande.)
    final partnerLocId = order.deliveryLocationId;
    if (order.status == SaleStatus.completed
        && order.deliveryMode == DeliveryMode.partner
        && partnerLocId != null && partnerLocId.isNotEmpty) {
      final alreadyRemitted = PartnerLedgerService.entriesForShop(order.shopId)
          .where((e) => e.orderId == order.id)
          .any((e) => e.type == PartnerLedgerEntryType.remittance);
      if (!alreadyRemitted) {
        await PartnerLedgerService.syncOrderDeliveryFee(
          shopId:            order.shopId,
          partnerLocationId: partnerLocId,
          orderId:           order.id!,
          feesTotal:         result.fees.fold<double>(0, (s, f) => s + f.amount),
        );
      }
    }

    widget.onChanged?.call();
    if (mounted) setState(() {});
    if (mounted) {
      AppSnack.success(context, 'Frais de la commande mis à jour');
    }
  }

  /// Transfère la COMMANDE (pas le stock) à un dépôt partenaire : réassigne
  /// son emplacement + mode = partner. La commande passe alors sous la vue
  /// de ce partenaire et son stock sera décrémenté chez lui à la finalisation.
  /// BLOQUÉ si le partenaire choisi n'a pas assez de stock (choix utilisateur).
  Future<void> _transferToPartner(BuildContext context) async {
    final shopId = widget.order.shopId;
    final partners = OrdersExportSource.partnerLocationsForShop(shopId);
    if (partners.isEmpty) {
      AppSnack.info(context, 'Aucun dépôt partenaire configuré.');
      return;
    }
    final picked = await showModalBottomSheet<StockLocation>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 12),
          Container(width: 36, height: 4,
              decoration: BoxDecoration(color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Transférer la commande à…',
                  style: AppTextStyles.subtitleBold),
            ),
          ),
          for (final p in partners)
            ListTile(
              leading: Icon(Icons.local_shipping_outlined,
                  color: AppColors.primary),
              title: Text(p.name, style: AppTextStyles.body),
              onTap: () => Navigator.of(ctx).pop(p),
            ),
          const SizedBox(height: 12),
        ]),
      ),
    );
    if (picked == null || !context.mounted) return;
    final ds = SaleLocalDatasource();
    // Bloquer si le partenaire n'a pas le stock (choix utilisateur).
    final check = ds.locationCanFulfill(widget.order, picked.id);
    if (!check.ok) {
      AppSnack.error(context,
          'Stock insuffisant chez ${picked.name}'
          '${check.missing != null ? ' — ${check.missing}' : ''}. '
          'Transfert impossible.');
      return;
    }
    await ds.reassignDelivery(widget.order.id!,
        mode: DeliveryMode.partner, locationId: picked.id);
    ActivityLogService.log(
      action: 'order_transferred_partner',
      targetType: 'order', targetId: widget.order.id,
      targetLabel: widget.order.clientName ?? 'Commande',
      shopId: widget.order.shopId,
      details: {'partner_location_id': picked.id, 'partner_name': picked.name},
    );
    widget.onChanged?.call();
    if (context.mounted) {
      AppSnack.success(context, 'Commande transférée à ${picked.name}.');
    }
  }

  /// Prévient le client par WhatsApp que sa commande est en rupture de stock.
  /// Ouverture wa.me SYNCHRONE (pas d'await avant → user gesture web préservé).
  /// La suppression de la commande reste l'action « Supprimer » séparée.
  void _notifyOutOfStock(BuildContext context) {
    final order = widget.order;
    final phone = (order.clientPhone ?? '').trim();
    if (phone.isEmpty) {
      AppSnack.error(context, 'Numéro WhatsApp du client manquant.');
      return;
    }
    final p = PhoneFormatter.toWame(phone).replaceAll(RegExp(r'[^\d]'), '');
    if (p.isEmpty) {
      AppSnack.error(context, 'Numéro WhatsApp invalide.');
      return;
    }
    final clientName = order.clientName ?? 'Cher client';
    final shop = LocalStorageService.getShop(order.shopId);
    final shopName = shop?.name ?? 'notre boutique';
    final msg = 'Bonjour $clientName,\n\n'
        'Nous sommes désolés : le ou les articles de votre commande chez '
        '$shopName sont actuellement en rupture de stock. Nous ne pourrons '
        'malheureusement pas honorer cette commande. Merci de votre '
        'compréhension — n\'hésitez pas à nous recontacter prochainement.';
    final url = 'https://wa.me/$p?text=${Uri.encodeComponent(msg)}';
    openExternal(url).then((ok) {
      if (!ok && context.mounted) {
        AppSnack.error(context,
            'Impossible d\'ouvrir WhatsApp. Autorisez les pop-ups du navigateur.');
      }
    });
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
  /// Pré-génère le PDF facture + upload + raccourcit l'URL. Stocke le
  /// résultat dans `_invoiceShortUrl` pour que `_sendInvoiceWhatsApp`
  /// puisse ouvrir wa.me synchroniquement avec le lien intégré au message.
  /// No-op si déjà prêt ou en cours.
  Future<void> _prepareInvoice() async {
    if (_invoiceShortUrl != null || _preparingInvoice) return;
    setState(() => _preparingInvoice = true);
    final order = widget.order;
    final shop  = LocalStorageService.getShop(order.shopId);
    try {
      // Même moteur que l'aperçu in-app (facture brandée logo+couleurs)
      // pour que le lien partagé soit identique. Repli sur l'ancien
      // template Fortress si la boutique n'est pas en cache.
      final bytes = shop != null
          ? await InvoiceService.generatePdf(sale: order, shop: shop)
          : await OrderReceiptUseCase.generatePdf(order, shop: shop);
      final orderId = order.id
          ?? 'order_${order.createdAt.millisecondsSinceEpoch}';
      final longUrl = await InvoiceStorageService.uploadInvoice(
        shopId:  order.shopId,
        orderId: orderId,
        bytes:   bytes,
      );
      if (longUrl == null) return;
      // Raccourcisseur maison (Edge Function `r`) avec expiration 90j.
      // Fallback TinyURL si la création échoue.
      final shortUrl = await ShortLinkService.createShortLink(
        longUrl:   longUrl,
        linkType:  'invoice',
        expiresIn: const Duration(days: 90),
      ) ?? await UrlShortenerService.shorten(longUrl);
      if (mounted) setState(() => _invoiceShortUrl = shortUrl);
    } catch (_) {
      // Échec silencieux : `_sendInvoiceWhatsApp` retombera sur le flow
      // legacy avec presse-papier.
    } finally {
      if (mounted) setState(() => _preparingInvoice = false);
    }
  }

  /// Variables d'interpolation pour le template `invoice`.
  Map<String, String?> _invoiceContext({
    required Sale order,
    required String shopName,
    required String shortUrl,
  }) {
    final fmt = NumberFormat('#,###', 'fr_FR');
    return {
      'client_name': order.clientName ?? '',
      'shop_name':   shopName,
      'link':        shortUrl,
      'total':       '${fmt.format(order.total)} ${CurrencyFormatter.currentSymbol}',
      'order_id':    (order.id ?? '').replaceFirst('order_', ''),
      'date':        '${order.createdAt.day.toString().padLeft(2, '0')}/'
                     '${order.createdAt.month.toString().padLeft(2, '0')}/'
                     '${order.createdAt.year}',
    };
  }

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

    // Template `invoice` : celui du shop si présent, SINON un fallback
    // construit depuis le body par défaut du type. Avant, si le template
    // n'était pas seedé sur cet appareil (seed uniquement au 1er accès à
    // Paramètres > Modèles WhatsApp), `getDefault` renvoyait null → on
    // tombait sur un message générique codé en dur SANS lien. Désormais
    // le message envoyé correspond TOUJOURS au template facture.
    final tplRepo = ref.read(whatsappTemplateRepositoryProvider);
    final now = DateTime.now();
    final template =
        tplRepo.getDefault(order.shopId, WhatsappTemplateType.invoice)
        ?? WhatsappTemplate(
          id:        'fallback_invoice',
          shopId:    order.shopId,
          type:      WhatsappTemplateType.invoice,
          name:      WhatsappTemplateType.invoice.defaultName,
          body:      WhatsappTemplateType.invoice.defaultBody,
          isDefault: true,
          createdAt: now,
          updatedAt: now,
        );

    // ── Cas 1 : facture déjà pré-générée → render template + ouverture
    //    SYNCHRONE de wa.me dans le tick du clic.
    if (_invoiceShortUrl != null) {
      final msg = WhatsappTemplateRenderer.render(
        template,
        _invoiceContext(
          order:    order,
          shopName: shopName,
          shortUrl: _invoiceShortUrl!,
        ),
      );
      final url = 'https://wa.me/$p?text=${Uri.encodeComponent(msg)}';
      openExternal(url).then((ok) {
        if (!ok && context.mounted) {
          AppSnack.error(context,
              'Impossible d\'ouvrir WhatsApp. Autorisez les pop-ups dans le navigateur.');
        }
      });
      return;
    }

    // ── Cas 2 : facture pas encore prête. On envoie quand même le VRAI
    //    template facture (placeholder sur le lien), puis on génère/
    //    upload en arrière-plan et on copie le lien au presse-papier.
    //    (Contrainte web : wa.me doit s'ouvrir dans le tick du clic, donc
    //    on ne peut pas attendre l'URL ici.)
    final msg = WhatsappTemplateRenderer.render(
      template,
      _invoiceContext(
        order:    order,
        shopName: shopName,
        shortUrl: '(lien de la facture envoyé dans un instant)',
      ),
    );
    final url = 'https://wa.me/$p?text=${Uri.encodeComponent(msg)}';

    openExternal(url).then((ok) {
      if (!ok && context.mounted) {
        AppSnack.error(context,
            'Impossible d\'ouvrir WhatsApp. Autorisez les pop-ups dans le navigateur.');
      }
    });

    setState(() => _sendingInvoice = true);
    () async {
      try {
        // Même moteur que l'aperçu in-app (facture brandée logo+couleurs)
        // pour que le lien partagé soit identique. Repli sur l'ancien
        // template Fortress si la boutique n'est pas en cache.
        final bytes = shop != null
            ? await InvoiceService.generatePdf(sale: order, shop: shop)
            : await OrderReceiptUseCase.generatePdf(order, shop: shop);
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
        final shortUrl = await ShortLinkService.createShortLink(
              longUrl:   longUrl,
              linkType:  'invoice',
              expiresIn: const Duration(days: 90),
            )
            ?? await UrlShortenerService.shorten(longUrl);
        await Clipboard.setData(ClipboardData(text: shortUrl));
        if (mounted) {
          setState(() => _invoiceShortUrl = shortUrl);
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

  /// Suffixe « — Quartier, Ville » pour le bandeau « frais à fixer ».
  String _deliveryDest() {
    final parts = [widget.order.deliveryQuartier, widget.order.deliveryCity]
        .where((s) => (s ?? '').trim().isNotEmpty)
        .toList();
    return parts.isEmpty ? '' : ' — ${parts.join(', ')}';
  }

  /// Saisie du prix de livraison pour une commande web « à fixer » (quartier
  /// non répertorié). Persiste le prix (le total est recalculé) puis propose
  /// d'en informer le client par WhatsApp si un numéro est disponible.
  Future<void> _fixDeliveryFee(BuildContext context) async {
    final order = widget.order;
    if (order.id == null) return;
    final ctrl = TextEditingController();
    final amount = await showAdaptiveFormSheet<double>(
      context: context,
      builder: (ctx) => AdaptiveFormFrame(
        title: 'Frais de livraison',
        icon: Icons.local_shipping_outlined,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                      'Quartier non répertorié${_deliveryDest()}. '
                      'Saisissez les frais convenus avec le client.',
                      style: AppTextStyles.body
                          .copyWith(color: AppColors.textHint)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    decoration: InputDecoration(
                      isDense: true,
                      suffixText: 'FCFA',
                      hintText: 'Montant',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Annuler'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      final v = double.tryParse(
                          ctrl.text.trim().replaceAll(',', '.'));
                      Navigator.of(ctx).pop(v);
                    },
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary),
                    child: const Text('Enregistrer'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (amount == null || amount < 0) return;
    await SaleLocalDatasource().setDeliveryPrice(order.id!, amount.round());
    if (!mounted) return;
    AppSnack.success(context,
        'Frais de livraison fixés : ${CurrencyFormatter.format(amount)}');
    // Notifier le client par WhatsApp si un numéro est disponible.
    final phone = (order.clientPhone ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (phone.isEmpty) return;
    final newTotal =
        order.subtotal - order.discountAmount + order.taxAmount + amount;
    final msg = 'Bonjour, les frais de livraison pour votre commande '
        's\'élèvent à ${CurrencyFormatter.format(amount)}. '
        'Total à payer : ${CurrencyFormatter.format(newTotal)}.';
    await openExternal('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}');
  }

  /// Permissions de l'utilisateur pour le shop de cette commande.
  AppPermissions _permsForOrder() =>
      ref.read(permissionsProvider(widget.order.shopId));

  /// Défaire une vente DÉJÀ ENCAISSÉE (retour en « programmée »).
  ///
  /// En RESTAURATION, sous PIN gérant et journalisé. C'est la troisième porte
  /// par laquelle l'argent ressort sans qu'un plat sorte, après l'annulation
  /// d'une tournée et la remise sur addition — et la plus large, puisqu'elle
  /// restitue stock, paiement et écritures partenaire. La permission
  /// `canCancelSale` seule ne disait pas QUI avait autorisé le geste.
  ///
  /// Hors restauration, le comportement est inchangé : le circuit e-commerce a
  /// ses propres contrôles (partenaires, transferts) et n'a pas de gérant de
  /// salle au bout du comptoir.
  Future<void> _reopenPaidSale(BuildContext context) async {
    if (_isResto) {
      final ok = await ManagerGate.require(
        context: context,
        perms: _permsForOrder(),
        action: ManagerAction.reopenPaidSale,
        shopId: widget.order.shopId,
        targetId: widget.order.id,
        targetLabel: widget.order.clientName,
        details: {
          'total': widget.order.total,
          'amount_paid': widget.order.amountPaid,
          'order_type': widget.order.orderType,
        },
      );
      if (!ok) return;
    }
    widget.onUpdate(SaleStatus.scheduled);
  }

  /// Ouvre le sheet « Copier message livraison ». Génère le message
  /// final (template résolu + variables partenaire + lien court produits)
  /// et le met dans le presse-papier. Le user colle ensuite manuellement
  /// dans son groupe WhatsApp — wa.me ne supportant pas les groupes,
  /// l'envoi automatique in-app n'est pas possible.
  Future<void> _openCopyDeliveryMessage(BuildContext context) async {
    final shop = LocalStorageService.getShop(widget.order.shopId);
    await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => CopyDeliveryMessageSheet(
        order:    widget.order,
        shopId:   widget.order.shopId,
        shopName: shop?.name ?? '',
      ),
    );
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

  /// Bouton d'évènement contextuel qui remplace l'ancien menu déroulant de
  /// statut. On ne « choisit » plus un statut : on déclenche l'évènement
  /// métier adapté à l'état courant (qui ouvre les sheets de paiement /
  /// livraison / clôture via `widget.onUpdate`).
  ///   * Programmée  → « Démarrer la livraison » (→ en cours). Masqué quand
  ///     la paire « Validée / Annulée par client » est déjà affichée (échéance).
  ///   * En cours    → « Encaisser & finaliser » (→ complétée).
  ///   * États terminaux → pastille de statut en lecture seule.
  ///
  /// EN RESTAURATION, l'étape « en cours de livraison » n'existe pas : le
  /// client commande sur place et emporte lui-même. Une commande programmée
  /// s'encaisse donc DIRECTEMENT, sans passer par un état intermédiaire qui
  /// n'aurait aucune réalité en salle. Le stock suit : `scheduled → completed`
  /// décrémente en une fois (cf. `StockEngagement.decide`).
  /// Emballages de la commande — facturés au client, déduits du stock.
  ///
  /// Ouvert À LA DEMANDE, jamais d'office : sur place l'emballage est
  /// l'exception, et l'imposer à chaque commande ralentirait tout le service
  /// pour un cas minoritaire.
  Future<void> _addPackaging(BuildContext context) async {
    final billed = await showPackagingSheet(
      context: context,
      shopId: widget.order.shopId,
      order: widget.order,
    );
    if (billed == null || !context.mounted) return;
    if (billed > 0) {
      AppSnack.success(
          context, '$billed emballage(s) ajouté(s) — stock déduit');
    }
  }

  /// Cette commande porte-t-elle déjà des emballages facturés ?
  ///
  /// Repéré sur les LIGNES DE FRAIS, seule trace qu'un emballage a été posé —
  /// `showPackagingSheet` en écrit une par article retenu.
  bool get _hasPackaging => widget.order.fees.any((f) {
        final label = (f['label'] as String?)?.toLowerCase() ?? '';
        return _packagingNames.any(label.contains);
      });

  /// Noms des fournitures facturables, en minuscules — ce sont les libellés
  /// que `showPackagingSheet` écrit sur les frais.
  List<String> get _packagingNames => StockItemService
      .sellable(widget.order.shopId)
      .map((i) => i.name.toLowerCase())
      .toList();

  /// BOUTON D'EMBALLAGE, affiché au moment où il sert — un seul geste au lieu
  /// des trois qu'imposait le menu « Actions ».
  ///
  /// Le moment diffère selon le canal, parce que la réalité diffère :
  ///   * À EMPORTER — dès le premier état : la commande part dans un
  ///     contenant, c'est sa nature même ;
  ///   * SUR PLACE — seulement une fois TERMINÉE : on emballe les restes, et
  ///     avant la fin du repas il n'y a rien à emballer. Le proposer plus tôt
  ///     encombrerait chaque table de la salle ;
  ///   * À LIVRER — OBLIGATOIRE : une commande qui voyage doit être fermée.
  ///     Le bouton s'affiche donc en avertissement tant que rien n'est posé,
  ///     et l'encaissement est refusé (cf. `_buildServiceProgress`).
  List<Widget> _buildPackagingAction(BuildContext context, SaleStatus s) {
    if (!_isResto) return const [];
    if (s != SaleStatus.scheduled && s != SaleStatus.processing) {
      return const [];
    }
    final o = widget.order;
    final delivery = o.orderType == 'delivery';
    final show = switch (o.orderType) {
      'takeaway' => true,
      'delivery' => true,
      _ => o.finished,
    };
    if (!show) return const [];

    // DÉJÀ EMBALLÉE → plus rien à proposer. La feuille « Type de commande »
    // pose désormais les emballages à la prise, pour l'emporté comme pour la
    // livraison : la commande arrive ici avec sa ligne de frais. Le bouton
    // « Emballages — ajouter » qui subsistait laissait croire à une étape en
    // attente, et rouvrir la feuille aurait facturé une seconde fois le même
    // contenant. Les restes d'un repas en salle, eux, n'ont encore rien :
    // le bouton s'affiche pour eux comme avant.
    if (_hasPackaging) return const [];

    return [
      _WideActionButton(
        icon: Icons.takeout_dining_outlined,
        label: delivery ? 'Emballer (obligatoire)' : 'Emballer',
        // Une livraison sans emballage se signale en orange : ce n'est pas
        // une option qu'on aurait oubliée, c'est une étape manquante.
        color: delivery ? AppColors.warning : AppColors.primary,
        onPressed: () => _addPackaging(context),
      ),
      const SizedBox(height: 8),
    ];
  }

  /// ASSIGNER UN LIVREUR — commandes à livrer, tant qu'elles sont ouvertes.
  ///
  /// Le nom retenu s'inscrit sur la commande et le bouton l'affiche : on doit
  /// savoir qui porte la commande sans ouvrir quoi que ce soit.
  List<Widget> _buildCourierAction(BuildContext context, SaleStatus s) {
    if (!_isResto || widget.order.orderType != 'delivery') return const [];
    if (s != SaleStatus.scheduled && s != SaleStatus.processing) {
      return const [];
    }
    final assigned = (widget.order.deliveryPersonName ?? '').trim();
    return [
      _WideActionButton(
        icon: Icons.delivery_dining_outlined,
        label: assigned.isEmpty ? 'Assigner un livreur' : assigned,
        color: assigned.isEmpty ? AppColors.warning : AppColors.primary,
        onPressed: () => _assignCourier(context),
      ),
      const SizedBox(height: 8),
    ];
  }

  Future<void> _assignCourier(BuildContext context) async {
    final choice = await showCourierSheet(
      context: context,
      shopId: widget.order.shopId,
      current: widget.order.deliveryPersonName,
    );
    if (choice == null || !context.mounted) return;
    try {
      await SaleLocalDatasource()
          .updateOrder(widget.order.copyWith(
              deliveryPersonName: choice.label));
      if (context.mounted) {
        AppSnack.success(context, 'Commande confiée à ${choice.name}');
      }
    } catch (e) {
      if (context.mounted) AppSnack.error(context, e.toString());
    }
  }

  /// CANAL de la commande — « Emporter » ou « Livraison », dès le premier
  /// état et jusqu'au bout.
  ///
  /// Sur place n'a PAS de pastille : c'est le cas par défaut d'un restaurant,
  /// et l'étiqueter reviendrait à baliser toute la liste pour ne rien
  /// distinguer. Le nom de la table le dit déjà.
  ///
  /// Elle se lit avant tout le reste parce que c'est elle qui commande le
  /// geste : une commande à emporter s'emballe, une commande sur place se
  /// sert.
  List<Widget> _channelChip() {
    if (!_isResto) return const [];
    final (String label, IconData icon) = switch (widget.order.orderType) {
      'takeaway' => ('Emporter', Icons.takeout_dining_outlined),
      'delivery' => ('Livraison', Icons.local_shipping_outlined),
      _ => ('', Icons.circle),
    };
    if (label.isEmpty) return const [];
    return [
      _ServiceChip(label: label, icon: icon, color: AppColors.primary),
    ];
  }

  /// Pastille d'état de service, en regard du statut commercial.
  ///
  /// Muette hors restauration, et muette sur une commande jamais partie en
  /// cuisine : « pas encore envoyée » est déjà dit par le bouton d'action
  /// juste dessous, et une pastille de plus sur chaque carte ferait du bruit.
  List<Widget> _serviceStateChip() {
    if (!_isResto) return const [];
    final o = widget.order;
    // Une commande ENCAISSÉE est terminée, quoi qu'en disent ses drapeaux :
    // on ne fait pas payer un client dont l'assiette n'est pas arrivée. La
    // pastille ne dépend donc pas d'un parcours de service complet — un
    // encaissement direct, ou une commande dont un drapeau s'est perdu en
    // route, reste correctement étiquetée.
    if (o.status == SaleStatus.completed) {
      return [
        _ServiceChip(
            label: 'Terminée',
            icon: Icons.done_all_rounded,
            color: AppColors.secondary),
      ];
    }
    if (!o.sentToKitchen) return const [];

    final (String label, IconData icon, Color color) = o.isInKitchen
        ? ('En préparation', Icons.local_fire_department_rounded,
            AppColors.warning)
        : o.isWaitingService
            ? ('Prête', Icons.room_service_outlined, AppColors.primary)
            : o.finished
                ? ('Terminée', Icons.done_all_rounded, AppColors.secondary)
                : ('Servie', Icons.check_circle_outline_rounded,
                    AppColors.secondary);

    return [_ServiceChip(label: label, icon: icon, color: color)];
  }

  /// AVANCEMENT DU SERVICE — un bouton, celui de l'étape suivante.
  ///
  /// `Envoyer en cuisine → Commande prête → Servie` puis l'encaissement, qui
  /// garde sa propre ligne : ces boutons ne le remplacent pas. Un client qui
  /// paie tout de suite ne doit pas avoir à franchir trois étapes de service
  /// d'abord — et à l'inverse, avancer le service ne doit pas encaisser.
  ///
  /// À EMPORTER, l'étape « servie » devient « Remise au client » : rien n'est
  /// servi à une table, la commande passe par-dessus le comptoir. Le canevas
  /// distingue d'ailleurs les deux cycles (`Prête → Servie → …` en salle,
  /// `Prête → Terminée` au comptoir).
  ///
  /// Rendu seulement sur les commandes VIVANTES : une commande encaissée ou
  /// annulée n'a plus de service à faire avancer.
  List<Widget> _buildServiceProgress(BuildContext context, SaleStatus s) {
    if (!_isResto) return const [];
    if (s != SaleStatus.scheduled && s != SaleStatus.processing) {
      return const [];
    }
    final o = widget.order;

    final IconData icon;
    final String label;
    final Future<void> Function() action;
    if (!o.sentToKitchen) {
      icon   = Icons.local_fire_department_rounded;
      label  = 'Envoyer en préparation';
      action = () => RestaurantOrderService.sendToKitchen(o);
    } else if (o.isInKitchen) {
      icon   = Icons.room_service_outlined;
      label  = 'Commande prête';
      action = () => RestaurantOrderService.markKitchenReady(o);
    } else if (o.isWaitingService && o.orderType == 'dine_in') {
      // « Servie » n'a de sens qu'en salle : au comptoir comme en livraison,
      // remettre la commande et clore le service sont le MÊME geste — on passe
      // donc directement à « Terminée » plutôt que d'imposer deux taps pour un
      // seul évènement réel.
      icon   = Icons.restaurant_rounded;
      label  = 'Marquer servie';
      action = () => RestaurantOrderService.markServed(o);
    } else if (!o.finished) {
      // Fin du service, argent non encaissé. Le libellé nomme la réalité du
      // canal : un client attablé finit de manger, un client au comptoir
      // récupère, un client livré est livré.
      (icon, label) = switch (o.orderType) {
        'takeaway' => (Icons.shopping_bag_outlined, 'Commande récupérée'),
        'delivery' => (Icons.local_shipping_outlined, 'Livrée au client'),
        _          => (Icons.done_all_rounded, 'Repas terminé'),
      };
      action = () async {
        // GARDE LIVRAISON : une commande qui voyage doit être emballée. La
        // refuser ICI, au moment de la remise, plutôt qu'à l'encaissement :
        // c'est le dernier instant où le contenant est encore entre les mains
        // du restaurant.
        if (o.orderType == 'delivery' && !_hasPackaging) {
          if (context.mounted) {
            AppSnack.error(context,
                'Emballez la commande avant de la remettre au livreur.');
          }
          return;
        }
        await RestaurantOrderService.markFinished(o);
      };
    } else {
      // Terminée : il ne reste que l'encaissement, dont la ligne est juste
      // dessous. Un bouton de plus ne ferait que du bruit.
      return const [];
    }

    return [
      Row(children: [
        Expanded(
          child: _WideActionButton(
            icon: icon,
            label: label,
            color: AppColors.primary,
            onPressed: () async {
              try {
                await action();
              } catch (e) {
                if (context.mounted) AppSnack.error(context, e.toString());
              }
            },
          ),
        ),
        // Retour en arrière d'UN cran. « Prête » cliqué par erreur renvoie le
        // bon en préparation ; « terminée » de trop rouvre le service. Sans
        // ça, la seule issue serait d'encaisser un plat jamais parti.
        if (o.kitchenReady) ...[
          const SizedBox(width: 6),
          _ActionBtn(
            icon: Icons.undo_rounded,
            color: AppColors.warning,
            bgColor: AppColors.warning.withValues(alpha: 0.12),
            tooltip: o.finished
                ? 'Rouvrir le service'
                : 'Renvoyer en préparation',
            onTap: () => o.finished
                ? RestaurantOrderService.reopenService(o)
                : RestaurantOrderService.reopenKitchen(o),
          ),
        ],
      ]),
      const SizedBox(height: 8),
    ];
  }

  Widget _buildStatusAction(SaleStatus s) {
    switch (s) {
      case SaleStatus.scheduled:
        if (_canConfirmClient()) return _StatusChip(status: s);
        if (_isResto) {
          return _WideActionButton(
            icon: Icons.point_of_sale_rounded,
            label: 'Encaisser & finaliser',
            color: AppColors.secondary,
            filled: true,
            onPressed: () => widget.onUpdate(SaleStatus.completed),
          );
        }
        return _WideActionButton(
          icon: Icons.local_shipping_outlined,
          label: 'Démarrer la livraison',
          color: AppColors.primary,
          filled: true,
          onPressed: () => widget.onUpdate(SaleStatus.processing),
        );
      case SaleStatus.processing:
        return _WideActionButton(
          icon: Icons.point_of_sale_rounded,
          label: 'Encaisser & finaliser',
          color: AppColors.secondary,
          filled: true,
          onPressed: () => widget.onUpdate(SaleStatus.completed),
        );
      case SaleStatus.completed:
      case SaleStatus.cancelled:
      case SaleStatus.refused:
      case SaleStatus.refunded:
        return _StatusChip(status: s);
    }
  }

  /// Évènements négatifs (annuler / refuser) présentés comme un choix
  /// explicite, jamais comme une sélection de statut. Chaque option déclenche
  /// le flux métier dédié (motif d'annulation / frais de course refusée).
  Future<void> _askCancelOrRefuse(BuildContext context) async {
    // « Refusée » décrit un client qui refuse une LIVRAISON à sa porte. En
    // salle, personne ne refuse un plat qu'il vient de commander : il annule.
    // Proposer un choix dont une branche est sans objet ne fait qu'ajouter un
    // appui et une hésitation.
    if (_isResto) {
      await _askCancelReason(context);
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 12),
          Container(width: 36, height: 4,
              decoration: BoxDecoration(color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.cancel_outlined, color: AppColors.error),
            title: const Text('Annuler la commande'),
            subtitle: const Text('Le client a annulé — motif requis'),
            onTap: () => Navigator.of(ctx).pop('cancel'),
          ),
          ListTile(
            leading: const Icon(Icons.do_not_disturb_on_outlined,
                color: AppColors.error),
            title: const Text('Marquer comme refusée'),
            subtitle: const Text('Le client a refusé la livraison'),
            onTap: () => Navigator.of(ctx).pop('refuse'),
          ),
          const SizedBox(height: 12),
        ]),
      ),
    );
    if (!context.mounted) return;
    if (choice == 'cancel') {
      await _askCancelReason(context);
    } else if (choice == 'refuse') {
      widget.onUpdate(SaleStatus.refused);
    }
  }

  /// Confirme puis enregistre le versement partenaire reçu pour la commande
  /// (marquage manuel, écrit dans le livre partenaire via `onRemitReceived`).
  Future<void> _confirmRemitReceived(BuildContext context) async {
    final amount = widget.pendingRemittance ?? 0;
    if (amount <= 0 || widget.onRemitReceived == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
                color: AppColors.info.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.account_balance_wallet_outlined,
                size: 18, color: AppColors.info),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Versement reçu ?',
                style: AppTextStyles.subtitleBold),
          ),
        ]),
        content: Text(
            'Confirmer la réception de '
            '${CurrencyFormatter.format(amount)} versés par le partenaire '
            'pour cette commande ? Le livre partenaire sera mis à jour.',
            style: AppTextStyles.body.copyWith(height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dc).pop(false),
            child: Text('Annuler',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.info,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.of(dc).pop(true),
            child: const Text('Confirmer le versement'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.onRemitReceived!.call();
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
      hint: 'Raison (facultatif) — ex : empêchement client / boutique.',
      confirmLabel: 'Reprogrammer',
      confirmColor: AppColors.warning,
      // FIX 3 — la reprogrammation est une opération courante : motif facultatif.
      optional: true,
    );
    // `null` = fermé via X/Annuler → on abandonne. Chaîne vide = confirmé sans
    // motif → on reprogramme quand même.
    if (reason == null) return;
    await widget.onReschedule(newDate, reason);
  }

  void _showEditOrder(BuildContext context) {
    // Avertissement si commande complétée
    if (widget.order.status == SaleStatus.completed) {
      showDialog(
        context: context,
        builder: (dc) => AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.warning_amber_rounded,
                  size: 18, color: AppColors.warning),
            ),
            const SizedBox(width: 10),
            const Text('Commande complétée',
                style: AppTextStyles.subtitleBold),
          ]),
          content: Text(
              'Cette commande a déjà été complétée. '
                  'La modifier peut affecter la comptabilité. '
                  'Continuer quand même ?',
              style: AppTextStyles.bodySecondary),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dc).pop(),
                child: Text('Annuler',
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

  // Sélecteur de format d'impression — conservé (dormant) après le retrait du
  // bouton « Partager ». Réutilisable pour un futur bouton « Imprimer ».
  // ignore: unused_element
  void _showFormatPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _FormatPickerSheet(order: widget.order),
    );
  }

  /// Aperçu de la facture personnalisée (logo + couleurs dérivées).
  /// Diffère du legacy `DocumentService.previewInvoice` qui utilise le
  /// template Fortress violet ; ce flow passe par `InvoiceService` →
  /// `Printing.layoutPdf` qui propose nativement impression + share.
  Future<void> _previewBrandedInvoice(BuildContext context) async {
    final shop = LocalStorageService.getShop(widget.order.shopId);
    if (shop == null) {
      // Filet : si la shop n'est pas en cache local (cas improbable
      // sur cette page qui ne s'ouvre que dans un shop courant), on
      // retombe sur l'ancien template pour ne pas bloquer l'opérateur.
      await DocumentService.previewInvoice(widget.order, context);
      return;
    }
    try {
      await Printing.layoutPdf(
        name: 'Facture-${widget.order.id ?? "POS"}',
        onLayout: (format) =>
            InvoiceService.generatePdf(sale: widget.order, shop: shop),
      );
    } catch (e) {
      if (!context.mounted) return;
      // Si `Printing.layoutPdf` n'est pas dispo (web sans support
      // imprimante ou popup bloquée), on partage les bytes directement
      // via share_plus → l'utilisateur peut télécharger ou ouvrir
      // dans un viewer externe.
      try {
        final bytes = await InvoiceService.generatePdf(
            sale: widget.order, shop: shop);
        if (bytes.isEmpty) {
          AppSnack.error(context, 'Erreur génération facture');
          return;
        }
        final filename = 'facture_${widget.order.id ?? "pos"}.pdf';
        final xfile = XFile.fromData(bytes,
            name: filename, mimeType: 'application/pdf');
        await Share.shareXFiles([xfile], subject: filename);
      } catch (e2) {
        if (context.mounted) {
          AppSnack.error(context, 'Erreur facture : $e2');
        }
      }
    }
  }

  /// Ouvre le sheet de clôture de tournée « à choisir sur place ». Récupère
  /// les quantités gardées par article puis délègue au callback parent qui
  /// appelle `closeApprovalOrder` (réconciliation du stock réservé).
  Future<void> _closeApproval(BuildContext context) async {
    final res = await showApprovalClosureSheet(context, order: widget.order);
    if (res == null) return; // annulé
    await widget.onCloseApproval(res);
    if (mounted) setState(() {});
  }

  /// Annule une tournée « à choisir sur place » après confirmation : tout le
  /// stock réservé est restauré (callback parent → `cancelApprovalOrder`).
  Future<void> _cancelApproval(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Annuler la tournée'),
        content: const Text(
            'Tous les articles réservés seront remis en stock et la commande '
            'sera annulée. Continuer ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Retour'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Annuler la tournée'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.onCancelApproval();
    if (mounted) setState(() {});
  }

  Future<void> _confirmDelete(BuildContext context) async {
    // Dialog dédié (hotfix_084) : motif obligatoire ≥ 10 caractères,
    // checkbox de confirmation, bouton danger désactivé tant que les 2
    // conditions ne sont pas réunies. Remplace l'ancien DangerActionService
    // pour cette action précise (qui demandait un confirmText par recopie).
    await showDeleteSaleDialog(
      context,
      order: widget.order,
      onConfirm: widget.onDelete,
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

  // Ticket 80 mm par défaut (index 3) : c'est le format d'impression de
  // l'établissement. Les formats A4/A5/A6 restent proposés pour un envoi
  // par e-mail ou une impression bureautique.
  int _selected = 3;

  @override
  Widget build(BuildContext context) {
    final fmt = _formats[_selected];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
                      style: AppTextStyles.subtitleBold
                          .copyWith(fontWeight: FontWeight.w800)),
                  Text('Choisissez le format de votre reçu',
                      style: AppTextStyles.captionHint),
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
                              : Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: sel
                                ? AppColors.primary.withValues(alpha:0.5)
                                : AppColors.inputFill,
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
                                    style: AppTextStyles.bodySmBold.copyWith(
                                        color: sel
                                            ? AppColors.primary
                                            : Theme.of(context)
                                                .colorScheme.onSurface)),
                                Text(f.description,
                                    style: AppTextStyles.micro),
                              ],
                            ),
                          ),
                          Text(
                            '${f.widthMm}×${f.heightMm}mm',
                            style: AppTextStyles.micro.copyWith(
                                color: sel
                                    ? AppColors.primary
                                    : AppColors.textHint,
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
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
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
                style: AppTextStyles.micro.copyWith(
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
                style: AppTextStyles.microBold.copyWith(
                    fontSize: 7,
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
          style: AppTextStyles.microBold.copyWith(color: color)),
    );
  }
}

// ─── Avatar client (initiales colorées) ──────────────────────────────────────
/// Pastille ronde avec les initiales du client, couleur stable dérivée du
/// nom. Rend la liste des commandes plus vivante et scannable qu'une icône
/// générique. Couleur déterministe → un même client garde toujours la même.
class _ClientAvatar extends StatelessWidget {
  final String name;
  final double size;
  const _ClientAvatar({required this.name, this.size = 20});

  // Palette douce — l'index est dérivé du nom (cf. _color).
  static const _palette = [
    Color(0xFF6366F1), // indigo
    Color(0xFF0EA5E9), // sky
    AppColors.secondary, // emerald
    AppColors.warning, // amber
    AppColors.error, // red
    Color(0xFFEC4899), // pink
    Color(0xFF8B5CF6), // violet
    Color(0xFF14B8A6), // teal
  ];

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final p = parts.first;
      return (p.length >= 2 ? p.substring(0, 2) : p).toUpperCase();
    }
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  Color get _color {
    var h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _palette[h % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return Container(
      width: size, height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.5),
      ),
      child: Text(_initials,
          style: (size >= 30 ? AppTextStyles.captionBold : AppTextStyles.microBold)
              .copyWith(color: color)),
    );
  }
}

/// Action secondaire d'une commande, présentée dans la feuille « Actions »
/// (regroupement pour alléger la carte).
class _OrderActionItem {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _OrderActionItem({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
}

/// Bouton d'action « tonal » de la carte commande : fond teinté doux + icône
/// + libellé, dimensionné au contenu. [filled] = fond plein coloré (action
/// primaire, ex. « Encaisser »).
class _WideActionButton extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  final VoidCallback? onPressed;
  final bool     filled;
  const _WideActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final bg = filled
        ? color.withValues(alpha: disabled ? 0.4 : 1)
        : color.withValues(alpha: disabled ? 0.05 : 0.10);
    final fg = filled
        ? Colors.white
        : color.withValues(alpha: disabled ? 0.5 : 1);
    // Dimensionné au CONTENU + padding compact H10/V3. Pas de wrapper qui
    // remplit la largeur → en `Wrap` (contraintes lâches) le bouton épouse son
    // contenu et s'enchaîne sur la ligne ; en `Expanded` (contraintes serrées)
    // le Container remplit la cellule. Le `Flexible` borne le Text → ellipse
    // au lieu de déborder quand l'espace manque.
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: filled
                ? null
                : Border.all(color: color.withValues(alpha: 0.22)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodySmBold.copyWith(color: fg)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pastille de statut en LECTURE SEULE (remplace l'ancien menu déroulant
/// `_StatusMenu`). Le changement de statut passe désormais uniquement par
/// des boutons d'évènement contextuels, jamais par une sélection directe.
/// Pastille d'état de SERVICE (restauration) — « En préparation », « Prête »,
/// « Servie », « Terminée ». Distincte de [_StatusChip], qui porte le statut
/// commercial : une commande peut être « Programmée » et déjà « Prête ».
class _ServiceChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const _ServiceChip({
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(label, style: AppTextStyles.microBold.copyWith(color: color)),
        ]),
      );
}

class _StatusChip extends StatelessWidget {
  final SaleStatus status;
  const _StatusChip({required this.status});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: status.color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: status.color.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 7, height: 7,
              decoration: BoxDecoration(
                  color: status.color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(status.label,
              style: AppTextStyles.captionBold
                  .copyWith(color: status.color)),
        ]),
      );
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
                ? Theme.of(context).semantic.borderSubtle
                : (bgColor ?? color.withValues(alpha:0.1)),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
                color: disabled
                    ? Theme.of(context).semantic.borderSubtle
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
    // Commande PROGRAMMÉE : le mode de paiement et le lieu de retrait/livraison
    // ne sont pas encore fixés → on ne les affiche pas (cf. demande).
    final isScheduled = order.status == SaleStatus.scheduled;
    final feesTotal = order.fees.fold<double>(
        0, (s, f) => s + ((f['amount'] as num?)?.toDouble() ?? 0));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ─── Paiement ─── (masqué si programmée : mode pas encore connu)
        if (!isScheduled)
          _DetailRow(
            icon: _paymentIcon(order.paymentMethod),
            label: 'Paiement',
            value: _paymentLabel(order.paymentMethod),
          ),

        // ─── Livraison ─── (masqué si programmée : lieu pas encore fixé)
        if (!isScheduled) ...[
          const SizedBox(height: 6),
          _DetailRow(
            icon: _deliveryIcon(order.deliveryMode),
            label: 'Livraison',
            value: order.deliveryMode?.labelFr ?? 'Non renseigné',
          ),
        ],
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
        Divider(height: 1, color: AppColors.inputFill),
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
        if ((order.deliveryPrice ?? 0) > 0)
          _MoneyLine(
              label: 'Livraison'
                  '${(order.deliveryQuartier ?? '').isNotEmpty
                      ? ' — ${order.deliveryQuartier}' : ''}',
              value: _money(order.deliveryPrice!)),
        if (feesTotal > 0)
          _MoneyLine(
              label: 'Frais supplémentaires',
              value: _money(feesTotal)),
        const SizedBox(height: 4),
        _MoneyLine(
            label: 'Total facturé',
            value: _money(order.total),
            bold: true),
        // Frais de livraison dûs au partenaire livreur (déduits de son
        // versement) → rend la dette explicite directement sur la commande.
        if (order.deliveryMode == DeliveryMode.partner
            && (order.deliveryLocationId ?? '').isNotEmpty
            && (order.deliveryPrice ?? 0) > 0) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(children: [
              const Icon(Icons.local_shipping_outlined,
                  size: 10, color: AppColors.info),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                    'Frais de livraison dûs au partenaire '
                    '(déduits de son versement)',
                    style: AppTextStyles.micro
                        .copyWith(color: AppColors.info)),
              ),
            ]),
          ),
        ],

        // ─── Détail des frais (toujours, même un seul frais) ──────
        // Affiche chaque frais (libellé + montant) pour que l'opérateur
        // sache EXACTEMENT ce qui est déjà engagé sur la commande et évite
        // de saisir deux fois (ex. livraison) — cf. règle métier frais.
        if (order.fees.isNotEmpty) ...[
          const SizedBox(height: 6),
          for (final f in order.fees)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Row(children: [
                Icon(Icons.subdirectory_arrow_right_rounded,
                    size: 10, color: AppColors.textHint),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(f['label']?.toString() ?? '',
                      style: AppTextStyles.micro),
                ),
                Text(_money(((f['amount'] as num?)?.toDouble() ?? 0)),
                    style: AppTextStyles.micro),
              ]),
            ),
        ],

        // ─── Référence + numéro client ────────────────────────────
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.tag_rounded, size: 10, color: AppColors.textHint),
          const SizedBox(width: 4),
          Expanded(
            child: Text(order.id ?? '',
                style: TextStyle(fontSize: 10,
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
                      style: AppTextStyles.micro.copyWith(
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
            style: AppTextStyles.micro
                .copyWith(fontWeight: FontWeight.w500)),
      ),
      Expanded(
        child: Text(value,
            style: AppTextStyles.captionHint.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
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
          style: AppTextStyles.bodySm.copyWith(
              fontSize: bold ? 12 : 10,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              color: color ?? (bold
                  ? Theme.of(context).colorScheme.onSurface
                  : AppColors.textSecondary))),
      Text(value,
          style: AppTextStyles.body.copyWith(
              fontSize: bold ? 13 : 11,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              color: color ?? (bold
                  ? AppColors.primary
                  : Theme.of(context).colorScheme.onSurface))),
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
                  style: AppTextStyles.microBold
                      .copyWith(fontWeight: FontWeight.w800, color: color)),
              const SizedBox(height: 2),
              Text(text,
                  style: AppTextStyles.captionHint.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
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
  /// FIX 3 — quand `true`, le motif n'est PAS obligatoire : le bouton de
  /// confirmation reste actif même sans texte (retourne alors une chaîne vide).
  /// Utilisé pour la reprogrammation (opération courante). L'annulation, elle,
  /// garde `optional = false` (motif requis pour l'audit).
  final bool optional;
  const _ReasonDialog({
    required this.title,
    required this.hint,
    required this.confirmLabel,
    required this.confirmColor,
    this.optional = false,
  });

  /// Ouvre le sheet et retourne la raison saisie (éventuellement vide si
  /// `optional`), ou null si l'utilisateur ferme via X / Annuler.
  static Future<String?> ask(
    BuildContext context, {
    required String title,
    required String hint,
    required String confirmLabel,
    required Color confirmColor,
    bool optional = false,
  }) =>
      showAdaptiveFormSheet<String>(
        context: context,
        builder: (_) => _ReasonDialog(
          title: title,
          hint: hint,
          confirmLabel: confirmLabel,
          confirmColor: confirmColor,
          optional: optional,
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
    // FIX 3 — motif optionnel : on autorise la confirmation sans texte.
    final canConfirm = widget.optional || hasText;
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
                  hintStyle: TextStyle(
                      fontSize: 12, color: AppColors.textHint),
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.inputFill,
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Theme.of(context).semantic.borderSubtle)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Theme.of(context).semantic.borderSubtle)),
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
                  onPressed: canConfirm
                      ? () => Navigator.of(context).pop(_ctrl.text.trim())
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: widget.confirmColor,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.inputBorder,
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