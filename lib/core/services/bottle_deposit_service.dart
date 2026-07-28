import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/bottle_deposit.dart';
import '../../features/restaurant/domain/entities/loss.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'loss_service.dart';

/// Service Hive-first des consignes d'emballages (Lot B — hotfix_146).
/// Ids `bd_` + microsecondes. Push Supabase via `bgUpsert('bottle_deposits')`.
///
/// Point d'entrée UNIQUE des consignes : la liste des emballages dehors, les
/// retours et la perte d'une consigne non rendue passent tous par ici, pour que
/// le statut et la catégorie de perte restent au même endroit.
class BottleDepositService {
  BottleDepositService._();

  static Box<Map> _raw() => HiveBoxes.bottleDepositsBox;

  static String _id() => 'bd_${DateTime.now().microsecondsSinceEpoch}';

  /// Consignes de la boutique, les plus récentes en tête.
  ///
  /// [onlyOpen] ne garde que celles dont des emballages sont encore dehors —
  /// la seule liste consultée au quotidien.
  static List<BottleDeposit> forShop(String shopId, {bool onlyOpen = false}) {
    try {
      final list = <BottleDeposit>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          final d = BottleDeposit.fromMap(Map<String, dynamic>.from(raw));
          if (onlyOpen && d.isClosed) continue;
          list.add(d);
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    } catch (e) {
      debugPrint('[Deposit] forShop err: $e');
      return [];
    }
  }

  /// Consignes rattachées à une commande.
  static List<BottleDeposit> forOrder(String shopId, String orderId) =>
      forShop(shopId).where((d) => d.orderId == orderId).toList();

  /// Nombre d'emballages encore dehors et argent correspondant.
  static ({int bottles, int amount}) outstanding(String shopId) {
    var bottles = 0;
    var amount = 0;
    for (final d in forShop(shopId, onlyOpen: true)) {
      bottles += d.outstanding;
      amount += d.outstandingAmount;
    }
    return (bottles: bottles, amount: amount);
  }

  /// Enregistre une consigne remise à un client.
  ///
  /// N'ENCAISSE RIEN : le montant est facturé par la ligne de frais posée sur
  /// la commande (cf. `RestaurantOrderService.addFee`). Séparer les deux évite
  /// de compter la consigne deux fois dans le chiffre d'affaires.
  static Future<BottleDeposit> record({
    required String shopId,
    required int quantity,
    required int depositPerUnit,
    String label = 'Consigne',
    String? orderId,
    String? productId,
    String? holder,
  }) async {
    final d = BottleDeposit(
      id: _id(),
      shopId: shopId,
      orderId: orderId,
      productId: productId,
      label: label.trim().isEmpty ? 'Consigne' : label.trim(),
      quantity: quantity < 0 ? 0 : quantity,
      depositPerUnit: depositPerUnit < 0 ? 0 : depositPerUnit,
      status: 'pending',
      holder: holder,
      createdAt: DateTime.now(),
    );
    await _put(d);
    return d;
  }

  /// Enregistre le retour de [count] emballages (plafonné à ce qui reste dû,
  /// cf. [BottleDeposit.withReturn]).
  static Future<BottleDeposit> registerReturn(
      BottleDeposit deposit, int count) async {
    final updated = deposit.withReturn(count);
    if (updated.returnedQuantity == deposit.returnedQuantity) return deposit;
    await _put(updated);
    return updated;
  }

  /// Acte qu'une consigne ne reviendra pas : la boutique rachètera les
  /// emballages, donc c'est une perte de sa poche.
  ///
  /// Le montant perdu est la caution des emballages ENCORE DEHORS — pas la
  /// consigne entière : ce qui est déjà revenu a été rendu et remboursé.
  static Future<Loss?> declareLost(
    BottleDeposit deposit, {
    String origin = '',
    String? declaredBy,
  }) async {
    final amount = deposit.outstandingAmount;
    final updated = deposit.copyWith(status: 'lost');
    await _put(updated);
    if (amount <= 0) return null;
    return LossService.record(
      shopId: deposit.shopId,
      description: '${deposit.label} — ${deposit.outstanding} emballage'
          '${deposit.outstanding > 1 ? 's' : ''} non rendu'
          '${deposit.outstanding > 1 ? 's' : ''}',
      amount: amount,
      category: 'consigne_perdue',
      origin: origin.isEmpty ? (deposit.holder ?? '') : origin,
      declaredBy: declaredBy,
    );
  }

  static Future<void> _put(BottleDeposit d) async {
    final map = d.toMap();
    try {
      await _raw().put(d.id, map);
    } catch (e) {
      debugPrint('[Deposit] put Hive err: $e');
    }
    AppDatabase.bgUpsert('bottle_deposits', map);
    AppDatabase.notifyListeners('bottle_deposits', d.shopId);
  }

  static Future<void> delete(String id, String shopId) async {
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[Deposit] delete Hive err: $e');
    }
    AppDatabase.bgDelete('bottle_deposits', val: id);
    AppDatabase.notifyListeners('bottle_deposits', shopId);
  }
}
