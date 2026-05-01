import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../data/shop_settings_store.dart';
import '../widgets/settings_widgets.dart';

class NotificationsPage extends ConsumerStatefulWidget {
  final String shopId;
  const NotificationsPage({super.key, required this.shopId});

  @override
  ConsumerState<NotificationsPage> createState() =>
      _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  late final ShopSettingsStore _store = ShopSettingsStore(widget.shopId);

  final _bigSaleCtrl = TextEditingController();

  bool _stockLow = true;
  bool _newSale = false;
  bool _bigSale = true;
  bool _daily = true;
  bool _sound = true;
  bool _vibration = true;

  @override
  void initState() {
    super.initState();
    _stockLow  = _store.read<bool>('notif_stock_low', fallback: true) ?? true;
    _newSale   = _store.read<bool>('notif_new_sale', fallback: false) ?? false;
    _bigSale   = _store.read<bool>('notif_big_sale', fallback: true) ?? true;
    _daily     = _store.read<bool>('notif_daily', fallback: true) ?? true;
    _sound     = _store.read<bool>('notif_sound', fallback: true) ?? true;
    _vibration = _store.read<bool>('notif_vibration', fallback: true) ?? true;
    final amount = _store.read<num>('notif_big_sale_amount', fallback: 100000) ?? 100000;
    _bigSaleCtrl.text = amount.toString();
  }

  @override
  void dispose() {
    _bigSaleCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await _store.write('notif_stock_low', _stockLow);
    await _store.write('notif_new_sale', _newSale);
    await _store.write('notif_big_sale', _bigSale);
    await _store.write('notif_big_sale_amount',
        num.tryParse(_bigSaleCtrl.text.trim()) ?? 0);
    await _store.write('notif_daily', _daily);
    await _store.write('notif_sound', _sound);
    await _store.write('notif_vibration', _vibration);
    if (mounted) AppSnack.success(context, context.l10n.commonSaved);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AppScaffold(
      shopId: widget.shopId,
      title: l.notifsTitle,
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Header(title: l.notifsTitle, subtitle: l.notifsSubtitle),
          const SizedBox(height: 14),
          SettingsSectionCard(title: l.paramBoutique, children: [
            SettingsSwitchTile(
              label: l.notifsStockLow,
              hint: l.notifsStockLowHint,
              value: _stockLow,
              onChanged: (v) => setState(() => _stockLow = v),
            ),
            SettingsSwitchTile(
              label: l.notifsNewSale,
              hint: l.notifsNewSaleHint,
              value: _newSale,
              onChanged: (v) => setState(() => _newSale = v),
            ),
            SettingsSwitchTile(
              label: l.notifsBigSale,
              hint: l.notifsBigSaleHint,
              value: _bigSale,
              onChanged: (v) => setState(() => _bigSale = v),
            ),
            if (_bigSale)
              SettingsField(
                label: l.notifsBigSaleAmount,
                controller: _bigSaleCtrl,
                keyboardType: TextInputType.number,
                hint: '100000',
              ),
            SettingsSwitchTile(
              label: l.notifsDaily,
              hint: l.notifsDailyHint,
              value: _daily,
              onChanged: (v) => setState(() => _daily = v),
            ),
          ]),
          const SizedBox(height: 12),
          SettingsSectionCard(title: l.paramPreferences, children: [
            SettingsSwitchTile(
              label: l.notifsSound,
              value: _sound,
              onChanged: (v) => setState(() => _sound = v),
            ),
            SettingsSwitchTile(
              label: l.notifsVibration,
              value: _vibration,
              onChanged: (v) => setState(() => _vibration = v),
            ),
          ]),
          const SizedBox(height: 20),
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
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  const _Header({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.primary, AppColors.primaryLight],
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const SizedBox(height: 4),
            Text(subtitle,
                style: TextStyle(
                    fontSize: 12, color: Colors.white.withOpacity(0.85))),
          ],
        ),
      );
}
