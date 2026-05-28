import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/new_web_order_service.dart';
import '../../features/caisse/domain/entities/sale.dart';

/// Stream des nouvelles commandes web non acquittées (= source='web' +
/// status='scheduled' + non vues par l'owner/admin). Alimente la
/// bannière persistante en haut de l'app.
///
/// Pattern aligné avec [scheduledAlertsProvider] :
/// `ConsumerWidget` → `ref.watch(newWebOrdersProvider).valueOrNull`.
final newWebOrdersProvider = StreamProvider<List<Sale>>((ref) {
  return NewWebOrderService.instance.alerts;
});

/// True si au moins une commande web est non acquittée.
final hasNewWebOrdersProvider = Provider<bool>((ref) {
  final list = ref.watch(newWebOrdersProvider).valueOrNull ?? const [];
  return list.isNotEmpty;
});
