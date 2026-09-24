import 'package:flutter/material.dart';
import '../../../../core/storage/schema_migrator.dart';
import '../../../../core/theme/app_theme.dart';

/// Statut d'une table du plan de salle.
///
/// Sérialisé par [RestaurantTableStatusX.key] (et NON par `.name`) : les clés
/// SQL sont en français sans accent (`occupee`, `reservee`) et doivent rester
/// stables même si l'identifiant Dart évolue. Même pattern que `PaymentStatus`
/// et `DeliveryMode` dans `sale.dart`.
enum RestaurantTableStatus { libre, occupee, addition, reservee }

extension RestaurantTableStatusX on RestaurantTableStatus {
  /// Clé persistée (colonne `restaurant_tables.status`).
  String get key => switch (this) {
        RestaurantTableStatus.libre     => 'libre',
        RestaurantTableStatus.occupee   => 'occupee',
        RestaurantTableStatus.addition   => 'addition',
        RestaurantTableStatus.reservee  => 'reservee',
      };

  String get label => switch (this) {
        RestaurantTableStatus.libre     => 'Libre',
        RestaurantTableStatus.occupee   => 'Occupée',
        RestaurantTableStatus.addition  => 'Addition',
        RestaurantTableStatus.reservee  => 'Réservée',
      };

  /// Icône de la carte — uniquement des glyphes DÉJÀ utilisés ailleurs dans
  /// l'app. Le repo a un historique documenté d'icônes Material récentes
  /// absentes de la police bundlée (cf. commentaires shell_nav_items.dart) :
  /// `ti-armchair` / `chair_rounded` sont donc évités au profit de valeurs sûres.
  IconData get icon => switch (this) {
        RestaurantTableStatus.libre     => Icons.check_circle_outline_rounded,
        RestaurantTableStatus.occupee   => Icons.people_rounded,
        RestaurantTableStatus.addition  => Icons.receipt_long_rounded,
        RestaurantTableStatus.reservee  => Icons.access_time_rounded,
      };

  /// Couleur d'accent, résolue depuis les tokens sémantiques du thème
  /// (jamais de `Color(0xFF…)` en dur — cf. règle projet).
  Color color(AppSemanticColors s) => switch (this) {
        RestaurantTableStatus.libre     => s.success,
        RestaurantTableStatus.occupee   => s.warning,
        RestaurantTableStatus.addition  => s.danger,
        RestaurantTableStatus.reservee  => s.info,
      };

  /// Fond de carte — surface teintée du même token.
  Color surface(AppSemanticColors s) => switch (this) {
        RestaurantTableStatus.libre     => s.successSurface,
        RestaurantTableStatus.occupee   => s.warningSurface,
        RestaurantTableStatus.addition  => s.dangerSurface,
        // Pas de `infoSurface` dans AppSemanticColors → dérivé du token info,
        // ce qui reste cohérent en clair comme en sombre.
        RestaurantTableStatus.reservee  => s.info.withValues(alpha: 0.12),
      };

  /// Lecture tolérante : une valeur inconnue (donnée legacy, faute de frappe
  /// côté base) retombe sur `libre` plutôt que de faire planter la page.
  static RestaurantTableStatus fromKey(String? raw) =>
      RestaurantTableStatus.values.firstWhere((s) => s.key == raw,
          orElse: () => RestaurantTableStatus.libre);
}

/// Une table physique du plan de salle.
///
/// `id` est une clé TEXT générée côté client (`rt_<microsecondes>`) : Hive et
/// Supabase partagent la même clé, ce qui permet de créer une table hors ligne
/// et de la synchroniser ensuite sans réconciliation d'identifiant.
class RestaurantTable {
  final String id;
  final String shopId;

  /// Numéro affiché (T1, T2…). Unique par boutique — contrainte
  /// `restaurant_tables_shop_number_uidx` côté base.
  final int number;
  final String name;
  final int capacity;
  final RestaurantTableStatus status;

  /// Nombre de couverts réellement assis. `null` quand la table est libre.
  final int? covers;

  /// Commande en cours rattachée à la table. Câblé en PR-2 (commande par
  /// table) — déjà porté ici pour que le schéma Hive/Supabase soit stable.
  final String? currentOrderId;

  /// Heure d'ouverture du service en cours (sert au calcul de durée de repas
  /// en PR-3). `null` quand la table est libre.
  final DateTime? openedAt;

  final DateTime? reservationTime;
  final String? reservationName;
  final DateTime createdAt;

  /// Horodatage de suppression, `null` tant que la table est en service.
  ///
  /// SUPPRESSION DOUCE (hotfix_180) : la ligne survit, l'app la filtre à la
  /// lecture. Une table est référencée par `orders.table_id` sur tout
  /// l'historique des commandes qu'elle a servies — l'effacer pour de bon
  /// laissait ces commandes pointer vers rien, sans recours.
  final DateTime? deletedAt;

  const RestaurantTable({
    required this.id,
    required this.shopId,
    required this.number,
    required this.name,
    required this.createdAt,
    this.capacity = 4,
    this.status = RestaurantTableStatus.libre,
    this.covers,
    this.currentOrderId,
    this.openedAt,
    this.reservationTime,
    this.reservationName,
    this.deletedAt,
  });

  /// DÉLAI DE COURTOISIE d'une réservation.
  ///
  /// Passé l'heure, la table reste tenue pendant ce délai : dix minutes de
  /// retard sont ordinaires, un quart d'heure est la marge habituelle en
  /// salle. Au-delà d'une demi-heure, la table est perdue pour le service —
  /// on ne garde pas six places vides une heure durant.
  ///
  /// CONSTANTE, et pas un réglage : le jour où un restaurateur la conteste,
  /// elle devra devenir une colonne `shops` synchronisée. Surtout pas un
  /// `ShopSettingsStore`, qui est du Hive local jamais synchronisé — deux
  /// appareils de la même salle y liraient deux valeurs différentes.
  static const Duration reservationGrace = Duration(minutes: 30);

  /// La table est-elle RÉELLEMENT retenue en ce moment ?
  ///
  /// Une réservation dépassée n'est pas annulée en base : elle est ignorée à la
  /// lecture. C'est un choix, pas un raccourci — l'app n'a aucun planificateur,
  /// donc une annulation ÉCRITE exigerait qu'un appareil allumé la déclenche,
  /// et deux appareils produiraient deux écritures pour le même fait. Le calcul
  /// donne le même résultat à l'écran, à coût nul, et ne dépend de personne.
  ///
  /// `reservationTime == null` compte comme périmée, délibérément : une ligne
  /// `reservee` sans heure — donnée incohérente, saisie directe en base —
  /// bloquerait la table POUR TOUJOURS, puisque aucune heure ne peut être
  /// dépassée. En cas de doute, on libère.
  bool get hasLiveReservation {
    if (status != RestaurantTableStatus.reservee) return false;
    final at = reservationTime;
    if (at == null) return false;
    return DateTime.now().isBefore(at.add(reservationGrace));
  }

  /// L'heure de la réservation est-elle atteinte, sans que la courtoisie soit
  /// écoulée ? C'est l'état « client attendu » : la table est encore tenue.
  bool get isReservationOverdue =>
      hasLiveReservation && DateTime.now().isAfter(reservationTime!);

  /// Table disponible pour y asseoir des clients.
  ///
  /// Inclut les tables dont la RÉSERVATION EST PÉRIMÉE : la courtoisie écoulée,
  /// la table redevient libre sans que rien n'ait été écrit. Tous les lecteurs
  /// de ce getter en profitent d'un coup — la capacité de salle, la prise de
  /// commande, le menu d'actions, la suppression.
  ///
  /// ⚠ `status` n'est PAS une source fiable à lui seul : une table peut porter
  /// `reservee` avec une heure d'hier. Les écrans qui comparent directement le
  /// statut doivent passer par [displayStatus].
  bool get isFree =>
      status == RestaurantTableStatus.libre ||
      (status == RestaurantTableStatus.reservee && !hasLiveReservation);

  /// Statut TEL QU'IL DOIT S'AFFICHER — une réservation périmée retombe sur
  /// « Libre ».
  ///
  /// Sans lui, une table dont la courtoisie est écoulée resterait bleue et
  /// marquée « Réservée » alors que tout le reste de l'app la traite comme
  /// libre : l'écran dirait le contraire du comportement.
  RestaurantTableStatus get displayStatus =>
      (status == RestaurantTableStatus.reservee && !hasLiveReservation)
          ? RestaurantTableStatus.libre
          : status;

  /// Table retirée du plan de salle. Filtrée par `tablesForShop`.
  bool get isDeleted => deletedAt != null;

  /// Sentinelle interne : distingue « paramètre non fourni » de « mis à null »
  /// dans [copyWith]. Sans ça, impossible de libérer une table (remettre
  /// `covers`/`openedAt` à null) via copyWith.
  static const Object _unset = Object();

  RestaurantTable copyWith({
    String? name,
    int? number,
    int? capacity,
    RestaurantTableStatus? status,
    Object? deletedAt = _unset,
    Object? covers = _unset,
    Object? currentOrderId = _unset,
    Object? openedAt = _unset,
    Object? reservationTime = _unset,
    Object? reservationName = _unset,
  }) =>
      RestaurantTable(
        id: id,
        shopId: shopId,
        number: number ?? this.number,
        name: name ?? this.name,
        capacity: capacity ?? this.capacity,
        status: status ?? this.status,
        deletedAt:
            deletedAt == _unset ? this.deletedAt : deletedAt as DateTime?,
        covers: covers == _unset ? this.covers : covers as int?,
        currentOrderId: currentOrderId == _unset
            ? this.currentOrderId
            : currentOrderId as String?,
        openedAt: openedAt == _unset ? this.openedAt : openedAt as DateTime?,
        reservationTime: reservationTime == _unset
            ? this.reservationTime
            : reservationTime as DateTime?,
        reservationName: reservationName == _unset
            ? this.reservationName
            : reservationName as String?,
        createdAt: createdAt,
      );

  // Schema versioning — cf. lib/core/storage/schema_migrator.dart.
  static const int currentSchemaVersion = 1;
  static const SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {},
  );

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id': id,
        'shop_id': shopId,
        'number': number,
        'name': name,
        'capacity': capacity,
        'status': status.key,
        'covers': covers,
        'current_order_id': currentOrderId,
        'opened_at': openedAt?.toUtc().toIso8601String(),
        'reservation_time': reservationTime?.toUtc().toIso8601String(),
        'reservation_name': reservationName,
        'deleted_at': deletedAt?.toUtc().toIso8601String(),
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory RestaurantTable.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    // Lectures défensives : les lignes arrivent aussi bien de Hive que du
    // passthrough Supabase brut, où un champ peut manquer sur une ligne
    // écrite par une version antérieure de l'app.
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse(v.toString())?.toLocal();
    }

    return RestaurantTable(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      number: (m['number'] as num?)?.toInt() ?? 0,
      name: (m['name'] ?? '').toString(),
      capacity: (m['capacity'] as num?)?.toInt() ?? 4,
      status: RestaurantTableStatusX.fromKey(m['status']?.toString()),
      covers: (m['covers'] as num?)?.toInt(),
      currentOrderId: m['current_order_id']?.toString(),
      openedAt: parseDate(m['opened_at']),
      reservationTime: parseDate(m['reservation_time']),
      reservationName: m['reservation_name']?.toString(),
      // Pas de bump de `schema_version` pour cet ajout : la clé est optionnelle
      // et son absence se lit `null`, c'est-à-dire « vivante » — exactement ce
      // que valent les lignes écrites avant hotfix_180.
      deletedAt: parseDate(m['deleted_at']),
      createdAt: parseDate(m['created_at']) ?? DateTime.now(),
    );
  }
}
