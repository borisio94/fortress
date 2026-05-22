import 'package:flutter/material.dart';
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

/// Écran super-admin (hotfix_084) — liste des commandes soft-deleted et
/// permet de les restaurer.
///
/// Lecture
/// ───────
/// Lecture DIRECTE Supabase (pas Hive). La RLS `orders_select_deleted_sa`
/// accorde le SELECT au super-admin uniquement → la lecture renverra 0
/// lignes pour tout autre utilisateur.
///
/// Pagination
/// ──────────
/// 20 lignes par page (`_pageSize`), tri `deleted_at DESC`. Scroll
/// infini : on charge la page suivante quand l'utilisateur arrive à 80%
/// du bas. La pagination utilise `.range(offset, offset + size - 1)` —
/// l'écran super-admin peut donc gérer des milliers d'éléments.
///
/// Restauration
/// ────────────
/// Bouton « Restaurer » par ligne → `AppDatabase.bgRestoreSale` →
/// RPC SQL `restore_sale`. Retry automatique 1× sur erreur réseau
/// (les erreurs métier P0001/42501 ne sont jamais retry-ées). La RPC
/// SQL trace elle-même un `activity_log` `sale_restored` — pas de log
/// client (évite le doublon).
///
/// Variante embeddable
/// ───────────────────
/// [DeletedOrdersBody] expose le contenu sans Scaffold/AppBar, utilisé
/// par le hub à onglets `super_admin_deleted_hub_page`.
class DeletedOrdersPage extends ConsumerWidget {
  const DeletedOrdersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSuperAdmin = ref.watch(currentPlanProvider).isSuperAdmin;
    if (!isSuperAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Commandes supprimées')),
        body: const EmptyStateWidget(
          icon:  Icons.lock_outline_rounded,
          title: 'Réservé au super-admin',
          subtitle: 'Cette page liste les commandes supprimées de toutes '
              'les boutiques. Seul le super-admin Fortress y a accès.',
        ),
      );
    }
    return const _OrdersScaffold();
  }
}

class _OrdersScaffold extends StatefulWidget {
  const _OrdersScaffold();
  @override
  State<_OrdersScaffold> createState() => _OrdersScaffoldState();
}

class _OrdersScaffoldState extends State<_OrdersScaffold> {
  final GlobalKey<DeletedOrdersBodyState> _bodyKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Commandes supprimées'),
        actions: [
          IconButton(
            tooltip: 'Rafraîchir',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _bodyKey.currentState?.refresh(),
          ),
        ],
      ),
      body: DeletedOrdersBody(key: _bodyKey),
    );
  }
}

/// Corps de la page — utilisable seul (sous une AppBar custom) ou
/// embarqué dans le hub à onglets. Expose `refresh()` via la state key
/// pour permettre au caller de déclencher un rafraîchissement.
class DeletedOrdersBody extends ConsumerStatefulWidget {
  const DeletedOrdersBody({super.key});
  @override
  ConsumerState<DeletedOrdersBody> createState() => DeletedOrdersBodyState();
}

class DeletedOrdersBodyState extends ConsumerState<DeletedOrdersBody> {
  static const int _pageSize = 20;

  final List<_DeletedRow> _rows = [];
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

  Future<List<_DeletedRow>> _fetch({required int offset}) async {
    final db = Supabase.instance.client;
    // La table `orders` ne stocke PAS de colonne `total` — il est calculé
    // côté client à partir d'items + discount + tax. On lit les composants
    // et on les recompose dans `_DeletedRow.fromMap`.
    final raw = await db.from('orders')
        .select('id, shop_id, client_name, client_phone, '
                'discount_amount, tax_rate, amount_paid, status, items, '
                'deleted_at, deleted_by, delete_reason, created_at')
        .not('deleted_at', 'is', null)
        .order('deleted_at', ascending: false)
        .range(offset, offset + _pageSize - 1);
    final rows = List<Map<String, dynamic>>.from(raw as List);

    // Jointures légères : emails des auteurs + noms boutiques. Tolérantes :
    // si elles échouent, on continue avec l'identifiant brut.
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
    final shopIds = rows.map((r) => r['shop_id'] as String?)
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
    return rows.map((r) => _DeletedRow.fromMap(r,
        deleterEmail: emails[r['deleted_by'] as String? ?? ''],
        shopName:     shopNames[r['shop_id']    as String? ?? ''],
    )).toList();
  }

  Future<void> _restore(_DeletedRow row) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
        title: const Text('Restaurer la commande',
            style: AppTextStyles.subtitleBold),
        content: Text(
            'La commande de ${row.clientLabel} (${row.totalLabel}) '
            'redeviendra visible et éditable par les membres de la '
            'boutique.\n\n'
            'Le stock sera ré-décrémenté automatiquement à la prochaine '
            'transition de la commande vers le statut « complétée ».\n\n'
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

    // Retry automatique 1× sur erreur réseau (les erreurs métier
    // P0001/42501 sont propagées immédiatement et NE doivent JAMAIS
    // être retry-ées — ré-exécuter la RPC avec la même charge donnera
    // la même réponse).
    final result = await _restoreWithRetry(orderId: row.id, userId: userId);
    if (!mounted) return;
    if (result.success) {
      AppSnack.success(context, 'Commande ${row.shortRef} restaurée.');
      await refresh();
    } else {
      AppSnack.error(context, result.message);
    }
  }

  Future<_RestoreOutcome> _restoreWithRetry({
    required String orderId,
    required String userId,
  }) async {
    try {
      await AppDatabase.bgRestoreSale(orderId: orderId, userId: userId);
      return const _RestoreOutcome(success: true);
    } catch (e) {
      final mapped = _mapRestoreSaleError(e);
      if (mapped.permanent) return _RestoreOutcome(message: mapped.message);
      // Une seule tentative supplémentaire — pas plus, pour éviter de
      // marteler une RPC qui souffre déjà.
      try {
        await AppDatabase.bgRestoreSale(orderId: orderId, userId: userId);
        return const _RestoreOutcome(success: true);
      } catch (e2) {
        final mapped2 = _mapRestoreSaleError(e2);
        return _RestoreOutcome(message: mapped2.message);
      }
    }
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
              icon:     Icons.delete_outline_rounded,
              title:    'Aucune commande supprimée',
              subtitle: 'Quand un opérateur supprime une commande '
                  'éligible, elle apparaît ici pour audit ou '
                  'restauration.',
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
          return _DeletedOrderCard(
            row: _rows[i],
            onRestore: () => _restore(_rows[i]),
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

/// Mappe les exceptions remontées par `bgRestoreSale` vers un message FR
/// affichable. Les codes serveur connus deviennent des libellés explicites
/// et permanents (non retry-ables) ; le reste tombe dans le générique
/// "erreur réseau" qui sera retry-é une fois.
_MappedError _mapRestoreSaleError(Object e) {
  final err = e.toString();
  // Erreurs métier serveur (PL/pgSQL RAISE) — pas la peine de retry.
  if (err.contains('suppression_statut_invalide')) {
    return const _MappedError(
        'Impossible de restaurer : le statut de la commande n\'est plus '
        'compatible avec une restauration.',
        permanent: true);
  }
  if (err.contains('permission_insuffisante') || err.contains('42501')) {
    return const _MappedError(
        'Restauration refusée par le serveur (super-admin requis).',
        permanent: true);
  }
  if (err.contains('sale_not_found') || err.contains('P0002')) {
    return const _MappedError(
        'Commande introuvable côté serveur.',
        permanent: true);
  }
  if (err.contains('P0001')) {
    // Autre RAISE PL/pgSQL non-modélisé — on affiche brut mais permanent.
    return _MappedError('Restauration refusée : $err', permanent: true);
  }
  // Erreur réseau / 5xx → retry une fois.
  return _MappedError('Restauration échouée : $err');
}

// ══════════════════════════════════════════════════════════════════════════
// Modèle de ligne — projection des colonnes utiles à l'affichage.
// ══════════════════════════════════════════════════════════════════════════

class _DeletedRow {
  final String id;
  final String shopId;
  final String? shopName;
  final String? clientName;
  final String? clientPhone;
  final double  total;
  final double  amountPaid;
  final String  status;
  final int     itemCount;
  final DateTime? deletedAt;
  final String? deletedBy;
  final String? deleterEmail;
  final String? deleteReason;
  final DateTime? createdAt;

  const _DeletedRow({
    required this.id,
    required this.shopId,
    required this.shopName,
    required this.clientName,
    required this.clientPhone,
    required this.total,
    required this.amountPaid,
    required this.status,
    required this.itemCount,
    required this.deletedAt,
    required this.deletedBy,
    required this.deleterEmail,
    required this.deleteReason,
    required this.createdAt,
  });

  factory _DeletedRow.fromMap(Map<String, dynamic> m, {
    String? deleterEmail, String? shopName,
  }) {
    final items = (m['items'] as List?) ?? const [];
    int itemCount = 0;
    double subtotal = 0;
    for (final it in items) {
      try {
        final mm   = Map<String, dynamic>.from(it as Map);
        final qty  = (mm['quantity'] as num?)?.toInt() ?? 0;
        final price = (mm['custom_price'] as num?)?.toDouble()
            ?? (mm['unit_price'] as num?)?.toDouble() ?? 0;
        itemCount += qty;
        subtotal  += qty * price;
      } catch (_) {}
    }
    final discount = (m['discount_amount'] as num?)?.toDouble() ?? 0;
    final taxRate  = (m['tax_rate']        as num?)?.toDouble() ?? 0;
    final taxable  = (subtotal - discount).clamp(0, double.infinity);
    final tax      = taxable * (taxRate / 100);
    final total    = subtotal - discount + tax;
    return _DeletedRow(
      id:           m['id']           as String,
      shopId:       m['shop_id']      as String? ?? '',
      shopName:     shopName,
      clientName:   m['client_name']  as String?,
      clientPhone:  m['client_phone'] as String?,
      total:        total,
      amountPaid:   (m['amount_paid'] as num?)?.toDouble() ?? 0,
      status:       m['status']       as String? ?? 'scheduled',
      itemCount:    itemCount,
      deletedAt:    DateTime.tryParse(m['deleted_at']?.toString() ?? ''),
      deletedBy:    m['deleted_by']    as String?,
      deleterEmail: deleterEmail,
      deleteReason: m['delete_reason'] as String?,
      createdAt:    DateTime.tryParse(m['created_at']?.toString() ?? ''),
    );
  }

  String get clientLabel =>
      (clientName ?? '').isNotEmpty ? clientName! : 'Client non précisé';
  String get totalLabel  => CurrencyFormatter.format(total);
  String get shortRef    => id.length >= 6
      ? id.substring(id.length - 6)
      : id;
  String get deleterLabel {
    final e = (deleterEmail ?? '').trim();
    if (e.isNotEmpty) return e;
    final by = (deletedBy ?? '').trim();
    return by.isNotEmpty
        ? by.substring(0, by.length.clamp(0, 8))
        : 'inconnu';
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Card individuelle.
// ══════════════════════════════════════════════════════════════════════════

class _DeletedOrderCard extends StatelessWidget {
  final _DeletedRow row;
  final VoidCallback onRestore;
  const _DeletedOrderCard({required this.row, required this.onRestore});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd/MM/yyyy HH:mm');
    final deletedLabel = row.deletedAt != null
        ? df.format(row.deletedAt!.toLocal())
        : '—';
    final createdLabel = row.createdAt != null
        ? df.format(row.createdAt!.toLocal())
        : '—';
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
          // ── Header ────────────────────────────────────────────────────
          Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.delete_outline_rounded,
                  color: AppColors.error, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.clientLabel,
                      style: AppTextStyles.bodyBold,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    '${row.itemCount} article'
                        '${row.itemCount > 1 ? "s" : ""} · '
                        '${row.totalLabel} · ${row.status}',
                    style: AppTextStyles.caption,
                  ),
                ],
              ),
            ),
            Text('#${row.shortRef}', style: AppTextStyles.captionBold),
          ]),
          const SizedBox(height: 10),

          // ── Métadonnées suppression ────────────────────────────────────
          _MetaRow(label: 'Motif',
              value: (row.deleteReason ?? '').isNotEmpty
                  ? row.deleteReason!
                  : '—'),
          _MetaRow(label: 'Supprimée le',  value: deletedLabel),
          _MetaRow(label: 'Supprimée par', value: row.deleterLabel),
          _MetaRow(label: 'Créée le',      value: createdLabel),
          if ((row.shopName ?? '').isNotEmpty)
            _MetaRow(label: 'Boutique', value: row.shopName!),

          const SizedBox(height: 12),

          // ── Action restaurer ───────────────────────────────────────────
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
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
          ),
        ],
      ),
    );
  }
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
