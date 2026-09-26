import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/link.dart';

// Pixel Facebook : stub no-op partout sauf web (import conditionnel).
import '../../../../core/services/fb_pixel.dart'
    if (dart.library.html) '../../../../core/services/fb_pixel_web.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/autocomplete_text_field.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../../../core/theme/app_text_styles.dart';

/// Catalogue public d'une boutique — accessible sans authentification via
/// `/catalogue/:shopId` avec query params optionnels :
///   - `cat=<categorie>` : filtre par catégorie initiale
///   - `ids=<id1,id2,...>` : restreint à certains produits
///
/// Chaque **variante** est affichée comme une card distincte avec sa
/// propre image / prix / stock. L'utilisateur peut :
///   - Commander un item directement → ouvre wa.me
///   - Activer le mode sélection multi → cocher plusieurs items → FAB
///     "Commander la sélection" envoie un message wa.me unique avec la
///     liste détaillée.
class CataloguePage extends StatefulWidget {
  final String        shopId;
  final String?       initialCategory;
  final List<String>? productIds;

  /// Snapshot de stock filtré au moment du partage. Clé = `productId`
  /// (produit sans variante) ou `productId|variantId` (variante). Quand
  /// fourni, on l'utilise au lieu du `stock_qty`/`stock_available` global
  /// retourné par Supabase — permet d'afficher au client le stock du
  /// périmètre actuellement visualisé par le marchand au moment du
  /// partage (Boutique seule, Partenaire X, Globale). Snapshot figé,
  /// pas refresh temps réel. Null = comportement historique (cumul).
  final Map<String, int>? stockOverride;

  /// Emplacement de stock choisi par le marchand AU MOMENT DU PARTAGE
  /// (param `loc` du lien). Propagé à `place_public_order` →
  /// `orders.delivery_location_id` pour que la commande client soit
  /// rattachée au bon emplacement (décrément stock côté marchand). Null =
  /// périmètre global / boutique → comportement historique inchangé.
  final String? locationId;

  /// Mode livraison (param `mode=delivery` du lien généré par
  /// `DeliveryMessageBuilder`). Quand activé, la page se simplifie pour
  /// un livreur qui n'a besoin que de voir l'image et la quantité à
  /// livrer par item :
  ///   - cards minimalistes (image + badge quantité, sans nom/prix/stock)
  ///   - pas de toolbar de sélection / commande
  ///   - pas de hint « cliquez pour sélectionner »
  ///   - pas de bandeau « Commander la sélection »
  /// `stockOverride[key]` est alors interprété comme la quantité à
  /// livrer (et plus comme un snapshot de stock disponible).
  final bool deliveryMode;

  /// Deep-link pub Facebook (`?product=<id>`). Quand fourni, le catalogue
  /// complet se charge ET la fiche détail du produit correspondant s'ouvre
  /// automatiquement au premier rendu. Le client ferme la fiche et continue
  /// à parcourir. Compatible avec recherche/filtres. Null = comportement
  /// historique (aucune fiche auto-ouverte).
  final String? highlightProductId;

  const CataloguePage({
    super.key,
    required this.shopId,
    this.initialCategory,
    this.productIds,
    this.stockOverride,
    this.locationId,
    this.deliveryMode = false,
    this.highlightProductId,
  });

  @override
  State<CataloguePage> createState() => _CataloguePageState();
}

class _CataloguePageState extends State<CataloguePage> {
  late Future<_CatalogueData> _future;
  String? _category;
  bool _selectMode = false;
  final Set<String> _selected = <String>{};
  // Recherche libre (nom produit) — filtre la grille en plus de la catégorie.
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  // Deep-link ?product : la fiche n'est auto-ouverte qu'UNE fois (au 1er
  // rendu avec données), pas à chaque rebuild (sinon réouverture en boucle).
  bool _highlightHandled = false;

  // Pixel Facebook : ID du pixel de la boutique (lu via get_public_shop_info).
  // Null/vide = boutique non connectée à Meta → aucun évènement n'est remonté.
  String? _pixelId;

  /// Le pixel n'est actif que sur le web, sur une page catalogue PUBLIQUE
  /// (pas le mode livreur interne), et si la boutique a connecté un ID.
  bool get _pixelOn =>
      kIsWeb && !widget.deliveryMode && (_pixelId?.isNotEmpty ?? false);

  /// XAF = devise FCFA du catalogue (valeur attendue par Meta).
  void _trackPixel(String event, [Map<String, Object?>? params]) {
    if (_pixelOn) trackFacebookEvent(event, params);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Normalise pour la recherche (minuscules + accents retirés).
  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll('à', 'a').replaceAll('â', 'a').replaceAll('ä', 'a')
      .replaceAll('é', 'e').replaceAll('è', 'e').replaceAll('ê', 'e')
      .replaceAll('ë', 'e')
      .replaceAll('î', 'i').replaceAll('ï', 'i')
      .replaceAll('ô', 'o').replaceAll('ö', 'o')
      .replaceAll('ù', 'u').replaceAll('û', 'u').replaceAll('ü', 'u')
      .replaceAll('ç', 'c');

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory;
    _future = _load();
  }

  /// Retourne le prix promo d'une variante si `promo_enabled` ET la date
  /// courante est dans la fenêtre [promo_start, promo_end[. Sinon retourne
  /// [fallback] (= prix normal). Bénéficie à tout le catalogue : un produit
  /// avec promo activée (manuellement ou via une campagne) affiche son
  /// prix réduit côté client.
  static double _effectivePrice(Map src, double fallback) {
    if (src['promo_enabled'] != true) return fallback;
    final promo = (src['promo_price'] as num?)?.toDouble();
    if (promo == null || promo <= 0) return fallback;
    final now = DateTime.now();
    final start = src['promo_start'] != null
        ? DateTime.tryParse(src['promo_start'].toString())
        : null;
    final end = src['promo_end'] != null
        ? DateTime.tryParse(src['promo_end'].toString())
        : null;
    if (start != null && now.isBefore(start)) return fallback;
    if (end != null && !now.isBefore(end)) return fallback;
    return promo;
  }

  Future<_CatalogueData> _load() async {
    final db = Supabase.instance.client;
    // Passe par un RPC SECURITY DEFINER (hotfix_095) plutôt qu'un SELECT
    // direct sur `shops` : la policy `shops_select_owner_or_member`
    // (TO authenticated) bloque les utilisateurs authentifiés non-membres
    // du shop, ce qui cassait le partage de lien sur mobile quand le
    // marchand l'ouvrait dans un browser où sa session Supabase était
    // persistée. Le RPC retourne les colonnes publiques d'un shop actif
    // quel que soit le rôle de l'appelant.
    final rpcResult = await db.rpc(
        'get_public_shop_info', params: {'p_shop_id': widget.shopId});
    final shopRow = rpcResult is Map
        ? Map<String, dynamic>.from(rpcResult)
        : null;
    if (shopRow == null) {
      throw Exception(
          'Boutique introuvable ou non publique.\n\n'
          'Vérifiez que la migration `hotfix_095_public_shop_info.sql` '
          'a été appliquée côté Supabase et que la boutique est active.');
    }
    // Pixel Facebook : injection du snippet (init + PageView) dès qu'on sait
    // que la boutique a connecté un pixel. No-op hors web / mode livreur (cf.
    // _pixelOn). Fait au plus tôt pour capter le PageView du visiteur.
    _pixelId = (shopRow['facebook_pixel_id'] as String?)?.trim();
    if (_pixelOn) initFacebookPixel(_pixelId!);
    final ids = widget.productIds;
    final hasExplicitIds = ids != null && ids.isNotEmpty;
    // Quand le partage WhatsApp inclut une liste d'`ids` précise, l'owner
    // a explicitement consenti à exposer ces produits — on bypass alors
    // le filtre `is_visible_web`. Hotfix_094 : la requête passe par un
    // RPC SECURITY DEFINER (`get_delivery_products`) qui contourne RLS
    // pour le cas ids-explicites. Avant ce hotfix on dépendait de
    // `is_visible_web=true` côté DB, qui exigeait une étape de
    // publication implicite (race conditions, ancien lien en cache,
    // ...). Avec le RPC, le lien fonctionne dès qu'il est généré.
    List<Map<String, dynamic>> products;
    if (hasExplicitIds) {
      final rows = await db.rpc('get_delivery_products', params: {
        'p_shop_id':     widget.shopId,
        'p_product_ids': ids,
      });
      products = (rows as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } else {
      // Vitrine publique générique (pas d'ids) — partage catalogue
      // complet ou par catégorie depuis l'inventaire. Passe par le RPC
      // SECURITY DEFINER `get_public_catalogue_products` (hotfix_097)
      // plutôt qu'un SELECT direct. Raison : la policy `products_select`
      // (TO authenticated) exige `_is_shop_member`, ce qui cassait le
      // partage de lien sur mobile quand le marchand avait une session
      // Supabase persistée sur un compte non-membre du shop testé.
      // Le RPC retourne uniquement les produits actifs + visibles web
      // d'un shop actif quel que soit le rôle de l'appelant.
      final rpcResult = await db.rpc('get_public_catalogue_products',
          params: {
            'p_shop_id':  widget.shopId,
            'p_category': widget.initialCategory,
          });
      products = (rpcResult as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // Deep-link pub `?product=<id>` SANS `ids` : garantir que le produit
      // ciblé est présent MÊME s'il n'est pas publié web (sinon la fiche ne
      // peut pas s'ouvrir, et si rien n'est publié, la page est vide). On le
      // récupère via le RPC delivery (le lien pub = consentement explicite
      // d'exposer ce produit) et on le fusionne en tête, dédupliqué par id.
      final hl = widget.highlightProductId;
      if (hl != null && hl.isNotEmpty &&
          !products.any((p) => p['id'] == hl)) {
        try {
          final extra = await db.rpc('get_delivery_products', params: {
            'p_shop_id':     widget.shopId,
            'p_product_ids': [hl],
          });
          final extraList = (extra as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          products = [...extraList, ...products];
        } catch (e) {
          debugPrint('[Catalogue] highlight product fetch error: $e');
        }
      }
    }

    // Flatten produit + variantes en items (1 card par variante). Try/catch
    // par produit pour ne pas tout crasher si un seul produit a un format
    // de variantes inattendu — le reste s'affiche quand même.
    final items = <_CatalogueItem>[];
    for (final p in products) {
      try {
        final base = (p['name'] as String?) ?? '';
        final variantsRaw = p['variants'];
        final variants = variantsRaw is List ? variantsRaw : const [];
        // On filtre les "fausses" variantes (sans nom ou vides) pour décider
        // si afficher 1 card produit ou N cards variantes.
        final realVariants = variants.where((v) {
          if (v is! Map) return false;
          final n = (v['name'] as String?)?.trim();
          return n != null && n.isNotEmpty;
        }).toList();

        final override = widget.stockOverride;
        if (realVariants.length <= 1) {
          final pid = p['id'] as String;
          // Si snapshot fourni → priorité au stock du périmètre choisi
          // par le marchand au moment du partage. Sinon → stock_qty
          // global Supabase (cumul historique toutes locations).
          final snapStock = override?[pid];
          final basePrice =
              (p['price_sell_pos'] as num?)?.toDouble() ?? 0;
          // Le prix promo est porté par la 1ʳᵉ variante (le sync campagne
          // applique promo_* sur les variantes). On la lit même si elle
          // est "fausse" (nom vide) pour les produits sans vraie variante.
          final firstV = variants.isNotEmpty && variants.first is Map
              ? Map<String, dynamic>.from(variants.first as Map)
              : null;
          final price = firstV != null
              ? _effectivePrice(firstV, basePrice)
              : basePrice;
          items.add(_CatalogueItem(
            productId:       pid,
            variantId:       null,
            name:            base,
            baseProductName: base,
            variantName:     null,
            sku:             p['sku'] as String?,
            price:           price,
            stock:           snapStock
                ?? (p['stock_qty'] as num?)?.toInt() ?? 0,
            imageUrl:        p['image_url'] as String?,
            categoryId:      p['category_id'] as String?,
            description:     p['description'] as String?,
            createdAt:       DateTime.tryParse(
                (p['created_at'] ?? '').toString()),
          ));
        } else {
          final pid = p['id'] as String;
          // Clé snapshot = `productId|<idx>` où idx = position dans
          // `realVariants` (= post-filtre name non vide). Aligné avec
          // `_buildStockSnapshot` côté inventaire/dashboard pour que
          // le matching survive aux divergences d'ID variants entre
          // Hive local et JSONB Supabase.
          //
          // Filtre variantes affichées (cf. bug 2026-05-28) : quand
          // `override` est fourni ET qu'aucune clé pour cette variante
          // n'est présente, on n'affiche PAS la variante. Permet au
          // partage commande (delivery) d'exposer SEULEMENT les variantes
          // réellement commandées, pas toutes les variantes du parent.
          // Le partage catalogue (inventaire) publie un snapshot pour
          // CHAQUE variante du shop, donc toutes restent affichées.
          // Fallback rétro-compat : si la clé `pid|<variantId>` est dans
          // override (ancien format), on accepte aussi.
          final hasOverride = override != null;
          for (int idx = 0; idx < realVariants.length; idx++) {
            final v = Map<String, dynamic>.from(realVariants[idx] as Map);
            final variantName = (v['name'] as String).trim();
            final vid = v['id']?.toString() ?? variantName;
            final snapByIdx = override?['$pid|$idx'];
            final snapByVid = override?['$pid|$vid'];
            if (hasOverride && snapByIdx == null && snapByVid == null) {
              continue; // variante non commandée → masquée
            }
            final snapStock = snapByIdx ?? snapByVid;
            items.add(_CatalogueItem(
              productId:       pid,
              variantId:       vid,
              name:            '$base — $variantName',
              baseProductName: base,
              variantName:     variantName,
              sku:             (v['sku'] as String?) ?? (p['sku'] as String?),
              price: _effectivePrice(
                  v,
                  (v['price_sell_pos'] as num?)?.toDouble()
                      ?? (p['price_sell_pos'] as num?)?.toDouble() ?? 0),
              stock: snapStock
                  ?? ((v['stock_available'] ?? v['stock_qty']) as num?)
                      ?.toInt()
                  ?? 0,
              imageUrl: (v['image_url'] as String?) ??
                  p['image_url'] as String?,
              isMain: v['is_main'] as bool? ?? false,
              categoryId: p['category_id'] as String?,
              description: p['description'] as String?,
              createdAt:   DateTime.tryParse(
                  (p['created_at'] ?? '').toString()),
            ));
          }
        }
      } catch (e) {
        debugPrint('[Catalogue] erreur parsing produit ${p['id']}: $e');
      }
    }

    // Règle métier : ne JAMAIS exposer un produit/variante en rupture dans
    // le catalogue public (envoi WhatsApp catalogue OU lien promotion qui
    // redirige ici). Le `stock` reflète déjà le périmètre choisi (snapshot
    // location si fourni, sinon stock global). Stock ≤ 0 → masqué.
    items.removeWhere((it) => it.stock <= 0);

    debugPrint('[Catalogue] shop=${widget.shopId} '
        'produits=${products.length} items=${items.length} '
        '(ids=${ids?.length ?? 'all'}, cat=${widget.initialCategory ?? 'all'})');

    final categories = items
        .map((i) => i.categoryId?.trim())
        .whereType<String>()
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    return _CatalogueData(
      shop: _ShopHeaderData(
        name:  shopRow['name'] as String? ?? '',
        // Numéro WhatsApp dédié prioritaire ; repli sur le téléphone
        // boutique s'il est vide/non renseigné.
        phone: () {
          final wa = (shopRow['whatsapp_phone'] as String?)?.trim();
          if (wa != null && wa.isNotEmpty) return wa;
          return shopRow['phone'] as String?;
        }(),
        logoUrl: (shopRow['logo_url'] as String?)?.trim(),
        city: (shopRow['city'] as String?)?.trim(),
      ),
      items:      items,
      categories: categories,
    );
  }

  /// Liste des items sélectionnés ET disponibles (stock > 0). Les items
  /// en rupture sont exclus à l'envoi pour éviter qu'un client commande
  /// un produit indisponible.
  List<_CatalogueItem> _selectedAvailable(_CatalogueData data) =>
      data.items
          .where((it) => _selected.contains(it.key) && it.stock > 0)
          .toList();

  /// URI `wa.me/<phone>?text=<msg>` pour commander la sélection courante.
  /// Exclut les items en rupture de stock.
  Uri _buildBatchOrderUri(_CatalogueData data) {
    final shopName = data.shop.name;
    final selectedItems = _selectedAvailable(data);
    final sym = CurrencyFormatter.currentSymbol;
    final buf = StringBuffer()
      ..write('Bonjour ')
      ..write(shopName.isEmpty ? '' : '$shopName, ')
      ..writeln('je souhaite commander :')
      ..writeln();
    var total = 0.0;
    for (final it in selectedItems) {
      buf.writeln('• ${it.name} — ${it.price.toStringAsFixed(0)} $sym');
      total += it.price;
    }
    buf
      ..writeln()
      ..writeln('Total estimé : ${total.toStringAsFixed(0)} $sym');
    return _waUri(data.shop.phone, buf.toString());
  }

  Uri _waUri(String? phone, String message) {
    final p = (phone ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    final encoded = Uri.encodeComponent(message);
    return Uri.parse(p.isEmpty
        ? 'https://wa.me/?text=$encoded'
        : 'https://wa.me/$p?text=$encoded');
  }

  /// Ouvre le sheet "Passer commande" pour finaliser un achat directement
  /// dans la page web (sans repasser par WhatsApp). À la confirmation,
  /// appelle la RPC `place_public_order` qui insert un row dans `orders`
  /// — le marchand connecté reçoit la notif in-app via Realtime.
  Future<void> _placeOrder(_CatalogueData data,
      List<_CatalogueItem> items, {Map<String, int>? quantities}) async {
    if (items.isEmpty) return;
    // Pixel : clic « Commander » (ouverture du formulaire) → AddToCart.
    final cartTotal = items.fold<double>(
        0, (s, it) => s + it.price * (quantities?[it.key] ?? 1));
    _trackPixel('AddToCart', {'value': cartTotal, 'currency': 'XAF'});
    final res = await showModalBottomSheet<_OrderResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _PlaceOrderSheet(
        shopId: widget.shopId,
        shopName: data.shop.name,
        items: items,
        quantities: quantities,
        locationId: widget.locationId,
      ),
    );
    if (res != null && mounted) {
      // Pixel : commande confirmée (créée côté Fortress) → Purchase.
      _trackPixel('Purchase', {'value': res.total, 'currency': 'XAF'});
      // Reset sélection après commande validée.
      setState(() {
        _selectMode = false;
        _selected.clear();
      });
      // Confirmation claire + bouton « Confirmer sur WhatsApp » (optionnel :
      // la commande est DÉJÀ créée dans Fortress, le WhatsApp n'est qu'un plus).
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (_) => _OrderConfirmedSheet(
          reference:   res.reference,
          total:       res.total,
          clientPhone: res.phone,
          waUri: _waUri(
              data.shop.phone, _confirmationMessage(data.shop.name, res)),
          hasWhatsapp: (data.shop.phone ?? '').trim().isNotEmpty,
        ),
      );
    }
  }

  /// Message wa.me pré-rempli pour la confirmation post-commande.
  String _confirmationMessage(String shopName, _OrderResult r) {
    final addr =
        [r.district, r.city].where((s) => s.trim().isNotEmpty).join(', ');
    final b = StringBuffer()
      ..write('Bonjour ')
      ..write(shopName.isEmpty ? '' : '$shopName, ')
      ..writeln('j\'ai passé une commande sur votre catalogue.')
      ..writeln('Nom : ${r.name}')
      ..writeln('Tél : ${r.phone}');
    if (addr.isNotEmpty) b.writeln('Adresse : $addr');
    return b.toString();
  }

  /// Toggle la sélection d'un item. Si le mode sélection n'est pas encore
  /// activé, l'active automatiquement (UX naturelle : taper sur une card
  /// suffit pour entrer dans le mode sélection avec cette card cochée).
  void _toggleSelect(String key) {
    setState(() {
      if (!_selectMode) _selectMode = true;
      if (_selected.contains(key)) {
        _selected.remove(key);
      } else {
        _selected.add(key);
      }
    });
  }

  /// Ouvre la fiche produit détaillée : grande image zoomable, galerie des
  /// variantes (chaque variante porte sa propre image) et bouton
  /// « Commander ». Déclenchée au tap sur une card hors mode sélection
  /// multiple. Valorise les visuels pour déclencher l'achat côté client.
  void _openProductSheet(_CatalogueData data, _CatalogueItem item) {
    // Pixel : vue d'une fiche produit → ViewContent.
    _trackPixel('ViewContent', {
      'content_ids':  [item.productId],
      'content_name': item.name,
      'value':        item.price,
      'currency':     'XAF',
    });
    // Galerie = les variantes du même produit (1 item = 1 variante).
    // Une seule → la rangée de miniatures est masquée dans la fiche.
    final siblings = data.items
        .where((it) => it.productId == item.productId)
        .toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ProductDetailSheet(
        item:     item,
        siblings: siblings,
        onOrder:  (chosen, qty) {
          Navigator.of(context).pop();
          _placeOrder(data, [chosen], quantities: {chosen.key: qty});
        },
      ),
    );
  }

  /// Deep-link pub Facebook (`?product=<id>`) : ouvre automatiquement la
  /// fiche du produit ciblé au 1er rendu avec données. Le catalogue complet
  /// reste derrière → le client ferme la fiche et continue à parcourir. No-op
  /// si déjà traité, en mode livreur, ou si le produit est absent/épuisé.
  void _maybeOpenHighlighted(_CatalogueData data) {
    if (_highlightHandled) return;
    final pid = widget.highlightProductId;
    if (pid == null || widget.deliveryMode) return;
    _highlightHandled = true;
    // Ouvre sur la variante MISE EN AVANT du produit (comme la boutique),
    // pas la première rencontrée dans la liste.
    final matches =
        data.items.where((it) => it.productId == pid).toList();
    if (matches.isEmpty) return; // produit non visible/rupture → catalogue normal
    final t = _featuredAmong(matches);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openProductSheet(data, t);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: FutureBuilder<_CatalogueData>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${snap.error}',
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, color: theme.colorScheme.error)),
              ),
            );
          }
          final data = snap.data!;
          // Deep-link ?product : ouvre la fiche du produit ciblé (une fois).
          _maybeOpenHighlighted(data);
          // Filtre combiné : catégorie active + recherche libre (nom).
          final q = _norm(_query.trim());
          final filtered = data.items.where((it) {
            if (_category != null && it.categoryId != _category) return false;
            if (q.isNotEmpty && !_norm(it.name).contains(q)) return false;
            return true;
          }).toList();
          return SafeArea(
            bottom: false,
            child: Column(
              children: [
                // ── Bannière sticky (toujours visible en haut) ──
                _StickyBanner(
                  shopName: data.shop.name,
                  logoUrl:  data.shop.logoUrl,
                  city:     data.shop.city,
                ),
                // ── Recherche + chips catégories (masqués en mode livreur) ──
                if (!widget.deliveryMode) ...[
                  _SearchRow(
                    controller:     _searchCtrl,
                    onChanged:      (v) => setState(() => _query = v),
                    selectMode:     _selectMode,
                    selectedCount:  _selected.length,
                    onToggleSelect: () => setState(() {
                      _selectMode = !_selectMode;
                      if (!_selectMode) _selected.clear();
                    }),
                  ),
                  if (data.categories.isNotEmpty)
                    _CategoryChips(
                      categories: data.categories,
                      active:     _category,
                      onSelect:   (c) => setState(() => _category = c),
                    ),
                ],
                // ── Grille produits (scrollable) ──
                Expanded(
                  child: LayoutBuilder(builder: (_, c) {
                    final isWide = c.maxWidth >= 700;
                    final cols   = isWide ? 3 : 2;
                    // Card = image carrée (Expanded) + nom/variante/prix +
                    // bouton « Commander ». L'image absorbe la hauteur restante
                    // (Expanded) → pas d'overflow quel que soit le ratio.
                    const aspect = 0.62;
                    if (filtered.isEmpty) {
                      return _Empty(
                        isFiltered:   data.items.isNotEmpty,
                        hasIdsFilter: widget.productIds != null,
                      );
                    }
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount:  cols,
                        mainAxisSpacing:  16,
                        crossAxisSpacing: 16,
                        childAspectRatio: aspect,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final item = filtered[i];
                        if (widget.deliveryMode) {
                          // Card minimaliste livreur : image + badge quantité.
                          return _DeliveryCard(
                            imageUrl: item.imageUrl,
                            quantity: item.stock,
                            sku:      item.sku,
                          );
                        }
                        final selected = _selected.contains(item.key);
                        return _CatalogueCard(
                          item:       item,
                          selectMode: _selectMode,
                          selected:   selected,
                          // Hors sélection : tap = fiche produit. En sélection :
                          // tap = coche la card.
                          onTap: () => _selectMode
                              ? _toggleSelect(item.key)
                              : _openProductSheet(data, item),
                          // Bouton « Commander » → commande directe ce produit.
                          onOrder: () => _placeOrder(data, [item]),
                        );
                      },
                    );
                  }),
                ),
                // ── Bandeau "Commander la sélection" fixé en bas ──
                if (!widget.deliveryMode &&
                    _selectMode && _selected.isNotEmpty)
                  _BatchOrderBar(
                    count:           _selected.length,
                    availableCount:  _selectedAvailable(data).length,
                    waOrderUri:      _buildBatchOrderUri(data),
                    onPlaceOrder:    () => _placeOrder(
                      data,
                      _selectedAvailable(data),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─── Modèles ───────────────────────────────────────────────────────────────

class _CatalogueItem {
  final String  productId;
  final String? variantId;
  final String  name;
  final String  baseProductName;
  final String? variantName;
  final String? sku;
  final double  price;
  final int     stock;
  final String? imageUrl;
  /// Variante explicitement « mise en avant » par le marchand (`is_main`).
  /// Sert de tie-breaker pour désigner la variante hero — identique à la
  /// logique POS (`Product.featuredVariant`) — dans la fiche détail.
  final bool    isMain;
  final String? categoryId;
  /// Description produit (si exposée par le RPC public). Affichée dans la
  /// fiche détail. Null = pas de description / RPC ne la renvoie pas.
  final String? description;
  /// Date de création du produit (si exposée par le RPC). Pilote le badge
  /// « Nouveau » (récent). Null = RPC ne la renvoie pas → pas de badge.
  final DateTime? createdAt;

  const _CatalogueItem({
    required this.productId,
    required this.variantId,
    required this.name,
    required this.baseProductName,
    required this.variantName,
    required this.sku,
    required this.price,
    required this.stock,
    required this.imageUrl,
    required this.categoryId,
    this.isMain = false,
    this.description,
    this.createdAt,
  });

  /// True si le produit a été créé récemment (≤ 14 jours) → badge « Nouveau ».
  bool get isRecent {
    final c = createdAt;
    if (c == null) return false;
    return DateTime.now().difference(c).inDays <= 14;
  }

  String get key => variantId == null ? productId : '$productId|$variantId';
}

/// Variante « mise en avant » parmi [items] (variantes d'un même produit).
/// Réplique la logique POS (`Product.featuredVariant`) pour que la vitrine
/// web mette en avant exactement la même variante hero que la boutique :
/// plus grand stock disponible, égalité tranchée par la variante marquée
/// `isMain`, sinon la 1ʳᵉ stable (tri par id/nom). [items] est supposé non
/// vide (toutes les variantes en rupture sont déjà masquées du catalogue).
_CatalogueItem _featuredAmong(List<_CatalogueItem> items) {
  final maxStock = items.fold<int>(0, (m, v) => v.stock > m ? v.stock : m);
  final tied = items.where((v) => v.stock == maxStock).toList()
    ..sort((a, b) => (a.variantId ?? a.variantName ?? a.productId)
        .compareTo(b.variantId ?? b.variantName ?? b.productId));
  return tied.firstWhere((v) => v.isMain, orElse: () => tied.first);
}

class _ShopHeaderData {
  final String name;
  final String? phone;
  /// Logo de la boutique (Supabase Storage) — renvoyé par le hotfix SQL
  /// `get_public_shop_info`. Null tant que le hotfix n'est pas appliqué →
  /// repli sur le logo Fortress.
  final String? logoUrl;
  /// Ville de la boutique (si exposée par `get_public_shop_info`). Affichée
  /// dans la bannière (« <ville> · Livraison disponible »). Null = on n'affiche
  /// que « Livraison disponible » — zéro ville en dur.
  final String? city;
  const _ShopHeaderData({
    required this.name, this.phone, this.logoUrl, this.city});
}

/// Quartier de livraison configuré, lu via la RPC publique
/// `get_public_delivery_quartiers` (PR-3 frais de livraison par quartier).
class _WebQuartier {
  final String  city;
  final String  name;
  final int     price;
  final String? zone;
  const _WebQuartier({
    required this.city,
    required this.name,
    required this.price,
    this.zone,
  });
}

/// Coordonnées client saisies à la commande — renvoyées par
/// [_PlaceOrderSheet] pour construire la confirmation WhatsApp post-commande.
class _OrderResult {
  final String name;
  final String phone;
  final String city;
  final String district;
  /// Id de la commande créée (RPC `place_public_order`) — sert la référence
  /// #ORD-XXXX de la page de confirmation. Null si l'id n'a pu être lu.
  final String? orderId;
  /// Total à payer (somme prix × quantité) — affiché « montant à préparer ».
  final double total;
  const _OrderResult({
    required this.name, required this.phone,
    required this.city, required this.district,
    this.orderId, this.total = 0,
  });

  /// Référence courte « ORD-XXXXXX » dérivée de l'id (6 derniers caractères
  /// alphanumériques, majuscules). Fallback générique si id absent.
  String get reference {
    final raw = (orderId ?? '').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    if (raw.isEmpty) return 'ORD';
    final tail = raw.length <= 6 ? raw : raw.substring(raw.length - 6);
    return 'ORD-${tail.toUpperCase()}';
  }
}

class _CatalogueData {
  final _ShopHeaderData       shop;
  final List<_CatalogueItem>  items;
  final List<String>          categories;
  const _CatalogueData({
    required this.shop,
    required this.items,
    required this.categories,
  });
}

// ─── Bannière sticky ────────────────────────────────────────────────────────
//
// Barre compacte toujours visible en haut du catalogue : logo boutique, nom +
// ville, et un badge « Paiement à la réception » rassurant pour un visiteur
// Facebook. Fond surface (pas un gros header dégradé) → laisse la place à la
// grille produits, mobile-first.

class _StickyBanner extends StatelessWidget {
  final String shopName;
  final String? logoUrl;
  final String? city;
  const _StickyBanner({required this.shopName, this.logoUrl, this.city});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final name = shopName.isEmpty ? l.hubBrand : shopName;
    final subtitle = (city != null && city!.isNotEmpty)
        ? '$city · Livraison disponible'
        : 'Livraison disponible';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(children: [
        _BannerLogo(logoUrl: logoUrl, name: name),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption.copyWith(
                      color: AppColors.onSurface,
                      fontWeight: FontWeight.w600)),
              Text(subtitle,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.micro),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Badge rassurant « Paiement à la réception ».
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.secondary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.payments_outlined,
                size: 11, color: AppColors.secondary),
            const SizedBox(width: 4),
            Text('Paiement à la réception',
                style: AppTextStyles.micro.copyWith(
                    color: AppColors.secondary,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }
}

/// Logo boutique 28×28 (radius 6). Image si `logoUrl`, sinon initiale du nom
/// sur fond primary (zéro asset requis).
class _BannerLogo extends StatelessWidget {
  final String? logoUrl;
  final String name;
  const _BannerLogo({this.logoUrl, required this.name});

  static const double _size = 28;

  Widget _initial() => Container(
        width: _size, height: _size,
        decoration: BoxDecoration(
          color: AppColors.primaryFill,
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: Text(
            name.trim().isNotEmpty
                ? name.trim().characters.first.toUpperCase()
                : '?',
            style: AppTextStyles.caption.copyWith(
                color: Colors.white, fontWeight: FontWeight.w800)),
      );

  @override
  Widget build(BuildContext context) {
    if (logoUrl != null && logoUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(logoUrl!,
            width: _size, height: _size, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _initial()),
      );
    }
    return _initial();
  }
}

// ─── Recherche + toggle sélection ───────────────────────────────────────────

class _SearchRow extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool selectMode;
  final int selectedCount;
  final VoidCallback onToggleSelect;
  const _SearchRow({
    required this.controller,
    required this.onChanged,
    required this.selectMode,
    required this.selectedCount,
    required this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(children: [
        Expanded(
          child: SizedBox(
            height: 44,
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: AppTextStyles.bodySm,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Rechercher un produit...',
                hintStyle: AppTextStyles.bodySm
                    .copyWith(color: AppColors.textHint),
                prefixIcon: Icon(Icons.search_rounded,
                    size: 18, color: AppColors.textHint),
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(Icons.close_rounded,
                            size: 16, color: AppColors.textHint),
                        splashRadius: 18,
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
                filled: true,
                fillColor: AppColors.inputFill,
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.primary)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Toggle sélection multiple (pour commander plusieurs produits).
        Tooltip(
          message: selectMode
              ? 'Quitter la sélection'
              : 'Sélectionner plusieurs produits',
          child: InkWell(
            onTap: onToggleSelect,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: selectMode
                    ? AppColors.primarySurface
                    : AppColors.inputFill,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: selectMode
                        ? AppColors.primary.withValues(alpha: 0.4)
                        : AppColors.divider),
              ),
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  Icon(
                      selectMode
                          ? Icons.close_rounded
                          : Icons.checklist_rounded,
                      size: 20,
                      color: selectMode
                          ? AppColors.primary
                          : AppColors.textSecondary),
                  if (selectMode && selectedCount > 0)
                    Positioned(
                      top: 1, right: 1,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.primaryFill,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('$selectedCount',
                            style: AppTextStyles.micro.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─── Chips catégories (scroll horizontal) ───────────────────────────────────

class _CategoryChips extends StatelessWidget {
  final List<String> categories;
  final String? active;
  final ValueChanged<String?> onSelect;
  const _CategoryChips({
    required this.categories,
    required this.active,
    required this.onSelect,
  });

  Widget _chip(BuildContext context,
      {required String label, required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryFill : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected ? AppColors.primaryFill : AppColors.divider),
        ),
        child: Text(label,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: AppTextStyles.caption.copyWith(
                color: selected ? Colors.white : AppColors.textSecondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        children: [
          _chip(context,
              label: l.catalogueCategoryAll,
              selected: active == null,
              onTap: () => onSelect(null)),
          for (final c in categories) ...[
            const SizedBox(width: 8),
            _chip(context,
                label: c,
                selected: active == c,
                onTap: () => onSelect(c)),
          ],
        ],
      ),
    );
  }
}

// ─── Sheet "Passer commande" (formulaire client) ──────────────────────────

class _PlaceOrderSheet extends StatefulWidget {
  final String shopId;
  final String shopName;
  final List<_CatalogueItem> items;
  /// Quantité par item (clé = `item.key`). Absent → 1 (commande historique).
  final Map<String, int>? quantities;
  final String? locationId;
  const _PlaceOrderSheet({
    required this.shopId,
    required this.shopName,
    required this.items,
    this.quantities,
    this.locationId,
  });

  int _qtyOf(_CatalogueItem it) {
    final q = quantities?[it.key] ?? 1;
    return q < 1 ? 1 : q;
  }

  @override
  State<_PlaceOrderSheet> createState() => _PlaceOrderSheetState();
}

class _PlaceOrderSheetState extends State<_PlaceOrderSheet> {
  final _formKey      = GlobalKey<FormState>();
  final _nameCtrl     = TextEditingController();
  final _phoneCtrl    = TextEditingController();
  final _cityCtrl     = TextEditingController();
  final _districtCtrl = TextEditingController();
  final _noteCtrl     = TextEditingController();
  String  _phoneFull  = '';
  bool    _phoneValid = false;
  // Date de livraison souhaitée (OBLIGATOIRE). Sélectionnée via les
  // pickers Material natifs — pattern identique à `delivery_details_sheet`.
  DateTime? _deliveryDate;
  bool _dateMissing = false; // bordure rouge si on a tenté d'envoyer sans date
  bool _submitting = false;
  String? _error;

  // ── Frais de livraison par quartier (PR-3) ────────────────────────────────
  List<_WebQuartier> _quartiers = const [];
  int?    _deliveryPrice;   // null = à confirmer (ou ville vide)
  String? _deliveryZone;
  bool    _quartierKnown = false; // quartier saisi reconnu dans la liste

  @override
  void initState() {
    super.initState();
    _cityCtrl.addListener(_recomputeDelivery);
    _districtCtrl.addListener(_recomputeDelivery);
    _loadQuartiers();
  }

  Future<void> _loadQuartiers() async {
    try {
      final rows = await Supabase.instance.client.rpc(
          'get_public_delivery_quartiers',
          params: {'p_shop_id': widget.shopId});
      if (!mounted || rows is! List) return;
      setState(() {
        _quartiers = rows.map((r) {
          final m = Map<String, dynamic>.from(r as Map);
          return _WebQuartier(
            city:  (m['city'] ?? '') as String,
            name:  (m['name'] ?? '') as String,
            price: (m['price'] as num?)?.toInt() ?? 0,
            zone:  m['zone_id'] as String?,
          );
        }).toList();
      });
      _recomputeDelivery();
    } catch (e) {
      debugPrint('[Catalogue] get_public_delivery_quartiers error: $e');
    }
  }

  static String _norm(String s) => s.trim().toLowerCase();

  /// Villes configurées (depuis les quartiers) — pour l'autocomplete ville.
  List<String> get _configuredCities {
    final set = <String>{};
    for (final q in _quartiers) {
      if (q.city.trim().isNotEmpty) set.add(q.city.trim());
    }
    return set.toList()..sort();
  }

  /// Quartiers configurés pour la ville actuellement saisie.
  List<_WebQuartier> get _cityQuartiers {
    final c = _norm(_cityCtrl.text);
    if (c.isEmpty) return const [];
    return _quartiers.where((q) => _norm(q.city) == c).toList();
  }

  /// Recalcule le prix de livraison selon la ville + le quartier saisis.
  void _recomputeDelivery() {
    final c = _norm(_cityCtrl.text);
    final d = _norm(_districtCtrl.text);
    _WebQuartier? match;
    if (c.isNotEmpty && d.isNotEmpty) {
      for (final q in _quartiers) {
        if (_norm(q.city) == c && _norm(q.name) == d) { match = q; break; }
      }
    }
    final newKnown = match != null;
    final newPrice = match?.price;
    final newZone  = match?.zone;
    if (newKnown != _quartierKnown ||
        newPrice != _deliveryPrice ||
        newZone != _deliveryZone) {
      setState(() {
        _quartierKnown = newKnown;
        _deliveryPrice = newPrice;
        _deliveryZone  = newZone;
      });
    }
  }

  /// Total facturé = produits + livraison (si connue).
  double get _grandTotal => _total + (_deliveryPrice ?? 0).toDouble();

  Future<void> _pickDeliveryDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _deliveryDate ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      locale: const Locale('fr', 'FR'),
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_deliveryDate
          ?? DateTime(picked.year, picked.month, picked.day, 14)),
    );
    if (!mounted) return;
    setState(() {
      _deliveryDate = DateTime(
          picked.year, picked.month, picked.day,
          time?.hour ?? 14, time?.minute ?? 0);
      _dateMissing = false;
    });
  }

  String _formatDeliveryDate(DateTime d) {
    const days = ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'];
    const months = ['jan', 'fév', 'mar', 'avr', 'mai', 'juin',
                    'juil', 'août', 'sep', 'oct', 'nov', 'déc'];
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]} · $h:$m';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _cityCtrl.dispose();
    _districtCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  double get _total => widget.items
      .fold<double>(0, (s, it) => s + it.price * widget._qtyOf(it));

  // Validateurs réutilisés du formulaire client de l'app (clients_page.dart).
  String? _validateName(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Le nom est requis';
    if (s.length < 2) return 'Minimum 2 caractères';
    if (s.length > 80) return 'Maximum 80 caractères';
    if (!RegExp(r"^[a-zA-ZÀ-ÿ\s\-\']+$").hasMatch(s)) {
      return 'Lettres et espaces uniquement';
    }
    return null;
  }

  String? _validateCity(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'La ville est requise';
    if (s.length < 2) return 'Minimum 2 caractères';
    return null;
  }

  String? _validateDistrict(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Le quartier est requis';
    if (s.length < 2) return 'Minimum 2 caractères';
    return null;
  }

  Future<void> _submit() async {
    final formOk = _formKey.currentState?.validate() ?? false;
    if (!formOk) {
      setState(() => _error = 'Vérifiez les champs en rouge.');
      return;
    }
    if (!_phoneValid) {
      setState(() => _error = 'Numéro de téléphone invalide.');
      return;
    }
    if (_deliveryDate == null) {
      setState(() {
        _error = 'La date de livraison souhaitée est requise.';
        _dateMissing = true;
      });
      return;
    }
    setState(() { _submitting = true; _error = null; });
    try {
      final db = Supabase.instance.client;
      final itemsJson = widget.items.map((it) => {
        'product_id':  it.productId,
        'variant_id':  it.variantId,
        'name':        it.name,
        'sku':         it.sku,
        'quantity':    widget._qtyOf(it),
        'unit_price':  it.price,
        // Image figée pour que la page tracking (et le marchand côté
        // dashboard) puissent afficher l'image du produit dans le
        // récap commande — sinon `m['image_url']` est null et tombe sur
        // le placeholder gris.
        'image_url':   it.imageUrl,
      }).toList();
      final city     = _cityCtrl.text.trim();
      final district = _districtCtrl.text.trim();
      final note     = _noteCtrl.text.trim();
      // Signature hotfix_048 : on passe city/district séparés + date de
      // livraison optionnelle. La RPC fait l'upsert client et stocke
      // `scheduled_at` pour que la commande apparaisse dans la liste
      // marchand comme une commande normale (avec bouton "modifier").
      final orderId = await db.rpc('place_public_order', params: {
        'p_shop_id':         widget.shopId,
        'p_items':           itemsJson,
        'p_location_id':     widget.locationId,
        'p_client_name':     _nameCtrl.text.trim(),
        'p_client_phone':    _phoneFull.isNotEmpty ? _phoneFull : _phoneCtrl.text.trim(),
        'p_client_city':     city.isEmpty ? null : city,
        'p_client_district': district.isEmpty ? null : district,
        'p_notes':           note.isEmpty ? null : note,
        'p_scheduled_at':    _deliveryDate?.toUtc().toIso8601String(),
        // Livraison par quartier (PR-3). `p_delivery_price` null = quartier
        // non répertorié → « frais à fixer » côté marchand (dashboard).
        'p_delivery_price':    _deliveryPrice,
        'p_delivery_quartier': district.isEmpty ? null : district,
        'p_delivery_zone':     _deliveryZone,
      });
      debugPrint('[Catalogue] commande créée : $orderId');
      if (!mounted) return;
      Navigator.of(context).pop(_OrderResult(
        name:     _nameCtrl.text.trim(),
        phone:    _phoneFull.isNotEmpty ? _phoneFull : _phoneCtrl.text.trim(),
        city:     city,
        district: district,
        orderId:  orderId?.toString(),
        total:    _grandTotal,
      ));
    } catch (e) {
      debugPrint('[Catalogue] place_public_order error: $e');
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Erreur lors de l\'envoi : ${e.toString()}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets),
        child: DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize:     0.5,
          maxChildSize:     0.95,
          expand: false,
          builder: (_, sc) => Column(children: [
            // Drag handle + header
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.shopping_bag_outlined,
                      size: 18, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Passer commande',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: theme.colorScheme.onSurface)),
                      Text(widget.shopName.isEmpty
                              ? 'Boutique en ligne'
                              : 'Vers ${widget.shopName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.6))),
                    ],
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: Container(
                    width: 36, height: 36,
                    alignment: Alignment.center,
                    child: Icon(Icons.close_rounded,
                        size: 22,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.7)),
                  ),
                ),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: sc,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  // ── Récap commande : photo + nom + variante + qté + prix ──
                  Text(
                      'Votre commande (${widget.items.length} '
                      'produit${widget.items.length > 1 ? 's' : ''})',
                      style: AppTextStyles.micro.copyWith(
                          fontWeight: FontWeight.w700, letterSpacing: 0.6)),
                  const SizedBox(height: 8),
                  for (final it in widget.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 44, height: 44,
                            child: _CardImage(url: it.imageUrl),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(it.baseProductName,
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.bodySm.copyWith(
                                      color: AppColors.onSurface,
                                      fontWeight: FontWeight.w600)),
                              if (it.variantName != null &&
                                  it.variantName!.isNotEmpty)
                                Text(it.variantName!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.micro),
                              Text(
                                  '${widget._qtyOf(it)} × '
                                  '${CurrencyFormatter.format(it.price)}',
                                  style: AppTextStyles.micro
                                      .copyWith(color: AppColors.textHint)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                            CurrencyFormatter.format(
                                it.price * widget._qtyOf(it)),
                            style: AppTextStyles.bodySmBold
                                .copyWith(color: AppColors.primary)),
                      ]),
                    ),
                  const SizedBox(height: 12),
                  // ── Récap : Produits + Livraison + Total ──
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.primarySurface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(children: [
                      Row(children: [
                        Text('Produits',
                            style: AppTextStyles.bodySm
                                .copyWith(color: AppColors.textSecondary)),
                        const Spacer(),
                        Text(CurrencyFormatter.format(_total),
                            style: AppTextStyles.bodySm),
                      ]),
                      if (_cityCtrl.text.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Row(children: [
                          Text('Livraison',
                              style: AppTextStyles.bodySm
                                  .copyWith(color: AppColors.textSecondary)),
                          const Spacer(),
                          Text(
                              _quartierKnown
                                  ? '+ ${CurrencyFormatter.format(
                                      _deliveryPrice!.toDouble())}'
                                  : 'À confirmer',
                              style: AppTextStyles.bodySm.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: _quartierKnown
                                      ? AppColors.onSurface
                                      : AppColors.warning)),
                        ]),
                      ],
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Divider(
                            height: 1, color: theme.semantic.borderSubtle),
                      ),
                      Row(children: [
                        Text('Total à payer',
                            style: AppTextStyles.label
                                .copyWith(color: AppColors.onSurface)),
                        const Spacer(),
                        Text(CurrencyFormatter.format(_grandTotal),
                            style: AppTextStyles.subtitleBold
                                .copyWith(color: AppColors.primary)),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 18),
                  // Form
                  Text('Vos coordonnées',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6))),
                  const SizedBox(height: 8),
                  Form(
                    key: _formKey,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const AppFieldLabel('Nom complet', required: true),
                        AppField(
                          controller: _nameCtrl,
                          hint: 'Ex : Jean Mballa',
                          prefixIcon: Icons.person_outline_rounded,
                          validator: _validateName,
                        ),
                        const SizedBox(height: 10),
                        PhoneField(
                          controller: _phoneCtrl,
                          label: 'Téléphone',
                          required: true,
                          onChanged: (full, valid) {
                            _phoneFull = full;
                            _phoneValid = valid;
                          },
                        ),
                        const SizedBox(height: 10),
                        AutocompleteTextField(
                          controller: _cityCtrl,
                          label: 'Ville',
                          hint: 'Ex : Yaoundé',
                          prefixIcon: Icons.location_city_outlined,
                          required: true,
                          // Villes configurées par la boutique en priorité,
                          // puis repli sur les grandes villes du Cameroun.
                          suggestions: <String>{
                            ..._configuredCities,
                            'Douala', 'Yaoundé', 'Bafoussam', 'Bamenda',
                            'Garoua', 'Maroua', 'Ngaoundéré', 'Bertoua',
                            'Ebolowa', 'Kribi', 'Limbé', 'Buea',
                          }.toList(),
                          validator: _validateCity,
                          // Rafraîchit la visibilité + les suggestions du
                          // champ quartier dès que la ville change.
                          onChanged: (_) => setState(() {}),
                        ),
                        // Quartier : MASQUÉ tant que la ville n'est pas saisie.
                        if (_cityCtrl.text.trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          AutocompleteTextField(
                            controller: _districtCtrl,
                            label: 'Quartier',
                            hint: 'Ex : Bastos',
                            prefixIcon: Icons.maps_home_work_outlined,
                            required: true,
                            suggestions: _cityQuartiers
                                .map((q) => q.name).toList(),
                            validator: _validateDistrict,
                            onChanged: (_) => setState(() {}),
                          ),
                          // Cas « quartier non répertorié » → forfait à confirmer.
                          if (_districtCtrl.text.trim().isNotEmpty
                              && !_quartierKnown) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppColors.warning.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: AppColors.warning
                                        .withValues(alpha: 0.4)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.info_outline_rounded,
                                      size: 16, color: AppColors.warning),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('Prix forfaitaire à confirmer',
                                            style: AppTextStyles.captionBold
                                                .copyWith(
                                                    color: AppColors.warning)),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Votre quartier n\'est pas encore '
                                          'dans notre liste. Les frais de '
                                          'livraison seront fixés à l\'amiable '
                                          'entre vous et la boutique lors de la '
                                          'confirmation de votre commande.',
                                          style: AppTextStyles.caption.copyWith(
                                              color: AppColors.textSecondary),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                        const SizedBox(height: 14),
                        // Date de livraison souhaitée (OBLIGATOIRE).
                        const AppFieldLabel('Date de livraison souhaitée',
                            required: true),
                        const SizedBox(height: 6),
                        InkWell(
                          onTap: _pickDeliveryDate,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 12),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: _dateMissing
                                      ? theme.colorScheme.error
                                      : _deliveryDate != null
                                          ? theme.colorScheme.primary
                                              .withValues(alpha: 0.5)
                                          : theme.semantic.borderSubtle),
                            ),
                            child: Row(children: [
                              Icon(Icons.event_rounded,
                                  size: 16,
                                  color: _deliveryDate != null
                                      ? theme.colorScheme.primary
                                      : AppColors.textHint),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _deliveryDate != null
                                      ? _formatDeliveryDate(_deliveryDate!)
                                      : 'Choisir une date',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: _deliveryDate != null
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: _deliveryDate != null
                                          ? AppColors.onSurface
                                          : AppColors.textHint),
                                ),
                              ),
                              // Champ obligatoire : on remplace l'icône
                              // « effacer » par un chevron (on change la date
                              // en re-tapant la ligne, sans pouvoir la vider).
                              Icon(Icons.chevron_right_rounded,
                                  size: 18,
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.35)),
                            ]),
                          ),
                        ),
                        const SizedBox(height: 14),
                        const AppFieldLabel('Note pour le livreur (optionnel)'),
                        AppField(
                          controller: _noteCtrl,
                          hint: 'Ex : Appeler avant de livrer, '
                              'point de repère…',
                          prefixIcon: Icons.sticky_note_2_outlined,
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      Icon(Icons.error_outline,
                          size: 14, color: theme.colorScheme.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_error!,
                            style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.error)),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submitting ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryFill,
                      foregroundColor: theme.colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(
                            (_cityCtrl.text.trim().isNotEmpty
                                    && _districtCtrl.text.trim().isNotEmpty
                                    && !_quartierKnown)
                                ? 'Commander — frais à confirmer'
                                : 'Commander — '
                                    '${CurrencyFormatter.format(_grandTotal)}',
                            style: AppTextStyles.label
                                .copyWith(color: Colors.white)),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}


class _Empty extends StatelessWidget {
  final bool isFiltered;
  final bool hasIdsFilter;
  const _Empty({this.isFiltered = false, this.hasIdsFilter = false});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    String message;
    if (hasIdsFilter) {
      message = 'Les produits partagés ne sont plus disponibles publiquement.\n'
          'Contactez la boutique pour plus d\'informations.';
    } else if (isFiltered) {
      message = 'Aucun produit dans cette catégorie.\n'
          'Essayez de réinitialiser les filtres.';
    } else {
      message = l.catalogueEmpty;
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined,
                size: 48,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.7))),
          ],
        ),
      ),
    );
  }
}

// ─── Bandeau "Commander la sélection" (FAB-like) ───────────────────────────

class _BatchOrderBar extends StatelessWidget {
  final int          count;
  final int          availableCount;
  final Uri          waOrderUri;
  final VoidCallback onPlaceOrder;
  const _BatchOrderBar({
    required this.count,
    required this.availableCount,
    required this.waOrderUri,
    required this.onPlaceOrder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.15)),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Icon(Icons.shopping_cart_outlined,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    '$count produit${count > 1 ? 's' : ''} sélectionné${count > 1 ? 's' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface)),
              ),
            ]),
            // Avertissement : certains items sélectionnés sont en rupture
            // et seront automatiquement exclus de la commande.
            if (availableCount < count) ...[
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.warning_amber_rounded,
                    size: 13, color: theme.semantic.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      '${count - availableCount} en rupture exclu${count - availableCount > 1 ? 's' : ''} — '
                      '$availableCount sera${availableCount > 1 ? 'ont' : ''} envoyé${availableCount > 1 ? 's' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          color: theme.semantic.warning)),
                ),
              ]),
            ],
            const SizedBox(height: 10),
            // Bouton primaire : passer commande dans l'app (formulaire +
            // RPC vers Supabase + notif marchand). Plein largeur.
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: availableCount == 0 ? null : onPlaceOrder,
                icon: const Icon(Icons.shopping_bag_outlined, size: 18),
                label: Text(
                    availableCount == 0
                        ? 'Aucun produit disponible'
                        : 'Passer commande',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // Bouton secondaire : ouvrir WhatsApp directement avec la liste
            // (alternative pour discuter, pas de commande créée).
            SizedBox(
              width: double.infinity,
              child: Link(
                uri:    waOrderUri,
                target: LinkTarget.blank,
                builder: (ctx, followLink) => TextButton.icon(
                  onPressed: followLink,
                  icon: Icon(Icons.chat_outlined,
                      size: 16, color: theme.colorScheme.primary),
                  label: Text('Discuter via WhatsApp à la place',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Sheet de confirmation post-commande ───────────────────────────────────

/// Affiché après une commande publique réussie. Checkmark animé + référence
/// #ORD + montant à préparer en espèces + bouton optionnel « Confirmer sur
/// WhatsApp » (la commande est DÉJÀ créée dans Fortress, le WhatsApp n'est
/// qu'un canal de réassurance) + « Continuer mes achats ».
class _OrderConfirmedSheet extends StatelessWidget {
  final String reference;
  final double total;
  final String clientPhone;
  final Uri    waUri;
  final bool   hasWhatsapp;
  const _OrderConfirmedSheet({
    required this.reference,
    required this.total,
    required this.clientPhone,
    required this.waUri,
    required this.hasWhatsapp,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Checkmark animé (pop élastique au montage).
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 520),
            curve: Curves.elasticOut,
            builder: (_, v, child) =>
                Transform.scale(scale: v.clamp(0, 1.2), child: child),
            child: Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                  color: sem.successSurface, shape: BoxShape.circle),
              child: Icon(Icons.check_rounded, size: 38, color: sem.success),
            ),
          ),
          const SizedBox(height: 16),
          Text('Votre commande est confirmée !',
              textAlign: TextAlign.center, style: AppTextStyles.subtitleBold),
          const SizedBox(height: 8),
          Text(
            clientPhone.isNotEmpty
                ? 'Nous vous appellerons au $clientPhone pour confirmer la '
                    'livraison (généralement sous 24–48 h).'
                : 'Nous vous appellerons pour confirmer la livraison '
                    '(généralement sous 24–48 h).',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySmSecondary,
          ),
          const SizedBox(height: 16),
          // Référence commande.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.inputFill,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.tag_rounded,
                  size: 14, color: AppColors.textHint),
              const SizedBox(width: 6),
              Text('Référence : ', style: AppTextStyles.caption),
              Text(reference,
                  style: AppTextStyles.captionBold
                      .copyWith(color: AppColors.onSurface)),
            ]),
          ),
          // Montant à préparer en espèces.
          if (total > 0) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.primarySurface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                Icon(Icons.payments_outlined,
                    size: 18, color: AppColors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('À préparer en espèces',
                      style: AppTextStyles.bodySm
                          .copyWith(color: AppColors.onSurface)),
                ),
                Text(CurrencyFormatter.format(total),
                    style: AppTextStyles.subtitleBold
                        .copyWith(color: AppColors.primary)),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          if (hasWhatsapp) ...[
            SizedBox(
              width: double.infinity,
              child: Link(
                uri:    waUri,
                target: LinkTarget.blank,
                builder: (ctx, followLink) => ElevatedButton.icon(
                  onPressed: followLink,
                  icon: const Icon(Icons.chat_rounded, size: 18),
                  label: const Text('Confirmer sur WhatsApp'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.whatsapp,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 48),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 48),
                foregroundColor: AppColors.primary,
                side: BorderSide(
                    color: AppColors.primary.withValues(alpha: 0.4)),
              ),
              child: Text('Continuer mes achats',
                  style: AppTextStyles.label
                      .copyWith(color: AppColors.primary)),
            ),
          ),
        ]),
      ),
    );
  }
}

// ─── Card produit (catalogue public) ────────────────────────────────────────
//
// Card DÉDIÉE au catalogue (n'utilise PAS le `ProductGridCard` partagé pour ne
// pas impacter caisse/inventaire) : image carrée + badge stock, nom + variante
// + prix, et un bouton « Commander » pleine largeur. Tap card → fiche détail.

class _CatalogueCard extends StatelessWidget {
  final _CatalogueItem item;
  final bool selectMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onOrder;
  const _CatalogueCard({
    required this.item,
    required this.selectMode,
    required this.selected,
    required this.onTap,
    required this.onOrder,
  });

  @override
  Widget build(BuildContext context) {
    final outOfStock = item.stock <= 0;
    final lowStock   = !outOfStock && item.stock <= 3;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? AppColors.primary : AppColors.divider,
              width: selected ? 1.5 : 1),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 6, offset: const Offset(0, 2)),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Image carrée (Expanded) + badges ──
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _CardImage(url: item.imageUrl),
                  // Badges (haut-gauche, empilés) : Nouveau (récent) + stock.
                  if (item.isRecent || outOfStock || lowStock)
                    Positioned(
                      top: 6, left: 6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (item.isRecent) ...[
                            _Badge(label: 'Nouveau', color: AppColors.primaryFill),
                            const SizedBox(height: 4),
                          ],
                          if (outOfStock || lowStock)
                            _StockBadge(outOfStock: outOfStock),
                        ],
                      ),
                    ),
                  if (selectMode)
                    Positioned(
                      top: 6, right: 6,
                      child: _SelectDot(selected: selected),
                    ),
                ],
              ),
            ),
            // ── Infos + bouton ──
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(item.baseProductName,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption.copyWith(
                          color: AppColors.onSurface,
                          fontWeight: FontWeight.w600)),
                  if (item.variantName != null &&
                      item.variantName!.isNotEmpty)
                    Text(item.variantName!,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.micro),
                  const SizedBox(height: 4),
                  Text(CurrencyFormatter.format(item.price),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySmBold
                          .copyWith(color: AppColors.primary)),
                  const SizedBox(height: 6),
                  // Bouton « Commander » pleine largeur (grisé si rupture).
                  SizedBox(
                    width: double.infinity,
                    height: 36,
                    child: outOfStock
                        ? Container(
                            decoration: BoxDecoration(
                              color: AppColors.inputFill,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.center,
                            child: Text('Indisponible',
                                style: AppTextStyles.caption
                                    .copyWith(color: AppColors.textHint)),
                          )
                        : Material(
                            color: AppColors.primaryFill,
                            borderRadius: BorderRadius.circular(8),
                            child: InkWell(
                              onTap: onOrder,
                              borderRadius: BorderRadius.circular(8),
                              child: Center(
                                child: Text('Commander',
                                    style: AppTextStyles.caption.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700)),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Image de card : `cover`, skeleton pendant le chargement, placeholder
/// neutre (fond `inputFill` + icône) si pas de photo ou URL cassée.
class _CardImage extends StatelessWidget {
  final String? url;
  const _CardImage({this.url});

  Widget _placeholder({bool loading = false}) => Container(
        color: AppColors.inputFill,
        alignment: Alignment.center,
        child: loading
            ? const SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(Icons.image_outlined,
                size: 28, color: AppColors.textHint),
      );

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) return _placeholder();
    return Image.network(url!,
        fit: BoxFit.cover,
        loadingBuilder: (_, child, prog) =>
            prog == null ? child : _placeholder(loading: true),
        errorBuilder: (_, __, ___) => _placeholder());
  }
}

/// Petit badge plein coloré (texte blanc) pour le coin d'une card.
class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: AppTextStyles.micro.copyWith(
                color: Colors.white, fontWeight: FontWeight.w700)),
      );
}

/// Badge de stock : « Rupture » (rouge) si stock 0, sinon « Stock limité »
/// (ambre) — déclenché par le parent quand stock ≤ 3.
class _StockBadge extends StatelessWidget {
  final bool outOfStock;
  const _StockBadge({required this.outOfStock});

  @override
  Widget build(BuildContext context) => _Badge(
        label: outOfStock ? 'Rupture' : 'Stock limité',
        color: outOfStock ? AppColors.error : AppColors.warning,
      );
}

/// Pastille de sélection (haut-droite) en mode sélection multiple.
class _SelectDot extends StatelessWidget {
  final bool selected;
  const _SelectDot({required this.selected});

  @override
  Widget build(BuildContext context) => Container(
        width: 22, height: 22,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary
              : Colors.white.withValues(alpha: 0.9),
          shape: BoxShape.circle,
          border: Border.all(
              color: selected ? AppColors.primary : AppColors.divider,
              width: 1.5),
        ),
        child: selected
            ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
            : null,
      );
}

// ─── Delivery card (mode livreur) ──────────────────────────────────────────
//
// Card minimaliste utilisée quand `mode=delivery` est dans l'URL. Le
// livreur n'a besoin que d'identifier visuellement le produit et la
// quantité à livrer ; ni nom, ni prix, ni stock, ni interactions.
// AspectRatio 3:4 imposé pour rester aligné avec la grille
// (`childAspectRatio: 0.75` côté SliverGrid).
class _DeliveryCard extends StatelessWidget {
  final String? imageUrl;
  final int     quantity;
  final String? sku;
  const _DeliveryCard({
    required this.imageUrl,
    required this.quantity,
    required this.sku,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final skuValue = (sku ?? '').trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.4),
          border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imageUrl != null && imageUrl!.isNotEmpty)
              Image.network(imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const _DeliveryPlaceholder())
            else
              const _DeliveryPlaceholder(),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primaryFill,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  '×$quantity',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800),
                ),
              ),
            ),
            // Badge SKU en bas — sert au livreur à identifier précisément
            // la référence à prendre dans le stock (utile quand plusieurs
            // produits/variantes se ressemblent visuellement). Masqué si
            // pas de SKU enregistré pour le produit.
            if (skuValue.isNotEmpty)
              Positioned(
                left:   8,
                right:  8,
                bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    skuValue,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color:      Colors.white,
                      fontSize:   11,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DeliveryPlaceholder extends StatelessWidget {
  const _DeliveryPlaceholder();
  @override
  Widget build(BuildContext context) => Container(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
        child: Icon(Icons.image_outlined,
            size: 40,
            color: Theme.of(context).colorScheme.onSurfaceVariant
                .withValues(alpha: 0.4)),
      );
}

// ─── Fiche produit (catalogue public) ───────────────────────────────────────
//
// Bottom sheet ouverte au tap sur une card (hors mode sélection). Valorise le
// visuel : grande image zoomable (pincer / molette), galerie des variantes du
// même produit (chacune a sa propre image), prix bien visible, et bouton
// « Commander » qui réutilise le flux `_placeOrder` (RPC place_public_order).
// Objectif : laisser le client examiner le produit en grand → déclencher l'achat.
class _ProductDetailSheet extends StatefulWidget {
  final _CatalogueItem item;
  final List<_CatalogueItem> siblings;
  /// Commande la variante choisie avec la quantité sélectionnée.
  final void Function(_CatalogueItem item, int qty) onOrder;
  const _ProductDetailSheet({
    required this.item,
    required this.siblings,
    required this.onOrder,
  });

  @override
  State<_ProductDetailSheet> createState() => _ProductDetailSheetState();
}

class _ProductDetailSheetState extends State<_ProductDetailSheet> {
  late _CatalogueItem _active;
  int _qty = 1;
  final _zoom = TransformationController();

  @override
  void initState() {
    super.initState();
    _active = widget.item;
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  /// Max commandable = stock de la variante active (au moins 1 par sécurité).
  int get _maxQty => _active.stock < 1 ? 1 : _active.stock;

  void _setQty(int q) {
    final clamped = q < 1 ? 1 : (q > _maxQty ? _maxQty : q);
    if (clamped != _qty) setState(() => _qty = clamped);
  }

  void _select(_CatalogueItem it) {
    if (it.key == _active.key) return;
    setState(() {
      _active = it;
      _qty = 1; // reset quantité au changement de variante
      _zoom.value = Matrix4.identity();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    final hasGallery = widget.siblings.length > 1;
    // Variante hero = celle mise en avant dans la boutique (même règle POS).
    final featuredKey = hasGallery
        ? _featuredAmong(widget.siblings).key
        : _active.key;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize:     0.55,
      maxChildSize:     0.96,
      expand: false,
      builder: (ctx, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(children: [
          // ── Poignée + fermer ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 2),
            child: Row(children: [
              const SizedBox(width: 32),
              Expanded(
                child: Center(
                  child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(
                      color: sem.borderSubtle,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded,
                    size: 20, color: AppColors.textHint),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                    minWidth: 32, minHeight: 32),
              ),
            ]),
          ),

          Expanded(
            child: ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                // ── Grande image zoomable ───────────────────────────
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      color: sem.brand.withValues(alpha: 0.06),
                      child: InteractiveViewer(
                        transformationController: _zoom,
                        minScale: 1, maxScale: 4,
                        child: ProductImageCard(
                          imageUrl:   _active.imageUrl,
                          fillParent: true,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.zoom_in_rounded,
                      size: 13, color: AppColors.textHint),
                  const SizedBox(width: 4),
                  Text('Pincez ou faites défiler pour zoomer',
                      style: AppTextStyles.micro
                          .copyWith(color: AppColors.textHint)),
                ]),

                // ── Variantes : vignettes image (active = anneau primary,
                // hero boutique = badge « ★ », épuisée = voilée) ──────────
                if (hasGallery) ...[
                  const SizedBox(height: 16),
                  Text('Choix',
                      style: AppTextStyles.micro.copyWith(
                          fontWeight: FontWeight.w700, letterSpacing: 0.4)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10, runSpacing: 12,
                    children: [
                      for (final s in widget.siblings)
                        _VariantThumb(
                          item:     s,
                          selected: s.key == _active.key,
                          featured: s.key == featuredKey,
                          onTap:    () => _select(s),
                        ),
                    ],
                  ),
                ],

                // ── Nom + variante ──────────────────────────────────
                const SizedBox(height: 16),
                Text(_active.baseProductName,
                    style: AppTextStyles.subtitle.copyWith(
                        color: theme.colorScheme.onSurface)),
                if (_active.variantName != null
                    && _active.variantName!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(_active.variantName!,
                      style: AppTextStyles.bodySm
                          .copyWith(color: AppColors.textSecondary)),
                ],

                // ── Prix + disponibilité ("X disponibles" si ≤ 5) ───
                const SizedBox(height: 12),
                Row(children: [
                  Text(CurrencyFormatter.format(_active.price),
                      style: AppTextStyles.title.copyWith(
                          color: AppColors.primary)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: sem.successSurface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 6, height: 6,
                          decoration: BoxDecoration(
                              color: sem.success, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text(
                          _active.stock <= 5
                              ? '${_active.stock} disponible'
                                  '${_active.stock > 1 ? 's' : ''}'
                              : 'En stock',
                          style: AppTextStyles.captionBold
                              .copyWith(color: sem.successText)),
                    ]),
                  ),
                ]),

                // ── Description complète ────────────────────────────
                if ((_active.description ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(_active.description!.trim(),
                      style: AppTextStyles.bodySmSecondary),
                ],

                if ((_active.sku ?? '').isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Réf. ${_active.sku}',
                      style: AppTextStyles.micro.copyWith(
                          color: AppColors.textHint,
                          fontFamily: 'monospace')),
                ],

                // ── Sélecteur quantité (+/- · min 1 · max stock) ────
                const SizedBox(height: 18),
                Row(children: [
                  Text('Quantité',
                      style: AppTextStyles.caption.copyWith(
                          color: AppColors.onSurface,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  _QtyStepper(
                    qty:     _qty,
                    max:     _maxQty,
                    onMinus: () => _setQty(_qty - 1),
                    onPlus:  () => _setQty(_qty + 1),
                  ),
                ]),
              ],
            ),
          ),

          // ── CTA « Commander — total » épinglé en bas ───────────────
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity, height: 56,
                child: ElevatedButton(
                  onPressed: () => widget.onOrder(_active, _qty),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryFill,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                          'Commander — '
                          '${CurrencyFormatter.format(_active.price * _qty)}',
                          style: AppTextStyles.label
                              .copyWith(color: Colors.white)),
                      Text('Paiement à la réception',
                          style: AppTextStyles.micro.copyWith(
                              color: Colors.white.withValues(alpha: 0.85))),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Chip de variante dans la fiche détail : actif = fond/bordure primary clair ;
/// épuisé = grisé + texte barré (non cliquable). Cf. spec catalogue.
/// Vignette image d'une variante dans la fiche détail (zone « Choix »).
/// - Sélectionnée → anneau primary + pastille de coche.
/// - Mise en avant boutique (`featured`) → badge étoile en haut à gauche
///   (même variante hero que celle affichée dans la boutique / le POS).
/// - Épuisée → image voilée + libellé « Épuisé », tap désactivé.
class _VariantThumb extends StatelessWidget {
  final _CatalogueItem item;
  final bool selected;
  final bool featured;
  final VoidCallback onTap;
  const _VariantThumb({
    required this.item,
    required this.selected,
    required this.featured,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final soldOut = item.stock <= 0;
    final label = item.variantName ?? item.baseProductName;
    return GestureDetector(
      onTap: soldOut ? null : onTap,
      child: SizedBox(
        width: 78,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 78, height: 78,
                  decoration: BoxDecoration(
                    color: AppColors.inputFill,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected ? AppColors.primary : AppColors.divider,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Opacity(
                      opacity: soldOut ? 0.4 : 1,
                      child: ProductImageCard(
                        imageUrl:   item.imageUrl,
                        fillParent: true,
                      ),
                    ),
                  ),
                ),
                // Badge « mis en avant » = variante hero de la boutique.
                if (featured)
                  Positioned(
                    top: 4, left: 4,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: AppColors.primaryFill,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.star_rounded,
                          size: 12, color: Colors.white),
                    ),
                  ),
                // Pastille de coche sur la variante sélectionnée.
                if (selected)
                  Positioned(
                    bottom: 4, right: 4,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: AppColors.primaryFill,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check_rounded,
                          size: 12, color: Colors.white),
                    ),
                  ),
                // Voile « Épuisé ».
                if (soldOut)
                  Positioned.fill(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('Épuisé',
                            style: AppTextStyles.micro
                                .copyWith(color: Colors.white)),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppTextStyles.micro.copyWith(
                color: soldOut
                    ? AppColors.textHint
                    : (selected
                        ? AppColors.primary
                        : AppColors.textSecondary),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sélecteur de quantité +/- (min 1, max stock). Boutons grisés aux bornes.
class _QtyStepper extends StatelessWidget {
  final int qty;
  final int max;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _QtyStepper({
    required this.qty,
    required this.max,
    required this.onMinus,
    required this.onPlus,
  });

  Widget _btn(IconData icon, VoidCallback? onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 38, height: 38,
          alignment: Alignment.center,
          child: Icon(icon, size: 18,
              color: onTap == null
                  ? AppColors.textHint
                  : AppColors.primary),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _btn(Icons.remove_rounded, qty > 1 ? onMinus : null),
        Container(
          constraints: const BoxConstraints(minWidth: 32),
          alignment: Alignment.center,
          child: Text('$qty',
              style: AppTextStyles.label
                  .copyWith(color: AppColors.onSurface)),
        ),
        _btn(Icons.add_rounded, qty < max ? onPlus : null),
      ]),
    );
  }
}
