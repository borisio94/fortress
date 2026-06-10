import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/permisions/subscription_provider.dart';
import '../../core/storage/hive_boxes.dart';
import '../../core/storage/local_storage_service.dart';
import '../../core/config/supabase_client.dart';

/// Message broadcast reçu côté client (SA-5). Lecture seule.
class BroadcastMessage {
  final String id;
  final String title;
  final String body;
  final String type;        // info | warning | maintenance
  final DateTime? sentAt;

  const BroadcastMessage({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    this.sentAt,
  });

  factory BroadcastMessage.fromMap(Map<String, dynamic> m) => BroadcastMessage(
        id:     m['id'].toString(),
        title:  m['title']?.toString() ?? '',
        body:   m['body']?.toString() ?? '',
        type:   m['type']?.toString() ?? 'info',
        sentAt: DateTime.tryParse(m['sent_at']?.toString() ?? ''),
      );
}

/// Stockage local des broadcasts déjà « vus » (fermés par l'utilisateur).
/// Persisté dans la `settingsBox` (clé-valeur) — pas de read-receipt
/// serveur, on évite simplement de ré-afficher une bannière déjà fermée.
class BroadcastSeenStore {
  static const _key = 'seen_broadcasts';

  static Set<String> seenIds() {
    final raw = HiveBoxes.settingsBox.get(_key);
    if (raw is List) return raw.map((e) => e.toString()).toSet();
    return <String>{};
  }

  static Future<void> markSeen(String id) async {
    final s = seenIds()..add(id);
    await HiveBoxes.settingsBox.put(_key, s.toList());
  }
}

/// Broadcasts NON LUS qui ciblent la boutique courante. Filtre :
///   • target_type 'all'  → toujours
///   • target_type 'shop' → target_value == shopId
///   • target_type 'plan' → target_value == nom du plan courant
/// Les messages déjà fermés ([BroadcastSeenStore]) sont exclus.
final unreadBroadcastsProvider = FutureProvider.autoDispose
    .family<List<BroadcastMessage>, String>((ref, shopId) async {
  // Nom réel du plan (couvre les plans personnalisés, pas seulement l'enum).
  final planName = ref.watch(currentPlanProvider).planNameRaw; // ex 'pro', 'test'
  final uid = SupabaseClientService.currentUserId
      ?? LocalStorageService.getCurrentUser()?.id;
  final raw  = await AppDatabase.getBroadcasts();
  final seen = BroadcastSeenStore.seenIds();

  final out = <BroadcastMessage>[];
  for (final m in raw) {
    final id = m['id'].toString();
    if (seen.contains(id)) continue;
    final targetType  = m['target_type']?.toString() ?? 'all';
    final targetValue = m['target_value']?.toString();
    final matches = switch (targetType) {
      'all'  => true,
      'shop' => targetValue == shopId,
      'plan' => targetValue == planName,
      'user' => uid != null && targetValue == uid,
      _      => false,
    };
    if (matches) out.add(BroadcastMessage.fromMap(m));
  }
  return out;
});
