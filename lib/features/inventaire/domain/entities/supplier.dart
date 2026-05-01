import 'package:equatable/equatable.dart';

class Supplier extends Equatable {
  final String  id;
  final String  shopId;
  final String  name;
  final String? phone;
  final String? email;
  final String? address;
  final String? notes;
  final bool    isActive;
  final DateTime createdAt;

  const Supplier({
    required this.id,
    required this.shopId,
    required this.name,
    this.phone,
    this.email,
    this.address,
    this.notes,
    this.isActive = true,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id, 'shop_id': shopId, 'name': name,
    'phone': phone, 'email': email, 'address': address,
    'notes': notes, 'is_active': isActive,
    'created_at': createdAt.toIso8601String(),
  };

  factory Supplier.fromMap(Map<String, dynamic> m) => Supplier(
    id:        m['id'] as String,
    shopId:    m['shop_id'] as String,
    name:      m['name'] as String? ?? '',
    phone:     m['phone'] as String?,
    email:     m['email'] as String?,
    address:   m['address'] as String?,
    notes:     m['notes'] as String?,
    isActive:  m['is_active'] as bool? ?? true,
    createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '') ?? DateTime.now(),
  );

  @override List<Object?> get props => [id, shopId, name];
}
