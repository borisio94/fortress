import '../../../../core/storage/schema_migrator.dart';

/// PRIME SPÉCIALE — un concours à durée déterminée (hotfix_165).
///
/// « Le serveur qui vend le plus de chawarmas entre le 1er et le 15 gagne
/// 20 000 F. » Une motivation ponctuelle, décidée par le gérant, qui n'a rien
/// à voir avec le salaire : elle se verse À CÔTÉ, en une fois, et ne doit
/// jamais entrer dans le calcul du net — sinon elle deviendrait un acquis que
/// l'employé réclamerait le mois suivant.
///
/// Les conditions sont du TEXTE LIBRE et le vainqueur est désigné à la main.
/// Vouloir les évaluer automatiquement supposerait que l'app sache mesurer
/// « le plus souriant » ou « le plus ponctuel » — elle ne le sait pas, et un
/// concours qu'on ne peut pas énoncer librement ne serait jamais lancé.
enum ContestState {
  /// Annoncé, pas encore commencé.
  upcoming,

  /// En cours : la période court.
  running,

  /// Terminé, vainqueur pas encore désigné.
  toAward,

  /// Vainqueur désigné, prime pas encore versée.
  awarded,

  /// Prime versée.
  paid,
}

extension ContestStateX on ContestState {
  String get label => switch (this) {
        ContestState.upcoming => 'À venir',
        ContestState.running => 'En cours',
        ContestState.toAward => 'À départager',
        ContestState.awarded => 'À verser',
        ContestState.paid => 'Versée',
      };
}

class StaffContest {
  final String id;
  final String shopId;

  /// Le nom du concours, tel qu'il est annoncé à l'équipe.
  final String title;

  /// Ce qu'il faut faire pour gagner. Texte libre, affiché tel quel.
  final String conditions;

  /// Montant de la prime, en FCFA entiers.
  final int prize;

  final DateTime startDate;
  final DateTime endDate;

  /// Ref logique vers `employees`. `null` tant que personne n'a gagné.
  final String? winnerId;

  /// Nom figé du vainqueur — un concours gagné reste au palmarès même si la
  /// fiche de l'employé disparaît.
  final String? winnerName;

  final DateTime? awardedAt;
  final DateTime? paidAt;

  /// Prime versée EN ESPÈCES (défaut) : elle sort du tiroir et la clôture de
  /// caisse doit la déduire, exactement comme une avance.
  final bool paidCash;

  final DateTime createdAt;

  const StaffContest({
    required this.id,
    required this.shopId,
    required this.title,
    required this.startDate,
    required this.endDate,
    required this.createdAt,
    this.conditions = '',
    this.prize = 0,
    this.winnerId,
    this.winnerName,
    this.awardedAt,
    this.paidAt,
    this.paidCash = true,
  });

  bool get hasWinner => (winnerId ?? '').isNotEmpty;
  bool get isPaid => paidAt != null;

  /// Où en est le concours à l'instant [now]. Règle pure — c'est elle qui
  /// décide des boutons affichés.
  ContestState stateAt(DateTime now) {
    if (isPaid) return ContestState.paid;
    if (hasWinner) return ContestState.awarded;
    if (now.isBefore(startDate)) return ContestState.upcoming;
    // La journée de fin compte ENTIÈREMENT : un concours qui se termine le 15
    // court jusqu'au 15 à minuit, pas jusqu'au 15 à 00 h 00 — sans quoi la
    // dernière journée annoncée à l'équipe ne compterait pas.
    final lastMoment = DateTime(
        endDate.year, endDate.month, endDate.day, 23, 59, 59);
    return now.isAfter(lastMoment)
        ? ContestState.toAward
        : ContestState.running;
  }

  /// Jours restants avant la fin, 0 une fois terminé.
  int daysLeftAt(DateTime now) {
    final last = DateTime(endDate.year, endDate.month, endDate.day);
    final today = DateTime(now.year, now.month, now.day);
    final d = last.difference(today).inDays;
    return d < 0 ? 0 : d;
  }

  StaffContest copyWith({
    String? title,
    String? conditions,
    int? prize,
    DateTime? startDate,
    DateTime? endDate,
    String? winnerId,
    String? winnerName,
    DateTime? awardedAt,
    DateTime? paidAt,
    bool? paidCash,

    /// Retire le vainqueur : `copyWith(winnerId: null)` serait un no-op
    /// silencieux et le concours resterait attribué à quelqu'un.
    bool clearWinner = false,
  }) =>
      StaffContest(
        id: id,
        shopId: shopId,
        createdAt: createdAt,
        title: title ?? this.title,
        conditions: conditions ?? this.conditions,
        prize: prize ?? this.prize,
        startDate: startDate ?? this.startDate,
        endDate: endDate ?? this.endDate,
        winnerId: clearWinner ? null : (winnerId ?? this.winnerId),
        winnerName: clearWinner ? null : (winnerName ?? this.winnerName),
        awardedAt: clearWinner ? null : (awardedAt ?? this.awardedAt),
        paidAt: clearWinner ? null : (paidAt ?? this.paidAt),
        paidCash: paidCash ?? this.paidCash,
      );

  static const int currentSchemaVersion = 1;
  static const SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {},
  );

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id': id,
        'shop_id': shopId,
        'title': title,
        'conditions': conditions,
        'prize': prize,
        'start_date': dayKey(startDate),
        'end_date': dayKey(endDate),
        'winner_id': winnerId,
        'winner_name': winnerName,
        'awarded_at': awardedAt?.toUtc().toIso8601String(),
        'paid_at': paidAt?.toUtc().toIso8601String(),
        'paid_cash': paidCash,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory StaffContest.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    final start =
        DateTime.tryParse(m['start_date']?.toString() ?? '') ?? DateTime.now();
    return StaffContest(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      title: (m['title'] ?? '').toString(),
      conditions: (m['conditions'] ?? '').toString(),
      prize: (m['prize'] as num?)?.toInt() ?? 0,
      startDate: start,
      endDate:
          DateTime.tryParse(m['end_date']?.toString() ?? '') ?? start,
      winnerId: _nullIfEmpty(m['winner_id']),
      winnerName: _nullIfEmpty(m['winner_name']),
      awardedAt: _parseDate(m['awarded_at']),
      paidAt: _parseDate(m['paid_at']),
      paidCash: m['paid_cash'] as bool? ?? true,
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
