import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../domain/approval_closure.dart';
import '../../domain/entities/sale.dart';

/// Ouvre le sheet de clôture d'une tournée « à choisir sur place ».
///
/// Pour chaque article réservé, l'opérateur saisit la quantité GARDÉE par le
/// client (via un stepper borné à `[0, réservé]`). Retourne une map
/// `{ item.productId: quantité gardée }` à passer à
/// `SaleLocalDatasource.closeApprovalOrder`, ou `null` si annulé.
Future<Map<String, int>?> showApprovalClosureSheet(
  BuildContext context, {
  required Sale order,
}) {
  return showFormSheet<Map<String, int>>(
    context: context,
    builder: (_) => _ApprovalClosureSheet(order: order),
  );
}

class _ApprovalClosureSheet extends StatefulWidget {
  final Sale order;
  const _ApprovalClosureSheet({required this.order});

  @override
  State<_ApprovalClosureSheet> createState() => _ApprovalClosureSheetState();
}

class _ApprovalClosureSheetState extends State<_ApprovalClosureSheet> {
  // Quantité gardée (vendue) par article. Par défaut : tout est gardé.
  late final Map<String, int> _kept;

  @override
  void initState() {
    super.initState();
    _kept = {for (final i in widget.order.items) i.productId: i.quantity};
  }

  /// Quantité réservée par article (clé = productId) — base de la borne.
  Map<String, int> get _reserved =>
      {for (final i in widget.order.items) i.productId: i.quantity};

  void _inc(String productId, int max) {
    final cur = _kept[productId] ?? 0;
    if (cur >= max) return;
    setState(() => _kept[productId] = cur + 1);
  }

  void _dec(String productId) {
    final cur = _kept[productId] ?? 0;
    if (cur <= 0) return;
    setState(() => _kept[productId] = cur - 1);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    // Réconciliation pure : total vendu vs total remis en stock.
    final recon = ApprovalClosure.reconcile(reserved: _reserved, kept: _kept);

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FormSheetHeader(
            title: 'Clôturer la tournée',
            subtitle: widget.order.clientName,
            icon: Icons.fact_check_outlined,
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Indique pour chaque article la quantité GARDÉE par le '
                    'client. Le reste est automatiquement remis en stock.',
                    style: AppTextStyles.captionHint
                        .copyWith(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  for (final item in widget.order.items)
                    _ApprovalItemRow(
                      name: item.variantName != null &&
                              item.variantName!.isNotEmpty
                          ? '${item.productName} · ${item.variantName}'
                          : item.productName,
                      reserved: item.quantity,
                      kept: _kept[item.productId] ?? 0,
                      onDec: () => _dec(item.productId),
                      onInc: () => _inc(item.productId, item.quantity),
                    ),
                ],
              ),
            ),
          ),
          // Récapitulatif gardé / retourné.
          Container(
            margin: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: sem.brandSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: sem.brand.withValues(alpha: 0.25)),
            ),
            child: Row(children: [
              Expanded(
                child: _RecapCell(
                  label: 'Gardé (vendu)',
                  value: recon.totalKept,
                  color: sem.brandText,
                ),
              ),
              Container(width: 1, height: 28, color: sem.borderSubtle),
              Expanded(
                child: _RecapCell(
                  label: 'Retourné (stock)',
                  value: recon.totalReturned,
                  color: AppColors.textSecondary,
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
            child: AppPrimaryButton(
              label: 'Valider la clôture',
              icon: Icons.check_circle_outline_rounded,
              color: AppColors.primary,
              onTap: () => Navigator.of(context).pop(_kept),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ligne article : nom + quantité réservée + stepper de la quantité gardée.
class _ApprovalItemRow extends StatelessWidget {
  final String name;
  final int reserved;
  final int kept;
  final VoidCallback onDec;
  final VoidCallback onInc;
  const _ApprovalItemRow({
    required this.name,
    required this.reserved,
    required this.kept,
    required this.onDec,
    required this.onInc,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColors.onSurface)),
              const SizedBox(height: 2),
              Text('Réservé : $reserved',
                  style: AppTextStyles.captionHint
                      .copyWith(color: AppColors.textSecondary)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _StepBtn(icon: Icons.remove_rounded, onTap: onDec),
        SizedBox(
          width: 34,
          child: Text('$kept',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyBold.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppColors.onSurface)),
        ),
        _StepBtn(icon: Icons.add_rounded, onTap: onInc),
      ]),
    );
  }
}

/// Bouton − / + du stepper.
class _StepBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _StepBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: sem.borderSubtle),
          ),
          child: Icon(icon, size: 18, color: AppColors.primary),
        ),
      ),
    );
  }
}

/// Cellule du récapitulatif bas (libellé + total).
class _RecapCell extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _RecapCell({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$value',
            style: AppTextStyles.subtitleBold
                .copyWith(fontWeight: FontWeight.w800, color: color)),
        const SizedBox(height: 2),
        Text(label,
            style: AppTextStyles.captionHint
                .copyWith(color: AppColors.textSecondary)),
      ],
    );
  }
}
