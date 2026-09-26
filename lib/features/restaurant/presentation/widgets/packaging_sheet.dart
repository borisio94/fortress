import 'package:flutter/material.dart';

import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/stock_item_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/stock_item.dart';
import '../../../../core/widgets/touch_target.dart';
import 'resto_empty_state.dart';

/// EMBALLAGES d'une commande — barquettes, sachets, boîtes.
///
/// Ouvert À LA DEMANDE, jamais d'office : sur place, l'emballage est
/// l'exception, et imposer cette feuille à chaque encaissement ralentirait
/// tout le service pour un cas minoritaire.
///
/// Deux effets à la validation, et ils vont ensemble :
///   * chaque emballage devient une LIGNE DE FRAIS de la commande, donc
///     s'ajoute au total facturé — conformément à la règle « plus rien n'est
///     absorbé par la boutique » ;
///   * son STOCK est décrémenté. Avec les boissons, les emballages sont
///     aujourd'hui les deux seules choses dont le stock bouge à la vente : les
///     plats n'en ont pas, et les ingrédients ne se décrémentent plus depuis le
///     passage à la répartition au prorata.
///
/// Choisis par le RESTAURANT, jamais par le client : cette feuille ne vit que
/// dans les écrans internes, rien n'en transparaît côté catalogue public.
///
/// Retourne le nombre d'emballages facturés.
Future<int?> showPackagingSheet({
  required BuildContext context,
  required String shopId,
  required Sale order,

  /// Adapte le propos : sur une table, on emballe des RESTES ; au comptoir,
  /// c'est la commande entière qui part.
  bool isLeftovers = false,
}) =>
    showAdaptiveFormSheet<int>(
      context: context,
      builder: (_) => _PackagingSheet(
          shopId: shopId, order: order, isLeftovers: isLeftovers),
    );

class _PackagingSheet extends StatefulWidget {
  final String shopId;
  final Sale order;
  final bool isLeftovers;

  const _PackagingSheet({
    required this.shopId,
    required this.order,
    required this.isLeftovers,
  });

  @override
  State<_PackagingSheet> createState() => _PackagingSheetState();
}

class _PackagingSheetState extends State<_PackagingSheet> {
  late final List<StockItem> _items = StockItemService.sellable(widget.shopId);

  /// Quantité retenue par emballage.
  final Map<String, int> _qty = {};

  /// Prix unitaire retenu — pré-rempli avec le prix de vente de l'article,
  /// modifiable : une grande barquette se négocie parfois sur le moment.
  late final Map<String, int> _price = {
    for (final i in _items) i.id: i.sellingPrice,
  };

  bool _saving = false;

  int get _total => _qty.entries
      .fold<int>(0, (s, e) => s + e.value * (_price[e.key] ?? 0));

  int get _count => _qty.values.fold<int>(0, (s, v) => s + v);

  void _bump(StockItem item, int delta) {
    setState(() {
      final next = (_qty[item.id] ?? 0) + delta;
      if (next <= 0) {
        _qty.remove(item.id);
      } else {
        _qty[item.id] = next;
      }
    });
  }

  Future<void> _editPrice(StockItem item) async {
    final ctrl =
        TextEditingController(text: '${_price[item.id] ?? item.sellingPrice}');
    final value = await showAdaptiveFormSheet<int>(
      context: context,
      builder: (ctx) => AdaptiveFormFrame(
        title: item.name,
        subtitle: 'Prix unitaire',
        icon: Icons.payments_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AppField(
              controller: ctrl,
              hint: '${item.sellingPrice}',
              numbersOnly: true,
              keyboardType: TextInputType.number,
              autofocus: true,
            ),
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Valider',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(ctx)
                  .pop(int.tryParse(ctrl.text.trim()) ?? item.sellingPrice),
            ),
          ]),
        ),
      ),
    );
    ctrl.dispose();
    if (value == null || !mounted) return;
    setState(() => _price[item.id] = value < 0 ? 0 : value);
  }

  Future<void> _confirm() async {
    if (_qty.isEmpty) return;
    setState(() => _saving = true);
    var order = widget.order;
    var billed = 0;
    for (final entry in _qty.entries) {
      final item = _items.firstWhere((i) => i.id == entry.key);
      final qty = entry.value;
      final unit = _price[entry.key] ?? item.sellingPrice;
      try {
        // Le stock D'ABORD : c'est le fait matériel — l'emballage est parti,
        // qu'on parvienne ou non à le facturer.
        await StockItemService.consume(
            widget.shopId, item.id, qty.toDouble());
        if (unit > 0) {
          order = await RestaurantOrderService.addFee(
            order,
            label: qty > 1 ? '${item.name} ×$qty' : item.name,
            amount: (unit * qty).toDouble(),
          );
        }
        billed += qty;
      } catch (e) {
        // Un emballage qui échoue n'empêche pas les autres : mieux vaut une
        // facture partielle qu'un service bloqué.
        debugPrint('[Packaging] ${item.name}: $e');
      }
    }
    if (mounted) Navigator.of(context).pop(billed);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;

    return AdaptiveFormFrame(
      title: widget.isLeftovers ? 'Emballer des restes' : 'Emballages',
      subtitle: _count == 0
          ? null
          : '$_count emballage(s) · ${CurrencyFormatter.format(_total.toDouble())}',
      icon: Icons.takeout_dining_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_items.isEmpty)
              const RestoEmptyNote(
                  'Aucun emballage facturable. Créez vos barquettes et vos '
                  'sachets dans Finances → Fournitures, avec un prix de '
                  'vente — c\'est lui qui les rend proposables ici.')
            else ...[
              Text(
                  'Ce que vous ajoutez est facturé au client et retiré de '
                  'votre stock.',
                  style: AppTextStyles.captionHint),
              const SizedBox(height: 12),
              for (final item in _items)
                _PackagingRow(
                  item: item,
                  quantity: _qty[item.id] ?? 0,
                  unitPrice: _price[item.id] ?? item.sellingPrice,
                  onMinus: () => _bump(item, -1),
                  onPlus: () => _bump(item, 1),
                  onEditPrice: () => _editPrice(item),
                ),
              const Divider(height: 20),
              Row(children: [
                Expanded(
                  child: Text('Total emballages',
                      style: AppTextStyles.bodySm
                          .copyWith(color: cs.onSurface)),
                ),
                Text(CurrencyFormatter.format(_total.toDouble()),
                    style: AppTextStyles.subtitleBold
                        .copyWith(color: cs.onSurface)),
              ]),
              if (_count > 0) ...[
                const SizedBox(height: 6),
                Text(
                    'Ajouté au total de la commande, et déduit de votre stock.',
                    style:
                        AppTextStyles.caption.copyWith(color: sem.warningText)),
              ],
              const SizedBox(height: 16),
              AppPrimaryButton(
                label: 'Confirmer les emballages',
                icon: Icons.check_rounded,
                fullWidth: true,
                isLoading: _saving,
                enabled: _count > 0,
                onTap: _confirm,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Une ligne : nom, stock restant, compteur, prix modifiable, sous-total.
class _PackagingRow extends StatelessWidget {
  final StockItem item;
  final int quantity;
  final int unitPrice;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback onEditPrice;

  const _PackagingRow({
    required this.item,
    required this.quantity,
    required this.unitPrice,
    required this.onMinus,
    required this.onPlus,
    required this.onEditPrice,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    // Le stock RESTANT est affiché : sans lui, on facture des barquettes
    // qu'on n'a plus, et l'écart n'apparaît qu'au comptage suivant.
    final remaining = item.quantity - quantity;
    final short = remaining < 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      AppTextStyles.bodySmBold.copyWith(color: cs.onSurface)),
              InkWell(
                onTap: onEditPrice,
                child: Text(
                    '$unitPrice F · reste ${_fmt(remaining)} ${item.unit}',
                    style: AppTextStyles.caption.copyWith(
                        color: short ? sem.dangerText : null)),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: quantity > 0 ? onMinus : null,
          visualDensity: compactUnlessTouch,
          icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
        ),
        SizedBox(
          width: 22,
          child: Text('$quantity',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
        ),
        IconButton(
          onPressed: onPlus,
          visualDensity: compactUnlessTouch,
          icon: Icon(Icons.add_circle_outline_rounded,
              size: 20, color: cs.primary),
        ),
      ]),
    );
  }

  /// Quantité lisible, sans « .0 » superflu.
  static String _fmt(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}
