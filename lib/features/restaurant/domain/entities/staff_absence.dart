import '../../../../core/storage/schema_migrator.dart';

/// ABSENCE DÉCIDÉE — mise à pied ou congé payé (hotfix_166).
///
/// À ne pas confondre avec un départ anticipé, qui est un écart CONSTATÉ sur un
/// pointage : ici l'absence est décidée à l'avance, elle couvre des journées
/// entières, et personne n'est censé badger pendant.
///
/// Les deux formes partagent tout — des dates, un motif obligatoire, un effet
/// possible sur le salaire — et ne diffèrent que par ce qu'elles racontent :
/// l'une sanctionne, l'autre récompense. Les séparer en deux tables aurait
/// dupliqué le calendrier, le calcul de retenue et le contrôle de la badgeuse
/// pour ne gagner qu'un libellé.
enum AbsenceKind {
  /// Mise à pied : l'employé est écarté du service. Sans solde par défaut,
  /// mais le gérant peut la maintenir payée — c'est le cas de la mise à pied
  /// CONSERVATOIRE, prononcée le temps de vérifier les faits. Sanctionner
  /// avant d'avoir vérifié serait exactement ce qu'elle sert à éviter.
  suspension,

  /// Congé payé : le salaire est maintenu, intégralement et toujours.
  paidLeave,
}

extension AbsenceKindX on AbsenceKind {
  String get key => switch (this) {
        AbsenceKind.suspension => 'suspension',
        AbsenceKind.paidLeave => 'paid_leave',
      };

  String get label => switch (this) {
        AbsenceKind.suspension => 'Mise à pied',
        AbsenceKind.paidLeave => 'Congé payé',
      };

  /// Une clé inconnue retombe sur le congé payé — la forme qui ne retient
  /// RIEN. Se tromper dans ce sens ne coûte que de l'argent à l'employeur ;
  /// dans l'autre, on ampute le salaire de quelqu'un sur une valeur qu'on n'a
  /// pas su lire.
  static AbsenceKind fromKey(String? raw) => switch (raw?.trim()) {
        'suspension' => AbsenceKind.suspension,
        _ => AbsenceKind.paidLeave,
      };
}

class StaffAbsence {
  final String id;
  final String shopId;

  /// Ref logique vers `employees`.
  final String employeeId;

  /// Nom figé : l'absence d'un employé parti doit rester lisible.
  final String? employeeName;

  final AbsenceKind kind;

  /// Premier et DERNIER jour de l'absence, tous deux inclus.
  ///
  /// Inclusifs et non « jusqu'au matin du » : « du 10 au 12 » se compte trois
  /// jours pour tout le monde, et une absence d'un seul jour s'écrit avec la
  /// même date deux fois plutôt qu'avec une durée nulle.
  final DateTime startDate;
  final DateTime endDate;

  /// Le motif. Obligatoire : une mise à pied sans raison écrite est
  /// indéfendable, et un congé sans motif ne se distingue plus d'un oubli de
  /// pointage.
  final String reason;

  /// Le salaire est-il maintenu ? TOUJOURS vrai pour un congé payé.
  final bool isPaid;

  /// Cumul déjà retenu sur des fiches de paie. Même rôle que
  /// `StaffPenalty.amountRecovered` : sans lui, une absence à cheval sur deux
  /// mois serait retenue deux fois en entier.
  final int amountDeducted;

  final DateTime createdAt;

  /// Absence annulée. La ligne est conservée : « la mise à pied a été levée »
  /// est une information, l'effacer laisserait croire qu'elle n'a jamais eu
  /// lieu.
  final DateTime? cancelledAt;

  const StaffAbsence({
    required this.id,
    required this.shopId,
    required this.employeeId,
    required this.kind,
    required this.startDate,
    required this.endDate,
    required this.reason,
    required this.createdAt,
    this.employeeName,
    this.isPaid = false,
    this.amountDeducted = 0,
    this.cancelledAt,
  });

  bool get isCancelled => cancelledAt != null;

  /// Le salaire est-il amputé ? Un congé payé ne l'est jamais, une mise à pied
  /// maintenue payée non plus, une absence annulée pas davantage.
  bool get hitsPayroll =>
      !isCancelled && kind == AbsenceKind.suspension && !isPaid;

  /// Nombre de jours couverts, bornes incluses. Jamais moins de 1 : une
  /// absence qui ne dure aucun jour n'a pas de sens, et une fin saisie avant
  /// le début vaut une journée plutôt qu'une durée négative.
  int get days {
    final d = _dayOnly(endDate).difference(_dayOnly(startDate)).inDays + 1;
    return d < 1 ? 1 : d;
  }

  /// L'absence couvre-t-elle ce jour ? C'est la question de la badgeuse.
  bool coversDay(DateTime d) {
    if (isCancelled) return false;
    final day = _dayOnly(d);
    return !day.isBefore(_dayOnly(startDate)) &&
        !day.isAfter(_dayOnly(endDate));
  }

  /// Jours de cette absence qui tombent dans le mois `YYYY-MM`.
  ///
  /// Une mise à pied du 28 au 3 pèse sur deux paies : sans ce découpage, la
  /// retenue entière tomberait sur le mois de départ et le bulletin suivant
  /// serait faux.
  int daysInMonth(String month) {
    var count = 0;
    var cursor = _dayOnly(startDate);
    final last = _dayOnly(endDate);
    // Borne de sécurité : une saisie aberrante (fin en 2099) ne doit pas
    // boucler indéfiniment au moment de préparer une paie.
    var guard = 0;
    while (!cursor.isAfter(last) && guard < 3660) {
      if (monthKey(cursor) == month) count++;
      cursor = cursor.add(const Duration(days: 1));
      guard++;
    }
    return count;
  }

  /// COÛT D'UNE JOURNÉE D'ABSENCE : le salaire mensuel divisé par 30.
  ///
  /// Trente et non le nombre réel de jours du mois : c'est le diviseur que
  /// tout le monde utilise et vérifie de tête, et il donne la même retenue en
  /// février qu'en mars pour une même absence — ce qu'un employé comprend,
  /// contrairement à deux montants différents pour trois jours manqués.
  static int dailyRate(int baseSalary) =>
      baseSalary <= 0 ? 0 : (baseSalary / 30).round();

  /// Retenue totale que cette absence représente.
  int totalDeduction(int baseSalary) =>
      hitsPayroll ? dailyRate(baseSalary) * days : 0;

  /// Reste à retenir.
  int remaining(int baseSalary) {
    final r = totalDeduction(baseSalary) - amountDeducted;
    return r < 0 ? 0 : r;
  }

  /// CE QUI DOIT ÊTRE RETENU sur la paie de [month]. La règle, telle quelle.
  int dueFor(String month, int baseSalary) {
    if (!hitsPayroll) return 0;
    final share = dailyRate(baseSalary) * daysInMonth(month);
    final left = remaining(baseSalary);
    return share > left ? left : share;
  }

  StaffAbsence copyWith({
    AbsenceKind? kind,
    DateTime? startDate,
    DateTime? endDate,
    String? reason,
    bool? isPaid,
    int? amountDeducted,
    DateTime? cancelledAt,
    bool clearCancelled = false,
  }) =>
      StaffAbsence(
        id: id,
        shopId: shopId,
        employeeId: employeeId,
        employeeName: employeeName,
        createdAt: createdAt,
        kind: kind ?? this.kind,
        startDate: startDate ?? this.startDate,
        endDate: endDate ?? this.endDate,
        reason: reason ?? this.reason,
        isPaid: isPaid ?? this.isPaid,
        amountDeducted: amountDeducted ?? this.amountDeducted,
        cancelledAt: clearCancelled ? null : (cancelledAt ?? this.cancelledAt),
      );

  /// Encaisse [value] sur la retenue due.
  StaffAbsence deduct(int value) {
    final next = amountDeducted + (value < 0 ? 0 : value);
    return copyWith(amountDeducted: next < 0 ? 0 : next);
  }

  static DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static String monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}';

  static String dayKey(DateTime d) =>
      '${monthKey(d)}-${d.day.toString().padLeft(2, '0')}';

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
        'kind': kind.key,
        'start_date': dayKey(startDate),
        'end_date': dayKey(endDate),
        'reason': reason,
        'is_paid': isPaid,
        'amount_deducted': amountDeducted,
        'cancelled_at': cancelledAt?.toUtc().toIso8601String(),
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory StaffAbsence.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    final kind = AbsenceKindX.fromKey(m['kind']?.toString());
    final start =
        DateTime.tryParse(m['start_date']?.toString() ?? '') ?? DateTime.now();
    return StaffAbsence(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      employeeId: (m['employee_id'] ?? '').toString(),
      employeeName: _nullIfEmpty(m['employee_name']),
      kind: kind,
      startDate: start,
      endDate: DateTime.tryParse(m['end_date']?.toString() ?? '') ?? start,
      reason: (m['reason'] ?? '').toString(),
      // Un congé payé l'est PAR DÉFINITION : le drapeau stocké ne peut pas le
      // contredire, sans quoi une ligne corrompue amputerait un salaire.
      isPaid: kind == AbsenceKind.paidLeave || (m['is_paid'] as bool? ?? false),
      amountDeducted: (m['amount_deducted'] as num?)?.toInt() ?? 0,
      cancelledAt: _parseDate(m['cancelled_at']),
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
