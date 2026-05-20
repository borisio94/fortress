import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/services/scheduled_order_alert_service.dart';
import '../../../features/caisse/domain/entities/sale.dart';
import '../../../features/caisse/domain/entities/sale_item.dart';
import 'favicon_blinker.dart'
    if (dart.library.html) 'favicon_blinker_web.dart';
import 'scheduled_order_banner.dart';
import 'scheduled_order_modal.dart';

/// Page interne de démo pour valider visuellement les composants d'alerte
/// AVANT le sprint 2B (branchement global).
///
/// Accessible via la route `/dev/alerts-demo` mais uniquement en
/// `kDebugMode` (cf. router) — ne fuite pas en production.
///
/// Permet de :
///   * Afficher le banner pour chaque niveau (warning, critical, max, overdue)
///   * Ouvrir la modal pour 1 ou 3 commandes simulées
///   * Tester le FaviconBlinker (start/stop) sur web
class AlertDemoPage extends StatefulWidget {
  const AlertDemoPage({super.key});

  @override
  State<AlertDemoPage> createState() => _AlertDemoPageState();
}

class _AlertDemoPageState extends State<AlertDemoPage> {
  AlertLevel _selectedLevel = AlertLevel.critical;
  bool _faviconActive = false;

  Sale _fakeOrder({
    required String id,
    required String name,
    required Duration deltaFromNow,
  }) =>
      Sale(
        id:             id,
        shopId:         'demo_shop',
        items: [
          SaleItem(
            productId:    'p1',
            productName:  'Sac à main rouge',
            variantName:  'Taille M',
            unitPrice:    15000,
            quantity:     2,
          ),
          SaleItem(
            productId:    'p2',
            productName:  'Ceinture cuir',
            unitPrice:    12000,
            quantity:     1,
          ),
          SaleItem(
            productId:    'p3',
            productName:  'Foulard soie',
            unitPrice:    8000,
            quantity:     1,
          ),
        ],
        paymentMethod:  PaymentMethod.cash,
        status:         SaleStatus.scheduled,
        clientName:     name,
        clientPhone:    '+237 6 95 12 34 56',
        createdAt:      DateTime.now(),
        scheduledAt:    DateTime.now().add(deltaFromNow),
        deliveryAddress:'Rue 12, Bonapriso',
        deliveryCity:   'Douala',
        deliveryMode:   DeliveryMode.partner,
      );

  Duration _deltaForLevel(AlertLevel lvl) {
    switch (lvl) {
      case AlertLevel.info:           return const Duration(hours: 8);
      case AlertLevel.warning:        return const Duration(minutes: 90);
      case AlertLevel.critical:       return const Duration(minutes: 47);
      case AlertLevel.criticalRepeat: return const Duration(minutes: 22);
      case AlertLevel.max:            return const Duration(minutes: 8);
      case AlertLevel.overdue:        return const Duration(minutes: -12);
    }
  }

  AlertInfo _fakeAlert(Sale s, AlertLevel lvl) => AlertInfo(
        orderId:      s.id ?? 'x',
        shopId:       s.shopId,
        level:        lvl,
        scheduledAt:  s.scheduledAt!,
        triggeredAt:  s.scheduledAt!,
        customerName: s.clientName,
        acknowledged: false,
      );

  @override
  Widget build(BuildContext context) {
    // Garde-fou : si on est arrivé ici par accident en release, on bloque.
    if (!kDebugMode) {
      return const Scaffold(
        body: Center(child: Text('Demo page disabled in release builds')),
      );
    }

    final order = _fakeOrder(
      id:           'demo_${_selectedLevel.name}',
      name:         'Marie Dupont',
      deltaFromNow: _deltaForLevel(_selectedLevel),
    );
    final alert = _fakeAlert(order, _selectedLevel);

    return Scaffold(
      appBar: AppBar(title: const Text('Alerts demo (debug)')),
      body: Column(children: [
        ScheduledOrderBanner(
          alerts:        [alert],
          ordersById:    {order.id!: order},
          onViewPressed: () => _openModal(context, [order]),
        ),
        Expanded(child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Niveau d\'alerte simulé',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final lvl in AlertLevel.values)
                  ChoiceChip(
                    label: Text(lvl.name),
                    selected: _selectedLevel == lvl,
                    onSelected: (_) => setState(() => _selectedLevel = lvl),
                  ),
              ]),
              const Divider(height: 32),
              const Text('Modal',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: () => _openModal(context, [order]),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Ouvrir modal — 1 commande'),
              ),
              const SizedBox(height: 6),
              ElevatedButton.icon(
                onPressed: () => _openModal(context, [
                  order,
                  _fakeOrder(
                      id: 'demo_2', name: 'Paul Mbarga',
                      deltaFromNow: const Duration(minutes: 35)),
                  _fakeOrder(
                      id: 'demo_3', name: 'Aïcha Ntolo',
                      deltaFromNow: const Duration(minutes: 11)),
                ]),
                icon: const Icon(Icons.view_carousel_rounded),
                label: const Text('Ouvrir modal — 3 commandes (carrousel)'),
              ),
              const Divider(height: 32),
              const Text('Favicon + title flashing (web only)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text(
                'Cliquez "Démarrer", puis basculez sur un autre onglet : '
                'le favicon clignote + le titre alterne avec "⚠ COMMANDE — Marie".',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 8),
              Row(children: [
                ElevatedButton.icon(
                  onPressed: _faviconActive
                      ? null
                      : () {
                          FaviconBlinker.start(
                              flashPrefix: '⚠ COMMANDE — ',
                              suffix:      'Marie Dupont');
                          setState(() => _faviconActive = true);
                        },
                  icon: const Icon(Icons.notifications_active_rounded),
                  label: const Text('Démarrer'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _faviconActive
                      ? () {
                          FaviconBlinker.stop();
                          setState(() => _faviconActive = false);
                        }
                      : null,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Arrêter'),
                ),
              ]),
            ],
          ),
        )),
      ]),
    );
  }

  void _openModal(BuildContext context, List<Sale> orders) {
    showScheduledOrderModal(
      context,
      orders:          orders,
      triggeringLevel: _selectedLevel,
    );
  }
}
