import 'package:equatable/equatable.dart';

/// Segment dérivé automatiquement du nombre d'achats complétés du client.
/// Voir [Client.tag] : 0 → none, 1 → new_, 2-3 → regular, 4+ → vip.
enum ClientTag { vip, regular, new_, none }

extension ClientTagX on ClientTag {
  String get label => switch (this) {
    ClientTag.vip     => 'VIP',
    ClientTag.regular => 'Régulier',
    ClientTag.new_    => 'Nouveau',
    ClientTag.none    => '',
  };
  static ClientTag fromString(String? s) => switch (s) {
    'vip'     => ClientTag.vip,
    'regular' => ClientTag.regular,
    'new'     => ClientTag.new_,
    _         => ClientTag.none,
  };
  String get key => switch (this) {
    ClientTag.vip     => 'vip',
    ClientTag.regular => 'regular',
    ClientTag.new_    => 'new',
    ClientTag.none    => '',
  };
}

class Client extends Equatable {
  final String  id;
  final String  storeId;
  final String  name;
  final String? phone;
  final String? email;
  /// Ville — saisie libre avec autocomplétion des villes déjà connues.
  final String? city;
  /// Quartier — saisie libre avec autocomplétion des quartiers déjà connus.
  final String? district;
  /// Adresse texte libre (legacy / fallback). Conservée pour compatibilité
  /// descendante avec les anciens clients n'ayant pas de ville/quartier
  /// séparés. Nouveaux clients : laissé null.
  final String? address;
  final String? notes;
  final DateTime createdAt;
  final DateTime? lastVisitAt;
  final int     totalOrders;
  final double  totalSpent;

  /// Client archivé (soft-delete) : masqué des listes et sélecteurs par
  /// défaut, mais l'historique des commandes le référence toujours.
  final bool    isArchived;

  const Client({
    required this.id,
    required this.storeId,
    required this.name,
    this.phone,
    this.email,
    this.city,
    this.district,
    this.address,
    this.notes,
    required this.createdAt,
    this.lastVisitAt,
    this.totalOrders = 0,
    this.totalSpent  = 0,
    this.isArchived  = false,
  });

  /// Segment calculé à la volée depuis [totalOrders] — plus de champ manuel.
  /// Règle métier :
  ///   0 achat   → none (pas de badge)
  ///   1 achat   → new_ (Nouveau)
  ///   2-3 achats → regular (Régulier)
  ///   4+ achats → vip (VIP)
  ClientTag get tag {
    if (totalOrders >= 4) return ClientTag.vip;
    if (totalOrders >= 2) return ClientTag.regular;
    if (totalOrders >= 1) return ClientTag.new_;
    return ClientTag.none;
  }

  Client copyWith({
    String? name, String? phone, String? email,
    String? city, String? district,
    String? address, String? notes,
    DateTime? lastVisitAt, int? totalOrders, double? totalSpent,
    bool? isArchived,
  }) => Client(
    id:           id,
    storeId:      storeId,
    name:         name         ?? this.name,
    phone:        phone        ?? this.phone,
    email:        email        ?? this.email,
    city:         city         ?? this.city,
    district:     district     ?? this.district,
    address:      address      ?? this.address,
    notes:        notes        ?? this.notes,
    createdAt:    createdAt,
    lastVisitAt:  lastVisitAt  ?? this.lastVisitAt,
    totalOrders:  totalOrders  ?? this.totalOrders,
    totalSpent:   totalSpent   ?? this.totalSpent,
    isArchived:   isArchived   ?? this.isArchived,
  );

  @override
  List<Object?> get props =>
      [id, storeId, name, phone, email, city, district, address,
       totalOrders, isArchived];
}
