import '../../../../core/storage/schema_migrator.dart';
import 'shift_evaluation.dart';

/// Un service pointé : une entrée, puis une sortie (Lot D — hotfix_148).
///
/// Tant que [clockOut] est nul, l'employé est EN SERVICE — c'est cet état qui
/// décide, au badge suivant, s'il entre ou s'il sort.
///
/// Depuis hotfix_165, la sortie est aussi JUGÉE : partir avant l'heure de
/// fermeture appelle une excuse, partir après crée des heures supplémentaires.
/// Tout ce que cette comparaison produit est FIGÉ ici à la sortie — l'heure de
/// référence, les minutes, le taux, le montant. Rien n'est recalculé à la
/// lecture : l'établissement qui change son horaire ou le taux d'un poste en
/// novembre ne doit pas réécrire les heures supplémentaires de septembre.
class TimeRecord {
  final String id;
  final String shopId;

  /// Ref logique vers `employees`.
  final String employeeId;

  /// Nom figé : un employé parti l'an dernier doit rester lisible dans
  /// l'historique des heures, même si sa fiche a été supprimée.
  final String? employeeName;

  final DateTime? clockIn;
  final DateTime? clockOut;

  /// Durée FIGÉE à la sortie, en minutes.
  ///
  /// Stockée plutôt que recalculée : un pointage corrigé à la main par le
  /// gérant (oubli de badge) doit garder la durée qu'il a validée, pas celle
  /// que redonneraient deux horodatages approximatifs.
  final int? durationMinutes;

  /// 'pin' · 'qr_code' · 'manual'.
  final String method;

  final String? note;

  /// Heure de fin PRÉVUE pour ce service, figée à la sortie. `null` quand
  /// l'établissement n'a pas réglé d'horaire : rien n'est alors jugé.
  final DateTime? scheduledEnd;

  /// Minutes manquantes avant l'heure prévue (départ anticipé).
  final int earlyMinutes;

  /// L'excuse donnée par l'employé à la badgeuse, telle qu'il l'a dictée.
  final String? earlyExcuse;

  /// Le gérant l'a-t-il acceptée ? Voir [ExcuseStatus] — un refus ne retient
  /// RIEN tout seul, il signale.
  final ExcuseStatus excuseStatus;

  /// Minutes travaillées au-delà de l'heure prévue.
  final int overtimeMinutes;

  /// Taux horaire appliqué, FIGÉ. Celui de la fonction de l'employé au moment
  /// du service.
  final int overtimeRate;

  /// Montant dû pour ces heures, FIGÉ.
  final int overtimeAmount;

  /// Payées de suite, reportées sur la paie, ou pas encore tranché.
  final OvertimeSettlement overtimeSettlement;

  /// `true` une fois l'argent effectivement sorti — versé de la main à la
  /// main, ou porté sur une fiche de paie générée. Même rôle que
  /// `SalaryAdvance.isDeducted` : sans lui, les mêmes heures seraient payées
  /// à chaque génération de fiche.
  final bool overtimeSettled;

  final DateTime createdAt;

  const TimeRecord({
    required this.id,
    required this.shopId,
    required this.employeeId,
    required this.createdAt,
    this.employeeName,
    this.clockIn,
    this.clockOut,
    this.durationMinutes,
    this.method = 'pin',
    this.note,
    this.scheduledEnd,
    this.earlyMinutes = 0,
    this.earlyExcuse,
    this.excuseStatus = ExcuseStatus.none,
    this.overtimeMinutes = 0,
    this.overtimeRate = 0,
    this.overtimeAmount = 0,
    this.overtimeSettlement = OvertimeSettlement.pending,
    this.overtimeSettled = false,
  });

  /// Service en cours : badgé à l'entrée, pas encore à la sortie.
  bool get isOpen => clockOut == null;

  bool get hasOvertime => overtimeMinutes > 0;
  bool get isEarly => earlyMinutes > 0;

  /// Heures supplémentaires en attente d'une décision du gérant.
  bool get overtimeToSettle =>
      hasOvertime &&
      !overtimeSettled &&
      overtimeSettlement == OvertimeSettlement.pending;

  /// Excuse fournie mais pas encore jugée — c'est ce qui doit remonter au
  /// gérant, un départ anticipé sans décision restant une ardoise ouverte.
  bool get excuseToJudge => excuseStatus == ExcuseStatus.pending;

  /// Départ anticipé que personne n'a justifié : ni excuse donnée, ni excuse
  /// acceptée. C'est le seul cas que la paie signale au gérant.
  bool get isUnexcused =>
      isEarly &&
      (excuseStatus == ExcuseStatus.none ||
          excuseStatus == ExcuseStatus.refused);

  /// Durée réellement travaillée. Utilise [durationMinutes] s'il est figé,
  /// sinon le temps écoulé depuis l'entrée (service en cours).
  Duration get worked {
    if (durationMinutes != null) return Duration(minutes: durationMinutes!);
    final start = clockIn;
    if (start == null) return Duration.zero;
    final end = clockOut ?? DateTime.now();
    final d = end.difference(start);
    // Une horloge d'appareil mal réglée produirait une durée négative : on
    // préfère zéro à « −3 h » dans un total d'heures du mois.
    return d.isNegative ? Duration.zero : d;
  }

  /// Minutes entre deux horodatages, jamais négatives. Fonction pure : c'est
  /// elle qui alimente le total d'heures d'une fiche de paie.
  static int minutesBetween(DateTime start, DateTime end) {
    final m = end.difference(start).inMinutes;
    return m < 0 ? 0 : m;
  }

  /// Format court « 7h30 » / « 45 min » pour l'affichage.
  static String formatMinutes(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h${m.toString().padLeft(2, '0')}';
  }

  TimeRecord copyWith({
    DateTime? clockOut,
    int? durationMinutes,
    String? method,
    String? note,
    DateTime? scheduledEnd,
    int? earlyMinutes,
    String? earlyExcuse,
    ExcuseStatus? excuseStatus,
    int? overtimeMinutes,
    int? overtimeRate,
    int? overtimeAmount,
    OvertimeSettlement? overtimeSettlement,
    bool? overtimeSettled,
  }) =>
      TimeRecord(
        id: id,
        shopId: shopId,
        employeeId: employeeId,
        employeeName: employeeName,
        createdAt: createdAt,
        clockIn: clockIn,
        clockOut: clockOut ?? this.clockOut,
        durationMinutes: durationMinutes ?? this.durationMinutes,
        method: method ?? this.method,
        note: note ?? this.note,
        scheduledEnd: scheduledEnd ?? this.scheduledEnd,
        earlyMinutes: earlyMinutes ?? this.earlyMinutes,
        earlyExcuse: earlyExcuse ?? this.earlyExcuse,
        excuseStatus: excuseStatus ?? this.excuseStatus,
        overtimeMinutes: overtimeMinutes ?? this.overtimeMinutes,
        overtimeRate: overtimeRate ?? this.overtimeRate,
        overtimeAmount: overtimeAmount ?? this.overtimeAmount,
        overtimeSettlement: overtimeSettlement ?? this.overtimeSettlement,
        overtimeSettled: overtimeSettled ?? this.overtimeSettled,
      );

  // v2 — jugement de la sortie (hotfix_165). Purement ADDITIF : les champs
  // absents d'un pointage v1 valent zéro, `none` et `pending`, ce qui décrit
  // exactement un service d'avant la règle — rien à juger, rien à payer. Aucune
  // step n'est donc nécessaire.
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
        'clock_in': clockIn?.toUtc().toIso8601String(),
        'clock_out': clockOut?.toUtc().toIso8601String(),
        'duration_minutes': durationMinutes,
        'method': method,
        'note': note,
        'scheduled_end': scheduledEnd?.toUtc().toIso8601String(),
        'early_minutes': earlyMinutes,
        'early_excuse': earlyExcuse,
        'excuse_status': excuseStatus.key,
        'overtime_minutes': overtimeMinutes,
        'overtime_rate': overtimeRate,
        'overtime_amount': overtimeAmount,
        'overtime_settlement': overtimeSettlement.key,
        'overtime_settled': overtimeSettled,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory TimeRecord.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    final method = (m['method'] ?? 'pin').toString();
    return TimeRecord(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      employeeId: (m['employee_id'] ?? '').toString(),
      employeeName: _nullIfEmpty(m['employee_name']),
      clockIn: _parseDate(m['clock_in']),
      clockOut: _parseDate(m['clock_out']),
      durationMinutes: (m['duration_minutes'] as num?)?.toInt(),
      // Hors CHECK, l'upsert serait rejeté par Postgres et l'op droppée après
      // dix essais : on retombe sur le mode le plus courant.
      method: const {'pin', 'qr_code', 'manual'}.contains(method)
          ? method
          : 'pin',
      note: _nullIfEmpty(m['note']),
      scheduledEnd: _parseDate(m['scheduled_end']),
      earlyMinutes: (m['early_minutes'] as num?)?.toInt() ?? 0,
      earlyExcuse: _nullIfEmpty(m['early_excuse']),
      excuseStatus: ExcuseStatusX.fromKey(m['excuse_status']?.toString()),
      overtimeMinutes: (m['overtime_minutes'] as num?)?.toInt() ?? 0,
      overtimeRate: (m['overtime_rate'] as num?)?.toInt() ?? 0,
      overtimeAmount: (m['overtime_amount'] as num?)?.toInt() ?? 0,
      overtimeSettlement:
          OvertimeSettlementX.fromKey(m['overtime_settlement']?.toString()),
      overtimeSettled: m['overtime_settled'] as bool? ?? false,
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
