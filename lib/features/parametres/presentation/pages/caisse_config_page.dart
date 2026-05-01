import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/whatsapp/message_templates.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../data/shop_settings_store.dart';
import '../widgets/settings_widgets.dart';

class CaisseConfigPage extends ConsumerStatefulWidget {
  final String shopId;
  const CaisseConfigPage({super.key, required this.shopId});

  @override
  ConsumerState<CaisseConfigPage> createState() => _CaisseConfigPageState();
}

class _CaisseConfigPageState extends ConsumerState<CaisseConfigPage> {
  late final ShopSettingsStore _store = ShopSettingsStore(widget.shopId);

  final _headerCtrl = TextEditingController();
  final _footerCtrl = TextEditingController();
  final _taxRateCtrl = TextEditingController();
  final _prefixCtrl = TextEditingController();

  bool _autoPrint = false;
  bool _taxEnabled = false;
  bool _quickSale = true;
  bool _confirmDelete = true;
  WhatsappMessageStyle _whatsappStyle = WhatsappMessageStyle.standard;

  @override
  void initState() {
    super.initState();
    _headerCtrl.text  = _store.read<String>('caisse_header', fallback: '') ?? '';
    _footerCtrl.text  = _store.read<String>('caisse_footer',
        fallback: 'Merci de votre visite !') ?? '';
    _taxRateCtrl.text = (_store.read<num>('caisse_tax_rate', fallback: 19.25) ?? 19.25).toString();
    _prefixCtrl.text  = _store.read<String>('caisse_order_prefix', fallback: 'CMD-') ?? 'CMD-';
    _autoPrint        = _store.read<bool>('caisse_auto_print', fallback: false) ?? false;
    _taxEnabled       = _store.read<bool>('caisse_tax_enabled', fallback: false) ?? false;
    _quickSale        = _store.read<bool>('caisse_quick_sale', fallback: true) ?? true;
    _confirmDelete    = _store.read<bool>('caisse_confirm_delete', fallback: true) ?? true;
    _whatsappStyle    = WhatsappMessageStyleX.fromKey(
        _store.read<String>('whatsapp_message_style', fallback: 'standard'));
  }

  @override
  void dispose() {
    _headerCtrl.dispose();
    _footerCtrl.dispose();
    _taxRateCtrl.dispose();
    _prefixCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await _store.write('caisse_header', _headerCtrl.text.trim());
    await _store.write('caisse_footer', _footerCtrl.text.trim());
    await _store.write('caisse_tax_rate',
        double.tryParse(_taxRateCtrl.text.replaceAll(',', '.')) ?? 0);
    await _store.write('caisse_order_prefix', _prefixCtrl.text.trim());
    await _store.write('caisse_auto_print', _autoPrint);
    await _store.write('caisse_tax_enabled', _taxEnabled);
    await _store.write('caisse_quick_sale', _quickSale);
    await _store.write('caisse_confirm_delete', _confirmDelete);
    await _store.write('whatsapp_message_style', _whatsappStyle.key);
    if (mounted) AppSnack.success(context, context.l10n.commonSaved);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final perms = ref.watch(permissionsProvider(widget.shopId));
    final canEdit = perms.canEditShopInfo;

    return AppScaffold(
      shopId: widget.shopId,
      title: l.caisseConfigTitle,
      isRootPage: false,
      body: AbsorbPointer(
        absorbing: !canEdit,
        child: Opacity(
          opacity: canEdit ? 1 : 0.55,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!canEdit) const ReadOnlyBanner(),
              SettingsSectionCard(title: l.caisseReceipt, children: [
                SettingsField(
                  label: l.caisseReceiptHeader,
                  controller: _headerCtrl,
                  hint: 'Fortress SARL',
                ),
                SettingsField(
                  label: l.caisseReceiptFooter,
                  controller: _footerCtrl,
                  hint: l.caisseReceiptFooter,
                  maxLines: 2,
                ),
                SettingsSwitchTile(
                  label: l.caisseAutoPrint,
                  hint: l.caisseAutoPrintHint,
                  value: _autoPrint,
                  onChanged: (v) => setState(() => _autoPrint = v),
                ),
              ]),
              const SizedBox(height: 12),
              SettingsSectionCard(title: l.caisseTaxes, children: [
                SettingsSwitchTile(
                  label: l.caisseTaxEnabled,
                  value: _taxEnabled,
                  onChanged: (v) => setState(() => _taxEnabled = v),
                ),
                if (_taxEnabled)
                  SettingsField(
                    label: l.caisseTaxRate,
                    controller: _taxRateCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    hint: '19.25',
                  ),
              ]),
              const SizedBox(height: 12),
              SettingsSectionCard(title: l.caisseOrderNumber, children: [
                SettingsField(
                  label: l.caisseOrderPrefix,
                  controller: _prefixCtrl,
                  hint: 'CMD-',
                ),
              ]),
              const SizedBox(height: 12),
              SettingsSectionCard(title: l.caisseShortcuts, children: [
                SettingsSwitchTile(
                  label: l.caisseQuickSale,
                  value: _quickSale,
                  onChanged: (v) => setState(() => _quickSale = v),
                ),
                SettingsSwitchTile(
                  label: l.caisseConfirmDelete,
                  value: _confirmDelete,
                  onChanged: (v) => setState(() => _confirmDelete = v),
                ),
              ]),
              const SizedBox(height: 12),
              SettingsSectionCard(
                title: l.whatsappStyleSection,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(l.whatsappStyleHint,
                        style: TextStyle(fontSize: 11,
                            color: AppColors.textSecondary)),
                  ),
                  _StyleRadio(
                    label:    l.whatsappStyleStandard,
                    hint:     l.whatsappStyleStandardHint,
                    selected: _whatsappStyle == WhatsappMessageStyle.standard,
                    onTap:    () => setState(() =>
                        _whatsappStyle = WhatsappMessageStyle.standard),
                  ),
                  _StyleRadio(
                    label:    l.whatsappStyleShort,
                    hint:     l.whatsappStyleShortHint,
                    selected: _whatsappStyle == WhatsappMessageStyle.short,
                    onTap:    () => setState(() =>
                        _whatsappStyle = WhatsappMessageStyle.short),
                  ),
                  _StyleRadio(
                    label:    l.whatsappStylePremium,
                    hint:     l.whatsappStylePremiumHint,
                    selected: _whatsappStyle == WhatsappMessageStyle.premium,
                    onTap:    () => setState(() =>
                        _whatsappStyle = WhatsappMessageStyle.premium),
                  ),
                  const SizedBox(height: 12),
                  _StylePreview(
                    label: l.whatsappStylePreview,
                    text:  MessageTemplates.preview(_whatsappStyle),
                  ),
                ],
              ),
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

// ─── Tuile radio pour un style de message WhatsApp ──────────────────────────
class _StyleRadio extends StatelessWidget {
  final String label;
  final String hint;
  final bool   selected;
  final VoidCallback onTap;
  const _StyleRadio({
    required this.label, required this.hint,
    required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.primary.withOpacity(0.06)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected
              ? AppColors.primary
              : AppColors.divider,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(children: [
        Icon(
          selected
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_off_rounded,
          size: 18,
          color: selected ? AppColors.primary : AppColors.textHint,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? AppColors.primary
                        : AppColors.textPrimary,
                  )),
              const SizedBox(height: 2),
              Text(hint,
                  style: TextStyle(fontSize: 11,
                      color: AppColors.textSecondary)),
            ],
          ),
        ),
      ]),
    ),
  );
}

// ─── Aperçu du message — bulle "WhatsApp" ────────────────────────────────────
class _StylePreview extends StatelessWidget {
  final String label;
  final String text;
  const _StylePreview({required this.label, required this.text});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label.toUpperCase(),
          style: TextStyle(fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: AppColors.textSecondary)),
      const SizedBox(height: 6),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.inputFill,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.divider),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 12,
                height: 1.4,
                color: AppColors.textPrimary)),
      ),
    ],
  );
}
