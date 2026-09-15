import '../../../../core/storage/schema_migrator.dart';

/// Un service pointé : une entrée, puis une sortie (Lot D — hotfix_148).
///
/// Tant que [clockOut] est nul, l'employé est EN SERVICE — c'est cet état qui
/// décide, au badge suivant, s'il entre ou s'il sort.
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
  });

  /// Service en cours : badgé à l'entrée, pas encore à la sortie.
  bool get isOpen => clockOut == null;

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
        'clock_in': clockIn?.toUtc().toIso8601String(),
        'clock_out': clockOut?.toUtc().toIso8601String(),
        'duration_minutes': durationMinutes,
        'method': method,
        'note': note,
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
