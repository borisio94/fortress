import '../../../../core/storage/schema_migrator.dart';

/// Fiche de paie mensuelle d'un membre du personnel (table `payroll`, Lot D).
///
/// Le net est STOCKÉ, pas recalculé à la lecture : une fiche remise à l'employé
/// est un document. Si le salaire de base change en septembre, la fiche de
/// juillet doit continuer d'afficher ce qui a été versé en juillet.
class Payslip {
  final String id;
  final String shopId;

  /// Ref logique vers `employees`.
  final String employeeId;
  final String? employeeName;

  /// Mois de paie au format `YYYY-MM`.
  final String month;

  final int baseSalary;

  /// Primes, commissions, heures supplémentaires — tout ce qui s'ajoute.
  final int bonuses;

  /// Retenues hors avances : pénalités, retards, casse imputée.
  final int deductions;

  /// Avances déjà versées et retenues sur cette fiche.
  final int advancesDeducted;

  /// Minutes pointées sur le mois. INFORMATIF : aucune prime d'heures
  /// supplémentaires n'est calculée automatiquement — le taux dépend d'un
  /// accord que l'application ne connaît pas. Le gérant le saisit en [bonuses].
  final int minutesWorked;

  final int netSalary;

  /// Date de versement effectif. `null` = fiche préparée, pas encore payée.
  final DateTime? paidAt;

  final String? notes;
  final DateTime createdAt;

  const Payslip({
    required this.id,
    required this.shopId,
    required this.employeeId,
    required this.month,
    required this.createdAt,
    this.employeeName,
    this.baseSalary = 0,
    this.bonuses = 0,
    this.deductions = 0,
    this.advancesDeducted = 0,
    this.minutesWorked = 0,
    this.netSalary = 0,
    this.paidAt,
    this.notes,
  });

  bool get isPaid => paidAt != null;

  /// LE calcul de la paie. Fonction pure — c'est le montant qu'un employé
  /// reçoit, il ne doit avoir qu'une seule définition.
  ///
  /// Le net PEUT être nul mais jamais négatif : si les avances dépassent le
  /// salaire, on ne réclame pas d'argent à l'employé en fin de mois. Le
  /// reliquat reste dû via les avances non soldées ; verser un net négatif
  /// n'aurait aucun sens sur une fiche de paie.
  static int computeNet({
    required int baseSalary,
    int bonuses = 0,
    int deductions = 0,
    int advances = 0,
  }) {
    final net = baseSalary + bonuses - deductions - advances;
    return net < 0 ? 0 : net;
  }

  Payslip copyWith({
    int? bonuses,
    int? deductions,
    int? advancesDeducted,
    int? netSalary,
    DateTime? paidAt,
    String? notes,
  }) =>
      Payslip(
        id: id,
        shopId: shopId,
        employeeId: employeeId,
        employeeName: employeeName,
        month: month,
        createdAt: createdAt,
        baseSalary: baseSalary,
        bonuses: bonuses ?? this.bonuses,
        deductions: deductions ?? this.deductions,
        advancesDeducted: advancesDeducted ?? this.advancesDeducted,
        minutesWorked: minutesWorked,
        netSalary: netSalary ?? this.netSalary,
        paidAt: paidAt ?? this.paidAt,
        notes: notes ?? this.notes,
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
        'month': month,
        'base_salary': baseSalary,
        'bonuses': bonuses,
        'deductions': deductions,
        'advances_deducted': advancesDeducted,
        'minutes_worked': minutesWorked,
        'net_salary': netSalary,
        'paid_at': paidAt?.toUtc().toIso8601String(),
        'notes': notes,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory Payslip.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    final base = (m['base_salary'] as num?)?.toInt() ?? 0;
    final bonuses = (m['bonuses'] as num?)?.toInt() ?? 0;
    final deductions = (m['deductions'] as num?)?.toInt() ?? 0;
    final advances = (m['advances_deducted'] as num?)?.toInt() ?? 0;
    return Payslip(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      employeeId: (m['employee_id'] ?? '').toString(),
      employeeName: _nullIfEmpty(m['employee_name']),
      month: (m['month'] ?? '').toString(),
      baseSalary: base,
      bonuses: bonuses,
      deductions: deductions,
      advancesDeducted: advances,
      minutesWorked: (m['minutes_worked'] as num?)?.toInt() ?? 0,
      // Le net STOCKÉ fait foi (c'est ce qui a été versé) ; on ne le
      // reconstruit que s'il manque.
      netSalary: (m['net_salary'] as num?)?.toInt() ??
          computeNet(
            baseSalary: base,
            bonuses: bonuses,
            deductions: deductions,
            advances: advances,
          ),
      paidAt: _parseDate(m['paid_at']),
      notes: _nullIfEmpty(m['notes']),
      createdAt: _parseDate(m['created_at']) ?? DateTime.now(),
    );
  }

  static DateTime? _parseDate(dynamic v) {
    final s = v?.toString() ?? '';
    if (s.isEmpty) return null;
    return DateTime.tryParse(s)?.toLocal();
  }

  static String? _nullIfEmpty(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }
}
