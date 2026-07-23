import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';

/// Phase 1 observabilité — section super-admin « Bugs ».
/// Liste les rapports d'erreurs de TOUTES les boutiques (table `error_reports`,
/// dédupliquée côté serveur : 1 ligne par bug, `count` = nb d'occurrences),
/// triés par dernière occurrence. Actions de statut (résolu / en cours /
/// ignoré). Rendu INLINE dans le panneau SA (pas de scaffold propre).
class PlatformBugsSection extends StatefulWidget {
  const PlatformBugsSection({super.key});

  @override
  State<PlatformBugsSection> createState() => _PlatformBugsSectionState();
}

class _PlatformBugsSectionState extends State<PlatformBugsSection> {
  late Future<List<Map<String, dynamic>>> _future;
  // Filtre : null = tous, sinon une sévérité ('fatal'|'error'|'warning').
  String? _sevFilter;
  final _dateFmt = DateFormat('dd/MM HH:mm');

  @override
  void initState() {
    super.initState();
    _future = AppDatabase.getErrorReports();
  }

  Future<void> _refresh() async {
    setState(() => _future = AppDatabase.getErrorReports());
    await _future;
  }

  Future<void> _setStatus(String id, String status) async {
    try {
      await AppDatabase.setErrorReportStatus(id, status);
      if (!mounted) return;
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Échec mise à jour : $e')),
      );
    }
  }

  List<Map<String, dynamic>> _applyFilter(List<Map<String, dynamic>> all) {
    if (_sevFilter == null) return all;
    return all.where((e) => e['severity'] == _sevFilter).toList();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final all = snapshot.data ?? const <Map<String, dynamic>>[];
        final filtered = _applyFilter(all);
        final fatals = all.where((e) => e['severity'] == 'fatal').length;

        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _buildFilters(),
              const SizedBox(height: 12),
              Text.rich(TextSpan(
                style: AppTextStyles.bodyBold,
                children: [
                  TextSpan(text: '${all.length} bug(s)'),
                  const TextSpan(text: ' dont '),
                  TextSpan(
                    text: '$fatals critique(s)',
                    style:
                        AppTextStyles.bodyBold.copyWith(color: AppColors.error),
                  ),
                ],
              )),
              const SizedBox(height: 12),
              if (filtered.isEmpty)
                _buildEmpty(context)
              else
                ...filtered.map((e) => _BugCard(
                      report: e,
                      dateFmt: _dateFmt,
                      onStatus: (status) =>
                          _setStatus(e['id'].toString(), status),
                    )),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFilters() {
    const sevs = <MapEntry<String?, String>>[
      MapEntry(null, 'Tous'),
      MapEntry('fatal', 'Critiques'),
      MapEntry('error', 'Erreurs'),
      MapEntry('warning', 'Avertissements'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in sevs)
          ChoiceChip(
            label: Text(s.value, style: AppTextStyles.caption),
            selected: _sevFilter == s.key,
            selectedColor: s.key == 'fatal'
                ? AppColors.error.withValues(alpha: 0.15)
                : null,
            onSelected: (_) => setState(() => _sevFilter = s.key),
          ),
      ],
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.check_circle_outline_rounded,
              size: 40, color: Theme.of(context).semantic.borderSubtle),
          const SizedBox(height: 12),
          Text('Aucun bug signalé', style: AppTextStyles.bodySecondary),
        ],
      ),
    );
  }
}

class _BugCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final DateFormat dateFmt;
  final ValueChanged<String> onStatus;

  const _BugCard({
    required this.report,
    required this.dateFmt,
    required this.onStatus,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final severity = (report['severity'] as String?) ?? 'error';
    final color = _sevColor(severity);
    final message = (report['message'] as String?)?.trim();
    final errorType = (report['error_type'] as String?) ?? '';
    final route = (report['route'] as String?) ?? '';
    final shopId = (report['shop_id'] as String?);
    final platform = (report['platform'] as String?) ?? '';
    final count = report['count'] ?? 1;
    final status = (report['status'] as String?) ?? 'new';
    final lastSeen = _parseDate(report['last_seen_at']);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: severity == 'fatal' ? AppColors.error : theme.semantic.borderSubtle,
          width: severity == 'fatal' ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Badge(text: severity.toUpperCase(), color: color),
              const SizedBox(width: 6),
              if (count is int && count > 1)
                _Badge(text: '×$count', color: AppColors.textSecondary),
              const Spacer(),
              if (status != 'new')
                _Badge(text: _statusLabel(status), color: AppColors.textSecondary),
              _StatusMenu(onSelected: onStatus),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            errorType.isNotEmpty ? errorType : 'Erreur',
            style: AppTextStyles.bodyBold,
          ),
          if (message != null && message.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(message,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodySmSecondary),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              if (route.isNotEmpty)
                _Meta(icon: Icons.alt_route_rounded, text: route),
              if (shopId != null && shopId.isNotEmpty)
                _Meta(icon: Icons.store_outlined, text: shopId),
              if (platform.isNotEmpty)
                _Meta(icon: Icons.devices_outlined, text: platform),
              if (lastSeen != null)
                _Meta(
                    icon: Icons.schedule_rounded,
                    text: dateFmt.format(lastSeen)),
            ],
          ),
        ],
      ),
    );
  }

  Color _sevColor(String s) => switch (s) {
        'fatal' => AppColors.error,
        'warning' => AppColors.warning,
        _ => const Color(0xFFD97706), // orange = error
      };

  String _statusLabel(String s) => switch (s) {
        'ack' => 'Vu',
        'in_progress' => 'En cours',
        'resolved' => 'Résolu',
        'ignored' => 'Ignoré',
        _ => s,
      };

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    return DateTime.tryParse(raw.toString())?.toLocal();
  }
}

class _StatusMenu extends StatelessWidget {
  final ValueChanged<String> onSelected;
  const _StatusMenu({required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded, size: 18),
      tooltip: 'Statut',
      onSelected: onSelected,
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'in_progress', child: Text('Marquer « en cours »')),
        PopupMenuItem(value: 'resolved', child: Text('Marquer résolu')),
        PopupMenuItem(value: 'ignored', child: Text('Ignorer')),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: AppTextStyles.caption
              .copyWith(color: color, fontWeight: FontWeight.w700)),
    );
  }
}

class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Meta({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(text, style: AppTextStyles.bodySmSecondary),
      ],
    );
  }
}
