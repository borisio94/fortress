import 'package:equatable/equatable.dart';

// ─── Rôles disponibles ────────────────────────────────────────────────────────
enum UserRole {
  admin,       // Tous les droits
  manager,     // Gestion boutique, inventaire, rapports
  cashier,     // Caisse uniquement
  viewer,      // Lecture seule
}

extension UserRoleX on UserRole {
  String get label => switch (this) {
    UserRole.admin   => 'Administrateur',
    UserRole.manager => 'Manager',
    UserRole.cashier => 'Caissier',
    UserRole.viewer  => 'Observateur',
  };

  String get key => name; // 'admin', 'manager', etc.

  bool get canManageShop      => this == UserRole.admin || this == UserRole.manager;
  bool get canManageInventory => this == UserRole.admin || this == UserRole.manager;
  bool get canAccessCaisse    => this != UserRole.viewer;
  bool get canViewReports     => this == UserRole.admin || this == UserRole.manager;
  bool get canManageUsers     => this == UserRole.admin;
  bool get canDeleteData      => this == UserRole.admin;
}

// ─── Appartenance à une boutique ─────────────────────────────────────────────
class ShopMembership extends Equatable {
  final String shopId;
  final String shopName;
  final UserRole role;
  final DateTime joinedAt;

  const ShopMembership({
    required this.shopId,
    required this.shopName,
    required this.role,
    required this.joinedAt,
  });

  bool get isAdmin => role == UserRole.admin;

  @override
  List<Object?> get props => [shopId, role];
}

// ─── Entité User ──────────────────────────────────────────────────────────────
class User extends Equatable {
  final String id;
  final String email;
  final String name;
  final String? phone;
  final String? avatarUrl;
  final DateTime createdAt;

  /// Boutiques auxquelles l'utilisateur appartient, avec son rôle dans chacune
  final List<ShopMembership> memberships;

  const User({
    required this.id,
    required this.email,
    required this.name,
    this.phone,
    this.avatarUrl,
    required this.createdAt,
    this.memberships = const [],
  });

  /// Rôle de l'utilisateur dans une boutique donnée
  UserRole? roleIn(String shopId) =>
      memberships.where((m) => m.shopId == shopId).firstOrNull?.role;

  /// L'utilisateur est-il admin d'une boutique donnée ?
  bool isAdminOf(String shopId) => roleIn(shopId) == UserRole.admin;

  /// L'utilisateur a-t-il accès à une boutique donnée ?
  bool hasAccessTo(String shopId) =>
      memberships.any((m) => m.shopId == shopId);

  /// Tous les droits admin → accès à toutes les boutiques comme admin
  bool get isSuperAdmin =>
      memberships.isNotEmpty &&
          memberships.every((m) => m.role == UserRole.admin);

  User copyWith({
    String? id, String? email, String? name,
    String? phone, String? avatarUrl, DateTime? createdAt,
    List<ShopMembership>? memberships,
  }) => User(
    id:          id          ?? this.id,
    email:       email       ?? this.email,
    name:        name        ?? this.name,
    phone:       phone       ?? this.phone,
    avatarUrl:   avatarUrl   ?? this.avatarUrl,
    createdAt:   createdAt   ?? this.createdAt,
    memberships: memberships ?? this.memberships,
  );

  @override
  List<Object?> get props => [id, email, name, memberships];
}
