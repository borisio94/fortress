import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/empty_state_widget.dart';

/// Écran super-admin (hotfix_085) — liste des produits soft-deleted et
/// permet de les restaurer.
///
/// Lecture
/// ───────
/// Lecture DIRECTE Supabase (pas Hive). La RLS
/// `products_select_deleted_sa` accorde le SELECT au super-admin
/// uniquement → la lecture renverra 0 lignes pour tout autre utilisateur.
///
/// Pagination
/// ──────────
/// 20 lignes par page, tri `deleted_at DESC`. Scroll infini (load à 85%
/// du bas). Bouton "Rafraîchir" pour repartir de zéro.
///
/// Affichage
/// ─────────
/// Lecture prioritaire de `archived_snapshot` (capture figée au moment
/// de la suppression). Fallback sur les colonnes courantes si snapshot
/// null (cas legacy). Le bouton « Voir snapshot » ouvre un bottom sheet
/// affichant le JSON formaté du snapshot.
///
/// Restauration
/// ────────────
/// Bouton « Restaurer » par ligne → `AppDatabase.bgRestoreProduct` →
/// RPC SQL `restore_product`. Retry automatique 1× sur erreur réseau.
/// La RPC ne touche pas à `is_active` ni `is_visible_web` : le manager
/// doit republier manuellement. La RPC SQL trace elle-même un
/// `activity_log` `product_restored` — pas de log client (évite doublon).
///
/// Variante embeddable
/// ───────────────────
/// [DeletedProductsBody] expose le contenu sans Scaffold/AppBar, utilisé
/// par le hub à onglets.
class DeletedProductsPage extends ConsumerWidget {
  const DeletedProductsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSuperAdmin = ref.watch(currentPlanProvider).isSuperAdmin;
    if (!isSuperAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Produits supprimés')),
        body: const EmptyStateWidget(
          icon:     Icons.lock_outline_rounded,
          title:    'Réservé au super-admin',
          subtitle: 'Cette page liste les produits supprimés de toutes '
              'les boutiques. Seul le super-admin Fortress y a accès.',
        ),
      );
    }
    return const _ProductsScaffold();
  }
}

class _ProductsScaffold extends StatefulWidget {
  const _ProductsScaffold();
  @override
  State<_ProductsScaffold> createState() => _ProductsScaffoldState();
}

class _ProductsScaffoldState extends State<_ProductsScaffold> {
  final GlobalKey<DeletedProductsBodyState> _bodyKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Produits supprimés'),
        actions: [
          IconButton(
            tooltip: 'Rafraîchir',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _bodyKey.currentState?.refresh(),
          ),
        ],
      ),
      body: DeletedProductsBody(key: _bodyKey),
    );
  }
}

class DeletedProductsBody extends ConsumerStatefulWidget {
  const DeletedProductsBody({super.key});
  @override
  ConsumerState<DeletedProductsBody> createState() =>
      DeletedProductsBodyState();
}

class DeletedProductsBodyState extends ConsumerState<DeletedProductsBody> {
  static const int _pageSize = 20;

  final List<_DeletedProductRow> _rows = [];
  bool _loading      = true;
  bool _loadingMore  = false;
  bool _hasMore      = true;
  String? _error;
  late final ScrollController _scrollCtrl;

  @override
  void initState() {
    super.initState();
    _scrollCtrl = ScrollController()..addListener(_onScroll);
    _loadFirstPage();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore) return;
    if (_scrollCtrl.position.pixels
        >= _scrollCtrl.position.maxScrollExtent * 0.85) {
      _loadMore();
    }
  }

  Future<void> refresh() async {
    if (!mounted) return;
    setState(() {
      _rows.clear();
      _loading     = true;
      _loadingMore = false;
      _hasMore     = true;
      _error       = null;
    });
    await _loadFirstPage();
  }

  Future<void> _loadFirstPage() async {
    try {
      final page = await _fetch(offset: 0);
      if (!mounted) return;
      setState(() {
        _rows
          ..clear()
          ..addAll(page);
        _hasMore = page.length == _pageSize;
        _loading = false;
        _error   = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error   = e.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final page = await _fetch(offset: _rows.length);
      if (!mounted) return;
      setState(() {
        _rows.addAll(page);
        _hasMore     = page.length == _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      AppSnack.error(context, 'Page suivante : ${e.toString()}');
    }
  }

  Future<List<_DeletedProductRow>> _fetch({required int offset}) async {
    final db = Supabase.instance.client;
    final raw = await db.from('products')
        .select('id, store_id, name, sku, barcode, price_sell, price_buy, '
                'image_url, variants, archived_snapshot, '
                'deleted_at, deleted_by, delete_reason, created_at')
        .not('deleted_at', 'is', null)
        .order('deleted_at', ascending: false)
        .range(offset, offset + _pageSize - 1);
    final rows = List<Map<String, dynamic>>.from(raw as List);

    final deleterIds = rows.map((r) => r['deleted_by'] as String?)
        .whereType<String>().toSet().toList();
    Map<String, String> emails = const {};
    if (deleterIds.isNotEmpty) {
      try {
        final profs = await db.from('profiles')
            .select('id, email')
            .inFilter('id', deleterIds);
        emails = {
          for (final p in (profs as List).cast<Map<String, dynamic>>())
            (p['id'] as String): (p['email'] as String? ?? '')
        };
      } catch (_) {}
    }
    final shopIds = rows.map((r) => r['store_id'] as String?)
        .whereType<String>().toSet().toList();
    Map<String, String> shopNames = const {};
    if (shopIds.isNotEmpty) {
      try {
        final shops = await db.from('shops')
            .select('id, name')
            .inFilter('id', shopIds);
        shopNames = {
          for (final s in (shops as List).cast<Map<String, dynamic>>())
            (s['id'] as String): (s['name'] as String? ?? '')
        };
      } catch (_) {}
    }
    return rows.map((r) => _DeletedProductRow.fromMap(r,
        deleterEmail: emails[r['deleted_by'] as String? ?? ''],
        shopName:     shopNames[r['store_id']   as String? ?? ''],
    )).toList();
  }

  Future<void> _restore(_DeletedProductRow row) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
        title: const Text('Restaurer le produit',
            style: AppTextStyles.subtitleBold),
        content: Text(
            'Le produit « ${row.displayName} » sera restauré dans la '
            'boutique d\'origine MAIS restera invisible '
            '(`is_active = false`, `is_visible_web = false`). Le manager '
            'devra le republier manuellement après vérification.\n\n'
            'Confirmer la restauration ?',
            style: AppTextStyles.body),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dc).pop(false),
              child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () => Navigator.of(dc).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.secondary,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Restaurer'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      AppSnack.error(context, 'Session expirée — reconnexion requise.');
      return;
    }
    final result = await _restoreWithRetry(
        productId: row.id, userId: userId);
    if (!mounted) return;
    if (result.success) {
      AppSnack.success(context,
          'Produit « ${row.displayName} » restauré. Republie-le pour '
          'le rendre visible.');
      await refresh();
    } else {
      AppSnack.error(context, result.message);
    }
  }

  Future<_RestoreOutcome> _restoreWithRetry({
    required String productId,
    required String userId,
  }) async {
    try {
      await AppDatabase.bgRestoreProduct(
          productId: productId, userId: userId);
      return const _RestoreOutcome(success: true);
    } catch (e) {
      final mapped = _mapRestoreProductError(e);
      if (mapped.permanent) return _RestoreOutcome(message: mapped.message);
      try {
        await AppDatabase.bgRestoreProduct(
            productId: productId, userId: userId);
        return const _RestoreOutcome(success: true);
      } catch (e2) {
        final mapped2 = _mapRestoreProductError(e2);
        return _RestoreOutcome(message: mapped2.message);
      }
    }
  }

  void _showSnapshot(_DeletedProductRow row) {
    if (row.archivedSnapshot == null) {
      AppSnack.error(context, 'Aucun snapshot disponible pour ce produit.');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SnapshotSheet(
        title:    row.displayName,
        snapshot: row.archivedSnapshot!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Erreur de chargement : $_error',
              style: AppTextStyles.bodySecondary,
              textAlign: TextAlign.center),
        ),
      );
    }
    if (_rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 40),
            EmptyStateWidget(
              icon:     Icons.inventory_2_outlined,
              title:    'Aucun produit supprimé',
              subtitle: 'Quand un manager supprime un produit, '
                  'il apparaît ici pour audit ou restauration.',
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.separated(
        controller: _scrollCtrl,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _rows.length + (_loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          if (i >= _rows.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return _DeletedProductCard(
            row: _rows[i],
            onRestore:      () => _restore(_rows[i]),
            onShowSnapshot: () => _showSnapshot(_rows[i]),
          );
        },
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Mapping erreurs RPC → message FR + flag "permanent" (skip retry).
// ══════════════════════════════════════════════════════════════════════════

class _MappedError {
  final String message;
  final bool   permanent;
  const _MappedError(this.message, {this.permanent = false});
}

class _RestoreOutcome {
  final bool   success;
  final String message;
  const _RestoreOutcome({this.success = false, this.message = ''});
}

_MappedError _mapRestoreProductError(Object e) {
  final err = e.toString();
  if (err.contains('permission_insuffisante') || err.contains('42501')) {
    // Théoriquement impossible si l'UI est correctement gated, mais on
    // garde un message clair pour le diagnostic.
    return const _MappedError(
        'Restauration refusée par le serveur (super-admin requis). '
        'Si tu es super-admin, contacte le support.',
        permanent: true);
  }
  if (err.contains('product_not_found') || err.contains('P0002')) {
    return const _MappedError(
        'Produit introuvable côté serveur.',
        permanent: true);
  }
  if (err.contains('P0001')) {
    return _MappedError('Restauration refusée : $err', permanent: true);
  }
  return _MappedError('Restauration échouée : $err');
}

// ══════════════════════════════════════════════════════════════════════════
// Modèle de ligne — combine archived_snapshot (priorité) + colonnes
// directes pour rester robuste aux deux situations.
// ══════════════════════════════════════════════════════════════════════════

class _DeletedProductRow {
  final String  id;
  final String  storeId;
  final String? shopName;
  final String  name;
  final String? sku;
  final String? barcode;
  final double  priceSell;
  final double  priceBuy;
  final String? imageUrl;
  final int     variantCount;
  final DateTime? deletedAt;
  final String? deletedBy;
  final String? deleterEmail;
  final String? deleteReason;
  final DateTime? createdAt;
  /// `archived_snapshot` JSON brut (ou null pour les produits legacy).
  /// Sert au bottom sheet « Voir snapshot ».
  final Map<String, dynamic>? archivedSnapshot;

  const _DeletedProductRow({
    required this.id,
    required this.storeId,
    required this.shopName,
    required this.name,
    required this.sku,
    required this.barcode,
    required this.priceSell,
    required this.priceBuy,
    required this.imageUrl,
    required this.variantCount,
    required this.deletedAt,
    required this.deletedBy,
    required this.deleterEmail,
    required this.deleteReason,
    required this.createdAt,
    required this.archivedSnapshot,
  });

  factory _DeletedProductRow.fromMap(Map<String, dynamic> m, {
    String? deleterEmail, String? shopName,
  }) {
    final snap = m['archived_snapshot'] is Map
        ? Map<String, dynamic>.from(m['archived_snapshot'] as Map)
        : <String, dynamic>{};
    String pick(String key) =>
        (snap[key] ?? m[key] ?? '').toString();
    double pickNum(String key) =>
        (snap[key] as num?)?.toDouble()
            ?? (m[key] as num?)?.toDouble() ?? 0;
    final variantsSrc = snap['variants'] is List
        ? snap['variants'] as List
        : (m['variants'] as List? ?? const []);

    return _DeletedProductRow(
      id:           m['id']           as String,
      storeId:      m['store_id']     as String? ?? '',
      shopName:     shopName,
      name:         pick('name'),
      sku:          (snap['sku']     ?? m['sku'])     as String?,
      barcode:      (snap['barcode'] ?? m['barcode']) as String?,
      priceSell:    pickNum('price_sell'),
      priceBuy:     pickNum('price_buy'),
      imageUrl:     (snap['image_url'] ?? m['image_url']) as String?,
      variantCount: variantsSrc.length,
      deletedAt:    DateTime.tryParse(m['deleted_at']?.toString() ?? ''),
      deletedBy:    m['deleted_by']    as String?,
      deleterEmail: deleterEmail,
      deleteReason: m['delete_reason'] as String?,
      createdAt:    DateTime.tryParse(m['created_at']?.toString() ?? ''),
      archivedSnapshot: snap.isEmpty ? null : snap,
    );
  }

  String get displayName => name.isNotEmpty ? name : 'Produit sans nom';
  String get priceLabel  => CurrencyFormatter.format(priceSell);
  String get deleterLabel {
    final e = (deleterEmail ?? '').trim();
    if (e.isNotEmpty) return e;
    final by = (deletedBy ?? '').trim();
    return by.isNotEmpty
        ? by.substring(0, by.length.clamp(0, 8))
        : 'inconnu';
  }
  String get variantLabel => variantCount == 0
      ? 'Sans variante'
      : variantCount == 1
          ? '1 variante'
          : '$variantCount variantes';
}

// ══════════════════════════════════════════════════════════════════════════
// Card individuelle.
// ══════════════════════════════════════════════════════════════════════════

class _DeletedProductCard extends StatelessWidget {
  final _DeletedProductRow row;
  final VoidCallback onRestore;
  final VoidCallback onShowSnapshot;
  const _DeletedProductCard({
    required this.row,
    required this.onRestore,
    required this.onShowSnapshot,
  });

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd/MM/yyyy HH:mm');
    final deletedLabel = row.deletedAt != null
        ? df.format(row.deletedAt!.toLocal())
        : '—';
    final createdLabel = row.createdAt != null
        ? df.format(row.createdAt!.toLocal())
        : '—';
    final imageUrl = row.imageUrl;
    final hasSnapshot = row.archivedSnapshot != null;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header : image + nom + chip snapshot ────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48, height: 48,
                  child: imageUrl != null && imageUrl.isNotEmpty
                      ? Image.network(imageUrl, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const _PlaceholderImg())
                      : const _PlaceholderImg(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.displayName,
                        style: AppTextStyles.bodyBold,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      'SKU ${row.sku ?? "—"} · '
                      '${row.priceLabel} · ${row.variantLabel}',
                      style: AppTextStyles.caption,
                    ),
                  ],
                ),
              ),
              if (hasSnapshot)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('snapshot',
                      style: AppTextStyles.micro.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          const SizedBox(height: 10),

          // ── Métadonnées suppression ────────────────────────────────────
          _MetaRow(label: 'Motif',
              value: (row.deleteReason ?? '').isNotEmpty
                  ? row.deleteReason!
                  : '—'),
          _MetaRow(label: 'Supprimé le',  value: deletedLabel),
          _MetaRow(label: 'Supprimé par', value: row.deleterLabel),
          _MetaRow(label: 'Créé le',      value: createdLabel),
          if ((row.shopName ?? '').isNotEmpty)
            _MetaRow(label: 'Boutique', value: row.shopName!),

          const SizedBox(height: 12),

          // ── Actions ───────────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (hasSnapshot) ...[
                OutlinedButton.icon(
                  onPressed: onShowSnapshot,
                  icon:  const Icon(Icons.code_rounded, size: 16),
                  label: const Text('Voir snapshot'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(
                        color: AppColors.primary.withValues(alpha: 0.4)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              ElevatedButton.icon(
                onPressed: onRestore,
                icon:  const Icon(Icons.restore_rounded, size: 18),
                label: const Text('Restaurer'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.secondary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlaceholderImg extends StatelessWidget {
  const _PlaceholderImg();
  @override
  Widget build(BuildContext context) => Container(
        color: Theme.of(context).semantic.borderSubtle,
        child: Icon(Icons.image_outlined,
            color: AppColors.textHint, size: 20),
      );
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;
  const _MetaRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: AppTextStyles.caption),
          ),
          Expanded(
            child: Text(value,
                style: AppTextStyles.bodySm,
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Bottom sheet : affiche le snapshot JSON formaté avec bouton Copier.
// ══════════════════════════════════════════════════════════════════════════

class _SnapshotSheet extends StatelessWidget {
  final String title;
  final Map<String, dynamic> snapshot;
  const _SnapshotSheet({required this.title, required this.snapshot});

  String _prettyJson() {
    try {
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(snapshot);
    } catch (_) {
      return snapshot.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pretty = _prettyJson();
    final size = MediaQuery.of(context).size;
    return Container(
      constraints: BoxConstraints(maxHeight: size.height * 0.85),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Poignée ────────────────────────────────────────────────────
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 36, height: 4,
            decoration: BoxDecoration(
                color: AppColors.primarySurface,
                borderRadius: BorderRadius.circular(2)),
          ),

          // ── Header ────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 12, 8),
            child: Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(8)),
                child: Icon(Icons.code_rounded,
                    size: 18, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Snapshot archivé',
                        style: AppTextStyles.subtitleBold),
                    Text(title,
                        style: AppTextStyles.caption,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Copier le JSON',
                icon: Icon(Icons.copy_rounded,
                    color: AppColors.textSecondary),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: pretty));
                  if (!context.mounted) return;
                  AppSnack.success(context, 'Snapshot copié.');
                },
              ),
              IconButton(
                tooltip: 'Fermer',
                icon: Icon(Icons.close_rounded,
                    color: AppColors.textSecondary),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
          ),
          const Divider(height: 1),

          // ── Corps JSON ────────────────────────────────────────────────
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                pretty,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.45,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
