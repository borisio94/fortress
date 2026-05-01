import 'package:flutter/material.dart';
import 'caisse_page.dart' show OrdersTab;

/// Page shell « Commandes caisse ».
///
/// Wrapper minimal autour d'`OrdersTab` (extrait de l'ancien onglet de
/// CaissePage). Embarquée dans la ShellRoute via `/shop/:shopId/caisse/orders`,
/// donc rendue à l'intérieur d'`AdaptiveScaffold` qui fournit déjà la
/// sidebar / topbar / bottom nav. Le `CaisseBloc` est exposé au niveau app
/// (cf. `PosApp`), pas besoin de le re-provisionner ici.
class OrdersPage extends StatelessWidget {
  final String shopId;
  const OrdersPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context) => OrdersTab(shopId: shopId);
}
