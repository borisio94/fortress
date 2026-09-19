import '../../../../core/storage/schema_migrator.dart';

/// Avance sur salaire versée en cours de mois (Lot D — hotfix_148).
///
/// Pratique courante et non négociable dans un restaurant camerounais : le
/// personnel demande une avance en cours de mois. Sans suivi, elle est versée
/// puis oubliée — la boutique paie deux fois.
class SalaryAdvance {
  final String id;
  final String shopId;

  /// Ref logique vers `employees`.
  final String employeeId;

  /// Nom figé, pour que l'historique reste lisible après le départ de
  /// l'employé.
  final String? employeeName;

  final int amount;
  final String? reason;
  final DateTime advanceDate;

  /// Mois de paie sur lequel l'avance est retenue, au format `YYYY-MM`.
  /// Une avance de fin de mois se retient souvent sur le mois suivant.
  final String? deductedFromMonth;

  /// `true` une fois la fiche de paie du mois générée : l'avance a été
  /// effectivement retenue et ne doit plus l'être.
  final bool isDeducted;

  /// Avance versée EN ESPÈCES (défaut) : elle sort alors du tiroir et doit
  /// être déduite du total attendu à la clôture de caisse. Sans ce suivi, une
  /// avance de 20 000 F prise dans la caisse apparaît le soir comme un
  /// manquant de 20 000 F.
  final bool isCash;

  /// AVANCE ou QUINZAINE ? (hotfix_165)
  ///
  /// Les deux sortent de la même caisse et se retiennent sur la même paie,
  /// mais ne s'obtiennent pas de la même façon : la quinzaine est un DROIT —
  /// la moitié du salaire vers le milieu du mois, sans avoir à se justifier ;
  /// l'avance est une FAVEUR, demandée à tout moment et motivée.
  ///
  /// Les distinguer sert à deux choses : ne pas exiger de motif là où il n'en
  /// faut pas, et pouvoir dire à l'employé qui redemande une quinzaine qu'il
  /// l'a déjà touchée ce mois-ci.
  final String kind;

  final DateTime createdAt;

  static const String kindAdvance = 'advance';
  static const String kindFortnight = 'fortnight';

  const SalaryAdvance({
    required this.id,
    required this.shopId,
    required this.employeeId,
    required this.advanceDate,
    required this.createdAt,
    this.employeeName,
    this.amount = 0,
    this.reason,
    this.deductedFromMonth,
    this.isDeducted = false,
    this.isCash = true,
    this.kind = kindAdvance,
  });

  bool get isFortnight => kind == kindFortnight;

  /// PLAFOND DE LA QUINZAINE : la moitié du salaire de base.
  ///
  /// Au-delà, ce n'est plus une quinzaine mais une avance — qui, elle, se
  /// motive. Sans ce plafond, « toucher sa quinzaine » viderait le salaire du
  /// mois en une fois et l'employé se retrouverait à zéro le 30.
  static int fortnightCap(int baseSalary) =>
      baseSalary <= 0 ? 0 : baseSalary ~/ 2;

  /// Clé de mois `YYYY-MM` — le format de `payroll.month`, et donc la seule
  /// façon de rapprocher une avance d'une fiche de paie.
  static String monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}';

  /// Clé `yyyy-MM-dd` d'une date (stockage DATE sans heure).
  static String dayKey(DateTime d) =>
      '${monthKey(d)}-${d.day.toString().padLeft(2, '0')}';

  SalaryAdvance copyWith({
    int? amount,
    String? reason,
    DateTime? advanceDate,
    String? deductedFromMonth,
    bool? isDeducted,
    bool? isCash,
    String? kind,
  }) =>
      SalaryAdvance(
        id: id,
        shopId: shopId,
        employeeId: employeeId,
        employeeName: employeeName,
        createdAt: createdAt,
        amount: amount ?? this.amount,
        reason: reason ?? this.reason,
        advanceDate: advanceDate ?? this.advanceDate,
        deductedFromMonth: deductedFromMonth ?? this.deductedFromMonth,
        isDeducted: isDeducted ?? this.isDeducted,
        isCash: isCash ?? this.isCash,
        kind: kind ?? this.kind,
      );

  // v2 — la quinzaine (hotfix_165). Purement additif : une ligne écrite avant
  // la règle est forcément une avance, ce que donne déjà la valeur par défaut.
  static const int currentSchemaVersion = 2;
  static const SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {},
  );

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id': id,
        'shop_id': shopId,
        'employee_id': employeeId,
        'employee_name': employeeName,
        'amount': amount,
        'reason': reason,
        'advance_date': dayKey(advanceDate),
        'deducted_from_month': deductedFromMonth,
        'is_deducted': isDeducted,
        'is_cash': isCash,
        'kind': kind,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory SalaryAdvance.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    final date = DateTime.tryParse(m['advance_date']?.toString() ?? '') ??
        DateTime.now();
    return SalaryAdvance(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      employeeId: (m['employee_id'] ?? '').toString(),
      employeeName: _nullIfEmpty(m['employee_name']),
      amount: (m['amount'] as num?)?.toInt() ?? 0,
      reason: _nullIfEmpty(m['reason']),
      advanceDate: date,
      // Sans mois de retenue, l'avance serait invisible au moment de la paie :
      // on la rattache au mois où elle a été versée.
      deductedFromMonth:
          _nullIfEmpty(m['deducted_from_month']) ?? monthKey(date),
      isDeducted: m['is_deducted'] as bool? ?? false,
      isCash: m['is_cash'] as bool? ?? true,
      // Hors CHECK, l'upsert serait rejeté par Postgres et l'op droppée après
      // dix essais : une valeur inconnue retombe sur l'avance.
      kind: (m['kind']?.toString() == kindFortnight)
          ? kindFortnight
          : kindAdvance,
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
