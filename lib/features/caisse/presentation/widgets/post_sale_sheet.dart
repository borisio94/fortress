import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/services/document_service.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/entities/sale.dart';

/// Bottom sheet affiché après une vente complétée.
/// Permet de choisir le format, imprimer, aperçu, et partager.
class PostSaleSheet extends StatefulWidget {
  final Sale sale;
  const PostSaleSheet({super.key, required this.sale});

  /// Ouvre le bottom sheet. Appeler après chaque vente complétée.
  static void show(BuildContext context, Sale sale) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => PostSaleSheet(sale: sale),
    );
  }

  @override
  State<PostSaleSheet> createState() => _PostSaleSheetState();
}

class _PostSaleSheetState extends State<PostSaleSheet> {
  int _formatIdx = 0;
  bool _busy = false;

  static const _formats = [
    ('A4',     InvoiceFormat.a4,        Icons.description_outlined),
    ('58mm',   InvoiceFormat.thermal58, Icons.receipt_outlined),
    ('80mm',   InvoiceFormat.thermal80, Icons.receipt_long_outlined),
  ];

  InvoiceFormat get _format => _formats[_formatIdx].$2;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) AppSnack.error(context, e.toString().split('\n').first);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sale = widget.sale;

    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [

          // Poignée
          Center(child: Container(width: 36, height: 4,
              decoration: BoxDecoration(color: const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),

          // Titre + montant
          Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.receipt_long_rounded,
                  size: 20, color: Color(0xFF10B981)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Envoyer le reçu',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A))),
              Text(CurrencyFormatter.format(sale.total),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                      color: AppColors.primary)),
            ])),
            if (sale.clientName != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(8)),
                child: Text(sale.clientName!,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: AppColors.primary)),
              ),
          ]),
          const SizedBox(height: 20),

          // ── Sélection format ──────────────────────────────────
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Format du reçu',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280))),
          ),
          const SizedBox(height: 8),
          Row(children: List.generate(_formats.length, (i) {
            final f = _formats[i];
            final sel = i == _formatIdx;
            return Expanded(child: Padding(
              padding: EdgeInsets.only(right: i < _formats.length - 1 ? 8 : 0),
              child: GestureDetector(
                onTap: () => setState(() => _formatIdx = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: sel ? AppColors.primary : const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: sel ? AppColors.primary : const Color(0xFFE5E7EB)),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(f.$3, size: 20,
                        color: sel ? Colors.white : const Color(0xFF9CA3AF)),
                    const SizedBox(height: 4),
                    Text(f.$1, style: TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: sel ? Colors.white : const Color(0xFF6B7280))),
                  ]),
                ),
              ),
            ));
          })),
          const SizedBox(height: 20),

          // ── Boutons Imprimer / Aperçu ─────────────────────────
          Row(children: [
            Expanded(child: _SheetBtn(
              icon: Icons.print_rounded,
              label: 'Imprimer',
              color: const Color(0xFF374151),
              busy: _busy,
              onTap: () => _run(() =>
                  DocumentService.printInvoice(sale, format: _format)),
            )),
            const SizedBox(width: 10),
            Expanded(child: _SheetBtn(
              icon: Icons.picture_as_pdf_rounded,
              label: 'Aperçu PDF',
              color: const Color(0xFF3B82F6),
              busy: _busy,
              onTap: () => _run(() =>
                  DocumentService.previewInvoice(sale, context, format: _format)),
            )),
          ]),
          const SizedBox(height: 16),

          // ── Bouton Partager ─────────────────────────────────────
          SizedBox(
            width: double.infinity, height: 48,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : () => _run(() async {
                await DocumentService.shareInvoice(sale, format: _format);
                if (mounted) Navigator.of(context).pop();
              }),
              icon: _busy
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.share_rounded, size: 18),
              label: const Text('Partager le reçu'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _SheetBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool busy;
  final VoidCallback onTap;
  const _SheetBtn({required this.icon, required this.label,
    required this.color, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: busy ? null : onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 22, color: color),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 11,
            fontWeight: FontWeight.w600, color: color)),
      ]),
    ),
  );
}
