import '../../domain/entities/user.dart';


// ShopMembershipModel — serialisation manuelle (pas de build_runner requis)
class ShopMembershipModel {
  final String shopId;
  final String shopName;
  final String role;
  final String joinedAt;

  const ShopMembershipModel({
    required this.shopId,
    required this.shopName,
    required this.role,
    required this.joinedAt,
  });

  ShopMembership toEntity() => ShopMembership(
    shopId:   shopId,
    shopName: shopName,
    role:     _roleFrom(role),
    joinedAt: DateTime.parse(joinedAt),
  );

  factory ShopMembershipModel.fromEntity(ShopMembership m) =>
      ShopMembershipModel(
        shopId:   m.shopId,
        shopName: m.shopName,
        role:     m.role.name,
        joinedAt: m.joinedAt.toIso8601String(),
      );

  static UserRole _roleFrom(String s) =>
      UserRole.values.firstWhere((r) => r.name == s,
          orElse: () => UserRole.cashier);
}

class UserModel {
  final String id;
  final String email;
  final String name;
  final String? phone;
  final String? avatarUrl;
  final DateTime createdAt;
  final List<ShopMembershipModel> memberships;

  const UserModel({
    required this.id,
    required this.email,
    required this.name,
    this.phone,
    this.avatarUrl,
    required this.createdAt,
    this.memberships = const [],
  });

  factory UserModel.fromMap(Map<String, dynamic> m) => UserModel(
    id:          m['id']         as String,
    email:       m['email']      as String,
    name:        m['name']       as String,
    phone:       m['phone']      as String?,
    avatarUrl:   m['avatar_url'] as String?,
    createdAt:   DateTime.parse(m['created_at'] as String),
    memberships: (m['memberships'] as List? ?? [])
        .map((e) => ShopMembershipModel.fromEntity(
        ShopMembership(
          shopId:   e['shop_id']   as String,
          shopName: e['shop_name'] as String,
          role:     UserRole.values.firstWhere(
                  (r) => r.name == e['role'],
              orElse: () => UserRole.cashier),
          joinedAt: DateTime.parse(e['joined_at'] as String),
        )))
        .toList(),
  );

  Map<String, dynamic> toMap() => {
    'id':          id,
    'email':       email,
    'name':        name,
    'phone':       phone,
    'avatar_url':  avatarUrl,
    'created_at':  createdAt.toIso8601String(),
    'memberships': memberships.map((m) => {
      'shop_id':   m.shopId,
      'shop_name': m.shopName,
      'role':      m.role,
      'joined_at': m.joinedAt,
    }).toList(),
  };

  factory UserModel.fromEntity(User u) => UserModel(
    id:          u.id,
    email:       u.email,
    name:        u.name,
    phone:       u.phone,
    avatarUrl:   u.avatarUrl,
    createdAt:   u.createdAt,
    memberships: u.memberships
        .map(ShopMembershipModel.fromEntity)
        .toList(),
  );

  User toEntity() => User(
    id:          id,
    email:       email,
    name:        name,
    phone:       phone,
    avatarUrl:   avatarUrl,
    createdAt:   createdAt,
    memberships: memberships.map((m) => m.toEntity()).toList(),
  );
}