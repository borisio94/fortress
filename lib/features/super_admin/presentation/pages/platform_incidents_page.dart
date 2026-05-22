import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_scaffold.dart';

/// SA-7 — Page super-admin listant les incidents critiques de TOUTES les
/// boutiques (non résolus). Filtres en mémoire par type et par sévérité.
class PlatformIncidentsPage extends StatefulWidget {
  final String shopId;
  const PlatformIncidentsPage({super.key, this.shopId = ''});

  @override
  State<PlatformIncidentsPage> createState() => _PlatformIncidentsPageState();
}

class _PlatformIncidentsPageState extends State<PlatformIncidentsPage> {
  // Filtre type : null = tous, sinon une des valeurs de `type`.
  String? _typeFilter;
  // Filtre sévérité : true = uniquement les critiques.
  bool _criticalOnly = false;

  late Future<List<Map<String, dynamic>>> _future;

  static const _typeLabels = <String, String>{
    'scrapped': 'Rebut',
    'discounted': 'Remisé',
    'in_repair': 'Réparation',
    'return_supplier': 'Retour fournisseur',
  };

  final _dateFmt = DateFormat('dd/MM/yy');

  @override
  void initState() {
    super.initState();
    _future = AppDatabase.getAllIncidents();
  }

  Future<void> _refresh() async {
    setState(() {
      _future = AppDatabase.getAllIncidents();
    });
    await _future;
  }

  String _typeLabel(String? type) => _typeLabels[type] ?? (type ?? '—');

  List<Map<String, dynamic>> _applyFilters(List<Map<String, dynamic>> all) {
    return all.where((i) {
      if (_typeFilter != null && i['type'] != _typeFilter) return false;
      if (_criticalOnly && i['severity'] != 'critical') return false;
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Incidents',
      isRootPage: false,
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = snapshot.data ?? const <Map<String, dynamic>>[];
          final filtered = _applyFilters(all);
          final criticalCount =
              filtered.where((i) => i['severity'] == 'critical').length;

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                _buildFilters(context),
                const SizedBox(height: 12),
                _buildCounter(context, filtered.length, criticalCount),
                const SizedBox(height: 12),
                if (filtered.isEmpty)
                  _buildEmpty(context)
                else
                  ...filtered.map((i) => _IncidentCard(
                        incident: i,
                        typeLabel: _typeLabel(i['type'] as String?),
                        dateFmt: _dateFmt,
                      )),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildFilters(BuildContext context) {
    final entries = <MapEntry<String?, String>>[
      const MapEntry<String?, String>(null, 'Tous'),
      ..._typeLabels.entries
          .map((e) => MapEntry<String?, String>(e.key, e.value)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in entries)
              ChoiceChip(
                label: Text(e.value, style: AppTextStyles.caption),
                selected: _typeFilter == e.key,
                onSelected: (_) => setState(() => _typeFilter = e.key),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Tous', style: AppTextStyles.caption),
              selected: !_criticalOnly,
              onSelected: (_) => setState(() => _criticalOnly = false),
            ),
            ChoiceChip(
              label: const Text('Critiques', style: AppTextStyles.caption),
              selected: _criticalOnly,
              selectedColor: AppColors.error.withValues(alpha: 0.15),
              onSelected: (_) => setState(() => _criticalOnly = true),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCounter(BuildContext context, int total, int critical) {
    return Text.rich(
      TextSpan(
        style: AppTextStyles.bodyBold,
        children: [
          TextSpan(text: '$total incident(s)'),
          const TextSpan(text: ' dont '),
          TextSpan(
            text: '$critical critique(s)',
            style: AppTextStyles.bodyBold.copyWith(color: AppColors.error),
          ),
        ],
      ),
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
          const Text('Aucun incident', style: AppTextStyles.bodySecondary),
        ],
      ),
    );
  }
}

class _IncidentCard extends StatelessWidget {
  final Map<String, dynamic> incident;
  final String typeLabel;
  final DateFormat dateFmt;

  const _IncidentCard({
    required this.incident,
    required this.typeLabel,
    required this.dateFmt,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCritical = incident['severity'] == 'critical';
    final shops = incident['shops'];
    final shopName = (shops is Map && shops['name'] != null)
        ? shops['name'].toString()
        : 'Boutique inconnue';
    final productName =
        (incident['product_name'] as String?)?.trim().isNotEmpty == true
            ? incident['product_name'] as String
            : 'Produit inconnu';
    final quantity = incident['quantity'];
    final createdAt = _parseDate(incident['created_at']);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCritical ? AppColors.error : theme.semantic.borderSubtle,
          width: isCritical ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(productName, style: AppTextStyles.bodyBold),
              ),
              const SizedBox(width: 8),
              _SeverityBadge(isCritical: isCritical),
            ],
          ),
          const SizedBox(height: 4),
          Text(shopName, style: AppTextStyles.bodySmSecondary),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              _MetaItem(icon: Icons.label_outline_rounded, text: typeLabel),
              if (quantity != null)
                _MetaItem(
                    icon: Icons.numbers_rounded, text: 'Qté : $quantity'),
              if (createdAt != null)
                _MetaItem(
                    icon: Icons.event_outlined,
                    text: dateFmt.format(createdAt)),
            ],
          ),
        ],
      ),
    );
  }

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    return DateTime.tryParse(raw.toString())?.toLocal();
  }
}

class _SeverityBadge extends StatelessWidget {
  final bool isCritical;
  const _SeverityBadge({required this.isCritical});

  @override
  Widget build(BuildContext context) {
    final color =
        isCritical ? AppColors.error : Theme.of(context).semantic.borderSubtle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isCritical ? 'Critique' : 'Normal',
        style: AppTextStyles.caption.copyWith(
          color: isCritical ? AppColors.error : AppColors.textSecondary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MetaItem({required this.icon, required this.text});

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
