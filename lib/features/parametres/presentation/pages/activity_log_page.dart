import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../features/dashboard/data/dashboard_providers.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';

// ═════════════════════════════════════════════════════════════════════════════
// PAGE HISTORIQUE — liste des actions auditées sur la boutique courante.
// Source : Hive (offline-first) alimenté par AppDatabase.syncActivityLogs +
// realtime via subscribeToShop. La liste se met à jour automatiquement dès
// qu'un log est créé côté Supabase (depuis un autre appareil ou le même).
//
// Format d'affichage :
// - Titre court (ex: "Produit créé : Coca 33cl")
// - Sous-ligne discrète composée à partir de `details` JSONB (ex: "SKU
//   COCA-33 · Boissons · 500 XAF · stock 50")
// ═════════════════════════════════════════════════════════════════════════════

// ─── Helper : résolution du filtre dashboard en location_ids ───────────────
//
// `dashViewFilterProvider` peut valoir :
//   * null         → vue Globale, pas de filtre.
//   * '_base'      → boutique seule, on prend la `StockLocation type='shop'`
//                    rattachée à `shopId`.
//   * <location_id> → un partenaire spécifique.
List<String>? _resolveLocationIds(String? viewFilter, String shopId) {
  if (viewFilter == null) return null;
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

class ActivityLogPage extends ConsumerStatefulWidget {
  final String shopId;
  const ActivityLogPage({super.key, required this.shopId});
  @override
  ConsumerState<ActivityLogPage> createState() => _ActivityLogPageState();
}

class _ActivityLogPageState extends ConsumerState<ActivityLogPage> {
  List<_LogEntry> _logs = [];
  bool   _syncing    = false;
  String _filter     = 'all';
  /// Filtre par utilisateur (uniquement visible pour admin/owner).
  /// `null` = tous les utilisateurs. Pour un vendeur (`!isShopAdmin`), ce
  /// champ est forcé à son propre `user_id` côté `_filtered`.
  String? _userFilter;

  @override
  void initState() {
    super.initState();
    _readFromHive();
    _syncInBackground();
    AppDatabase.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged(String table, String shopId) {
    if (!mounted) return;
    if (table != 'activity_logs') return;
    if (shopId != widget.shopId && shopId != '_all') return;
    _readFromHive();
  }

  void _readFromHive() {
    final rows = AppDatabase.getActivityLogsForShop(widget.shopId);
    final logs = rows.map(_LogEntry.fromMap).toList();
    if (!mounted) return;
    setState(() => _logs = logs);
  }

  Future<void> _syncInBackground() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    await AppDatabase.syncActivityLogs(widget.shopId);
    if (!mounted) return;
    setState(() => _syncing = false);
    _readFromHive();
  }

  /// Liste des `(user_id, name)` distincts présents dans les logs courants —
  /// alimente le dropdown du filtre utilisateur. Construit à la volée pour
  /// éviter une jointure à `shop_memberships` (qui ajouterait un sync).
  List<({String id, String name})> get _actors {
    final seen = <String, String>{};
    for (final log in _logs) {
      final id = log.actorId;
      if (id == null || id.isEmpty) continue;
      seen.putIfAbsent(id, () => log.actorName);
    }
    final out = seen.entries
        .map((e) => (id: e.key, name: e.value))
        .toList();
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// Logs filtrés selon : (1) règle hiérarchique, (2) catégorie,
  /// (3) utilisateur sélectionné, (4) vue location (Globale / boutique
  /// seule / partenaire).
  List<_LogEntry> _filteredFor(String? selfFilterId, List<String>? locIds) {
    Iterable<_LogEntry> out = _logs;
    // (1) Règle hiérarchique : un vendeur ne voit que ses propres actions.
    if (selfFilterId != null) {
      out = out.where((l) => l.actorId == selfFilterId);
    } else if (_userFilter != null && _userFilter!.isNotEmpty) {
      // (3) Filtre utilisateur explicite (admin/owner).
      out = out.where((l) => l.actorId == _userFilter);
    }
    // (2) Catégorie.
    if (_filter != 'all') {
      out = out.where((l) => l.category == _filter);
    }
    // (4) Vue location — uniquement si filtre actif (sinon tout passe).
    if (locIds != null && locIds.isNotEmpty) {
      out = out.where((l) => l.matchesLocations(locIds));
    }
    return out.toList();
  }

  @override
  Widget build(BuildContext context) {
    final l     = context.l10n;
    final perms = ref.watch(permissionsProvider(widget.shopId));
    final myUid = LocalStorageService.getCurrentUser()?.id;
    // Vendeur (rôle `user`) : ne voit que ses propres actions, sans
    // possibilité de filtrer par autre utilisateur. Admin/owner voient
    // tout, peuvent affiner via le dropdown.
    final isPrivileged = perms.isShopAdmin || perms.isOwner;
    final selfFilterId = isPrivileged ? null : myUid;
    // Filtre location issu du dashboard (Globale / boutique seule /
    // partenaire) — appliqué en sus des filtres existants.
    final viewFilter = ref.watch(dashViewFilterProvider);
    final locIds     = _resolveLocationIds(viewFilter, widget.shopId);
    return Column(children: [
      _FilterBar(
        selected: _filter,
        onChange: (v) => setState(() => _filter = v),
      ),
      if (isPrivileged && _actors.length > 1)
        _UserFilterDropdown(
          selected: _userFilter,
          actors:   _actors,
          onChange: (v) => setState(() => _userFilter = v),
        ),
      Expanded(child: _body(l, _filteredFor(selfFilterId, locIds),
          canManage: isPrivileged)),
    ]);
  }

  Widget _body(AppLocalizations l, List<_LogEntry> list,
      {required bool canManage}) {
    if (list.isEmpty) {
      return RefreshIndicator(
        onRefresh: _syncInBackground,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 80),
            const Icon(Icons.history_toggle_off_rounded, size: 40,
                color: Color(0xFFD1D5DB)),
            const SizedBox(height: 12),
            Text(l.historiqueEmpty,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySecondary),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _syncInBackground,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (_, i) => _LogTile(
          entry: list[i],
          // Archive/delete réservé super-admin et propriétaire de la
          // boutique (cf. RPC `_can_manage_activity_logs` côté serveur
          // qui vérifie côté serveur — la règle UI ici est juste pour
          // ne pas afficher un bouton qui throw côté serveur).
          canManage: canManage,
          onArchive: canManage ? () => _confirmArchive(list[i]) : null,
          onDelete:  canManage ? () => _confirmDelete(list[i])  : null,
        ),
      ),
    );
  }

  Future<void> _confirmArchive(_LogEntry e) async {
    final id = e.id;
    if (id == null || id.isEmpty) {
      AppSnack.error(context, 'Log sans id, impossible à archiver');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Archiver ce log ?'),
        content: Text('"${e.message}" sera marqué archivé. '
            'Action tracée dans l\'audit.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Archiver')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final n = await ActivityLogService.archiveLogs([id],
          reason: 'Archivé manuellement depuis Historique');
      if (mounted) AppSnack.success(context, '$n log(s) archivé(s)');
      await _syncInBackground();
    } catch (err) {
      if (mounted) AppSnack.error(context,
          'Archivage refusé : ${err.toString()}');
    }
  }

  Future<void> _confirmDelete(_LogEntry e) async {
    final id = e.id;
    if (id == null || id.isEmpty) {
      AppSnack.error(context, 'Log sans id, impossible à supprimer');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce log ?'),
        content: Text('"${e.message}" sera supprimé définitivement. '
            'Action tracée dans l\'audit. Préférez l\'archivage si '
            'possible.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final n = await ActivityLogService.deleteLogs([id],
          reason: 'Suppression manuelle depuis Historique');
      if (mounted) AppSnack.success(context, '$n log(s) supprimé(s)');
      await _syncInBackground();
    } catch (err) {
      if (mounted) AppSnack.error(context,
          'Suppression refusée : ${err.toString()}');
    }
  }
}

// ─── Barre de filtres ───────────────────────────────────────────────────────

class _FilterBar extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChange;
  const _FilterBar({required this.selected, required this.onChange});

  static const _filters = [
    ('all',     'Tous',        Icons.all_inclusive_rounded),
    ('sale',    'Ventes',      Icons.point_of_sale_rounded),
    ('shop',    'Produits',    Icons.inventory_2_rounded),
    ('stock',   'Stock',       Icons.swap_horiz_rounded),
    ('account', 'Comptes',     Icons.person_rounded),
    ('alert',   'Alertes',     Icons.warning_rounded),
    ('auth',    'Connexions',  Icons.login_rounded),
  ];

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 40,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      itemCount: _filters.length,
      separatorBuilder: (_, __) => const SizedBox(width: 6),
      itemBuilder: (_, i) {
        final f = _filters[i];
        final active = f.$1 == selected;
        return InkWell(
          onTap: () => onChange(f.$1),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: active ? AppColors.primary : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: active
                  ? AppColors.primary
                  : Theme.of(context).semantic.borderSubtle),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(f.$3, size: 13,
                  color: active ? Colors.white : AppColors.textSecondary),
              const SizedBox(width: 5),
              Text(f.$2,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.captionBold.copyWith(
                      color: active ? Colors.white : AppColors.textSecondary)),
            ]),
          ),
        );
      },
    ),
  );
}

// ─── Dropdown filtre utilisateur (admin/owner uniquement) ──────────────────

class _UserFilterDropdown extends StatelessWidget {
  final String? selected;
  final List<({String id, String name})> actors;
  final ValueChanged<String?> onChange;
  const _UserFilterDropdown({
    required this.selected,
    required this.actors,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(children: [
        const Icon(Icons.person_outline_rounded, size: 14,
            color: AppColors.textHint),
        const SizedBox(width: 6),
        const Text('Utilisateur :',
            style: AppTextStyles.captionBold),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              value: selected,
              isDense: true,
              isExpanded: true,
              icon: const Icon(Icons.expand_more_rounded, size: 16),
              style: AppTextStyles.bodySmBold,
              items: [
                const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Tous',
                        overflow: TextOverflow.ellipsis)),
                for (final a in actors)
                  DropdownMenuItem<String?>(
                      value: a.id,
                      child: Text(a.name,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1)),
              ],
              onChanged: onChange,
            ),
          ),
        ),
      ]),
    );
  }
}

// ─── Tuile log ──────────────────────────────────────────────────────────────

class _LogTile extends StatelessWidget {
  final _LogEntry entry;
  /// Si true, affiche un menu trailing avec Archive/Supprimer (réservé
  /// super-admin + propriétaire de la boutique du log — la règle est
  /// re-vérifiée côté serveur dans le RPC).
  final bool canManage;
  final VoidCallback? onArchive;
  final VoidCallback? onDelete;
  const _LogTile({
    required this.entry,
    this.canManage = false,
    this.onArchive,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final date = entry.date;
    final dateLabel = date != null ? _fmtDate(date) : '—';
    final hasSubtitle = (entry.subtitle ?? '').isNotEmpty;
    final isMobile  = MediaQuery.of(context).size.width < 600;
    // Spec round 9 prompt 3 (mobile only) : icône 26px cercle
    // primarySurface (vs 30 + tinted color), titre 11px ellipsis (vs
    // 12.5), meta 9px muted (vs 10.5), heure 9px tertiary. Sur desktop
    // on garde les valeurs précédentes.
    final iconBox  = isMobile ? 26.0 : 30.0;
    final iconSize = isMobile ? 14.0 : 15.0;
    final iconBg   = isMobile
        ? AppColors.primarySurface
        : entry.color.withValues(alpha:0.1);
    final iconFg   = isMobile ? AppColors.primary : entry.color;
    final titleFs  = isMobile ? 11.0 : 12.5;
    final metaFs   = isMobile ? 9.0  : 10.5;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12,
          vertical: isMobile ? 8 : 10),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Theme.of(context).semantic.borderSubtle, width: 0.5)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            width: iconBox, height: iconBox,
            decoration: BoxDecoration(color: iconBg,
                shape: isMobile ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: isMobile ? null : BorderRadius.circular(8)),
            child: Icon(entry.icon, size: iconSize, color: iconFg)),
        const SizedBox(width: 10),
        // Zone info (Flexible) — heure et meta sur la même ligne, heure
        // poussée à droite via Spacer pour respecter flex-shrink:0.
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text(entry.message,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySm.copyWith(
                  fontSize: titleFs,
                  fontWeight: isMobile ? FontWeight.w500 : FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface)),
          if (hasSubtitle) ...[
            const SizedBox(height: 2),
            Text(entry.subtitle!,
                maxLines: isMobile ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.micro.copyWith(fontSize: metaFs,
                    color: AppColors.textSecondary, height: 1.3)),
          ],
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.person_outline_rounded, size: 11,
                color: AppColors.textHint),
            const SizedBox(width: 3),
            // Flexible sur l'acteur — la heure prend sa place fixe à droite.
            Flexible(child: Text(entry.actorName,
                overflow: TextOverflow.ellipsis, maxLines: 1,
                style: AppTextStyles.micro.copyWith(fontSize: metaFs))),
            const SizedBox(width: 8),
            Icon(Icons.access_time_rounded, size: 11,
                color: AppColors.textHint),
            const SizedBox(width: 3),
            Text(dateLabel,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.micro.copyWith(fontSize: metaFs)),
          ]),
        ])),
        if (canManage && (onArchive != null || onDelete != null))
          PopupMenuButton<String>(
            tooltip: 'Actions',
            padding: EdgeInsets.zero,
            iconSize: 18,
            icon: Icon(Icons.more_vert_rounded,
                size: 18, color: AppColors.textSecondary),
            itemBuilder: (_) => [
              if (onArchive != null)
                const PopupMenuItem(
                    value: 'archive',
                    child: Row(children: [
                      Icon(Icons.archive_outlined, size: 16),
                      SizedBox(width: 8),
                      Text('Archiver', style: AppTextStyles.bodySm),
                    ])),
              if (onDelete != null)
                PopupMenuItem(
                    value: 'delete',
                    child: Row(children: [
                      Icon(Icons.delete_outline_rounded,
                          size: 16, color: AppColors.error),
                      const SizedBox(width: 8),
                      Text('Supprimer',
                          style: AppTextStyles.bodySm.copyWith(
                              color: AppColors.error)),
                    ])),
            ],
            onSelected: (v) {
              if (v == 'archive') onArchive?.call();
              if (v == 'delete')  onDelete?.call();
            },
          ),
      ]),
    );
  }

  String _fmtDate(DateTime d) {
    final local = d.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year.toString().substring(2)} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

// ─── Modèle + mapping ───────────────────────────────────────────────────────

class _LogEntry {
  /// `id` brut du log — requis pour appeler les RPCs archive/delete.
  final String?  id;
  final String   action;
  final String   category;
  final String   message;     // titre (1 ligne)
  final String?  subtitle;    // sous-ligne discrète (composée depuis details)
  /// `actor_id` Supabase — utilisé pour le filtre hiérarchique (un vendeur
  /// ne voit que ses propres logs).
  final String?  actorId;
  final String   actorName;
  final IconData icon;
  final Color    color;
  final String?  targetLabel;
  /// `target_id` brut — utile pour filtrer par location (cas où
  /// `target_type='stock_location'` ou `'shop'`).
  final String?  targetId;
  /// `details` JSONB brut — scanné pour matcher les ids de location
  /// embarqués (origin_location_id, to_location_id, etc.).
  final Map<String, dynamic>? details;
  final DateTime? date;

  const _LogEntry({
    required this.action,
    required this.category,
    required this.message,
    required this.actorName,
    required this.icon,
    required this.color,
    this.id,
    this.actorId,
    this.subtitle,
    this.targetLabel,
    this.targetId,
    this.details,
    this.date,
  });

  factory _LogEntry.fromRow(Map<String, dynamic> r,
      {required String actorName, String? actorId}) {
    final action      = r['action']       as String? ?? 'unknown';
    final targetLabel = r['target_label'] as String?;
    final targetId    = r['target_id']?.toString();
    final rawDate     = r['created_at']   as String?;
    final date        = rawDate != null ? DateTime.tryParse(rawDate) : null;
    final details     = _parseDetails(r['details']);
    final meta        = _metaFor(action);
    return _LogEntry(
      id:          r['id']?.toString(),
      action:      action,
      category:    meta.category,
      icon:        meta.icon,
      color:       meta.color,
      actorId:     actorId,
      actorName:   actorName,
      targetLabel: targetLabel,
      targetId:    targetId,
      details:     details,
      date:        date,
      message:     _titleFor(action, targetLabel),
      subtitle:    _subtitleFor(action, details),
    );
  }

  /// Construit depuis une map Hive. Préfère `_actor_name` (résolu au sync),
  /// fallback sur `actor_email`, puis '—'.
  factory _LogEntry.fromMap(Map<String, dynamic> m) {
    final actor = (m['_actor_name'] as String?)
        ?? (m['actor_email'] as String?)
        ?? '—';
    final actorId = m['actor_id']?.toString();
    return _LogEntry.fromRow(m, actorName: actor, actorId: actorId);
  }

  /// `true` si ce log est pertinent pour au moins une des [locIds] —
  /// match sur `targetId` ou sur n'importe quelle valeur scalaire
  /// dans `details` (origin_location_id, to_location_id, etc.). Si
  /// [locIds] est null/vide → pas de filtre, accepte tout.
  bool matchesLocations(List<String>? locIds) {
    if (locIds == null || locIds.isEmpty) return true;
    if (targetId != null && locIds.contains(targetId)) return true;
    final d = details;
    if (d != null) {
      for (final v in d.values) {
        if (v is String && locIds.contains(v)) return true;
      }
    }
    return false;
  }
}

class _LogMeta {
  final String   category;
  final IconData icon;
  final Color    color;
  const _LogMeta(this.category, this.icon, this.color);
}

/// Désérialise `details` qui peut arriver soit comme `Map` (JSONB Supabase
/// déjà parsé) soit comme `String` (si stocké brut en JSON dans Hive).
Map<String, dynamic>? _parseDetails(dynamic raw) {
  if (raw == null) return null;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String && raw.isNotEmpty) {
    try {
      final v = jsonDecode(raw);
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {}
  }
  return null;
}

_LogMeta _metaFor(String action) {
  switch (action) {
    // Auth
    case 'user_login':
      return const _LogMeta('auth', Icons.login_rounded, AppColors.secondary);
    case 'super_admin_password_reset':
      return const _LogMeta('auth', Icons.password_rounded, AppColors.warning);

    // Boutique
    case 'shop_created':
      return _LogMeta('shop', Icons.storefront_rounded, AppColors.primary);
    case 'shop_updated':
      return _LogMeta('shop', Icons.edit_outlined, AppColors.primary);
    case 'shop_deleted':
      return const _LogMeta('alert', Icons.storefront_outlined, AppColors.error);
    case 'shop_reset':
      return const _LogMeta('alert', Icons.cleaning_services_rounded, AppColors.warning);
    case 'shop_reset_keep_products':
      return const _LogMeta('alert', Icons.refresh_rounded, AppColors.warning);

    // Produits
    case 'product_created':
      return _LogMeta('shop', Icons.add_box_outlined, AppColors.primary);
    case 'product_updated':
      return _LogMeta('shop', Icons.edit_outlined, AppColors.primary);
    case 'product_deleted':
      return const _LogMeta('shop', Icons.delete_outline_rounded, AppColors.warning);
    case 'product_archived':
      return const _LogMeta('shop', Icons.archive_outlined, AppColors.warning);
    case 'product_auto_merged':
      return _LogMeta('shop', Icons.auto_awesome_rounded, AppColors.primary);
    case 'product_copied_out':
      return _LogMeta('shop', Icons.content_copy_rounded, AppColors.primary);
    case 'product_copied_in':
      return _LogMeta('shop', Icons.content_paste_rounded, AppColors.primary);
    case 'stock_updated':
      return _LogMeta('shop', Icons.inventory_2_rounded, AppColors.primary);

    // Variantes
    case 'variant_created':
      return _LogMeta('shop', Icons.add_circle_outline_rounded, AppColors.primary);
    case 'variant_updated':
      return _LogMeta('shop', Icons.tune_rounded, AppColors.primary);
    case 'variant_deleted':
      return const _LogMeta('shop', Icons.remove_circle_outline_rounded, AppColors.warning);

    // Stock (mouvements)
    case 'stock_transfer':
    case 'stock_transfer_out':
      return _LogMeta('stock', Icons.call_made_rounded, AppColors.primary);
    case 'stock_transfer_in':
      return _LogMeta('stock', Icons.call_received_rounded, AppColors.primary);
    case 'stock_arrival':
      return const _LogMeta('stock', Icons.input_rounded, AppColors.secondary);
    case 'stock_incident':
      return const _LogMeta('alert', Icons.report_problem_outlined, AppColors.error);
    case 'stock_return_supplier':
      return const _LogMeta('stock', Icons.assignment_return_outlined, AppColors.warning);
    case 'stock_return_client':
      return const _LogMeta('stock', Icons.assignment_returned_outlined, AppColors.warning);
    case 'stock_adjustment':
      return _LogMeta('stock', Icons.tune_rounded, AppColors.primary);

    // Métadonnées (catégorie / marque / unité)
    case 'category_created':
    case 'category_updated':
    case 'category_deleted':
      return _LogMeta('shop', Icons.category_outlined, AppColors.primary);
    case 'brand_created':
    case 'brand_updated':
    case 'brand_deleted':
      return _LogMeta('shop', Icons.bookmark_outline_rounded, AppColors.primary);
    case 'unit_created':
    case 'unit_updated':
    case 'unit_deleted':
      return _LogMeta('shop', Icons.straighten_rounded, AppColors.primary);

    // Fournisseurs / réceptions / bons de commande
    case 'supplier_created':
    case 'supplier_updated':
    case 'supplier_deleted':
      return _LogMeta('shop', Icons.local_shipping_outlined, AppColors.primary);
    case 'reception_validated':
      return const _LogMeta('stock', Icons.move_to_inbox_rounded, AppColors.secondary);
    case 'purchase_order_created':
    case 'purchase_order_updated':
    case 'purchase_order_deleted':
      return _LogMeta('shop', Icons.receipt_long_outlined, AppColors.primary);

    // Ventes
    case 'sale_completed':
      return const _LogMeta('sale', Icons.point_of_sale_rounded, AppColors.secondary);
    case 'sale_cancelled':
      return const _LogMeta('alert', Icons.cancel_outlined, AppColors.warning);

    // Clients
    case 'client_created':
      return _LogMeta('shop', Icons.person_add_alt_rounded, AppColors.primary);
    case 'client_updated':
      return _LogMeta('shop', Icons.manage_accounts_rounded, AppColors.primary);
    case 'client_deleted':
      return const _LogMeta('shop', Icons.person_remove_alt_1_rounded, AppColors.warning);

    // Dépenses
    case 'expense_created':
      return _LogMeta('shop', Icons.payments_outlined, AppColors.primary);
    case 'expense_updated':
      return _LogMeta('shop', Icons.edit_note_rounded, AppColors.primary);
    case 'expense_deleted':
      return const _LogMeta('shop', Icons.money_off_rounded, AppColors.warning);

    // Membres
    case 'member_added':
      return _LogMeta('account', Icons.group_add_rounded, AppColors.primary);
    case 'member_removed':
      return const _LogMeta('account', Icons.group_remove_rounded, AppColors.warning);
    case 'member_role_changed':
      return _LogMeta('account', Icons.admin_panel_settings_outlined, AppColors.primary);

    // Comptes / abonnements
    case 'user_blocked':
      return const _LogMeta('alert', Icons.block_rounded, AppColors.error);
    case 'user_unblocked':
      return const _LogMeta('account', Icons.check_circle_outline_rounded, AppColors.secondary);
    case 'subscription_activated':
      return const _LogMeta('account', Icons.verified_rounded, AppColors.secondary);
    case 'subscription_cancelled':
      return const _LogMeta('account', Icons.cancel_outlined, AppColors.warning);
    case 'user_deleted':
    case 'account_deleted':
      return const _LogMeta('alert', Icons.person_remove_rounded, AppColors.error);
    case 'platform_reset':
      return const _LogMeta('alert', Icons.restart_alt_rounded, AppColors.error);

    default:
      return const _LogMeta('other', Icons.info_outline_rounded, AppColors.textSecondary);
  }
}

/// Titre court — 1 ligne. Les détails (catégorie, prix, etc.) vont dans la
/// sous-ligne via [_subtitleFor].
String _titleFor(String action, String? label) {
  final l = (label != null && label.isNotEmpty) ? ' : $label' : '';
  switch (action) {
    // Auth
    case 'user_login':                  return 'Connexion$l';
    case 'super_admin_password_reset':  return 'Réinit. mot de passe$l';

    // Boutique
    case 'shop_created':                return 'Boutique créée$l';
    case 'shop_updated':                return 'Boutique modifiée$l';
    case 'shop_deleted':                return 'Boutique supprimée$l';
    case 'shop_reset':                  return 'Boutique réinitialisée$l';
    case 'shop_reset_keep_products':    return 'Boutique réinitialisée (produits gardés)$l';

    // Produits
    case 'product_created':             return 'Produit créé$l';
    case 'product_updated':             return 'Produit modifié$l';
    case 'product_deleted':             return 'Produit supprimé$l';
    case 'product_archived':            return 'Produit archivé$l';
    case 'product_auto_merged':         return 'Produit auto-créé (transfert SKU)$l';
    case 'product_copied_out':          return 'Produit copié (sortie)$l';
    case 'product_copied_in':           return 'Produit copié (entrée)$l';
    case 'stock_updated':               return 'Stock modifié$l';

    // Variantes
    case 'variant_created':             return 'Variante ajoutée$l';
    case 'variant_updated':             return 'Variante modifiée$l';
    case 'variant_deleted':             return 'Variante supprimée$l';

    // Stock
    case 'stock_transfer':              return 'Transfert de stock$l';
    case 'stock_transfer_out':          return 'Transfert sortant$l';
    case 'stock_transfer_in':           return 'Transfert entrant$l';
    case 'stock_arrival':               return 'Arrivée de stock$l';
    case 'stock_incident':              return 'Incident de stock$l';
    case 'stock_return_supplier':       return 'Retour fournisseur$l';
    case 'stock_return_client':         return 'Retour client$l';
    case 'stock_adjustment':            return 'Ajustement de stock$l';

    // Métadonnées
    case 'category_created':            return 'Catégorie créée$l';
    case 'category_updated':            return 'Catégorie modifiée$l';
    case 'category_deleted':            return 'Catégorie supprimée$l';
    case 'brand_created':               return 'Marque créée$l';
    case 'brand_updated':               return 'Marque modifiée$l';
    case 'brand_deleted':               return 'Marque supprimée$l';
    case 'unit_created':                return 'Unité créée$l';
    case 'unit_updated':                return 'Unité modifiée$l';
    case 'unit_deleted':                return 'Unité supprimée$l';

    // Fournisseurs / réceptions / POs
    case 'supplier_created':            return 'Fournisseur créé$l';
    case 'supplier_updated':            return 'Fournisseur modifié$l';
    case 'supplier_deleted':            return 'Fournisseur supprimé$l';
    case 'reception_validated':         return 'Réception validée$l';
    case 'purchase_order_created':      return 'Bon de commande créé$l';
    case 'purchase_order_updated':      return 'Bon de commande modifié$l';
    case 'purchase_order_deleted':      return 'Bon de commande supprimé$l';

    // Ventes
    case 'sale_completed':              return 'Vente encaissée${label == null ? '' : ' — $label'}';
    case 'sale_cancelled':              return 'Vente annulée${label == null ? '' : ' — $label'}';

    // Clients
    case 'client_created':              return 'Client créé$l';
    case 'client_updated':              return 'Client modifié$l';
    case 'client_deleted':              return 'Client supprimé$l';

    // Dépenses
    case 'expense_created':             return 'Dépense créée$l';
    case 'expense_updated':             return 'Dépense modifiée$l';
    case 'expense_deleted':             return 'Dépense supprimée$l';

    // Membres
    case 'member_added':                return 'Membre ajouté$l';
    case 'member_removed':              return 'Membre retiré$l';
    case 'member_role_changed':         return 'Rôle modifié$l';

    // Comptes / abonnements
    case 'user_blocked':                return 'Utilisateur bloqué$l';
    case 'user_unblocked':              return 'Utilisateur débloqué$l';
    case 'subscription_activated':      return 'Abonnement activé$l';
    case 'subscription_cancelled':      return 'Abonnement annulé$l';
    case 'user_deleted':                return 'Compte supprimé$l';
    case 'account_deleted':             return 'Compte auto-supprimé$l';
    case 'platform_reset':              return 'Plateforme réinitialisée';

    default:                            return action.replaceAll('_', ' ');
  }
}

/// Sous-ligne discrète composée depuis le `details` JSONB. Retourne `null`
/// s'il n'y a rien à montrer (pas de details ou details vides).
///
/// Convention : chaque champ est séparé par " · ". Les valeurs sont rendues
/// telles quelles depuis Supabase pour rester génériques. Si une clé connue
/// ne convient pas (ex: 'price' = 0), on la saute.
String? _subtitleFor(String action, Map<String, dynamic>? d) {
  if (d == null || d.isEmpty) return null;

  // Helper : ajoute un fragment si non vide / non zéro.
  String? _str(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }
  String? _num(dynamic v, {String? unit, bool zeroOk = false}) {
    if (v == null) return null;
    if (v is num) {
      if (!zeroOk && v == 0) return null;
      // entier si possible
      final txt = v == v.toInt() ? v.toInt().toString() : v.toString();
      return unit == null ? txt : '$txt $unit';
    }
    final s = v.toString();
    return s.isEmpty ? null : (unit == null ? s : '$s $unit');
  }
  String join(List<String?> parts) =>
      parts.where((p) => p != null && p.isNotEmpty).join(' · ');

  switch (action) {
    case 'product_created':
    case 'product_updated':
    case 'stock_updated':
      return join([
        _str(d['sku']) != null ? 'SKU ${d['sku']}' : null,
        _str(d['category']),
        _str(d['brand']),
        _num(d['price'], unit: CurrencyFormatter.currentSymbol),
        _num(d['stock'], unit: 'unités', zeroOk: true) != null
            ? 'stock ${d['stock']}' : null,
        _str(d['variant_count']) != null
            ? '${d['variant_count']} variante(s)' : null,
      ]).ifEmpty();

    case 'product_deleted':
    case 'product_archived':
      return join([
        _str(d['sku']) != null ? 'SKU ${d['sku']}' : null,
        _str(d['category']),
        _num(d['stock_before'], unit: 'unités', zeroOk: true) != null
            ? 'stock avant ${d['stock_before']}' : null,
        _str(d['reason']),
      ]).ifEmpty();

    case 'product_auto_merged':
      return join([
        _str(d['sku']) != null ? 'SKU ${d['sku']}' : null,
        _str(d['from_shop']) != null
            ? 'depuis ${d['from_shop']}' : null,
        _str(d['to_shop']) != null
            ? 'vers ${d['to_shop']}' : null,
        _num(d['quantity'], unit: 'unités'),
      ]).ifEmpty();

    case 'product_copied_out':
    case 'product_copied_in':
      // out → "vers …" / in → "depuis …"
      return join([
        if (action != 'product_copied_out' && _str(d['from_shop']) != null)
          'depuis ${d['from_shop']}',
        if (action != 'product_copied_in' && _str(d['to_shop']) != null)
          'vers ${d['to_shop']}',
        _str(d['sku']) != null ? 'SKU ${d['sku']}' : null,
        _num(d['variant_count']) != null
            ? '${d['variant_count']} variante(s)' : null,
      ]).ifEmpty();

    case 'variant_created':
    case 'variant_updated':
    case 'variant_deleted':
      return join([
        _str(d['product']) != null ? 'Produit ${d['product']}' : null,
        _str(d['sku']) != null ? 'SKU ${d['sku']}' : null,
        _num(d['price'], unit: CurrencyFormatter.currentSymbol),
        _num(d['stock'], unit: 'unités', zeroOk: true) != null
            ? 'stock ${d['stock']}' : null,
      ]).ifEmpty();

    case 'stock_transfer':
    case 'stock_transfer_out':
    case 'stock_transfer_in':
      // out  → "vers …"   (côté source : où sont parties les unités)
      // in   → "depuis …" (côté destination : d'où elles arrivent)
      // legacy 'stock_transfer' → "depuis … · vers …"
      return join([
        if (action != 'stock_transfer_out' && _str(d['from']) != null)
          'depuis ${d['from']}',
        if (action != 'stock_transfer_in' && _str(d['to']) != null)
          'vers ${d['to']}',
        _num(d['quantity'], unit: 'unités'),
        _str(d['lines']) != null ? '${d['lines']} ligne(s)' : null,
      ]).ifEmpty();

    case 'stock_arrival':
      return join([
        _str(d['location']) != null ? 'sur ${d['location']}' : null,
        _num(d['quantity'], unit: 'unités'),
        _str(d['cause']),
      ]).ifEmpty();

    case 'stock_incident':
      return join([
        _str(d['status']),
        _num(d['quantity'], unit: 'unités'),
        _str(d['cause']),
      ]).ifEmpty();

    case 'stock_return_supplier':
    case 'stock_return_client':
      return join([
        _num(d['quantity'], unit: 'unités'),
        _str(d['reason']),
        _str(d['reference']) != null ? 'réf. ${d['reference']}' : null,
      ]).ifEmpty();

    case 'stock_adjustment':
      return join([
        _num(d['delta'], zeroOk: true) != null
            ? 'delta ${d['delta']}' : null,
        _str(d['reason']),
      ]).ifEmpty();

    case 'sale_completed':
    case 'sale_cancelled':
      return join([
        _num(d['item_count']) != null
            ? '${d['item_count']} article(s)' : null,
        _num(d['total'], unit: CurrencyFormatter.currentSymbol),
        _str(d['payment_method']),
        _str(d['reference']) != null ? 'réf. ${d['reference']}' : null,
      ]).ifEmpty();

    case 'client_created':
    case 'client_updated':
    case 'client_deleted':
      return join([
        _str(d['phone']),
        _str(d['email']),
        _str(d['city']),
      ]).ifEmpty();

    case 'expense_created':
    case 'expense_updated':
    case 'expense_deleted':
      return join([
        _num(d['amount'], unit: CurrencyFormatter.currentSymbol),
        _str(d['category']),
        _str(d['payment_method']),
      ]).ifEmpty();

    case 'shop_created':
    case 'shop_updated':
      return join([
        _str(d['sector']),
        _str(d['country']),
        _str(d['currency']),
      ]).ifEmpty();

    case 'shop_deleted':
      return join([
        _num(d['products_count']) != null
            ? '${d['products_count']} produit(s)' : null,
        _str(d['reason']),
      ]).ifEmpty();

    case 'shop_reset':
    case 'shop_reset_keep_products':
      return join([
        _num(d['orders']) != null ? '${d['orders']} ventes' : null,
        _num(d['products']) != null
            ? '${d['products']} produits' : null,
        _num(d['clients']) != null ? '${d['clients']} clients' : null,
        _num(d['locations']) != null
            ? '${d['locations']} emplacements' : null,
      ]).ifEmpty();

    case 'category_created':
    case 'category_updated':
    case 'category_deleted':
    case 'brand_created':
    case 'brand_updated':
    case 'brand_deleted':
    case 'unit_created':
    case 'unit_updated':
    case 'unit_deleted':
      return join([
        _str(d['old_name']) != null
            ? 'ancien nom ${d['old_name']}' : null,
        _num(d['used_by']) != null
            ? 'utilisé par ${d['used_by']} produit(s)' : null,
      ]).ifEmpty();

    case 'supplier_created':
    case 'supplier_updated':
    case 'supplier_deleted':
      return join([
        _str(d['phone']),
        _str(d['email']),
        _str(d['city']),
      ]).ifEmpty();

    case 'reception_validated':
      return join([
        _str(d['supplier']) != null ? 'de ${d['supplier']}' : null,
        _num(d['quantity'], unit: 'unités'),
        _num(d['lines']) != null ? '${d['lines']} ligne(s)' : null,
      ]).ifEmpty();

    case 'purchase_order_created':
    case 'purchase_order_updated':
    case 'purchase_order_deleted':
      return join([
        _str(d['supplier']) != null ? 'fournisseur ${d['supplier']}' : null,
        _num(d['total'], unit: CurrencyFormatter.currentSymbol),
        _str(d['status']),
      ]).ifEmpty();

    case 'member_added':
    case 'member_removed':
    case 'member_role_changed':
      return join([
        _str(d['email']),
        _str(d['role']) != null ? 'rôle ${d['role']}' : null,
        _str(d['old_role']) != null
            ? 'ancien rôle ${d['old_role']}' : null,
      ]).ifEmpty();

    case 'subscription_activated':
    case 'subscription_cancelled':
      return join([
        _str(d['plan']) != null ? 'plan ${d['plan']}' : null,
        _str(d['cycle']),
        _num(d['amount'], unit: CurrencyFormatter.currentSymbol),
      ]).ifEmpty();

    case 'user_blocked':
    case 'user_unblocked':
    case 'user_deleted':
    case 'account_deleted':
      return join([
        _str(d['email']),
        _str(d['reason']),
      ]).ifEmpty();

    default:
      // Fallback : aplatir les clés/valeurs simples (max 4) pour ne pas
      // perdre l'info même si on n'a pas de mapping dédié.
      final flat = d.entries
          .where((e) => e.value != null
                      && e.value.toString().isNotEmpty
                      && e.key != 'created_at')
          .take(4)
          .map((e) => '${e.key} ${e.value}')
          .join(' · ');
      return flat.isEmpty ? null : flat;
  }
}

extension _StringIfEmpty on String {
  String? ifEmpty() => isEmpty ? null : this;
}
