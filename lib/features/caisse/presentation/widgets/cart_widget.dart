import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/i18n/app_localizations.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../bloc/caisse_bloc.dart';
import '../../domain/entities/sale_item.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/utils/country_phone_data.dart';
import '../../../../shared/widgets/product_image_smart.dart';
import '../../../crm/domain/entities/client.dart';
import '../../../crm/presentation/pages/clients_page.dart';
import '../../../../shared/widgets/autocomplete_text_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../parametres/data/shop_settings_store.dart';

class CartWidget extends ConsumerWidget {
  final String shopId;
  final bool   isEcommerce;
  const CartWidget({super.key, required this.shopId,
    this.isEcommerce = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final canApplyDiscount = ref.watch(permissionsProvider(shopId)).canApplyDiscount;
    return LayoutBuilder(
        builder: (context, constraints) => BlocBuilder<CaisseBloc, CaisseState>(
          builder: (context, state) => SizedBox(
            height: constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : MediaQuery.of(context).size.height * 0.85,
            child: Column(children: [
              // ── Header ────────────────────────────────────────────────
              _CartHeader(state: state, shopId: shopId),

              // ── Alerte prix ───────────────────────────────────────────
              if (state.priceAlerts.isNotEmpty)
                _PriceAlertBanner(alerts: state.priceAlerts),

              // ── Liste articles ─────────────────────────────────────────
              Expanded(
                child: state.items.isEmpty
                    ? _EmptyCart(l: l)
                    : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  itemCount: state.items.length,
                  separatorBuilder: (_, __) => Divider(
                      height: 1, color: AppColors.divider, indent: 16),
                  itemBuilder: (ctx, i) {
                    final item = state.items[i];
                    return _CartItemRow(
                      item:        item,
                      onDecrement: () => ctx.read<CaisseBloc>().add(
                          UpdateItemQuantity(item.productId, item.quantity - 1)),
                      onIncrement: () => ctx.read<CaisseBloc>().add(
                          UpdateItemQuantity(item.productId, item.quantity + 1)),
                      onEditPrice: () {
                        if (!canApplyDiscount) {
                          AppSnack.error(ctx,
                              'Action réservée : applique une remise '
                              'requiert la permission "sales.discount".');
                          return;
                        }
                        _showPriceEditor(ctx, item);
                      },
                    );
                  },
                ),
              ),

              // ── Frais de commande ─────────────────────────────────────
              if (state.fees.isNotEmpty || state.items.isNotEmpty)
                _FeesSection(shopId: shopId, state: state),

              // ── Client + TVA ──────────────────────────────────────────
              if (state.items.isNotEmpty)
                _ClientTaxSection(shopId: shopId, state: state),

              // ── Récap + bouton ────────────────────────────────────────
              _CartFooter(shopId: shopId, state: state, l: l, isEcommerce: isEcommerce),
            ]),
          ),
        ));
  }

  void _showPriceEditor(BuildContext context, SaleItem item) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _PriceEditorSheet(
        item:   item,
        bloc:   context.read<CaisseBloc>(),
        shopId: shopId,
      ),
    );
  }
}

// ─── Header ───────────────────────────────────────────────────────────────────
class _CartHeader extends StatelessWidget {
  final CaisseState state;
  final String      shopId;
  const _CartHeader({required this.state, required this.shopId});

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;
    final client = state.selectedClient;
    // Mobile : header dense pour libérer de l'espace pour la liste.
    // Desktop : valeurs Material standard.
    final isCompact = MediaQuery.of(context).size.width < 900;
    return Container(
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [

        // ── Titre + badge + vider ──────────────────────────────────
        Padding(
          padding: isCompact
              ? const EdgeInsets.fromLTRB(16, 8, 8, 4)
              : const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(children: [
            Icon(Icons.shopping_cart_outlined,
                size: isCompact ? 15 : 16,
                color: AppColors.textSecondary),
            SizedBox(width: isCompact ? 6 : 8),
            Expanded(child: Text(l.caisseCartTitle,
                style: TextStyle(
                    fontSize: isCompact ? 13 : 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary))),
            if (state.itemCount > 0)
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: isCompact ? 7 : 8,
                    vertical: isCompact ? 2 : 3),
                decoration: BoxDecoration(color: AppColors.primary,
                    borderRadius: BorderRadius.circular(12)),
                child: Text('${state.itemCount}',
                    style: TextStyle(
                        fontSize: isCompact ? 10 : 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            if (state.items.isNotEmpty) ...[
              SizedBox(width: isCompact ? 4 : 8),
              TextButton(
                onPressed: () =>
                    context.read<CaisseBloc>().add(ClearCart()),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.error,
                  padding: EdgeInsets.symmetric(
                      horizontal: isCompact ? 6 : 8,
                      vertical: isCompact ? 2 : 4),
                  minimumSize: Size.zero,
                ),
                child: Text(l.caisseClear,
                    style: TextStyle(fontSize: isCompact ? 11 : 12)),
              ),
            ],
          ]),
        ),

        // ── Zone client ────────────────────────────────────────────
        Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 12, isCompact ? 4 : 10),
          child: GestureDetector(
            onTap: () => _openClientPicker(context),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: EdgeInsets.symmetric(
                  horizontal: isCompact ? 8 : 10,
                  vertical:   isCompact ? 4 : 7),
              decoration: BoxDecoration(
                color: client != null
                    ? AppColors.primarySurface
                    : AppColors.inputFill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: client != null
                      ? AppColors.primary.withOpacity(0.35)
                      : AppColors.divider,
                ),
              ),
              child: Row(children: [
                Container(
                  width:  isCompact ? 22 : 26,
                  height: isCompact ? 22 : 26,
                  decoration: BoxDecoration(
                    color: client != null
                        ? AppColors.primary.withOpacity(0.15)
                        : AppColors.divider,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: client != null
                        ? Text(client.name[0].toUpperCase(),
                            style: TextStyle(
                                fontSize: isCompact ? 11 : 12,
                                fontWeight: FontWeight.w800,
                                color: AppColors.primary))
                        : Icon(Icons.person_add_outlined,
                            size: isCompact ? 12 : 13,
                            color: AppColors.textHint),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: client != null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(client.name,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            if (client.phone != null)
                              Text(client.phone!,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: AppColors.textSecondary)),
                          ])
                      : const Text('Associer un client',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textHint)),
                ),
                if (client != null)
                  GestureDetector(
                    onTap: () => context
                        .read<CaisseBloc>()
                        .add(SetSelectedClient(null)),
                    child: const Icon(Icons.close_rounded,
                        size: 14, color: AppColors.textHint),
                  )
                else
                  Icon(Icons.chevron_right_rounded,
                      size: 16,
                      color: AppColors.primary.withOpacity(0.5)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  void _openClientPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius:
          BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _ClientPickerSheet(
        shopId:   shopId,
        bloc:     context.read<CaisseBloc>(),
        selected: state.selectedClient,
      ),
    );
  }
}

// ─── Alerte prix ──────────────────────────────────────────────────────────────
class _PriceAlertBanner extends StatelessWidget {
  final List<SaleItem> alerts;
  const _PriceAlertBanner({required this.alerts});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AppColors.warning.withOpacity(0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.warning.withOpacity(0.35)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.warning_amber_rounded,
          size: 16, color: AppColors.warning),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Alerte marge',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                      color: AppColors.warning)),
              ...alerts.map((i) => Text(
                '• ${i.productName}${i.variantName != null ? ' — ${i.variantName}' : ''} : '
                    '${CurrencyFormatter.format(i.effectivePrice)} '
                    '(bénéf. < 50% du normal)',
                style: const TextStyle(fontSize: 10,
                    color: AppColors.textPrimary),
              )),
            ]),
      ),
    ]),
  );
}

// ─── Ligne article ────────────────────────────────────────────────────────────
class _CartItemRow extends StatelessWidget {
  final SaleItem     item;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  final VoidCallback onEditPrice;
  const _CartItemRow({
    required this.item,
    required this.onDecrement,
    required this.onIncrement,
    required this.onEditPrice,
  });

  @override
  Widget build(BuildContext context) {
    final hasPriceAlert = item.isPriceAlertTriggered;
    final priceModified = item.customPrice != null;
    // Spec round 9 : compactage mobile. Image 36 (vs 44), variante 9
    // (vs 10), qty 10 (vs 13). Desktop garde les anciennes tailles.
    final isCompact = MediaQuery.of(context).size.width < 900;
    final imageSize = isCompact ? 36.0 : 44.0;
    final variantFs = isCompact ? 9.0 : 10.0;
    final qtyFs     = isCompact ? 10.0 : 13.0;
    final subtotalFs= isCompact ? 11.0 : 12.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        // Image produit
        Container(
          width: imageSize, height: imageSize,
          decoration: BoxDecoration(
            color: AppColors.inputFill,
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: ProductImageSmart(
            url:      item.imageUrl,
            fallback: const _ProductIcon(),
          ),
        ),
        const SizedBox(width: 10),
        // Infos produit
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.productName,
                    style: const TextStyle(fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                if (item.variantName != null)
                  Text(item.variantName!,
                      style: TextStyle(fontSize: variantFs,
                          color: AppColors.primary,
                          fontWeight: FontWeight.w500),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                // Prix + crayon édition
                GestureDetector(
                  onTap: onEditPrice,
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      if (priceModified) ...[
                        Text(CurrencyFormatter.format(item.effectivePrice),
                            style: TextStyle(fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: hasPriceAlert
                                    ? AppColors.warning
                                    : AppColors.primary)),
                        Text(CurrencyFormatter.format(item.unitPrice),
                            style: const TextStyle(fontSize: 9,
                                color: AppColors.textHint,
                                decoration: TextDecoration.lineThrough)),
                      ] else
                        Text(CurrencyFormatter.format(item.unitPrice),
                            style: TextStyle(fontSize: 11,
                                color: AppColors.primary,
                                fontWeight: FontWeight.w600)),
                      Icon(Icons.edit_rounded, size: 10,
                          color: AppColors.primary.withOpacity(0.5)),
                    ],
                  ),
                ),
              ]),
        ),
        const SizedBox(width: 8),
        // Sous-total + stepper
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(CurrencyFormatter.format(item.subtotal),
              style: TextStyle(fontSize: subtotalFs,
                  fontWeight: FontWeight.w700,
                  color: hasPriceAlert
                      ? AppColors.warning
                      : AppColors.primary)),
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(color: AppColors.inputFill,
                borderRadius: BorderRadius.circular(8)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _QtyBtn(icon: Icons.remove_rounded, onTap: onDecrement),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('${item.quantity}',
                    style: TextStyle(fontSize: qtyFs,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
              ),
              _QtyBtn(icon: Icons.add_rounded, onTap: onIncrement),
            ]),
          ),
        ]),
      ]),
    );
  }
}

// ─── Section frais de commande ────────────────────────────────────────────────
class _FeesSection extends StatelessWidget {
  final String shopId;
  final CaisseState state;
  const _FeesSection({required this.shopId, required this.state});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
    decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.local_shipping_outlined,
            size: 13, color: AppColors.textSecondary),
        const SizedBox(width: 6),
        const Expanded(
          child: Text('Frais de commande',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary)),
        ),
        GestureDetector(
          onTap: () => _showAddFeeDialog(context, shopId),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add_rounded, size: 12, color: AppColors.primary),
              const SizedBox(width: 3),
              Text('Ajouter', style: TextStyle(fontSize: 10,
                  fontWeight: FontWeight.w600, color: AppColors.primary)),
            ]),
          ),
        ),
      ]),
      if (state.fees.isNotEmpty) ...[
        const SizedBox(height: 6),
        ...state.fees.map((fee) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: () => _showEditFeeDialog(context, fee, shopId),
                child: Row(children: [
                  Expanded(child: Text(fee.label,
                      style: const TextStyle(fontSize: 11,
                          color: AppColors.textPrimary),
                      overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 4),
                  Icon(Icons.edit_rounded, size: 10,
                      color: AppColors.primary.withOpacity(0.4)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            Text(CurrencyFormatter.format(fee.amount),
                style: const TextStyle(fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => context.read<CaisseBloc>()
                  .add(RemoveOrderFee(fee.id)),
              child: const Icon(Icons.close_rounded,
                  size: 14, color: AppColors.textHint),
            ),
          ]),
        )),
      ],
    ]),
  );

  void _showAddFeeDialog(BuildContext context, String shopId) {
    final labelCtrl  = TextEditingController();
    final amountCtrl = TextEditingController();
    final suggestions = AppDatabase.getDistinctOrderFeeLabels(shopId);
    showDialog(
      context: context,
      builder: (dc) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        title: Row(children: [
          Container(width: 32, height: 32,
              decoration: BoxDecoration(color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.local_shipping_outlined,
                  size: 16, color: AppColors.primary)),
          const SizedBox(width: 10),
          const Text('Ajouter un frais',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          AutocompleteTextField(
            controller:  labelCtrl,
            label:       'Libellé',
            hint:        'Ex: Frais de livraison',
            prefixIcon:  Icons.label_outline_rounded,
            suggestions: suggestions,
          ),
          const SizedBox(height: 10),
          _FeeField(ctrl: amountCtrl, hint: 'Montant (XAF)',
              icon: Icons.payments_outlined, inputType: TextInputType.number),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(dc).pop(),
              child: const Text('Annuler',
                  style: TextStyle(color: AppColors.textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary,
                foregroundColor: Colors.white, elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            onPressed: () {
              final label  = labelCtrl.text.trim();
              final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
              if (label.isEmpty || amount <= 0) return;
              Navigator.of(dc).pop();
              context.read<CaisseBloc>().add(AddOrderFee(OrderFee(
                id:     DateTime.now().millisecondsSinceEpoch.toString(),
                label:  label,
                amount: amount,
              )));
            },
            child: const Text('Ajouter'),
          ),
        ],
      ),
    );
  }

  void _showEditFeeDialog(BuildContext context, OrderFee fee, String shopId) {
    final labelCtrl  = TextEditingController(text: fee.label);
    final amountCtrl = TextEditingController(text: fee.amount.toStringAsFixed(0));
    final suggestions = AppDatabase.getDistinctOrderFeeLabels(shopId);
    showDialog(
      context: context,
      builder: (dc) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        title: const Text('Modifier le frais',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          AutocompleteTextField(
            controller:  labelCtrl,
            label:       'Libellé',
            prefixIcon:  Icons.label_outline_rounded,
            suggestions: suggestions,
          ),
          const SizedBox(height: 10),
          _FeeField(ctrl: amountCtrl, hint: 'Montant (XAF)',
              icon: Icons.payments_outlined, inputType: TextInputType.number),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(dc).pop(),
              child: const Text('Annuler',
                  style: TextStyle(color: AppColors.textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary,
                foregroundColor: Colors.white, elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            onPressed: () {
              final label  = labelCtrl.text.trim();
              final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
              if (label.isEmpty || amount <= 0) return;
              Navigator.of(dc).pop();
              context.read<CaisseBloc>().add(UpdateOrderFee(
                  fee.id, label: label, amount: amount));
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }
}


// ─── Section Client + TVA ─────────────────────────────────────────────────────
class _ClientTaxSection extends StatelessWidget {
  final String      shopId;
  final CaisseState state;
  const _ClientTaxSection({required this.shopId, required this.state});

  @override
  Widget build(BuildContext context) {
    // Lecture du toggle "TVA activée" (Paramètres → Caisse). Quand il est
    // désactivé : la ligne TVA disparaît du panier ET on remet à zéro le
    // taux côté Bloc — sinon un taux saisi avant la désactivation
    // continuerait à gonfler le total via `state.taxAmount`.
    final taxEnabled = ShopSettingsStore(shopId)
        .read<bool>('caisse_tax_enabled', fallback: false) ?? false;
    if (!taxEnabled) {
      if ((state.taxRate) > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          context.read<CaisseBloc>().add(SetTaxRate(0));
        });
      }
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
      decoration: BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.divider))),
      child: _TvaLine(state: state),
    );
  }
}


// ─── Bottom sheet sélection client ───────────────────────────────────────────
class _ClientPickerSheet extends StatefulWidget {
  final String     shopId;
  final CaisseBloc bloc;
  final Client?    selected;
  const _ClientPickerSheet({
    required this.shopId, required this.bloc, this.selected});
  @override
  State<_ClientPickerSheet> createState() => _ClientPickerSheetState();
}

class _ClientPickerSheetState extends State<_ClientPickerSheet> {
  String _query  = '';
  List<Client> _clients = [];

  @override
  void initState() {
    super.initState();
    _clients = AppDatabase.getClientsForShop(widget.shopId);
  }

  List<Client> get _filtered => _query.isEmpty
      ? _clients
      : _clients.where((c) =>
  c.name.toLowerCase().contains(_query.toLowerCase()) ||
      (c.phone?.contains(_query) ?? false)).toList();

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    initialChildSize: 0.65,
    minChildSize:     0.4,
    maxChildSize:     0.9,
    expand: false,
    builder: (_, sc) => Column(children: [
      // Poignée
      Container(
          margin: const EdgeInsets.only(top: 10, bottom: 8),
          width: 36, height: 4,
          decoration: BoxDecoration(
              color: const Color(0xFFDDDDDD),
              borderRadius: BorderRadius.circular(2))),

      // Titre
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(Icons.person_search_rounded,
                  size: 17, color: AppColors.primary)),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Sélectionner un client',
                style: TextStyle(fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
          ),
          // Bouton nouveau client
          GestureDetector(
            onTap: () => _showCreateClient(context),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(8)),
              child: const Row(
                  mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.person_add_rounded,
                    size: 13, color: Colors.white),
                SizedBox(width: 4),
                Text('Nouveau', style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600,
                    color: Colors.white)),
              ]),
            ),
          ),
        ]),
      ),

      // Recherche
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        child: TextField(
          onChanged: (v) => setState(() => _query = v),
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Rechercher par nom ou téléphone…',
            hintStyle: const TextStyle(
                color: Color(0xFFBBBBBB), fontSize: 12),
            prefixIcon: const Icon(Icons.search_rounded,
                size: 16, color: AppColors.textHint),
            filled: true, fillColor: const Color(0xFFF9FAFB),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                    color: AppColors.divider)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                    color: AppColors.divider)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                    color: AppColors.primary, width: 1.5)),
          ),
        ),
      ),
      const Divider(height: 1, color: Color(0xFFF0F0F0)),

      // Liste clients
      Expanded(
        child: _filtered.isEmpty
            ? Center(
            child: Column(
                mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.person_off_outlined,
                  size: 36, color: AppColors.divider),
              const SizedBox(height: 8),
              Text(
                  _query.isEmpty
                      ? 'Aucun client enregistré'
                      : 'Aucun résultat pour "$_query"',
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textHint)),
            ]))
            : ListView.separated(
          controller:  sc,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount:   _filtered.length,
          separatorBuilder: (_, __) => const Divider(
              height: 1, color: AppColors.inputFill,
              indent: 56),
          itemBuilder: (_, i) {
            final c   = _filtered[i];
            final sel = c.id == widget.selected?.id;
            return ListTile(
              dense: true,
              leading: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.1),
                    shape: BoxShape.circle),
                child: Center(child: Text(
                  c.name[0].toUpperCase(),
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary),
                )),
              ),
              title: Text(c.name,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: sel
                          ? FontWeight.w700 : FontWeight.w500,
                      color: sel
                          ? AppColors.primary
                          : AppColors.textPrimary)),
              subtitle: c.phone != null
                  ? Text(c.phone!,
                  style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textHint))
                  : null,
              trailing: sel
                  ? Icon(Icons.check_circle_rounded,
                  color: AppColors.primary, size: 18)
                  : null,
              selected: sel,
              selectedTileColor:
              AppColors.primarySurface,
              onTap: () {
                widget.bloc.add(SetSelectedClient(c));
                Navigator.of(context).pop();
              },
            );
          },
        ),
      ),
    ]),
  );

  void _showCreateClient(BuildContext context) {
    // Capturer le bloc AVANT de fermer le picker
    // (le bloc reste valide même après dispose du picker)
    final bloc     = widget.bloc;
    final shopId   = widget.shopId;

    Navigator.of(context).pop();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showModalBottomSheet(
        context: this.context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
            borderRadius:
            BorderRadius.vertical(top: Radius.circular(20))),
        builder: (ctx) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: ClientFormSheet(
            shopId: shopId,
            onSaved: () {
              Navigator.of(ctx).pop();
              // Récupérer le dernier client créé depuis Hive
              final all = AppDatabase.getClientsForShop(shopId);
              if (all.isNotEmpty) {
                final newest = all.reduce((a, b) =>
                a.createdAt.isAfter(b.createdAt) ? a : b);
                // Sélectionner via le bloc (stable, indépendant du widget tree)
                bloc.add(SetSelectedClient(newest));
              }
            },
          ),
        ),
      );
    });
  }
}

// ─── Footer récap ─────────────────────────────────────────────────────────────
class _CartFooter extends StatelessWidget {
  final String shopId;
  final CaisseState state;
  final AppLocalizations l;
  final bool isEcommerce;
  const _CartFooter({required this.shopId, required this.state,
    required this.l, this.isEcommerce = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.divider))),
    child: Column(children: [
      _Line(l.caisseSubtotal, CurrencyFormatter.format(state.subtotal)),
      if (state.totalFees > 0) ...[
        const SizedBox(height: 4),
        _Line('Frais', CurrencyFormatter.format(state.totalFees)),
      ],
      if (state.discountAmount > 0) ...[
        const SizedBox(height: 4),
        _Line(l.caisseDiscount,
            '- ${CurrencyFormatter.format(state.discountAmount)}',
            color: AppColors.warning),
      ],
      const SizedBox(height: 8),
      Divider(height: 1, color: AppColors.divider),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(l.total.toUpperCase(),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
        Text(CurrencyFormatter.format(state.total),
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800,
                color: AppColors.primary)),
      ]),
      const SizedBox(height: 12),
      // Date à laquelle la commande est censée être livrée (saisie par le
      // client à la création). Persistée sur Sale.scheduledAt. La date
      // RÉELLE de livraison sera capturée plus tard dans le sheet qui
      // s'ouvre quand la commande passe à "complete".
      if (state.items.isNotEmpty) ...[
        _ScheduledDeliveryField(state: state),
        const SizedBox(height: 12),
      ],
      // Le message "Sélectionne un client" est diffusé en tooltip sur le
      // bouton désactivé (tap pour l'afficher) plutôt qu'en texte sous le
      // bouton — moins encombrant dans un panier déjà chargé.
      Tooltip(
        message: state.items.isNotEmpty && state.selectedClient == null
            ? 'Sélectionne un client avant de valider — règle obligatoire.'
            : '',
        triggerMode: TooltipTriggerMode.tap,
        showDuration: const Duration(seconds: 3),
        preferBelow: false,
        decoration: BoxDecoration(
          color: AppColors.warning,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(
            fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
        child: SizedBox(
          width: double.infinity,
          child: Builder(builder: (btnCtx) {
            final isCompact = MediaQuery.of(btnCtx).size.width < 900;
            final iconSize  = isCompact ? 14.0 : 18.0;
            final btnPad    = isCompact
                ? const EdgeInsets.symmetric(vertical: 8)
                : const EdgeInsets.symmetric(vertical: 13);
            final btnMinH   = isCompact
                ? const Size.fromHeight(34)
                : const Size.fromHeight(46);
            final btnRadius = isCompact ? 8.0 : 10.0;
            return isEcommerce
                ? ElevatedButton.icon(
              icon: state.isProcessing
                  ? SizedBox(width: iconSize, height: iconSize,
                  child: const CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                  : Icon(Icons.save_outlined, size: iconSize),
              label: Text(state.orderSaved == true
                  ? (state.editingOrderId != null
                  ? 'Modifications enregistrées ✓'
                  : 'Commande enregistrée ✓')
                  : (state.editingOrderId != null
                  ? 'Mettre à jour la commande'
                  : 'Enregistrer la commande')),
              onPressed: state.items.isEmpty
                      || state.isProcessing
                      || state.orderSaved == true
                      || state.selectedClient == null
                  ? null
                  : () {
                try {
                  context.read<CaisseBloc>().add(SaveOrder(shopId));
                } catch (e) {
                  debugPrint('SaveOrder error: $e');
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: state.orderSaved == true
                    ? AppColors.secondary : AppColors.primary,
                foregroundColor: Colors.white, elevation: 0,
                minimumSize: btnMinH,
                padding: btnPad,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(btnRadius)),
              ),
            )
                : ElevatedButton.icon(
              icon: Icon(Icons.point_of_sale_rounded, size: iconSize),
              label: Text(l.caissePay),
              onPressed: state.items.isEmpty || state.selectedClient == null
                  ? null
                  : () => context.push('/shop/$shopId/caisse/payment'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white, elevation: 0,
                minimumSize: btnMinH,
                padding: btnPad,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(btnRadius)),
              ),
            );
          }),
        ),
      ),
    ]),
  );
}


// ─── Ligne TVA avec édition ─────────────────────────────────────────────────
class _TvaLine extends StatelessWidget {
  final CaisseState state;
  const _TvaLine({required this.state});

  String get _currency {
    try {
      final user = LocalStorageService.getCurrentUser();
      if (user?.phone == null) return 'XAF';
      final sorted = kCountries.toList()
        ..sort((a, b) => b.dialCode.length.compareTo(a.dialCode.length));
      for (final c in sorted) {
        if (user!.phone!.startsWith(c.dialCode)) {
          return switch (c.isoCode) {
            'CM'||'TD'||'CF'||'CG'||'GA'||'GQ' => 'XAF',
            'SN'||'CI'||'BF'||'ML'||'NE'||'TG'||'BJ' => 'XOF',
            'NG' => 'NGN', 'GH' => 'GHS', 'MA' => 'MAD',
            'FR'||'BE'||'DE'||'IT'||'ES' => 'EUR',
            'US' => 'USD', 'GB' => 'GBP',
            _ => 'XAF',
          };
        }
      }
    } catch (_) {}
    return 'XAF';
  }

  void _showTaxDialog(BuildContext context) {
    final rate = state.taxRate ?? 0.0;
    final ctrl = TextEditingController(
        text: rate == 0 ? '' : rate.toStringAsFixed(
            rate % 1 == 0 ? 0 : 2));
    showDialog(
      context: context,
      builder: (dc) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        title: Row(children: [
          Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(Icons.receipt_long_outlined,
                  size: 17, color: AppColors.primary)),
          const SizedBox(width: 10),
          const Text('Taux de TVA',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 4),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(
                RegExp(r'[0-9.]'))],
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              hintText: '0',
              hintStyle: const TextStyle(color: Color(0xFFBBBBBB)),
              suffixText: '%',
              suffixStyle: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary),
              filled: true,
              fillColor: AppColors.primarySurface,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 13),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                      color: AppColors.primary, width: 1.5)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                      color: AppColors.primary.withOpacity(0.3),
                      width: 1)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                      color: AppColors.primary, width: 1.5)),
            ),
          ),
          const SizedBox(height: 8),
          const Text('Laissez vide ou 0 pour aucune TVA',
              style: TextStyle(
                  fontSize: 11, color: AppColors.textHint)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dc).pop(),
              child: const Text('Annuler',
                  style: TextStyle(color: AppColors.textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            onPressed: () {
              final v = double.tryParse(ctrl.text.trim()) ?? 0;
              Navigator.of(dc).pop();
              context.read<CaisseBloc>()
                  .add(SetTaxRate(v.clamp(0, 100)));
            },
            child: const Text('Appliquer'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rate     = state.taxRate ?? 0.0;
    final currency = _currency;
    final amount   = state.taxAmount;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('TVA',
            style: TextStyle(
                fontSize: 12, color: AppColors.textSecondary)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          RichText(
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: TextStyle(
                  fontSize: 12,
                  color: rate > 0
                      ? AppColors.textPrimary
                      : AppColors.textHint),
              children: [
                TextSpan(
                  text: rate == 0
                      ? '0'
                      : '+${CurrencyFormatter.format(amount)}',
                  style: TextStyle(
                      fontWeight: rate > 0
                          ? FontWeight.w600
                          : FontWeight.normal),
                ),
                TextSpan(
                  text: ' $currency',
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w500),
                ),
                if (rate > 0)
                  const TextSpan(
                    text: '  ',
                    style: TextStyle(fontSize: 10),
                  ),
                if (rate > 0)
                  TextSpan(
                    text: '(${rate.toStringAsFixed(rate % 1 == 0 ? 0 : 2)}%)',
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.textHint),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _showTaxDialog(context),
            child: Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                color: AppColors.primarySurface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: AppColors.primary.withOpacity(0.3)),
              ),
              child: Icon(Icons.edit_rounded,
                  size: 12, color: AppColors.primary),
            ),
          ),
        ]),
      ],
    );
  }
}


class _Line extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _Line(this.label, this.value, {this.color});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label, style: TextStyle(fontSize: 12,
          color: color ?? AppColors.textSecondary)),
      Text(value,  style: TextStyle(fontSize: 12,
          color: color ?? AppColors.textPrimary)),
    ],
  );
}

// ─── Sheet édition de prix ────────────────────────────────────────────────────
class _PriceEditorSheet extends ConsumerStatefulWidget {
  final SaleItem   item;
  final CaisseBloc bloc;
  final String     shopId;
  const _PriceEditorSheet({
    required this.item,
    required this.bloc,
    required this.shopId,
  });
  @override
  ConsumerState<_PriceEditorSheet> createState() => _PriceEditorSheetState();
}

enum _MarginStatus { ok, low, below, unknown }

class _PriceEditorSheetState extends ConsumerState<_PriceEditorSheet> {
  static const _minMarginPct = 30.0;

  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
        text: (widget.item.customPrice ?? widget.item.unitPrice)
            .toStringAsFixed(0));
    _ctrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  double get _priceBuy => widget.item.priceBuy;
  double get _minPrice => _priceBuy * (1 + _minMarginPct / 100);

  /// Calcule la marge (%) à partir du prix saisi.
  double? _currentMargin(double price) {
    if (_priceBuy <= 0 || price <= 0) return null;
    return (price - _priceBuy) / price * 100;
  }

  _MarginStatus _status(double? price) {
    if (price == null || price <= 0) return _MarginStatus.unknown;
    if (_priceBuy <= 0) return _MarginStatus.unknown;
    if (price < _priceBuy) return _MarginStatus.below;
    if (price < _minPrice) return _MarginStatus.low;
    return _MarginStatus.ok;
  }

  Color _colorFor(_MarginStatus s) => switch (s) {
    _MarginStatus.ok      => AppColors.secondary,
    _MarginStatus.low     => AppColors.warning,
    _MarginStatus.below   => AppColors.error,
    _MarginStatus.unknown => AppColors.primary,
  };

  /// Dialog de confirmation quand 0 ≤ marge < 30%.
  Future<bool> _confirmLowMargin(double price, double marginPct) async {
    final l = context.l10n;
    return await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
        title: Row(children: [
          Container(width: 32, height: 32,
              decoration: BoxDecoration(
                  color: AppColors.warning.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.warning_amber_rounded,
                  size: 17, color: AppColors.warning)),
          const SizedBox(width: 10),
          Expanded(child: Text(l.priceEditConfirmTitle,
              style: const TextStyle(fontSize: 15,
                  fontWeight: FontWeight.w700))),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.priceEditConfirmBody,
              style: const TextStyle(fontSize: 13, height: 1.4)),
          const SizedBox(height: 10),
          _kvRow(l.priceEditCost,
              CurrencyFormatter.format(_priceBuy),
              AppColors.textSecondary),
          const SizedBox(height: 3),
          _kvRow('${l.priceEditApply} :',
              CurrencyFormatter.format(price),
              AppColors.textPrimary),
          const SizedBox(height: 3),
          _kvRow(l.priceEditMargin,
              '${marginPct.toStringAsFixed(0)}%',
              AppColors.warning),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dc).pop(false),
            child: Text(l.commonCancel,
                style: const TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.warning,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.of(dc).pop(true),
            child: Text(l.priceEditConfirmKeep),
          ),
        ],
      ),
    ) ?? false;
  }

  Widget _kvRow(String label, String value, Color valueColor) =>
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: const TextStyle(fontSize: 12,
            color: AppColors.textSecondary)),
        Text(value, style: TextStyle(fontSize: 12,
            fontWeight: FontWeight.w700, color: valueColor)),
      ]);

  Future<void> _apply() async {
    final v = double.tryParse(_ctrl.text);
    if (v == null || v <= 0) return;
    final s = _status(v);
    // Bloqué : sous le prix de revient
    if (s == _MarginStatus.below) return;
    // Garde défensive : re-vérifier la permission au moment du dispatch.
    // L'UX a déjà été gardée à l'ouverture du sheet (cart_widget), mais
    // on revérifie ici pour couvrir le cas où la permission a changé
    // pendant l'édition (révocation Realtime) ou tout futur call site
    // qui ouvrirait le sheet sans vérifier.
    final canDiscount = ref.read(permissionsProvider(widget.shopId))
        .canApplyDiscount;
    if (!canDiscount) {
      AppSnack.error(context,
          'Action réservée : appliquer une remise requiert la '
          'permission "sales.discount".');
      return;
    }
    // Confirmation si marge basse (entre 0% et 30%)
    if (s == _MarginStatus.low) {
      final margin = _currentMargin(v)!;
      final ok = await _confirmLowMargin(v, margin);
      if (!ok) return;
    }
    widget.bloc.add(UpdateItemPrice(widget.item.productId, v));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l        = context.l10n;
    final original = widget.item.unitPrice;
    final typed    = double.tryParse(_ctrl.text);
    final status   = _status(typed);
    final color    = _colorFor(status);
    final margin   = typed != null ? _currentMargin(typed) : null;
    final costKnown = _priceBuy > 0;

    final message = switch (status) {
      _MarginStatus.ok      => margin != null
          ? l.priceEditMarginOk(margin) : null,
      _MarginStatus.low     => margin != null
          ? l.priceEditMarginLow(margin) : null,
      _MarginStatus.below   => l.priceEditBelowCost,
      _MarginStatus.unknown => null,
    };

    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Poignée
          Center(child: Container(width: 36, height: 4,
              decoration: BoxDecoration(color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),

          // Titre
          Row(children: [
            Container(width: 36, height: 36,
                decoration: BoxDecoration(color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(Icons.price_change_outlined,
                    size: 18, color: AppColors.primary)),
            const SizedBox(width: 10),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${widget.item.productName}'
                  '${widget.item.variantName != null
                      ? ' — ${widget.item.variantName}' : ''}',
                  style: const TextStyle(fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(l.priceEditSubtitle,
                  style: const TextStyle(fontSize: 11,
                      color: AppColors.textHint)),
            ])),
          ]),
          const SizedBox(height: 16),

          // Champ saisie
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(
                RegExp(r'[0-9.]'))],
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              hintText: '0',
              suffixText: 'XAF',
              suffixStyle: TextStyle(fontSize: 13, color: color),
              filled: true,
              fillColor: color.withOpacity(0.06),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 16),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: color, width: 1.5)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                      color: color.withOpacity(0.5), width: 1.5)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: color, width: 2)),
            ),
          ),
          const SizedBox(height: 10),

          // Infos temps réel
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.divider)),
            child: Column(children: [
              _kvRow(l.priceEditOriginal,
                  CurrencyFormatter.format(original),
                  AppColors.textPrimary),
              const SizedBox(height: 4),
              _kvRow(
                l.priceEditCost,
                costKnown
                    ? CurrencyFormatter.format(_priceBuy)
                    : l.priceEditCostUnknown,
                AppColors.textSecondary,
              ),
              if (costKnown) ...[
                const SizedBox(height: 4),
                _kvRow(
                  l.priceEditMinPrice,
                  CurrencyFormatter.format(_minPrice),
                  AppColors.warning,
                ),
                if (margin != null) ...[
                  const SizedBox(height: 4),
                  _kvRow(
                    l.priceEditMargin,
                    '${margin.toStringAsFixed(0)}%',
                    color,
                  ),
                ],
              ],
            ]),
          ),

          // Message d'état
          if (message != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withOpacity(0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withOpacity(0.35)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Icon(
                    status == _MarginStatus.below
                        ? Icons.block_rounded
                        : status == _MarginStatus.low
                            ? Icons.warning_amber_rounded
                            : Icons.check_circle_outline_rounded,
                    size: 14, color: color),
                const SizedBox(width: 6),
                Expanded(child: Text(message,
                    style: TextStyle(fontSize: 11,
                        color: color,
                        fontWeight: FontWeight.w600,
                        height: 1.4))),
              ]),
            ),
          ],
          const SizedBox(height: 16),

          // Boutons
          Row(children: [
            if (widget.item.customPrice != null)
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    widget.bloc.add(UpdateItemPrice(
                        widget.item.productId, null));
                    Navigator.of(context).pop();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.divider),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(l.priceEditReset,
                      style: const TextStyle(fontSize: 13)),
                ),
              ),
            if (widget.item.customPrice != null) const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                // Bouton bloqué uniquement si prix < prix revient
                onPressed: status == _MarginStatus.below ? null : _apply,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      AppColors.primary.withOpacity(0.35),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(l.priceEditApply,
                    style: const TextStyle(fontSize: 14,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ─── Widgets atomiques ────────────────────────────────────────────────────────
class _QtyBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _QtyBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    // Mobile : 24×24 (spec round 9 — densité maximale dans le bottom
    // sheet). Desktop : 48×48 (a11y P0-8 — taille tactile correcte).
    final isCompact = MediaQuery.of(context).size.width < 900;
    final boxSize  = isCompact ? 24.0 : 48.0;
    final iconSize = isCompact ? 14.0 : 20.0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: BoxConstraints(minWidth: boxSize, minHeight: boxSize),
        decoration: BoxDecoration(color: Colors.white,
            borderRadius: BorderRadius.circular(isCompact ? 7 : 8),
            border: Border.all(color: AppColors.divider)),
        child: Icon(icon, size: iconSize, color: AppColors.textPrimary),
      ),
    );
  }
}

class _FeeField extends StatelessWidget {
  final TextEditingController ctrl;
  final String hint;
  final IconData icon;
  final TextInputType inputType;
  const _FeeField({required this.ctrl, required this.hint,
    required this.icon, required this.inputType});
  @override
  Widget build(BuildContext context) => TextField(
    controller: ctrl,
    keyboardType: inputType,
    inputFormatters: inputType == TextInputType.number
        ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
        : null,
    style: const TextStyle(fontSize: 13),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 12),
      prefixIcon: Icon(icon, size: 16, color: const Color(0xFFAAAAAA)),
      filled: true, fillColor: const Color(0xFFF9FAFB), isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.divider)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.divider)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
    ),
  );
}

class _EmptyCart extends StatelessWidget {
  final AppLocalizations l;
  const _EmptyCart({required this.l});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.shopping_cart_outlined,
          size: 40, color: AppColors.divider),
      const SizedBox(height: 10),
      Text(l.caisseEmpty,
          style: const TextStyle(fontSize: 13,
              color: AppColors.textHint)),
    ]),
  );
}

class _ProductIcon extends StatelessWidget {
  const _ProductIcon();
  @override
  Widget build(BuildContext context) => const Center(
    child: Icon(Icons.inventory_2_outlined,
        size: 20, color: AppColors.textHint),
  );
}

// ─── Date de livraison prévue (cliquable, optionnel) ───────────────────────
// Représente la date que le client a demandée pour être livré.
// Persistée sur Sale.scheduledAt. La date RÉELLE de livraison (constatée
// au moment où la commande passe à `completed`) est saisie séparément dans
// le DeliveryDetailsSheet.
class _ScheduledDeliveryField extends StatelessWidget {
  final CaisseState state;
  const _ScheduledDeliveryField({required this.state});

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: state.deliveryDate ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      locale: const Locale('fr', 'FR'),
    );
    if (picked == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(state.deliveryDate
          ?? DateTime(picked.year, picked.month, picked.day, 14)),
    );
    if (!context.mounted) return;
    final date = DateTime(picked.year, picked.month, picked.day,
        time?.hour ?? 14, time?.minute ?? 0);
    context.read<CaisseBloc>().add(SetDeliveryDate(date));
  }

  String _format(DateTime d) {
    const days   = ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'];
    const months = ['jan', 'fév', 'mar', 'avr', 'mai', 'juin',
                    'juil', 'août', 'sep', 'oct', 'nov', 'déc'];
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]} · $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final has = state.deliveryDate != null;
    return InkWell(
      onTap: () => _pickDate(context),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: has
              ? AppColors.primary.withOpacity(0.06)
              : const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: has
                ? AppColors.primary.withOpacity(0.30)
                : AppColors.divider,
          ),
        ),
        child: Row(children: [
          Icon(Icons.event_rounded,
              size: 16,
              color: has ? AppColors.primary : AppColors.textHint),
          const SizedBox(width: 8),
          Expanded(child: Text(
              has
                  ? 'Livraison prévue : ${_format(state.deliveryDate!)}'
                  : 'Date de livraison souhaitée (optionnel)',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: has ? FontWeight.w600 : FontWeight.w400,
                  color: has
                      ? AppColors.primary : AppColors.textSecondary))),
          if (has)
            InkWell(
              onTap: () =>
                  context.read<CaisseBloc>().add(SetDeliveryDate(null)),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close_rounded,
                    size: 14, color: AppColors.textHint),
              ),
            )
          else
            const Icon(Icons.chevron_right_rounded,
                size: 16, color: AppColors.textHint),
        ]),
      ),
    );
  }
}

