import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/empty_state_widget.dart';

/// Commandes à emporter (module restaurant, PR-4).
///
/// Regroupe les commandes `order_type = 'takeaway'` encore ouvertes, qu'elles
/// viennent du catalogue web (le client commande en ligne, paie au retrait)
/// ou du comptoir. La sonnerie d'arrivée est déjà gérée en amont par
/// `NewWebOrderService` — inutile de la redéclencher ici, ce qui produirait
/// un double bip quand les deux écrans sont ouverts.
class TakeawayPage extends StatefulWidget {
  final String shopId;

  const TakeawayPage({super.key, required this.shopId});

  @override
  State<TakeawayPage> createState() => _TakeawayPageState();
}

class _TakeawayPageState extends State<TakeawayPage> {
  late final OnDataChanged _listener;

  @override
  void initState() {
    super.initState();
    _listener = (table, sid) {
      if (!mounted) return;
      if (table != 'orders') return;
      if (sid != widget.shopId) return;
      setState(() {});
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  List<Sale> get _orders =>
      RestaurantOrderService.takeawayOrders(widget.shopId);

  Future<void> _sendToKitchen(Sale order) async {
    await RestaurantOrderService.sendToKitchen(order);
    if (!mounted) return;
    AppSnack.success(context, 'Envoyée en cuisine');
  }

  Future<void> _markCollected(Sale order) async {
    try {
      await RestaurantOrderService.collectTakeaway(order);
      if (!mounted) return;
      AppSnack.success(context, 'Commande remise et encaissée');
    } catch (e) {
      // `updateOrderStatus` lève des exceptions métier au message déjà
      // rédigé pour l'utilisateur (transition interdite, motif requis).
      if (mounted) AppSnack.error(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final orders = _orders;
    return AppScaffold(
      title: 'À emporter',
      shopId: widget.shopId,
      body: orders.isEmpty
          ? const EmptyStateWidget(
              icon: Icons.shopping_bag_outlined,
              title: 'Aucune commande à emporter',
              subtitle: 'Les commandes passées depuis le catalogue en ligne '
                  'apparaîtront ici, avec une alerte sonore.',
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: orders.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _TakeawayCard(
                order: orders[i],
                onSendToKitchen: () => _sendToKitchen(orders[i]),
                onCollected: () => _markCollected(orders[i]),
              ),
            ),
    );
  }
}

/// Carte d'une commande à emporter.
class _TakeawayCard extends StatelessWidget {
  final Sale order;
  final VoidCallback onSendToKitchen;
  final VoidCallback onCollected;

  const _TakeawayCard({
    required this.order,
    required this.onSendToKitchen,
    required this.onCollected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.semantic;
    final waiting = DateTime.now().difference(order.createdAt);
    final isWeb = order.source == 'web';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: semantic.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isWeb ? Icons.language_rounded : Icons.storefront_outlined,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  order.clientName?.isNotEmpty == true
                      ? order.clientName!
                      : 'Client',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyBold,
                ),
              ),
              Text(DurationFormatter.compact(waiting),
                  style: AppTextStyles.caption.copyWith(
                      color: waiting.inMinutes >= 15
                          ? semantic.danger
                          : semantic.warning)),
            ],
          ),
          if (order.clientPhone?.isNotEmpty == true)
            Text(order.clientPhone!, style: AppTextStyles.captionHint),
          const SizedBox(height: 8),
          for (final item in order.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text('${item.quantity}×', style: AppTextStyles.bodySmBold),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.productName, style: AppTextStyles.bodySm),
                        if (item.modifiersLabel.isNotEmpty)
                          Text(item.modifiersLabel,
                              style: AppTextStyles.micro
                                  .copyWith(color: semantic.warning)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 16),
          Row(
            children: [
              Text(CurrencyFormatter.format(order.total),
                  style: AppTextStyles.subtitleBold
                      .copyWith(color: theme.colorScheme.primary)),
              const Spacer(),
              if (!order.sentToKitchen)
                TextButton.icon(
                  onPressed: onSendToKitchen,
                  icon: const Icon(Icons.restaurant_rounded, size: 16),
                  label: const Text('Cuisine'),
                  style: TextButton.styleFrom(
                      minimumSize: const Size(0, 38)),
                )
              else if (!order.kitchenReady)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('En préparation',
                      style: AppTextStyles.caption
                          .copyWith(color: semantic.warning)),
                ),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: onCollected,
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('Remise'),
                style: FilledButton.styleFrom(
                  backgroundColor: semantic.success,
                  // Hauteur explicite : le thème global impose un
                  // minimumSize infini qui casserait la rangée.
                  minimumSize: const Size(0, 38),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
