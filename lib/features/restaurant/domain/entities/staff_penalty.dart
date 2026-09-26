import '../../../../core/storage/schema_migrator.dart';

/// CASSE IMPUTÉE À UN EMPLOYÉ — un bien détruit par imprudence (hotfix_165).
///
/// Trois façons de solder la même dette, et le choix appartient au gérant :
///   * tout retenir sur la paie du mois — brutal, mais soldé ;
///   * en retenir un pourcentage chaque mois jusqu'à extinction — la seule
///     option tenable quand le bien vaut plus qu'un demi-salaire ;
///   * l'employé rembourse de sa poche — le salaire n'est alors JAMAIS touché.
///
/// Le montant déjà récupéré est stocké ([amountRecovered]) plutôt que déduit
/// des fiches de paie à la lecture : une fiche remise à l'employé est un
/// document, et supprimer une fiche ne doit pas faire disparaître la trace de
/// ce qui a été retenu ailleurs.
enum PenaltyMode {
  /// Retenue intégrale sur la prochaine paie.
  oneShot,

  /// Un pourcentage du montant retenu chaque mois, jusqu'à solde.
  installments,

  /// Remboursé directement par l'employé : aucun impact sur le salaire.
  cashRepaid,
}

extension PenaltyModeX on PenaltyMode {
  String get key => switch (this) {
        PenaltyMode.oneShot => 'one_shot',
        PenaltyMode.installments => 'installments',
        PenaltyMode.cashRepaid => 'cash_repaid',
      };

  String get label => switch (this) {
        PenaltyMode.oneShot => 'En une fois sur la paie',
        PenaltyMode.installments => 'Étalé sur plusieurs mois',
        PenaltyMode.cashRepaid => 'Remboursé de sa poche',
      };

  /// Une clé inconnue retombe sur la retenue en une fois — le mode le plus
  /// courant, et celui qui ne fait pas disparaître la dette.
  static PenaltyMode fromKey(String? raw) => switch (raw?.trim()) {
        'installments' => PenaltyMode.installments,
        'cash_repaid' => PenaltyMode.cashRepaid,
        _ => PenaltyMode.oneShot,
      };
}

class StaffPenalty {
  final String id;
  final String shopId;

  /// Ref logique vers `employees`.
  final String employeeId;

  /// Nom figé : la casse d'un employé parti doit rester lisible.
  final String? employeeName;

  /// Le bien détruit : « assiette », « blender », « vitre du frigo ».
  final String itemLabel;

  /// Valeur du bien, en FCFA entiers. C'est le total à récupérer.
  final int amount;

  final PenaltyMode mode;

  /// Pourcentage du MONTANT retenu chaque mois, en mode [PenaltyMode.installments].
  ///
  /// Du montant et non du salaire : « 25 % » se lit alors « quatre mois », une
  /// durée que l'employé peut vérifier lui-même. Adossé au salaire, le même
  /// réglage donnerait une durée qui change à chaque augmentation.
  final int percentPerMonth;

  /// Cumul déjà retenu sur des fiches de paie (ou remboursé).
  final int amountRecovered;

  /// Premier mois de retenue, `YYYY-MM`.
  final String startMonth;

  /// Les circonstances. Obligatoire à la saisie : une retenue sur salaire sans
  /// motif écrit est indéfendable le jour où elle est contestée.
  final String reason;

  final DateTime incidentDate;
  final DateTime createdAt;

  /// Date de solde. `null` tant qu'il reste quelque chose à récupérer.
  final DateTime? closedAt;

  const StaffPenalty({
    required this.id,
    required this.shopId,
    required this.employeeId,
    required this.itemLabel,
    required this.amount,
    required this.startMonth,
    required this.reason,
    required this.incidentDate,
    required this.createdAt,
    this.employeeName,
    this.mode = PenaltyMode.oneShot,
    this.percentPerMonth = 25,
    this.amountRecovered = 0,
    this.closedAt,
  });

  /// Reste à récupérer. Jamais négatif : une retenue de trop ne doit pas
  /// transformer la dette en créance.
  int get remaining {
    final r = amount - amountRecovered;
    return r < 0 ? 0 : r;
  }

  bool get isSettled => remaining == 0;

  /// Le salaire est-il touché ? Non quand l'employé rembourse lui-même.
  bool get hitsPayroll => mode != PenaltyMode.cashRepaid;

  /// Retenue théorique d'un mois, avant plafonnement par le reste dû.
  int get monthlyShare {
    switch (mode) {
      case PenaltyMode.cashRepaid:
        return 0;
      case PenaltyMode.oneShot:
        return amount;
      case PenaltyMode.installments:
        final pct = percentPerMonth <= 0 ? 25 : percentPerMonth;
        // Arrondi au FRANC SUPÉRIEUR : arrondir vers le bas laisserait un
        // reliquat de quelques francs qui ferait traîner un mois de plus pour
        // rien.
        final share = (amount * pct + 99) ~/ 100;
        return share <= 0 ? amount : share;
    }
  }

  /// Nombre de mois nécessaires au solde complet, tel qu'il est annoncé au
  /// gérant AVANT qu'il ne valide.
  int get monthsNeeded {
    final share = monthlyShare;
    if (share <= 0) return 0;
    return (amount + share - 1) ~/ share;
  }

  /// CE QUI DOIT ÊTRE RETENU sur la paie de [month]. La règle, telle quelle.
  ///
  /// Rien avant le mois de départ : une casse de mars ne se retient pas sur la
  /// paie de janvier qu'on régularise. Rien non plus une fois soldée, ni quand
  /// l'employé a remboursé lui-même.
  int dueFor(String month) {
    if (!hitsPayroll || isSettled) return 0;
    if (month.compareTo(startMonth) < 0) return 0;
    final share = monthlyShare;
    return share > remaining ? remaining : share;
  }

  StaffPenalty copyWith({
    String? itemLabel,
    int? amount,
    PenaltyMode? mode,
    int? percentPerMonth,
    int? amountRecovered,
    String? startMonth,
    String? reason,
    DateTime? closedAt,
    bool clearClosedAt = false,
  }) =>
      StaffPenalty(
        id: id,
        shopId: shopId,
        employeeId: employeeId,
        employeeName: employeeName,
        incidentDate: incidentDate,
        createdAt: createdAt,
        itemLabel: itemLabel ?? this.itemLabel,
        amount: amount ?? this.amount,
        mode: mode ?? this.mode,
        percentPerMonth: percentPerMonth ?? this.percentPerMonth,
        amountRecovered: amountRecovered ?? this.amountRecovered,
        startMonth: startMonth ?? this.startMonth,
        reason: reason ?? this.reason,
        closedAt: clearClosedAt ? null : (closedAt ?? this.closedAt),
      );

  /// Encaisse [value] sur la dette et referme la pénalité si elle est soldée.
  StaffPenalty recover(int value, {DateTime? at}) {
    final next = amountRecovered + (value < 0 ? 0 : value);
    final capped = next > amount ? amount : next;
    return copyWith(
      amountRecovered: capped,
      closedAt: capped >= amount ? (at ?? DateTime.now()) : null,
      clearClosedAt: capped < amount,
    );
  }

  static const int currentSchemaVersion = 1;
  static const SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {},
  );

  /// Clé de mois `YYYY-MM`.
  static String monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}';

  static String dayKey(DateTime d) =>
      '${monthKey(d)}-${d.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id': id,
        'shop_id': shopId,
        'employee_id': employeeId,
        'employee_name': employeeName,
        'item_label': itemLabel,
        'amount': amount,
        'mode': mode.key,
        'percent_per_month': percentPerMonth,
        'amount_recovered': amountRecovered,
        'start_month': startMonth,
        'reason': reason,
        'incident_date': dayKey(incidentDate),
        'closed_at': closedAt?.toUtc().toIso8601String(),
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory StaffPenalty.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    final incident =
        DateTime.tryParse(m['incident_date']?.toString() ?? '') ??
            DateTime.now();
    return StaffPenalty(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      employeeId: (m['employee_id'] ?? '').toString(),
      employeeName: _nullIfEmpty(m['employee_name']),
      itemLabel: (m['item_label'] ?? '').toString(),
      amount: (m['amount'] as num?)?.toInt() ?? 0,
      mode: PenaltyModeX.fromKey(m['mode']?.toString()),
      percentPerMonth: (m['percent_per_month'] as num?)?.toInt() ?? 25,
      amountRecovered: (m['amount_recovered'] as num?)?.toInt() ?? 0,
      // Sans mois de départ, la retenue serait invisible à la paie : on la
      // rattache au mois de l'incident.
      startMonth:
          _nullIfEmpty(m['start_month']) ?? monthKey(incident),
      reason: (m['reason'] ?? '').toString(),
      incidentDate: incident,
      closedAt: _parseDate(m['closed_at']),
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
