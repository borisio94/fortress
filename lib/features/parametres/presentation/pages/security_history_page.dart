import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/empty_state_widget.dart';

/// Page « Historique sécurité » : liste paginée des actions destructives
/// loggées dans `danger_action_logs` pour la boutique courante.
///
/// Visible uniquement par le **owner** de la boutique. Si un employé tape
/// l'URL en direct, il voit un état "non autorisé".
class SecurityHistoryPage extends ConsumerStatefulWidget {
  final String shopId;
  const SecurityHistoryPage({super.key, required this.shopId});

  @override
  ConsumerState<SecurityHistoryPage> createState() =>
      _SecurityHistoryPageState();
}

class _SecurityHistoryPageState extends ConsumerState<SecurityHistoryPage> {
  static const int _pageSize = 50;
  bool _loading = true;
  String? _error;
  List<_LogRow> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error   = null;
    });
    try {
      final raw = await Supabase.instance.client
          .from('danger_action_logs')
          .select('id, action, target_id, target_label, executed_at, '
              'success, error_message, user_id, user_email')
          .eq('shop_id', widget.shopId)
          .order('executed_at', ascending: false)
          .limit(_pageSize);
      final list = (raw as List)
          .map((m) => _LogRow.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList();
      if (!mounted) return;
      setState(() {
        _rows    = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error   = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n  = AppLocalizations.of(context)!;
    final perms = ref.watch(permissionsProvider(widget.shopId));

    return AppScaffold(
      shopId:     widget.shopId,
      title:      l10n.securityHistoryTitle,
      isRootPage: false,
      body: !perms.isOwner
          ? _NotAuthorized(message: l10n.securityHistoryOwnerOnly)
          : RefreshIndicator(
              onRefresh: _load,
              child: _buildBody(context, l10n),
            ),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).semantic.danger,
            ),
          ),
        ),
      );
    }
    if (_rows.isEmpty) {
      return Center(
        child: EmptyStateWidget(
          icon:     Icons.shield_outlined,
          title:    l10n.securityHistoryEmptyTitle,
          subtitle: l10n.securityHistoryEmptySubtitle,
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _LogTile(row: _rows[i]),
    );
  }
}

// ─── Modèle ─────────────────────────────────────────────────────────────────

class _LogRow {
  final String   id;
  final String   action;
  final String?  targetId;
  final String?  targetLabel;
  final DateTime executedAt;
  final bool     success;
  final String?  errorMessage;
  final String?  userEmail;

  const _LogRow({
    required this.id,
    required this.action,
    required this.executedAt,
    required this.success,
    this.targetId,
    this.targetLabel,
    this.errorMessage,
    this.userEmail,
  });

  factory _LogRow.fromMap(Map<String, dynamic> m) => _LogRow(
        id:           m['id']           as String,
        action:       m['action']       as String? ?? '',
        targetId:     m['target_id']    as String?,
        targetLabel:  m['target_label'] as String?,
        executedAt:   DateTime.parse(m['executed_at'] as String).toLocal(),
        success:      (m['success']     as bool?) ?? false,
        errorMessage: m['error_message'] as String?,
        userEmail:    m['user_email']   as String?,
      );
}

// ─── Tile log ───────────────────────────────────────────────────────────────

class _LogTile extends StatelessWidget {
  final _LogRow row;
  const _LogTile({required this.row});

  String _actionLabel(AppLocalizations l10n, String key) => switch (key) {
        'delete_shop'    => l10n.dangerActionDeleteShop,
        'delete_admin'   => l10n.dangerActionDeleteAdmin,
        'demote_admin'   => l10n.dangerActionDemoteAdmin,
        'cancel_sale'    => l10n.dangerActionCancelSale,
        'delete_product' => l10n.dangerActionDeleteProduct,
        'delete_client'  => l10n.dangerActionDeleteClient,
        _                => key,
      };

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final scheme   = theme.colorScheme;
    final semantic = theme.semantic;
    final l10n     = AppLocalizations.of(context)!;

    final statusColor = row.success ? semantic.success : semantic.danger;
    final statusIcon  = row.success
        ? Icons.check_circle_outline
        : Icons.error_outline;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: semantic.borderSubtle),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(statusIcon, size: 18, color: statusColor),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(
                _actionLabel(l10n, row.action),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                maxLines: 1, overflow: TextOverflow.ellipsis,
              )),
              const SizedBox(width: 8),
              Text(
                _formatDate(row.executedAt),
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ]),
            if ((row.targetLabel ?? '').isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                row.targetLabel!,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.75),
                ),
                maxLines: 2, overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 4, children: [
              _Pill(
                label: row.userEmail ?? l10n.securityHistoryUnknownUser,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
              _Pill(
                label: row.success
                    ? l10n.securityHistorySuccess
                    : (row.errorMessage ?? l10n.securityHistoryFailure),
                color: statusColor,
              ),
            ]),
          ],
        )),
      ]),
    );
  }

  String _formatDate(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mn = d.minute.toString().padLeft(2, '0');
    return '$dd/$mm $hh:$mn';
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color  color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
        maxLines: 1, overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

// ─── Non autorisé ───────────────────────────────────────────────────────────

class _NotAuthorized extends StatelessWidget {
  final String message;
  const _NotAuthorized({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final semantic = theme.semantic;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded,
                size: 42, color: semantic.danger),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
