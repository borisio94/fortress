import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/restaurant_table_service.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../widgets/kitchen_ticket_card.dart';

/// Écran Cuisine — les bons envoyés et pas encore prêts (module restaurant).
///
/// Conçu pour une tablette posée en cuisine : gros tickets, lecture à
/// distance, une seule action par bon. Aucun widget de la caisse e-commerce
/// n'est réutilisé.
class KitchenPage extends StatefulWidget {
  final String shopId;

  const KitchenPage({super.key, required this.shopId});

  @override
  State<KitchenPage> createState() => _KitchenPageState();
}

class _KitchenPageState extends State<KitchenPage> {
  late final OnDataChanged _listener;
  Timer? _ticker;

  /// Articles cochés « prêt », par commande. Purement local et volontairement
  /// NON persisté : c'est une aide visuelle pour le cuisinier pendant le
  /// dressage, pas un état métier. La seule transition persistée est
  /// « commande prête » (`kitchen_ready`).
  final Map<String, Set<int>> _checked = {};

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
    // Rafraîchit les minuteurs. 10 s suffit : les seuils sont à 8 et 15 min,
    // une seconde de précision n'apporterait rien et réveillerait l'écran
    // en continu.
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    _ticker?.cancel();
    super.dispose();
  }

  List<Sale> get _tickets =>
      RestaurantOrderService.kitchenTickets(widget.shopId);

  /// Nom de la table d'un bon, ou libellé de repli pour une commande à
  /// emporter (qui n'a pas de table).
  String _tableLabel(Sale order) {
    final id = order.tableId;
    if (id == null || id.isEmpty) return 'À emporter';
    return RestaurantTableService.tableById(id)?.name ?? 'Table';
  }

  Future<void> _markReady(Sale order) async {
    await RestaurantOrderService.markKitchenReady(order);
    if (!mounted) return;
    setState(() => _checked.remove(order.id));
    AppSnack.success(context, '${_tableLabel(order)} — prête à servir');
  }

  @override
  Widget build(BuildContext context) {
    final tickets = _tickets;
    return AppScaffold(
      title: 'Cuisine',
      shopId: widget.shopId,
      body: tickets.isEmpty
          ? const EmptyStateWidget(
              icon: Icons.restaurant_rounded,
              title: 'Aucun bon en cours',
              subtitle: 'Les commandes envoyées en cuisine apparaîtront ici, '
                  'du plus ancien au plus récent.',
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                // Tickets larges (~320 dp) : lisibles à distance sur une
                // tablette de cuisine, une seule colonne sur téléphone.
                final columns = (constraints.maxWidth / 320).floor().clamp(1, 4);
                return GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: tickets.length,
                  itemBuilder: (_, i) {
                    final t = tickets[i];
                    final id = t.id ?? '';
                    return KitchenTicketCard(
                      order: t,
                      tableLabel: _tableLabel(t),
                      checked: _checked[id] ?? const {},
                      onToggleItem: (index) => setState(() {
                        final set = _checked.putIfAbsent(id, () => <int>{});
                        if (!set.remove(index)) set.add(index);
                      }),
                      onReady: () => _markReady(t),
                    );
                  },
                );
              },
            ),
    );
  }
}

