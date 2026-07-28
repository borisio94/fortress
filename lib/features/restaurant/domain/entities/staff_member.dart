import '../../../../core/storage/schema_migrator.dart';

/// Un membre du PERSONNEL du restaurant (table `employees`, Lot D).
///
/// À ne pas confondre avec `Employee` (module RH, `features/hr/`) qui désigne
/// un UTILISATEUR de l'application — quelqu'un qui a un compte, un mot de passe
/// et des permissions. Ici il s'agit des serveuses, cuisiniers et plongeurs :
/// ils ne se connectent jamais à l'app, mais ils ont un salaire, des heures et
/// des avances. D'où le nom distinct, pour qu'aucun import ne se trompe.
class StaffMember {
  final String id;
  final String shopId;
  final String fullName;

  /// Fonction, en texte libre : « serveuse », « aide-cuisine », « boy »…
  /// Volontairement non contraint (cf. hotfix_148).
  final String role;

  /// Salaire mensuel de base (FCFA entier).
  final int baseSalary;

  final DateTime hireDate;
  final String? phone;
  final bool isActive;

  /// Poste de rattachement, libre : « Cuisine », « Salle », « Bar ».
  final String? station;

  /// SHA-256(sel:PIN) du code de pointage. Jamais le PIN en clair — ces lignes
  /// sont synchronisées sur tous les appareils de la boutique.
  final String? pinHash;
  final String? pinSalt;

  final DateTime createdAt;

  const StaffMember({
    required this.id,
    required this.shopId,
    required this.fullName,
    required this.hireDate,
    required this.createdAt,
    this.role = '',
    this.baseSalary = 0,
    this.phone,
    this.isActive = true,
    this.station,
    this.pinHash,
    this.pinSalt,
  });

  /// L'employé peut-il badger ? Sans PIN configuré, il faut passer par une
  /// saisie manuelle du gérant.
  bool get hasPin => (pinHash ?? '').isNotEmpty && (pinSalt ?? '').isNotEmpty;

  /// Fonctions SUGGÉRÉES à la saisie. Ni exhaustives ni contraignantes : la
  /// base accepte n'importe quel libellé (cf. hotfix_148).
  static const List<String> suggestedRoles = [
    'Gérant',
    'Caissier',
    'Serveur',
    'Cuisinier',
    'Aide-cuisine',
    'Barman',
    'Plongeur',
    'Agent d\'entretien',
  ];

  /// Clé `yyyy-MM-dd` d'une date (stockage DATE sans heure).
  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  StaffMember copyWith({
    String? fullName,
    String? role,
    int? baseSalary,
    DateTime? hireDate,
    String? phone,
    bool? isActive,
    String? station,
    String? pinHash,
    String? pinSalt,

    /// Retire le code de pointage : `copyWith(pinHash: null)` serait un no-op
    /// silencieux et l'employé continuerait de pouvoir badger.
    bool clearPin = false,
  }) =>
      StaffMember(
        id: id,
        shopId: shopId,
        createdAt: createdAt,
        fullName: fullName ?? this.fullName,
        role: role ?? this.role,
        baseSalary: baseSalary ?? this.baseSalary,
        hireDate: hireDate ?? this.hireDate,
        phone: phone ?? this.phone,
        isActive: isActive ?? this.isActive,
        station: station ?? this.station,
        pinHash: clearPin ? null : (pinHash ?? this.pinHash),
        pinSalt: clearPin ? null : (pinSalt ?? this.pinSalt),
      );

  static const int currentSchemaVersion = 1;
  static const SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {},
  );

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id': id,
        'shop_id': shopId,
        'full_name': fullName,
        'role': role,
        'base_salary': baseSalary,
        'hire_date': dayKey(hireDate),
        'phone': phone,
        'is_active': isActive,
        'station': station,
        'pin_hash': pinHash,
        'pin_salt': pinSalt,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory StaffMember.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return StaffMember(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      fullName: (m['full_name'] ?? '').toString(),
      role: (m['role'] ?? '').toString(),
      baseSalary: (m['base_salary'] as num?)?.toInt() ?? 0,
      hireDate: DateTime.tryParse(m['hire_date']?.toString() ?? '') ??
          DateTime.now(),
      phone: _nullIfEmpty(m['phone']),
      isActive: m['is_active'] as bool? ?? true,
      station: _nullIfEmpty(m['station']),
      pinHash: _nullIfEmpty(m['pin_hash']),
      pinSalt: _nullIfEmpty(m['pin_salt']),
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }

  static String? _nullIfEmpty(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }
}
