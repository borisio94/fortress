import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/export_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../dashboard/data/dashboard_providers.dart';
import '../../../subscription/domain/models/plan_type.dart';
import '../../../subscription/presentation/widgets/subscription_guard.dart';

/// Journal des rebuts résolus sur la période courante, avec export CSV.
/// S'appuie sur `scrapJournalProvider` (déjà existant dans dashboard).
class LossesJournalWidget extends ConsumerWidget {
  final String shopId;
  const LossesJournalWidget({super.key, required this.shopId});

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  Future<void> _export(BuildContext context, List<ScrapEntry> entries) async {
    await ExportService.shareCsv(
      context,
      filename: 'pertes',
      subject:  'Journal des pertes',
      emptyMessage: 'Aucune perte à exporter sur la période',
      header:   const ['Date', 'Produit', 'Quantite', 'Cout unitaire',
                       'Perte totale', 'Declare par', 'Notes'],
      rows: entries.map((e) => [
        _fmtDate(e.resolvedAt),
        e.productName,
        e.quantity,
        e.unitCost.toStringAsFixed(2),
        e.totalLoss.toStringAsFixed(2),
        e.createdBy ?? '',
        e.notes ?? '',
      ]).toList(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(scrapJournalProvider(shopId));
    final total   = entries.fold<double>(0, (s, e) => s + e.totalLoss);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha:0.03),
            blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.delete_forever_rounded,
              size: 16, color: Color(0xFFEF4444)),
          const SizedBox(width: 8),
          const Expanded(child: Text('Journal des pertes',
              style: AppTextStyles.label)),
          // Guard CSV export — feature premium. L'utilisateur sans la
          // feature voit le bouton mais le tap ouvre l'UpgradeSheet.
          TextButton.icon(
            onPressed: entries.isEmpty ? null : () {
              final plan = ref.read(currentPlanProvider);
              if (!plan.hasFeature(Feature.csvExport)) {
                UpgradeSheet.showFeature(context,
                    feature: Feature.csvExport);
                return;
              }
              _export(context, entries);
            },
            icon: const Icon(Icons.file_download_rounded, size: 16),
            label: Text('CSV', style: AppTextStyles.bodySm.copyWith(
                color: AppColors.primary)),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Text(
          entries.isEmpty
              ? 'Aucun rebut résolu sur la période'
              : '${entries.length} entrée${entries.length > 1 ? "s" : ""} · '
                'Total : ${CurrencyFormatter.format(total)}',
          style: AppTextStyles.caption,
        ),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 10),
          Divider(height: 1, color: Theme.of(context).semantic.borderSubtle),
          const SizedBox(height: 6),
          ...entries.take(8).map((e) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.productName,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodySmBold),
                Text('${_fmtDate(e.resolvedAt)} · ×${e.quantity}',
                    style: AppTextStyles.micro.copyWith(
                        color: const Color(0xFF9CA3AF))),
              ])),
              const SizedBox(width: 8),
              Text(CurrencyFormatter.format(e.totalLoss),
                  style: AppTextStyles.bodySmBold.copyWith(
                      color: const Color(0xFFEF4444))),
            ]),
          )),
          if (entries.length > 8) ...[
            const SizedBox(height: 4),
            Text('+${entries.length - 8} autre'
                '${entries.length - 8 > 1 ? "s" : ""}',
                style: AppTextStyles.micro.copyWith(
                    color: const Color(0xFF9CA3AF))),
          ],
        ],
      ]),
    );
  }
}
