import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/danger_action_service.dart';
import '../../../../core/services/export_models.dart';
import '../../../../core/services/export_service.dart';
import '../../../../shared/widgets/export_scope_selector.dart';
import '../../data/exports/products_export_source.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/app_switch.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../../../shared/widgets/view_filter_chip_bar.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/database/app_database.dart';
import '../../../../features/dashboard/data/dashboard_providers.dart';
import '../../domain/entities/stock_location.dart';
import '../../domain/stock_at_location.dart' as stock_loc;
import '../../../../core/services/activity_log_service.dart';
import '../../../../shared/widgets/upload_status_dot.dart';
import '../../../../core/services/stock_service.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import 'product_form_page.dart' show ProductFormExtra;
import '../../../../core/services/document_service.dart';
import '../../../../core/services/external_launcher.dart';
import '../../../../core/services/short_link_service.dart';
import '../../../../core/services/url_shortener_service.dart';
import '../../../../core/services/whatsapp/message_templates.dart';
import '../../../../core/services/whatsapp_service.dart';
import '../widgets/recipient_picker_sheet.dart';
import '../widgets/share_catalog_dialog.dart';
import '../widgets/adjust_stock_dialog.dart';
import '../widgets/delete_product_dialog.dart';
import '../../domain/usecases/delete_product_usecase.dart';
import '../../../../shared/widgets/blocked_delete_dialog.dart';
import '../../../parametres/presentation/widgets/transfer_form_sheet.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../../subscription/presentation/widgets/subscription_guard.dart';
import '../widgets/arrival_sheet.dart';

// ─── Helpers stock par location (filtre dashboard) ──────────────────────────
//
// Résolvent le `dashViewFilterProvider` (`null` / `'_base'` / `<loc_id>`)
// vers une liste d'`location_id` à considérer pour le calcul de stock /
// filtrage. Utilisé pour aligner l'affichage de la page Inventaire sur la
// vue choisie au dashboard, comme on le fait déjà pour la caisse.
List<String>? _resolveLocationIds(String? viewFilter, String shopId) {
  if (viewFilter == null) {
    // Globale : tous les emplacements de l'owner — boutique(s) type='shop'
    // rattachée(s) au shop courant + partenaires actifs du même owner.
    // Permet à `_stockAtLocations` de SOMMER boutique + partenaires plutôt
    // que retomber sur `p.totalStock` qui ne lit que la boutique.
    final shop = LocalStorageService.getShop(shopId);
    final ownerId = shop?.ownerId;
    final ids = <String>[];
    for (final raw in HiveBoxes.stockLocationsBox.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
        if (!loc.isActive) continue;
        final isShopLoc = loc.shopId == shopId
            && loc.type == StockLocationType.shop;
        final isOwnerPartner = ownerId != null
            && loc.ownerId == ownerId
            && loc.type == StockLocationType.partner;
        if (isShopLoc || isOwnerPartner) ids.add(loc.id);
      } catch (_) {/* skip */}
    }
    return ids.isEmpty ? null : ids;
  }
  if (viewFilter == '_base') {
    final ids = <String>[];
    for (final raw in HiveBoxes.stockLocationsBox.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
        if (loc.shopId == shopId
            && loc.type == StockLocationType.shop
            && loc.isActive) {
          ids.add(loc.id);
        }
      } catch (_) {/* skip */}
    }
    return ids;
  }
  return [viewFilter];
}

/// Stock total d'un produit calculé sur les `location_ids` fournis.
/// Si la liste est vide ou null → on retombe sur `product.totalStock`.
int _stockAtLocations(Product p, List<String>? locationIds) {
  if (locationIds == null || locationIds.isEmpty) return p.totalStock;
  if (p.variants.isEmpty) return 0;
  var total = 0;
  for (final v in p.variants) {
    final id = v.id;
    if (id == null) continue;
    for (final locId in locationIds) {
      total += AppDatabase.getStockLevel(id, locId)?.stockAvailable ?? 0;
    }
  }
  return total;
}

/// Reproduit la règle `Product.isLowStock` mais sur le stock filtré par
/// location. Renvoie `true` si stock filtré ∈ ]0, stockMinAlert].
bool _isLowStockAt(Product p, List<String>? locationIds) {
  // Un brouillon n'est pas au catalogue : il ne doit pas déclencher d'alerte
  // de stock. Répété ici car la branche « emplacement filtré » ci-dessous
  // recalcule le seuil sans repasser par `Product.isLowStock`.
  if (p.isDraft) return false;
  if (locationIds == null) return p.isLowStock;
  final s = _stockAtLocations(p, locationIds);
  return s > 0 && s <= p.stockMinAlert;
}

class InventairePage extends ConsumerStatefulWidget {
  final String shopId;
  const InventairePage({super.key, required this.shopId});
  @override ConsumerState<InventairePage> createState() => _InventairePageState();
}

class _InventairePageState extends ConsumerState<InventairePage>
    with WidgetsBindingObserver {
  List<Product> _products = [];
  bool _isSyncing = false;
  String _query   = '';
  String _sort    = 'name';
  int    _page    = 1;
  int    _perPage = 10;
  final _sortKey  = GlobalKey(); // ← déclaré dans le State, pas dans build()

  // Mode sélection multiple (partage)
  bool _selectMode = false;
  final Set<String> _selected = {};
  bool _creatingCatalogue = false;

  // Filtre actif par chip. Défaut « all » : ne JAMAIS masquer les produits en
  // rupture à l'ouverture (sinon on croit le produit supprimé / introuvable
  // quand on veut justement le réapprovisionner).
  String _activeChip = 'all'; // all | active | inactive | low_stock | no_price | stock

  // Filtres catégorie / marque
  Set<String> _filterCategories  = {};
  Set<String> _filterBrands      = {};
  List<String> _availableCategories = [];
  List<String> _availableBrands     = [];

  bool _wasActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 1. Hive immédiat — afficher ce qui est en cache
    _load();
    // 2. Sync Supabase — toujours, à chaque montage (silencieux si Hive non vide)
    _syncFromSupabase();
    // Realtime : l'abonnement au shop est centralisé dans AppScaffold,
    // plus besoin de le déclencher ici. On garde juste le listener qui
    // rebuild la page quand un event arrive.
    AppDatabase.addListener(_onRealtimeChange);
    // Les comptes-à-rebours promo ont leur propre timer interne
    // (_PromoCountdown), donc pas besoin d'un rebuild global.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _listenToRouter();
    });
  }

  void _listenToRouter() {
    final router = GoRouter.of(context);
    router.routerDelegate.addListener(_onRouteChange);
  }

  void _onRouteChange() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        final location = GoRouterState.of(context).matchedLocation;
        final isNow = location.contains('/inventaire') &&
            !location.contains('/inventaire/product');
        // Recharger à chaque fois qu'on ARRIVE sur inventaire
        // (qu'on vienne du dashboard, hub, shops, ou autre page)
        if (isNow && !_wasActive) {
          _load();             // Hive immédiat
          _syncFromSupabase(); // Supabase silencieux
        }
        _wasActive = isNow;
      } catch (_) {}
    });
  }

  /// Appelé quand l'app revient au premier plan (depuis background)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _load();
      _syncFromSupabase();
    }
  }

  /// Appelé à chaque rebuild de la route (retour depuis une autre page)
  @override
  void didUpdateWidget(InventairePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shopId != widget.shopId) {
      // Changement de boutique → AppScaffold gère la subscription realtime.
      // Ici on force juste un recharge + sync.
      _load();
      _syncFromSupabase();
    } else {
      // Même boutique mais widget reconstruit (retour depuis hub/shops)
      // → recharger depuis Hive immédiatement
      _load();
    }
  }

  void _onRealtimeChange(String table, String shopId) {
    if (shopId != widget.shopId || !mounted) return;
    // Retour à la page 1 pour que les nouveaux produits (insérés en début
    // de liste après tri) soient immédiatement visibles. Reset aussi les
    // filtres de catégorie/marque qui pourraient masquer un nouveau
    // produit dont la catégorie n'est pas dans la sélection.
    setState(() {
      _page = 1;
      _filterCategories = {};
      _filterBrands = {};
    });
    _load();
  }

  /// Sync depuis Supabase → Hive → rebuild UI
  /// Overlay visible SEULEMENT si Hive est vide (premier chargement)
  /// Sinon : sync silencieuse en arrière-plan
  Future<void> _syncFromSupabase({bool force = false}) async {
    if (!mounted) return;

    // Offline-first strict : l'indicateur de sync ne se montre que si Hive
    // n'a VRAIMENT rien à afficher. Sinon la liste est déjà rendue depuis
    // Hive et la sync se fait silencieusement en arrière-plan.
    final hiveEmpty = LocalStorageService.getProductsForShop(widget.shopId).isEmpty;
    if (hiveEmpty || force) setState(() => _isSyncing = true);

    try {
      debugPrint('[Inventaire] Sync start shopId=' + widget.shopId);
      await AppDatabase.syncProducts(widget.shopId);
      await AppDatabase.syncMetadata(widget.shopId);
      if (mounted) {
        _load();
        debugPrint('[Inventaire] Sync done → ' + _products.length.toString() + ' produits');
        // Si toujours vide après sync, log avertissement
        if (_products.isEmpty) {
          debugPrint('[Inventaire] ! 0 produits pour shopId=' + widget.shopId);
          final allInHive = HiveBoxes.productsBox.values.length;
          debugPrint('[Inventaire] Total Hive: ' + allInHive.toString());
        }
      }
    } catch (e, st) {
      debugPrint('[Inventaire] sync error: $e\n$st');
    } finally {
      if (mounted && _isSyncing) setState(() => _isSyncing = false);
    }
  }

  /// Pull-to-refresh : re-fetch toutes les tables métier depuis Supabase,
  /// puis recharge la vue depuis Hive.
  Future<void> _pullAndReload() async {
    await AppDatabase.pullAllForShop(widget.shopId);
    if (mounted) _load();
  }

  void _load() => setState(() {
    _products = LocalStorageService.getProductsForShop(widget.shopId);
    final savedCats   = LocalStorageService.getCategories(widget.shopId);
    final savedBrands = LocalStorageService.getBrands(widget.shopId);
    final prodCats    = _products.map((p) => p.categoryId).whereType<String>().toSet();
    final prodBrands  = _products.map((p) => p.brand).whereType<String>().toSet();
    _availableCategories = {...savedCats,   ...prodCats  }.toList()..sort();
    _availableBrands     = {...savedBrands, ...prodBrands}.toList()..sort();
  });

  // ── Stats ──────────────────────────────────────────────────────────────────
  // (Compteurs supprimés round 12 — les filtres status sont désormais
  // accessibles via le popup _StatusFilterPopupBtn, plus de cards KPI.)

  /// Locations résolues par le `dashViewFilterProvider` au build courant.
  /// `null` = vue Globale (cumul). Liste vide = '_base' sans match (rare).
  /// Toutes les méthodes qui calculent stock/lowStock/tri lisent ce champ —
  /// il est rafraîchi en tête de chaque `build`.
  List<String>? _locIds;

  /// `true` si la vue active est un partenaire spécifique (pas Globale ni
  /// Boutique seule). Utilisé par `_filtered` pour masquer les produits
  /// qui n'existent pas chez ce partenaire (stock 0).
  bool _isPartnerView = false;

  // ── Liste filtrée ──────────────────────────────────────────────────────────
  // Le filtre `dashViewFilterProvider` (vue Globale / boutique seule /
  // partenaire) est résolu en `_locIds` qui pilote :
  //   * la chip "low_stock" → recalcule le seuil au périmètre choisi.
  //   * le tri/affichage stock → utilise `_stockAtLocations` au lieu de
  //     `totalStock` quand `_locIds` est non-null.
  List<Product> get _filtered {
    final locIds = _locIds;
    var list = List<Product>.from(_products);
    // Vue Partenaire : on n'affiche que les produits qui existent réellement
    // chez ce partenaire (stock > 0). En vue Globale (`null`) ou Boutique
    // seule (`'_base'`), on affiche tout — utile pour identifier les
    // ruptures à réapprovisionner. Lit le filter via `_isPartnerView`
    // (calculé dans build) pour éviter un read direct du provider ici.
    if (_isPartnerView) {
      list = list.where((p) => _stockAtLocations(p, locIds) > 0).toList();
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list.where((p) =>
      p.name.toLowerCase().contains(q) ||
          (p.sku ?? '').toLowerCase().contains(q) ||
          (p.categoryId ?? '').toLowerCase().contains(q)).toList();
    }
    int stockOf(Product p) => _stockAtLocations(p, locIds);
    switch (_activeChip) {
      case 'active':    list = list.where((p) => p.isActive).toList();
      case 'inactive':  list = list.where((p) => !p.isActive).toList();
      case 'low_stock': list = list.where((p) => _isLowStockAt(p, locIds)).toList();
      case 'no_price':  list = list.where((p) => p.priceSellPos == 0).toList();
      // Chip "Disponible" — filtre les produits avec stock > 0 dans le
      // périmètre courant. (Le tri par stock reste accessible via _sort.)
      case 'stock':     list = list.where((p) => stockOf(p) > 0).toList();
    }
    if (_filterCategories.isNotEmpty) {
      list = list.where((p) =>
      p.categoryId != null && _filterCategories.contains(p.categoryId)).toList();
    }
    if (_filterBrands.isNotEmpty) {
      list = list.where((p) =>
      p.brand != null && _filterBrands.contains(p.brand)).toList();
    }
    list.sort((a, b) => switch (_sort) {
      'stock' => stockOf(b).compareTo(stockOf(a)),
      'price' => b.priceSellPos.compareTo(a.priceSellPos),
      _       => a.name.compareTo(b.name),
    });
    return list;
  }

  List<Product> get _pageItems {
    final f = _filtered;
    final s = (_page - 1) * _perPage;
    final e = (s + _perPage).clamp(0, f.length);
    return s >= f.length ? [] : f.sublist(s, e);
  }
  int get _totalPages => (_filtered.length / _perPage).ceil().clamp(1, 999);

  /// Stock disponible total des produits actuellement **filtrés** au
  /// périmètre courant (boutique cumul / boutique seule / partenaire).
  /// Se recalcule à chaque setState ou changement de
  /// `dashViewFilterProvider`.
  int _totalAvailableStock() {
    var total = 0;
    for (final p in _filtered) {
      total += _stockAtLocations(p, _locIds);
    }
    return total;
  }

  /// Construit le snapshot `productId|<idx> → stock` (variantes) ou
  /// `productId → stock` (produit sans variante réelle) filtré par la
  /// vue active (`_locIds`).
  ///
  /// Choix de la clé `pid|<idx>` plutôt que `pid|<variantId>` : les IDs
  /// de variantes peuvent diverger entre le Hive local et le JSONB
  /// Supabase (cas de produits créés sur un autre device, ou variantes
  /// sans id). L'index dans la liste **filtrée** (`realVariants` =
  /// variantes avec nom non vide) est stable car JSONB preserve
  /// l'ordre d'insertion ET on applique le même filtre côté
  /// `catalogue_page._load()`.
  Map<String, int> _buildStockSnapshot(List<Product> products) =>
      _buildStockSnapshotForLocs(products, _locIds);

  /// Variante explicite : construit le snapshot pour un périmètre
  /// d'emplacements DONNÉ (au lieu de la vue active `_locIds`). Utilisé par
  /// le partage « Par emplacement » qui cible un emplacement précis choisi
  /// dans le dialogue, indépendamment du filtre de vue courant.
  Map<String, int> _buildStockSnapshotForLocs(
      List<Product> products, List<String>? locIds) {
    final m = <String, int>{};
    for (final p in products) {
      final pid = p.id;
      if (pid == null) continue;
      final realVariants = p.variants
          .where((v) => v.name.trim().isNotEmpty)
          .toList();
      if (realVariants.length <= 1) {
        m[pid] = stock_loc.stockAtLocations(p, locIds);
      } else {
        for (int i = 0; i < realVariants.length; i++) {
          m['$pid|$i'] =
              stock_loc.stockForVariantAtLocations(realVariants[i], locIds);
        }
      }
    }
    return m;
  }

  /// Répartit une dépense (transport, douane…) sur les produits cochés.
  /// Aucune entrée de stock : seul le prix de revient est corrigé.
  Future<void> _openFeesForSelection() async {
    final ok = await showArrivalSheet(
      context,
      shopId: widget.shopId,
      mode: ArrivalSheetMode.costOnly,
      preselectedIds: Set<String>.from(_selected),
      lockMode: true,
    );
    if (ok != true || !mounted) return;
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
    _load();
    AppSnack.success(context, 'Frais imputés — prix de revient mis à jour');
  }

  /// Helper : check le quota produits avant de naviguer vers le formulaire
  /// de création. Si limite atteinte → UpgradeSheet avec plan recommandé.
  Future<void> _handleCreateProductTap() async {
    final container = ProviderScope.containerOf(context, listen: false);
    final plan = container.read(currentPlanProvider);
    final count = LocalStorageService.getProductsForShop(widget.shopId).length;
    if (!plan.canAddProduct(count)) {
      UpgradeSheet.showQuota(context,
          label:    context.l10n.navInventaire,
          current:  count,
          max:      plan.maxProducts);
      return;
    }
    if (!mounted) return;
    final mode = await _askCreationMode();
    if (mode == null) return;
    // `mounted` (celui du State) et non `context.mounted` : dans une méthode
    // de State, c'est le garde que l'analyseur rattache au contexte — c'est
    // aussi la forme employée par le reste du fichier.
    if (!mounted) return;
    await context.push(mode == 'quick'
        ? '/shop/${widget.shopId}/inventaire/quick-add'
        : '/shop/${widget.shopId}/inventaire/product');
    _load(); _syncFromSupabase();
  }

  /// Deux façons de créer, proposées AVANT d'ouvrir quoi que ce soit :
  /// atterrir dans un assistant en trois étapes pour saisir un nom et un
  /// prix décourage, alors que la fiche complète reste indispensable dès
  /// qu'il y a des variantes ou un fournisseur.
  Future<String?> _askCreationMode() => showFormSheet<String>(
    context: context,
    builder: (dc) => SafeArea(
      top: false,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const FormSheetHeader(
            title: 'Nouveau produit', icon: Icons.add_box_outlined),
        Divider(height: 1, color: Theme.of(dc).semantic.borderSubtle),
        ListTile(
          leading: Icon(Icons.bolt_rounded, size: 22, color: AppColors.primary),
          title: const Text('Création rapide'),
          subtitle: Text('Nom, prix, stock, photo',
              style: AppTextStyles.micro),
          onTap: () => Navigator.of(dc).pop('quick'),
        ),
        ListTile(
          leading: Icon(Icons.list_alt_rounded,
              size: 22, color: AppColors.textSecondary),
          title: const Text('Formulaire complet'),
          subtitle: Text('Variantes, TVA, fournisseur, dépenses',
              style: AppTextStyles.micro),
          onTap: () => Navigator.of(dc).pop('full'),
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );

  /// Duplique un produit : même fiche, stock remis à zéro, SKU libres.
  ///
  /// Un catalogue contient presque toujours des articles très proches, et
  /// il fallait jusqu'ici tout resaisir. La copie part à stock zéro —
  /// dupliquer une fiche ne fait pas apparaître de marchandise — puis
  /// s'ouvre aussitôt pour être ajustée.
  Future<void> _duplicateProduct(Product original) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final plan  = container.read(currentPlanProvider);
    final count = LocalStorageService.getProductsForShop(widget.shopId).length;
    // Dupliquer crée un produit : sans ce contrôle, on contournerait le
    // quota de l'abonnement par le menu contextuel.
    if (!plan.canAddProduct(count)) {
      UpgradeSheet.showQuota(context,
          label:   context.l10n.navInventaire,
          current: count,
          max:     plan.maxProducts);
      return;
    }

    // SKU déjà pris dans la boutique : le contrôle d'unicité de
    // `saveProduct` refuserait la copie. On cherche le premier suffixe
    // LIBRE plutôt qu'un « -2 » fixe, qui échouerait dès la 2ᵉ copie.
    final taken = <String>{};
    for (final p in LocalStorageService.getProductsForShop(widget.shopId)) {
      for (final v in p.variants) {
        final s = v.sku?.trim().toLowerCase();
        if (s != null && s.isNotEmpty) taken.add(s);
      }
    }
    String freeSku(String? base) {
      final root = (base ?? '').trim();
      if (root.isEmpty) return '';
      for (var n = 2; n < 100; n++) {
        final candidate = '$root-$n';
        if (taken.add(candidate.toLowerCase())) return candidate;
      }
      return '$root-${DateTime.now().millisecondsSinceEpoch}';
    }

    final now = DateTime.now();
    final copy = Product(
      id:            'prod_${now.microsecondsSinceEpoch}',
      storeId:       widget.shopId,
      categoryId:    original.categoryId,
      brand:         original.brand,
      name:          '${original.name} (copie)',
      description:   original.description,
      priceBuy:      original.priceBuy,
      priceSellPos:  original.priceSellPos,
      priceSellWeb:  original.priceSellWeb,
      taxRate:       original.taxRate,
      stockQty:      0,
      stockMinAlert: original.stockMinAlert,
      isActive:      original.isActive,
      isVisibleWeb:  original.isVisibleWeb,
      trackStock:    original.trackStock,
      imageUrl:      original.imageUrl,
      rating:        0,
      createdAt:     now,
      // Ni dépenses ni promotion : les premières se rapportent à un lot
      // d'achat précis que la copie n'a pas (elle part à stock zéro), la
      // seconde est une opération datée propre au produit d'origine.
      variants: [
        for (var i = 0; i < original.variants.length; i++)
          ProductVariant(
            id:      'var_${now.microsecondsSinceEpoch}_$i',
            name:    original.variants[i].name,
            sku:     freeSku(original.variants[i].sku),
            // Un code-barres identifie un article unique dans le monde
            // réel : le recopier ferait répondre deux fiches au scan.
            supplier:      original.variants[i].supplier,
            supplierRef:   original.variants[i].supplierRef,
            priceBuy:      original.variants[i].priceBuy,
            priceSellPos:  original.variants[i].priceSellPos,
            priceSellWeb:  original.variants[i].priceSellWeb,
            stockMinAlert: original.variants[i].stockMinAlert,
            imageUrl:      original.variants[i].imageUrl,
            secondaryImageUrls: original.variants[i].secondaryImageUrls,
            isMain:        original.variants[i].isMain,
          ),
      ],
    );

    try {
      await AppDatabase.saveProduct(copy);
    } catch (e) {
      if (!mounted) return;
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
      return;
    }
    if (!mounted) return;
    AppSnack.success(context, '« ${copy.name} » créé — ajustez ce qui change');
    await context.push('/shop/${widget.shopId}/inventaire/product',
        extra: copy);
    _load();
  }

  /// Audit stock — Couche 3 du plan « sécurise le stock ».
  /// Lance la réconciliation manuelle, affiche un dialog récapitulatif,
  /// Ouvre le selector de scope puis exporte le catalogue selon le
  /// format choisi (CSV/PDF). Lit Hive uniquement (offline-first) via
  /// `ProductsExportSource`. La permission `canExportProducts` a déjà
  /// été vérifiée par le bouton qui appelle cette méthode.
  Future<void> _openExport() async {
    if (!mounted) return;
    final shop = LocalStorageService.getShop(widget.shopId);
    final partners =
        ProductsExportSource.partnerLocationsForShop(widget.shopId);
    final config = await ExportScopeSelector.show(
      context,
      type:             ExportType.products,
      shopId:           widget.shopId,
      shopName:         shop?.name,
      partnerLocations: partners,
    );
    if (!mounted || config == null) return;
    final rows = ProductsExportSource.collect(config.scope);
    if (rows.isEmpty) {
      AppSnack.info(context, 'Aucun produit dans ce périmètre');
      return;
    }
    if (config.format == ExportFormat.csv) {
      await ExportService.exportToCsv(
        context,
        config: config,
        header: ProductsExportSource.header,
        rows:   rows,
      );
    } else {
      await ExportService.exportToPdf(
        context,
        config: config,
        header: ProductsExportSource.header,
        rows:   rows,
      );
    }
  }

  /// et propose la navigation vers la page Incidents si des drifts sont
  /// détectés (les incidents sont créés automatiquement par
  /// `StockService.reconcileShop`).
  Future<void> _runStockAudit() async {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: SizedBox(
          width: 56, height: 56,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      ),
    );
    ReconciliationReport? report;
    try {
      report = await StockService.reconcileShop(
        shopId: widget.shopId,
        createIncidents: true,
      );
    } catch (e) {
      debugPrint('[Inventaire] audit stock erreur : $e');
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // ferme le loader
    if (report == null) {
      AppSnack.error(context, 'Audit échoué — réessaie.');
      return;
    }
    // Recharge les produits pour que tout incident affecte les compteurs
    // (la chip "Incidents" est visible ailleurs dans l'app).
    _load();
    await showDialog<void>(
      context: context,
      builder: (ctx) =>
          _StockAuditReportDialog(report: report!, shopId: widget.shopId),
    );
  }

  void _toggleActive(String id, bool v) {
    final p = _products.firstWhere((p) => p.id == id);
    AppDatabase.saveProduct(p.copyWith(isActive: v), skipValidation: true);
    _load();
  }
  void _toggleWeb(String id, bool v) {
    final p = _products.firstWhere((p) => p.id == id);
    AppDatabase.saveProduct(p.copyWith(isVisibleWeb: v), skipValidation: true);
    _load();
  }

  /// Activation/désactivation rapide d'une promo sur le produit, sans
  /// passer par la page Modifier. Ouvre une feuille légère (prix promo
  /// par variante + date de fin optionnelle) et persiste via
  /// `AppDatabase.saveProduct`.
  Future<void> _openQuickPromo(Product p) async {
    final perms = ref.read(permissionsProvider(widget.shopId));
    if (!perms.canEditProduct) {
      AppSnack.warning(context,
          'Vous n\'avez pas la permission de modifier ce produit.');
      return;
    }
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _QuickPromoDialog(product: p, shopId: widget.shopId),
    );
    if (changed == true) {
      _load();
      if (mounted) AppSnack.success(context, 'Promotion mise à jour');
    }
  }

  /// Ouvre le formulaire de transfert pré-rempli pour ce produit.
  ///
  /// La source est alignée sur l'onglet « Vue » actuellement actif :
  ///   * Globale / Boutique seule → location type='shop' de la boutique.
  ///   * Partenaire X → location_id de ce partenaire.
  ///
  /// Sans ça, l'utilisateur consultant le partenaire (où le stock est)
  /// ouvrait un transfert hardcodé sur la boutique (souvent vide pour ce
  /// produit après un transfert précédent) — la picker s'affichait vide
  /// avec « Aucune variante à la source ».
  ///
  /// Réservé au propriétaire de la boutique.
  Future<void> _openTransferSheet(Product p) async {
    final shop  = LocalStorageService.getShop(widget.shopId);
    final user  = LocalStorageService.getCurrentUser();
    if (shop == null || user == null) return;
    if (shop.ownerId != user.id) {
      AppSnack.warning(context,
          'Seul le propriétaire de la boutique peut effectuer un transfert.');
      return;
    }
    final shopLoc = AppDatabase.getShopLocation(widget.shopId);
    if (shopLoc == null) {
      AppSnack.error(context,
          'Emplacement de la boutique introuvable. Réessayez après synchronisation.');
      return;
    }

    // Résolution de la source selon l'onglet Vue actif.
    final viewFilter = ref.read(dashViewFilterProvider);
    String sourceId;
    if (viewFilter == null || viewFilter == '_base') {
      sourceId = shopLoc.id;
    } else {
      // Partenaire : on vérifie qu'il appartient bien au même owner et
      // qu'il est actif avant de l'utiliser comme source (un id corrompu
      // donnerait une sheet vide sans erreur).
      final raw = HiveBoxes.stockLocationsBox.get(viewFilter);
      StockLocation? partnerLoc;
      if (raw != null) {
        try {
          partnerLoc = StockLocation.fromMap(
              Map<String, dynamic>.from(raw));
        } catch (_) {/* ignore */}
      }
      if (partnerLoc == null
          || !partnerLoc.isActive
          || partnerLoc.ownerId != user.id) {
        // Fallback : si la résolution échoue, on retombe sur la boutique
        // pour ne pas bloquer l'utilisateur (mais on log).
        debugPrint('[Transfer] vue partenaire non résoluble '
            '($viewFilter) — fallback sur la boutique');
        sourceId = shopLoc.id;
      } else {
        sourceId = partnerLoc.id;
      }
    }

    final done = await showFormSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => TransferFormSheet(
        ownerId:         user.id,
        presetSourceId:  sourceId,
        presetProductId: p.id,
      ),
    );
    if (done == true && mounted) {
      AppSnack.success(context, 'Transfert exécuté');
      _load();
    }
  }

  /// Partage un produit. Si le produit a plusieurs variantes, ouvre un
  /// Partage le produit via WhatsApp (wa.me sans destinataire imposé).
  /// Si le produit a > 1 variante, l'opérateur choisit dans une mini-modale
  /// la variante précise à partager (ou l'image principale du produit).
  /// WhatsApp affiche automatiquement l'aperçu de l'image grâce à l'URL en
  /// première ligne du message.
  Future<void> _shareProductOnWhatsApp(Product p) async {
    ProductVariant? variant;
    if (p.variants.length > 1) {
      variant = await showDialog<ProductVariant?>(
        context: context,
        builder: (_) => _PickOneVariantDialog(product: p),
      );
      // dismiss → null = partage produit (sans variante précise)
    } else if (p.variants.length == 1) {
      variant = p.variants.first;
    }
    // Stock filtré sur la vue active (Boutique seule / Partenaire X /
    // Globale). Sans override le template tombe sur le cumul global
    // (`variant.stockAvailable` ou `p.totalStock`) — incorrect quand
    // le marchand consulte un partenaire.
    final int stockOverride = variant != null
        ? stock_loc.stockForVariantAtLocations(variant, _locIds)
        : stock_loc.stockAtLocations(p, _locIds);
    final msg = MessageTemplates.buildProductShareMessage(
      product:  p,
      variant:  variant,
      currency: CurrencyFormatter.currentSymbol,
      stockOverride: stockOverride,
    );
    final svc = ProviderScope.containerOf(context, listen: false)
        .read(whatsappServiceProvider);
    final ok = await svc.share(msg);
    if (!ok && mounted) {
      AppSnack.error(context,
          'Impossible d\'ouvrir WhatsApp.');
    }
  }

  /// Génère un catalogue HTML à partir des produits sélectionnés, l'upload
  /// sur Supabase Storage (bucket `catalogues`, signed URL 48 h), raccourcit
  /// l'URL, puis ouvre WhatsApp avec un message pré-rempli (sans destinataire
  /// — l'utilisateur choisit le contact ou le groupe à qui envoyer).
  /// Partage le **lien web** de la vitrine publique de la boutique :
  /// `https://<host>/catalogue/<shopId>`. Plus besoin de générer / uploader
  /// un PDF — la page publique est dynamique (toujours à jour) et ouvre
  /// directement le catalogue dans le navigateur du client.
  /// Path routing (sans `#`) depuis main.usePathUrlStrategy().
  ///
  /// Volontairement **synchrone jusqu'à `openExternal`** : sur web, un
  /// `await` préalable rompt le user gesture et le navigateur bloque
  /// la fenêtre wa.me.
  Future<void> _createWhatsappCatalogue() async {
    if (_creatingCatalogue) return;

    // 1) Demander quoi partager : tout / une catégorie / la sélection.
    final selectedIds = _selected.toList();
    final hasSelection = _selectMode && selectedIds.isNotEmpty;
    final categories = _availableCategories;
    // Emplacements proposés : la boutique + ses partenaires actifs (même
    // owner). Permet le partage « Par emplacement » (stock d'un dépôt précis).
    final uid = LocalStorageService.getCurrentUser()?.id ?? '';
    final shareLocations = <_ShareLoc>[];
    final shopLoc = AppDatabase.getShopLocation(widget.shopId);
    if (shopLoc != null) {
      shareLocations.add(_ShareLoc(
          id: shopLoc.id, name: shopLoc.name, isPartner: false));
    }
    for (final loc in AppDatabase.getStockLocationsForOwner(uid)) {
      if (loc.type == StockLocationType.partner && loc.isActive) {
        shareLocations.add(_ShareLoc(
            id: loc.id, name: loc.name, isPartner: true));
      }
    }
    final choice = await showDialog<_CatalogueShareChoice>(
      context: context,
      builder: (ctx) => _CatalogueShareDialog(
        categories:      categories,
        locations:       shareLocations,
        canUseSelection: hasSelection,
        selectionCount:  selectedIds.length,
      ),
    );
    if (choice == null) return;

    // 2) Construire l'URL `/catalogue/<shopId>` avec query params optionnels.
    if (!mounted) return;
    final origin = Uri.base.origin.startsWith('http')
        ? Uri.base.origin
        : 'https://fortress-pos.web.app';
    final qp = <String, String>{};
    // Périmètre produits que va afficher la page catalogue côté visiteur —
    // sert AUSSI à savoir lesquels embarquer dans le snapshot stock.
    // `selection` : seulement les produits cochés (loadés via `ids=`).
    // `category`/`all` : page catalogue charge tous les produits actifs
    // visibles web → on snapshote le même périmètre.
    List<Product> catalogueProducts;
    if (choice.kind == _CatalogueShareKind.category &&
        choice.category != null && choice.category!.isNotEmpty) {
      qp['cat'] = choice.category!;
      catalogueProducts = _products
          .where((p) => p.isActive && p.isVisibleWeb)
          .toList();
    } else if (choice.kind == _CatalogueShareKind.selection) {
      // Sélection : on n'expose que les produits cochés ET en stock dans la
      // vue active (pas de produit en rupture partagé).
      catalogueProducts = _products
          .where((p) => p.id != null && _selected.contains(p.id) &&
              stock_loc.stockAtLocations(p, _locIds) > 0)
          .toList();
      final selIds =
          catalogueProducts.map((p) => p.id).whereType<String>().toList();
      if (selIds.isNotEmpty) qp['ids'] = selIds.join(',');
      // Le partage explicite = consentement à exposer publiquement.
      // Sans ça, la RLS `products_anon_read_visible_web` renvoie 0 row
      // et le destinataire voit « Les produits partagés ne sont plus
      // disponibles publiquement ». Idempotent, fire-and-forget.
      if (catalogueProducts.isNotEmpty) {
        AppDatabase.markProductsVisibleWeb(catalogueProducts).catchError((e) {
          debugPrint('[Catalogue] markProductsVisibleWeb error: $e');
        });
      }
    } else if (choice.kind == _CatalogueShareKind.location &&
        choice.locationId != null && choice.locationId!.isNotEmpty) {
      // Par emplacement : seuls les produits effectivement EN STOCK dans
      // cet emplacement précis (dépôt / partenaire) sont exposés. On passe
      // leurs `ids` à la vitrine pour qu'elle n'affiche que ceux-là.
      catalogueProducts = _products
          .where((p) => p.isActive && p.isVisibleWeb &&
              stock_loc.stockAtLocations(p, [choice.locationId!]) > 0)
          .toList();
      final locProductIds =
          catalogueProducts.map((p) => p.id).whereType<String>().toList();
      if (locProductIds.isNotEmpty) qp['ids'] = locProductIds.join(',');
    } else {
      catalogueProducts = _products
          .where((p) => p.isActive && p.isVisibleWeb)
          .toList();
    }
    // Garde-fou : pour un partage RESTREINT (sélection / emplacement), s'il
    // n'y a aucun produit en stock dans le périmètre, on n'envoie RIEN —
    // sinon, faute d'`ids=`, la vitrine retomberait sur le catalogue global
    // complet (fuite de produits hors périmètre).
    if ((choice.kind == _CatalogueShareKind.selection ||
            choice.kind == _CatalogueShareKind.location) &&
        catalogueProducts.isEmpty) {
      if (mounted) {
        AppSnack.info(context,
            'Aucun produit en stock à partager dans ce périmètre.');
      }
      return;
    }
    // Périmètre d'emplacements pour le snapshot de stock (`stock=`) ET
    // l'emplacement rattaché à la commande client (`loc=`). « Par
    // emplacement » cible l'emplacement choisi ; sinon on retombe sur la
    // vue active (Globale / Boutique seule / Partenaire X).
    final List<String>? snapLocIds;
    final String? shareLocId;
    if (choice.kind == _CatalogueShareKind.location &&
        choice.locationId != null && choice.locationId!.isNotEmpty) {
      snapLocIds = [choice.locationId!];
      shareLocId = choice.locationId;
    } else {
      snapLocIds = _locIds;
      final vf = ref.read(dashViewFilterProvider);
      if (vf == null || vf == '_base') {
        shareLocId = AppDatabase.getShopLocation(widget.shopId)?.id;
      } else if (HiveBoxes.stockLocationsBox.get(vf) != null) {
        shareLocId = vf;
      } else {
        shareLocId = null;
      }
    }
    // Snapshot embarqué dans l'URL via `stock=` — sans ça, la page catalogue
    // retombe sur le JSONB Supabase (boutique principale uniquement).
    final snapshot = _buildStockSnapshotForLocs(catalogueProducts, snapLocIds);
    if (snapshot.isNotEmpty) {
      qp['stock'] = snapshot.entries
          .map((e) => '${e.key}:${e.value}')
          .join(',');
    }
    if (shareLocId != null && shareLocId.isNotEmpty) {
      qp['loc'] = shareLocId;
    }
    final qpString = qp.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final longUrl = qpString.isEmpty
        ? '$origin/catalogue/${widget.shopId}'
        : '$origin/catalogue/${widget.shopId}?$qpString';
    // Raccourcir AVANT le picker destinataire : l'await est consommé
    // avant la prochaine interaction utilisateur (clic recipient), qui
    // fournit alors un user gesture frais pour `openExternal` côté web
    // (anti popup-blocker). Si shortening échoue → fallback URL longue.
    // 1. Raccourcisseur maison (Supabase `r`) — même pipeline fiable que le
    //    dialog 3 étapes et les campagnes promo, et le SEUL qui fonctionne
    //    sur web (tinyurl/is.gd y sont bloqués par CORS → URL longue).
    // 2. Repli tinyurl/is.gd si la DB/réseau Supabase est indisponible.
    // 3. Dernier recours : l'URL longue (l'envoi n'est jamais bloqué).
    String url;
    try {
      final maison = await ShortLinkService.createShortLink(
        longUrl:   longUrl,
        linkType:  'catalogue',
        expiresIn: const Duration(days: 90),
      );
      url = maison ?? await UrlShortenerService.shorten(longUrl);
    } catch (_) {
      url = longUrl;
    }
    if (!mounted) return;

    // 3) Choix du destinataire WhatsApp.
    final phone = await pickWhatsappRecipient(
        context, shopId: widget.shopId);
    if (phone == null || phone.isEmpty) return;
    if (!mounted) return;

    final shop = LocalStorageService.getShop(widget.shopId);
    final shopName = shop?.name ?? '';
    // Message court : nom boutique + 1 ligne intitulé + URL. Le contenu
    // détaillé (produits, prix, stock) est déjà visible dans la page
    // ouverte par le lien — pas besoin de le répéter dans la prose.
    String catalogLine;
    switch (choice.kind) {
      case _CatalogueShareKind.category:
        catalogLine = 'Notre catalogue — ${choice.category}';
        break;
      case _CatalogueShareKind.selection:
        catalogLine = 'Nos produits sélectionnés '
            '(${catalogueProducts.length})';
        break;
      case _CatalogueShareKind.location:
        catalogLine = 'Notre catalogue — ${choice.locationName}';
        break;
      case _CatalogueShareKind.all:
        catalogLine = 'Notre catalogue';
        break;
    }
    final msg = shopName.isEmpty
        ? '$catalogLine :\n$url'
        : '🛍️ $shopName\n$catalogLine : $url';

    // 4) Ouvrir wa.me.
    final p = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (p.isEmpty) {
      AppSnack.error(context, 'Numéro WhatsApp invalide.');
      return;
    }
    final waUrl = 'https://wa.me/$p?text=${Uri.encodeComponent(msg)}';
    final ok = await openExternal(waUrl);
    if (!ok && mounted) {
      AppSnack.error(context,
          'Impossible d\'ouvrir WhatsApp. Autorisez les pop-ups.');
    } else if (mounted) {
      setState(() {
        _selectMode = false;
        _selected.clear();
      });
    }
  }

  /// sélecteur (cases à cocher) pour choisir lesquelles partager. Sinon
  /// partage directement.
  Future<void> _openSharePicker(Product p) async {
    if (p.variants.length <= 1) {
      // Stock filtré vue active — sinon le texte partagé via share sheet OS
      // contient le cumul global (`p.totalStock`), pas le stock du
      // partenaire/boutique que le marchand visualise.
      await DocumentService.shareProduct(p,
          shopId: widget.shopId,
          stockOverride: stock_loc.stockAtLocations(p, _locIds));
      return;
    }
    final selectedIds = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _ShareVariantsPickerDialog(product: p),
    );
    if (selectedIds == null || selectedIds.isEmpty) return;
    final filtered = p.copyWith(
      variants: p.variants.where((v) =>
          v.id != null && selectedIds.contains(v.id)).toList());
    // Stock filtré = somme des variantes sélectionnées sur la vue active.
    var stockOverride = 0;
    for (final v in filtered.variants) {
      stockOverride += stock_loc.stockForVariantAtLocations(v, _locIds);
    }
    await DocumentService.shareProduct(filtered,
        shopId: widget.shopId, stockOverride: stockOverride);
  }
  Future<void> _delete(String id) async {
    final p = _products.where((p) => p.id == id).firstOrNull;
    if (p == null) return;

    // hotfix_085 — pré-check léger : si le produit a manifestement du
    // stock, on saute directement le dialog motif et on propose
    // l'archivage (UX : pas la peine de demander un motif si on sait
    // que l'opération échouera).
    final blocker = DeleteProductUseCase().peekBlocker(p);
    if (blocker != null) {
      if (!mounted) return;
      final choice = await showBlockedDeleteDialog(
        context,
        itemLabel: p.name,
        reason:
            '${blocker.message}\n\nVide le stock ou supprime les commandes '
            'concernées avant de réessayer, ou archive le produit.',
        archiveDescription:
            'Le produit sera désactivé : plus visible à la caisse, dans '
            'les listes ni à la vente. L\'historique de ses ventes passées '
            'reste intact. Aucune trace centralisée n\'est créée — '
            'utilise la suppression pour un audit complet.',
      );
      if (choice == BlockedDeleteChoice.archive) {
        await AppDatabase.saveProduct(
            p.copyWith(isActive: false), skipValidation: true);
        if (mounted) AppSnack.success(context, 'Produit archivé');
        _load();
      }
      return;
    }

    // Pas de blocker visible → dialog motif + checkbox. Le use case fait
    // les checks complets (stock_levels, commandes ouvertes) côté
    // AppDatabase + push la RPC. Les exceptions sont catched par le
    // dialog et affichées en place.
    final ok = await showDeleteProductDialog(
      context,
      product: p,
      onConfirm: (reason) =>
          DeleteProductUseCase().call(productId: id, reason: reason),
    );
    if (ok != true) return;
    // L'audit `product_deleted` est désormais émis SIDE serveur par la
    // RPC `delete_product` (cf. hotfix_085). `_load()` rafraîchit la
    // liste — `LocalStorageService.getProductsForShop` filtre déjà les
    // produits soft-deleted.
    if (mounted) AppSnack.success(context, 'Produit supprimé');
    _load();
  }


  // ── Sort menu ──────────────────────────────────────────────────────────────
  void _showSortMenu(BuildContext ctx, GlobalKey key) {
    final box = key.currentContext!.findRenderObject() as RenderBox;
    final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox;
    // CRITIQUE : `ancestor: overlay` — sinon localToGlobal renvoie les coords
    // ABSOLUES écran tandis que RelativeRect.fromRect traite le container
    // comme commençant à (0,0). Sans ancestor, le menu s'ouvre décalé d'une
    // hauteur d'AppBar/StatusBar/banner.
    final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
    final l    = ctx.l10n;
    final cs   = Theme.of(ctx).colorScheme;
    showMenu<String>(
      context: ctx, color: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      elevation: 4,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(pos.dx, pos.dy + box.size.height + 4,
            box.size.width, 0),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 240),
      items: [
        ('name',  l.invSortName,  Icons.sort_by_alpha_rounded),
        ('stock', l.invSortStock, Icons.inventory_2_outlined),
        ('price', l.invSortPrice, Icons.attach_money_rounded),
      ].map((e) {
        final isSel = _sort == e.$1;
        return PopupMenuItem<String>(
          value: e.$1,
          height: 38,
          child: Row(children: [
            Icon(
              isSel
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 16,
              color: isSel
                  ? cs.primary
                  : cs.onSurface.withValues(alpha: 0.4),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(e.$2,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body.copyWith(
                    fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                    color: isSel ? cs.primary : cs.onSurface))),
            if (isSel)
              Icon(Icons.check_rounded, size: 14, color: cs.primary),
          ]),
        );
      }).toList(),
    ).then((v) { if (v != null) setState(() { _sort = v; _page = 1; }); });
  }

  // ── Dialog suppression ─────────────────────────────────────────────────────
  Future<void> _confirmDelete(BuildContext ctx, Product p) async {
    final l = ctx.l10n;
    final perms = ProviderScope.containerOf(ctx, listen: false)
        .read(permissionsProvider(widget.shopId));
    await DangerActionService.execute(
      context:      ctx,
      perms:        perms,
      action:       DangerAction.deleteProduct,
      shopId:       widget.shopId,
      targetId:     p.id ?? '',
      targetLabel:  p.name,
      title:        l.invDeleteConfirm,
      description:  '« ${p.name} » — ${l.invDeleteWarning}',
      consequences: const [
        'Le produit disparaît du catalogue et de la caisse.',
        'L\'historique des ventes passées le mentionnant reste lisible.',
        'Le stock courant sur cette référence est perdu.',
      ],
      confirmText:  p.name,
      onConfirmed:  () async => _delete(p.id!),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    try {
      GoRouter.of(context).routerDelegate.removeListener(_onRouteChange);
    } catch (_) {}
    AppDatabase.removeListener(_onRealtimeChange);
    // Pas de unsubscribeFromShop ici : la subscription est pilotée par
    // AppScaffold qui survit aux navigations entre pages du même shop.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;
    // Filtre dashboard (Globale / boutique seule / partenaire). On résout
    // au build pour que tous les `_filtered`, _stockAtLocations, etc.
    // s'alignent automatiquement sur la vue choisie.
    final viewFilter = ref.watch(dashViewFilterProvider);
    _locIds = _resolveLocationIds(viewFilter, widget.shopId);
    _isPartnerView = viewFilter != null && viewFilter != '_base';
    // Breakpoint mobile : utilisé plus bas pour switcher entre _MobileCard
    // et _DesktopRow dans la liste produits.
    final mobile = MediaQuery.of(context).size.width < 700;

    return Column(children: [

        // ⓪ Onglets « Vue » — sélecteur Globale / Boutique / Partenaires.
        // Partagé avec Vente et Commandes via dashViewFilterProvider.
        ViewFilterChipBar(shopId: widget.shopId, useTabs: true),

        // ⓪ CHIPS Stock — rendus au niveau du shell (mobile ET desktop
        // depuis round 11) pour rester visibles sur les 5 sous-pages.
        // Cf. AdaptiveScaffold._MobileShell + _DesktopShell.

        // ① STATS — supprimées (round 12) : redondantes avec le popup
        // status qui contient déjà les 6 mêmes filtres en accès immédiat
        // sans encombrer la première ligne. Le widget _StatsCards reste
        // défini plus bas mais n'est plus instancié.

        // ② TOPBAR — 4 boutons compacts alignés à GAUCHE (mobile + desktop) :
        //   - Status (Tous / Actifs / Stock bas / Disponible / Inactifs / Sans prix)
        //   - Catégorie (multi-select, si dispo)
        //   - Marque (multi-select, si dispo)
        //   - Tri (déplacé depuis la ligne de recherche pour regrouper tous
        //     les boutons popup ensemble)
        // Style identique : popup compact 32px (cohérence avec _MembersFilterPopupBtn).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _StatusFilterPopupBtn(
                    active: _activeChip,
                    onChange: (chip) => setState(() {
                      _activeChip = chip;
                      _page = 1;
                    }),
                  ),
                  if (_availableCategories.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _MultiChip(
                      label:    l.invCategoryLabel,
                      icon:     Icons.category_outlined,
                      count:    _filterCategories.length,
                      items:    _availableCategories,
                      selected: _filterCategories,
                      onChanged: (v) => setState(() {
                        _filterCategories = v;
                        _page = 1;
                      }),
                      context: context,
                    ),
                  ],
                  if (_availableBrands.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _MultiChip(
                      label:    l.invBrandLabel,
                      icon:     Icons.local_offer_outlined,
                      count:    _filterBrands.length,
                      items:    _availableBrands,
                      selected: _filterBrands,
                      onChanged: (v) => setState(() {
                        _filterBrands = v;
                        _page = 1;
                      }),
                      context: context,
                    ),
                  ],
                  const SizedBox(width: 6),
                  _SortBtn(key: _sortKey, active: _sort != 'name',
                      onTap: () => _showSortMenu(context, _sortKey)),
                  const SizedBox(width: 6),
                  // Audit stock — bouton manuel Couche 3 : compare le
                  // `stockAvailable` de chaque variante au dernier
                  // `after_available` enregistré dans stock_movements.
                  // Crée un Incident `audit_drift` par variante divergente.
                  _AuditStockBtn(onTap: _runStockAudit),
                  // Export catalogue (CSV/PDF). Visible uniquement si
                  // l'utilisateur a `inventory.export`. Ouvre directement
                  // le scope selector — pas besoin de passer par /exports.
                  if (ref.watch(permissionsProvider(widget.shopId))
                      .canExportProducts) ...[
                    const SizedBox(width: 6),
                    _ExportBtn(onTap: _openExport),
                  ],
                ]),
              ),
            ),
            const SizedBox(width: 8),
            // Bouton "Ajouter produit" inline — extrême droite de la
            // ligne des filtres. Remplace l'ancien FAB draggable + le
            // bouton "+" de la topbar shell.
            Tooltip(
              message: l.inventaireAdd,
              child: SizedBox(
                width: 38, height: 38,
                child: Material(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: _handleCreateProductTap,
                    child: const Icon(Icons.add_rounded,
                        size: 20, color: Colors.white),
                  ),
                ),
              ),
            ),
          ]),
        ),

        // ③ RECHERCHE — bulk-select AVANT la barre de recherche, sur la
        // même ligne. Icône `select_all_rounded` (carré + checkmarks) pour
        // signaler clairement « selection multiple ». Le bouton Tri a été
        // déplacé sur la ligne des filtres ci-dessus.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(children: [
            Tooltip(
              message: _selectMode ? l.invActionCancelSelect : l.invActionSelect,
              child: SizedBox(
                width: 38, height: 38,
                child: Material(
                  color: _selectMode
                      ? AppColors.primary.withValues(alpha:0.10)
                      : Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() {
                      _selectMode = !_selectMode;
                      if (!_selectMode) _selected.clear();
                    }),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _selectMode
                            ? AppColors.primary.withValues(alpha:0.45)
                            : Theme.of(context).semantic.borderSubtle),
                      ),
                      child: Icon(
                        _selectMode
                            ? Icons.close_rounded
                            : Icons.select_all_rounded,
                        size: 18,
                        color: _selectMode
                            ? AppColors.primary
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 38,
                child: TextField(
                  onChanged: (v) => setState(() { _query = v; _page = 1; }),
                  style: AppTextStyles.body,
                  decoration: InputDecoration(
                    hintText: l.inventaireSearch,
                    hintStyle: AppTextStyles.bodySm
                        .copyWith(color: AppColors.textHint),
                    prefixIcon: Icon(Icons.search_rounded,
                        size: 18, color: AppColors.textHint),
                    filled: true, fillColor: Theme.of(context).colorScheme.surface, isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: AppColors.primary,
                            width: 1.5)),
                  ),
                ),
              ),
            ),
          ]),
        ),

        // ④ Compteur articles + stock total filtré + per-page
        // Stock total = somme des `stockAvailable` de toutes les variantes
        // des produits filtrés. Se met à jour live à chaque filtre.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
          child: Row(children: [
            // ── Gauche : nombre d'articles filtrés ──
            Expanded(
              child: Text('${_filtered.length} ${l.invItems}',
                  style: AppTextStyles.caption),
            ),
            // ── Centre : stock global ──
            Expanded(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                      '${_totalAvailableStock()} en stock',
                      style: AppTextStyles.captionBold
                          .copyWith(color: AppColors.primary)),
                ),
              ),
            ),
            // ── Droite : dropdown per-page ──
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(l.invPerPage,
                      style: AppTextStyles.captionHint
                          .copyWith(color: AppColors.textSecondary)),
                  const SizedBox(width: 6),
                  Theme(
                    data: Theme.of(context).copyWith(
                      canvasColor: Theme.of(context).colorScheme.surface,
                      colorScheme: Theme.of(context).colorScheme.copyWith(
                          surface: Theme.of(context).colorScheme.surface,
                          onSurface: Theme.of(context).colorScheme.onSurface),
                    ),
                    child: DropdownButton<int>(
                      value: _perPage, isDense: true,
                      underline: const SizedBox.shrink(),
                      dropdownColor: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      style: AppTextStyles.bodySm,
                      items: [10, 25, 50].map((n) => DropdownMenuItem(
                        value: n,
                        child: Text('$n', style: AppTextStyles.bodySm),
                      )).toList(),
                      onChanged: (v) =>
                          setState(() { _perPage = v!; _page = 1; }),
                    ),
                  ),
                ],
              ),
            ),
          ]),
        ),

        // ⑤ LISTE
        Expanded(
          child: RefreshIndicator(
            onRefresh: _pullAndReload,
            child: _filtered.isEmpty
              ? (_products.isEmpty
          // Vrais aucun produit → état vide avec bouton ajout
              ? ListView(children: [EmptyStateWidget(
            icon: Icons.inventory_2_outlined,
            title: context.l10n.inventaireEmpty,
            subtitle: context.l10n.inventaireEmptyHint,
            ctaLabel: context.l10n.inventaireAdd,
            onCta: _handleCreateProductTap,
          )])
              : ListView(children: const [_NoResultState()]))
              : ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            itemCount: _pageItems.length,
            itemBuilder: (_, i) {
              final p = _pageItems[i];
              final card = mobile
                  ? _MobileCard(product: p, shopId: widget.shopId,
                  onToggleActive: (v) => _toggleActive(p.id!, v),
                  onToggleWeb: (v) => _toggleWeb(p.id!, v),
                  onDelete: () => _confirmDelete(context, p),
                  onProductChanged: _load,
                  onTransfer: () => _openTransferSheet(p),
                  onShare: () => _openSharePicker(p),
                  onShareWhatsApp: () => _shareProductOnWhatsApp(p),
                  onPromo: () => _openQuickPromo(p),
                  onDuplicate: () => _duplicateProduct(p),
                  onEdit: () async {
                    await context.push(
                        '/shop/${widget.shopId}/inventaire/product',
                        extra: p);
                    _load();
                  })
                  : _DesktopRow(product: p, shopId: widget.shopId,
                  onToggleActive: (v) => _toggleActive(p.id!, v),
                  onToggleWeb: (v) => _toggleWeb(p.id!, v),
                  onDelete: () => _confirmDelete(context, p),
                  onProductChanged: _load,
                  onTransfer: () => _openTransferSheet(p),
                  onShare: () => _openSharePicker(p),
                  onShareWhatsApp: () => _shareProductOnWhatsApp(p),
                  onPromo: () => _openQuickPromo(p),
                  onDuplicate: () => _duplicateProduct(p),
                  onEdit: () async {
                    await context.push(
                        '/shop/${widget.shopId}/inventaire/product',
                        extra: p);
                    _load();
                  });
              if (!_selectMode) return card;
              final sel = p.id != null && _selected.contains(p.id);
              return Row(children: [
                Checkbox(
                  value: sel,
                  activeColor: AppColors.primary,
                  onChanged: (_) => setState(() {
                    if (sel) { _selected.remove(p.id); }
                    else if (p.id != null) { _selected.add(p.id!); }
                  }),
                ),
                Expanded(child: card),
              ]);
            },
          ),
          ),
        ),

        // ⑥ PAGINATION
        if (_filtered.isNotEmpty)
          _Pagination(
            page: _page, total: _totalPages,
            count: _filtered.length, perPage: _perPage,
            onPrev: _page > 1 ? () => setState(() => _page--) : null,
            onNext: _page < _totalPages ? () => setState(() => _page++) : null,
          ),

        // ⑦ BARRE PARTAGE SÉLECTION
        if (_selectMode && _selected.isNotEmpty)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(children: [
                // Bouton "Frais" — répartit une dépense (transport, douane)
                // sur les produits cochés, au prorata de leurs pièces. Le
                // stock ne bouge pas : seul le prix de revient est corrigé.
                SizedBox(
                  height: 46,
                  child: OutlinedButton.icon(
                    onPressed: _openFeesForSelection,
                    icon: const Icon(Icons.receipt_long_rounded, size: 18),
                    label: Text('Frais',
                        style: AppTextStyles.bodyBold
                            .copyWith(color: AppColors.primary)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      side: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.4)),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Bouton "Catalogue WhatsApp" — génère un HTML léger,
                // l'upload sur Supabase, raccourcit l'URL et ouvre wa.me.
                Expanded(
                  flex: 3,
                  child: SizedBox(
                    height: 46,
                    child: ElevatedButton.icon(
                      onPressed: _creatingCatalogue
                          ? null
                          : _createWhatsappCatalogue,
                      icon: _creatingCatalogue
                          ? const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.send_rounded, size: 18),
                      label: Text(
                          _creatingCatalogue
                              ? 'Génération…'
                              : 'Catalogue WhatsApp '
                                '(${_selected.length})',
                          style: AppTextStyles.bodyBold
                              .copyWith(color: Colors.white)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Bouton "Partager" classique (share sheet OS multi-canal)
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 46,
                    child: OutlinedButton.icon(
                      onPressed: _creatingCatalogue ? null : () {
                        final products = _products
                            .where((p) => p.id != null
                                && _selected.contains(p.id))
                            .toList();
                        // Snapshot du stock filtré sur la vue active
                        // (Globale / Boutique seule / Partenaire X).
                        // Embarqué dans l'URL côté share_catalog_dialog
                        // → le client voit le stock du périmètre que
                        // le marchand visualise au moment du partage,
                        // pas le cumul global Supabase.
                        final snapshot = _buildStockSnapshot(products);
                        // Emplacement du périmètre actif → propagé à la
                        // commande client (orders.delivery_location_id).
                        final vf = ref.read(dashViewFilterProvider);
                        String? shareLocId;
                        if (vf == null || vf == '_base') {
                          shareLocId =
                              AppDatabase.getShopLocation(widget.shopId)?.id;
                        } else if (HiveBoxes.stockLocationsBox.get(vf)
                            != null) {
                          shareLocId = vf;
                        }
                        ShareCatalogDialog.show(context,
                            products: _products, shopId: widget.shopId,
                            preSelected: products,
                            stockSnapshot: snapshot,
                            locationId: shareLocId);
                      },
                      icon: const Icon(Icons.share_rounded, size: 16),
                      label: Text('Partager',
                          style: AppTextStyles.bodyBold
                              .copyWith(color: AppColors.primary)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: BorderSide(
                            color: AppColors.primary.withValues(alpha:0.4)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
      ]);
  }
}

// _StockNavChips déplacé vers lib/shared/widgets/stock_nav_chips.dart
// (rendu désormais au niveau du shell pour rester visible sur les 5
// sous-pages Stock).
//
// _StatsCards / _StatCard : supprimés round 12. Les filtres status
// (Tous / Actifs / Stock bas / Disponible / Inactifs / Sans prix) sont
// désormais accessibles via _StatusFilterPopupBtn — plus de cards KPI.
//
// _FilterChips : supprimé round 12. Remplacé par les 3 boutons popup
// alignés à droite (status + catégorie + marque) pour cohérence
// mobile/desktop.


/// Bouton popup compact 32×32 qui regroupe les 6 filtres status produits :
/// Tous · Actifs · Stock bas · Disponible · Inactifs · Sans prix. Pastille
/// primary affichée si filtre actif ≠ 'all'. Utilisé sur mobile ET desktop.
///
/// Positionnement popup : `RelativeRect.fromRect` calculé depuis le
/// `RenderBox` du bouton via [GlobalKey] — garantit l'ouverture juste
/// sous le bouton (offset 4px), même quand le bouton est dans une Row
/// imbriquée. Le `PopupMenuButton` natif Flutter calculait parfois
/// la position à partir d'un wrapper parent, d'où des popups trop loin.
class _StatusFilterPopupBtn extends StatefulWidget {
  final String              active;
  final ValueChanged<String> onChange;
  const _StatusFilterPopupBtn({
    required this.active,
    required this.onChange,
  });

  @override
  State<_StatusFilterPopupBtn> createState() => _StatusFilterPopupBtnState();
}

class _StatusFilterPopupBtnState extends State<_StatusFilterPopupBtn> {
  final _anchorKey = GlobalKey();

  Future<void> _open() async {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    // CRITIQUE : `ancestor: overlay` (cf. _showSortMenu) — sinon le rect
    // est en coords ABSOLUES alors que RelativeRect.fromRect attend des
    // coords RELATIVES à l'overlay. Sans ça, popup décalé d'une hauteur
    // d'AppBar/StatusBar.
    final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final l     = context.l10n;
    final items = <(String, String)>[
      ('all',       l.invChipAll),
      ('active',    l.invFilterActive),
      ('low_stock', l.invChipLowStock),
      ('stock',     l.invAvailableLabel),
      ('inactive',  l.invFilterInactive),
      ('no_price',  l.invChipNoPrice),
    ];
    final selected = await showMenu<String>(
      context: context,
      color: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      elevation: 4,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(pos.dx, pos.dy + box.size.height + 4,
            box.size.width, 0),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 240),
      items: items.map((it) {
        final isSel = widget.active == it.$1;
        return PopupMenuItem<String>(
          value: it.$1,
          height: 38,
          child: Row(children: [
            Icon(
              isSel
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 16,
              color: isSel
                  ? cs.primary
                  : cs.onSurface.withValues(alpha: 0.4),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(it.$2,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body.copyWith(
                    fontWeight: isSel
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: isSel
                        ? cs.primary
                        : cs.onSurface))),
            if (isSel)
              Icon(Icons.check_rounded, size: 14, color: cs.primary),
          ]),
        );
      }).toList(),
    );
    if (selected != null) widget.onChange(selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final l     = context.l10n;
    final isActive = widget.active != 'all';
    return SizedBox(
      key: _anchorKey,
      width: 32, height: 32,
      child: Tooltip(
        message: l.invChipAll,
        child: InkWell(
          onTap: _open,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: isActive
                  ? cs.primary.withValues(alpha: 0.10)
                  : sem.elevatedSurface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: isActive
                      ? cs.primary.withValues(alpha: 0.4)
                      : sem.borderSubtle),
            ),
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Icon(Icons.tune_rounded, size: 15,
                    color: isActive
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.7)),
                if (isActive)
                  Positioned(
                    right: 4, top: 4,
                    child: Container(
                      width: 6, height: 6,
                      decoration: BoxDecoration(
                        color: cs.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: cs.surface, width: 1),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bouton multi-sélection compact 32×32 (mobile) — même style que
/// `_StatusFilterPopupBtn`. Icône seule + pastille primary si au moins
/// un élément sélectionné. Tap → ouvre un popup similaire à
/// `_StatusFilterPopupBtn` mais avec checkboxes (multi-select).
class _MultiChip extends StatefulWidget {
  final String label;
  final IconData icon;
  final int count;
  final List<String> items;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final BuildContext context;

  const _MultiChip({required this.label, required this.icon,
    required this.count, required this.items, required this.selected,
    required this.onChanged, required this.context});

  @override
  State<_MultiChip> createState() => _MultiChipState();
}

class _MultiChipState extends State<_MultiChip> {
  final _anchorKey = GlobalKey();
  // Sélection locale — mise à jour sans fermer le menu
  late Set<String> _localSel;

  @override
  void initState() {
    super.initState();
    _localSel = Set.from(widget.selected);
  }

  @override
  void didUpdateWidget(_MultiChip old) {
    super.didUpdateWidget(old);
    _localSel = Set.from(widget.selected);
  }

  Future<void> _open() async {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    // CRITIQUE : `ancestor: overlay` (cf. _showSortMenu / _StatusFilterPopupBtn)
    // — sinon coords absolues vs container relatif → popup décalé.
    final pos  = box.localToGlobal(Offset.zero, ancestor: overlay);
    final size = box.size;

    await showMenu<String>(
      context: context,
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      elevation: 4,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(pos.dx, pos.dy + size.height + 4, size.width, 0),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(
        minWidth: 200,
        maxWidth: 280,
        maxHeight: 360,
      ),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          padding: EdgeInsets.zero,
          value: '__container__',
          child: _InlineMultiMenu(
            label: widget.label,
            items: widget.items,
            selected: _localSel,
            onToggle: (item) {
              setState(() {
                if (_localSel.contains(item)) _localSel.remove(item);
                else _localSel.add(item);
              });
              widget.onChanged(Set.from(_localSel));
            },
            onClear: () {
              setState(() => _localSel.clear());
              widget.onChanged({});
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final active = widget.count > 0;
    return SizedBox(
      key: _anchorKey,
      width: 32, height: 32,
      child: Tooltip(
        message: widget.label,
        child: InkWell(
          onTap: _open,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: active
                  ? cs.primary.withValues(alpha: 0.10)
                  : sem.elevatedSurface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: active
                      ? cs.primary.withValues(alpha: 0.4)
                      : sem.borderSubtle),
            ),
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Icon(widget.icon, size: 15,
                    color: active
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.7)),
                if (active)
                  Positioned(
                    right: 4, top: 4,
                    child: Container(
                      width: 6, height: 6,
                      decoration: BoxDecoration(
                        color: cs.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: cs.surface, width: 1),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Menu inline multi-sélection — même style que AppSelectMenu ───────────────

class _InlineMultiMenu extends StatefulWidget {
  final String label;
  final List<String> items;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  const _InlineMultiMenu({required this.label, required this.items,
    required this.selected, required this.onToggle, required this.onClear});

  @override
  State<_InlineMultiMenu> createState() => _InlineMultiMenuState();
}

class _InlineMultiMenuState extends State<_InlineMultiMenu> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    return Material(
      color: cs.surface,
      borderRadius: BorderRadius.circular(10),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header label discret en haut du popup
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              child: Text(widget.label.toUpperCase(),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.microBold.copyWith(
                      letterSpacing: 0.6,
                      color: cs.onSurface.withValues(alpha: 0.5))),
            ),
            if (widget.items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  Icon(Icons.info_outline_rounded, size: 14,
                      color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Text(context.l10n.invNoResult,
                      style: AppTextStyles.bodySmSecondary),
                ]),
              )
            else
              ...widget.items.map((item) {
                final sel = widget.selected.contains(item);
                return InkWell(
                  onTap: () {
                    setState(() {});
                    widget.onToggle(item);
                  },
                  child: SizedBox(
                    height: 38,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          width: 14, height: 14,
                          decoration: BoxDecoration(
                            color: sel ? AppColors.primary : Colors.transparent,
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(
                                color: sel
                                    ? AppColors.primary
                                    : cs.onSurface.withValues(alpha: 0.4),
                                width: 1.5),
                          ),
                          child: sel ? const Icon(Icons.check_rounded,
                              size: 10, color: Colors.white) : null,
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: Text(item,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.bodySm.copyWith(
                                fontWeight: sel
                                    ? FontWeight.w600 : FontWeight.w400,
                                color: sel ? AppColors.primary
                                    : Theme.of(context).colorScheme.onSurface))),
                      ]),
                    ),
                  ),
                );
              }),
            // Séparateur + bouton effacer si sélection active
            if (widget.selected.isNotEmpty) ...[
              Divider(height: 1, color: cs.onSurface.withValues(alpha: 0.08)),
              InkWell(
                onTap: () {
                  setState(() {});
                  widget.onClear();
                },
                child: SizedBox(
                  height: 36,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(children: [
                      Icon(Icons.close_rounded, size: 14,
                          color: AppColors.error),
                      const SizedBox(width: 8),
                      Text(context.l10n.clear,
                          style: AppTextStyles.bodySmBold
                              .copyWith(color: AppColors.error)),
                    ]),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Bouton tri compact ───────────────────────────────────────────────────────

class _SortBtn extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;
  const _SortBtn({super.key, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: 36, width: 36,
      decoration: BoxDecoration(
        color: active ? AppColors.primarySurface : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: active ? AppColors.primary : Theme.of(context).semantic.borderSubtle),
      ),
      child: Icon(Icons.sort_rounded, size: 18,
          color: active ? AppColors.primary : AppColors.textSecondary),
    ),
  );
}

// ─── Desktop row ──────────────────────────────────────────────────────────────

class _DesktopRow extends ConsumerStatefulWidget {
  final Product product;
  final String shopId;
  final ValueChanged<bool> onToggleActive, onToggleWeb;
  final VoidCallback onDelete, onEdit, onProductChanged, onTransfer, onShare,
      onShareWhatsApp, onPromo;
  final VoidCallback onDuplicate;
  const _DesktopRow({required this.product, required this.shopId,
    required this.onToggleActive, required this.onToggleWeb,
    required this.onDelete, required this.onEdit,
    required this.onProductChanged, required this.onTransfer,
    required this.onShare,
    required this.onShareWhatsApp, required this.onPromo,
    required this.onDuplicate});
  @override ConsumerState<_DesktopRow> createState() => _DesktopRowState();
}

class _DesktopRowState extends ConsumerState<_DesktopRow> {
  bool _showVariants = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final p = widget.product;
    // Stock conditionné au filtre dashboard (Globale / boutique seule /
    // partenaire) pour rester cohérent avec la caisse.
    final viewFilter = ref.watch(dashViewFilterProvider);
    final locIds     = _resolveLocationIds(viewFilter, widget.shopId);
    final stock      = _stockAtLocations(p, locIds);
    final isLow      = _isLowStockAt(p, locIds);
    // Vue partenaire = un id de stock_location dans le filtre (ni null=Globale
    // ni '_base'=Boutique seule). Dans cette vue le produit est read-only :
    // pas de toggles, pas de Modifier/Supprimer, variantes filtrées sur ce
    // qui a été effectivement transféré chez ce partenaire.
    final isPartnerView = viewFilter != null && viewFilter != '_base';
    final partnerLocId  = isPartnerView ? viewFilter : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Stack(children: [
              ProductImageCard(
                imageUrl: p.mainImageUrl,
                width:  64,
                height: 64,
                borderRadius: BorderRadius.circular(8),
              ),
              Positioned(bottom: 2, right: 2,
                  child: UploadStatusDot(productId: p.id, size: 18)),
            ]),
            const SizedBox(width: 10),
            Expanded(flex: 3, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: AppTextStyles.bodySmBold,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              Row(children: [
                ...List.generate(5, (i) => Icon(
                    i < p.rating ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: 10, color: AppColors.warning)),
                const SizedBox(width: 4),
                if (p.sku != null) Text(p.sku!,
                    style: AppTextStyles.micro),
              ]),
            ])),
            Expanded(flex: 2, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.l10n.invCategoryLabel, style: AppTextStyles.micro),
              Text(p.categoryId ?? '—', style: AppTextStyles.captionHint
                  .copyWith(color: AppColors.onSurface),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
            Expanded(flex: 1, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.invStock, style: AppTextStyles.micro),
              Text('$stock', style: AppTextStyles.bodySmBold.copyWith(
                  color: isLow ? AppColors.error : Theme.of(context).colorScheme.onSurface)),
            ])),
            Expanded(flex: 2, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.invPriceLabel, style: AppTextStyles.micro),
              _PriceDisplay(product: p, compact: true),
            ])),
            Expanded(flex: 2, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.invVisibility, style: AppTextStyles.micro),
              if (isPartnerView)
                Text('—', style: AppTextStyles.captionHint)
              else
                Transform.scale(scale: 0.7, alignment: Alignment.centerLeft,
                    child: AppSwitch(value: p.isActive,
                        onChanged: widget.onToggleActive)),
            ])),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (p.variants.isNotEmpty)
                IconButton(
                  icon: Icon(_showVariants
                      ? Icons.expand_less : Icons.expand_more, size: 16),
                  onPressed: () => setState(() => _showVariants = !_showVariants),
                  color: AppColors.primary, padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  tooltip: _showVariants ? 'Masquer variantes' : 'Voir variantes',
                ),
              _ProductActionsMenu(
                shopId: widget.shopId,
                product: p,
                onTransfer: widget.onTransfer,
                onShare: widget.onShare,
                onShareWhatsApp: widget.onShareWhatsApp,
                onEdit: widget.onEdit,
                onDelete: widget.onDelete,
                onPromo: widget.onPromo,
                onDuplicate: widget.onDuplicate,
                iconSize: 16,
                isPartnerView: isPartnerView,
              ),
            ]),
          ]),
        ),
        if (_showVariants && p.variants.isNotEmpty)
          _VariantsSection(
            product: p,
            onChanged: widget.onProductChanged,
            isPartnerView: isPartnerView,
            partnerLocId:  partnerLocId,
            locationIds:   locIds,
          ),
      ]),
    );
  }
}

// ─── Mobile card ──────────────────────────────────────────────────────────────

class _MobileCard extends ConsumerStatefulWidget {
  final Product product;
  final String shopId;
  final ValueChanged<bool> onToggleActive, onToggleWeb;
  final VoidCallback onDelete, onEdit, onProductChanged, onTransfer, onShare,
      onShareWhatsApp, onPromo;
  final VoidCallback onDuplicate;
  const _MobileCard({required this.product, required this.shopId,
    required this.onToggleActive, required this.onToggleWeb,
    required this.onDelete, required this.onEdit,
    required this.onProductChanged, required this.onTransfer,
    required this.onShare,
    required this.onShareWhatsApp, required this.onPromo,
    required this.onDuplicate});
  @override ConsumerState<_MobileCard> createState() => _MobileCardState();
}

class _MobileCardState extends ConsumerState<_MobileCard> {
  bool _expanded     = false;
  bool _showVariants = false;

  /// Couleur du liseré gauche selon l'état du produit. La règle low-stock
  /// est calculée au périmètre courant (cf. `_isLowStockAt`).
  /// null → pas de liseré.
  Color? _leftIndicator(Product p, List<String>? locIds) {
    final noPrice = p.priceSellPos <= 0 &&
        !p.variants.any((v) => v.priceSellPos > 0);
    if (noPrice) return AppColors.error;
    if (_isLowStockAt(p, locIds)) return AppColors.warning;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final viewFilter = ref.watch(dashViewFilterProvider);
    final locIds     = _resolveLocationIds(viewFilter, widget.shopId);
    final stockAt    = _stockAtLocations(p, locIds);
    final indicator  = _leftIndicator(p, locIds);
    final isPartnerView = viewFilter != null && viewFilter != '_base';
    final partnerLocId  = isPartnerView ? viewFilter : null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
        // Liseré gauche coloré : orange si stock bas, rouge si sans prix.
        // Implémenté via un BorderSide épais à gauche (préservant le radius).
      ),
      // ClipRRect pour que le liseré respecte le border radius
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (indicator != null)
            Container(width: 3, color: indicator),
          Expanded(child: Column(children: [
            // ── Ligne principale ──────────────────────────────────────────
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  Stack(children: [
                    ProductImageCard(
                      imageUrl: p.mainImageUrl,
                      width:  34,
                      height: 34,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    Positioned(bottom: -1, right: -1,
                        child: UploadStatusDot(productId: p.id)),
                  ]),
                  const SizedBox(width: 10),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      Expanded(child: Text(p.name,
                          style: AppTextStyles.captionBold
                              .copyWith(color: Theme.of(context).colorScheme.onSurface),
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                      if (p.rating > 0) ...[
                        const SizedBox(width: 6),
                        _StarsRating(rating: p.rating),
                      ],
                    ]),
                    if ((p.sku ?? '').isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text('SKU : ${p.sku}',
                          style: AppTextStyles.micro,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 4),
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      if (p.isDraft) const _DraftBadge(),
                      if (p.categoryId != null && p.categoryId!.isNotEmpty)
                        Text(p.categoryId!,
                            style: AppTextStyles.microSecondary
                                .copyWith(fontWeight: FontWeight.w500)),
                      _StockBadge(stock: stockAt, min: p.stockMinAlert),
                      _PriceDisplay(product: p),
                      _MarginPill(product: p),
                    ]),
                  ])),
                  // Actions à droite — taille compacte
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    // Toggle visibilité (œil) — actif ↔ inactif. Caché en
                    // vue partenaire (le statut actif/inactif appartient à
                    // la boutique, pas au partenaire).
                    if (!isPartnerView)
                      IconButton(
                        icon: Icon(
                            p.isActive
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 17),
                        onPressed: () => widget.onToggleActive(!p.isActive),
                        color: p.isActive
                            ? AppColors.primary
                            : AppColors.textHint,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 28, minHeight: 28),
                        tooltip: p.isActive
                            ? context.l10n.invActiveInCaisse
                            : context.l10n.invActiveInCaisse,
                      ),
                    _ProductActionsMenu(
                      shopId: widget.shopId,
                      product: p,
                      onTransfer: widget.onTransfer,
                      onShare: widget.onShare,
                      onShareWhatsApp: widget.onShareWhatsApp,
                      onEdit: widget.onEdit,
                      onDelete: widget.onDelete,
                      onPromo: widget.onPromo,
                      onDuplicate: widget.onDuplicate,
                      iconSize: 17,
                      isPartnerView: isPartnerView,
                    ),
                    // Flèche expand/collapse avec rotation 180°
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(Icons.expand_more_rounded,
                          size: 20, color: AppColors.textSecondary),
                    ),
                    const SizedBox(width: 4),
                  ]),
                ]),
              ),
            ),

            // ── Résumé variantes (état fermé) ───────────────────────────
            if (!_expanded && p.variants.isNotEmpty)
              _VariantsSummary(product: p, locationIds: locIds),

        // Détails expandés
        if (_expanded) ...[
          Divider(height: 1, color: Theme.of(context).semantic.borderSubtle),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(children: [
              // Infos clés en grille 2 colonnes
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Theme.of(context).semantic.borderSubtle)),
                child: Column(children: [
                  _DetailRow('Prix achat',
                      p.priceBuy > 0 ? CurrencyFormatter.format(p.priceBuy) : '—'),
                  _DetailRowWidget(
                    label: context.l10n.invPriceLabel,
                    child: _PriceDisplay(product: p, compact: true),
                  ),
                  if (p.priceBuy > 0 && p.priceSellPos > 0) ...[
                    const SizedBox(height: 2),
                    _DetailRow('Marge',
                        '${((p.priceSellPos - p.priceBuy) / p.priceSellPos * 100).toStringAsFixed(1)}%',
                        valueColor: AppColors.secondary),
                  ],
                  _DetailRow('SKU', p.sku ?? '—'),
                  _DetailRow('Marque', p.brand ?? '—'),
                  _DetailRow('Alerte stock', '${p.stockMinAlert} unités'),
                ]),
              ),
              const SizedBox(height: 8),
              // Switches — masqués en vue Partenaire : ces propriétés
              // (actif en caisse, visible web) appartiennent au produit
              // côté boutique, pas au partenaire qui en détient seulement
              // une partie de stock via transfert.
              if (!isPartnerView)
                Row(children: [
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.l10n.invActiveInCaisse,
                        style: AppTextStyles.captionHint
                            .copyWith(color: AppColors.textSecondary)),
                    Transform.scale(scale: 0.85, alignment: Alignment.centerLeft,
                        child: AppSwitch(value: p.isActive,
                            onChanged: widget.onToggleActive)),
                  ])),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.l10n.invVisibleWeb,
                        style: AppTextStyles.captionHint
                            .copyWith(color: AppColors.textSecondary)),
                    Transform.scale(scale: 0.85, alignment: Alignment.centerLeft,
                        child: AppSwitch(value: p.isVisibleWeb,
                            onChanged: widget.onToggleWeb)),
                  ])),
                ]),
              // Bouton variantes si existantes
              if (p.variants.isNotEmpty) ...[
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () => setState(() => _showVariants = !_showVariants),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: AppColors.primarySurface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppColors.primary.withValues(alpha:0.3)),
                    ),
                    child: Row(children: [
                      Icon(Icons.layers_outlined, size: 14,
                          color: AppColors.primary),
                      const SizedBox(width: 6),
                      Text('${p.variants.length} variante(s)',
                          style: AppTextStyles.bodySmBold
                              .copyWith(color: AppColors.primary)),
                      const Spacer(),
                      Icon(_showVariants
                          ? Icons.expand_less : Icons.expand_more,
                          size: 16, color: AppColors.primary),
                    ]),
                  ),
                ),
                if (_showVariants)
                  _VariantsSection(
                    product: p,
                    onChanged: widget.onProductChanged,
                    isPartnerView: isPartnerView,
                    partnerLocId:  partnerLocId,
                    // Sans `locationIds`, `_VariantRow` retombe sur
                    // `variant.stockAvailable` (= 0 en modèle stock_levels)
                    // → stock variante affiché à 0 sur mobile alors que le
                    // desktop (qui passe locIds) montre la bonne valeur.
                    locationIds:   locIds,
                  ),
              ],
            ]),
          ),
        ],
          ])), // ← close Expanded(child: Column(children: [...]))
        ]),   // ← close Row(children: [...])
      ),      // ← close IntrinsicHeight
    );
  }
}

// ─── Badge brouillon ──────────────────────────────────────────────────────────

/// Marque une fiche commencée mais jamais publiée. Ambre comme les autres
/// signaux d'attention de l'inventaire.
class _DraftBadge extends StatelessWidget {
  const _DraftBadge();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: AppColors.warning.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text('Brouillon', style: AppTextStyles.micro.copyWith(
        color: AppColors.warning, fontWeight: FontWeight.w700)),
  );
}

// ─── Badge stock ──────────────────────────────────────────────────────────────

class _StockBadge extends StatelessWidget {
  final int stock, min;
  const _StockBadge({required this.stock, required this.min});

  @override
  Widget build(BuildContext context) {
    // 3 niveaux : rouge (rupture) → orange (bas) → vert (OK)
    final Color color;
    if (stock <= 0) {
      color = AppColors.error;
    } else if (stock <= min) {
      color = AppColors.warning;
    } else {
      color = AppColors.secondary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha:0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('${context.l10n.invStock}: $stock',
          style: AppTextStyles.microBold.copyWith(color: color)),
    );
  }
}

// ─── Pill marge moyenne (sur variantes avec priceSellPos > 0) ─────────────────

class _MarginPill extends StatelessWidget {
  final Product product;
  const _MarginPill({required this.product});

  double? _avgMargin() {
    final variants = product.variants.where((v) => v.priceSellPos > 0).toList();
    if (variants.isEmpty) return null;
    double sum = 0;
    for (final v in variants) {
      sum += (v.priceSellPos - v.priceBuy) / v.priceSellPos * 100;
    }
    return sum / variants.length;
  }

  @override
  Widget build(BuildContext context) {
    final margin = _avgMargin();
    final color  = AppColors.secondary; // vert du thème
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha:0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        margin == null ? '—' : '${margin.toStringAsFixed(0)}%',
        style: AppTextStyles.microBold.copyWith(color: color),
      ),
    );
  }
}

// ─── Étoiles de notation (rating 0..5) ────────────────────────────────────────

class _StarsRating extends StatelessWidget {
  final int rating; // 0..5
  const _StarsRating({required this.rating});

  @override
  Widget build(BuildContext context) {
    if (rating <= 0) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: List.generate(5, (i) {
      return Icon(
        i < rating ? Icons.star_rounded : Icons.star_outline_rounded,
        size: 11,
        color: i < rating ? AppColors.warning : AppColors.textHint,
      );
    }));
  }
}

// ─── Résumé variantes (état fermé de la card) ─────────────────────────────────
// Bande grise sous la ligne principale, pills compactes : nom variante + stock.
// Badge "Stock bas" aligné à droite si au moins une variante est sous alerte.

class _VariantsSummary extends StatelessWidget {
  final Product product;
  /// Emplacements de la vue active (cf. `_resolveLocationIds`). Le stock de
  /// chaque variante est la Σ de son stock sur ces emplacements — identique
  /// au tableau développé (`_VariantRow`) et au stock produit principal.
  /// Null/legacy sans id → repli `variant.stockAvailable`.
  final List<String>? locationIds;
  const _VariantsSummary({required this.product, this.locationIds});

  /// Stock affiché d'une variante = Σ stock_levels sur les emplacements de la
  /// vue (Globale = boutique + partenaires). Sans ça, on lisait
  /// `variant.stockAvailable` qui vaut 0 dans le modèle multi-emplacement →
  /// pills à « · 0 » sur mobile alors que le desktop montrait le bon stock.
  int _stockOf(ProductVariant v) => v.id == null
      ? v.stockAvailable
      : stock_loc.stockForVariantAtLocations(v, locationIds);

  /// Retourne une couleur sémantique selon le niveau de stock de la variante.
  Color _variantStatusColor(ProductVariant v) {
    final s = _stockOf(v);
    if (s <= 0) return AppColors.error;
    if (s <= v.stockMinAlert) return AppColors.warning;
    return AppColors.secondary;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final variants = product.variants;
    final hasLow = variants.any((v) {
      final s = _stockOf(v);
      return s > 0 && s <= v.stockMinAlert;
    });
    final hasOut = variants.any((v) => _stockOf(v) <= 0);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(11, 8, 11, 10),
      decoration: BoxDecoration(
        color: AppColors.background, // gris très clair du thème
        border: Border(top: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Pills scrollables si trop de variantes pour tenir sur une ligne
        Expanded(child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (int i = 0; i < variants.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _VariantPill(variant: variants[i],
                  stock: _stockOf(variants[i]),
                  statusColor: _variantStatusColor(variants[i])),
            ],
          ]),
        )),
        if (hasOut || hasLow) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: (hasOut ? AppColors.error : AppColors.warning)
                  .withValues(alpha:0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.warning_amber_rounded,
                  size: 11,
                  color: hasOut ? AppColors.error : AppColors.warning),
              const SizedBox(width: 3),
              Text(l.invLowStockLabel,
                  style: AppTextStyles.microBold.copyWith(
                      color: hasOut ? AppColors.error : AppColors.warning)),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _VariantPill extends StatelessWidget {
  final ProductVariant variant;
  /// Stock résolu sur la vue active (passé par `_VariantsSummary`), pas
  /// `variant.stockAvailable` qui vaut 0 dans le modèle multi-emplacement.
  final int stock;
  final Color statusColor;
  const _VariantPill({required this.variant, required this.stock,
      required this.statusColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        // Puce colorée statut
        Container(
          width: 6, height: 6,
          decoration: BoxDecoration(
              color: statusColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(variant.name,
            style: AppTextStyles.micro.copyWith(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface)),
        const SizedBox(width: 5),
        Text('· $stock',
            style: AppTextStyles.microBold.copyWith(color: statusColor)),
      ]),
    );
  }
}

// ─── Variantes section ────────────────────────────────────────────────────────

class _VariantsSection extends StatefulWidget {
  final Product product;
  final VoidCallback? onChanged;
  /// En vue Partenaire on ne montre QUE les variantes effectivement présentes
  /// chez ce partenaire (StockLevel > 0) et chaque ligne affiche le stock
  /// local. Hors vue partenaire, toutes les variantes sont visibles avec
  /// leur stockAvailable (= boutique).
  final bool isPartnerView;
  final String? partnerLocId;
  /// Emplacements résolus de la vue active (cf. `_resolveLocationIds`).
  /// Globale = tous (boutique + partenaires) → chaque variante affiche la
  /// SOMME de son stock sur ces emplacements, cohérent avec le stock
  /// produit du visuel principal. Null = repli `variant.stockAvailable`.
  final List<String>? locationIds;
  const _VariantsSection({required this.product, this.onChanged,
    this.isPartnerView = false, this.partnerLocId, this.locationIds});
  @override
  State<_VariantsSection> createState() => _VariantsSectionState();
}

class _VariantsSectionState extends State<_VariantsSection> {
  // Copie locale pour mise à jour instantanée de l'UI
  late List<ProductVariant> _variants;

  @override
  void initState() {
    super.initState();
    _variants = List.from(widget.product.variants);
  }

  @override
  void didUpdateWidget(_VariantsSection old) {
    super.didUpdateWidget(old);
    // Resync la copie locale dès que le Product change. On compare via
    // Equatable (Product.props inclut `variants`, et ProductVariant.props
    // inclut stockAvailable, prix, isMain, promo…) — donc toute édition
    // depuis la fiche produit (stock, prix, ordre, ajout/suppression) est
    // détectée. La condition restreinte précédente (id + mainId + listIds)
    // ratait les modifs de stock/prix : la copie locale figeait l'ancienne
    // valeur et l'utilisateur devait actualiser pour voir le résultat.
    if (old.product != widget.product) {
      _variants = List.from(widget.product.variants);
    }
  }

  // Mise à jour INSTANTANÉE : UI d'abord, Hive+Supabase en arrière-plan
  void _setMain(ProductVariant target) {
    // 1. Mettre à jour la copie locale IMMÉDIATEMENT → bouton change tout de suite
    final newVariants = _variants.map((v) =>
        v.copyWith(isMain: v.id == target.id)
    ).toList();
    setState(() => _variants = newVariants);

    // 2. Sauvegarder dans Hive + Supabase en arrière-plan
    final updated = widget.product.copyWith(variants: newVariants);
    AppDatabase.saveProduct(updated).then((_) {
      // 3. Notifier la grille caisse (page boutique) → image principale mise à jour
      final shopId = widget.product.storeId ?? '';
      AppDatabase.notifyListeners('products', shopId);
      // 4. Notifier InventairePageState → recharge la liste inventaire
      if (mounted) widget.onChanged?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // En vue partenaire on filtre les variantes : seules celles qui ont un
    // StockLevel > 0 chez ce partenaire sont visibles. Les variantes jamais
    // transférées ne doivent pas apparaître (sinon l'utilisateur croit que
    // le partenaire détient du stock alors qu'il n'a rien reçu).
    final shown = (widget.isPartnerView && widget.partnerLocId != null)
        ? _variants.where((v) {
            final vid = v.id;
            if (vid == null) return false;
            final lvl = AppDatabase.getStockLevel(vid, widget.partnerLocId!);
            return (lvl?.stockAvailable ?? 0) > 0;
          }).toList()
        : _variants;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.primarySurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.primary.withValues(alpha:0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.layers_outlined, size: 13, color: AppColors.primary),
          const SizedBox(width: 5),
          Text('${l.invVariantsLabel} (${shown.length})',
              style: AppTextStyles.captionBold
                  .copyWith(color: AppColors.primary)),
        ]),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              widget.isPartnerView
                  ? 'Aucune variante transférée chez ce partenaire.'
                  : 'Aucune variante.',
              style: AppTextStyles.captionHint
                  .copyWith(color: AppColors.textSecondary)),
          )
        else
          // Scrollable horizontal si l'écran est trop étroit pour toutes
          // les colonnes (prix achat / marge peuvent pousser le total > 360px).
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 548),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min, children: [
                const _VariantTableHeader(),
                ...shown.map((v) => _VariantRow(
                  variant: v,
                  product: widget.product,
                  onSetMain: v.isMain ? null : () => _setMain(v),
                  onChanged: widget.onChanged,
                  isPartnerView: widget.isPartnerView,
                  partnerLocId:  widget.partnerLocId,
                  locationIds:   widget.locationIds,
                )),
                const SizedBox(height: 6),
                // Pas d'ajout de variante en vue partenaire — la création
                // se fait depuis la fiche produit (boutique uniquement).
                if (!widget.isPartnerView)
                  _AddVariantButton(product: widget.product,
                      onChanged: widget.onChanged),
              ]),
            ),
          ),
      ]),
    );
  }
}

// ─── Header du tableau variantes ──────────────────────────────────────────────

class _VariantTableHeader extends StatelessWidget {
  const _VariantTableHeader();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: Row(children: [
        SizedBox(width: 160, child: _HeaderCell(l.invTableVariant)),
        SizedBox(width: 60,  child: _HeaderCell(l.invStock,        right: true)),
        SizedBox(width: 80,  child: _HeaderCell(l.invTableSellPrice, right: true)),
        SizedBox(width: 80,  child: _HeaderCell(l.invTableBuyPrice,  right: true)),
        SizedBox(width: 50,  child: _HeaderCell(l.invTableMargin,    right: true)),
        SizedBox(width: 118, child: _HeaderCell(l.invTableActions,   right: true)),
      ]),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String label;
  final bool right;
  const _HeaderCell(this.label, {this.right = false});

  @override
  Widget build(BuildContext context) => Text(label,
      textAlign: right ? TextAlign.right : TextAlign.left,
      style: AppTextStyles.microBold.copyWith(
          color: AppColors.textHint,
          letterSpacing: 0.3));
}

// ─── Ligne du tableau variantes ───────────────────────────────────────────────

class _VariantRow extends StatelessWidget {
  final ProductVariant variant;
  final Product        product;
  final VoidCallback?  onSetMain;
  final VoidCallback?  onChanged;
  /// Si vrai, on est en vue Partenaire : on affiche le stock local du
  /// partenaire (StockLevel) au lieu du stock global de la variante, et on
  /// masque les actions Modifier/Corriger/Marquer-principale (ces actions
  /// ne s'appliquent qu'à la boutique propriétaire du produit).
  final bool           isPartnerView;
  final String?        partnerLocId;
  /// Emplacements de la vue active (cf. `_resolveLocationIds`). Le stock
  /// affiché = Σ du stock de CETTE variante sur ces emplacements
  /// (Globale = boutique + partenaires), cohérent avec le stock produit
  /// du visuel principal. Null/legacy sans id → `variant.stockAvailable`.
  final List<String>?  locationIds;
  const _VariantRow({
    required this.variant, required this.product,
    this.onSetMain, this.onChanged,
    this.isPartnerView = false, this.partnerLocId, this.locationIds,
  });

  double? _margin() {
    if (variant.priceSellPos <= 0) return null;
    return (variant.priceSellPos - variant.priceBuy) /
        variant.priceSellPos * 100;
  }

  /// Ouvre la fiche produit pour permettre arrivée stock / modification.
  /// Si [focusVariantId] est fourni, le formulaire s'ouvre sur l'étape 2
  /// avec uniquement cette variante dépliée (les autres sont repliées).
  void _openProductForm(BuildContext context, {String? focusVariantId}) {
    final shopId = product.storeId ?? '';
    if (shopId.isEmpty || product.id == null) return;
    final extra = focusVariantId != null
        ? ProductFormExtra(product: product, focusVariantId: focusVariantId)
        : product;
    context.push('/shop/$shopId/inventaire/product', extra: extra)
        .then((_) => onChanged?.call());
  }

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;
    // Stock variante = Σ du stock de CETTE variante sur les emplacements
    // de la vue active (helper partagé, identique au calcul du stock
    // produit du visuel principal) :
    //   * Globale    → boutique + tous les partenaires (la somme attendue),
    //   * Boutique   → emplacements `type='shop'`,
    //   * Partenaire → ce partenaire uniquement.
    // Legacy : variante sans id → repli `variant.stockAvailable` (le helper
    // renverrait 0, ce qui masquerait à tort un stock boutique existant).
    final stockShown = variant.id == null
        ? variant.stockAvailable
        : stock_loc.stockForVariantAtLocations(variant, locationIds);
    final isLow  = stockShown > 0 && stockShown <= variant.stockMinAlert;
    final margin = _margin();
    final stockC = stockShown <= 0
        ? AppColors.error
        : (stockShown <= variant.stockMinAlert
            ? AppColors.warning
            : AppColors.secondary);

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: variant.isMain
                ? AppColors.primary.withValues(alpha:0.5)
                : Theme.of(context).semantic.borderSubtle,
            width: variant.isMain ? 1.2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(children: [
          if (isLow)
            Container(width: 2.5, color: AppColors.warning),
          // ── Col 1 : Variante (swatch + nom + SKU) ────────────────
          SizedBox(width: 160, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(children: [
              _VariantSwatch(variant: variant),
              const SizedBox(width: 6),
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Expanded(child: Text(variant.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.captionBold
                          .copyWith(color: Theme.of(context).colorScheme.onSurface))),
                  if (variant.isMain) ...[
                    const SizedBox(width: 3),
                    Icon(Icons.star_rounded, size: 11,
                        color: AppColors.primary),
                  ],
                ]),
                if ((variant.sku ?? '').isNotEmpty)
                  Text(variant.sku!,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.micro),
              ])),
            ]),
          )),
          // ── Col 2 : Stock coloré (local au filtre courant) ───────
          SizedBox(width: 60, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Align(alignment: Alignment.centerRight,
              child: Text('$stockShown',
                  style: AppTextStyles.bodySmBold.copyWith(
                      fontWeight: FontWeight.w800, color: stockC)))),
          ),
          // ── Col 3 : Prix vente ────────────────────────────────────
          SizedBox(width: 80, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Align(alignment: Alignment.centerRight,
              child: _VariantPriceDisplay(variant: variant))),
          ),
          // ── Col 4 : Prix achat ────────────────────────────────────
          SizedBox(width: 80, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Align(alignment: Alignment.centerRight,
              child: Text(
                  variant.priceBuy > 0
                      ? CurrencyFormatter.format(variant.priceBuy)
                      : '—',
                  style: AppTextStyles.captionBold))),
          ),
          // ── Col 5 : Marge pill ────────────────────────────────────
          SizedBox(width: 50, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Align(alignment: Alignment.centerRight,
              child: margin == null
                  ? Text('—',
                      style: AppTextStyles.micro)
                  : Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.secondary.withValues(alpha:0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('${margin.toStringAsFixed(0)}%',
                          style: AppTextStyles.microBold
                              .copyWith(color: AppColors.secondary)),
                    ))),
          ),
          // ── Col 6 : Actions (variante) — masquées en vue Partenaire,
          //          le stock partenaire ne peut être modifié qu'au moyen
          //          de transferts (cf. menu "…" → Transférer).
          if (isPartnerView)
            const SizedBox(width: 70)
          else
            SizedBox(width: 70, child: Row(
                mainAxisAlignment: MainAxisAlignment.end, children: [
              IconButton(
                tooltip: variant.isMain
                    ? l.invActionMainActive
                    : l.invActionSetMain,
                icon: Icon(
                    variant.isMain
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    size: 15),
                onPressed: variant.isMain ? null : onSetMain,
                color: variant.isMain
                    ? AppColors.primary
                    : AppColors.textHint,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                    minWidth: 26, minHeight: 26),
              ),
              IconButton(
                tooltip: 'Corriger le stock',
                icon: const Icon(Icons.edit_outlined, size: 14),
                onPressed: () async {
                  final pid = product.id;
                  final sid = product.storeId;
                  final vid = variant.id;
                  if (pid == null || sid == null || vid == null) {
                    _openProductForm(context, focusVariantId: variant.id);
                    return;
                  }
                  final ok = await showAdjustStockSheet(
                    context:   context,
                    variant:   variant,
                    shopId:    sid,
                    productId: pid,
                  );
                  if (ok) {
                    if (context.mounted) {
                      AppSnack.success(context, 'Stock corrigé avec succès');
                    }
                    onChanged?.call();
                  }
                },
                color: AppColors.textSecondary,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                    minWidth: 26, minHeight: 26),
              ),
            ])),
        ]),
      ),
    );
  }
}

// ─── Swatch (thumbnail mini + initiale en fallback) ───────────────────────────

class _VariantSwatch extends StatelessWidget {
  final ProductVariant variant;
  const _VariantSwatch({required this.variant});

  @override
  Widget build(BuildContext context) {
    final url = variant.imageUrl;
    final hasImg = url != null && url.isNotEmpty;

    if (hasImg) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 24, height: 24,
          // `CachedNetworkImage` pour le cache disque/IndexedDB persistant —
          // sans ça, le swatch reflashait à chaque reload web (cf. fix
          // images produit). Le fallback `_initials` couvre à la fois le
          // chargement (placeholder) et l'erreur réseau (errorWidget) :
          // c'est un repère lisible qui évite un trou visuel.
          child: url.startsWith('http')
              ? CachedNetworkImage(
                  // Swatch 24 px → vignette serveur ~96 px (rétina) au lieu de
                  // l'image brute → net + léger. Repli initials si erreur.
                  imageUrl: StorageService.thumbUrl(url, width: 96),
                  cacheKey: StorageService.thumbUrl(url, width: 96),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                  placeholder:  (_, __) => _initials(context),
                  errorWidget:  (_, __, ___) => _initials(context),
                )
              : Image.file(File(url), fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, __, ___) => _initials(context)),
        ),
      );
    }
    return _initials(context);
  }

  Widget _initials(BuildContext context) {
    final name = variant.name.trim();
    final letter = name.isEmpty ? '?' : name[0].toUpperCase();
    // Couleur basée sur le hash du nom → stable par variante
    final hue = (name.hashCode & 0x7FFFFFFF) % 360;
    final bg = HSLColor.fromAHSL(1, hue.toDouble(), 0.4, 0.85).toColor();
    final fg = HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.35).toColor();
    return Container(
      width: 24, height: 24,
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(4)),
      alignment: Alignment.center,
      child: Text(letter,
          style: AppTextStyles.captionBold
              .copyWith(fontWeight: FontWeight.w800, color: fg)),
    );
  }
}

// ─── Bouton "+ Ajouter une variante" (bordure pointillée) ────────────────────

class _AddVariantButton extends StatelessWidget {
  final Product product;
  final VoidCallback? onChanged;
  const _AddVariantButton({required this.product, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;
    final shopId = product.storeId ?? '';
    if (shopId.isEmpty || product.id == null) return const SizedBox.shrink();
    return InkWell(
      onTap: () => context
          .push('/shop/$shopId/inventaire/product',
              extra: ProductFormExtra(
                  product: product, addNewVariant: true))
          .then((_) => onChanged?.call()),
      borderRadius: BorderRadius.circular(6),
      child: DottedBorderBox(
        color: AppColors.primary,
        radius: 6,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          child: Row(mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.add_rounded, size: 14, color: AppColors.primary),
            const SizedBox(width: 5),
            Text(l.invAddVariant,
                style: AppTextStyles.captionBold
                    .copyWith(color: AppColors.primary)),
          ]),
        ),
      ),
    );
  }
}

// ─── Petit box à bordure pointillée (no dep externe) ──────────────────────────

class DottedBorderBox extends StatelessWidget {
  final Widget child;
  final Color color;
  final double radius;
  const DottedBorderBox({super.key,
      required this.child, required this.color, this.radius = 8});

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DottedBorderPainter(color: color, radius: radius),
    child: child,
  );
}

class _DottedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;
  _DottedBorderPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final rect = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rect);
    const dash = 3.0;
    const gap  = 3.0;
    for (final m in path.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DottedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

class _VariantPriceDisplay extends StatelessWidget {
  final ProductVariant variant;
  const _VariantPriceDisplay({required this.variant});

  bool get _isPromoActive {
    if (!variant.promoEnabled || variant.promoPrice == null) return false;
    final now = DateTime.now();
    final started  = variant.promoStart == null || !now.isBefore(variant.promoStart!);
    final notEnded = variant.promoEnd   == null || now.isBefore(variant.promoEnd!);
    return started && notEnded;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isPromoActive) {
      return Text(CurrencyFormatter.format(variant.priceSellPos),
          style: AppTextStyles.bodySmBold
              .copyWith(color: AppColors.primary));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text(CurrencyFormatter.format(variant.promoPrice!),
          style: AppTextStyles.bodySmBold
              .copyWith(color: AppColors.error)),
      Text(CurrencyFormatter.format(variant.priceSellPos),
          style: AppTextStyles.micro.copyWith(
              decoration: TextDecoration.lineThrough,
              decorationColor: AppColors.textHint)),
      if (variant.promoEnd != null)
        _PromoCountdown(end: variant.promoEnd!),
    ]);
  }
}

// ─── Detail row ───────────────────────────────────────────────────────────────

class _DetailRow extends StatelessWidget {
  final String label, value;
  final Color? valueColor;
  const _DetailRow(this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      Text(label, style: AppTextStyles.captionHint
          .copyWith(color: AppColors.textSecondary)),
      const Spacer(),
      Flexible(child: Text(value,
          style: AppTextStyles.bodySmBold
              .copyWith(color: valueColor ?? Theme.of(context).colorScheme.onSurface),
          textAlign: TextAlign.right, overflow: TextOverflow.ellipsis)),
    ]),
  );
}

class _DetailRowWidget extends StatelessWidget {
  final String label;
  final Widget child;
  const _DetailRowWidget({required this.label, required this.child});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      Text(label, style: AppTextStyles.captionHint
          .copyWith(color: AppColors.textSecondary)),
      const Spacer(),
      child,
    ]),
  );
}

// ─── Empty state ──────────────────────────────────────────────────────────────

class _NoResultState extends StatelessWidget {
  const _NoResultState();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Center(child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 64, height: 64,
            decoration: BoxDecoration(
                color: AppColors.inputFill, shape: BoxShape.circle),
            child: Icon(Icons.search_off_rounded, size: 28,
                color: AppColors.textHint)),
        const SizedBox(height: 16),
        Text(l.invNoResult, style: AppTextStyles.subtitleBold,
            textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(l.invNoResultHint,
            style: AppTextStyles.bodySmSecondary,
            textAlign: TextAlign.center),
      ]),
    ));
  }
}


// ─── Pagination ───────────────────────────────────────────────────────────────

class _Pagination extends StatelessWidget {
  final int page, total, count, perPage;
  final VoidCallback? onPrev, onNext;
  const _Pagination({required this.page, required this.total,
    required this.count, required this.perPage,
    required this.onPrev, required this.onNext});

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final start = ((page - 1) * perPage + 1).clamp(1, count);
    final end   = (page * perPage).clamp(1, count);
    final isCompact = MediaQuery.of(context).size.width < 900;
    // Mobile : hauteur ÷2 (vPad 8→4, btnPad vertical 8→4, fonts 13→11
    // et 12→10). Desktop : valeurs originales (vPad 8, font 12/11).
    final vPad   = isCompact ? 4.0 : 8.0;
    final btnPad = isCompact
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 6);
    final btnFs   = isCompact ? 11.0 : 12.0;
    final countFs = isCompact ? 10.0 : 11.0;
    final disabledColor = AppColors.textHint.withValues(alpha:0.6);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: vPad),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: Theme.of(context).semantic.borderSubtle, width: 0.5))),
      child: Row(children: [
        TextButton(
          onPressed: onPrev,
          style: TextButton.styleFrom(
              foregroundColor: onPrev != null
                  ? AppColors.textSecondary : disabledColor,
              minimumSize: Size.zero,
              padding: btnPad),
          child: Text(l.invPrevPage,
              style: AppTextStyles.body.copyWith(fontSize: btnFs,
                  fontWeight: FontWeight.w600)),
        ),
        const Spacer(),
        Text('$start–$end / $count',
            style: AppTextStyles.bodySm.copyWith(fontSize: countFs,
                color: AppColors.textSecondary)),
        const Spacer(),
        TextButton(
          onPressed: onNext,
          style: TextButton.styleFrom(
              foregroundColor: onNext != null
                  ? AppColors.textSecondary : disabledColor,
              minimumSize: Size.zero,
              padding: btnPad),
          child: Text(l.invNextPage,
              style: AppTextStyles.body.copyWith(fontSize: btnFs,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
} // fin _Pagination

// ─── Affichage prix avec gestion promotion ────────────────────────────────────

class _PriceDisplay extends StatelessWidget {
  final Product product;
  final bool compact;
  const _PriceDisplay({required this.product, this.compact = false});

  static bool _isPromoActive(ProductVariant v) {
    if (!v.promoEnabled || v.promoPrice == null || v.promoPrice! <= 0) return false;
    final now      = DateTime.now();
    final started  = v.promoStart == null || !now.isBefore(v.promoStart!);
    final notEnded = v.promoEnd   == null || now.isBefore(v.promoEnd!);
    return started && notEnded;
  }

  @override
  Widget build(BuildContext context) {
    final variants = product.variants;

    // Variante principale = celle marquée isMain, sinon index 0
    final main = variants.isEmpty ? null
        : variants.firstWhere((v) => v.isMain, orElse: () => variants[0]);

    // Prix de référence depuis la variante principale (ou prix produit)
    final basePrice = main?.priceSellPos ?? product.priceSellPos;
    if (basePrice <= 0) return const SizedBox.shrink();

    // Chercher une promo active : priorité à la variante principale
    ProductVariant? promoV;
    if (main != null && _isPromoActive(main)) {
      promoV = main;
    } else {
      for (final v in variants) {
        if (_isPromoActive(v)) { promoV = v; break; }
      }
    }

    if (promoV != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Text(CurrencyFormatter.format(promoV.promoPrice!),
              style: AppTextStyles.captionBold.copyWith(
                  fontSize: compact ? 11 : 10,
                  color: AppColors.error)),
          const SizedBox(width: 5),
          Text(CurrencyFormatter.format(promoV.priceSellPos),
              style: AppTextStyles.micro.copyWith(
                  decoration: TextDecoration.lineThrough,
                  decorationColor: AppColors.textHint)),
        ]),
        if (promoV.promoEnd != null)
          _PromoCountdown(end: promoV.promoEnd!),
      ]);
    }

    return Text(CurrencyFormatter.format(basePrice),
        style: AppTextStyles.captionBold.copyWith(
            fontSize: compact ? 11 : 10,
            color: AppColors.primary));
  }
}

class _PromoCountdown extends StatefulWidget {
  final DateTime end;
  const _PromoCountdown({required this.end});
  @override State<_PromoCountdown> createState() => _PromoCountdownState();
}

class _PromoCountdownState extends State<_PromoCountdown> {
  late Duration _remaining;

  @override
  void initState() {
    super.initState();
    _tick();
    Future.doWhile(() async {
      await Future.delayed(const Duration(minutes: 1));
      if (!mounted) return false;
      setState(() => _tick());
      return _remaining.inSeconds > 0;
    });
  }

  void _tick() {
    _remaining = widget.end.difference(DateTime.now());
    if (_remaining.isNegative) _remaining = Duration.zero;
  }

  @override
  Widget build(BuildContext context) {
    if (_remaining.inSeconds <= 0) {
      return Text('Promo terminée',
          style: AppTextStyles.micro);
    }
    final h = _remaining.inHours;
    final m = _remaining.inMinutes % 60;
    final d = _remaining.inDays;
    String label;
    if (d > 0) {
      label = '$d j ${h % 24}h';
    } else if (h > 0) {
      label = '${h}h${m.toString().padLeft(2,'0')}';
    } else {
      label = '< 1h';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha:0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.timer_outlined, size: 8, color: AppColors.error),
        const SizedBox(width: 2),
        Text(label,
            style: AppTextStyles.micro.copyWith(
                color: AppColors.error, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ─── Menu d'actions sur la ligne produit (Transférer / Partager / Modifier
// /  Supprimer). Items conditionnés par les permissions du shop.
class _ProductActionsMenu extends ConsumerWidget {
  final String shopId;
  final Product product;
  final VoidCallback onTransfer, onShare, onShareWhatsApp, onEdit, onDelete,
      onPromo, onDuplicate;
  final double iconSize;
  /// Si vrai, on est en vue Partenaire : Modifier et Supprimer sont masqués
  /// (le produit appartient à la boutique, pas au partenaire — toute édition
  /// se fait depuis la vue Globale ou Boutique seule). Transférer reste
  /// disponible pour permettre un retour de stock vers la boutique.
  final bool isPartnerView;
  const _ProductActionsMenu({
    required this.shopId,
    required this.product,
    required this.onTransfer,
    required this.onShare,
    required this.onShareWhatsApp,
    required this.onEdit,
    required this.onDelete,
    required this.onPromo,
    required this.onDuplicate,
    this.iconSize = 16,
    this.isPartnerView = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider(shopId));
    final shop  = LocalStorageService.getShop(shopId);
    final user  = LocalStorageService.getCurrentUser();
    // Transfert : réservé au propriétaire de la boutique (les warehouses /
    // dépôts partenaires sont rattachés à l'owner).
    final canTransfer = shop != null && user != null
        && shop.ownerId == user.id
        && perms.canEditProduct;

    final items = <PopupMenuEntry<String>>[];
    if (canTransfer) {
      items.add(PopupMenuItem<String>(
        value: 'transfer',
        child: Row(children: [
          Icon(Icons.swap_horiz_rounded, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          const Text('Transférer', style: AppTextStyles.body),
        ]),
      ));
    }
    items.add(PopupMenuItem<String>(
      value: 'share_whatsapp',
      child: Row(children: const [
        Icon(Icons.send_rounded, size: 16, color: Color(0xFF25D366)),
        SizedBox(width: 8),
        Text('Partager via WhatsApp', style: AppTextStyles.body),
      ]),
    ));
    // Lien pub Facebook : ouvre le catalogue directement sur ce produit
    // (deep-link `?product=`). À coller dans une carte de carrousel Meta.
    if (product.id != null) {
      items.add(PopupMenuItem<String>(
        value: 'copy_ad_link',
        child: Row(children: [
          Icon(Icons.link_rounded, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          const Text('Copier le lien du produit', style: AppTextStyles.body),
        ]),
      ));
    }
    if (perms.canEditProduct && !isPartnerView) {
      final promoActive = product.variants
          .any((v) => v.promoEnabled && (v.promoPrice ?? 0) > 0);
      items.add(PopupMenuItem<String>(
        value: 'promo',
        child: Row(children: [
          Icon(Icons.local_offer_outlined, size: 16,
              color: promoActive ? AppColors.secondary : AppColors.primary),
          const SizedBox(width: 8),
          Text(promoActive ? 'Promotion (active)' : 'Activer une promo',
              style: AppTextStyles.body.copyWith(
                  fontWeight: promoActive
                      ? FontWeight.w700 : FontWeight.w400,
                  color: promoActive ? AppColors.secondary : null)),
        ]),
      ));
      items.add(PopupMenuItem<String>(
        value: 'edit',
        child: Row(children: [
          Icon(Icons.edit_outlined, size: 16, color: AppColors.textSecondary),
          SizedBox(width: 8),
          Text('Modifier', style: AppTextStyles.body),
        ]),
      ));
      items.add(PopupMenuItem<String>(
        value: 'duplicate',
        child: Row(children: [
          Icon(Icons.copy_outlined, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          const Text('Dupliquer', style: AppTextStyles.body),
        ]),
      ));
    }
    if (perms.canDeleteProduct && !isPartnerView) {
      items.add(PopupMenuItem<String>(
        value: 'delete',
        child: Row(children: [
          const Icon(Icons.delete_outline, size: 16, color: AppColors.error),
          const SizedBox(width: 8),
          Text('Supprimer',
              style: AppTextStyles.body.copyWith(color: AppColors.error)),
        ]),
      ));
    }
    if (items.isEmpty) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      // Abonnement gelé → kebab grisé (consultation seule). Le menu
      // AppBar (AppOverflowMenu) reste, lui, actif.
      enabled: perms.hasActiveSubscription,
      icon: Icon(Icons.more_vert_rounded,
          size: iconSize, color: AppColors.textSecondary),
      padding: EdgeInsets.zero,
      tooltip: 'Plus d\'actions',
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onSelected: (v) {
        switch (v) {
          case 'transfer':       onTransfer();       break;
          case 'share':          onShare();          break;
          case 'share_whatsapp': onShareWhatsApp();  break;
          case 'copy_ad_link':   _copyAdLink(context); break;
          case 'promo':          onPromo();          break;
          case 'edit':           onEdit();           break;
          case 'duplicate':      onDuplicate();      break;
          case 'delete':         onDelete();         break;
        }
      },
      itemBuilder: (_) => items,
    );
  }

  /// Copie le lien pub Facebook du produit : ouvre le catalogue public
  /// directement sur ce produit (deep-link `?product=`). Origine via
  /// `Uri.base.origin` (runtime web), repli sur l'hôte déployé — même
  /// pattern que `client_detail_page` (zéro hardcode dur).
  void _copyAdLink(BuildContext context) {
    final origin = Uri.base.origin.startsWith('http')
        ? Uri.base.origin
        : 'https://fortress-pos.web.app';
    final url = '$origin/catalogue/$shopId?product=${product.id}';
    Clipboard.setData(ClipboardData(text: url));
    AppSnack.success(context, 'Lien du produit copié');
  }
}

// ─── Dialog : activation rapide d'une promo (sans page Modifier) ─────────
//
// Promo = champ par variante (promoEnabled / promoPrice / promoStart /
// promoEnd). Ici on expose l'essentiel : un switch + un prix promo par
// variante, et une date de fin optionnelle commune. Tout le reste (dates
// de début fines, etc.) reste dans la page Modifier.
class _QuickPromoDialog extends StatefulWidget {
  final Product product;
  final String  shopId;
  const _QuickPromoDialog({required this.product, required this.shopId});

  @override
  State<_QuickPromoDialog> createState() => _QuickPromoDialogState();
}

class _QuickPromoRow {
  bool enabled;
  final TextEditingController price;
  _QuickPromoRow({required this.enabled, required this.price});
}

class _QuickPromoDialogState extends State<_QuickPromoDialog> {
  late final List<_QuickPromoRow> _rows;
  DateTime? _end;
  String?   _error;
  bool      _saving = false;

  @override
  void initState() {
    super.initState();
    _rows = widget.product.variants.map((v) => _QuickPromoRow(
      enabled: v.promoEnabled,
      price: TextEditingController(
          text: (v.promoPrice ?? 0) > 0
              ? v.promoPrice!.toStringAsFixed(0) : ''),
    )).toList();
    // Date de fin commune : la plus tardive déjà posée sur une variante.
    for (final v in widget.product.variants) {
      if (v.promoEnd != null
          && (_end == null || v.promoEnd!.isAfter(_end!))) {
        _end = v.promoEnd;
      }
    }
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.price.dispose();
    }
    super.dispose();
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  Future<void> _pickEnd() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _end ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (picked != null) setState(() => _end = picked);
  }

  Future<void> _save() async {
    final variants = widget.product.variants;
    final newVariants = <ProductVariant>[];
    for (var i = 0; i < variants.length; i++) {
      final v = variants[i];
      final row = _rows[i];
      if (row.enabled) {
        final price = double.tryParse(row.price.text.trim().replaceAll(',', '.'));
        if (price == null || price <= 0) {
          setState(() => _error =
              'Prix promo invalide pour « ${v.name} ».');
          return;
        }
        if (price >= v.priceSellPos && v.priceSellPos > 0) {
          setState(() => _error =
              'Le prix promo doit être inférieur au prix normal '
              '(${CurrencyFormatter.format(v.priceSellPos)}) pour '
              '« ${v.name} ».');
          return;
        }
        newVariants.add(v.copyWith(
          promoEnabled: true,
          promoPrice:   price,
          promoStart:   v.promoStart ?? DateTime.now(),
          promoEnd:     _end ?? v.promoEnd,
        ));
      } else {
        newVariants.add(v.copyWith(promoEnabled: false));
      }
    }

    setState(() { _saving = true; _error = null; });
    try {
      final updated = widget.product.copyWith(variants: newVariants);
      await AppDatabase.saveProduct(updated);
      final activeCount = newVariants.where((v) => v.promoEnabled).length;
      await ActivityLogService.log(
        action:      'product_promo_quick',
        targetType:  'product',
        targetId:    widget.product.id,
        targetLabel: widget.product.name,
        shopId:      widget.shopId,
        details: {
          'variants_en_promo': activeCount,
          'fin': _end?.toIso8601String(),
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Échec de l\'enregistrement : $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final variants = widget.product.variants;
    final single = variants.length == 1;
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8)),
          child: Icon(Icons.local_offer_outlined,
              size: 16, color: AppColors.primary),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('Promotion',
              style: AppTextStyles.subtitleBold),
        ),
      ]),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.product.name,
                style: AppTextStyles.bodyBold),
            const SizedBox(height: 10),
            for (var i = 0; i < variants.length; i++)
              _buildVariantTile(variants[i], _rows[i], single),
            const SizedBox(height: 6),
            // Date de fin commune (optionnelle).
            InkWell(
              onTap: _pickEnd,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.inputFill,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.inputBorder),
                ),
                child: Row(children: [
                  Icon(Icons.event_outlined,
                      size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _end == null
                          ? 'Fin de promo (optionnel)'
                          : 'Fin : ${_fmtDate(_end!)}',
                      style: AppTextStyles.bodySmBold.copyWith(
                          color: _end == null
                              ? AppColors.textSecondary
                              : Theme.of(context).colorScheme.onSurface),
                    ),
                  ),
                  if (_end != null)
                    InkWell(
                      onTap: () => setState(() => _end = null),
                      child: Icon(Icons.close_rounded,
                          size: 16, color: AppColors.textSecondary),
                    ),
                ]),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: AppTextStyles.bodySmBold
                      .copyWith(color: AppColors.error)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary),
          child: _saving
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Enregistrer'),
        ),
      ],
    );
  }

  Widget _buildVariantTile(
      ProductVariant v, _QuickPromoRow row, bool single) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: row.enabled
            ? AppColors.primary.withValues(alpha: 0.05)
            : AppColors.inputFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: row.enabled
                ? AppColors.primary.withValues(alpha: 0.35)
                : AppColors.inputBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(single ? 'Activer la promo' : v.name,
                style: AppTextStyles.bodyBold),
          ),
          AppSwitch(
            value: row.enabled,
            onChanged: (val) => setState(() {
              row.enabled = val;
              _error = null;
            }),
          ),
        ]),
        if (!single)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
                'Prix normal : ${CurrencyFormatter.format(v.priceSellPos)}',
                style: AppTextStyles.captionHint
                    .copyWith(color: AppColors.textSecondary)),
          ),
        if (row.enabled) ...[
          const SizedBox(height: 10),
          if (single)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                  'Prix normal : ${CurrencyFormatter.format(v.priceSellPos)}',
                  style: AppTextStyles.captionHint
                      .copyWith(color: AppColors.textSecondary)),
            ),
          TextField(
            controller: row.price,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            style: AppTextStyles.input
                .copyWith(fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Prix promo',
              suffixText: 'FCFA',
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.inputBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.primary, width: 1.5),
              ),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      ]),
    );
  }
}

// ─── Dialog : sélection des variantes à partager ─────────────────────────
class _ShareVariantsPickerDialog extends StatefulWidget {
  final Product product;
  const _ShareVariantsPickerDialog({required this.product});

  @override
  State<_ShareVariantsPickerDialog> createState() =>
      _ShareVariantsPickerDialogState();
}

class _ShareVariantsPickerDialogState
    extends State<_ShareVariantsPickerDialog> {
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    // Par défaut : tout sélectionné. L'utilisateur décoche ce qu'il ne veut
    // pas partager.
    _selected = widget.product.variants
        .where((v) => v.id != null)
        .map((v) => v.id!)
        .toSet();
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == widget.product.variants.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(widget.product.variants
              .where((v) => v.id != null)
              .map((v) => v.id!));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final variants = widget.product.variants;
    final allSelected = _selected.length == variants.length;
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
              color: AppColors.secondary.withValues(alpha:0.14),
              borderRadius: BorderRadius.circular(8)),
          child: const Icon(Icons.share_outlined,
              size: 16, color: AppColors.secondary),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('Variantes à partager',
              style: AppTextStyles.subtitleBold),
        ),
      ]),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.product.name,
              style: AppTextStyles.bodyBold),
          const SizedBox(height: 8),
          // Tout / Rien
          InkWell(
            onTap: _toggleAll,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(allSelected
                    ? Icons.indeterminate_check_box_rounded
                    : Icons.check_box_outlined,
                    size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(allSelected
                    ? 'Tout désélectionner'
                    : 'Tout sélectionner',
                    style: AppTextStyles.bodySmBold
                        .copyWith(color: AppColors.primary)),
              ]),
            ),
          ),
          Divider(height: 12, color: Theme.of(context).semantic.borderSubtle),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: variants.length,
              itemBuilder: (_, i) {
                final v = variants[i];
                final id = v.id;
                if (id == null) return const SizedBox.shrink();
                final checked = _selected.contains(id);
                return InkWell(
                  onTap: () => setState(() {
                    if (checked) {
                      _selected.remove(id);
                    } else {
                      _selected.add(id);
                    }
                  }),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Icon(
                          checked
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 18,
                          color: checked
                              ? AppColors.primary
                              : AppColors.textHint),
                      const SizedBox(width: 8),
                      ProductImageCard(
                        imageUrl: v.imageUrl ?? widget.product.imageUrl,
                        width: 28, height: 28,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(v.name.isEmpty ? '—' : v.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.bodySmBold),
                        if ((v.sku ?? '').isNotEmpty)
                          Text('SKU ${v.sku}',
                              style: AppTextStyles.micro),
                      ])),
                      Text('${v.stockAvailable}',
                          style: AppTextStyles.captionBold),
                    ]),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text('Annuler',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
        ElevatedButton.icon(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.secondary,
            foregroundColor: Colors.white,
            disabledBackgroundColor: AppColors.secondary.withValues(alpha:0.35),
            elevation: 0,
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          icon: const Icon(Icons.share_outlined, size: 14),
          label: Text('Partager (${_selected.length})'),
        ),
      ],
    );
  }
}

// ─── Dialog : choisir UNE variante à partager (wa.me) ──────────────────────
class _PickOneVariantDialog extends StatefulWidget {
  final Product product;
  const _PickOneVariantDialog({required this.product});
  @override
  State<_PickOneVariantDialog> createState() => _PickOneVariantDialogState();
}

class _PickOneVariantDialogState extends State<_PickOneVariantDialog> {
  String? _selectedId; // null = partage le produit dans son ensemble

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      title: Text(p.name,
          style: AppTextStyles.label
              .copyWith(fontWeight: FontWeight.w800)),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      content: SizedBox(
        width: 320,
        child: ListView(
          shrinkWrap: true,
          children: [
            RadioListTile<String?>(
              value: null,
              groupValue: _selectedId,
              onChanged: (v) => setState(() => _selectedId = v),
              dense: true,
              activeColor: AppColors.primary,
              title: const Text('Produit complet (image principale)',
                  style: AppTextStyles.bodyBold),
              subtitle: Text('${p.totalStock} unité'
                  '${p.totalStock > 1 ? 's' : ''} au total',
                  style: AppTextStyles.captionHint),
            ),
            Divider(height: 8, color: Theme.of(context).semantic.borderSubtle),
            for (final v in p.variants)
              RadioListTile<String?>(
                value: v.id,
                groupValue: _selectedId,
                onChanged: (val) => setState(() => _selectedId = val),
                dense: true,
                activeColor: AppColors.primary,
                title: Text(v.name,
                    style: AppTextStyles.bodyBold),
                subtitle: Text('${v.stockAvailable} unité'
                    '${v.stockAvailable > 1 ? 's' : ''} · '
                    '${CurrencyFormatter.format(v.priceSellPos)}',
                    style: AppTextStyles.captionHint),
              ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Annuler'),
        ),
        ElevatedButton.icon(
          onPressed: () {
            final v = _selectedId == null
                ? null
                : p.variants.where((x) => x.id == _selectedId).firstOrNull;
            Navigator.of(context).pop(v);
          },
          icon: const Icon(Icons.send_rounded, size: 14),
          label: const Text('Partager'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF25D366),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ],
    );
  }
}

// ─── Dialog "Que partager ?" ──────────────────────────────────────────────

enum _CatalogueShareKind { all, category, location, selection }

/// Emplacement proposé dans le partage « Par emplacement » (boutique ou
/// partenaire actif de l'owner).
class _ShareLoc {
  final String id;
  final String name;
  final bool   isPartner;
  const _ShareLoc({
    required this.id,
    required this.name,
    required this.isPartner,
  });
}

class _CatalogueShareChoice {
  final _CatalogueShareKind kind;
  final String?             category;
  final String?             locationId;
  final String?             locationName;
  const _CatalogueShareChoice(this.kind, {
    this.category,
    this.locationId,
    this.locationName,
  });
}

class _CatalogueShareDialog extends StatefulWidget {
  final List<String>    categories;
  final List<_ShareLoc> locations;
  final bool            canUseSelection;
  final int             selectionCount;
  const _CatalogueShareDialog({
    required this.categories,
    required this.locations,
    required this.canUseSelection,
    required this.selectionCount,
  });

  @override
  State<_CatalogueShareDialog> createState() => _CatalogueShareDialogState();
}

class _CatalogueShareDialogState extends State<_CatalogueShareDialog> {
  late _CatalogueShareKind _kind;
  String? _category;
  String? _locationId;

  @override
  void initState() {
    super.initState();
    _kind = widget.canUseSelection
        ? _CatalogueShareKind.selection
        : _CatalogueShareKind.all;
    if (widget.categories.isNotEmpty) _category = widget.categories.first;
    if (widget.locations.isNotEmpty) _locationId = widget.locations.first.id;
  }

  bool get _canContinue {
    if (_kind == _CatalogueShareKind.category) return _category != null;
    if (_kind == _CatalogueShareKind.location) return _locationId != null;
    return true;
  }

  void _onContinue() {
    final loc = (_kind == _CatalogueShareKind.location && _locationId != null)
        ? widget.locations.firstWhere((e) => e.id == _locationId)
        : null;
    Navigator.of(context).pop(_CatalogueShareChoice(
      _kind,
      category: _kind == _CatalogueShareKind.category ? _category : null,
      locationId:   loc?.id,
      locationName: loc?.name,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
              child: Row(children: [
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(Icons.ios_share_rounded,
                      size: 19, color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Que partager ?',
                        style: AppTextStyles.subtitleBold
                            .copyWith(fontWeight: FontWeight.w800)),
                    Text('Choisissez le périmètre du catalogue',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.textHint)),
                  ],
                )),
              ]),
            ),
            // ── Options ─────────────────────────────────────────────────
            Flexible(child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
              child: Column(children: [
                _ShareOption(
                  icon:     Icons.storefront_rounded,
                  title:    'Tout le catalogue',
                  subtitle: 'Tous les produits visibles publiquement',
                  selected: _kind == _CatalogueShareKind.all,
                  onTap: () => setState(() => _kind = _CatalogueShareKind.all),
                ),
                if (widget.categories.isNotEmpty)
                  _ShareOption(
                    icon:     Icons.category_rounded,
                    title:    'Une catégorie',
                    subtitle: 'Filtre par catégorie de produit',
                    selected: _kind == _CatalogueShareKind.category,
                    onTap: () =>
                        setState(() => _kind = _CatalogueShareKind.category),
                    expanded: _kind == _CatalogueShareKind.category
                        ? _dropdown(
                            value:   _category,
                            items:   widget.categories,
                            labelOf: (c) => c,
                            hint:    'Catégorie',
                            onChanged: (v) => setState(() => _category = v),
                          )
                        : null,
                  ),
                if (widget.locations.isNotEmpty)
                  _ShareOption(
                    icon:     Icons.warehouse_rounded,
                    title:    'Par emplacement',
                    subtitle: 'Stock d\'un dépôt / partenaire précis',
                    selected: _kind == _CatalogueShareKind.location,
                    onTap: () =>
                        setState(() => _kind = _CatalogueShareKind.location),
                    expanded: _kind == _CatalogueShareKind.location
                        ? _dropdown(
                            value:   _locationId,
                            items:   widget.locations
                                .map((e) => e.id).toList(),
                            labelOf: (id) => widget.locations
                                .firstWhere((e) => e.id == id).name,
                            hint:    'Emplacement',
                            onChanged: (v) => setState(() => _locationId = v),
                          )
                        : null,
                  ),
                if (widget.canUseSelection)
                  _ShareOption(
                    icon:     Icons.check_circle_outline_rounded,
                    title:    'Sélection actuelle '
                        '(${widget.selectionCount} produit'
                        '${widget.selectionCount > 1 ? 's' : ''})',
                    subtitle: 'Uniquement les produits cochés',
                    selected: _kind == _CatalogueShareKind.selection,
                    onTap: () =>
                        setState(() => _kind = _CatalogueShareKind.selection),
                  ),
              ]),
            )),
            // ── Footer ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: Row(children: [
                Expanded(child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      padding: const EdgeInsets.symmetric(vertical: 13)),
                  child: const Text('Annuler'),
                )),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: ElevatedButton(
                  onPressed: _canContinue ? _onContinue : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.divider,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11)),
                  ),
                  child: const Text('Continuer'),
                )),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dropdown({
    required String? value,
    required List<String> items,
    required String Function(String) labelOf,
    required String hint,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isDense: true,
      isExpanded: true,
      hint: Text(hint, style: AppTextStyles.body
          .copyWith(color: AppColors.textHint)),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: Theme.of(context).colorScheme.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                BorderSide(color: AppColors.primary.withValues(alpha: 0.4))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                BorderSide(color: AppColors.primary.withValues(alpha: 0.4))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      ),
      items: items
          .map((c) => DropdownMenuItem(
              value: c,
              child: Text(labelOf(c),
                  style: AppTextStyles.body,
                  overflow: TextOverflow.ellipsis)))
          .toList(),
      onChanged: onChanged,
    );
  }
}

/// Carte d'option moderne pour le sélecteur de périmètre de partage.
class _ShareOption extends StatelessWidget {
  final IconData     icon;
  final String       title;
  final String       subtitle;
  final bool         selected;
  final VoidCallback onTap;
  final Widget?      expanded;
  const _ShareOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.primary;
    final sem    = Theme.of(context).semantic;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: selected ? accent.withValues(alpha: 0.06) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? accent : sem.borderSubtle,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Column(children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: selected
                      ? accent.withValues(alpha: 0.14)
                      : sem.elevatedSurface,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 18,
                    color: selected ? accent : AppColors.textSecondary),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: AppTextStyles.bodyBold,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 1),
                  Text(subtitle,
                      style: AppTextStyles.caption
                          .copyWith(color: AppColors.textHint),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              )),
              const SizedBox(width: 8),
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 20, height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: selected ? accent : const Color(0xFFCBD5E1),
                      width: 2),
                  color: selected ? accent : Colors.transparent,
                ),
                child: selected
                    ? const Icon(Icons.check_rounded,
                        size: 13, color: Colors.white)
                    : null,
              ),
            ]),
          ),
        ),
        if (expanded != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: expanded!,
          ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AUDIT STOCK (Couche 3) — bouton + dialog rapport
// ─────────────────────────────────────────────────────────────────────────────

/// Bouton 32×32 calé sur le style de `_StatusFilterPopupBtn` / `_MultiChip` —
/// même surface, même bordure, même taille d'icône, pour une rangée de
/// filtres visuellement homogène. Pas d'état "active" (déclencheur one-shot).
class _AuditStockBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _AuditStockBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    return SizedBox(
      width: 32, height: 32,
      child: Tooltip(
        message: 'Audit stock — détecte les divergences',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: sem.elevatedSurface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: sem.borderSubtle),
            ),
            child: Center(
              child: Icon(Icons.fact_check_rounded, size: 15,
                  color: cs.onSurface.withValues(alpha: 0.7)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bouton de téléchargement catalogue (CSV/PDF) dans la topbar
/// inventaire. Ouvre directement le `ExportScopeSelector` — pas de
/// passage par la page /exports pour ce raccourci.
class _ExportBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _ExportBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    // Icône `download_rounded` au lieu de `file_download_outlined` :
    // certaines variantes outlined Material ne sont pas embarquées par
    // le tree-shaker → glyphe invisible en web. Taille 18 (vs 15 sur
    // _AuditStockBtn) pour qu'on voie clairement que c'est cliquable.
    return SizedBox(
      width: 32, height: 32,
      child: Tooltip(
        message: 'Exporter le catalogue (CSV/PDF)',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: sem.elevatedSurface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: sem.borderSubtle),
            ),
            child: Center(
              child: Icon(Icons.download_rounded, size: 18,
                  color: cs.primary),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dialog récapitulatif du `ReconciliationReport`.
/// - Aucune divergence → état succès (vert).
/// - Drifts détectés → liste compacte avec bouton « Corriger » par ligne
///   qui appelle `StockService.applyAuditCorrection` (réaligne le stock sur
///   la valeur attendue + ferme l'incident automatiquement). La ligne
///   disparaît immédiatement de la liste après correction.
/// - Lien « Voir incidents » pour investigation manuelle.
class _StockAuditReportDialog extends StatefulWidget {
  final ReconciliationReport report;
  final String shopId;
  const _StockAuditReportDialog({required this.report, required this.shopId});

  @override
  State<_StockAuditReportDialog> createState() =>
      _StockAuditReportDialogState();
}

class _StockAuditReportDialogState extends State<_StockAuditReportDialog> {
  late List<ReconciliationResult> _drifts;
  final Set<String> _correcting = {};

  @override
  void initState() {
    super.initState();
    _drifts = List.from(widget.report.drifts);
  }

  Future<void> _correct(ReconciliationResult d) async {
    if (_correcting.contains(d.variantId)) return;
    setState(() => _correcting.add(d.variantId));
    final ok = await StockService.applyAuditCorrection(d);
    if (!mounted) return;
    setState(() {
      _correcting.remove(d.variantId);
      if (ok) _drifts.removeWhere((x) => x.variantId == d.variantId);
    });
    if (ok) {
      AppSnack.success(context,
          'Stock corrigé pour ${d.productName} — ${d.variantName}');
    } else {
      AppSnack.error(context,
          'Correction échouée pour ${d.productName} — ${d.variantName}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ok = _drifts.isEmpty;
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: (ok ? AppColors.secondary : AppColors.warning)
                .withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            ok ? Icons.check_circle_outline : Icons.warning_amber_rounded,
            size: 18,
            color: ok ? AppColors.secondary : AppColors.warning,
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('Audit stock', style: AppTextStyles.subtitleBold),
        ),
      ]),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ok
                  ? '${widget.report.totalVariants} variante(s) vérifiée(s) — '
                      'aucune divergence à corriger.'
                  : '${widget.report.totalVariants} variante(s) vérifiée(s) — '
                      '${_drifts.length} invariant(s) à corriger.',
              style: AppTextStyles.body,
            ),
            const SizedBox(height: 4),
            Text(
              widget.report.autoHealedCount > 0
                  ? 'Durée : ${widget.report.duration.inMilliseconds} ms · '
                      '${widget.report.autoHealedCount} drift(s) log auto-réalignés '
                      'en silence (invariant déjà cohérent).'
                  : 'Durée : ${widget.report.duration.inMilliseconds} ms',
              style: AppTextStyles.caption,
            ),
            if (!ok) ...[
              const SizedBox(height: 8),
              Text(
                '« Corriger » aligne disponible sur (physique − bloqué) '
                'pour restaurer la cohérence interne et le journal. Si le '
                'bon chiffre est différent, fais plutôt un ajustement '
                'manuel depuis la fiche produit.',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _drifts.length,
                    separatorBuilder: (_, __) => const Divider(height: 16),
                    itemBuilder: (_, i) {
                      final d = _drifts[i];
                      final busy = _correcting.contains(d.variantId);
                      // Layout vertical : texte plein largeur en haut,
                      // bouton aligné à droite en bas. Évite tout risque
                      // d'Expanded à 0px sur viewport étroit qui ferait
                      // wrapper le texte caractère par caractère.
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${d.productName} — ${d.variantName}',
                            style: AppTextStyles.bodyBold,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Physique ${d.physical} · Dispo ${d.actual} · '
                            'Bloqué ${d.blocked} '
                            '→ cohérent ${d.coherentAvailable}',
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.warning,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            d.diagnostic,
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: busy
                                ? const SizedBox(
                                    width: 18, height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : OutlinedButton.icon(
                                    icon: const Icon(
                                        Icons.settings_backup_restore_rounded,
                                        size: 14),
                                    label: Text('Corriger',
                                        style: AppTextStyles.captionBold),
                                    onPressed: () => _correct(d),
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 4),
                                      minimumSize: const Size(0, 32),
                                      foregroundColor: AppColors.primary,
                                      side: BorderSide(
                                          color: AppColors.primary
                                              .withValues(alpha: 0.4)),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8)),
                                    ),
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!ok)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              context.push('/shop/${widget.shopId}/inventaire/incidents');
            },
            child: const Text('Voir incidents'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}
