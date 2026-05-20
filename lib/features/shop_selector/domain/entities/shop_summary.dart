import 'package:equatable/equatable.dart';
import '../../../auth/domain/entities/user.dart';

/// Type de boutique :
///   - [main]         : boutique principale, possède le catalogue source.
///   - [partnerDepot] : dépôt partenaire / boutique satellite, hérite du
///                       catalogue d'une boutique main via `parentShopId`.
enum ShopKind { main, partnerDepot }

extension ShopKindX on ShopKind {
  String get key => switch (this) {
    ShopKind.main         => 'main',
    ShopKind.partnerDepot => 'partner_depot',
  };

  static ShopKind fromKey(String? k) => switch (k) {
    'partner_depot' => ShopKind.partnerDepot,
    _               => ShopKind.main,
  };

  bool get isPartnerDepot => this == ShopKind.partnerDepot;
}

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
  /// Numéro WhatsApp DÉDIÉ (commandes/catalogue). Distinct de [phone]
  /// (contact affiché). Si null/vide, les liens wa.me retombent sur [phone].
  final String? whatsappPhone;
  final String? email;

  /// Date de création (pour le DatePicker période personnalisée)
  final DateTime? createdAt;

  /// Membres de la boutique avec leurs rôles
  final List<ShopMembership> members;

  /// Type de la boutique (cf. [ShopKind]). Défaut [ShopKind.main].
  final ShopKind kind;

  /// Pour kind=partnerDepot : id de la boutique main qui détient le
  /// catalogue. NULL pour main.
  final String? parentShopId;

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
    this.whatsappPhone,
    this.email,
    this.createdAt,
    this.members = const [],
    this.kind = ShopKind.main,
    this.parentShopId,
  });

  /// Trouver le rôle d'un utilisateur dans cette boutique
  UserRole? roleOf(String userId) =>
      members.where((m) => m.shopId == id && m.shopId == userId).firstOrNull?.role
          ?? (userId == ownerId ? UserRole.admin : null);

  /// Raccourcis sémantiques.
  bool get isMain         => kind == ShopKind.main;
  bool get isPartnerDepot => kind == ShopKind.partnerDepot;

  @override
  List<Object?> get props => [id, name, currency, country, sector, isActive,
      ownerId, kind, parentShopId];
}
