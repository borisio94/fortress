import 'package:fortress/shared/widgets/app_snack.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/stock_item_service.dart';
import '../../../restaurant/presentation/widgets/courier_sheet.dart';
import '../../../restaurant/presentation/widgets/packaging_sheet.dart';
import '../../../restaurant/presentation/widgets/restaurant_checkout.dart';
import 'dart:async';

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
import '../../../../core/services/pin_service.dart';
import '../../../restaurant/domain/order_actions.dart';
import '../../../restaurant/domain/order_tile.dart';
import '../../../restaurant/domain/service_tabs.dart';
import '../../../restaurant/presentation/widgets/resto_empty_state.dart';
import '../../../restaurant/presentation/widgets/resto_amount_text.dart';
import '../../../restaurant/presentation/widgets/resto_fab.dart';
import '../../../restaurant/presentation/widgets/resto_underline_tabs.dart';
import '../../../restaurant/presentation/widgets/order_action_visuals.dart';
import '../../../restaurant/presentation/widgets/service_tab_visuals.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../shared/widgets/order_source_badge.dart';
import '../../../../shared/widgets/view_filter_chip_bar.dart';
import '../widgets/copy_delivery_message_sheet.dart';
import '../widgets/approval_closure_sheet.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/dimens.dart';
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
import '../../../restaurant/presentation/widgets/state_stripe.dart';
import '../../../../core/widgets/touch_target.dart';
import '../../../restaurant/presentation/widgets/service_settings_sheet.dart';
import '../../../restaurant/domain/service_wait.dart';
import '../../../shop_selector/domain/entities/shop_summary.dart';

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

  /// ⚠ DETTE ASSUMÉE — CET ÉCRAN DEVRAIT ÊTRE DEUX.
  ///
  /// `project_ui_separation_by_sector` pose la règle : « pas d'UI mélangée :
  /// restaurant a ses propres écrans ; on ne mutualise que données + design
  /// tokens ». Les branches `_isResto` qui suivent l'enfreignent.
  ///
  /// Elles ont été préférées à l'extraction pour UNE raison de circonstance :
  /// `caisse_page.dart` fait plus de six mille lignes et porte en permanence
  /// des travaux d'autres chantiers, ce qui impose un commit partiel à chaque
  /// lot. Y ajouter un découpage de fichier aurait rendu ce commit
  /// ingérable — pas impossible, ingérable, ce qui est pire.
  ///
  /// À EXTRAIRE quand le fichier sera propre. La carte, elle, est DÉJÀ séparée
  /// (`_buildRestoCard`) : le précédent existe, c'est le châssis de l'onglet
  /// qui reste à suivre.
  bool get _isResto => isRestaurantShop(widget.shopId);

  /// L'onglet de service courant — RESTAURATION seulement.
  ///
  /// Distinct de `_filter`, qui reste le `TabController` des six statuts en
  /// e-commerce. Les deux ne coexistent jamais à l'écran : c'est le secteur
  /// qui décide lequel s'affiche.
  ServiceTab _serviceTab = ServiceTab.toutes;

  /// Clé Hive de la préférence d'affichage.
  ///
  /// `settingsBox` et non une colonne `shops` : c'est une PRÉFÉRENCE
  /// D'APPAREIL, pas un réglage métier. La tablette du passe veut la liste
  /// dense, le téléphone du gérant veut les cartes — imposer le même choix aux
  /// deux depuis la base serait un réglage que personne n'a demandé. La boîte
  /// est d'ailleurs documentée pour ça : « préférences device : taille de
  /// texte, thème, locale ».
  ///
  /// PAS DE SUFFIXE DE BOUTIQUE, délibérément : on ne change pas de densité
  /// d'affichage parce qu'on change de boutique. C'est l'écran qu'on règle,
  /// pas l'établissement.
  static const String _viewModeKey = 'orders_view_mode';

  /// Vue GRILLE (cartes) ou LISTE (lignes denses) — restauration seulement.
  ///
  /// Grille par défaut : c'est le rendu historique, et un service qui découvre
  /// l'écran ne doit pas tomber sur une densité qu'il n'a pas demandée.
  bool _gridView = true;

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
    // Lecture SYNCHRONE : la boîte est déjà ouverte par le démarrage, et un
    // `await` ici ferait afficher la grille puis basculer en liste sous les
    // yeux de l'opérateur. Une valeur absente ou d'un autre type retombe sur
    // le défaut plutôt que de lever.
    final saved = HiveBoxes.settingsBox.get(_viewModeKey);
    if (saved is String) _gridView = saved != 'list';
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
    // LE CHRONOMÈTRE AVANCE TOUT SEUL (restauration). Sans ce battement, il
    // ne bougerait qu'à la prochaine modification d'une commande : « 3 min »
    // resterait affiché vingt minutes. Trente secondes suffisent à un
    // affichage à la minute.
    if (_isResto) {
      _chronoTick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  Timer? _chronoTick;

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
    _chronoTick?.cancel();
    AppDatabase.removeListener(_onDataChanged);
    _filter.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Pull-to-refresh : vide la file hors ligne, re-fetch toutes les tables
  /// métier depuis Supabase puis force un rebuild (le getter `_orders` relit
  /// Hive à jour).
  Future<void> _pullAndReload() async {
    await AppDatabase.refreshShopData(widget.shopId);
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

  /// Barre d'alerte unique — livraisons à traiter (en retard > 6h / à
  /// planifier) et versements partenaire en attente.
  ///
  /// Au repos : compteurs « Libellé · N », tap → feuille de détail d'où l'on
  /// active un filtre. Filtre actif : « Filtre : … · Tout voir », tap → retour
  /// à la liste complète. Le filtre versement l'emporte sur le filtre retard
  /// (cf. `orders` dans build), les deux sont donc exclusifs.
  Widget _alertBar({
    required int lateCount,
    required int unplannedCount,
    required int remitCount,
    required double remitTotal,
    required bool showLate,
    required bool showRemit,
  }) {
    final sem = Theme.of(context).semantic;
    final filtering = showLate || showRemit;
    // Couleur = alerte la plus grave présente (ou celle du filtre actif).
    final Color color = showRemit
        ? sem.info
        : showLate
            ? (lateCount > 0 ? sem.danger : sem.warning)
            : lateCount > 0
                ? sem.danger
                : unplannedCount > 0
                    ? sem.warning
                    : sem.info;
    final remitLabel =
        'Versements · $remitCount · ${CurrencyFormatter.format(remitTotal)}';
    final parts = filtering
        ? <String>[
            showRemit
                ? 'Filtre : $remitLabel'
                : 'Filtre : livraisons à traiter · '
                  '${lateCount + unplannedCount}',
          ]
        : <String>[
            if (lateCount > 0) 'En retard · $lateCount',
            if (unplannedCount > 0) 'À planifier · $unplannedCount',
            if (remitCount > 0) remitLabel,
          ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: InkWell(
        onTap: filtering
            ? () => setState(() {
                  _lateFilter  = false;
                  _remitFilter = false;
                })
            : () => _openAlertSheet(
                  lateCount:      lateCount,
                  unplannedCount: unplannedCount,
                  remitLabel:     remitCount > 0 ? remitLabel : null,
                ),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: color.withValues(alpha: filtering ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: color.withValues(alpha: filtering ? 0.6 : 0.25)),
          ),
          child: Row(children: [
            Icon(filtering
                    ? Icons.filter_alt_rounded
                    : Icons.notifications_active_rounded,
                size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                spacing: 12, runSpacing: 2,
                children: [
                  for (final p in parts)
                    Text(p,
                        style: AppTextStyles.bodySmBold.copyWith(color: color)),
                ],
              ),
            ),
            if (filtering)
              Text('Tout voir',
                  style: AppTextStyles.captionBold.copyWith(color: color)),
            Icon(filtering ? Icons.close_rounded : Icons.chevron_right_rounded,
                size: 16, color: color),
          ]),
        ),
      ),
    );
  }

  /// Feuille de détail de la barre d'alerte : une ligne par catégorie
  /// présente ; tap → active le filtre correspondant (et désactive l'autre).
  void _openAlertSheet({
    required int lateCount,
    required int unplannedCount,
    required String? remitLabel,
  }) {
    final sem = Theme.of(context).semantic;
    final lateParts = <String>[
      if (lateCount > 0) 'En retard · $lateCount',
      if (unplannedCount > 0) 'À planifier · $unplannedCount',
    ];
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
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text('À traiter', style: AppTextStyles.subtitleBold),
            ),
            if (lateParts.isNotEmpty)
              ListTile(
                leading: Icon(Icons.notifications_active_rounded,
                    color: lateCount > 0 ? sem.danger : sem.warning),
                title: Text('Livraisons à traiter',
                    style: AppTextStyles.body
                        .copyWith(color: AppColors.textPrimary)),
                subtitle: Text(lateParts.join('   '),
                    style: AppTextStyles.captionHint),
                trailing: Icon(Icons.chevron_right_rounded,
                    color: AppColors.textHint),
                onTap: () {
                  Navigator.of(ctx).pop();
                  setState(() {
                    _lateFilter  = true;
                    _remitFilter = false;
                  });
                },
              ),
            if (remitLabel != null)
              ListTile(
                leading: Icon(Icons.account_balance_wallet_rounded,
                    color: sem.info),
                title: Text('Versements partenaire en attente',
                    style: AppTextStyles.body
                        .copyWith(color: AppColors.textPrimary)),
                subtitle: Text(remitLabel, style: AppTextStyles.captionHint),
                trailing: Icon(Icons.chevron_right_rounded,
                    color: AppColors.textHint),
                onTap: () {
                  Navigator.of(ctx).pop();
                  setState(() {
                    _remitFilter = true;
                    _lateFilter  = false;
                  });
                },
              ),
            const SizedBox(height: 8),
          ],
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

  /// Mémorise la densité choisie. Sans `await` : c'est une écriture Hive
  /// locale, et son échec ne doit pas retarder un basculement d'affichage.
  void _setGridView(bool grid) {
    setState(() => _gridView = grid);
    HiveBoxes.settingsBox.put(_viewModeKey, grid ? 'grid' : 'list');
  }

  /// EN-TÊTE DE SERVICE — restauration seulement.
  ///
  /// Même recette que le tableau de bord et le Stock : un nom, puis UNE ligne
  /// comptée. Elle remplace le titre de la barre du haut, qui disait
  /// « Commandes » sans rien en dire.
  ///
  /// CE QU'ELLE COMPTE. « En cours » agrège les quatre rangs vivants — à
  /// envoyer, en préparation, à servir, à terminer — parce que c'est ce qu'un
  /// gérant veut savoir en entrant : combien de commandes ne sont pas finies.
  /// « À encaisser » reste seul, c'est de l'argent dû. Le montant est le reste
  /// à encaisser de la sélection courante, pas le chiffre d'affaires : il suit
  /// donc l'onglet et la recherche, comme tout le reste de l'écran.
  ///
  /// 14 px et 11 px : l'échelle canonique n'a ni 15 ni 9. Mêmes échelons que
  /// les en-têtes du Stock et du Menu, dont celui-ci reprend la forme.
  Widget _restoHeader(Map<ServiceTab, int> counts, double totalDue) {
    final cs = Theme.of(context).colorScheme;
    final enCours = (counts[ServiceTab.aEnvoyer] ?? 0) +
        (counts[ServiceTab.enPreparation] ?? 0) +
        (counts[ServiceTab.aServir] ?? 0) +
        (counts[ServiceTab.aTerminer] ?? 0);
    final aEncaisser = counts[ServiceTab.aEncaisser] ?? 0;
    // Les segments vides ne s'écrivent pas : « 0 en cours · 0 à encaisser »
    // occupe une ligne pour ne rien dire, et fait douter des deux autres.
    final parts = <String>[
      if (enCours > 0) '$enCours en cours',
      if (aEncaisser > 0) '$aEncaisser à encaisser',
      if (totalDue > 0) CurrencyFormatter.format(totalDue),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Commandes',
                  style: AppTextStyles.subtitle.copyWith(
                      fontWeight: FontWeight.w600, color: cs.onSurface)),
              const SizedBox(height: 2),
              Text(
                  parts.isEmpty ? 'Rien en cours' : parts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption),
            ],
          ),
        ),
        // ── Densité d'affichage ──────────────────────────────────────
        //
        // ICÔNES SEULES, deux segments. Un libellé « Grille » / « Liste »
        // doublerait le dessin sans rien apprendre, et l'en-tête n'a pas la
        // place : c'est la ligne comptée qui doit respirer, pas la bascule.
        _ViewModeToggle(
          grid: _gridView,
          onChanged: _setGridView,
        ),
        // ── Réglages du service (seuils de retard, hotfix_183) ────────
        //
        // À côté de la seule autre commande d'affichage de l'écran : on règle
        // le retard LÀ OÙ ON LE VOIT. MASQUÉE pour qui n'est pas admin — pas
        // seulement le contenu : une porte fermée qu'on voit est une
        // frustration.
        if (ref.watch(permissionsProvider(widget.shopId)).isShopAdmin) ...[
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Réglages du service',
            icon: const Icon(Icons.tune_rounded, size: 20),
            color: AppColors.textSecondary,
            onPressed: () => showServiceSettingsSheet(context, widget.shopId),
          ),
        ],
      ]),
    );
  }

  /// Onglet du TabBar : « Libellé · N » — même grammaire de compteur que la
  /// barre d'alerte. Compteur omis quand l'onglet est vide.
  Widget _tabLabel(String text, int count) =>
      Text(count > 0 ? '$text · $count' : text);

  /// Bandeau de synthèse de la sélection courante, coloré par nature :
  /// déjà encaissé (acquis, vert) et reste à encaisser (dû, ambre ; vert à
  /// zéro). Masqué quand la liste est vide (rien à résumer).
  /// UNE CARTE DE COMMANDE, par index dans la liste courante.
  ///
  /// Extrait du `itemBuilder` le 2026-09-23, sans qu'une seule ligne de rappel
  /// soit réécrite : la GRILLE avait besoin de construire une carte hors d'un
  /// `ListView`, et quinze rappels inlinés ne s'appellent pas depuis deux
  /// endroits.
  ///
  /// Les trois collections arrivent en paramètre plutôt que d'être relues :
  /// elles sont calculées une fois par build, en une passe Hive chacune, et
  /// les recalculer par carte annulerait tout le bénéfice.
  Widget _cardFor(
    int i, {
    required List<Sale> orders,
    required Map<String, PartnerDebtInfo> orderDebts,
    required Map<String, double> pendingRemit,
    bool grid = false,
    bool listWide = true,
  }) {
            final perms = ref.watch(permissionsProvider(widget.shopId));
            return _OrderCard(
            order:    orders[i],
            dense:    _isResto && !_gridView,
            grid:     grid,
            listWide: listWide,
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
                // `onConfirm` vide, et le travail APRÈS le `await` : le
                // sheet appelle `onConfirm` une fois refermé, donc tout ce
                // qu'on y mettrait tournerait sur un contexte démonté. Le
                // booléen rendu suffit, et c'est l'usage partout ici.
                final ok = await AppConfirmDialog.show(
                  context: context,
                  icon: Icons.schedule_rounded,
                  iconColor: AppColors.warning,
                  title: 'Repasser en programmée ?',
                  body: Text(
                      'La commande redeviendra « programmée » : le stock '
                      'sera restitué, le paiement remis à zéro et les '
                      'écritures partenaire liées (encaissement, frais) '
                      'seront annulées. À utiliser pour corriger une erreur '
                      'puis re-finaliser.',
                      style: AppTextStyles.bodySecondary),
                  cancelLabel: 'Annuler',
                  confirmLabel: 'Repasser en programmée',
                  confirmColor: AppColors.warning,
                  onConfirm: () {},
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
                  amountPaid:  res.amountPaidTotal,
                  // `.name` et non l'énumération : `CollectedBy` appartient à
                  // la présentation, la couche données ne doit pas l'importer.
                  collectedBy: res.collectedBy.name,
                  refusals:    res.refusals);
              // Suites de la finalisation, identiques à une complétion
              // classique (la clôture court-circuite `updateOrderStatus`
              // pour ne pas rejouer le stock, mais le VOLET FINANCIER doit
              // bien avoir lieu) : écritures du livre partenaire + frais de
              // livraison dus + rafraîchissement des stocks à l'écran.
              final fresh = _ds.getOrderById(o.id!);
              // ÉCRITURES MARCHANDISE — réservées à une vente aboutie.
              //
              // `_generatePartnerLedgerEntries` inscrit ce que le partenaire a
              // ENCAISSÉ, montant dérivé de `order.total`. Sur une tournée
              // entièrement refusée, elle créerait une créance pour de
              // l'argent que personne n'a touché.
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
              }
              // FRAIS DE LIVRAISON — dus même quand tout est refusé.
              //
              // Le partenaire a fait le trajet ; que le client ait tout rendu
              // ne le lui rembourse pas. `syncOrderDeliveryFee` ne dépend que
              // du montant qu'on lui passe, jamais des articles ni du total :
              // elle reste juste sur une commande vidée de ses lignes.
              //
              // ⚠ CAS PARTICULIER, ET NON RÈGLE GÉNÉRALE : les deux autres
              // appels de cette fonction (`sale_local_datasource.dart` dans
              // `updateOrderStatus`, et la feuille d'édition des frais plus
              // bas) restent strictement sous `completed`. Seule la clôture
              // d'une tournée « à choisir » connaît un refus total où le
              // déplacement a pourtant eu lieu.
              //
              // Le rafraîchissement des stocks suit la même porte : la
              // restitution vient de modifier les quantités.
              if (fresh != null
                  && (fresh.status == SaleStatus.completed
                      || fresh.status == SaleStatus.cancelled)) {
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
              // Journal déplacé dans `closeApprovalOrder` : il y est écrit au
              // moment où la commande change d'état, avec le détail des
              // refus. Le laisser ici en plus produirait deux entrées.
              if (mounted) setState(() {});
            },
            // Annulation d'une tournée : restaure tout le stock réservé.
            onCancelApproval: () async {
              final o = orders[i];
              await _ds.cancelApprovalOrder(o.id!,
                  reason: 'annulation tournée');
              // Journal déplacé dans `cancelApprovalOrder` — cf. clôture.
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
  }

  /// LES DEUX CHIFFRES DE LA SÉLECTION, EN DEUX CARTES.
  ///
  /// C'était un bandeau pleine largeur : deux nombres et un filet vertical au
  /// milieu d'une bande de mille pixels. Il prenait une ligne entière pour
  /// dire ce que deux cartes disent côte à côte, et il ne ressemblait à aucun
  /// autre bloc du module — le tableau de bord et le Stock comptent déjà en
  /// cartes.
  ///
  /// CHAQUE CARTE PREND LA COULEUR DE SON CHIFFRE, fond compris. Le bandeau
  /// teintait tout en accent et coloriait seulement les valeurs : on lisait
  /// deux nombres avant de comprendre lequel était un acquis et lequel une
  /// attente.
  Widget _summaryBar(double totalPaid, double totalDue) {
    final sem = Theme.of(context).semantic;
    // « Reste à encaisser » vire au vert à zéro : il n'y a plus d'attente, et
    // l'ambre d'un zéro ferait chercher un problème qui n'existe pas.
    final dueColor = totalDue > 0 ? sem.warning : sem.success;

    Widget card(IconData icon, String label, String value, Color color) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.22)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Icon(icon, size: 15, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.micro),
                  ),
                ]),
                const SizedBox(height: 4),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodyBold.copyWith(color: color)),
              ],
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(children: [
        card(Icons.check_circle_outline_rounded, 'Encaissé',
            CurrencyFormatter.format(totalPaid), sem.success),
        const SizedBox(width: 8),
        card(Icons.payments_outlined, 'Reste à encaisser',
            CurrencyFormatter.format(totalDue), dueColor),
      ]),
    );
  }

  /// LES DEUX CHIFFRES DE LA SÉLECTION — restauration.
  ///
  /// Plus de cartes, plus d'icônes : deux blocs de texte séparés par un filet
  /// vertical. Le chiffre porte la hiérarchie par sa TAILLE (`title`, 18 — le
  /// 19 de la maquette n'existe pas dans l'échelle), le libellé l'accompagne en
  /// atténué.
  ///
  /// « Reste à encaisser » garde sa teinte d'attente tant qu'il n'est pas nul :
  /// c'est l'information, pas une décoration. À zéro, il redevient du texte.
  Widget _restoSummary(double totalPaid, double totalDue) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;

    Widget block(String label, double value, Color color) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary)),
              const SizedBox(height: 2),
              RestoAmountText(value,
                  style: AppTextStyles.title
                      .copyWith(fontWeight: FontWeight.w600, color: color)),
            ],
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: IntrinsicHeight(
        child: Row(children: [
          block('Encaissé', totalPaid, cs.onSurface),
          VerticalDivider(
              width: 24, thickness: 1, color: sem.borderSubtle),
          block('Reste à encaisser', totalDue,
              totalDue > 0 ? sem.warningText : cs.onSurface),
        ]),
      ),
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
    // UNE SEULE PASSE pour les huit rangs, et sur la MÊME base filtrée que la
    // liste : un compteur qui ignorerait la recherche annoncerait des
    // commandes que l'onglet ne montrerait pas.
    final restoCounts = _isResto
        ? serviceTabCounts(_listForStatus('all', base))
        : const <ServiceTab, int>{};
    // « En retard / à planifier » : commandes programmées hors radar. Les
    // compteurs sont tirés de la liste FILTRÉE (recherche comprise) : la barre
    // annonce exactement ce que le filtre affichera.
    final lateList       = _lateUnplanned(base);
    final unplannedCount = lateList.where((o) => o.scheduledAt == null).length;
    final lateCount      = lateList.length - unplannedCount;
    final hasLate  = lateList.isNotEmpty;
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
    // Même règle que ci-dessus : compteur et total suivent la recherche.
    final remitList  = _pendingRemitList(base, pendingRemit);
    final remitCount = remitList.length;
    final remitTotal = remitList.fold<double>(
        0, (s, o) => s + (pendingRemit[o.id] ?? 0));
    final hasRemit   = remitCount > 0;
    final showRemit  = _remitFilter && hasRemit;
    // LE REGROUPEMENT DU SERVICE, en restauration seulement.
    //
    // `_listForStatus` filtre sur `o.status.name` — juste en e-commerce, où le
    // statut PORTE l'avancement. En restauration il ne bouge qu'à
    // l'encaissement : l'onglet « Programmée » contenait aussi bien une
    // commande que personne n'avait envoyée en cuisine qu'un client finissant
    // son dessert. Voir `service_tabs.dart`.
    //
    // La recherche et la fenêtre de dates restent celles de `_listForStatus` :
    // on regroupe autrement, on ne filtre pas autrement. `'all'` lui rend donc
    // la base déjà filtrée, sur laquelle le rang s'applique ensuite.
    final orders   = showRemit
        ? remitList
        : showLate
            ? lateList
            : _isResto
                ? ordersForServiceTab(
                    _serviceTab, _listForStatus('all', base))
                : _listForStatus(_filters[_filter.index].$1, base);
    final orderDebts = PartnerLedgerService.debtByOrder(
        widget.shopId, orders.map((o) => o.id).whereType<String>());
    // Synthèse de la sélection courante : déjà encaissé + reste à encaisser.
    // « Encaissé » inclut ce que le partenaire a perçu pour la boutique
    // (`amountPaid` reste au total) : le client, lui, a soldé.
    final totalPaid = orders.fold<double>(0, (s, o) => s + o.amountPaid);
    final totalDue  = orders.fold<double>(0, (s, o) => s + o.amountDue);
    final content = Column(children: [
      // ── Emplacements : Globale / Boutique / Partenaires ─────────────
      // Le filtre s'applique aux lignes via `orderToPartnerLocId` plus haut
      // dans `_orders` (cf. ref.watch(dashViewFilterProvider)).
      //
      // MASQUÉ EN RESTAURATION, et au SITE D'APPEL, pas dans le widget : il a
      // cinq appelants dont quatre e-commerce. Sans partenaire de livraison —
      // le cas d'un restaurant — la barre masque déjà « Globale » et ne laisse
      // qu'une pastille unique portant le nom de la boutique, qui ne filtre
      // rien et ne se compare à rien.
      if (!_isResto)
        ViewFilterChipBar(shopId: widget.shopId, compactPills: true),

      // ── En-tête de service (restauration) ────────────────────────────
      if (_isResto) _restoHeader(restoCounts, totalDue),

      // ── Filtres ─────────────────────────────────────────────
      //
      // `TabBar` en e-commerce. En restauration, SOULIGNÉS, plus en
      // pastilles : la hiérarchie de l'écran passe par la typographie et
      // l'espace, pas par des contours. Même widget que le Menu
      // et le Stock (`RestoUnderlineTabs`).
      if (_isResto)
        RestoUnderlineTabs(
          items: [
            for (final t in ServiceTab.ordered)
              RestoUnderlineTab(
                label: t.label,
                count: restoCounts[t] ?? 0,
                mutedWhenEmpty: t != ServiceTab.toutes,
              ),
          ],
          selected: ServiceTab.ordered.indexOf(_serviceTab),
          onSelect: (i) =>
              setState(() => _serviceTab = ServiceTab.ordered[i]),
        )
      else
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
                  counts[_filters[i].$1] ?? 0)),
          ],
        ),
      ),
      Divider(height: 1, color: Theme.of(context).semantic.borderSubtle),

      // ── Barre d'alerte unique : livraisons à traiter + versements ─────────
      // Disparaît quand tout est à zéro.
      if (hasLate || hasRemit)
        _alertBar(
          lateCount:      lateCount,
          unplannedCount: unplannedCount,
          remitCount:     remitCount,
          remitTotal:     remitTotal,
          showLate:       showLate,
          showRemit:      showRemit,
        ),

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
                    // Croix de 14 px : zone de 48 de large au doigt (lot 2).
                    // La puce fait 38 px de HAUT, et le reste : sa hauteur
                    // fixe plafonne la cible, sans débordement.
                    TouchTarget(
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
                // Même poids visuel que le bouton date au repos : l'export
                // est un outil, pas l'action principale de l'écran.
                child: Container(
                  height: 38, width: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.inputFill,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: Theme.of(context).semantic.borderSubtle),
                  ),
                  child: Icon(Icons.download_rounded,
                      size: 16, color: AppColors.textSecondary),
                ),
              ),
            ),
          ],
        ]),
      ),
      Divider(height: 1, color: Theme.of(context).semantic.borderSubtle),

      // ── Synthèse de la sélection (encaissé + reste à encaisser) ──
      if (orders.isNotEmpty) ...[
        const SizedBox(height: 8),
        // `_summaryBar` est PARTAGÉE avec l'e-commerce : on aiguille ici, au
        // site d'appel, plutôt que de la plier aux deux secteurs.
        if (_isResto)
          _restoSummary(totalPaid, totalDue)
        else
          _summaryBar(totalPaid, totalDue),
      ],

      // ── Liste commandes ──────────────────────────────────────
      Expanded(
        child: RefreshIndicator(
          onRefresh: _pullAndReload,
          child: orders.isEmpty
            ? ListView(children: [
                if (_isResto)
                  // COMPACT, et sous la barre d'onglets : le rendu plein
                  // occupait tout l'écran avec une pastille de 72 px et
                  // répétait le nom de l'onglet écrit juste au-dessus.
                  //
                  // ET IL PROPOSE UNE ACTION. Un service sans commande n'a pas
                  // besoin qu'on le lui dise, il a besoin d'un chemin pour en
                  // prendre une — et ce chemin est la carte.
                  RestoEmptyState(
                    compact: true,
                    icon: Icons.receipt_long_outlined,
                    title: _serviceTab == ServiceTab.toutes
                        ? 'Aucune commande'
                        : 'Rien dans « ${_serviceTab.label} »',
                    subtitle: _serviceTab == ServiceTab.toutes
                        ? 'Les commandes prises au Menu ou au plan de salle '
                            'arrivent ici.'
                        : 'Les autres onglets en portent peut-être.',
                    actionLabel: _serviceTab == ServiceTab.toutes
                        ? 'Prendre une commande'
                        : null,
                    onAction: _serviceTab == ServiceTab.toutes
                        ? () => context.go('/shop/${widget.shopId}/inventaire')
                        : null,
                  )
                else
                  EmptyStateWidget(
                    icon: Icons.inbox_outlined,
                    title: _filter.index == 0
                        ? 'Aucune commande'
                        : 'Aucune commande '
                            '${_filters[_filter.index].$2.toLowerCase()}',
                    subtitle:
                        'Les commandes que tu encaisses apparaîtront ici.',
                  ),
              ])
            : (_isResto && _gridView)
              // ── VRAIE GRILLE ────────────────────────────────────────
              //
              // La bascule ne changeait RIEN : « grille » rendait la même
              // colonne de cartes pleine largeur que « liste ». Deux modes
              // pour un seul rendu.
              //
              // `Wrap` ET NON `GridView`, et c'est le point technique du lot :
              // une carte de commande se DÉPLIE, donc sa hauteur varie.
              // `GridView` impose une hauteur commune à toute une rangée — la
              // carte dépliée aurait débordé, ou forcé les trois autres à sa
              // taille. `Wrap` laisse chaque tuile mesurer sa propre hauteur.
              //
              // LES COLONNES SE DÉDUISENT D'UN PLANCHER, PAS DE SEUILS.
              //
              // La première version fixait 1200 et 800 en dur, et se trompait :
              // sur un bloc de 1046 px elle rendait DEUX colonnes de 518 px
              // pour six lignes de contenu. Un seuil en pixels d'écran ne sait
              // rien de ce que la tuile doit porter.
              //
              // `kOrderTileMin` dit la largeur sous laquelle la tuile cesse de
              // parler, et `orderGridColumns` en déduit le reste — c'est ce qui
              // garantit que « Envoyer en préparation » passe à toute largeur.
              ? SingleChildScrollView(
                  // En bas : la place du bouton flottant (80 = 48 + 16 + 16,
                  // cf. `kRestoFabClearance`). Cette grille est propre à la
                  // restauration.
                  padding: const EdgeInsets.fromLTRB(
                      12, 4, 12, kRestoFabClearance),
                  child: LayoutBuilder(builder: (ctx, box) {
                    // 14 et non 10 : sans contour, c'est l'ESPACE qui sépare
                    // deux cartes.
                    const gap = 14.0;
                    final cols = orderGridColumns(box.maxWidth, gap: gap);
                    final w = (box.maxWidth - gap * (cols - 1)) / cols;
                    // DEUX SECTIONS : les terminées (encaissées, sans suite)
                    // ne se mêlent plus aux actives. « TERMINÉES » et non
                    // « encaissées aujourd'hui » : le titre doit rester vrai
                    // quel que soit le filtre de date.
                    //
                    // La case « Nouvelle commande » qui fermait la grille est
                    // remplacée par le bouton flottant (voir la fin de
                    // `build`).
                    final active = [
                      for (var i = 0; i < orders.length; i++)
                        if (!serviceTabOf(orders[i]).isSettled) i,
                    ];
                    final done = [
                      for (var i = 0; i < orders.length; i++)
                        if (serviceTabOf(orders[i]).isSettled) i,
                    ];
                    Widget tiles(List<int> ids) => Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final i in ids)
                              SizedBox(
                                  width: w,
                                  child: _cardFor(i,
                                      orders: orders,
                                      orderDebts: orderDebts,
                                      pendingRemit: pendingRemit,
                                      grid: true)),
                          ],
                        );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (active.isNotEmpty) ...[
                          const _OrdersSectionTitle('En cours'),
                          tiles(active),
                        ],
                        if (done.isNotEmpty) ...[
                          if (active.isNotEmpty) const SizedBox(height: 22),
                          const _OrdersSectionTitle('Terminées'),
                          tiles(done),
                        ],
                      ],
                    );
                  }),
                )
            : _isResto
              // ── LISTE DU RESTAURANT : colonnes ALIGNÉES (25/09/2026) ────
              //
              // Les lignes vivent dans UN panneau, séparées par un filet —
              // comme le Stock —, sous un en-tête de colonnes. Chaque ligne
              // garde son liseré d'état. Pas de sections : les actives passent
              // devant, les terminées reculent par leur fond.
              ? Builder(builder: (_) {
                  final sorted = [
                    ...orders.where((o) => !serviceTabOf(o).isSettled),
                    ...orders.where((o) => serviceTabOf(o).isSettled),
                  ];
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: RestoGlassPanel(
                      padding: EdgeInsets.zero,
                      radius: 14,
                      // UNE mesure, ici, hors des `IntrinsicHeight` des lignes
                      // (cf. `_OrderCard.listWide`) : l'en-tête et les lignes
                      // basculent ensemble.
                      child: LayoutBuilder(builder: (context, box) {
                      final wide = box.maxWidth >= kOrderListRowMin;
                      return Column(children: [
                        if (wide) const _OrdersListHeader(),
                        Expanded(
                          child: ListView.separated(
                            // En bas : la place du bouton flottant.
                            padding: const EdgeInsets.only(
                                bottom: kRestoFabClearance),
                            itemCount: sorted.length,
                            separatorBuilder: (_, __) => Divider(
                                height: 1,
                                thickness: 1,
                                color:
                                    Theme.of(context).semantic.borderSubtle),
                            itemBuilder: (_, i) => _cardFor(i,
                                orders: sorted,
                                orderDebts: orderDebts,
                                pendingRemit: pendingRemit,
                                listWide: wide),
                          ),
                        ),
                      ]);
                      }),
                    ),
                  );
                })
            : ListView.separated(
          // E-commerce : inchangé. (La restauration a sa liste, plus haut.)
          // (En restauration, cette branche est toujours la vue LISTE : la
          // grille a la sienne, plus haut.)
          padding: _isResto
              ? const EdgeInsets.fromLTRB(8, 8, 8, kRestoFabClearance)
              : const EdgeInsets.all(12),
          itemCount: orders.length,
          // EN LISTE, les lignes se touchent : un filet les separe, sans
          // espace. C'est ce qui fait la densite — huit pixels entre vingt
          // commandes, c'est un ecran de moins par service.
          separatorBuilder: (_, __) => _isResto && !_gridView
              ? const SizedBox(height: 4)
              : const SizedBox(height: 8),
          itemBuilder: (_, i) => _cardFor(i,
              orders: orders,
              orderDebts: orderDebts,
              pendingRemit: pendingRemit),
        ),
        ),
      ),
    ]);

    // LE BOUTON FLOTTANT — restauration seulement, seul appel de création de
    // l'écran (cf. `RestoFab`). MÊME DESTINATION que l'ancienne case
    // « Nouvelle commande » : la carte, où la commande se prend. Dans les DEUX
    // vues — la case n'existait qu'en grille. Masqué sur une liste vide, dont
    // l'état vide porte son propre bouton.
    //
    // En `Stack` et non en `floatingActionButton` : cet écran n'a pas
    // d'`AppScaffold` (`orders_page.dart` rend `OrdersTab` directement). Même
    // marge de 16 px, dans le corps du shell — donc au-dessus de la barre du
    // bas sur téléphone.
    if (!_isResto || orders.isEmpty) return content;
    return Stack(children: [
      content,
      Positioned(
        right: kRestoFabMargin,
        bottom: kRestoFabMargin,
        child: RestoFab(
          tooltip: 'Nouvelle commande',
          onPressed: () => context.go('/shop/${widget.shopId}/inventaire'),
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
  /// Rendu DENSE — une ligne par commande, pour un service chargé.
  ///
  /// Un drapeau plutôt qu'un second widget, et c'est délibéré : la carte porte
  /// quinze rappels de fonctions et tout le bloc de détails. Un jumeau dense
  /// aurait dupliqué ce câblage, et les deux auraient divergé au premier
  /// correctif. Seule la LIGNE RÉSUMÉ change ; le dépliement, les actions et
  /// les gardes sont exactement les mêmes objets.
  final bool dense;

  /// Rendu GRILLE — une tuile compacte, en colonnes.
  ///
  /// Troisième disposition de la même carte, et toujours pas un troisième
  /// widget : `dense` et `grid` ne changent que la LIGNE RÉSUMÉ. Le
  /// dépliement, les actions et les gardes restent les mêmes objets.
  final bool grid;

  /// Vue LISTE : la liste tient-elle ses colonnes sur une ligne ?
  ///
  /// MESURÉ PAR LA LISTE, pas par la carte, et c'est une contrainte, pas un
  /// goût : la ligne vit sous l'`IntrinsicHeight` du liseré, et Flutter refuse
  /// les dimensions intrinsèques d'un `LayoutBuilder` — la ligne ne rendait
  /// RIEN en ligne (26/09/2026). Une seule mesure sert aussi l'en-tête.
  final bool listWide;

  const _OrderCard({required this.order,
    this.dense = false,
    this.grid = false,
    this.listWide = true,
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

  /// Le rang de service de cette commande — source unique de la couleur du
  /// liseré, du mot de la pastille et de l'onglet qui la contient.
  ServiceTab get _tab => serviceTabOf(widget.order);
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
    // UI séparée par secteur : la restauration garde son rendu historique
    // (service, emballage, livreur) ; le e-commerce a sa carte hiérarchisée.
    if (_isResto) return _buildRestoCard(context);
    return _buildEcommerceCard(context);
  }

  /// Rendu historique de la carte — conservé pour la RESTAURATION.
  Widget _buildRestoCard(BuildContext context) {
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
        // EN GRILLE, PAS DE CONTOUR — MAIS UN LISERÉ (règle du 26/09/2026,
        // cf. `state_stripe.dart`). Le contour entoure la carte et la sépare
        // du fond : c'est le travail du FOND, de l'espace et de la
        // typographie, il reste interdit. Le liseré ne fait pas le tour et ne
        // sépare rien : il porte l'ÉTAT, sur un seul côté. Il est permis ici
        // parce que l'état est l'information principale de la carte ET que le
        // badge l'écrit en toutes lettres à côté.
        //
        // DEUX SURFACES, PAS UN VOILE. Soldée → surface de fond, à plat. Active
        // → surface de carte, ÉLEVÉE. L'ombre n'est pas un ornement : en clair,
        // les deux fonds ne s'écartent que de 1,07:1, et la carte blanche posée
        // sur le décor blanc n'a plus AUCUN bord (1,00:1) une fois la bordure
        // retirée. C'est l'élévation qui les lui rend.
        //
        // Le liseré ne change rien à ce calcul : découpé DANS la carte, sur le
        // seul bord gauche, il laisse les trois autres à 1,00:1 — l'ombre y
        // reste nécessaire. Une carte TERMINÉE, sans ombre, n'a plus que lui
        // pour bord.
        decoration: widget.grid
            ? BoxDecoration(
                color: _tab.isSettled
                    ? Theme.of(context).scaffoldBackgroundColor
                    : Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(14),
                boxShadow: _tab.isSettled
                    ? null
                    : [
                        BoxShadow(
                            color: Theme.of(context)
                                .shadowColor
                                .withValues(alpha: 0.07),
                            blurRadius: 12,
                            offset: const Offset(0, 3)),
                      ],
              )
            : widget.dense
                // LIGNE DE LISTE : elle vit dans le panneau de la liste, entre
                // deux filets — ni bordure, ni rayon, ni ombre. Une commande
                // terminée recule par son FOND, jamais par un voile.
                ? BoxDecoration(
                    color: _tab.isSettled
                        ? Theme.of(context).scaffoldBackgroundColor
                        : Colors.transparent,
                  )
                : BoxDecoration(
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
        // Le clip arrondit le liseré avec la carte : sans lui, il déborderait
        // des coins et la bande carrée trancherait sur la bordure arrondie.
        clipBehavior: Clip.antiAlias,
        // ── LISERÉ VERTICAL, coloré par le rang de service ────────────
        //
        // Il porte l'état à la PÉRIPHÉRIE de la carte, là où l'œil le trouve
        // en balayant une colonne — la pastille, elle, demande qu'on lise. Sur
        // vingt commandes empilées, c'est la seule information qui se perçoive
        // sans s'arrêter.
        //
        // MÊME COULEUR que l'onglet et la pastille : `serviceTabOf` est
        // l'unique source, les trois ne peuvent pas se contredire.
        //
        // LISTE ET GRILLE, MÊME GRAMMAIRE : même épaisseur (`kStateStripeWidth`,
        // celle du Plan de salle), même couleur (`stripeColor`). Une commande
        // terminée recule, son liseré aussi : `outlineVariant`, pas le gris
        // appuyé qu'elle portait (mesures dans `stripeColor`).
        //
        // ⚠ PLUSIEURS COULEURS SONT SOUS 3:1 sur leur carte, en clair :
        // « En préparation » 2,15, « À servir » 2,54 sur TOUTES les palettes,
        // « À encaisser » 2,54 à 2,80 sur emerald, ocean et sunset. Le liseré
        // n'est admissible que parce que le badge écrit l'état à côté : NE
        // RETIRE PAS LE BADGE en croyant alléger.
        //
        // `IntrinsicHeight` est le prix à payer pour qu'une bande de 4 px
        // s'étire sur une hauteur que seul son voisin détermine. Il coûte une
        // passe de mesure supplémentaire par carte — acceptable sur une liste
        // de service, à surveiller si elle devait porter des centaines de
        // lignes.
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                  width: kStateStripeWidth,
                  color: _tab.stripeColor(context)),
              Expanded(
                child: Padding(
                  // Tuile de ~92 px en grille ; ligne de ~48 px en liste.
                  padding: widget.grid
                      ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
                      : widget.dense
                          ? const EdgeInsets.symmetric(
                              horizontal: _kListPadH, vertical: 8)
                          : const EdgeInsets.all(14),
                  child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── Ligne résumé, en DENSE ───────────────────────────────
            //
            // Une seule ligne par commande sur large écran, deux sous
            // `kCartPaneFullWidthBelow` — le seuil déjà partagé avec le volet
            // panier, pour ne pas en inventer un troisième (l'app en a deux).
            //
            // LE LISERÉ COURT SUR LES DEUX LIGNES : il enveloppe tout le bloc,
            // pas la première ligne seule.
            //
            // CE QUI N'Y EST PAS, ET POURQUOI. Le brief voulait le bouton
            // d'action et le ⋮ dans la ligne. Ils n'y sont pas : en
            // restauration, le bouton de chronologie et les actions vivent
            // aujourd'hui DANS le bloc déplié, et `_showActionsSheet` — la
            // feuille qui les regrouperait — est explicitement masquée pour ce
            // secteur. Les faire remonter demande de recomposer la surface
            // d'actions de la carte, sur un écran qui n'a jamais tourné et que
            // zéro test de widget ne couvre. Le tap déplie, et tout reste
            // atteignable à un geste.
            if (widget.grid) ..._gridSummary(context)
            else if (widget.dense) ..._denseSummary(context) else
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
                      // ── LE STATUT COMMERCIAL A QUITTÉ LA CARTE ────────
                      //
                      // « Programmée » et l'état de service disaient la même
                      // chose deux fois, côte à côte — et le premier était le
                      // moins vrai des deux : il valait « Programmée » aussi
                      // bien sur une commande que personne n'avait envoyée en
                      // cuisine que sur un client finissant son dessert.
                      //
                      // RIEN N'EST PERDU : depuis le regroupement du service,
                      // `serviceTabOf` couvre TOUS les statuts — « Encaissées »
                      // pour `completed`, « Sans suite » pour annulée, refusée
                      // et remboursée. Un seul badge, et c'est le plus précis.
                      //
                      // SEULE EXCEPTION, conservée : le marqueur de
                      // reprogrammation. Il ne se déduit d'aucun drapeau de
                      // cuisine, et il dit qu'une date a été déplacée — ce que
                      // le rang de service ne saura jamais.
                      if ((widget.order.rescheduleReason ?? '').isNotEmpty)
                        Icon(Icons.event_repeat_rounded,
                            size: 12, color: color),
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
                      // LA PASTILLE DE PAIEMENT EST DESCENDUE SOUS LE MONTANT.
                      //
                      // Trois pastilles sur une ligne de huit mots : plus rien
                      // ne ressortait. Et celle-ci parlait d'argent au milieu
                      // de deux qui parlaient de service — elle appartient à
                      // la colonne du montant, pas à la ligne d'état.
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
              // Montant + état de paiement + chevron à droite.
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
                // EN TEXTE, PAS EN PASTILLE. Sous le montant, il le qualifie ;
                // dans la ligne d'état, il concurrençait deux pastilles qui
                // parlent de service. Une pastille de plus ne hiérarchise pas,
                // elle égalise.
                if (s != SaleStatus.cancelled && s != SaleStatus.refused)
                  Text(widget.order.paymentStatus.label,
                      maxLines: 1,
                      style: AppTextStyles.micro.copyWith(
                          color: widget.order.paymentStatus ==
                                  PaymentStatus.paid
                              ? sem.successText
                              : sem.warningText)),
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

            // ── L'ACTION DU SERVICE, SUR LA CARTE REPLIÉE ───────────────
            //
            // Elle vivait DANS le bloc déplié : pour faire avancer un bon, le
            // serveur devait d'abord ouvrir la carte. Un tap de plus par
            // commande, trente fois par service, sur le geste le plus fréquent
            // de l'écran.
            //
            // C'EST LE MÊME BOUTON, au même appel : `_buildServiceProgress`
            // n'est pas dupliqué, il est REMONTÉ — il a disparu du bloc déplié
            // dans le même mouvement. Sa logique, ses gardes et sa cascade sont
            // intactes.
            //
            // PAS EN MODE DENSE : la ligne y tient sur une hauteur de ligne,
            // et un bouton pleine largeur la doublerait — c'est exactement la
            // densité qu'on est venu chercher en basculant.
            // L'ACTION DU SERVICE est désormais DANS la carte repliée, en
            // ligne 3 (grille) ou dans la colonne ACTION (liste) — cf.
            // `_inlineAction`. Même cascade (`_nextStep`), mêmes gardes.

            // ── Bandeau dette enregistrée envers le partenaire ────
            // Synchronisé : `widget.debt` est calculé groupé par le parent
            // (une passe Hive) et recalculé sur tout changement ledger
            // (Realtime/local via _onDataChanged). Masqué dès que la dette
            // est compensée (encaissement/versement lié à la commande) ou
            // nulle — plus jamais statique.
            ..._partnerBanners(context),

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
                  const SizedBox(height: 6),
                  // L'IDENTITÉ DE LA COMMANDE, et rien d'autre en tête.
                  //
                  // La ligne 1 n'est PAS répétée ici : le résumé n'est jamais
                  // démonté au dépliement, il reste au-dessus. Le déplié n'a
                  // donc qu'à ajouter ce que le replié tait — l'identifiant,
                  // pour retrouver la commande dans un journal ou au
                  // téléphone, et les couverts, qui ne se déduisent ni du
                  // nombre de plats ni de la table.
                  Text(
                    [
                      '#${(widget.order.id ?? '').length > 8
                          ? widget.order.id!.substring(0, 8)
                          : widget.order.id ?? '—'}',
                      if ((widget.order.covers ?? 0) > 0)
                        '${widget.order.covers} couvert'
                            '${widget.order.covers! > 1 ? 's' : ''}',
                    ].join('  ·  '),
                    style: AppTextStyles.microSecondary,
                  ),
                  const SizedBox(height: 8),
                  Divider(height: 1, color: AppColors.inputFill),
                  const SizedBox(height: 8),

                  ..._itemsAndNotes(),

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

                  // AVANCEMENT DU SERVICE — REMONTÉ SUR LA CARTE REPLIÉE.
                  //
                  // Il n'est plus ici : l'ouvrir pour avancer un bon coûtait un
                  // tap par commande. Il reste rendu en mode DENSE, où la ligne
                  // n'a pas la place de le porter.
                  // En liste, l'action vit dans la colonne ACTION : seul le
                  // retour arrière reste ici, sous le pli.
                  if (widget.dense) ..._undoRow(),
                  // EMBALLAGE — bouton direct, au moment où il sert.
                  ..._buildPackagingAction(context, s),
                  // LIVREUR — commandes à livrer uniquement.
                  ..._buildCourierAction(context, s),

                  // ── LA SURFACE D'ACTIONS ────────────────────────────
                  //
                  // Elle était un `Row` nu de SIX contrôles au maximum : une
                  // action principale à libellé, puis jusqu'à cinq icônes de
                  // 30 px sans libellé — chiffre établi par balayage exhaustif
                  // dans `order_actions_test.dart`, pas estimé. Dans une tuile
                  // de grille de 342 px (311 utiles), « Encaisser & finaliser »
                  // à 195 px plus cinq icônes et leurs écarts font 381 px :
                  // DÉBORDEMENT de 70 px, franc, sans repli ni défilement.
                  //
                  // LA CAUSE N'ÉTAIT PAS LA DENSITÉ MAIS UNE MESURE FAUSSE :
                  // la rangée choisissait sa disposition sur
                  // `MediaQuery.size.width > 800`, c'est-à-dire la largeur de
                  // l'ÉCRAN. Dans une grille à trois colonnes sur 1070 px,
                  // elle prenait donc la branche « bureau », conçue pour une
                  // carte pleine largeur, à l'intérieur d'une tuile trois fois
                  // plus étroite. Plus rien ici ne lit la largeur d'écran.
                  ..._buildActionRow(context, s),
                  // Historique des transferts retiré : l'envoi se fait
                  // désormais manuellement via copier-coller dans WhatsApp,
                  // plus aucune trace ne transite par l'app.
                ],
              ),
            ),
          ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Blocs communs aux deux rendus ─────────────────────────────────────

  /// Bandeaux partenaire, hors zone dépliée (toujours visibles) :
  ///   * dette enregistrée envers le partenaire. Synchronisée : `widget.debt`
  ///     est calculé groupé par le parent (une passe Hive) et recalculé sur
  ///     tout changement ledger (Realtime/local via _onDataChanged). Masqué
  ///     dès que la dette est compensée ou nulle — plus jamais statique ;
  ///   * versement partenaire en attente : la commande a été livrée par un
  ///     partenaire qui a encaissé pour le compte de la boutique mais n'a pas
  ///     encore reversé (dérivé du livre partenaire). Tap → confirme et
  ///     enregistre le versement reçu.
  ///
  /// Le bandeau « Encaisser / Reste à payer » a été RETIRÉ de la carte
  /// repliée (densité).
  List<Widget> _partnerBanners(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return [
      if (widget.debt != null && widget.debt!.isOutstanding) ...[
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: sem.dangerSurface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: sem.danger.withValues(alpha: 0.2), width: 0.5),
          ),
          child: Row(children: [
            Icon(Icons.attach_money_rounded, size: 12, color: sem.danger),
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
      if ((widget.pendingRemittance ?? 0) > 0) ...[
        const SizedBox(height: 6),
        InkWell(
          onTap: () => _confirmRemitReceived(context),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.info.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: AppColors.info.withValues(alpha: 0.3), width: 0.5),
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
    ];
  }

  /// Articles (quantité + nom) puis notes de la commande.
  List<Widget> _itemsAndNotes() => [
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
        if (widget.order.notes != null) ...[
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.notes_rounded, size: 11, color: AppColors.textHint),
            const SizedBox(width: 4),
            Expanded(
              child: Text(widget.order.notes!,
                  style: AppTextStyles.micro
                      .copyWith(fontStyle: FontStyle.italic)),
            ),
          ]),
        ],
      ];

  // ─── Carte E-COMMERCE ───────────────────────────────────────────────────
  //
  // Hiérarchie : en-tête (client · ID · statut) → montants → UNE action
  // principale → actions client (à échéance) → articles & détails → actions
  // rapides en pied de carte. Aucune logique déplacée : chaque bouton appelle
  // le même callback, sous la même condition, que l'ancienne rangée d'icônes.

  Widget _buildEcommerceCard(BuildContext context) {
    final o      = widget.order;
    final s      = o.status;
    final sem    = Theme.of(context).semantic;
    final client = o.clientName ?? 'Client de passage';
    final visual = _statusVisual(s, sem);
    final money  = _collapsedMoney(sem);
    final primary = _primaryAction(context);
    final quick   = _quickActions(context);

    final meta = <Widget>[
      // Chip « À choisir sur place » — ventes d'approbation uniquement.
      if (o.isApprovalSale)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius:
                  const BorderRadius.all(Radius.circular(AppRadius.xs))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.fact_check_outlined,
                size: 10, color: AppColors.primary),
            const SizedBox(width: 3),
            Text('À choisir',
                style:
                    AppTextStyles.microBold.copyWith(color: AppColors.primary)),
          ]),
        ),
      // Pastille statut paiement (hors annulée/refusée).
      if (s != SaleStatus.cancelled && s != SaleStatus.refused)
        _PaymentStatusPill(status: o.paymentStatus),
      // Badge "Web"/"WhatsApp" si source != 'pos'.
      if (o.source != 'pos') OrderSourceBadge(source: o.source),
      Text(_formatDate(o.createdAt), style: AppTextStyles.micro),
      if (o.scheduledAt != null)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.event_rounded, size: 11, color: sem.warning),
          const SizedBox(width: 3),
          Text('Livré ${_formatDate(o.scheduledAt!)}',
              style: AppTextStyles.micro.copyWith(
                  fontWeight: FontWeight.w600, color: sem.warningText)),
        ]),
    ];

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
                  ? visual.color.withValues(alpha: 0.35)
                  : sem.borderSubtle),
          boxShadow: [BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 1. En-tête ───────────────────────────────────────────────
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _ClientAvatar(name: client, size: 36, color: sem.info),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(client,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.labelRegular.copyWith(
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 2),
                    _idAndPhoneLine(context),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _OrderStatusBadge(
                    label: _statusLabel(s),
                    icon:  visual.icon,
                    color: visual.color,
                    textColor: visual.textColor,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  // Montant de la carte repliée, coloré par état de PAIEMENT
                  // (une Complétée peut rester due) : deux montants égaux ne
                  // se confondent plus.
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    if (money.label != null) ...[
                      Text(money.label!, style: AppTextStyles.captionHint),
                      const SizedBox(width: AppSpacing.xs),
                    ],
                    Text(CurrencyFormatter.format(money.amount),
                        style: AppTextStyles.bodySmBold
                            .copyWith(color: money.color)),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: Icon(Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: _expanded ? visual.color : AppColors.textHint),
                    ),
                  ]),
                ],
              ),
            ]),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: 6, runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: meta,
              ),
            ],

            ..._partnerBanners(context),

            // ── Détails dépliés ──────────────────────────────────────────
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 220),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: AppSpacing.md),
                  // ── 2. Montants ────────────────────────────────────────
                  _OrderAmountsRow(order: o),

                  // ── 3. Action principale contextuelle ──────────────────
                  if (primary != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    _PrimaryActionTile(action: primary),
                  ],

                  // ── 4. Actions client (à échéance) ─────────────────────
                  if (_canConfirmClient()) ...[
                    const SizedBox(height: AppSpacing.md),
                    _clientActionsBlock(context),
                  ],

                  // ── Articles, notes, détails ───────────────────────────
                  const SizedBox(height: AppSpacing.md),
                  Divider(height: 0.5, thickness: 0.5, color: sem.borderSubtle),
                  const SizedBox(height: AppSpacing.sm),
                  ..._itemsAndNotes(),
                  const SizedBox(height: AppSpacing.sm),
                  // Référence + téléphone déjà dans l'en-tête → masqués ici.
                  _OrderDetailsBlock(order: o, showReference: false),

                  // ── 5. Actions rapides ─────────────────────────────────
                  if (quick.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    _QuickActionsBar(actions: quick),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Montant affiché sur la carte repliée :
  ///   * annulée / refusée / remboursée → total en gris, sans libellé ;
  ///   * rien à percevoir du client     → total en vert, « encaissé » ;
  ///   * reste dû                       → reste en ambre, « à encaisser ».
  ({double amount, Color color, String? label}) _collapsedMoney(
      AppSemanticColors sem) {
    final o = widget.order;
    if (o.status == SaleStatus.cancelled
        || o.status == SaleStatus.refused
        || o.status == SaleStatus.refunded) {
      return (amount: o.total, color: AppColors.textHint, label: null);
    }
    if (o.amountDue <= 0) {
      return (amount: o.total, color: sem.successText, label: 'encaissé');
    }
    return (amount: o.amountDue, color: sem.warningText, label: 'à encaisser');
  }

  /// Couleur, couleur de texte lisible et icône du badge de statut.
  ({Color color, Color textColor, IconData icon}) _statusVisual(
      SaleStatus s, AppSemanticColors sem) {
    return switch (s) {
      SaleStatus.scheduled => (
          color: sem.warning,
          textColor: sem.warningText,
          icon: (widget.order.rescheduleReason ?? '').isNotEmpty
              ? Icons.event_repeat_rounded
              : Icons.schedule_rounded,
        ),
      SaleStatus.processing => (
          color: sem.info,
          textColor: sem.info,
          icon: Icons.local_shipping_outlined,
        ),
      SaleStatus.completed => (
          color: sem.success,
          textColor: sem.successText,
          icon: Icons.check_rounded,
        ),
      SaleStatus.cancelled || SaleStatus.refused => (
          color: sem.danger,
          textColor: sem.dangerText,
          icon: Icons.close_rounded,
        ),
      SaleStatus.refunded => (
          color: AppColors.textSecondary,
          textColor: AppColors.textSecondary,
          icon: Icons.undo_rounded,
        ),
    };
  }

  /// « abcd1234 [copier] · 6XX XX XX XX » — l'ID tronqué se copie en entier ;
  /// le téléphone ouvre WhatsApp (même comportement que l'ancienne ligne de
  /// référence du bloc détails).
  Widget _idAndPhoneLine(BuildContext context) {
    final id    = widget.order.id ?? '';
    final phone = (widget.order.clientPhone ?? '').trim();
    return Wrap(
      spacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (id.isNotEmpty) ...[
          Text(id.length > 8 ? id.substring(0, 8) : id,
              style: AppTextStyles.captionHint),
          Tooltip(
            message: 'Copier l\'ID complet',
            child: InkWell(
              borderRadius:
                  const BorderRadius.all(Radius.circular(AppRadius.xs)),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: id));
                if (context.mounted) AppSnack.success(context, 'ID copié');
              },
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xxs),
                child: Icon(Icons.copy_rounded,
                    size: 11, color: AppColors.textHint),
              ),
            ),
          ),
        ],
        if (id.isNotEmpty && phone.isNotEmpty)
          Text('·', style: AppTextStyles.captionHint),
        if (phone.isNotEmpty)
          InkWell(
            borderRadius:
                const BorderRadius.all(Radius.circular(AppRadius.xs)),
            // Tap → WhatsApp avec le numéro (digits only ; wa.me ignore les
            // + et tirets). Sans WhatsApp, l'OS retombe sur le composeur.
            onTap: () {
              final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
              if (digits.isEmpty) return;
              openExternal('https://wa.me/$digits');
            },
            child: Text(phone,
                style: AppTextStyles.captionHint
                    .copyWith(color: AppColors.primary)),
          ),
      ],
    );
  }

  /// Action principale selon le statut — UNE seule, callbacks existants.
  /// `null` → aucune (commande terminale, ou paire « actions client » affichée
  /// à échéance, qui tient lieu d'action comme dans l'ancien rendu).
  _PrimaryOrderAction? _primaryAction(BuildContext context) {
    final o = widget.order;
    final s = o.status;
    // Tournée « à choisir sur place » : le stock est géré par
    // close/cancelApprovalOrder — jamais par la transition générique, qui
    // re-décrémenterait / restaurerait le stock à tort.
    if (o.isApprovalSale
        && (s == SaleStatus.scheduled || s == SaleStatus.processing)) {
      return _PrimaryOrderAction(
        icon: Icons.fact_check_outlined,
        title: 'Clôturer la tournée',
        subtitle: 'Réconcilier le stock gardé et rendu',
        onTap: () => _closeApproval(context),
      );
    }
    switch (s) {
      case SaleStatus.scheduled:
        if (_canConfirmClient()) return null;
        return _PrimaryOrderAction(
          icon: Icons.local_shipping_outlined,
          title: 'Démarrer la livraison',
          subtitle: 'Passer en En cours',
          onTap: () => widget.onUpdate(SaleStatus.processing),
        );
      case SaleStatus.processing:
        return _PrimaryOrderAction(
          icon: Icons.check_rounded,
          title: 'Marquer comme livrée',
          subtitle: 'Clôturer la commande',
          onTap: () => widget.onUpdate(SaleStatus.completed),
        );
      case SaleStatus.completed:
        // Vente à crédit : le solde à récupérer passe avant la facture
        // (qui reste accessible dans « Plus »).
        if (o.amountDue > 0) {
          return _PrimaryOrderAction(
            icon: Icons.payments_outlined,
            title: 'Encaisser le solde',
            subtitle: 'Reste ${CurrencyFormatter.format(o.amountDue)}',
            onTap: () => _recordAcompte(context),
          );
        }
        return _PrimaryOrderAction(
          icon: Icons.receipt_long_outlined,
          title: 'Voir la facture',
          subtitle: 'PDF ou impression',
          onTap: () => _previewBrandedInvoice(context),
        );
      case SaleStatus.cancelled:
      case SaleStatus.refused:
      case SaleStatus.refunded:
        return null;
    }
  }

  /// Paire « Validée / Annulée par le client » (commande programmée arrivée à
  /// échéance, cf. `_canConfirmClient`).
  Widget _clientActionsBlock(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: Text('ACTIONS CLIENT',
              style: AppTextStyles.micro.copyWith(letterSpacing: 0.5)),
        ),
        Container(
          decoration: BoxDecoration(
            borderRadius: AppRadius.mdR,
            border: Border.all(color: sem.borderSubtle, width: 0.5),
          ),
          child: IntrinsicHeight(
            child: Row(children: [
              Expanded(
                child: _ClientActionButton(
                  icon: Icons.check_circle_outline_rounded,
                  label: 'Validée par le client',
                  color: sem.success,
                  onTap: () => widget.onUpdate(SaleStatus.processing),
                ),
              ),
              // La moitié « Annulée » SEULEMENT est conditionnée : annuler
              // requiert salesCancel, valider non. Une validation client n'est
              // pas un geste d'annulation et reste ouverte à tout opérateur.
              // Sans la permission, le bouton DISPARAÎT au lieu de faire
              // saisir un motif pour refuser ensuite ; la garde du callback
              // parent reste la frontière qui compte.
              if (widget.canCancel) ...[
                VerticalDivider(
                    width: 0.5, thickness: 0.5, color: sem.borderSubtle),
                Expanded(
                  child: _ClientActionButton(
                    icon: Icons.cancel_outlined,
                    label: 'Annulée par le client',
                    color: sem.danger,
                    onTap: () => _askCancelReason(context),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ],
    );
  }

  /// Actions rapides du pied de carte. Chaque entrée reprend EXACTEMENT la
  /// condition de l'ancien bouton icône correspondant ; « Plus » ouvre la
  /// feuille des actions restantes.
  List<_QuickAction> _quickActions(BuildContext context) {
    final o    = widget.order;
    final s    = o.status;
    final open = s == SaleStatus.scheduled || s == SaleStatus.processing;
    final hasPhone = (o.clientPhone ?? '').trim().isNotEmpty;
    final more = _moreActions(context);
    return [
      // Rappel : icône « Relancer » (hors web) + entrée « Relancer le
      // client » de la feuille (web, avec téléphone) réunies.
      if (open && (o.source != 'web' || hasPhone))
        _QuickAction(
          icon: Icons.notifications_active_outlined,
          label: 'Rappel',
          onTap: () => _relaunchClient(context),
        ),
      // Articles figés une fois la commande complétée (frais dans « Plus »).
      if (widget.canEdit && s != SaleStatus.completed)
        _QuickAction(
          icon: Icons.edit_outlined,
          label: 'Modifier',
          onTap: () => _showEditOrder(context),
        ),
      if (s == SaleStatus.completed)
        _QuickAction(
          icon: (_sendingInvoice || _preparingInvoice)
              ? Icons.hourglass_top_rounded
              : Icons.share_outlined,
          label: 'Partager',
          tooltip: _preparingInvoice
              ? 'Préparation de la facture…'
              : 'Envoyer la facture par WhatsApp',
          onTap: (_sendingInvoice || _preparingInvoice)
              ? null
              : () => _sendInvoiceWhatsApp(context),
        )
      else if (open && _permsForOrder().canTransferDelivery)
        _QuickAction(
          icon: Icons.share_outlined,
          label: 'Partager',
          tooltip: 'Copier le message de livraison',
          onTap: () => _openCopyDeliveryMessage(context),
        ),
      // hotfix_084 : seulement si la commande est éligible (statut ouvert
      // non payé) — le use case et la RPC appliquent les mêmes règles.
      if (widget.canDelete
          && DeleteSaleUseCase.allowedStatuses.contains(s)
          && o.amountPaid <= 0)
        _QuickAction(
          icon: Icons.delete_outline_rounded,
          label: 'Supprimer',
          danger: true,
          onTap: () => _confirmDelete(context),
        ),
      if (more.isNotEmpty)
        _QuickAction(
          icon: Icons.more_horiz_rounded,
          label: 'Plus',
          onTap: () => _showActionsSheet(context, more),
        ),
    ];
  }

  /// Contenu de la feuille « Plus » : les actions contextuelles historiques
  /// (hors celles promues en actions rapides) + les icônes qui n'ont pas de
  /// place dans le pied de carte, chacune sous sa condition d'origine.
  List<_OrderActionItem> _moreActions(BuildContext context) {
    final o    = widget.order;
    final s    = o.status;
    final open = s == SaleStatus.scheduled || s == SaleStatus.processing;
    return [
      ..._contextualActions(context, quickBar: true),
      if (o.isApprovalSale && open)
        _OrderActionItem(
          icon: Icons.cancel_outlined,
          label: 'Annuler la tournée',
          color: AppColors.error,
          onTap: () => _cancelApproval(context),
        )
      else if (widget.canCancel && open && !_canConfirmClient())
        _OrderActionItem(
          icon: Icons.do_not_disturb_on_outlined,
          label: 'Annuler ou refuser',
          color: AppColors.error,
          onTap: () => _askCancelOrRefuse(context),
        ),
      // Repasser en programmée (correction / re-finalisation) — réservé
      // admin. Restitue stock + paiement + écritures partenaire.
      if (s == SaleStatus.completed && widget.canCancel)
        _OrderActionItem(
          icon: Icons.undo_rounded,
          label: 'Repasser en programmée',
          color: AppColors.warning,
          onTap: () => _reopenPaidSale(context),
        ),
      // Soldée, la facture est l'action principale ; sinon elle vit ici.
      if (s == SaleStatus.completed && o.amountDue > 0)
        _OrderActionItem(
          icon: Icons.picture_as_pdf_rounded,
          label: 'Facture (PDF avec logo)',
          color: AppColors.primary,
          onTap: () => _previewBrandedInvoice(context),
        ),
      // Frais modifiables même après complétion (souvent connus APRÈS la
      // livraison) ; sans objet sur annulée / refusée / remboursée.
      if (widget.canEdit
          && s != SaleStatus.cancelled
          && s != SaleStatus.refused
          && s != SaleStatus.refunded)
        _OrderActionItem(
          icon: Icons.local_shipping_outlined,
          label: 'Modifier les frais (livraison…)',
          color: AppColors.primary,
          onTap: () => _editFees(context),
        ),
    ];
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
  ///
  /// [quickBar] = feuille « Plus » de la carte e-commerce : « Copier message
  /// livraison » et « Relancer le client » (web) sont alors omis, puisqu'ils
  /// y ont déjà un bouton rapide (Partager / Rappel) sous la même condition.
  List<_OrderActionItem> _contextualActions(BuildContext context,
      {bool quickBar = false}) {
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
    if (!quickBar
        && !_isResto
        && (s == SaleStatus.scheduled || s == SaleStatus.processing)
        && _permsForOrder().canTransferDelivery) {
      list.add(_OrderActionItem(
          icon: Icons.content_copy_rounded,
          label: 'Copier message livraison',
          color: AppColors.whatsapp,
          onTap: () => _openCopyDeliveryMessage(context)));
    }
    if (!quickBar
        && o.source == 'web'
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

  /// LE REPÈRE d'une commande : la table et le compte, ou le client.
  ///
  /// `saveTableOrder` écrit le nom de la table dans `clientName` — c'est ce que
  /// lisent la facture et les listes — et le compte dans `tabLabel`. Les deux
  /// ensemble quand ils diffèrent : une table porte souvent plusieurs comptes,
  /// et « T4 » seul ne dit pas lequel.
  String _repere() {
    final o = widget.order;
    final base = (o.clientName ?? '').trim();
    final tab = (o.tabLabel ?? '').trim();
    if (base.isEmpty) return tab.isEmpty ? 'Client de passage' : tab;
    if (tab.isEmpty || tab == base) return base;
    return '$base · $tab';
  }

  /// L'heure de prise, sans la date : sur un écran de service, la date est
  /// toujours aujourd'hui, et l'écrire vole la place du contenu.
  String _hhmm() {
    final d = widget.order.createdAt;
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  /// Le contenu de la commande sur UNE ligne : « 2× Ndolè, 1× Jus ».
  ///
  /// La règle est partie dans `order_tile.dart` le 2026-09-23, telle quelle,
  /// pour tenir à côté de sa forme courte et passer sous test. Cet écran n'a
  /// jamais été couvert par un test de widget ; ce qu'on peut en sortir en
  /// règle pure, on le sort.
  String _contenu() => orderContentsLine(widget.order.items);

  /// Le contenu en DEMI-ligne : « 2× Ndolè + 3 autres ».
  ///
  /// La tuile de grille partage cette ligne avec le montant. Tronquer la forme
  /// longue y dirait le premier plat et rien d'autre ; le compte dit en plus la
  /// taille de la commande, pour la même largeur.
  String _contenuCourt() => orderContentsShort(widget.order.items);

  /// TUILE DE GRILLE — TROIS LIGNES, ~92 px (refonte du 25/09/2026).
  ///
  ///     Table 2  [En préparation]                    24 min  ⌄
  ///     4 couverts · 19:36 · en retard
  ///     2× Ndolè + 3 autres     12 500 F  non payée   [Prête]
  ///
  /// LIGNE 1 — le repère, l'état (badge écrit en variante TEXTE sur son fond
  /// teinté : le token suit son fond), le chronomètre à la couleur de l'état,
  /// le pli. LIGNE 2 — couverts, heure de prise, mention de retard, en `micro`
  /// atténué. LIGNE 3 — le contenu, le MONTANT (l'élément le plus lourd de la
  /// carte) et son état de paiement, puis le bouton d'action — petit, en fond
  /// teinté (`_StateButton`).
  ///
  /// LE LISERÉ D'ÉTAT, COMME EN LISTE (26/09/2026 — revient sur la décision
  /// du 25/09). Sans lui, la liste et la grille disaient le même état dans
  /// deux grammaires. La règle « la hiérarchie passe par le fond » visait les
  /// CONTOURS, qui restent interdits ; le liseré porte l'état sur un seul côté
  /// (cf. `state_stripe.dart`). Il ne vaut que parce que le badge écrit l'état
  /// en toutes lettres : la couleur ne le porte jamais seule.
  ///
  /// LE CHRONOMÈTRE mesure l'attente DANS L'ÉTAT (`service_state_at`), pas
  /// l'âge de la commande. Sans date — commande antérieure à la colonne —, il
  /// ne s'affiche pas : mieux vaut rien qu'un faux.
  ///
  /// LA LIGNE 3 TIENT, mesurée (métrique d'Inter) : le fixe fait ~250 px avec
  /// les libellés COURTS du bouton — d'où les libellés courts, le complet en
  /// infobulle. Au plancher de 480 px de tuile, le contenu garde ~200 px.
  List<Widget> _gridSummary(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final s = widget.order.status;
    final settled = _tab.isSettled;
    final paye = widget.order.paymentStatus == PaymentStatus.paid;
    final chrono = _chronoText();
    final action = _inlineAction(context, s, withIcon: true);
    final undo = _undoButton();
    return [
      // ── LIGNE 1 : qui, dans quel état, depuis combien de temps ───────
      Row(children: [
        Flexible(
          child: Text(_repere(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySmBold.copyWith(
                  color: settled ? AppColors.textSecondary : cs.onSurface)),
        ),
        const SizedBox(width: 8),
        _StateBadge(tab: _tab),
        const Spacer(),
        if (chrono != null) ...[
          const SizedBox(width: 8),
          Text(chrono,
              style: AppTextStyles.captionBold
                  .copyWith(color: _tab.textColor(context))),
        ],
        const SizedBox(width: 2),
        AnimatedRotation(
          turns: _expanded ? 0.5 : 0,
          duration: const Duration(milliseconds: 200),
          child: Icon(Icons.keyboard_arrow_down_rounded,
              size: 18, color: AppColors.textSecondary),
        ),
      ]),
      const SizedBox(height: 3),
      // ── LIGNE 2 : couverts · heure · retard ──────────────────────────
      Text(_metaLine(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.microSecondary),
      const SizedBox(height: 8),
      // ── LIGNE 3 : contenu · montant + paiement · action ──────────────
      Row(children: [
        Expanded(
          child: Text(_contenuCourt(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textSecondary)),
        ),
        const SizedBox(width: 8),
        RestoAmountText(widget.order.total,
            style: AppTextStyles.subtitle.copyWith(
                fontWeight: FontWeight.w600,
                color: settled ? AppColors.textSecondary : cs.onSurface)),
        // L'état de paiement QUALIFIE le montant : il le suit, en texte.
        if (s != SaleStatus.cancelled && s != SaleStatus.refused) ...[
          const SizedBox(width: 6),
          Text(widget.order.paymentStatus.label,
              maxLines: 1,
              style: AppTextStyles.caption.copyWith(
                  color: paye ? sem.successText : sem.warningText)),
        ],
        if (action != null) ...[const SizedBox(width: 10), action],
        if (undo != null) undo,
      ]),
    ];
  }

  /// LIGNE DE LISTE — colonnes ALIGNÉES (refonte du 25/09/2026).
  ///
  ///     TEMPS │ TABLE │ ÉTAT │ CONTENU │ MONTANT │ ACTION │ ⌄
  ///
  /// Largeurs FIXES (`_ListCols`) : chaque colonne s'aligne d'une commande à
  /// l'autre, et l'en-tête (`_OrdersListHeader`) les reprend des mêmes
  /// constantes. Sous `kOrderListRowMin` de CONTENEUR — et non d'écran : la
  /// version précédente lisait `MediaQuery`, contre la règle du document de
  /// design (§ 8) —, la ligne se replie sur deux.
  List<Widget> _denseSummary(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settled = _tab.isSettled;
    final chrono = _chronoText();
    final repere = Text(_repere(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodySmBold.copyWith(
            color: settled ? AppColors.textSecondary : cs.onSurface));
    final temps = Text(chrono ?? '',
        maxLines: 1,
        style: AppTextStyles.captionBold
            .copyWith(color: _tab.textColor(context)));
    final contenu = Text(_contenu(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.caption);
    final montant = RestoAmountText(widget.order.total,
        style: AppTextStyles.bodyBold.copyWith(
            fontWeight: FontWeight.w600,
            color: settled ? AppColors.textSecondary : cs.onSurface));
    final chevron = AnimatedRotation(
      turns: _expanded ? 0.5 : 0,
      duration: const Duration(milliseconds: 200),
      child: Icon(Icons.keyboard_arrow_down_rounded,
          size: 18, color: cs.onSurfaceVariant),
    );

    return [
      Builder(builder: (context) {
        // La largeur est celle de la LISTE, mesurée par elle : un
        // `LayoutBuilder` ici, sous l'`IntrinsicHeight` du liseré, faisait
        // lever Flutter et la ligne ne rendait rien (cf. `listWide`).
        final wide = widget.listWide;
        final action =
            _inlineAction(context, widget.order.status, withIcon: !wide);
        if (wide) {
          return Row(children: [
            SizedBox(width: _ListCols.temps, child: temps),
            const SizedBox(width: _ListCols.gap),
            SizedBox(width: _ListCols.table, child: repere),
            const SizedBox(width: _ListCols.gap),
            SizedBox(
              width: _ListCols.etat,
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: _StateBadge(tab: _tab)),
            ),
            const SizedBox(width: _ListCols.gap),
            Expanded(child: contenu),
            const SizedBox(width: _ListCols.gap),
            SizedBox(
              width: _ListCols.montant,
              child: Align(alignment: Alignment.centerRight, child: montant),
            ),
            const SizedBox(width: _ListCols.gap),
            SizedBox(
              width: _ListCols.action,
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: action ?? const SizedBox.shrink()),
            ),
            const SizedBox(width: _ListCols.gap),
            SizedBox(width: _ListCols.chevron, child: chevron),
          ]);
        }
        // DEUX lignes : qui et dans quel état en haut, ce que ça vaut et ce
        // qu'on en fait en bas.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: repere),
              if (chrono != null) ...[const SizedBox(width: 8), temps],
              const SizedBox(width: 8),
              _StateBadge(tab: _tab),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: contenu),
              const SizedBox(width: 8),
              montant,
              if (action != null) ...[const SizedBox(width: 8), action],
              const SizedBox(width: 4),
              chevron,
            ]),
          ],
        );
      }),
    ];
  }

  // ─── Chronomètre et ligne d'information ─────────────────────────────────

  /// « 24 min » — l'attente DANS L'ÉTAT, ou `null` : commande terminée (plus
  /// rien n'attend) ou sans date d'état (antérieure au 25/09/2026).
  String? _chronoText() {
    if (_tab.isSettled) return null;
    final wait = serviceWait(widget.order, DateTime.now());
    return wait == null ? null : formatServiceWait(wait);
  }

  /// En retard au regard des seuils de LA BOUTIQUE (`shops`, réglables dans
  /// « Réglages du service ») — défauts 5 / 20 / 5 si elle n'est pas en cache.
  bool _isLate() {
    if (_tab.isSettled) return false;
    final shop = LocalStorageService.getShop(widget.order.shopId);
    return isServiceLate(
      widget.order,
      DateTime.now(),
      sendMin: shop?.serviceLateSendMin ?? kServiceLateSendDefault,
      kitchenMin: shop?.serviceLateKitchenMin ?? kServiceLateKitchenDefault,
      passMin: shop?.serviceLatePassMin ?? kServiceLatePassDefault,
    );
  }

  /// « 4 couverts · 19:36 · en retard » — la ligne 2 de la tuile.
  String _metaLine() {
    final covers = widget.order.covers ?? 0;
    return [
      if (covers > 0) '$covers couvert${covers > 1 ? 's' : ''}',
      _hhmm(),
      if (_isLate()) 'en retard',
    ].join(' · ');
  }

  /// ÉTAT DE SERVICE — le même rang, le même mot et la même couleur que
  /// l'onglet qui contient cette carte.
  ///
  /// La pastille tenait sa propre cascade et son propre vocabulaire :
  /// « En préparation », « Prête », « Servie », « Terminée ». Deux problèmes,
  /// et le second est le pire :
  ///
  ///   1. un onglet nommé autrement l'aurait CONTREDITE à trois centimètres —
  ///      « À servir » au-dessus d'une carte marquée « Prête » ;
  ///   2. elle écrivait « Terminée » pour `finished` ET pour `completed`. Une
  ///      commande servie et une commande payée portaient le même mot, alors
  ///      que l'une attend encore l'argent.
  ///
  /// `serviceTabOf` tranche désormais les deux, pour l'onglet comme pour la
  /// pastille. Elles ne peuvent plus diverger : c'est le même appel.
  ///
  /// UNE COMMANDE ENCAISSÉE est traitée par son STATUT, quoi qu'en disent ses
  /// drapeaux — on ne fait pas payer un client dont l'assiette n'est pas
  /// arrivée. C'est la première marche de la cascade, et cette garantie-là est
  /// conservée telle quelle.
  ///
  /// SEUL CHANGEMENT DE COMPORTEMENT : la pastille s'affiche désormais AUSSI
  /// sur une commande pas encore envoyée en préparation (« À envoyer »), là où
  /// elle se taisait. C'est délibéré — une commande du catalogue web que
  /// personne n'a acquittée est précisément celle qu'il faut voir.
  List<Widget> _serviceStateChip() {
    if (!_isResto) return const [];
    final tab = serviceTabOf(widget.order);
    return [
      _ServiceChip(
        label: tab.label,
        icon: tab.icon,
        color: tab.color(context),
      ),
    ];
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
  ///
  /// UNE CASCADE, LUE PAR LA TUILE ET PAR LA LIGNE (25/09/2026). Elle vivait
  /// dans `_buildServiceProgress`, qui rendait tantôt un bouton large, tantôt
  /// un lien de grille. Elle est désormais ICI, une fois ; seul le RENDU vit
  /// ailleurs (`_inlineAction`). Mêmes actions, mêmes gardes, même ordre.
  ///
  /// `null` : rien à faire avancer — commande terminée (il ne reste que
  /// l'encaissement), encaissée, annulée, ou e-commerce.
  ({
    IconData icon,
    String label,
    String short,
    Future<void> Function() action,
  })? _nextStep(SaleStatus s) {
    if (!_isResto) return null;
    if (s != SaleStatus.scheduled && s != SaleStatus.processing) return null;
    final o = widget.order;
    if (!o.sentToKitchen) {
      return (
        icon: Icons.local_fire_department_rounded,
        label: 'Envoyer en préparation',
        short: 'Envoyer',
        action: () => RestaurantOrderService.sendToKitchen(o),
      );
    }
    if (o.isInKitchen) {
      return (
        icon: Icons.room_service_outlined,
        label: 'Commande prête',
        short: 'Prête',
        action: () => RestaurantOrderService.markKitchenReady(o),
      );
    }
    if (o.isWaitingService && o.orderType == 'dine_in') {
      // « Servie » n'a de sens qu'en salle : au comptoir comme en livraison,
      // remettre la commande et clore le service sont le MÊME geste — on passe
      // donc directement à « Terminée » plutôt que d'imposer deux taps pour un
      // seul évènement réel.
      return (
        icon: Icons.restaurant_rounded,
        label: 'Marquer servie',
        short: 'Servie',
        action: () => RestaurantOrderService.markServed(o),
      );
    }
    if (!o.finished) {
      // Fin du service, argent non encaissé. Le libellé nomme la réalité du
      // canal : un client attablé finit de manger, un client au comptoir
      // récupère, un client livré est livré.
      final (icon, label) = switch (o.orderType) {
        'takeaway' => (Icons.shopping_bag_outlined, 'Commande récupérée'),
        'delivery' => (Icons.local_shipping_outlined, 'Livrée au client'),
        _          => (Icons.done_all_rounded, 'Repas terminé'),
      };
      return (
        icon: icon,
        label: label,
        short: 'Terminer',
        action: () async {
          // GARDE LIVRAISON : une commande qui voyage doit être emballée. La
          // refuser ICI, au moment de la remise, plutôt qu'à l'encaissement :
          // c'est le dernier instant où le contenant est encore entre les
          // mains du restaurant.
          if (o.orderType == 'delivery' && !_hasPackaging) {
            if (mounted) {
              AppSnack.error(context,
                  'Emballez la commande avant de la remettre au livreur.');
            }
            return;
          }
          await RestaurantOrderService.markFinished(o);
        },
      );
    }
    return null;
  }

  /// LE BOUTON D'ACTION DE LA CARTE REPLIÉE — tuile (ligne 3) et ligne de
  /// liste (colonne ACTION).
  ///
  /// PETIT ET EN FOND TEINTÉ, pas en fond plein : trois boutons pleins sur un
  /// écran attirent tout le regard, alors que le MONTANT doit rester
  /// l'élément le plus lourd. Libellé COURT (« Envoyer », « Prête »…), le
  /// libellé complet en infobulle : c'est ce qui laisse ~200 px au contenu.
  ///
  /// Trois cas, dans cet ordre :
  ///   1. une étape de service à faire avancer — `_nextStep` ;
  ///   2. la commande est terminée : « Encaisser », LE MÊME
  ///      `onUpdate(completed)` que le bouton déplié — la page demande
  ///      d'abord le mode de règlement et porte le garde-fou du double
  ///      encaissement. Seulement là où ce bouton existe (`settleOffered`,
  ///      même source) ;
  ///   3. la commande est encaissée : « Facture », en NEUTRE — disponibilité
  ///      par `orderActionsFor`, exécution par `_runAction`.
  Widget? _inlineAction(BuildContext context, SaleStatus s,
      {required bool withIcon}) {
    if (!_isResto) return null;
    final step = _nextStep(s);
    if (step != null) {
      return _StateButton(
        icon: withIcon ? step.icon : null,
        label: step.short,
        tooltip: step.label,
        base: _tab.color(context),
        text: _tab.textColor(context),
        onPressed: () => _runStep(step.action),
      );
    }
    if ((s == SaleStatus.scheduled || s == SaleStatus.processing) &&
        settleOffered(_cardActions(s), isResto: _isResto)) {
      return _StateButton(
        icon: withIcon ? Icons.payments_outlined : null,
        label: 'Encaisser',
        tooltip: OrderAction.advanceStatus.label,
        base: _tab.color(context),
        text: _tab.textColor(context),
        onPressed: () => widget.onUpdate(SaleStatus.completed),
      );
    }
    if (_cardActions(s).contains(OrderAction.invoicePdf)) {
      return _StateButton(
        icon: withIcon ? Icons.print_outlined : null,
        label: 'Facture',
        tooltip: 'Facture',
        base: Theme.of(context).colorScheme.onSurfaceVariant,
        text: AppColors.textSecondary,
        onPressed: () => _runAction(context, OrderAction.invoicePdf),
      );
    }
    return null;
  }

  /// Exécute une étape de service ; une erreur s'affiche au lieu de se perdre.
  Future<void> _runStep(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) AppSnack.error(context, e.toString());
    }
  }

  /// RETOUR EN ARRIÈRE d'un cran — « Prête » cliqué par erreur renvoie le bon
  /// en préparation. Sans lui, la seule issue serait d'encaisser un plat
  /// jamais parti. Mêmes conditions et mêmes appels qu'avant la refonte.
  Widget? _undoButton() {
    final o = widget.order;
    if (_nextStep(o.status) == null || !o.kitchenReady) return null;
    return IconButton(
      icon: Icon(Icons.undo_rounded, size: 16, color: AppColors.textSecondary),
      tooltip: o.finished ? 'Rouvrir le service' : 'Renvoyer en préparation',
      visualDensity: compactUnlessTouch,
      onPressed: () => o.finished
          ? RestaurantOrderService.reopenService(o)
          : RestaurantOrderService.reopenKitchen(o),
    );
  }

  /// En liste, le retour arrière vit sous le pli — la colonne ACTION ne porte
  /// que l'étape suivante.
  List<Widget> _undoRow() {
    final undo = _undoButton();
    if (undo == null) return const [];
    return [
      Row(children: [
        undo,
        Text(widget.order.finished
                ? 'Rouvrir le service'
                : 'Renvoyer en préparation',
            style: AppTextStyles.caption),
      ]),
      const SizedBox(height: 8),
    ];
  }

  /// Les actions de CETTE carte, avec ses permissions et son contexte — les
  /// mêmes arguments que `_buildActionRow` passe à `orderActionsFor`.
  ///
  /// Les liens de la tuile de grille s'adossent à cette liste : ils ne peuvent
  /// proposer que ce que la carte dépliée propose déjà.
  List<OrderAction> _cardActions(SaleStatus s) {
    final o = widget.order;
    return orderActionsFor(
      status:           s,
      isApprovalSale:   o.isApprovalSale,
      amountDue:        o.amountDue,
      amountPaid:       o.amountPaid,
      source:           o.source,
      canCancel:        widget.canCancel,
      canEdit:          widget.canEdit,
      canDelete:        widget.canDelete,
      isResto:          _isResto,
      canConfirmClient: _canConfirmClient(),
    );
  }

  /// LES ACTIONS DE LA CARTE — trois contrôles au plus, tous nommés.
  ///
  /// L'action principale pleine largeur, puis « Facture » et « Plus
  /// d'actions » en contour. Le reste part dans une feuille qui défile, donc
  /// plus rien ne peut être coupé quelle que soit la largeur de la tuile.
  ///
  /// LA DEUXIÈME PLACE NE CHANGE JAMAIS DE SENS. Quand « Facture » n'est pas
  /// disponible — elle n'existe que sur une commande encaissée — elle reste
  /// VIDE et « Plus d'actions » prend toute la largeur. Y glisser la première
  /// action disponible ferait porter à la même place « Facture » ici et
  /// « Relancer » là : le serveur ne peut plus mémoriser où taper, et c'est le
  /// geste qu'il fait cent fois par service. Une place vide se mémorise ; une
  /// place qui change de sens, non.
  List<Widget> _buildActionRow(BuildContext context, SaleStatus s) {
    final o = widget.order;
    final acts = orderActionsFor(
      status:           s,
      isApprovalSale:   o.isApprovalSale,
      amountDue:        o.amountDue,
      amountPaid:       o.amountPaid,
      source:           o.source,
      canCancel:        widget.canCancel,
      canEdit:          widget.canEdit,
      canDelete:        widget.canDelete,
      isResto:          _isResto,
      canConfirmClient: _canConfirmClient(),
    );

    // L'ACTION PRINCIPALE GARDE SON WIDGET D'ORIGINE. `_buildStatusAction`
    // n'est ni dupliqué ni réécrit : il porte la cascade des transitions et
    // rend une pastille en lecture seule sur les états terminaux.
    final OrderAction? principale =
        acts.contains(OrderAction.closeApprovalRound)
            ? OrderAction.closeApprovalRound
            : acts.contains(OrderAction.advanceStatus)
                ? OrderAction.advanceStatus
                : null;

    final secondaires = acts.where((a) => a != principale).toList();

    return [
      if (principale == OrderAction.closeApprovalRound)
        SizedBox(
          width: double.infinity,
          child: _WideActionButton(
            icon: principale!.icon,
            label: principale.label,
            color: principale.color(context),
            filled: true,
            onPressed: () => _runAction(context, principale),
          ),
        )
      else if (principale == OrderAction.advanceStatus)
        SizedBox(width: double.infinity, child: _buildStatusAction(s))
      else
        // États terminaux : `_buildStatusAction` rend une pastille, qui n'est
        // pas une action et ne s'étire donc pas.
        Align(alignment: Alignment.centerLeft, child: _buildStatusAction(s)),
      if (secondaires.isNotEmpty) ...[
        const SizedBox(height: 6),
        Row(children: [
          if (secondaires.contains(OrderAction.invoicePdf)) ...[
            Expanded(
              child: _WideActionButton(
                icon: OrderAction.invoicePdf.icon,
                label: 'Facture',
                color: OrderAction.invoicePdf.color(context),
                onPressed: () =>
                    _runAction(context, OrderAction.invoicePdf),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: _WideActionButton(
              icon: Icons.more_horiz_rounded,
              label: "Plus d'actions",
              color: AppColors.primary,
              onPressed: () => _openActionsSheet(context, secondaires),
            ),
          ),
        ]),
      ],
    ];
  }

  /// LA FEUILLE « PLUS D'ACTIONS ».
  ///
  /// Trois règles, et elles répondent chacune à un défaut constaté :
  ///   * PLUS AUCUNE ICÔNE MUETTE. Les boutons de 30 px portaient bien un
  ///     `Tooltip`, mais un tooltip demande un survol ou un appui long : sur
  ///     une tablette en plein service, personne ne le découvre.
  ///   * LE PIN EST ANNONCÉ AVANT LE TAP, plus découvert après.
  ///   * LA FEUILLE DÉFILE — `AdaptiveFormFrame` scrolle son corps dans les
  ///     deux modes — donc aucune action ne peut plus être coupée.
  ///
  /// L'ORDRE EST CELUI DE LA RANGÉE, destructives exceptées qui descendent
  /// sous un filet. Il n'avait jamais été écrit nulle part, mais c'est celui
  /// que l'usage a fixé ; le rendre « logique » ferait chercher.
  Future<void> _openActionsSheet(
      BuildContext context, List<OrderAction> acts) async {
    // LE BADGE SE DÉCIDE SUR L'ÉTAT RÉEL DU PIN, pas sur le drapeau seul.
    // `ManagerGate.require` n'ouvre `OwnerPinDialog` que si un PIN existe ;
    // sans PIN posé il propose une création au propriétaire et laisse passer
    // un délégué. Annoncer « PIN » là où rien ne sera demandé serait aussi
    // faux que de ne pas l'annoncer là où il l'est.
    final pinPose =
        acts.any((a) => a.pinGated) && await PinService.hasPIN();
    if (!context.mounted) return;

    final o      = widget.order;
    final sem    = Theme.of(context).semantic;
    final graves = acts.where((a) => a.destructive).toList();
    final autres = acts.where((a) => !a.destructive).toList();

    final choix = await showAdaptiveFormSheet<OrderAction>(
      context: context,
      builder: (ctx) => AdaptiveFormFrame(
        title: 'Actions de la commande',
        subtitle: '${_repere()} · ${CurrencyFormatter.format(o.total)}',
        icon: Icons.more_horiz_rounded,
        body: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final a in autres) _actionTile(ctx, a, pinPose),
          if (graves.isNotEmpty) ...[
            const SizedBox(height: 6),
            Divider(height: 1, color: sem.borderSubtle),
            const SizedBox(height: 6),
            for (final a in graves) _actionTile(ctx, a, pinPose),
          ],
        ]),
      ),
    );

    if (choix == null || !context.mounted) return;
    await _runAction(context, choix);
  }

  /// Une ligne de la feuille : icône, LIBELLÉ, et le badge PIN le cas échéant.
  Widget _actionTile(BuildContext ctx, OrderAction a, bool pinPose) {
    // La facture WhatsApp reste indisponible pendant sa préparation, comme le
    // faisait son bouton — même garde, même état.
    final occupe = a == OrderAction.invoiceWhatsApp &&
        (_sendingInvoice || _preparingInvoice);
    final teinte = occupe ? AppColors.textHint : a.color(ctx);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
          occupe ? Icons.hourglass_top_rounded : a.icon,
          size: 20, color: teinte),
      title: Text(
          occupe ? 'Préparation de la facture…' : a.label,
          style: AppTextStyles.body.copyWith(color: teinte)),
      trailing: (a.pinGated && pinPose)
          ? Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                  color: Theme.of(ctx).semantic.warning,
                  borderRadius: BorderRadius.circular(6)),
              child: Text('PIN',
                  style: AppTextStyles.microBold
                      .copyWith(color: Theme.of(ctx).semantic.warningText)),
            )
          : null,
      onTap: occupe ? null : () => Navigator.of(ctx).pop(a),
    );
  }

  /// L'AIGUILLAGE — une action vers SON gestionnaire, inchangé.
  ///
  /// Aucune garde n'est déplacée ici : chaque branche appelle exactement la
  /// méthode que le bouton d'origine appelait, avec les mêmes arguments.
  Future<void> _runAction(BuildContext context, OrderAction a) async {
    switch (a) {
      case OrderAction.closeApprovalRound:
        return _closeApproval(context);
      case OrderAction.cancelApprovalRound:
        return _cancelApproval(context);
      case OrderAction.advanceStatus:
        // Jamais routée ici : elle est rendue par `_buildStatusAction`, qui
        // porte sa propre cascade de transitions.
        return;
      case OrderAction.cancelOrRefuse:
        return _askCancelOrRefuse(context);
      case OrderAction.reopenPaidSale:
        return _reopenPaidSale(context);
      case OrderAction.invoicePdf:
        return _previewBrandedInvoice(context);
      case OrderAction.invoiceWhatsApp:
        return _sendInvoiceWhatsApp(context);
      case OrderAction.collectBalance:
        return _recordAcompte(context);
      case OrderAction.relaunchClient:
        return _relaunchClient(context);
      case OrderAction.editFees:
        return _editFees(context);
      case OrderAction.editOrder:
        return _showEditOrder(context);
      case OrderAction.deleteOrder:
        return _confirmDelete(context);
    }
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
    // La pastille d'icône était dessinée à la main ici — carré de 32, fond à
    // 14 %, rayon 8. `FormSheetHeader` la dessine pour tout le monde : c'est
    // `icon` + `iconColor` qui la remplacent.
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.account_balance_wallet_outlined,
      iconColor: AppColors.info,
      title: 'Versement reçu ?',
      body: Text(
          'Confirmer la réception de '
          '${CurrencyFormatter.format(amount)} versés par le partenaire '
          'pour cette commande ? Le livre partenaire sera mis à jour.',
          style: AppTextStyles.body.copyWith(height: 1.4)),
      cancelLabel: 'Annuler',
      confirmLabel: 'Confirmer le versement',
      confirmColor: AppColors.info,
      onConfirm: () {},
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
      // SEUL des quatre à travailler dans `onConfirm`, et c'est exact ici :
      // `AppConfirmDialog` l'appelle APRÈS avoir refermé le sheet — le même
      // ordre que l'ancien dialogue écrivait à la main (`pop()` puis
      // `_openEditSheet`). La méthode reste synchrone, comme avant.
      AppConfirmDialog.show(
        context: context,
        icon: Icons.warning_amber_rounded,
        iconColor: AppColors.warning,
        title: 'Commande complétée',
        body: Text(
            'Cette commande a déjà été complétée. '
            'La modifier peut affecter la comptabilité. '
            'Continuer quand même ?',
            style: AppTextStyles.bodySecondary),
        cancelLabel: 'Annuler',
        confirmLabel: 'Modifier quand même',
        confirmColor: AppColors.warning,
        onConfirm: () => _openEditSheet(context),
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
    // Le seul des quatre qui n'avait NI fond de surface NI forme arrondie :
    // un `AlertDialog` nu, au châssis par défaut de Material. Il prend ici la
    // même carte que les trois autres.
    final confirmed = await AppConfirmDialog.show(
      context: context,
      icon: Icons.cancel_outlined,
      title: 'Annuler la tournée',
      body: Text(
          'Tous les articles réservés seront remis en stock et la commande '
          'sera annulée. Continuer ?',
          style: AppTextStyles.bodySecondary),
      cancelLabel: 'Retour',
      confirmLabel: 'Annuler la tournée',
      onConfirm: () {},
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
/// BASCULE GRILLE / LISTE — deux segments, icônes seules.
///
/// Le choix est mémorisé PAR APPAREIL (cf. `_viewModeKey`) : la tablette du
/// passe veut la liste dense, le téléphone du gérant veut les cartes.
///
/// Segment actif en fond plein, inactif transparent — même grammaire que les
/// pastilles d'onglets du Menu et du Stock, pour qu'un seul coup d'œil
/// suffise à savoir lequel est retenu.
class _ViewModeToggle extends StatelessWidget {
  final bool grid;
  final ValueChanged<bool> onChanged;

  const _ViewModeToggle({required this.grid, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;

    Widget seg(IconData icon, bool isGrid, String tooltip) {
      final on = grid == isGrid;
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: on ? null : () => onChanged(isGrid),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            // 36 dp : sous les 48 dp de Material, et c'est assumé — la bascule
            // est un réglage qu'on touche une fois par service, pas un geste
            // du parcours. L'élargir pousserait la ligne comptée hors de vue
            // sur un téléphone, ce qui coûterait plus qu'elle ne rapporte.
            width: 36,
            height: 32,
            decoration: BoxDecoration(
              color: on ? cs.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon,
                size: 17,
                color: on ? cs.onPrimary : cs.onSurfaceVariant),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg(Icons.grid_view_rounded, true, 'Cartes'),
        seg(Icons.view_list_rounded, false, 'Liste dense'),
      ]),
    );
  }
}

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
  /// Couleur imposée (carte e-commerce : bleu info). `null` → couleur
  /// déterministe dérivée du nom (rendu historique).
  final Color? color;
  const _ClientAvatar({required this.name, this.size = 20, this.color});

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
    final color = this.color ?? _color;
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

// ─── Carte commande e-commerce : briques visuelles ─────────────────────────

/// Badge de statut en haut à droite de l'en-tête : icône + libellé teintés.
class _OrderStatusBadge extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final Color textColor;
  const _OrderStatusBadge({
    required this.label,
    required this.icon,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.xs)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: AppSpacing.xs),
          Text(label,
              style: AppTextStyles.caption
                  .copyWith(fontWeight: FontWeight.w600, color: textColor)),
        ]),
      );
}

/// Ligne de 3 métriques séparées par des filets verticaux :
/// Facturé · À encaisser · Livraison (« — » sans livraison facturée).
class _OrderAmountsRow extends StatelessWidget {
  final Sale order;
  const _OrderAmountsRow({required this.order});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final delivery = order.deliveryMode == DeliveryMode.pickup
        ? 0.0
        : (order.deliveryPrice ?? 0);
    final divider =
        VerticalDivider(width: 0.5, thickness: 0.5, color: sem.borderSubtle);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: AppRadius.mdR,
      ),
      child: IntrinsicHeight(
        child: Row(children: [
          Expanded(child: _metric('Facturé',
              CurrencyFormatter.format(order.total), AppColors.primary)),
          divider,
          Expanded(child: _metric('À encaisser',
              CurrencyFormatter.format(order.amountDue),
              AppColors.textPrimary)),
          divider,
          Expanded(child: _metric('Livraison',
              delivery > 0 ? CurrencyFormatter.format(delivery) : '—',
              AppColors.textPrimary)),
        ]),
      ),
    );
  }

  Widget _metric(String label, String value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.captionHint),
          const SizedBox(height: AppSpacing.xxs),
          // Montants longs : réduits plutôt que tronqués.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                maxLines: 1,
                style: AppTextStyles.labelRegular
                    .copyWith(fontWeight: FontWeight.w500, color: color)),
          ),
        ]),
      );
}

/// Action principale contextuelle d'une commande (cf. `_primaryAction`).
class _PrimaryOrderAction {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _PrimaryOrderAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
}

/// Tuile mise en avant : carré d'icône coloré · titre + sous-titre · chevron.
class _PrimaryActionTile extends StatelessWidget {
  final _PrimaryOrderAction action;
  const _PrimaryActionTile({required this.action});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Material(
      color: sem.info.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdR,
        side: BorderSide(color: sem.info, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: action.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: 10),
          child: Row(children: [
            Container(
              width: 28, height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sem.info,
                borderRadius:
                    const BorderRadius.all(Radius.circular(AppRadius.sm)),
              ),
              child: Icon(action.icon, size: 16, color: Colors.white),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(action.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyBold
                          .copyWith(color: AppColors.textPrimary)),
                  Text(action.subtitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.captionHint),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: sem.info),
          ]),
        ),
      ),
    );
  }
}

/// Moitié de la paire « Validée / Annulée par le client ».
class _ClientActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ClientActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: AppRadius.mdR,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodySmBold.copyWith(color: color)),
              ),
            ],
          ),
        ),
      );
}

/// Entrée du pied « actions rapides ». `onTap == null` → désactivée.
class _QuickAction {
  final IconData icon;
  final String label;
  final String? tooltip;
  final bool danger;
  final VoidCallback? onTap;
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
    this.danger = false,
  });
}

/// Pied de carte : boutons icône + libellé séparés par des filets verticaux.
class _QuickActionsBar extends StatelessWidget {
  final List<_QuickAction> actions;
  const _QuickActionsBar({required this.actions});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdR,
        side: BorderSide(color: sem.borderSubtle, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0)
              VerticalDivider(
                  width: 0.5, thickness: 0.5, color: sem.borderSubtle),
            Expanded(child: _button(actions[i], sem)),
          ],
        ]),
      ),
    );
  }

  Widget _button(_QuickAction a, AppSemanticColors sem) {
    final color = a.onTap == null
        ? AppColors.textHint
        : (a.danger ? sem.danger : AppColors.textSecondary);
    return Tooltip(
      message: a.tooltip ?? a.label,
      child: InkWell(
        onTap: a.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(a.icon, size: 18, color: color),
            const SizedBox(height: AppSpacing.xxs),
            Text(a.label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.micro.copyWith(color: color)),
          ]),
        ),
      ),
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
// ═════════════════════════════════════════════════════════════════════════════
// CARTE DE COMMANDE — composants de la refonte du 25/09/2026 (restauration)
// ═════════════════════════════════════════════════════════════════════════════

/// Marge horizontale d'une LIGNE de liste, dans son panneau.
const double _kListPadH = 10;

/// LES COLONNES DE LA LISTE — une seule source pour les lignes ET l'en-tête,
/// sinon ils se décaleraient au premier réglage.
///
/// ⚠ Largeurs fixes, qui ne tiennent qu'au-dessus de `kOrderListRowMin` de
/// conteneur ; en dessous, la ligne se replie sur deux et l'en-tête se tait.
abstract final class _ListCols {
  static const double temps = 42;
  static const double table = 68;
  static const double etat = 112;
  static const double montant = 96;
  static const double action = 78;
  static const double chevron = 18;
  static const double gap = 8;
}

/// BADGE D'ÉTAT — l'état en toutes lettres, sur un fond teinté.
///
/// LE TOKEN SUIT SON FOND : le fond est la couleur de BASE de l'état à faible
/// opacité, le libellé sa variante TEXTE (`textColor`). `warning` en texte
/// sur une teinte claire ne ferait que ~2:1 — c'est l'erreur que porte encore
/// `_ServiceChip`, gardé pour la carte e-commerce.
///
/// Réserve connue, inscrite : « À encaisser » écrit en `colorScheme.primary`,
/// sous le seuil EN CLAIR sur Ocean, Emerald, Sunset, Rose et Amber tant que
/// le lot 1 côté clair n'existe pas. L'information passe : le badge écrit
/// l'état en toutes lettres.
class _StateBadge extends StatelessWidget {
  final ServiceTab tab;
  const _StateBadge({required this.tab});

  @override
  Widget build(BuildContext context) {
    final fg = tab.textColor(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: tab.color(context).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(tab.icon, size: 11, color: fg),
        const SizedBox(width: 4),
        Flexible(
          child: Text(tab.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.microBold.copyWith(color: fg)),
        ),
      ]),
    );
  }
}

/// BOUTON D'ACTION DE LA CARTE — petit, en fond teinté.
///
/// 28 px DE DESSIN, pas de cible : `tapTargetSize` adaptatif (lot 2, cf.
/// `touch_target.dart`) — 28 px à la souris, une zone de 48 px au doigt, et la
/// carte grandit d'autant sur un téléphone. Fond de l'état à faible opacité,
/// bordure du même état, libellé en variante texte.
class _StateButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final String tooltip;
  final Color base;
  final Color text;
  final VoidCallback onPressed;

  const _StateButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.base,
    required this.text,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      tapTargetSize: adaptiveTapTargetSize,
      visualDensity: VisualDensity.standard,
      backgroundColor: base.withValues(alpha: 0.10),
      foregroundColor: text,
      side: BorderSide(color: base.withValues(alpha: 0.35)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: AppTextStyles.bodySmBold,
    );
    final labelText = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    return Tooltip(
      message: tooltip,
      child: icon == null
          ? TextButton(onPressed: onPressed, style: style, child: labelText)
          : TextButton.icon(
              onPressed: onPressed,
              style: style,
              icon: Icon(icon, size: 15),
              label: labelText,
            ),
    );
  }
}

/// Titre de section de la grille — « EN COURS », « TERMINÉES » : `micro` en
/// capitales espacées (l'échelle n'a pas de 9 px ; cf. document de design,
/// § 5).
class _OrdersSectionTitle extends StatelessWidget {
  final String text;
  const _OrdersSectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Text(text.toUpperCase(),
            style: AppTextStyles.microBold.copyWith(letterSpacing: 0.8)),
      );
}

/// EN-TÊTE DE COLONNES de la liste — `micro` espacé (on demandait 8 px :
/// l'échelle commence à 10). Mêmes largeurs que les lignes (`_ListCols`) ;
/// la liste ne le pose que quand ses lignes tiennent sur une (même mesure
/// qu'elles, cf. `_OrderCard.listWide`).
class _OrdersListHeader extends StatelessWidget {
  const _OrdersListHeader();

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyles.microBold.copyWith(letterSpacing: 0.8);
    Widget col(double w, String t, {bool right = false}) => SizedBox(
          width: w,
          child: Text(t,
              maxLines: 1,
              textAlign: right ? TextAlign.right : TextAlign.left,
              style: style),
        );
    return Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              kStateStripeWidth + _kListPadH, 10, _kListPadH, 8),
          child: Row(children: [
            col(_ListCols.temps, 'TEMPS'),
            const SizedBox(width: _ListCols.gap),
            col(_ListCols.table, 'TABLE'),
            const SizedBox(width: _ListCols.gap),
            col(_ListCols.etat, 'ÉTAT'),
            const SizedBox(width: _ListCols.gap),
            Expanded(child: Text('CONTENU', maxLines: 1, style: style)),
            const SizedBox(width: _ListCols.gap),
            col(_ListCols.montant, 'MONTANT', right: true),
            const SizedBox(width: _ListCols.gap),
            col(_ListCols.action, 'ACTION'),
            const SizedBox(width: _ListCols.gap),
            const SizedBox(width: _ListCols.chevron),
          ]),
        ),
        Divider(
            height: 1,
            thickness: 1,
            color: Theme.of(context).semantic.borderSubtle),
      ]);
  }
}

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

// ─── Détails complets d'une commande (paiement, livraison, finance) ─────────
class _OrderDetailsBlock extends StatelessWidget {
  final Sale order;
  /// `false` sur la carte e-commerce : ID et téléphone y sont déjà dans
  /// l'en-tête.
  final bool showReference;
  const _OrderDetailsBlock({required this.order, this.showReference = true});

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
        if (showReference) ...[
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