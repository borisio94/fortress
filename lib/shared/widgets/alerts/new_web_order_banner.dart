import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/new_web_order_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../features/caisse/domain/entities/sale.dart';
import '../../providers/new_web_orders_provider.dart';

/// Bannière persistante (44 px) qui signale les nouvelles commandes
/// reçues via le lien catalogue public (source='web') tant que l'owner /
/// admin ne les a pas acquittées.
///
/// Différence avec [ScheduledOrderBanner] (alertes de proximité d'heure
/// de livraison) : ici on signale UNIQUEMENT le canal d'arrivée — pas
/// d'escalade temporelle. Une commande est visible dès son INSERT et
/// disparait au clic sur « Vu ».
///
/// Comportement :
///   * 1 commande → résume client + total
///   * N commandes → résume « N nouvelles commandes web »
///   * Bouton « Voir » → page caisse (toutes les commandes scheduled)
///   * Bouton « ✓ Vu » → acquitte toutes les commandes web actuelles
class NewWebOrderBanner extends ConsumerWidget {
  const NewWebOrderBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(newWebOrdersProvider).valueOrNull ?? const [];
    if (orders.isEmpty) return const SizedBox.shrink();

    final n = orders.length;
    final label = n == 1
        ? _singleLabel(orders.first)
        : '$n nouvelles commandes web';

    return Material(
      color: AppColors.secondary,
      child: SafeArea(
        top:    false,
        bottom: false,
        child: SizedBox(
          height: 44,
          child: Row(children: [
            const SizedBox(width: 14),
            const Icon(Icons.shopping_bag_rounded,
                size: 18, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color:      Colors.white,
                  fontSize:   13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            // Bouton "Voir" — redirige vers la liste des commandes du shop.
            // Si la commande appartient à un autre shop (multi-boutique),
            // l'utilisateur devra changer de shop manuellement.
            TextButton(
              onPressed: () => _onView(context, orders.first.shopId),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Voir',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            // Bouton "Vu" — acquitte toutes les commandes courantes.
            IconButton(
              tooltip: n == 1
                  ? 'Marquer comme vue'
                  : 'Tout marquer comme vu',
              icon: const Icon(Icons.check_rounded,
                  size: 18, color: Colors.white),
              onPressed: NewWebOrderService.instance.acknowledgeAll,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
            const SizedBox(width: 4),
          ]),
        ),
      ),
    );
  }

  String _singleLabel(Sale s) {
    final name  = s.clientName?.trim();
    final total = s.total.toStringAsFixed(0);
    final who   = (name == null || name.isEmpty) ? 'Client web' : name;
    return 'Nouvelle commande web · $who · $total XAF';
  }

  void _onView(BuildContext context, String shopId) {
    // Navigue vers la page caisse du shop concerné — c'est là que la
    // commande scheduled apparaît dans la liste des commandes en cours.
    context.go('/shop/$shopId/caisse');
  }
}
