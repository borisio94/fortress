import '../../../../core/storage/schema_migrator.dart';

/// NOTATION DU PERSONNEL — un événement de points (hotfix_165).
///
/// Chaque employé démarre le mois à 10 points. Une plainte client jugée
/// FONDÉE par le gérant en retranche ; un service remarquable en ajoute. Ce
/// qui est stocké, ce n'est jamais la note — c'est l'événement qui l'a fait
/// bouger, avec son motif.
///
/// Pourquoi l'événement et pas la note : une note seule ne se conteste pas.
/// Un employé descendu à 6 a le droit de savoir quelles trois décisions l'y
/// ont mené, et le gérant qui s'est trompé doit pouvoir en retirer une sans
/// avoir à recalculer quoi que ce soit. La note, elle, se redéduit à tout
/// moment de la somme des événements du mois.
class StaffRating {
  final String id;
  final String shopId;

  /// Ref logique vers `employees`.
  final String employeeId;

  /// Nom figé, pour que l'historique survive au départ de l'employé.
  final String? employeeName;

  /// Points, SIGNÉS : négatif pour une sanction, positif pour un bonus.
  final int points;

  /// La raison exacte. Obligatoire : retirer des points sans dire pourquoi
  /// est le meilleur moyen de rendre la note incompréhensible — et injuste.
  final String reason;

  /// D'où vient l'événement : `complaint` (plainte client jugée fondée),
  /// `bonus` (employé modèle), `other`.
  final String source;

  /// Mois de rattachement `YYYY-MM`. C'est lui qui décide sur quelle note
  /// l'événement pèse — et le fait cesser de peser au mois suivant.
  final String month;

  final DateTime createdAt;

  const StaffRating({
    required this.id,
    required this.shopId,
    required this.employeeId,
    required this.points,
    required this.reason,
    required this.month,
    required this.createdAt,
    this.employeeName,
    this.source = 'other',
  });

  bool get isPenalty => points < 0;
  bool get isBonus => points > 0;

  static const String sourceComplaint = 'complaint';
  static const String sourceBonus = 'bonus';
  static const String sourceOther = 'other';

  static String monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}';

  StaffRating copyWith({int? points, String? reason, String? source}) =>
      StaffRating(
        id: id,
        shopId: shopId,
        employeeId: employeeId,
        employeeName: employeeName,
        month: month,
        createdAt: createdAt,
        points: points ?? this.points,
        reason: reason ?? this.reason,
        source: source ?? this.source,
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
        'points': points,
        'reason': reason,
        'source': source,
        'month': month,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory StaffRating.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    final created = _parseDate(m['created_at']) ?? DateTime.now();
    final source = (m['source'] ?? sourceOther).toString();
    return StaffRating(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      employeeId: (m['employee_id'] ?? '').toString(),
      employeeName: _nullIfEmpty(m['employee_name']),
      points: (m['points'] as num?)?.toInt() ?? 0,
      reason: (m['reason'] ?? '').toString(),
      // Hors CHECK, l'upsert serait rejeté par Postgres et l'op droppée après
      // dix essais (cf. `stock_movements.reason`).
      source: const {sourceComplaint, sourceBonus, sourceOther}.contains(source)
          ? source
          : sourceOther,
      month: _nullIfEmpty(m['month']) ?? monthKey(created),
      createdAt: created,
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

/// LA NOTE D'UN EMPLOYÉ, déduite de ses événements du mois. Règle pure.
///
/// Trois nombres différents, qu'il ne faut pas confondre :
///   * [score] — la note sur 10, celle de la jauge. Plafonnée à 10 et jamais
///     négative ;
///   * [surplus] — les points gagnés AU-DELÀ de 10, affichés « 10 +3 ». Sans
///     eux, récompenser quelqu'un déjà à 10 ne se verrait nulle part et le
///     geste n'aurait aucun effet ;
///   * [points] — la somme algébrique brute, qui n'est jamais montrée telle
///     quelle.
class StaffScore {
  /// Le capital de départ, chaque mois, pour tout le monde.
  static const int baseScore = 10;

  /// En DEÇÀ de ce seuil, l'employé est signalé à remplacer d'urgence.
  static const int urgentThreshold = 5;

  /// Somme signée des événements du mois.
  final int points;

  const StaffScore(this.points);

  const StaffScore.clean() : points = 0;

  /// Note brute avant plafonnement — sert au calcul, pas à l'affichage.
  int get raw => baseScore + points;

  /// La note sur 10.
  int get score {
    if (raw > baseScore) return baseScore;
    return raw < 0 ? 0 : raw;
  }

  /// Points gagnés au-delà du plafond.
  int get surplus => raw > baseScore ? raw - baseScore : 0;

  /// Remplissage de la jauge, de 0 à 1.
  double get gauge => score / baseScore;

  /// À remplacer d'urgence : la note est passée sous le seuil.
  bool get needsReplacement => score < urgentThreshold;

  /// Un employé qui n'a rien perdu ni rien gagné.
  bool get isClean => points == 0;

  /// « 10 », « 7 », « 10 +3 ».
  String get label => surplus > 0 ? '$baseScore +$surplus' : '$score';

  /// Ordre du classement : le meilleur en tête.
  ///
  /// Le surplus départage deux employés à 10 — sans lui, celui qui a été
  /// félicité trois fois se retrouverait à égalité avec celui dont on n'a
  /// jamais rien eu à dire, et le classement perdrait tout intérêt.
  static int compare(StaffScore a, StaffScore b) => b.raw.compareTo(a.raw);
}
