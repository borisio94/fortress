import 'package:equatable/equatable.dart';
import '../../../auth/domain/entities/user.dart';

class ShopSummary extends Equatable {
  final String id;
  final String name;
  final String? logoUrl;
  final String currency;
  final String country;
  final String sector;
  final bool isActive;
  final double? todaySales;

  /// ID du créateur — devient automatiquement admin
  final String? ownerId;
  final String? phone;
  final String? email;

  /// Date de création (pour le DatePicker période personnalisée)
  final DateTime? createdAt;

  /// Membres de la boutique avec leurs rôles
  final List<ShopMembership> members;

  const ShopSummary({
    required this.id,
    required this.name,
    this.logoUrl,
    required this.currency,
    required this.country,
    required this.sector,
    this.isActive = true,
    this.todaySales,
    this.ownerId,
    this.phone,
    this.email,
    this.createdAt,
    this.members = const [],
  });

  /// Trouver le rôle d'un utilisateur dans cette boutique
  UserRole? roleOf(String userId) =>
      members.where((m) => m.shopId == id && m.shopId == userId).firstOrNull?.role
          ?? (userId == ownerId ? UserRole.admin : null);

  @override
  List<Object?> get props => [id, name, currency, country, sector, isActive, ownerId];
}
