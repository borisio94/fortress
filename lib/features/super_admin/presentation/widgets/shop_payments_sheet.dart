import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/form_sheet.dart';

/// Bottom-sheet SA-4 — historique des paiements d'une boutique + formulaire
/// d'enregistrement d'un paiement (super-admin). Charge `payment_records`
/// via `AppDatabase.getShopPayments` ; enregistre via `recordPayment`.
class ShopPaymentsSheet extends StatefulWidget {
  final String shopId;
  final String shopName;
  const ShopPaymentsSheet({super.key, required this.shopId, required this.shopName});

  @override
  State<ShopPaymentsSheet> createState() => _ShopPaymentsSheetState();
}

class _ShopPaymentsSheetState extends State<ShopPaymentsSheet> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = AppDatabase.getShopPayments(widget.shopId);
  }

  void _refresh() => setState(() {
        _future = AppDatabase.getShopPayments(widget.shopId);
      });

  Future<void> _openRecordForm() async {
    final saved = await showFormSheet<bool>(
      context: context,
      builder: (_) => _RecordPaymentForm(
          shopId: widget.shopId, shopName: widget.shopName),
    );
    if (saved == true) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scroll) => Column(children: [
        const SizedBox(height: 8),
        Container(width: 36, height: 4,
            decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(2))),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
          child: Row(children: [
            Expanded(child: Text('Paiements · ${widget.shopName}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.subtitleBold.copyWith(
                    color: theme.colorScheme.onSurface))),
            FilledButton.icon(
              onPressed: _openRecordForm,
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Enregistrer'),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final list = snap.data ?? const [];
              if (list.isEmpty) {
                return Center(child: Text('Aucun paiement enregistré',
                    style: AppTextStyles.bodySmSecondary));
              }
              return ListView.separated(
                controller: scroll,
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _PaymentTile(list[i]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _PaymentTile extends StatelessWidget {
  final Map<String, dynamic> p;
  const _PaymentTile(this.p);

  String _methodLabel(String? m) => switch (m) {
        'cash'         => 'Espèces',
        'mobile_money' => 'Mobile Money',
        'transfer'     => 'Virement',
        _              => m ?? '—',
      };

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final amount = (p['amount'] as num?)?.toDouble() ?? 0;
    final date   = DateTime.tryParse(p['paid_at']?.toString() ?? '');
    final plan   = p['plans'] as Map?;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.inputBorder),
      ),
      child: Row(children: [
        Container(width: 34, height: 34,
            decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.payments_rounded, size: 16,
                color: AppColors.secondary)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(CurrencyFormatter.format(amount),
                style: AppTextStyles.bodyBold),
            Text('${_methodLabel(p['method'] as String?)}'
                '${plan?['label'] != null ? " · ${plan!['label']}" : ""}',
                style: AppTextStyles.caption),
            if ((p['reference'] as String?)?.isNotEmpty == true)
              Text('Réf : ${p['reference']}', style: AppTextStyles.micro
                  .copyWith(color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.6))),
          ])),
        if (date != null)
          Text(DateFormat('dd/MM/yy').format(date),
              style: AppTextStyles.microSecondary),
      ]),
    );
  }
}

class _RecordPaymentForm extends StatefulWidget {
  final String shopId;
  final String shopName;
  const _RecordPaymentForm({required this.shopId, required this.shopName});

  @override
  State<_RecordPaymentForm> createState() => _RecordPaymentFormState();
}

class _RecordPaymentFormState extends State<_RecordPaymentForm> {
  final _amount = TextEditingController();
  final _ref    = TextEditingController();
  final _note   = TextEditingController();
  String _method = 'cash';
  String? _planId;
  bool _activate = false;
  int _months = 1;
  bool _saving = false;
  List<Map<String, dynamic>> _plans = const [];

  @override
  void initState() {
    super.initState();
    AppDatabase.getPlansLite().then((p) {
      if (mounted) setState(() => _plans = p);
    });
  }

  @override
  void dispose() {
    _amount.dispose(); _ref.dispose(); _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amount = num.tryParse(_amount.text.trim().replaceAll(',', '.')) ?? 0;
    if (amount <= 0) {
      AppSnack.error(context, 'Montant invalide');
      return;
    }
    setState(() => _saving = true);
    try {
      await AppDatabase.recordPayment(
        shopId:       widget.shopId,
        planId:       _planId,
        amount:       amount,
        method:       _method,
        reference:    _ref.text.trim(),
        note:         _note.text.trim(),
        activatePlan: _activate && _planId != null,
        months:       _months,
      );
      if (mounted) {
        AppSnack.success(context, 'Paiement enregistré');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Échec : $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          FormSheetHeader(title: 'Paiement · ${widget.shopName}'),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Montant', isDense: true),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _method,
            decoration: const InputDecoration(
                labelText: 'Mode de paiement', isDense: true),
            items: const [
              DropdownMenuItem(value: 'cash', child: Text('Espèces')),
              DropdownMenuItem(value: 'mobile_money', child: Text('Mobile Money')),
              DropdownMenuItem(value: 'transfer', child: Text('Virement')),
              DropdownMenuItem(value: 'other', child: Text('Autre')),
            ],
            onChanged: (v) => setState(() => _method = v ?? 'cash'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ref,
            decoration: const InputDecoration(
                labelText: 'Référence (optionnel)', isDense: true),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
                labelText: 'Note (optionnel)', isDense: true),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: _planId,
            decoration: const InputDecoration(
                labelText: 'Plan associé (optionnel)', isDense: true),
            items: [
              const DropdownMenuItem(value: null, child: Text('Aucun')),
              for (final p in _plans)
                DropdownMenuItem(value: p['id'] as String,
                    child: Text(p['label']?.toString() ?? p['name']?.toString() ?? '—')),
            ],
            onChanged: (v) => setState(() => _planId = v),
          ),
          if (_planId != null) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Activer ce plan sur la boutique',
                  style: AppTextStyles.body),
              subtitle: Text('Bascule l\'abonnement sur ce plan pour $_months mois',
                  style: AppTextStyles.caption),
              value: _activate,
              onChanged: (v) => setState(() => _activate = v),
            ),
            if (_activate)
              Row(children: [
                Text('Durée :', style: AppTextStyles.bodySm),
                const SizedBox(width: 12),
                for (final m in [1, 3, 12]) ...[
                  ChoiceChip(
                    label: Text(m == 12 ? '1 an' : '$m mois'),
                    selected: _months == m,
                    onSelected: (_) => setState(() => _months = m),
                  ),
                  const SizedBox(width: 6),
                ],
              ]),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _submit,
              style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _saving
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text('Enregistrer le paiement',
                      style: AppTextStyles.label.copyWith(
                          color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}
