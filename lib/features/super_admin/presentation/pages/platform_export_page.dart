import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/export_models.dart';
import '../../../../core/services/export_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_scaffold.dart';

/// SA-8 — exports plateforme (super-admin) : récap boutiques + journal
/// des paiements, toutes boutiques confondues, en CSV via ExportService.
class PlatformExportPage extends StatefulWidget {
  final String shopId;
  const PlatformExportPage({super.key, this.shopId = ''});

  @override
  State<PlatformExportPage> createState() => _PlatformExportPageState();
}

class _PlatformExportPageState extends State<PlatformExportPage> {
  bool _busyShops = false;
  bool _busyPayments = false;

  Future<void> _exportShops() async {
    setState(() => _busyShops = true);
    try {
      final (header, rows) = await AppDatabase.getPlatformShopsExport();
      if (!mounted) return;
      await ExportService.exportToCsv(
        context,
        config: const ExportConfig(
          type: ExportType.platformShops,
          scope: ExportScopePlatform(),
          format: ExportFormat.csv,
          scopeLabel: 'Plateforme',
        ),
        header: header,
        rows: rows,
        emptyMessage: 'Aucune boutique à exporter',
      );
    } finally {
      if (mounted) setState(() => _busyShops = false);
    }
  }

  Future<void> _exportPayments() async {
    setState(() => _busyPayments = true);
    try {
      final (header, rows) = await AppDatabase.getPlatformPaymentsExport();
      if (!mounted) return;
      await ExportService.exportToCsv(
        context,
        config: const ExportConfig(
          type: ExportType.platformPayments,
          scope: ExportScopePlatform(),
          format: ExportFormat.csv,
          scopeLabel: 'Plateforme',
        ),
        header: header,
        rows: rows,
        emptyMessage: 'Aucun paiement à exporter',
      );
    } finally {
      if (mounted) setState(() => _busyPayments = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Export plateforme',
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Exports CSV de l\'ensemble de la plateforme. Réservé au '
              'super-administrateur.', style: AppTextStyles.bodySmSecondary),
          const SizedBox(height: 16),
          _ExportCard(
            icon: Icons.store_rounded,
            color: AppColors.primary,
            title: 'Boutiques',
            subtitle: 'Nom, propriétaire, plan, CA encaissé, nb ventes, date',
            busy: _busyShops,
            onTap: _exportShops,
          ),
          const SizedBox(height: 12),
          _ExportCard(
            icon: Icons.receipt_long_rounded,
            color: AppColors.secondary,
            title: 'Paiements',
            subtitle: 'Tous les paiements enregistrés (toutes boutiques)',
            busy: _busyPayments,
            onTap: _exportPayments,
          ),
        ],
      ),
    );
  }
}

class _ExportCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool busy;
  final VoidCallback onTap;
  const _ExportCard({
    required this.icon, required this.color, required this.title,
    required this.subtitle, required this.busy, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.semantic.borderSubtle),
        ),
        child: Row(children: [
          Container(width: 42, height: 42,
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: color, size: 22)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTextStyles.bodyBold),
              Text(subtitle, style: AppTextStyles.caption),
            ])),
          if (busy)
            const SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(Icons.download_rounded, color: color, size: 22),
        ]),
      ),
    );
  }
}
