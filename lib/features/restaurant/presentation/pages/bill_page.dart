import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/invoice_printer.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/restaurant_table_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/entities/restaurant_table.dart';

/// Addition d'une table : récapitulatif, partage entre convives et
/// encaissement (module restaurant, PR-3).
///
/// UI dédiée au service en salle. L'encaissement lui-même délègue à la
/// couche données partagée (`updateOrderStatus` via
/// [RestaurantOrderService.settleAndRelease]), qui porte déjà le verrou de
/// transitions, le décrément de stock et le statut de paiement.
class BillPage extends StatefulWidget {
  final String shopId;
  final String tableId;

  const BillPage({
    super.key,
    required this.shopId,
    required this.tableId,
  });

  @override
  State<BillPage> createState() => _BillPageState();
}

class _BillPageState extends State<BillPage> {
  RestaurantTable? _table;
  Sale? _order;

  /// Nombre de parts pour le partage. 1 = pas de partage.
  int _shares = 1;

  bool _settling = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final table = RestaurantTableService.tableById(widget.tableId);
    if (table == null) return;
    final order = RestaurantOrderService.currentOrderFor(table);
    setState(() {
      _table = table;
      _order = order;
      _shares = 1;
    });
  }

  double get _total => _order?.total ?? 0;

  Future<void> _settle() async {
    final table = _table;
    final order = _order;
    if (table == null || order == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Encaisser l\'addition ?'),
        content: Text(
          'Montant : ${CurrencyFormatter.format(_total)}\n\n'
          'La commande sera clôturée et ${table.name} repassera libre.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Encaisser')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _settling = true);
    try {
      final settled = await RestaurantOrderService.settleAndRelease(
        order: order,
        table: table,
      );
      if (!mounted) return;
      AppSnack.success(context, '${table.name} encaissée et libérée');

      // Facture générée automatiquement après encaissement (spec §7).
      if (settled != null) {
        final shop = LocalStorageService.getShop(widget.shopId);
        await InvoicePrinter.printOrShare(
          context: context,
          sale: settled,
          shop: shop,
        );
      }
      if (mounted) context.pop();
    } catch (e) {
      // Remonte tel quel : `updateOrderStatus` lève des exceptions métier
      // explicites (transition interdite, motif requis) dont le message est
      // déjà rédigé pour l'utilisateur.
      if (mounted) AppSnack.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _settling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final table = _table;
    final order = _order;

    if (table == null) {
      return AppScaffold(
        shopId: widget.shopId,
        title: 'Addition',
        isRootPage: false,
        body: const Center(child: Text('Table introuvable.')),
      );
    }
    if (order == null || order.items.isEmpty) {
      return AppScaffold(
        shopId: widget.shopId,
        title: 'Addition — ${table.name}',
        isRootPage: false,
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Aucune commande en cours sur cette table.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Addition — ${table.name}',
      isRootPage: false,
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _TableInfoCard(table: table, order: order),
                const SizedBox(height: 16),
                _ItemsCard(order: order),
                const SizedBox(height: 16),
                _SplitCard(
                  total: _total,
                  covers: order.covers ?? table.capacity,
                  shares: _shares,
                  onSharesChanged: (v) => setState(() => _shares = v),
                ),
              ],
            ),
          ),
          _SettleBar(
            total: _total,
            busy: _settling,
            onSettle: _settle,
          ),
        ],
      ),
    );
  }
}

/// En-tête : couverts, serveur, durée du repas.
class _TableInfoCard extends StatelessWidget {
  final RestaurantTable table;
  final Sale order;

  const _TableInfoCard({required this.table, required this.order});

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    final duration = RestaurantOrderService.mealDuration(table, order);
    final server = order.createdByUserId;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: semantic.borderSubtle),
      ),
      child: Column(
        children: [
          _row(context, Icons.tag_rounded, 'Table', table.name),
          _row(context, Icons.people_rounded, 'Couverts',
              '${order.covers ?? table.covers ?? 1}'),
          if (duration != null)
            _row(context, Icons.access_time_rounded, 'Durée du repas',
                DurationFormatter.compact(duration)),
          if (server != null && server.isNotEmpty)
            _row(context, Icons.person_outline_rounded, 'Serveur', server),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Text(label, style: AppTextStyles.captionHint),
          const Spacer(),
          Text(value, style: AppTextStyles.bodySmBold),
        ],
      ),
    );
  }
}

/// Détail des articles consommés.
class _ItemsCard extends StatelessWidget {
  final Sale order;
  const _ItemsCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: semantic.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Détail', style: AppTextStyles.bodyBold),
          const SizedBox(height: 8),
          for (final item in order.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${item.quantity}×', style: AppTextStyles.bodySmBold),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.productName, style: AppTextStyles.bodySm),
                        if (item.modifiersLabel.isNotEmpty)
                          Text(item.modifiersLabel,
                              style: AppTextStyles.micro.copyWith(
                                  color: semantic.warning)),
                      ],
                    ),
                  ),
                  Text(CurrencyFormatter.format(item.subtotal),
                      style: AppTextStyles.bodySm),
                ],
              ),
            ),
          // Frais éventuels (la commande partage le modèle de la caisse).
          if (order.totalFees > 0) ...[
            const Divider(height: 18),
            Row(
              children: [
                const Expanded(
                    child: Text('Frais', style: AppTextStyles.bodySm)),
                Text(CurrencyFormatter.format(order.totalFees),
                    style: AppTextStyles.bodySm),
              ],
            ),
          ],
          const Divider(height: 18),
          Row(
            children: [
              const Expanded(
                  child: Text('Total', style: AppTextStyles.subtitleBold)),
              Text(CurrencyFormatter.format(order.total),
                  style: AppTextStyles.subtitleBold),
            ],
          ),
        ],
      ),
    );
  }
}

/// Partage de l'addition entre convives.
class _SplitCard extends StatelessWidget {
  final double total;
  final int covers;
  final int shares;
  final ValueChanged<int> onSharesChanged;

  const _SplitCard({
    required this.total,
    required this.covers,
    required this.shares,
    required this.onSharesChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.semantic;
    // Bornes : de 2 parts jusqu'au nombre de couverts (spec). Au minimum 2
    // options proposées même pour une table d'une personne, sinon la carte
    // n'aurait aucun intérêt.
    final maxShares = covers < 2 ? 2 : covers;
    final perPerson = RestaurantOrderService.splitAmount(total, shares);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: semantic.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Partager l\'addition', style: AppTextStyles.bodyBold),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip(context, label: 'Non', value: 1),
              for (var n = 2; n <= maxShares; n++)
                _chip(context, label: '÷ $n', value: n),
            ],
          ),
          if (shares > 1) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text('$shares × ', style: AppTextStyles.bodySecondary),
                Text(CurrencyFormatter.format(perPerson),
                    style: AppTextStyles.subtitleBold
                        .copyWith(color: theme.colorScheme.primary)),
                const Spacer(),
                Text('par personne', style: AppTextStyles.captionHint),
              ],
            ),
            // L'arrondi supérieur fait que N parts peuvent dépasser le total :
            // on l'affiche pour que le serveur sache combien il rend.
            if (perPerson * shares > total)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Soit ${CurrencyFormatter.format(perPerson * shares)} '
                  'encaissés — ${CurrencyFormatter.format(perPerson * shares - total)} '
                  'à rendre.',
                  style: AppTextStyles.micro
                      .copyWith(color: semantic.warning),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required String label, required int value}) {
    final theme = Theme.of(context);
    final sel = shares == value;
    return ChoiceChip(
      label: Text(label),
      selected: sel,
      onSelected: (_) => onSharesChanged(value),
      labelStyle: AppTextStyles.bodySm.copyWith(
        color: sel ? theme.colorScheme.primary : null,
        fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
      ),
    );
  }
}

/// Barre d'encaissement épinglée en bas.
class _SettleBar extends StatelessWidget {
  final double total;
  final bool busy;
  final VoidCallback onSettle;

  const _SettleBar({
    required this.total,
    required this.busy,
    required this.onSettle,
  });

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    return Container(
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        border: Border(top: BorderSide(color: semantic.borderSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: AppPrimaryButton(
            label: 'Encaisser ${CurrencyFormatter.format(total)}',
            icon: Icons.check_circle_outline_rounded,
            fullWidth: true,
            isLoading: busy,
            onTap: onSettle,
          ),
        ),
      ),
    );
  }
}
