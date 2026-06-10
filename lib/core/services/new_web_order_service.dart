import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/caisse/domain/entities/sale.dart';
import '../../shared/widgets/alerts/_order_hydration.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'notification_service.dart';

/// Service singleton qui maintient la liste des **nouvelles commandes web
/// non acquittées** (source='web' + status='scheduled' + non vue par
/// l'opérateur). Alimente la bannière persistante en haut de l'app pour
/// que l'owner / admin ne rate pas une commande passée par un client via
/// le lien catalogue public.
///
/// Différence avec [ScheduledOrderAlertService] : ce service ne dépend
/// PAS du delta temporel (J-1, H-2, …). Il signale uniquement le canal
/// d'arrivée (web) + l'état de lecture (acquittée ou non). La logique
/// d'escalade temporelle reste à ScheduledOrderAlertService.
///
/// Persistance des acquittements : `settings_box['acknowledged_web_orders']`
/// (List<String> d'order ids). Auto-purge quand la commande passe à un
/// status ≠ 'scheduled' (validation client, encaissement, annulation) —
/// l'id sort naturellement de la liste émise, ET on retire l'ack pour
/// rester clean si la commande est reprogrammée plus tard.
class NewWebOrderService {
  NewWebOrderService._();
  static final NewWebOrderService instance = NewWebOrderService._();

  static const String _ackKey = 'acknowledged_web_orders';

  final StreamController<List<Sale>> _alertsCtl =
      StreamController<List<Sale>>.broadcast();
  Stream<List<Sale>> get alerts => _alertsCtl.stream;

  Set<String> _acked = <String>{};
  bool _started = false;
  void Function(String table, String shopId)? _onChanged;

  /// Démarre le service. Idempotent.
  /// Préconditions : Hive box `orders` ET `settings` ouvertes (assuré
  /// par AppDatabase.init() avant l'appel).
  Future<void> start() async {
    if (_started) return;
    if (!Hive.isBoxOpen(HiveBoxes.orders) ||
        !Hive.isBoxOpen(HiveBoxes.settings)) {
      debugPrint('[NewWebOrder] start() : Hive pas prêt, skip');
      return;
    }
    _started = true;
    debugPrint('[NewWebOrder] start()');

    _loadAcks();

    // Écoute owner/admin uniquement. Comme ScheduledOrderAlertService,
    // on (re)démarre dynamiquement quand le rôle change.
    NotificationService.enabledForCurrentUser.removeListener(_onPermsChanged);
    NotificationService.enabledForCurrentUser.addListener(_onPermsChanged);
    if (!NotificationService.enabledForCurrentUser.value) {
      // Service démarré mais inactif (émet liste vide).
      _alertsCtl.add(const []);
      return;
    }

    _onChanged = (table, _) {
      if (table == 'orders') _evaluate();
    };
    AppDatabase.addListener(_onChanged!);
    _evaluate();
  }

  /// Arrête le service (logout, dispose).
  void stop() {
    debugPrint('[NewWebOrder] stop()');
    if (_onChanged != null) {
      AppDatabase.removeListener(_onChanged!);
      _onChanged = null;
    }
    NotificationService.enabledForCurrentUser
        .removeListener(_onPermsChanged);
    _started = false;
  }

  /// Marque une commande comme vue. Disparait de la bannière.
  void acknowledge(String orderId) {
    if (_acked.add(orderId)) {
      _persistAcks();
    }
    _evaluate();
  }

  /// Marque toutes les commandes web actuellement listées comme vues.
  void acknowledgeAll() {
    final current = _computeAlerts();
    var changed = false;
    for (final s in current) {
      final id = s.id;
      if (id != null && _acked.add(id)) changed = true;
    }
    if (changed) _persistAcks();
    _evaluate();
  }

  // ── Implementation ────────────────────────────────────────────────────

  void _onPermsChanged() {
    if (!_started) return;
    if (NotificationService.enabledForCurrentUser.value) {
      _onChanged ??= (table, _) {
        if (table == 'orders') _evaluate();
      };
      AppDatabase.addListener(_onChanged!);
      _evaluate();
    } else {
      if (_onChanged != null) {
        AppDatabase.removeListener(_onChanged!);
        _onChanged = null;
      }
      if (!_alertsCtl.isClosed) _alertsCtl.add(const []);
    }
  }

  void _loadAcks() {
    try {
      final raw = HiveBoxes.settingsBox.get(_ackKey);
      if (raw is List) {
        _acked = raw.whereType<String>().toSet();
      } else {
        _acked = <String>{};
      }
    } catch (e) {
      debugPrint('[NewWebOrder] _loadAcks err: $e');
      _acked = <String>{};
    }
  }

  void _persistAcks() {
    try {
      HiveBoxes.settingsBox.put(_ackKey, _acked.toList());
    } catch (e) {
      debugPrint('[NewWebOrder] _persistAcks err: $e');
    }
  }

  /// Liste des commandes web non acquittées encore en `scheduled`.
  /// Filtre aussi les soft-deleted (`deleted_at` non null, hotfix_084).
  List<Sale> _computeAlerts() {
    final out = <Sale>[];
    final box = HiveBoxes.ordersBox;
    final purge = <String>[];
    // Boutiques encore connues localement (shopsBox est indexé par shop.id).
    // On ignore toute commande dont la boutique n'existe plus → évite de
    // re-notifier une commande orpheline après suppression/recréation de la
    // boutique (la commande purgée côté serveur peut subsister dans le cache
    // Hive de l'appareil opérateur si la suppression n'est pas passée par
    // resetShopData). Si la liste est vide (cache non encore chargé), on ne
    // filtre pas pour ne pas masquer de vraies alertes pendant le boot.
    final validShopIds =
        HiveBoxes.shopsBox.keys.map((k) => k.toString()).toSet();
    for (final raw in box.values) {
      try {
        final m = Map<String, dynamic>.from(raw);
        final id = m['id'] as String?;
        if (id == null) continue;
        if ((m['source'] as String?) != 'web') continue;
        // Commande orpheline (boutique supprimée) → ne pas notifier.
        final sid = m['shop_id']?.toString();
        if (validShopIds.isNotEmpty &&
            sid != null &&
            !validShopIds.contains(sid)) {
          continue;
        }
        final status = m['status'] as String?;
        // Auto-purge l'ack si la commande n'est plus 'scheduled' — utile
        // si elle est reprogrammée plus tard (on veut re-notifier).
        if (status != 'scheduled') {
          if (_acked.contains(id)) purge.add(id);
          continue;
        }
        if (m['deleted_at'] != null) continue;
        if (_acked.contains(id)) continue;
        final s = hydrateOrderForAlert(m);
        if (s != null) out.add(s);
      } catch (e) {
        debugPrint('[NewWebOrder] eval item err: $e');
      }
    }
    if (purge.isNotEmpty) {
      _acked.removeAll(purge);
      _persistAcks();
    }
    // Tri par date de création décroissante (les plus récentes en premier).
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  void _evaluate() {
    if (!_alertsCtl.isClosed) {
      _alertsCtl.add(_computeAlerts());
    }
  }
}
