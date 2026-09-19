import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;

import '../storage/hive_boxes.dart';
import '../../features/caisse/domain/entities/sale_item.dart';

/// État de disponibilité d'un plat pour la journée en cours.
class DailyAvailability {
  /// Le plat est-il proposé aujourd'hui ? (interrupteur admin)
  final bool enabled;

  /// Stock du jour restant. `null` = illimité (aucune limite fixée).
  final int? count;

  const DailyAvailability({required this.enabled, required this.count});

  /// Défaut quand rien n'est configuré pour aujourd'hui : proposé, sans limite.
  static const initial = DailyAvailability(enabled: true, count: null);

  /// Vrai si le plat peut être commandé maintenant.
  bool get isAvailable => enabled && (count == null || count! > 0);

  /// Indisponible parce que le stock du jour est épuisé (distinct d'une
  /// désactivation manuelle) — permet de choisir le libellé « Épuisé ».
  bool get isSoldOut => enabled && count != null && count! <= 0;
}

/// Disponibilités du jour de la carte d'un restaurant (LOCAL, par appareil).
///
/// Chaque matin l'admin (ré)active les plats du jour et peut fixer un stock.
/// Le stock décrémente à chaque commande ; à 0 le plat passe « épuisé ». Les
/// réglages se réinitialisent chaque jour : une entrée dont la `date` n'est
/// pas aujourd'hui est ignorée → retour au défaut « proposé / illimité ».
///
/// Volontairement NON synchronisé (état opérationnel d'un poste de service) :
/// ni table Supabase ni file offline — c'est le poste qui tient le compte de
/// sa journée. Si un besoin multi-postes apparaît, migrer vers le pattern
/// AppDatabase.sync<Entity> (cf. CLAUDE.md).
class DailyMenuService {
  DailyMenuService._();

  /// Incrémenté à CHAQUE écriture (dispo, stock, décrément à la commande).
  /// Les écrans qui affichent la dispo (carte Menu) l'écoutent pour se
  /// reconstruire immédiatement, sans attendre une autre interaction — utile
  /// quand le décrément vient d'une commande encaissée depuis le panier.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static String _key(String shopId, String productId) => '$shopId::$productId';

  static String _today() {
    final n = DateTime.now();
    final m = n.month.toString().padLeft(2, '0');
    final d = n.day.toString().padLeft(2, '0');
    return '${n.year}-$m-$d';
  }

  /// Lit l'état du jour pour un plat (défaut si absent ou périmé = veille).
  static DailyAvailability read(String shopId, String productId) {
    try {
      final raw =
          HiveBoxes.dailyMenuAvailabilityBox.get(_key(shopId, productId));
      if (raw == null) return DailyAvailability.initial;
      final m = Map<String, dynamic>.from(raw);
      // Réinit quotidienne : une entrée d'hier ne s'applique plus.
      if (m['date'] != _today()) return DailyAvailability.initial;
      return DailyAvailability(
        enabled: (m['enabled'] as bool?) ?? true,
        count: (m['count'] as num?)?.toInt(),
      );
    } catch (e) {
      debugPrint('[DailyMenu] read err: $e');
      return DailyAvailability.initial;
    }
  }

  static Future<void> _write(
      String shopId, String productId, DailyAvailability a) async {
    try {
      await HiveBoxes.dailyMenuAvailabilityBox
          .put(_key(shopId, productId), <String, dynamic>{
        'date': _today(),
        'enabled': a.enabled,
        'count': a.count,
      });
      // Réveille les écrans qui affichent la dispo (rebuild immédiat).
      revision.value++;
    } catch (e) {
      debugPrint('[DailyMenu] write err: $e');
    }
  }

  /// Active / désactive le plat pour aujourd'hui.
  static Future<void> setEnabled(
      String shopId, String productId, bool enabled) async {
    final cur = read(shopId, productId);
    await _write(
        shopId, productId, DailyAvailability(enabled: enabled, count: cur.count));
  }

  /// Fixe le stock du jour. `null` = illimité (retire toute limite). Une
  /// valeur négative est ramenée à 0.
  static Future<void> setCount(
      String shopId, String productId, int? count) async {
    final cur = read(shopId, productId);
    final c = (count != null && count < 0) ? 0 : count;
    await _write(
        shopId, productId, DailyAvailability(enabled: cur.enabled, count: c));
  }

  /// Décrémente le stock du jour d'un plat de [qty] (jamais sous 0). No-op si
  /// aucune limite n'est fixée (count == null = illimité).
  static Future<void> consume(String shopId, String productId, int qty) async {
    final cur = read(shopId, productId);
    if (cur.count == null) return;
    final next = cur.count! - qty;
    await _write(shopId, productId,
        DailyAvailability(enabled: cur.enabled, count: next < 0 ? 0 : next));
  }

  /// Applique le décrément à toutes les lignes d'une commande restaurant —
  /// appelé après l'enregistrement d'une vente (cf. CaisseBloc).
  static Future<void> consumeForOrder(
      String shopId, List<SaleItem> items) async {
    for (final it in items) {
      final pid = it.productId;
      if (pid.isEmpty) continue;
      await consume(shopId, pid, it.quantity);
    }
  }
}
