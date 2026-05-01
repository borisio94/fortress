import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/app_switch.dart';
import '../../data/shop_settings_store.dart';
import '../widgets/settings_widgets.dart';

class PaymentsPage extends ConsumerStatefulWidget {
  final String shopId;
  const PaymentsPage({super.key, required this.shopId});

  @override
  ConsumerState<PaymentsPage> createState() => _PaymentsPageState();
}

class _PaymentsPageState extends ConsumerState<PaymentsPage> {
  late final ShopSettingsStore _store = ShopSettingsStore(widget.shopId);

  final _mtnAccountCtrl = TextEditingController();
  final _orangeAccountCtrl = TextEditingController();
  final _bankAccountCtrl = TextEditingController();

  bool _cash = true;
  bool _mtn = false;
  bool _orange = false;
  bool _card = false;
  bool _bank = false;
  bool _check = false;
  bool _credit = false;

  String _defaultMethod = 'cash';

  @override
  void initState() {
    super.initState();
    _cash   = _store.read<bool>('pay_cash',   fallback: true)  ?? true;
    _mtn    = _store.read<bool>('pay_mtn',    fallback: false) ?? false;
    _orange = _store.read<bool>('pay_orange', fallback: false) ?? false;
    _card   = _store.read<bool>('pay_card',   fallback: false) ?? false;
    _bank   = _store.read<bool>('pay_bank',   fallback: false) ?? false;
    _check  = _store.read<bool>('pay_check',  fallback: false) ?? false;
    _credit = _store.read<bool>('pay_credit', fallback: false) ?? false;
    _mtnAccountCtrl.text    = _store.read<String>('pay_mtn_account', fallback: '') ?? '';
    _orangeAccountCtrl.text = _store.read<String>('pay_orange_account', fallback: '') ?? '';
    _bankAccountCtrl.text   = _store.read<String>('pay_bank_account', fallback: '') ?? '';
    _defaultMethod = _store.read<String>('pay_default', fallback: 'cash') ?? 'cash';
  }

  @override
  void dispose() {
    _mtnAccountCtrl.dispose();
    _orangeAccountCtrl.dispose();
    _bankAccountCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await _store.write('pay_cash', _cash);
    await _store.write('pay_mtn', _mtn);
    await _store.write('pay_orange', _orange);
    await _store.write('pay_card', _card);
    await _store.write('pay_bank', _bank);
    await _store.write('pay_check', _check);
    await _store.write('pay_credit', _credit);
    await _store.write('pay_mtn_account', _mtnAccountCtrl.text.trim());
    await _store.write('pay_orange_account', _orangeAccountCtrl.text.trim());
    await _store.write('pay_bank_account', _bankAccountCtrl.text.trim());
    await _store.write('pay_default', _defaultMethod);
    if (mounted) AppSnack.success(context, context.l10n.commonSaved);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final perms = ref.watch(permissionsProvider(widget.shopId));
    final canEdit = perms.canEditShopInfo;

    final methods = <_MethodEntry>[
      _MethodEntry(
        id: 'cash',
        icon: Icons.payments_rounded,
        color: const Color(0xFF10B981),
        label: l.paymentCash,
        value: _cash,
        onChanged: (v) => setState(() => _cash = v),
      ),
      _MethodEntry(
        id: 'mtn',
        icon: Icons.phone_android_rounded,
        color: const Color(0xFFFFC107),
        label: l.paymentMobileMoney,
        value: _mtn,
        onChanged: (v) => setState(() => _mtn = v),
        accountCtrl: _mtnAccountCtrl,
      ),
      _MethodEntry(
        id: 'orange',
        icon: Icons.phone_android_rounded,
        color: const Color(0xFFFF6D00),
        label: l.paymentOrangeMoney,
        value: _orange,
        onChanged: (v) => setState(() => _orange = v),
        accountCtrl: _orangeAccountCtrl,
      ),
      _MethodEntry(
        id: 'card',
        icon: Icons.credit_card_rounded,
        color: const Color(0xFF3B82F6),
        label: l.paymentCard,
        value: _card,
        onChanged: (v) => setState(() => _card = v),
      ),
      _MethodEntry(
        id: 'bank',
        icon: Icons.account_balance_rounded,
        color: const Color(0xFF6366F1),
        label: l.paymentBank,
        value: _bank,
        onChanged: (v) => setState(() => _bank = v),
        accountCtrl: _bankAccountCtrl,
      ),
      _MethodEntry(
        id: 'check',
        icon: Icons.receipt_long_rounded,
        color: const Color(0xFF8B5CF6),
        label: l.paymentCheck,
        value: _check,
        onChanged: (v) => setState(() => _check = v),
      ),
      _MethodEntry(
        id: 'credit',
        icon: Icons.handshake_rounded,
        color: const Color(0xFFEF4444),
        label: l.paymentCredit,
        value: _credit,
        onChanged: (v) => setState(() => _credit = v),
      ),
    ];

    final activeMethods = methods.where((m) => m.value).toList();

    return AppScaffold(
      shopId: widget.shopId,
      title: l.paymentsTitle,
      isRootPage: false,
      body: AbsorbPointer(
        absorbing: !canEdit,
        child: Opacity(
          opacity: canEdit ? 1 : 0.55,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!canEdit) const ReadOnlyBanner(),
              SettingsSectionCard(
                title: l.paymentsSubtitle,
                children: methods.map((m) => _MethodRow(entry: m)).toList(),
              ),
              if (activeMethods.isNotEmpty) ...[
                const SizedBox(height: 12),
                SettingsSectionCard(
                  title: l.paymentDefault,
                  children: activeMethods
                      .map((m) => RadioListTile<String>(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(m.label,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                            activeColor: AppColors.primary,
                            value: m.id,
                            groupValue: _defaultMethod,
                            onChanged: (v) => setState(
                                () => _defaultMethod = v ?? _defaultMethod),
                          ))
                      .toList(),
                ),
              ],
              const SizedBox(height: 20),
              if (canEdit)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _save,
                    child: Text(l.commonSave),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MethodEntry {
  final String id;
  final IconData icon;
  final Color color;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final TextEditingController? accountCtrl;
  const _MethodEntry({
    required this.id,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.onChanged,
    this.accountCtrl,
  });
}

class _MethodRow extends StatelessWidget {
  final _MethodEntry entry;
  const _MethodRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: entry.color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(entry.icon, color: entry.color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(entry.label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            AppSwitch(value: entry.value, onChanged: entry.onChanged),
          ]),
          if (entry.value && entry.accountCtrl != null)
            Padding(
              padding: const EdgeInsets.only(left: 48, top: 4),
              child: SettingsField(
                label: l.paymentAccountNumber,
                controller: entry.accountCtrl!,
                keyboardType: TextInputType.phone,
              ),
            ),
        ],
      ),
    );
  }
}
