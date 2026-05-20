import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../storage/hive_boxes.dart';

/// Type d'évènement métier qui déclenche une notification in-app.
enum NotifKind {
  stockLow,
  stockOut,
  orderNew,
  orderCompleted,
  orderCancelled,
  orderRejected,
  // Tickets de messagerie hiérarchique (cf. phase 4).
  ticketNew,        // un membre vient d'ouvrir un ticket à mon niveau
  ticketEscalated,  // un ticket vient de monter à mon niveau
  ticketReply,      // un nouveau message arrive sur un ticket suivi
}

extension NotifKindX on NotifKind {
  String get key => switch (this) {
        NotifKind.stockLow        => 'stock_low',
        NotifKind.stockOut        => 'stock_out',
        NotifKind.orderNew        => 'order_new',
        NotifKind.orderCompleted  => 'order_completed',
        NotifKind.orderCancelled  => 'order_cancelled',
        NotifKind.orderRejected   => 'order_rejected',
        NotifKind.ticketNew       => 'ticket_new',
        NotifKind.ticketEscalated => 'ticket_escalated',
        NotifKind.ticketReply     => 'ticket_reply',
      };

  /// Catégorie utilisée comme préfixe d'id Hive pour grouper les
  /// notifications "mutuellement exclusives" (un produit n'a qu'un seul
  /// état de stock, une commande qu'un seul état terminal). Sans ce
  /// regroupement, on accumule plusieurs lignes pour la même cible quand
  /// son état change (ex: stock_low → stock_out → 2 entrées).
  String get category => switch (this) {
        NotifKind.stockLow        => 'stock',
        NotifKind.stockOut        => 'stock',
        NotifKind.orderNew        => 'order_new',     // distinct des transitions
        NotifKind.orderCompleted  => 'order_state',
        NotifKind.orderCancelled  => 'order_state',
        NotifKind.orderRejected   => 'order_state',
        NotifKind.ticketNew       => 'ticket',
        NotifKind.ticketEscalated => 'ticket_escal',
        NotifKind.ticketReply     => 'ticket_reply',  // chaque message = sa propre notif
      };

  static NotifKind? fromKey(String? k) {
    for (final v in NotifKind.values) {
      if (v.key == k) return v;
    }
    return null;
  }
}

/// Représente une notification stockée dans `notifications_box`.
class AppNotification {
  final String    id;
  final NotifKind kind;
  final String    title;
  final String    message;
  final String?   shopId;
  final String?   targetId;       // productId / orderId
  final DateTime  createdAt;
  final bool      read;
  /// Origine de l'évènement source. Pour `orderNew` : `'pos'` | `'web'` |
  /// `'whatsapp'`. Permet d'afficher le badge canal dans le panel cloche.
  final String?   source;

  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.message,
    this.shopId,
    this.targetId,
    required this.createdAt,
    required this.read,
    this.source,
  });

  AppNotification copyWith({bool? read}) => AppNotification(
        id:        id,
        kind:      kind,
        title:     title,
        message:   message,
        shopId:    shopId,
        targetId:  targetId,
        createdAt: createdAt,
        read:      read ?? this.read,
        source:    source,
      );

  Map<String, dynamic> toMap() => {
        'id':        id,
        'kind':      kind.key,
        'title':     title,
        'message':   message,
        'shop_id':   shopId,
        'target_id': targetId,
        'created_at': createdAt.toIso8601String(),
        'read':       read,
        'source':     source,
      };

  static AppNotification fromMap(Map m) => AppNotification(
        id:        m['id'] as String,
        kind:      NotifKindX.fromKey(m['kind'] as String?) ?? NotifKind.stockLow,
        title:     (m['title']   ?? '').toString(),
        message:   (m['message'] ?? '').toString(),
        shopId:    m['shop_id']   as String?,
        targetId:  m['target_id'] as String?,
        createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '') ??
                   DateTime.now(),
        read:      m['read'] == true,
        source:    m['source'] as String?,
      );
}

/// Centre de notifications local — alimente la cloche du topbar et le
/// panel déroulant. Les évènements sont déclenchés par
/// `AppDatabase.addListener` (cf. branchement dans app_database.dart).
///
/// **Filtre owner** : `enabledForCurrentUser` doit être `true` pour
/// activer les insertions. Côté UI, le widget badge lit aussi ce flag.
class NotificationService {
  static const int _maxEntries = 50;

  /// Drapeau owner — modifié quand le rôle de l'user courant change.
  static final ValueNotifier<bool> enabledForCurrentUser =
      ValueNotifier<bool>(false);

  /// Notifie l'UI (badge + panel) à chaque insertion / mise à jour.
  /// L'UI s'abonne via `ValueListenableBuilder` ou listener.
  static final ValueNotifier<int> rev = ValueNotifier<int>(0);

  /// Anti-doublon court (60 s par cle stable kind+targetId+shopId).
  /// Empêche d'empiler N notifs "stock bas" à chaque tick realtime.
  static final Map<String, DateTime> _dedup = {};

  /// Insère ou MET À JOUR une notification dans Hive si
  /// `enabledForCurrentUser=true`.
  ///
  /// L'id est **déterministe** sur la clé `(kind, targetId, shopId)` :
  ///   * Première émission → insertion neuve.
  ///   * Émission suivante (même produit en stock bas après un redémarrage) →
  ///     `box.put(id, ...)` écrase l'entrée. Le `read` et le `createdAt`
  ///     originaux sont préservés (l'utilisateur ne voit pas une notif
  ///     marquée "nouvelle" alors qu'elle l'est depuis hier). Seuls le
  ///     titre et le message sont rafraîchis (utile si le stock évolue
  ///     ex: "Stock : 5" → "Stock : 3").
  ///
  /// L'anti-spam in-memory `_dedup` reste en place (60 s) pour absorber
  /// les rebonds rapprochés du Realtime pendant un même run.
  static void notify({
    required NotifKind kind,
    required String    title,
    required String    message,
    String?            shopId,
    String?            targetId,
    String?            source,
  }) {
    if (!enabledForCurrentUser.value) return;
    // Id basé sur la **catégorie** plutôt que le `kind` exact : les
    // transitions d'état d'une même cible (stock_low → stock_out, ou
    // order_completed → order_cancelled) écrasent l'entrée existante au
    // lieu de cumuler. Les `kind` qui doivent rester distincts (ticketReply
    // par message) ont leur propre catégorie.
    final id  = '${kind.category}|${targetId ?? ''}|${shopId ?? ''}';
    final now = DateTime.now();
    // Anti-spam court : empêche les rafales pendant un même run.
    final last = _dedup[id];
    if (last != null && now.difference(last).inSeconds < 60) return;
    _dedup[id] = now;

    try {
      final box = HiveBoxes.notificationsBox;
      final raw = box.get(id);
      if (raw is Map) {
        // Existante → soft-update.
        // - Si le `kind` a changé (transition d'état : stock_low → stock_out
        //   par exemple) : on met à jour `kind` ET on remet `read=false`
        //   pour que l'utilisateur soit alerté du changement d'état.
        // - Si le `kind` est identique : on rafraîchit juste le contenu
        //   et on conserve la date d'origine + le statut lu/non-lu.
        final existing =
            AppNotification.fromMap(Map<String, dynamic>.from(raw));
        final kindChanged = existing.kind != kind;
        final updated = AppNotification(
          id:        existing.id,
          kind:      kind,            // toujours le plus récent
          title:     title,
          message:   message,
          shopId:    existing.shopId,
          targetId:  existing.targetId,
          createdAt: kindChanged ? now : existing.createdAt,
          read:      kindChanged ? false : existing.read,
          source:    existing.source ?? source,
        );
        box.put(id, updated.toMap());
        rev.value++;
        return;
      }

      // Nouvelle entrée — insertion avec id stable.
      final notif = AppNotification(
        id:        id,
        kind:      kind,
        title:     title,
        message:   message,
        shopId:    shopId,
        targetId:  targetId,
        createdAt: now,
        read:      false,
        source:    source,
      );
      box.put(id, notif.toMap());
      _truncate(box);
      rev.value++;
    } catch (e) {
      debugPrint('[Notif] persist error: $e');
    }
  }

  static List<AppNotification> list() {
    try {
      final box = HiveBoxes.notificationsBox;
      final items = box.values
          .map((m) => AppNotification.fromMap(Map<String, dynamic>.from(m)))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return items;
    } catch (_) {
      return const [];
    }
  }

  static int unreadCount() => list().where((n) => !n.read).length;

  static void markAsRead(String id) {
    try {
      final box = HiveBoxes.notificationsBox;
      final raw = box.get(id);
      if (raw == null) return;
      final notif =
          AppNotification.fromMap(Map<String, dynamic>.from(raw)).copyWith(read: true);
      box.put(id, notif.toMap());
      rev.value++;
    } catch (e) {
      debugPrint('[Notif] markAsRead: $e');
    }
  }

  static void markAllAsRead() {
    try {
      final box = HiveBoxes.notificationsBox;
      for (final key in box.keys.toList()) {
        final raw = box.get(key);
        if (raw == null) continue;
        final n = AppNotification.fromMap(Map<String, dynamic>.from(raw));
        if (!n.read) box.put(key, n.copyWith(read: true).toMap());
      }
      rev.value++;
    } catch (e) {
      debugPrint('[Notif] markAllAsRead: $e');
    }
  }

  static void clearAll() {
    try {
      HiveBoxes.notificationsBox.clear();
      _dedup.clear();
      rev.value++;
    } catch (e) {
      debugPrint('[Notif] clearAll: $e');
    }
  }

  /// Purge les notifications avec un id au format historique :
  ///   1. Pré-déterministe : `${ms}_${hexRandom}` (sans `|`).
  ///   2. Ancien préfixe `kind` plutôt que `category` (cf. introduction
  ///      du regroupement par état mutuellement exclusif). Ces préfixes
  ///      seraient écrits par les versions précédentes : ils créent des
  ///      doublons avec les nouveaux ids `category|targetId|shopId` quand
  ///      le même produit/commande change d'état.
  ///
  /// Les `kind` qui ont CONSERVÉ leur préfixe (orderNew, ticketReply)
  /// sont volontairement absents de la liste — on garde leurs entrées.
  ///
  /// Idempotent. À appeler UNE fois au boot.
  static int purgeLegacyEntries() {
    try {
      final box = HiveBoxes.notificationsBox;
      const oldKindPrefixes = <String>[
        'stock_low|',        // → catégorie 'stock'
        'stock_out|',        // → catégorie 'stock'
        'order_completed|',  // → catégorie 'order_state'
        'order_cancelled|',  // → catégorie 'order_state'
        'order_rejected|',   // → catégorie 'order_state'
        'ticket_new|',       // → catégorie 'ticket'
        'ticket_escalated|', // → catégorie 'ticket_escal'
      ];
      final toRemove = <dynamic>[];
      for (final key in box.keys) {
        if (key is! String) continue;
        if (!key.contains('|')) {
          toRemove.add(key); // format pré-déterministe
          continue;
        }
        for (final p in oldKindPrefixes) {
          if (key.startsWith(p)) {
            toRemove.add(key);
            break;
          }
        }
      }
      if (toRemove.isEmpty) return 0;
      for (final k in toRemove) {
        box.delete(k);
      }
      rev.value++;
      debugPrint('[Notif] Purgé ${toRemove.length} entrées legacy');
      return toRemove.length;
    } catch (e) {
      debugPrint('[Notif] purgeLegacy: $e');
      return 0;
    }
  }

  // ── Internes ──────────────────────────────────────────────────────────────

  /// FIFO : on garde les `_maxEntries` plus récentes.
  static void _truncate(Box<Map> box) {
    if (box.length <= _maxEntries) return;
    final all = box.toMap().entries.toList()
      ..sort((a, b) {
        final ta = DateTime.tryParse(a.value['created_at']?.toString() ?? '')
            ?.millisecondsSinceEpoch ?? 0;
        final tb = DateTime.tryParse(b.value['created_at']?.toString() ?? '')
            ?.millisecondsSinceEpoch ?? 0;
        return ta.compareTo(tb);
      });
    final excess = box.length - _maxEntries;
    for (int i = 0; i < excess; i++) {
      box.delete(all[i].key);
    }
  }
}
