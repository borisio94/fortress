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

  final DateTime createdAt;

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
  });

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
        'employee_id': employeeId,
        'employee_name': employeeName,
        'amount': amount,
        'reason': reason,
        'advance_date': dayKey(advanceDate),
        'deducted_from_month': deductedFromMonth,
        'is_deducted': isDeducted,
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
