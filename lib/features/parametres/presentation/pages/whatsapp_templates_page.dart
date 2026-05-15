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

// ═════════════════════════════════════════════════════════════════════════════
// WhatsAppTemplatesPage — éditeur des libellés courts utilisés dans tous les
// messages WhatsApp envoyés depuis l'app.
//
// Tous les messages suivent le format `<libellé> : <url>`. Le libellé est
// le call-to-action que verra le destinataire (ex: « Téléchargez votre
// facture », « Voir la commande »).
//
// 5 libellés éditables :
//   • facture       — envoi du PDF facture après une vente
//   • commande      — relance d'une commande programmée non livrée
//   • catalogue     — partage du catalogue produits avec un client
//   • nouveautés    — annonce de nouveaux produits (réservé)
//   • promotion     — annonce d'une campagne promo (réservé)
//
// Persistance : ShopSettingsStore avec clés `wa_label_*` (cf.
// [WaTemplateKeys]). Bouton de réinitialisation par défaut sur chaque champ.
// ═════════════════════════════════════════════════════════════════════════════

class WhatsAppTemplatesPage extends ConsumerStatefulWidget {
  final String shopId;
  const WhatsAppTemplatesPage({super.key, required this.shopId});

  @override
  ConsumerState<WhatsAppTemplatesPage> createState() =>
      _WhatsAppTemplatesPageState();
}

class _WhatsAppTemplatesPageState
    extends ConsumerState<WhatsAppTemplatesPage> {
  late final ShopSettingsStore _store = ShopSettingsStore(widget.shopId);

  final _invoiceCtrl   = TextEditingController();
  final _orderCtrl     = TextEditingController();
  final _catalogueCtrl = TextEditingController();
  final _newsCtrl      = TextEditingController();
  final _promoCtrl     = TextEditingController();

  @override
  void initState() {
    super.initState();
    _invoiceCtrl.text   = _store.read<String>(WaTemplateKeys.invoice,
        fallback: WaTemplateDefaults.invoice) ?? WaTemplateDefaults.invoice;
    _orderCtrl.text     = _store.read<String>(WaTemplateKeys.order,
        fallback: WaTemplateDefaults.order) ?? WaTemplateDefaults.order;
    _catalogueCtrl.text = _store.read<String>(WaTemplateKeys.catalogue,
        fallback: WaTemplateDefaults.catalogue) ?? WaTemplateDefaults.catalogue;
    _newsCtrl.text      = _store.read<String>(WaTemplateKeys.news,
        fallback: WaTemplateDefaults.news) ?? WaTemplateDefaults.news;
    _promoCtrl.text     = _store.read<String>(WaTemplateKeys.promo,
        fallback: WaTemplateDefaults.promo) ?? WaTemplateDefaults.promo;
  }

  @override
  void dispose() {
    _invoiceCtrl.dispose();
    _orderCtrl.dispose();
    _catalogueCtrl.dispose();
    _newsCtrl.dispose();
    _promoCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await _store.write(WaTemplateKeys.invoice,   _invoiceCtrl.text.trim());
    await _store.write(WaTemplateKeys.order,     _orderCtrl.text.trim());
    await _store.write(WaTemplateKeys.catalogue, _catalogueCtrl.text.trim());
    await _store.write(WaTemplateKeys.news,      _newsCtrl.text.trim());
    await _store.write(WaTemplateKeys.promo,     _promoCtrl.text.trim());
    if (mounted) AppSnack.success(context, context.l10n.commonSaved);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final perms = ref.watch(permissionsProvider(widget.shopId));
    final canEdit = perms.canEditShopInfo;

    return AppScaffold(
      shopId: widget.shopId,
      title: l.waTemplatesTitle,
      isRootPage: false,
      body: AbsorbPointer(
        absorbing: !canEdit,
        child: Opacity(
          opacity: canEdit ? 1 : 0.55,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!canEdit) const ReadOnlyBanner(),
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 16, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(l.waTemplatesIntro,
                            style: const TextStyle(
                                fontSize: 12, height: 1.4)),
                      ),
                    ],
                  ),
                ),
              ),
              _TemplateCard(
                title:        l.waTemplatesInvoice,
                hint:         l.waTemplatesInvoiceHint,
                controller:   _invoiceCtrl,
                defaultLabel: WaTemplateDefaults.invoice,
                onChanged:    () => setState(() {}),
              ),
              const SizedBox(height: 10),
              _TemplateCard(
                title:        l.waTemplatesOrder,
                hint:         l.waTemplatesOrderHint,
                controller:   _orderCtrl,
                defaultLabel: WaTemplateDefaults.order,
                onChanged:    () => setState(() {}),
              ),
              const SizedBox(height: 10),
              _TemplateCard(
                title:        l.waTemplatesCatalogue,
                hint:         l.waTemplatesCatalogueHint,
                controller:   _catalogueCtrl,
                defaultLabel: WaTemplateDefaults.catalogue,
                onChanged:    () => setState(() {}),
              ),
              const SizedBox(height: 10),
              _TemplateCard(
                title:        l.waTemplatesNews,
                hint:         l.waTemplatesNewsHint,
                controller:   _newsCtrl,
                defaultLabel: WaTemplateDefaults.news,
                onChanged:    () => setState(() {}),
              ),
              const SizedBox(height: 10),
              _TemplateCard(
                title:        l.waTemplatesPromo,
                hint:         l.waTemplatesPromoHint,
                controller:   _promoCtrl,
                defaultLabel: WaTemplateDefaults.promo,
                onChanged:    () => setState(() {}),
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

class _TemplateCard extends StatelessWidget {
  final String              title;
  final String              hint;
  final TextEditingController controller;
  final String              defaultLabel;
  final VoidCallback        onChanged;
  const _TemplateCard({
    required this.title,
    required this.hint,
    required this.controller,
    required this.defaultLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final label = controller.text.trim().isEmpty
        ? defaultLabel
        : controller.text.trim();
    final preview = '$label : https://exemple.com/abc';
    return SettingsSectionCard(
      title: title,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(hint,
              style: TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
        ),
        Row(children: [
          Expanded(
            child: SettingsField(
              label: l.waTemplatesFieldLabel,
              controller: controller,
              hint: defaultLabel,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: l.waTemplatesReset,
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            color: AppColors.textSecondary,
            onPressed: () {
              controller.text = defaultLabel;
              onChanged();
            },
          ),
        ]),
        const SizedBox(height: 8),
        _Preview(text: preview),
      ],
    );
  }
}

class _Preview extends StatelessWidget {
  final String text;
  const _Preview({required this.text});
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.waTemplatesPreview.toUpperCase(),
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: AppColors.textSecondary)),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFDCF8C6),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFB7E6A6)),
          ),
          child: Text(text,
              style: const TextStyle(fontSize: 12, height: 1.4)),
        ),
      ],
    );
  }
}
