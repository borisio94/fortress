import '../../../../core/services/export_models.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../inventaire/domain/entities/stock_location.dart';

/// Source de données pour l'export Commandes — offline-first Hive.
///
/// Lit directement `ordersBox.values` (Map) plutôt que de réhydrater
/// l'entité `Sale` complète : l'export n'a besoin que de quelques
/// colonnes scalaires + une agrégation des items, donc le passe-plat
/// JSON suffit et reste insensible aux évolutions futures de l'entité.
class OrdersExportSource {
  const OrdersExportSource._();

  /// Header CSV/PDF — 9 colonnes spec.
  static const List<String> header = [
    'ID',
    'Date',
    'Client',
    'Statut',
    'Paiement',
    'Montant',
    'Articles',
    'Livreur',
    'Emplacement',
  ];

  static List<List<Object?>> collect(ExportScope scope) {
    return switch (scope) {
      ExportScopeShop(:final shopId)        => _collectShop(shopId),
      ExportScopePartner(:final locationId) => _collectPartner(locationId),
      ExportScopeGlobal()                    => _collectGlobal(),
      ExportScopePlatform()                  => const <List<Object?>>[],
    };
  }

  // ── Shop scope ────────────────────────────────────────────────

  static List<List<Object?>> _collectShop(String shopId) {
    final locations = _locationsById();
    final rows = <List<Object?>>[];
    for (final raw in HiveBoxes.ordersBox.values) {
      final m = Map<String, dynamic>.from(raw);
      if (m['shop_id'] != shopId) continue;
      if (m['deleted_at'] != null) continue; // exclut soft-deleted
      rows.add(_rowFor(m, locations));
    }
    _sortByDateDesc(rows);
    return rows;
  }

  // ── Partner scope ─────────────────────────────────────────────

  static List<List<Object?>> _collectPartner(String locationId) {
    final locations = _locationsById();
    final rows = <List<Object?>>[];
    for (final raw in HiveBoxes.ordersBox.values) {
      final m = Map<String, dynamic>.from(raw);
      if (m['deleted_at'] != null) continue;
      if (m['delivery_location_id'] != locationId) continue;
      rows.add(_rowFor(m, locations));
    }
    _sortByDateDesc(rows);
    return rows;
  }

  // ── Global scope ──────────────────────────────────────────────

  static List<List<Object?>> _collectGlobal() {
    final me = LocalStorageService.getCurrentUser();
    if (me == null) return const [];
    final myShopIds = LocalStorageService.getShopsForUser(me.id)
        .map((s) => s.id)
        .toSet();
    final shopNames = {
      for (final s in LocalStorageService.getShopsForUser(me.id))
        s.id: s.name,
    };
    final locations = _locationsById();
    final rows = <List<Object?>>[];
    for (final raw in HiveBoxes.ordersBox.values) {
      final m = Map<String, dynamic>.from(raw);
      if (m['deleted_at'] != null) continue;
      final sid = m['shop_id']?.toString() ?? '';
      if (!myShopIds.contains(sid)) continue;
      final row = _rowFor(m, locations);
      // Suffixe l'emplacement par le nom de boutique pour distinguer
      // des dépôts homonymes dans l'agrégat global.
      final shopName = shopNames[sid];
      if (shopName != null) {
        row[8] = '$shopName — ${row[8]}';
      }
      rows.add(row);
    }
    _sortByDateDesc(rows);
    return rows;
  }

  // ── Helpers ───────────────────────────────────────────────────

  /// Calcule le montant total à partir des items + fees + discount + tax.
  /// La logique miroir celle de `Sale.total` mais sans réhydrater l'entité.
  /// Si la map porte une clé `amount_total` (futur cache serveur), on la
  /// privilégie.
  static double _totalFromMap(Map<String, dynamic> m) {
    final cached = (m['amount_total'] ?? m['total']) as num?;
    if (cached != null) return cached.toDouble();
    double subtotal = 0;
    final items = (m['items'] as List?) ?? const [];
    for (final raw in items) {
      if (raw is! Map) continue;
      final qty = (raw['quantity']    as num?)?.toInt() ?? 0;
      final base = (raw['unit_price'] as num?)?.toDouble() ?? 0;
      final custom = (raw['custom_price'] as num?)?.toDouble();
      final discount = (raw['discount'] as num?)?.toDouble() ?? 0;
      final unit = custom ?? base;
      subtotal += unit * qty * (1 - discount / 100);
    }
    final discountAmount = (m['discount_amount'] as num?)?.toDouble() ?? 0;
    final taxRate        = (m['tax_rate']        as num?)?.toDouble() ?? 0;
    double fees = 0;
    for (final f in (m['fees'] as List?) ?? const []) {
      if (f is Map) {
        fees += (f['amount'] as num?)?.toDouble() ?? 0;
      }
    }
    final taxed = (subtotal - discountAmount) * (1 + taxRate / 100);
    return taxed + fees;
  }

  static int _itemsCount(Map<String, dynamic> m) {
    int n = 0;
    for (final raw in (m['items'] as List?) ?? const []) {
      if (raw is Map) {
        n += (raw['quantity'] as num?)?.toInt() ?? 0;
      }
    }
    return n;
  }

  /// `JJ/MM/AAAA HH:mm` — format lisible humain. ISO conservé en source
  /// (`created_at`) pour parsing fiable.
  static String _formatDate(String? iso) {
    if (iso == null) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final local = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static String _statusLabel(String? key) => switch (key) {
        'completed'  => 'Complétée',
        'scheduled'  => 'Programmée',
        'processing' => 'En cours',
        'cancelled'  => 'Annulée',
        'refused'    => 'Refusée',
        'refunded'   => 'Remboursée',
        _            => key ?? '',
      };

  static String _paymentLabel(Map<String, dynamic> m) {
    final method = m['payment_method']?.toString() ?? 'cash';
    final status = m['payment_status']?.toString() ?? 'unpaid';
    final methodFr = switch (method) {
      'cash'         => 'Espèces',
      'mobileMoney'  => 'Mobile Money',
      'mobile_money' => 'Mobile Money',
      'card'         => 'Carte',
      'credit'       => 'Crédit',
      _              => method,
    };
    final statusFr = switch (status) {
      'unpaid'   => 'Non payé',
      'partial'  => 'Acompte',
      'paid'     => 'Payé',
      'refunded' => 'Remboursé',
      _          => status,
    };
    return '$methodFr · $statusFr';
  }

  static String _shortId(String? id) {
    if (id == null || id.isEmpty) return '';
    if (id.length <= 8) return id.toUpperCase();
    return id.substring(0, 8).toUpperCase();
  }

  static List<Object?> _rowFor(
      Map<String, dynamic> m, Map<String, StockLocation> locations) {
    final clientName = (m['client_name'] as String?)?.trim();
    final clientPhone = (m['client_phone'] as String?)?.trim();
    final clientLabel = (clientName != null && clientName.isNotEmpty)
        ? clientName
        : (clientPhone ?? '—');
    final locationId = m['delivery_location_id'] as String?;
    final locationLabel = locationId != null
        ? (locations[locationId]?.name ?? 'Emplacement supprimé')
        : 'Boutique';
    return [
      _shortId(m['id']?.toString()),
      _formatDate(m['created_at']?.toString()),
      clientLabel,
      _statusLabel(m['status'] as String?),
      _paymentLabel(m),
      _totalFromMap(m),
      _itemsCount(m),
      (m['delivery_person_name'] as String?) ?? '',
      locationLabel,
    ];
  }

  static Map<String, StockLocation> _locationsById() {
    final box = HiveBoxes.stockLocationsBox;
    final out = <String, StockLocation>{};
    for (final raw in box.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
        out[loc.id] = loc;
      } catch (_) {}
    }
    return out;
  }

  /// Tri date desc — la 1re colonne après ID. Les ids 8 chars sont
  /// pseudo-aléatoires (uuid v4 tronqué) donc on trie par la 2e colonne
  /// `date` qui contient le format lisible ; pour rester fiable on
  /// reparse vers DateTime à la volée.
  static void _sortByDateDesc(List<List<Object?>> rows) {
    rows.sort((a, b) {
      final da = _parseFr(a[1] as String? ?? '');
      final db = _parseFr(b[1] as String? ?? '');
      return db.compareTo(da);
    });
  }

  static DateTime _parseFr(String s) {
    // `JJ/MM/AAAA HH:mm` → DateTime ; fallback epoch=0 si invalide.
    try {
      final parts = s.split(' ');
      final date = parts[0].split('/');
      final time = parts.length > 1 ? parts[1].split(':') : ['0', '0'];
      return DateTime(
        int.parse(date[2]), int.parse(date[1]), int.parse(date[0]),
        int.parse(time[0]), int.parse(time[1]),
      );
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  /// Partenaires de la shop pour le selector. Identique au pattern
  /// `ProductsExportSource.partnerLocationsForShop`.
  static List<StockLocation> partnerLocationsForShop(String shopId) {
    final shop = LocalStorageService.getShop(shopId);
    if (shop == null) return const [];
    final ownerId = shop.ownerId;
    final out = <StockLocation>[];
    for (final raw in HiveBoxes.stockLocationsBox.values) {
      try {
        final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
        if (loc.type != StockLocationType.partner) continue;
        if (loc.ownerId != ownerId) continue;
        if (!loc.isActive) continue;
        out.add(loc);
      } catch (_) {}
    }
    out.sort((a, b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }
}
