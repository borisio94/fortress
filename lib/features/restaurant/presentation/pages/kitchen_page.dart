import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_service.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/restaurant_table_service.dart';
import '../../../../core/services/round_routing.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../features/caisse/domain/entities/sale_item.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../widgets/kitchen_ticket_card.dart';

/// Écran Cuisine — les bons envoyés et pas encore prêts (module restaurant).
///
/// Conçu pour une tablette posée en cuisine : gros tickets, lecture à
/// distance, une seule action par bon. Aucun widget de la caisse e-commerce
/// n'est réutilisé.
///
/// **Filtre par poste** (Lot A) : la même page sert d'écran cuisine, d'écran
/// bar et d'écran chawarma. Le poste choisi est mémorisé PAR APPAREIL — la
/// tablette du bar doit rouvrir sur le bar, pas sur « tous les postes », sinon
/// le barman relit la carte à chaque service.
class KitchenPage extends StatefulWidget {
  final String shopId;

  const KitchenPage({super.key, required this.shopId});

  @override
  State<KitchenPage> createState() => _KitchenPageState();
}

class _KitchenPageState extends State<KitchenPage> {
  late final OnDataChanged _listener;
  Timer? _ticker;

  /// Poste affiché. `null` = tous les postes (comportement d'avant le filtre,
  /// et seul choix sensible pour un restaurant à un seul poste).
  ServiceStation? _station;

  /// Articles cochés « prêt », par commande. Purement local et volontairement
  /// NON persisté : c'est une aide visuelle pour le cuisinier pendant le
  /// dressage, pas un état métier. La seule transition persistée est
  /// « commande prête » (`kitchen_ready`).
  ///
  /// Les index sont ceux de la liste AFFICHÉE : changer de poste les invalide,
  /// d'où la purge dans [_selectStation].
  final Map<String, Set<int>> _checked = {};

  String get _prefKey => 'kds_station_${widget.shopId}';

  @override
  void initState() {
    super.initState();
    _station = ServiceStation.fromKey(_readPref());
    _listener = (table, sid) {
      if (!mounted) return;
      // `restaurant_activities` compte autant que `orders` : rattacher un plat
      // à un autre poste depuis la caisse doit réétiqueter les bons affichés.
      if (table != 'orders' && table != 'restaurant_activities') return;
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

  String? _readPref() {
    try {
      return HiveBoxes.settingsBox.get(_prefKey) as String?;
    } catch (e) {
      debugPrint('[Cuisine] lecture poste err: $e');
      return null;
    }
  }

  void _selectStation(ServiceStation? s) {
    setState(() {
      _station = s;
      // Les index cochés désignaient les articles de l'ancien filtre : les
      // garder ferait apparaître des plats barrés au hasard.
      _checked.clear();
    });
    try {
      if (s == null) {
        HiveBoxes.settingsBox.delete(_prefKey);
      } else {
        HiveBoxes.settingsBox.put(_prefKey, s.key);
      }
    } catch (e) {
      debugPrint('[Cuisine] écriture poste err: $e');
    }
  }

  /// Postes proposés dans la barre de filtre : ceux que la boutique utilise
  /// réellement (déclarés ou déduits du mode de ses activités), plus la
  /// cuisine, où atterrissent tous les plats sans secteur.
  List<ServiceStation> get _availableStations {
    final used = <ServiceStation>{ServiceStation.cuisine};
    for (final a in ActivityService.forShop(widget.shopId)) {
      final explicit = ServiceStation.fromKey(a.station);
      used.add(explicit ??
          (a.isStockMode ? ServiceStation.bar : ServiceStation.cuisine));
    }
    return ServiceStation.values.where(used.contains).toList();
  }

  List<Sale> get _tickets =>
      RestaurantOrderService.kitchenTickets(widget.shopId);

  /// Articles du bon qui reviennent au poste affiché (tous si « Tous »).
  List<SaleItem> _itemsOf(Sale order) {
    final s = _station;
    if (s == null) return order.items;
    return RoundRouting.itemsFor(widget.shopId, order.items, s);
  }

  /// Autres postes concernés par le bon — affiché sur le ticket puisque
  /// « Commande prête » clôture le bon ENTIER, pas seulement la part du poste.
  List<String> _otherStationsOf(Sale order) {
    final s = _station;
    if (s == null) return const [];
    return RoundRouting.stationsOf(widget.shopId, order.items)
        .where((x) => x != s)
        .map((x) => x.title)
        .toList();
  }

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
    final stations = _availableStations;
    // Un seul poste possible : la barre de filtre n'apporterait rien et
    // mangerait de la hauteur d'écran sur une tablette.
    final showFilter = stations.length > 1;

    // Un bon sans article pour le poste affiché n'a rien à y faire.
    final tickets = <(Sale, List<SaleItem>)>[];
    for (final t in _tickets) {
      final items = _itemsOf(t);
      if (items.isEmpty) continue;
      tickets.add((t, items));
    }

    return AppScaffold(
      title: _station == null ? 'Cuisine' : _station!.title,
      shopId: widget.shopId,
      body: Column(
        children: [
          if (showFilter) _buildStationBar(stations),
          Expanded(
            child: tickets.isEmpty
                ? EmptyStateWidget(
                    icon: Icons.restaurant_rounded,
                    title: 'Aucun bon en cours',
                    subtitle: _station == null
                        ? 'Les commandes envoyées en cuisine apparaîtront ici, '
                            'du plus ancien au plus récent.'
                        : 'Aucun bon pour le poste ${_station!.title}. '
                            'Choisissez « Tous » pour voir les autres postes.',
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      // Tickets larges (~320 dp) : lisibles à distance sur une
                      // tablette de cuisine, une seule colonne sur téléphone.
                      final columns =
                          (constraints.maxWidth / 320).floor().clamp(1, 4);
                      return GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.78,
                        ),
                        itemCount: tickets.length,
                        itemBuilder: (_, i) {
                          final (t, items) = tickets[i];
                          final id = t.id ?? '';
                          return KitchenTicketCard(
                            order: t,
                            items: items,
                            otherStations: _otherStationsOf(t),
                            tableLabel: _tableLabel(t),
                            checked: _checked[id] ?? const {},
                            onToggleItem: (index) => setState(() {
                              final set =
                                  _checked.putIfAbsent(id, () => <int>{});
                              if (!set.remove(index)) set.add(index);
                            }),
                            onReady: () => _markReady(t),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStationBar(List<ServiceStation> stations) {
    // Compteur de bons par poste : le barman voit qu'il a du travail sans
    // changer d'onglet.
    final counts = <ServiceStation?, int>{};
    for (final t in _tickets) {
      counts[null] = (counts[null] ?? 0) + 1;
      for (final s in RoundRouting.stationsOf(widget.shopId, t.items)) {
        counts[s] = (counts[s] ?? 0) + 1;
      }
    }

    Widget chip(ServiceStation? s, String label) {
      final n = counts[s] ?? 0;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(n > 0 ? '$label ($n)' : label,
              style: AppTextStyles.label),
          selected: _station == s,
          onSelected: (_) => _selectStation(s),
        ),
      );
    }

    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          chip(null, 'Tous'),
          for (final s in stations) chip(s, s.title),
        ],
      ),
    );
  }
}
