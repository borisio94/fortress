import '../../domain/entities/client.dart';

/// Modèle de données pour la sérialisation/désérialisation du client
/// depuis Supabase et Hive. Aligne exactement sur l'entité [Client].
///
/// Note : [tag] n'est plus persisté — il est calculé dynamiquement depuis
/// [totalOrders] (cf. `Client.tag`). Conservé en lecture uniquement pour
/// tolérer les anciennes lignes Supabase qui avaient la colonne.
class ClientModel {
  final String  id;
  final String  storeId;
  final String  name;
  final String? phone;
  final String? email;
  final String? city;
  final String? district;
  /// Champ legacy concaténé "quartier, ville" — conservé pour compat
  /// avec les anciens clients et les colonnes Supabase existantes.
  final String? address;
  final String? notes;
  final String  createdAt;
  final String? lastVisitAt;
  final int     totalOrders;
  final double  totalSpent;

  const ClientModel({
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
  });

  factory ClientModel.fromMap(Map<String, dynamic> m) => ClientModel(
    id:           m['id']           as String,
    storeId:      (m['store_id'] ?? m['storeId'] ?? '') as String,
    name:         m['name']         as String,
    phone:        m['phone']        as String?,
    email:        m['email']        as String?,
    city:         m['city']         as String?,
    district:     m['district']     as String?,
    address:      m['address']      as String?,
    notes:        m['notes']        as String?,
    createdAt:    m['created_at']   as String,
    lastVisitAt:  m['last_visit_at'] as String?,
    totalOrders:  (m['total_orders'] as num?)?.toInt()    ?? 0,
    totalSpent:   (m['total_spent']  as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'id':           id,
    'store_id':     storeId,
    'name':         name,
    'phone':        phone,
    'email':        email,
    'city':         city,
    'district':     district,
    'address':      address,
    'notes':        notes,
    'created_at':   createdAt,
    'last_visit_at':lastVisitAt,
    'total_orders': totalOrders,
    'total_spent':  totalSpent,
  };

  factory ClientModel.fromEntity(Client c) => ClientModel(
    id:          c.id,
    storeId:     c.storeId,
    name:        c.name,
    phone:       c.phone,
    email:       c.email,
    city:        c.city,
    district:    c.district,
    address:     c.address,
    notes:       c.notes,
    createdAt:   c.createdAt.toIso8601String(),
    lastVisitAt: c.lastVisitAt?.toIso8601String(),
    totalOrders: c.totalOrders,
    totalSpent:  c.totalSpent,
  );

  Client toEntity() => Client(
    id:          id,
    storeId:     storeId,
    name:        name,
    phone:       phone,
    email:       email,
    city:        city,
    district:    district,
    address:     address,
    notes:       notes,
    createdAt:   DateTime.parse(createdAt),
    lastVisitAt: lastVisitAt != null ? DateTime.parse(lastVisitAt!) : null,
    totalOrders: totalOrders,
    totalSpent:  totalSpent,
  );
}
