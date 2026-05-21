import '../../../../core/services/export_models.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../domain/entities/client.dart';

/// Source de données pour l'export Clients — offline-first.
///
/// Le scope `Partner` n'a pas de sens pour un carnet d'adresses
/// (le client appartient à une boutique, pas à un dépôt) : le scope
/// selector est ouvert avec `allowPartner: false`. Le sealed Switch
/// reste exhaustif et délègue Partner → liste vide en filet.
class ClientsExportSource {
  const ClientsExportSource._();

  /// Header CSV — 8 colonnes spec.
  static const List<String> header = [
    'Nom',
    'Téléphone',
    'Email',
    'Ville',
    'Quartier',
    'Nb commandes',
    'Total dépensé',
    'Dernière commande',
    'Segment',
  ];

  static List<List<Object?>> collect(ExportScope scope) {
    return switch (scope) {
      ExportScopeShop(:final shopId) => _collectShop(shopId),
      ExportScopePartner()           => const [], // n/a — selector le bloque
      ExportScopeGlobal()            => _collectGlobal(),
    };
  }

  // ── Shop scope ───────────────────────────────────────────────

  static List<List<Object?>> _collectShop(String shopId) {
    final rows = <List<Object?>>[];
    for (final raw in HiveBoxes.clientsBox.values) {
      final m = Map<String, dynamic>.from(raw);
      if (m['store_id'] != shopId) continue;
      if (m['is_archived'] == true) continue;
      rows.add(_rowFor(_fromMap(m)));
    }
    _sortByName(rows);
    return rows;
  }

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
    final rows = <List<Object?>>[];
    for (final raw in HiveBoxes.clientsBox.values) {
      final m = Map<String, dynamic>.from(raw);
      final sid = m['store_id']?.toString() ?? '';
      if (!myShopIds.contains(sid)) continue;
      if (m['is_archived'] == true) continue;
      final row = _rowFor(_fromMap(m));
      final shopName = shopNames[sid];
      if (shopName != null) {
        // Préfixe le nom du client par la boutique pour éviter de
        // mélanger 2 « Jean Dupont » de 2 catalogues différents.
        row[0] = '$shopName — ${row[0]}';
      }
      rows.add(row);
    }
    _sortByName(rows);
    return rows;
  }

  // ── Mapping ──────────────────────────────────────────────────

  static Client _fromMap(Map<String, dynamic> m) {
    return Client(
      id:           m['id']?.toString() ?? '',
      storeId:      m['store_id']?.toString() ?? '',
      name:         m['name']?.toString() ?? '',
      phone:        m['phone']?.toString(),
      email:        m['email']?.toString(),
      city:         m['city']?.toString(),
      district:     m['district']?.toString(),
      address:      m['address']?.toString(),
      notes:        m['notes']?.toString(),
      createdAt:    DateTime.tryParse(m['created_at']?.toString() ?? '')
                    ?? DateTime.now(),
      lastVisitAt:  DateTime.tryParse(m['last_visit_at']?.toString() ?? ''),
      totalOrders:  (m['total_orders'] as num?)?.toInt() ?? 0,
      totalSpent:   (m['total_spent']  as num?)?.toDouble() ?? 0,
      isArchived:   m['is_archived'] == true,
    );
  }

  static List<Object?> _rowFor(Client c) {
    return [
      c.name,
      c.phone ?? '',
      c.email ?? '',
      c.city ?? '',
      c.district ?? '',
      c.totalOrders,
      c.totalSpent,
      _formatDate(c.lastVisitAt),
      c.tag.label,
    ];
  }

  static String _formatDate(DateTime? d) {
    if (d == null) return '';
    final local = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year}';
  }

  static void _sortByName(List<List<Object?>> rows) {
    rows.sort((a, b) => (a[0] as String)
        .toLowerCase()
        .compareTo((b[0] as String).toLowerCase()));
  }
}
