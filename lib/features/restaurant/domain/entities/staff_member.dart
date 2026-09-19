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

  /// Cette personne a-t-elle un COMPTE dans l'application ?
  ///
  /// Un restaurant emploie deux populations que rien ne distinguait jusqu'ici :
  ///   * celles qui utilisent l'app — serveurs qui prennent les commandes,
  ///     caissiers, gérants. Leur fiche est rattachée à un compte, dont elle
  ///     recopie le nom et la fonction ;
  ///   * celles qui ne s'y connecteront JAMAIS — veilleur de nuit, homme de
  ///     ménage, plongeur. Elles n'ont pas de compte, mais elles ont un
  ///     salaire, des heures et des avances à tenir.
  ///
  /// La seconde population était impossible à inscrire : la fiche exigeait de
  /// choisir la personne parmi les comptes de la boutique. D'où ce drapeau —
  /// il décide aussi si le nom et la fonction se saisissent ici (sans compte)
  /// ou s'ils sont hérités (avec compte), pour que les deux ne divergent
  /// jamais.
  ///
  /// `true` pour toute fiche antérieure : elles ont toutes été créées depuis
  /// un compte (cf. migration de schéma v2).
  final bool hasAppAccess;

  /// Heure de fin de service PROPRE à cet employé, `HH:mm` (hotfix_165).
  ///
  /// `null` — le cas de loin le plus fréquent — signifie « suit l'heure de
  /// fermeture de l'établissement ». La surcharge existe pour les horaires
  /// décalés qu'un restaurant a toujours : le boulanger qui part à 11 h, le
  /// veilleur qui prend à la fermeture. Sans elle, ces gens-là accumuleraient
  /// chaque jour des heures supplémentaires imaginaires, ou devraient
  /// justifier un départ anticipé quotidien.
  final String? closingTime;

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
    this.hasAppAccess = true,
    this.closingTime,
  });

  /// L'employé peut-il badger ? Sans PIN configuré, il faut passer par une
  /// saisie manuelle du gérant.
  bool get hasPin => (pinHash ?? '').isNotEmpty && (pinSalt ?? '').isNotEmpty;

  /// Fonctions SUGGÉRÉES à la saisie. Ni exhaustives ni contraignantes : la
  /// base accepte n'importe quel libellé (cf. hotfix_148).
  /// Les postes proposés en raccourci à la saisie. Le champ reste libre : la
  /// liste couvre les cas courants, elle ne les enferme pas.
  ///
  /// `Livreur`, `Chawarmier` et `Glacier` manquaient alors que les trois
  /// existent dans l'établissement : le chawarma et la glacerie sont des
  /// activités déclarées, et une commande à livrer doit pouvoir désigner qui
  /// la porte.
  static const List<String> suggestedRoles = [
    'Gérant',
    'Caissier',
    'Serveur',
    'Cuisinier',
    'Aide-cuisine',
    'Chawarmier',
    'Glacier',
    'Barman',
    'Livreur',
    'Plongeur',
    'Agent d\'entretien',
  ];

  /// Poste des livreurs — sert à proposer les bonnes personnes au moment
  /// d'assigner une commande à livrer. Comparaison insensible à la casse et
  /// aux accents approximatifs d'une saisie libre.
  static bool isCourierRole(String role) =>
      role.trim().toLowerCase().startsWith('livreur');

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
    bool? hasAppAccess,
    String? closingTime,

    /// Retire le code de pointage : `copyWith(pinHash: null)` serait un no-op
    /// silencieux et l'employé continuerait de pouvoir badger.
    bool clearPin = false,

    /// Remet l'employé à l'horaire de la boutique — même raison que ci-dessus.
    bool clearClosingTime = false,
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
        hasAppAccess: hasAppAccess ?? this.hasAppAccess,
        closingTime:
            clearClosingTime ? null : (closingTime ?? this.closingTime),
      );

  static const int currentSchemaVersion = 3;
  static const SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {
      // v1 → v2 — arrivée du personnel SANS compte. Toute fiche écrite avant
      // vient forcément d'un compte : c'était la seule façon d'en créer une.
      // Pure et idempotente, elle ne fait que poser un drapeau à vrai.
      //
      // La clé est la version de DÉPART (cf. `SchemaMigrator.steps`). Elle
      // valait 2 : la step ne s'exécutait donc jamais — sans conséquence tant
      // que la version cible était 2, le `fromMap` retombant de toute façon
      // sur `true`. Elle en aurait eu une dès le passage à v3 : la step se
      // serait déclenchée sur des fiches v2 et aurait remis `has_app_access` à
      // vrai sur tout le personnel SANS compte, effaçant précisément ce que la
      // v2 était venue introduire.
      1: _markLegacyAsAccountHolder,
      // v2 → v3 — heure de fermeture propre à un employé. Purement additif :
      // absente, elle vaut null et l'employé suit l'horaire de la boutique.
    },
  );

  static Map<String, dynamic> _markLegacyAsAccountHolder(
          Map<String, dynamic> m) =>
      {...m, 'has_app_access': true};

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
        'has_app_access': hasAppAccess,
        'closing_time': closingTime,
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
      hasAppAccess: m['has_app_access'] as bool? ?? true,
      closingTime: _nullIfEmpty(m['closing_time']),
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
