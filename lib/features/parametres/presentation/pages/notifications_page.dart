import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
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

  // ── Section "Alertes commandes programmées" (sprint 2B) ────────────
  // Toutes les valeurs sont DEVICE-WIDE (pas par-shop) → persistées dans
  // HiveBoxes.settingsBox direct. TODO: granularité per-shop dans futur
  // sprint si demande utilisateur (ex: marchand qui ne vend pas le matin
  // dans une boutique précise).
  bool _alertEnabled        = true;
  bool _alertModalEnabled   = true;
  bool _alertBannerEnabled  = true;
  bool _alertFaviconEnabled = true;
  bool _alertSoundEnabled   = true;
  bool _alertTitleFlashEnabled = true;
  double _alertVolume = 0.7;
  String _alertSoundChoice = 'bell'; // bell | siren | notification
  // Seuils (5)
  bool _alertThresholdInfo            = true;
  bool _alertThresholdWarning         = true;
  bool _alertThresholdCritical        = true;
  bool _alertThresholdCriticalRepeat  = true;
  bool _alertThresholdMax             = true;

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

    // Section alertes — lecture device-wide depuis settingsBox.
    final s = HiveBoxes.settingsBox;
    bool readBool(String k, {bool defaultValue = true}) =>
        (s.get(k, defaultValue: defaultValue) as bool?) ?? defaultValue;
    _alertEnabled               = readBool('alert_enabled');
    _alertModalEnabled          = readBool('alert_modal_enabled');
    _alertBannerEnabled         = readBool('alert_banner_enabled');
    _alertFaviconEnabled        = readBool('alert_favicon_enabled');
    _alertSoundEnabled          = readBool('alert_sound_enabled');
    _alertTitleFlashEnabled     = readBool('alert_title_flash_enabled');
    _alertThresholdInfo         = readBool('alert_threshold_info');
    _alertThresholdWarning      = readBool('alert_threshold_warning');
    _alertThresholdCritical     = readBool('alert_threshold_critical');
    _alertThresholdCriticalRepeat = readBool('alert_threshold_criticalRepeat');
    _alertThresholdMax          = readBool('alert_threshold_max');
    final vol = s.get('alert_volume', defaultValue: 0.7);
    _alertVolume = vol is num ? vol.toDouble().clamp(0.0, 1.0) : 0.7;
    _alertSoundChoice = s.get('alert_sound_choice', defaultValue: 'bell')
        as String? ?? 'bell';
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

    // Section alertes — persistance device-wide.
    final s = HiveBoxes.settingsBox;
    await s.put('alert_enabled',                   _alertEnabled);
    await s.put('alert_modal_enabled',             _alertModalEnabled);
    await s.put('alert_banner_enabled',            _alertBannerEnabled);
    await s.put('alert_favicon_enabled',           _alertFaviconEnabled);
    await s.put('alert_sound_enabled',             _alertSoundEnabled);
    await s.put('alert_title_flash_enabled',       _alertTitleFlashEnabled);
    await s.put('alert_threshold_info',            _alertThresholdInfo);
    await s.put('alert_threshold_warning',         _alertThresholdWarning);
    await s.put('alert_threshold_critical',        _alertThresholdCritical);
    await s.put('alert_threshold_criticalRepeat',  _alertThresholdCriticalRepeat);
    await s.put('alert_threshold_max',             _alertThresholdMax);
    await s.put('alert_volume',                    _alertVolume);
    await s.put('alert_sound_choice',              _alertSoundChoice);

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
          const SizedBox(height: 12),
          // ── Section "Alertes commandes programmées" (sprint 2B) ──
          _buildScheduledAlertsSection(context, l),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primaryFill,
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

  Widget _buildScheduledAlertsSection(BuildContext context, AppLocalizations l) {
    final sem = Theme.of(context).semantic;
    return SettingsSectionCard(
      title: l.settingsScheduledAlerts,
      children: [
        // Master toggle
        SettingsSwitchTile(
          label: l.settingsScheduledAlerts,
          value: _alertEnabled,
          onChanged: (v) => setState(() => _alertEnabled = v),
        ),
        if (_alertEnabled) ...[
          const Divider(height: 24),
          // Hint AudioContext non unlocké (web only)
          if (kIsWeb)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: sem.warningSurface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: sem.warning.withValues(alpha: 0.4)),
              ),
              child: Row(children: [
                Icon(Icons.touch_app_rounded,
                    size: 16, color: sem.warningText),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  l.scheduledAlertEnableSoundHint,
                  style: AppTextStyles.caption.copyWith(color: sem.warningText),
                )),
              ]),
            ),
          // Sous-section : Comportement
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
            child: Text(l.settingsAlertThresholds.replaceFirst(
                'Seuils', 'Comportement').replaceFirst(
                'Alert thresholds', 'Behavior'),
                style: AppTextStyles.captionBold.copyWith(
                    letterSpacing: 0.4,
                    color: Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.55))),
          ),
          SettingsSwitchTile(
            label: l.settingsAlertModalEnabled,
            value: _alertModalEnabled,
            onChanged: (v) => setState(() => _alertModalEnabled = v),
          ),
          SettingsSwitchTile(
            label: l.settingsAlertBanner,
            value: _alertBannerEnabled,
            onChanged: (v) => setState(() => _alertBannerEnabled = v),
          ),
          if (kIsWeb)
            SettingsSwitchTile(
              label: l.settingsAlertFavicon,
              value: _alertFaviconEnabled,
              onChanged: (v) => setState(() => _alertFaviconEnabled = v),
            ),
          SettingsSwitchTile(
            label: l.settingsAlertSoundEnabled,
            value: _alertSoundEnabled,
            onChanged: (v) => setState(() => _alertSoundEnabled = v),
          ),
          if (kIsWeb)
            SettingsSwitchTile(
              label: l.settingsAlertTitleFlash,
              value: _alertTitleFlashEnabled,
              onChanged: (v) => setState(() => _alertTitleFlashEnabled = v),
            ),
          // Sous-section : Son
          if (_alertSoundEnabled) ...[
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(l.settingsAlertSound,
                  style: AppTextStyles.captionBold.copyWith(
                      letterSpacing: 0.4,
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.55))),
            ),
            // Volume
            Row(children: [
              Text(l.settingsAlertVolume,
                  style: AppTextStyles.body),
              Expanded(child: Slider(
                value: _alertVolume,
                onChanged: (v) => setState(() => _alertVolume = v),
                divisions: 20,
                label: '${(_alertVolume * 100).round()}%',
              )),
              SizedBox(width: 36, child: Text(
                  '${(_alertVolume * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: AppTextStyles.bodySm)),
            ]),
            const SizedBox(height: 4),
            // Dropdown son d'alarme.
            // TODO: mapping alert_sound_choice → asset path quand sons
            // supplémentaires fournis (actuellement un seul mp3 strong).
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: DropdownButtonFormField<String>(
                value: _alertSoundChoice,
                decoration: InputDecoration(
                  labelText: l.settingsAlertSound,
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                items: [
                  DropdownMenuItem(
                      value: 'bell', child: Text(l.soundChoiceBell)),
                  DropdownMenuItem(
                      value: 'siren', child: Text(l.soundChoiceSiren)),
                  DropdownMenuItem(
                      value: 'notification',
                      child: Text(l.soundChoiceNotification)),
                ],
                onChanged: (v) =>
                    setState(() => _alertSoundChoice = v ?? 'bell'),
              ),
            ),
          ],
          const Divider(height: 24),
          // Sous-section : Seuils d'alerte
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(l.settingsAlertThresholds,
                style: AppTextStyles.captionBold.copyWith(
                    letterSpacing: 0.4,
                    color: Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.55))),
          ),
          SettingsSwitchTile(
            label: 'J-1 (07h00)',
            value: _alertThresholdInfo,
            onChanged: (v) => setState(() => _alertThresholdInfo = v),
          ),
          SettingsSwitchTile(
            label: 'H-2',
            value: _alertThresholdWarning,
            onChanged: (v) => setState(() => _alertThresholdWarning = v),
          ),
          SettingsSwitchTile(
            label: 'H-1',
            value: _alertThresholdCritical,
            onChanged: (v) => setState(() => _alertThresholdCritical = v),
          ),
          SettingsSwitchTile(
            label: 'H-30min (rappel)',
            value: _alertThresholdCriticalRepeat,
            onChanged: (v) =>
                setState(() => _alertThresholdCriticalRepeat = v),
          ),
          SettingsSwitchTile(
            label: 'H-15min (max)',
            value: _alertThresholdMax,
            onChanged: (v) => setState(() => _alertThresholdMax = v),
          ),
        ],
      ],
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
                style: AppTextStyles.subtitleBold.copyWith(
                    color: Colors.white)),
            const SizedBox(height: 4),
            Text(subtitle,
                style: AppTextStyles.bodySm.copyWith(
                    color: Colors.white.withValues(alpha:0.85))),
          ],
        ),
      );
}
