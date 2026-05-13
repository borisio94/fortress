import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/danger_action_service.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/app_switch.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../../../shared/widgets/view_filter_chip_bar.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/database/app_database.dart';
import '../../../../features/dashboard/data/dashboard_providers.dart';
import '../../domain/entities/stock_location.dart';
import '../../domain/stock_at_location.dart' as stock_loc;
import '../../../../core/services/activity_log_service.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import 'product_form_page.dart' show ProductFormExtra;
import '../../../../core/services/document_service.dart';
import '../../../../core/services/external_launcher.dart';
import '../../../../core/services/whatsapp/message_templates.dart';
import '../../../../core/services/whatsapp_service.dart';
import '../widgets/recipient_picker_sheet.dart';
import '../widgets/share_catalog_dialog.dart';
import '../widgets/adjust_stock_dialog.dart';
import '../../../../shared/widgets/blocked_delete_dialog.dart';
import '../../../parametres/presentation/widgets/transfer_form_sheet.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../../subscription/presentation/widgets/subscription_guard.dart';

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

  // Filtre actif par chip
  String _activeChip = 'all'; // all | active | inactive | low_stock | no_price

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

  /// Construit le snapshot `productId|variantId → stock` filtré par la
  /// vue active (`_locIds`), à embarquer dans l'URL du catalogue partagé
  /// pour que le client voie le stock du périmètre choisi par le
  /// marchand (Globale / Boutique seule / Partenaire X), pas le cumul
  /// brut Supabase. Cf. `stock_at_location.dart` pour la logique.
  Map<String, int> _buildStockSnapshot(List<Product> products) {
    final m = <String, int>{};
    for (final p in products) {
      final pid = p.id;
      if (pid == null) continue;
      if (p.variants.isEmpty) {
        m[pid] = stock_loc.stockAtLocations(p, _locIds);
      } else {
        for (final v in p.variants) {
          final vid = v.id;
          if (vid == null) continue;
          m['$pid|$vid'] = stock_loc.stockForVariantAtLocations(v, _locIds);
        }
      }
    }
    return m;
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
    await context.push('/shop/${widget.shopId}/inventaire/product');
    _load(); _syncFromSupabase();
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
    final msg = MessageTemplates.buildProductShareMessage(
      product:  p,
      variant:  variant,
      currency: CurrencyFormatter.currentSymbol,
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
  /// `https://<host>/#/catalogue/<shopId>`. Plus besoin de générer / uploader
  /// un PDF — la page publique est dynamique (toujours à jour) et ouvre
  /// directement le catalogue dans le navigateur du client.
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
    final choice = await showDialog<_CatalogueShareChoice>(
      context: context,
      builder: (ctx) => _CatalogueShareDialog(
        categories:    categories,
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
    if (choice.kind == _CatalogueShareKind.category &&
        choice.category != null && choice.category!.isNotEmpty) {
      qp['cat'] = choice.category!;
    } else if (choice.kind == _CatalogueShareKind.selection) {
      qp['ids'] = selectedIds.join(',');
    }
    final qpString = qp.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final url = qpString.isEmpty
        ? '$origin/#/catalogue/${widget.shopId}'
        : '$origin/#/catalogue/${widget.shopId}?$qpString';

    // 3) Choix du destinataire WhatsApp.
    final phone = await pickWhatsappRecipient(
        context, shopId: widget.shopId);
    if (phone == null || phone.isEmpty) return;
    if (!mounted) return;

    final shop = LocalStorageService.getShop(widget.shopId);
    final shopName = shop?.name ?? '';
    String label;
    switch (choice.kind) {
      case _CatalogueShareKind.category:
        label = 'la sélection « ${choice.category} »';
        break;
      case _CatalogueShareKind.selection:
        label = '${selectedIds.length} produit${selectedIds.length > 1 ? 's' : ''} sélectionné${selectedIds.length > 1 ? 's' : ''}';
        break;
      case _CatalogueShareKind.all:
        label = 'notre catalogue';
        break;
    }
    final msg = (shopName.isEmpty
            ? 'Découvrez $label :\n$url'
            : 'Bonjour, découvrez $label de $shopName :\n$url')
        + '\n\nVous pouvez parcourir nos produits et passer commande directement.';

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
      await DocumentService.shareProduct(p, shopId: widget.shopId);
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
    await DocumentService.shareProduct(filtered, shopId: widget.shopId);
  }
  Future<void> _delete(String id) async {
    final p = _products.where((p) => p.id == id).firstOrNull;
    try {
      await AppDatabase.deleteProduct(id);
    } catch (e) {
      if (!mounted) return;
      if (p == null) return;
      final choice = await showBlockedDeleteDialog(
        context,
        itemLabel: p.name,
        reason: e.toString().replaceAll('Exception: ', ''),
        archiveDescription:
            'Le produit sera désactivé : plus visible à la caisse, dans '
            'les listes ni à la vente. L\'historique de ses ventes passées '
            'reste intact.',
      );
      if (choice == BlockedDeleteChoice.archive) {
        await AppDatabase.saveProduct(
            p.copyWith(isActive: false), skipValidation: true);
        if (mounted) AppSnack.success(context, 'Produit archivé');
        _load();
      }
      return;
    }
    if (p != null) {
      ActivityLogService.log(
        action:      'product_deleted',
        targetType:  'product',
        targetId:    id,
        targetLabel: p.name,
        shopId:      p.storeId,
      );
    }
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
                style: TextStyle(fontSize: 13,
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
                      : Colors.white,
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
                            : AppColors.divider),
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
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: l.inventaireSearch,
                    hintStyle: const TextStyle(fontSize: 12,
                        color: AppColors.textHint),
                    prefixIcon: const Icon(Icons.search_rounded,
                        size: 18, color: AppColors.textHint),
                    filled: true, fillColor: Colors.white, isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.divider)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.divider)),
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
                  style: const TextStyle(fontSize: 11,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w500)),
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
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary)),
                ),
              ),
            ),
            // ── Droite : dropdown per-page ──
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(l.invPerPage,
                      style: const TextStyle(fontSize: 11,
                          color: AppColors.textSecondary)),
                  const SizedBox(width: 6),
                  Theme(
                    data: Theme.of(context).copyWith(
                      canvasColor: Colors.white,
                      colorScheme: Theme.of(context).colorScheme.copyWith(
                          surface: Colors.white,
                          onSurface: AppColors.textPrimary),
                    ),
                    child: DropdownButton<int>(
                      value: _perPage, isDense: true,
                      underline: const SizedBox.shrink(),
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      style: const TextStyle(fontSize: 12,
                          color: AppColors.textPrimary),
                      items: [10, 25, 50].map((n) => DropdownMenuItem(
                        value: n,
                        child: Text('$n', style: const TextStyle(
                            fontSize: 12, color: AppColors.textPrimary)),
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
                          style: const TextStyle(fontSize: 13,
                              fontWeight: FontWeight.w700)),
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
                        ShareCatalogDialog.show(context,
                            products: _products, shopId: widget.shopId,
                            preSelected: products,
                            stockSnapshot: snapshot);
                      },
                      icon: const Icon(Icons.share_rounded, size: 16),
                      label: const Text('Partager',
                          style: TextStyle(fontSize: 13,
                              fontWeight: FontWeight.w700)),
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
                style: TextStyle(
                    fontSize: 13,
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
                  style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
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
                      style: TextStyle(fontSize: 12,
                          color: AppColors.textSecondary)),
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
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: sel
                                    ? FontWeight.w600 : FontWeight.w400,
                                color: sel ? AppColors.primary
                                    : AppColors.textPrimary))),
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
                          style: TextStyle(fontSize: 12,
                              color: AppColors.error,
                              fontWeight: FontWeight.w600)),
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
        color: active ? AppColors.primarySurface : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: active ? AppColors.primary : AppColors.divider),
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
      onShareWhatsApp;
  const _DesktopRow({required this.product, required this.shopId,
    required this.onToggleActive, required this.onToggleWeb,
    required this.onDelete, required this.onEdit,
    required this.onProductChanged, required this.onTransfer,
    required this.onShare,
    required this.onShareWhatsApp});
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            ProductImageCard(
              imageUrl: p.mainImageUrl,
              width:  64,
              height: 64,
              borderRadius: BorderRadius.circular(8),
            ),
            const SizedBox(width: 10),
            Expanded(flex: 3, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: const TextStyle(fontSize: 12,
                  fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              Row(children: [
                ...List.generate(5, (i) => Icon(
                    i < p.rating ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: 10, color: AppColors.warning)),
                const SizedBox(width: 4),
                if (p.sku != null) Text(p.sku!,
                    style: const TextStyle(fontSize: 9, color: AppColors.textHint)),
              ]),
            ])),
            Expanded(flex: 2, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.l10n.invCategoryLabel, style: const TextStyle(fontSize: 9, color: AppColors.textHint)),
              Text(p.categoryId ?? '—', style: const TextStyle(fontSize: 11,
                  color: Color(0xFF374151)),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
            Expanded(flex: 1, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.invStock, style: const TextStyle(fontSize: 9, color: AppColors.textHint)),
              Text('$stock', style: TextStyle(fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isLow ? AppColors.error : AppColors.textPrimary)),
            ])),
            Expanded(flex: 2, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.invPriceLabel, style: const TextStyle(fontSize: 9, color: AppColors.textHint)),
              _PriceDisplay(product: p, compact: true),
            ])),
            Expanded(flex: 2, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.invVisibility, style: const TextStyle(fontSize: 9, color: AppColors.textHint)),
              if (isPartnerView)
                const Text('—', style: TextStyle(fontSize: 11,
                    color: AppColors.textHint))
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
      onShareWhatsApp;
  const _MobileCard({required this.product, required this.shopId,
    required this.onToggleActive, required this.onToggleWeb,
    required this.onDelete, required this.onEdit,
    required this.onProductChanged, required this.onTransfer,
    required this.onShare,
    required this.onShareWhatsApp});
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
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
                  ProductImageCard(
                    imageUrl: p.mainImageUrl,
                    width:  34,
                    height: 34,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      Expanded(child: Text(p.name,
                          style: const TextStyle(fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary),
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                      if (p.rating > 0) ...[
                        const SizedBox(width: 6),
                        _StarsRating(rating: p.rating),
                      ],
                    ]),
                    if ((p.sku ?? '').isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text('SKU : ${p.sku}',
                          style: const TextStyle(fontSize: 9,
                              color: AppColors.textHint),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 4),
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      if (p.categoryId != null && p.categoryId!.isNotEmpty)
                        Text(p.categoryId!,
                            style: const TextStyle(fontSize: 10,
                                color: AppColors.textSecondary,
                                fontWeight: FontWeight.w500)),
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
                      iconSize: 17,
                      isPartnerView: isPartnerView,
                    ),
                    // Flèche expand/collapse avec rotation 180°
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.expand_more_rounded,
                          size: 20, color: AppColors.textSecondary),
                    ),
                    const SizedBox(width: 4),
                  ]),
                ]),
              ),
            ),

            // ── Résumé variantes (état fermé) ───────────────────────────
            if (!_expanded && p.variants.isNotEmpty)
              _VariantsSummary(product: p),

        // Détails expandés
        if (_expanded) ...[
          const Divider(height: 1, color: AppColors.divider),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(children: [
              // Infos clés en grille 2 colonnes
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.divider)),
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
                        style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                    Transform.scale(scale: 0.85, alignment: Alignment.centerLeft,
                        child: AppSwitch(value: p.isActive,
                            onChanged: widget.onToggleActive)),
                  ])),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.l10n.invVisibleWeb,
                        style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
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
                          style: TextStyle(fontSize: 12,
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600)),
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
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color)),
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
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
            color: color),
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
  const _VariantsSummary({required this.product});

  /// Retourne une couleur sémantique selon le niveau de stock de la variante.
  Color _variantStatusColor(ProductVariant v) {
    if (v.stockAvailable <= 0) return AppColors.error;
    if (v.stockAvailable <= v.stockMinAlert) return AppColors.warning;
    return AppColors.secondary;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final variants = product.variants;
    final hasLow = variants.any((v) =>
        v.stockAvailable > 0 && v.stockAvailable <= v.stockMinAlert);
    final hasOut = variants.any((v) => v.stockAvailable <= 0);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(11, 8, 11, 10),
      decoration: BoxDecoration(
        color: AppColors.background, // gris très clair du thème
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Pills scrollables si trop de variantes pour tenir sur une ligne
        Expanded(child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (int i = 0; i < variants.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _VariantPill(variant: variants[i],
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
                  style: TextStyle(fontSize: 10,
                      fontWeight: FontWeight.w700,
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
  final Color statusColor;
  const _VariantPill({required this.variant, required this.statusColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.divider),
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
            style: const TextStyle(fontSize: 10,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary)),
        const SizedBox(width: 5),
        Text('· ${variant.stockAvailable}',
            style: TextStyle(fontSize: 10,
                fontWeight: FontWeight.w700,
                color: statusColor)),
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
  const _VariantsSection({required this.product, this.onChanged,
    this.isPartnerView = false, this.partnerLocId});
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
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                  color: AppColors.primary)),
        ]),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              widget.isPartnerView
                  ? 'Aucune variante transférée chez ce partenaire.'
                  : 'Aucune variante.',
              style: const TextStyle(fontSize: 11,
                  color: AppColors.textSecondary)),
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
      style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
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
  const _VariantRow({
    required this.variant, required this.product,
    this.onSetMain, this.onChanged,
    this.isPartnerView = false, this.partnerLocId,
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
    // En vue partenaire, on lit le StockLevel local du partenaire — c'est
    // ce stock qui a été effectivement transféré chez ce partenaire. Sinon
    // on lit le stockAvailable de la variante (= stock boutique).
    final stockShown = (isPartnerView && partnerLocId != null && variant.id != null)
        ? (AppDatabase.getStockLevel(variant.id!, partnerLocId!)?.stockAvailable ?? 0)
        : variant.stockAvailable;
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: variant.isMain
                ? AppColors.primary.withValues(alpha:0.5)
                : AppColors.divider,
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
                      style: const TextStyle(fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary))),
                  if (variant.isMain) ...[
                    const SizedBox(width: 3),
                    Icon(Icons.star_rounded, size: 11,
                        color: AppColors.primary),
                  ],
                ]),
                if ((variant.sku ?? '').isNotEmpty)
                  Text(variant.sku!,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9,
                          color: AppColors.textHint)),
              ])),
            ]),
          )),
          // ── Col 2 : Stock coloré (local au filtre courant) ───────
          SizedBox(width: 60, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Align(alignment: Alignment.centerRight,
              child: Text('$stockShown',
                  style: TextStyle(fontSize: 12,
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
                  style: const TextStyle(fontSize: 11,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600)))),
          ),
          // ── Col 5 : Marge pill ────────────────────────────────────
          SizedBox(width: 50, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Align(alignment: Alignment.centerRight,
              child: margin == null
                  ? const Text('—',
                      style: TextStyle(fontSize: 10,
                          color: AppColors.textHint))
                  : Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.secondary.withValues(alpha:0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('${margin.toStringAsFixed(0)}%',
                          style: TextStyle(fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.secondary)),
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
          child: url.startsWith('http')
              ? Image.network(url, fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, __, ___) => _initials(context))
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
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800,
              color: fg)),
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
                style: TextStyle(fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary)),
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
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
              color: AppColors.primary));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text(CurrencyFormatter.format(variant.promoPrice!),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
              color: AppColors.error)),
      Text(CurrencyFormatter.format(variant.priceSellPos),
          style: const TextStyle(fontSize: 9, color: AppColors.textHint,
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
      Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      const Spacer(),
      Flexible(child: Text(value,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
              color: valueColor ?? AppColors.textPrimary),
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
      Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
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
            child: const Icon(Icons.search_off_rounded, size: 28,
                color: AppColors.textHint)),
        const SizedBox(height: 16),
        Text(l.invNoResult, style: const TextStyle(
            fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(l.invNoResultHint,
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
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
          border: Border(top: BorderSide(color: AppColors.divider, width: 0.5))),
      child: Row(children: [
        TextButton(
          onPressed: onPrev,
          style: TextButton.styleFrom(
              foregroundColor: onPrev != null
                  ? AppColors.textSecondary : disabledColor,
              minimumSize: Size.zero,
              padding: btnPad),
          child: Text(l.invPrevPage,
              style: TextStyle(fontSize: btnFs,
                  fontWeight: FontWeight.w600)),
        ),
        const Spacer(),
        Text('$start–$end / $count',
            style: TextStyle(fontSize: countFs,
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
              style: TextStyle(fontSize: btnFs,
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
              style: TextStyle(
                  fontSize: compact ? 11 : 10,
                  fontWeight: FontWeight.w700,
                  color: AppColors.error)),
          const SizedBox(width: 5),
          Text(CurrencyFormatter.format(promoV.priceSellPos),
              style: const TextStyle(
                  fontSize: 9,
                  color: AppColors.textHint,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: AppColors.textHint)),
        ]),
        if (promoV.promoEnd != null)
          _PromoCountdown(end: promoV.promoEnd!),
      ]);
    }

    return Text(CurrencyFormatter.format(basePrice),
        style: TextStyle(
            fontSize: compact ? 11 : 10,
            fontWeight: FontWeight.w700,
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
      return const Text('Promo terminée',
          style: TextStyle(fontSize: 8, color: AppColors.textHint));
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
            style: TextStyle(fontSize: 8, color: AppColors.error,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ─── Menu d'actions sur la ligne produit (Transférer / Partager / Modifier
// /  Supprimer). Items conditionnés par les permissions du shop.
class _ProductActionsMenu extends ConsumerWidget {
  final String shopId;
  final Product product;
  final VoidCallback onTransfer, onShare, onShareWhatsApp, onEdit, onDelete;
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
          const Text('Transférer', style: TextStyle(fontSize: 13)),
        ]),
      ));
    }
    items.add(PopupMenuItem<String>(
      value: 'share_whatsapp',
      child: Row(children: const [
        Icon(Icons.send_rounded, size: 16, color: Color(0xFF25D366)),
        SizedBox(width: 8),
        Text('Partager via WhatsApp', style: TextStyle(fontSize: 13)),
      ]),
    ));
    items.add(PopupMenuItem<String>(
      value: 'share',
      child: Row(children: [
        Icon(Icons.share_outlined, size: 16, color: AppColors.secondary),
        const SizedBox(width: 8),
        const Text('Partager', style: TextStyle(fontSize: 13)),
      ]),
    ));
    if (perms.canEditProduct && !isPartnerView) {
      items.add(const PopupMenuItem<String>(
        value: 'edit',
        child: Row(children: [
          Icon(Icons.edit_outlined, size: 16, color: AppColors.textSecondary),
          SizedBox(width: 8),
          Text('Modifier', style: TextStyle(fontSize: 13)),
        ]),
      ));
    }
    if (perms.canDeleteProduct && !isPartnerView) {
      items.add(const PopupMenuItem<String>(
        value: 'delete',
        child: Row(children: [
          Icon(Icons.delete_outline, size: 16, color: AppColors.error),
          SizedBox(width: 8),
          Text('Supprimer',
              style: TextStyle(fontSize: 13, color: AppColors.error)),
        ]),
      ));
    }
    if (items.isEmpty) return const SizedBox.shrink();

    return PopupMenuButton<String>(
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
          case 'edit':           onEdit();           break;
          case 'delete':         onDelete();         break;
        }
      },
      itemBuilder: (_) => items,
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
      backgroundColor: Colors.white,
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
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      ]),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.product.name,
              style: const TextStyle(fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
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
                    style: TextStyle(fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary)),
              ]),
            ),
          ),
          const Divider(height: 12, color: AppColors.divider),
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
                            style: const TextStyle(fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary)),
                        if ((v.sku ?? '').isNotEmpty)
                          Text('SKU ${v.sku}',
                              style: const TextStyle(fontSize: 10,
                                  color: AppColors.textHint)),
                      ])),
                      Text('${v.stockAvailable}',
                          style: const TextStyle(fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textSecondary)),
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
          child: const Text('Annuler',
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
          style: const TextStyle(fontSize: 14,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary)),
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
                  style: TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w600)),
              subtitle: Text('${p.totalStock} unité'
                  '${p.totalStock > 1 ? 's' : ''} au total',
                  style: const TextStyle(fontSize: 11,
                      color: AppColors.textHint)),
            ),
            const Divider(height: 8, color: AppColors.divider),
            for (final v in p.variants)
              RadioListTile<String?>(
                value: v.id,
                groupValue: _selectedId,
                onChanged: (val) => setState(() => _selectedId = val),
                dense: true,
                activeColor: AppColors.primary,
                title: Text(v.name,
                    style: const TextStyle(fontSize: 13,
                        fontWeight: FontWeight.w600)),
                subtitle: Text('${v.stockAvailable} unité'
                    '${v.stockAvailable > 1 ? 's' : ''} · '
                    '${CurrencyFormatter.format(v.priceSellPos)}',
                    style: const TextStyle(fontSize: 11,
                        color: AppColors.textHint)),
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

enum _CatalogueShareKind { all, category, selection }

class _CatalogueShareChoice {
  final _CatalogueShareKind kind;
  final String?             category;
  const _CatalogueShareChoice(this.kind, {this.category});
}

class _CatalogueShareDialog extends StatefulWidget {
  final List<String> categories;
  final bool         canUseSelection;
  final int          selectionCount;
  const _CatalogueShareDialog({
    required this.categories,
    required this.canUseSelection,
    required this.selectionCount,
  });

  @override
  State<_CatalogueShareDialog> createState() => _CatalogueShareDialogState();
}

class _CatalogueShareDialogState extends State<_CatalogueShareDialog> {
  late _CatalogueShareKind _kind;
  String? _category;

  @override
  void initState() {
    super.initState();
    _kind = widget.canUseSelection
        ? _CatalogueShareKind.selection
        : _CatalogueShareKind.all;
    if (widget.categories.isNotEmpty) _category = widget.categories.first;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14)),
      titlePadding:   const EdgeInsets.fromLTRB(20, 20, 20, 4),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      title: const Text('Que partager ?',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioListTile<_CatalogueShareKind>(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _CatalogueShareKind.all,
              groupValue: _kind,
              onChanged: (v) => setState(() => _kind = v!),
              title: const Text('Tout le catalogue'),
              subtitle: const Text('Tous les produits visibles publiquement',
                  style: TextStyle(fontSize: 11)),
            ),
            if (widget.categories.isNotEmpty) ...[
              RadioListTile<_CatalogueShareKind>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _CatalogueShareKind.category,
                groupValue: _kind,
                onChanged: (v) => setState(() => _kind = v!),
                title: const Text('Une catégorie'),
                subtitle: const Text('Filtre par catégorie de produit',
                    style: TextStyle(fontSize: 11)),
              ),
              if (_kind == _CatalogueShareKind.category)
                Padding(
                  padding: const EdgeInsets.fromLTRB(36, 4, 0, 8),
                  child: DropdownButtonFormField<String>(
                    initialValue: _category,
                    isDense: true,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    items: widget.categories
                        .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(c,
                                style: const TextStyle(fontSize: 13))))
                        .toList(),
                    onChanged: (v) => setState(() => _category = v),
                  ),
                ),
            ],
            if (widget.canUseSelection)
              RadioListTile<_CatalogueShareKind>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _CatalogueShareKind.selection,
                groupValue: _kind,
                onChanged: (v) => setState(() => _kind = v!),
                title: Text(
                    'Sélection actuelle (${widget.selectionCount} produit${widget.selectionCount > 1 ? 's' : ''})'),
                subtitle: const Text('Uniquement les produits cochés',
                    style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.of(context).pop(_CatalogueShareChoice(
              _kind,
              category: _kind == _CatalogueShareKind.category
                  ? _category
                  : null,
            ));
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('Continuer'),
        ),
      ],
    );
  }
}
