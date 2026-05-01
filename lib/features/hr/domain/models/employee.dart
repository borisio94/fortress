import 'employee_permission.dart';
import 'member_role.dart';

// ─── Employee model ────────────────────────────────────────────────────────
//
// Représente un membre d'une boutique avec ses permissions granulaires.
// Source : RPC `list_shop_employees(shop_id)` (jointure shop_memberships
// + profiles). Stocké en cache Hive pour offline-first.
// ───────────────────────────────────────────────────────────────────────────

class Employee {
  /// userId est en TEXT côté SQL (cf. casts dans hotfix_018).
  final String                  userId;
  final String                  shopId;
  final String                  fullName;
  final String                  email;
  final MemberRole            role;
  final EmployeeStatus          status;
  final Set<EmployeePermission> permissions;
  /// Permissions explicitement RETIRÉES (format `deny:perm` en JSONB).
  /// Préservées lors d'une mise à jour via le form RH même si ce dernier
  /// ne montre que les grants. Voir [MemberPermissions] pour la sémantique.
  final Set<EmployeePermission> denies;
  final DateTime?               createdAt;
  final String?                 createdBy;
  /// `true` si cet employé est aussi le `owner_id` du shop. L'app empêche
  /// la suppression / suspension du owner (logique côté SQL aussi).
  final bool                    isOwner;

  const Employee({
    required this.userId,
    required this.shopId,
    required this.fullName,
    required this.email,
    required this.role,
    required this.status,
    required this.permissions,
    this.denies = const {},
    this.createdAt,
    this.createdBy,
    this.isOwner = false,
  });

  bool get isActive    => status == EmployeeStatus.active;
  bool get isSuspended => status == EmployeeStatus.suspended;
  bool get isArchived  => status == EmployeeStatus.archived;

  bool hasPermission(EmployeePermission p) => permissions.contains(p);

  Employee copyWith({
    String?                  fullName,
    MemberRole?            role,
    EmployeeStatus?          status,
    Set<EmployeePermission>? permissions,
  }) => Employee(
    userId:      userId,
    shopId:      shopId,
    fullName:    fullName    ?? this.fullName,
    email:       email,
    role:        role        ?? this.role,
    status:      status      ?? this.status,
    permissions: permissions ?? this.permissions,
    createdAt:   createdAt,
    createdBy:   createdBy,
    isOwner:     isOwner,
  );

  /// Construction depuis le row retourné par la RPC `list_shop_employees`.
  factory Employee.fromRpc(String shopId, Map<String, dynamic> m) {
    final isOwner = (m['is_owner'] as bool?) ?? false;
    // Le propriétaire d'une boutique a TOUS les droits par définition,
    // même si sa ligne shop_memberships a `permissions = []` (cas typique
    // d'un compte qui a créé sa boutique sans passer par create_employee).
    final raw = m['permissions'];
    final parsed = (raw is List)
        ? MemberPermissions.fromList(raw)
        : MemberPermissions.empty;
    final perms = isOwner
        ? EmployeePermission.values.toSet()
        : parsed.grants;
    return Employee(
      userId:      (m['user_id']    ?? '').toString(),
      shopId:      shopId,
      fullName:    (m['full_name']  ?? '').toString(),
      email:       (m['email']      ?? '').toString(),
      role:        MemberRoleX.fromString(m['role'] as String?),
      status:      EmployeeStatusX.fromString(m['status'] as String?),
      permissions: perms,
      denies:      parsed.denies,
      createdAt:   _parseDate(m['created_at']),
      createdBy:   m['created_by'] as String?,
      isOwner:     isOwner,
    );
  }

  /// Sérialisation pour le cache Hive (clé `employees_<shopId>` →
  /// `List<Map>` indexée par userId). Inclut les denies au format JSONB
  /// pour qu'un round-trip cache → reload préserve la sémantique.
  Map<String, dynamic> toCacheMap() => {
    'user_id':     userId,
    'shop_id':     shopId,
    'full_name':   fullName,
    'email':       email,
    'role':        role.key,
    'status':      status.key,
    'permissions': MemberPermissions(grants: permissions, denies: denies)
                       .toList(),
    'created_at':  createdAt?.toIso8601String(),
    'created_by':  createdBy,
    'is_owner':    isOwner,
  };

  factory Employee.fromCacheMap(Map<String, dynamic> m) {
    final isOwner = (m['is_owner'] as bool?) ?? false;
    final raw = m['permissions'];
    final parsed = (raw is List)
        ? MemberPermissions.fromList(raw)
        : MemberPermissions.empty;
    final perms = isOwner
        ? EmployeePermission.values.toSet()
        : parsed.grants;
    return Employee(
      userId:      (m['user_id']   ?? '').toString(),
      shopId:      (m['shop_id']   ?? '').toString(),
      fullName:    (m['full_name'] ?? '').toString(),
      email:       (m['email']     ?? '').toString(),
      role:        MemberRoleX.fromString(m['role'] as String?),
      status:      EmployeeStatusX.fromString(m['status'] as String?),
      permissions: perms,
      denies:      parsed.denies,
      createdAt:   _parseDate(m['created_at']),
      createdBy:   m['created_by'] as String?,
      isOwner:     isOwner,
    );
  }

  static DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw)?.toLocal();
    return null;
  }
}
