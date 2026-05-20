import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/delivery_transfer.dart';

/// Lecture seule des transferts WhatsApp effectués pour une commande
/// (cf. hotfix_049). Les transferts sont audit-only — ils sont insérés
/// EXCLUSIVEMENT par la RPC `transfer_order_to_delivery`.
///
/// Pas de cache Hive : la table grossit lentement et chaque fiche commande
/// charge à la demande. RLS garantit qu'on ne voit que les transferts du
/// shop dont on est membre.
class DeliveryTransferRepository {
  static const _table = 'delivery_transfers';

  SupabaseClient get _db => Supabase.instance.client;

  /// Liste les transferts d'une commande, du plus récent au plus ancien.
  Future<List<DeliveryTransfer>> listForOrder(String orderId) async {
    final rows = await _db.from(_table)
        .select()
        .eq('order_id', orderId)
        .order('created_at', ascending: false);
    return (rows as List)
        .whereType<Map>()
        .map((m) => DeliveryTransfer.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }
}

/// Provider singleton.
final deliveryTransferRepositoryProvider =
    Provider<DeliveryTransferRepository>((_) => DeliveryTransferRepository());

/// Liste des transferts d'une commande (clé = orderId). FutureProvider.family
/// → invalidate manuel quand un nouveau transfert est créé.
final orderDeliveryTransfersProvider =
    FutureProvider.family<List<DeliveryTransfer>, String>((ref, orderId) async {
  final repo = ref.watch(deliveryTransferRepositoryProvider);
  try {
    return await repo.listForOrder(orderId);
  } catch (e) {
    debugPrint('[DeliveryTransfers] fetch error: $e');
    return const [];
  }
});
