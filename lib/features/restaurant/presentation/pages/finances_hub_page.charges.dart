part of 'finances_hub_page.dart';

// L'onglet Charges.

// ═══════════════════════════════════════════════════════════════════════
//  Onglet STOCK (articles sans transformation)
// ═══════════════════════════════════════════════════════════════════════
class _ChargesTab extends StatefulWidget {
  final String shopId;
  const _ChargesTab({required this.shopId});
  @override
  State<_ChargesTab> createState() => _ChargesTabState();
}

class _ChargesTabState extends RestoTabState<_ChargesTab> {
  @override
  String get table => 'fixed_charges';
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final items = FixedChargeService.forShop(widget.shopId);
    return Column(children: [
      headerButton('Charge', () => _edit(null)),
      Expanded(
        child: items.isEmpty
            ? const RestoEmptyState(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Aucune charge fixe',
                subtitle:
                    'Loyer, électricité, salaires… suivez vos échéances récurrentes.',
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _ChargeRow(
                  charge: items[i],
                  onTap: () => _edit(items[i]),
                  onPaid: () => _markPaid(items[i]),
                ),
              ),
      ),
    ]);
  }

  Future<void> _markPaid(FixedCharge c) async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.check_circle_outline,
      title: 'Marquer réglée ?',
      body: Text('« ${c.name} » — échéance du ${restoDayLabel(c.nextDueDate)}. '
          'La prochaine échéance sera calculée automatiquement.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Régler',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await FixedChargeService.markPaid(widget.shopId, c.id);
  }

  Future<void> _edit(FixedCharge? c) async {
    await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => _ChargeEditor(shopId: widget.shopId, existing: c),
    );
    if (mounted) setState(() {});
  }
}

class _ChargeRow extends StatelessWidget {
  final FixedCharge charge;
  final VoidCallback onTap;
  final VoidCallback onPaid;
  const _ChargeRow(
      {required this.charge, required this.onTap, required this.onPaid});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final freq = _kFrequencyLabels[charge.frequency] ?? charge.frequency;
    final cat = _kChargeCategoryLabels[charge.category] ?? charge.category;
    return RestoCard(
      onTap: onTap,
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(charge.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyBold
                          .copyWith(color: cs.onSurface)),
                ),
                if (charge.isCurrentPaid) ...[
                  const SizedBox(width: 6),
                  RestoPill('réglée', sem.success),
                ] else if (charge.isOverdue) ...[
                  const SizedBox(width: 6),
                  RestoPill('en retard', sem.danger),
                ] else if (charge.isDueSoon) ...[
                  const SizedBox(width: 6),
                  RestoPill('bientôt', sem.warning),
                ],
              ]),
              Text(
                  '${CurrencyFormatter.format(charge.amount.toDouble())}'
                  ' · $freq · $cat · échéance ${restoDayLabel(charge.nextDueDate)}',
                  style: AppTextStyles.caption),
            ],
          ),
        ),
        if (!charge.isCurrentPaid)
          IconButton(
            onPressed: onPaid,
            tooltip: 'Marquer réglée',
            icon: Icon(Icons.check_circle_outline, size: 20, color: cs.primary),
          ),
      ]),
    );
  }
}

/// Éditeur charge fixe (création / modification / suppression).
class _ChargeEditor extends StatefulWidget {
  final String shopId;
  final FixedCharge? existing;
  const _ChargeEditor({required this.shopId, this.existing});
  @override
  State<_ChargeEditor> createState() => _ChargeEditorState();
}

class _ChargeEditorState extends State<_ChargeEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _amount = TextEditingController(
      text: widget.existing == null ? '' : '${widget.existing!.amount}');
  late final _alert = TextEditingController(
      text: '${widget.existing?.alertDaysBefore ?? 7}');
  late String _frequency = widget.existing?.frequency ?? 'monthly';
  late String _category = widget.existing?.category ?? 'autre';
  late DateTime _dueDate = widget.existing?.nextDueDate ?? DateTime.now();
  String? _err;
  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _alert.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _dueDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null && mounted) setState(() => _dueDate = d);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _err = 'Nom requis');
      return;
    }
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    final alert = int.tryParse(_alert.text.trim()) ?? 7;
    if (_isEdit) {
      await FixedChargeService.update(widget.existing!.copyWith(
        name: name,
        amount: amount,
        frequency: _frequency,
        nextDueDate: _dueDate,
        alertDaysBefore: alert,
        category: _category,
      ));
    } else {
      await FixedChargeService.create(
        shopId: widget.shopId,
        name: name,
        amount: amount,
        frequency: _frequency,
        nextDueDate: _dueDate,
        alertDaysBefore: alert,
        category: _category,
      );
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer cette charge ?',
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await FixedChargeService.delete(widget.existing!.id, widget.shopId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier la charge' : 'Nouvelle charge',
      icon: Icons.account_balance_wallet_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                controller: _name,
                autofocus: !_isEdit,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Nom')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: restoNumField(_amount, 'Montant (F)')),
              const SizedBox(width: 10),
              Expanded(child: restoNumField(_alert, 'Alerte (j avant)')),
            ]),
            const SizedBox(height: 14),
            Text('Fréquence', style: AppTextStyles.caption),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in _kFrequencyLabels.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: _frequency == e.key,
                  onSelected: (_) => setState(() => _frequency = e.key),
                ),
            ]),
            const SizedBox(height: 14),
            Text('Catégorie', style: AppTextStyles.caption),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in _kChargeCategoryLabels.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: _category == e.key,
                  onSelected: (_) => setState(() => _category = e.key),
                ),
            ]),
            const SizedBox(height: 14),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Prochaine échéance',
                    prefixIcon: Icon(Icons.calendar_today, size: 18)),
                child: Text(restoDayLabel(_dueDate), style: AppTextStyles.body),
              ),
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
                label: _isEdit ? 'Enregistrer' : 'Créer',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: _save),
            if (_isEdit) ...[
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: _delete,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: sem.danger),
                  label: Text('Supprimer',
                      style: AppTextStyles.label.copyWith(color: sem.dangerText)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
