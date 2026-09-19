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

  /// Minutes pointées sur le mois.
  final int minutesWorked;

  /// HEURES SUPPLÉMENTAIRES reportées sur cette fiche (hotfix_165).
  ///
  /// Séparées de [bonuses] et non fondues dedans : ce sont deux choses que
  /// l'employé lit différemment. Une prime est un geste du patron ; des heures
  /// supplémentaires sont un dû, calculé à partir de minutes pointées et d'un
  /// taux — et c'est la première ligne qu'il vérifie. Les additionner en un
  /// seul nombre rendrait la fiche incontestable, donc suspecte.
  final int overtimeAmount;

  /// Minutes supplémentaires que ce montant paie — la mention qui rend la
  /// ligne vérifiable.
  final int overtimeMinutes;

  /// Retenues pour CASSE, distinctes de [deductions] que le gérant saisit à la
  /// main. Une retenue automatique doit pouvoir être retrouvée dans la liste
  /// des pénalités, ligne par ligne.
  final int penaltiesDeducted;

  /// Retenues pour MISE À PIED SANS SOLDE (hotfix_166), et le nombre de jours
  /// qu'elles couvrent.
  ///
  /// Encore une ligne à part, pour la même raison que les deux précédentes :
  /// trois retenues de natures différentes fondues en un seul nombre donnent
  /// une fiche que personne ne peut vérifier. Ici la mention des jours est ce
  /// qui rend la retenue recalculable — salaire mensuel ÷ 30 × jours.
  final int absencesDeducted;
  final int absenceDays;

  final int netSalary;

  /// Date de versement effectif. `null` = fiche préparée, pas encore payée.
  final DateTime? paidAt;

  /// Salaire versé EN ESPÈCES (défaut) : il sort alors du tiroir à la date de
  /// [paidAt], et la clôture de caisse doit le déduire.
  final bool paidCash;

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
    this.overtimeAmount = 0,
    this.overtimeMinutes = 0,
    this.penaltiesDeducted = 0,
    this.absencesDeducted = 0,
    this.absenceDays = 0,
    this.netSalary = 0,
    this.paidAt,
    this.paidCash = true,
    this.notes,
  });

  bool get isPaid => paidAt != null;

  /// Ce que ce bulletin a COÛTÉ au restaurant — net versé PLUS les avances
  /// déjà décaissées.
  ///
  /// [netSalary] retranche les avances, et c'est juste pour le SALARIÉ : qui a
  /// pris 50 000 F le 10 n'en touche que 50 000 à la fin. Mais le restaurant,
  /// lui, a bien dépensé 100 000 F. Le bilan sommait les nets : il affichait
  /// 250 000 F pour une équipe qui en avait coûté 300 000, et surévaluait le
  /// bénéfice du montant exact sorti en avance.
  ///
  /// L'argent était pourtant bien parti, et le reste du logiciel le savait :
  /// `StaffService.cashOut` compte les avances en espèces pour que la clôture
  /// de caisse ne crie pas au manquant. Seul le bilan les ignorait.
  ///
  /// C'est aussi ce que rend l'estimation contractuelle (`payrollEstimateFor`,
  /// qui somme les salaires de base) : sans cette correction, la masse
  /// salariale changeait de nature au moment où le gérant générait ses fiches —
  /// coût du travail avant, argent versé après.
  ///
  /// À NE PAS UTILISER pour afficher un bulletin : le salarié touche bien son
  /// net. Ce getter sert au BILAN, pas à la fiche de paie.
  int get laborCost => netSalary + advancesDeducted;

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
    int overtime = 0,
    int penalties = 0,
    int absences = 0,
  }) {
    final net = baseSalary +
        bonuses +
        overtime -
        deductions -
        penalties -
        absences -
        advances;
    return net < 0 ? 0 : net;
  }

  Payslip copyWith({
    int? bonuses,
    int? deductions,
    int? advancesDeducted,
    int? overtimeAmount,
    int? overtimeMinutes,
    int? penaltiesDeducted,
    int? absencesDeducted,
    int? absenceDays,
    int? netSalary,
    DateTime? paidAt,
    bool? paidCash,
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
        overtimeAmount: overtimeAmount ?? this.overtimeAmount,
        overtimeMinutes: overtimeMinutes ?? this.overtimeMinutes,
        penaltiesDeducted: penaltiesDeducted ?? this.penaltiesDeducted,
        absencesDeducted: absencesDeducted ?? this.absencesDeducted,
        absenceDays: absenceDays ?? this.absenceDays,
        netSalary: netSalary ?? this.netSalary,
        paidAt: paidAt ?? this.paidAt,
        paidCash: paidCash ?? this.paidCash,
        notes: notes ?? this.notes,
      );

  // v2 — heures supplémentaires et casse détaillées (hotfix_165).
  // v3 — retenue de mise à pied (hotfix_166).
  // Les deux sont purement ADDITIVES : une fiche antérieure porte ces lignes à
  // zéro, et son net STOCKÉ reste celui qui a été versé — c'est bien ce qu'on
  // veut d'un document déjà remis.
  static const int currentSchemaVersion = 3;
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
        'overtime_amount': overtimeAmount,
        'overtime_minutes': overtimeMinutes,
        'penalties_deducted': penaltiesDeducted,
        'absences_deducted': absencesDeducted,
        'absence_days': absenceDays,
        'net_salary': netSalary,
        'paid_at': paidAt?.toUtc().toIso8601String(),
        'paid_cash': paidCash,
        'notes': notes,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory Payslip.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    final base = (m['base_salary'] as num?)?.toInt() ?? 0;
    final bonuses = (m['bonuses'] as num?)?.toInt() ?? 0;
    final deductions = (m['deductions'] as num?)?.toInt() ?? 0;
    final advances = (m['advances_deducted'] as num?)?.toInt() ?? 0;
    final overtime = (m['overtime_amount'] as num?)?.toInt() ?? 0;
    final penalties = (m['penalties_deducted'] as num?)?.toInt() ?? 0;
    final absences = (m['absences_deducted'] as num?)?.toInt() ?? 0;
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
      overtimeAmount: overtime,
      overtimeMinutes: (m['overtime_minutes'] as num?)?.toInt() ?? 0,
      penaltiesDeducted: penalties,
      absencesDeducted: absences,
      absenceDays: (m['absence_days'] as num?)?.toInt() ?? 0,
      // Le net STOCKÉ fait foi (c'est ce qui a été versé) ; on ne le
      // reconstruit que s'il manque.
      netSalary: (m['net_salary'] as num?)?.toInt() ??
          computeNet(
            baseSalary: base,
            bonuses: bonuses,
            deductions: deductions,
            advances: advances,
            overtime: overtime,
            penalties: penalties,
            absences: absences,
          ),
      paidAt: _parseDate(m['paid_at']),
      paidCash: m['paid_cash'] as bool? ?? true,
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
