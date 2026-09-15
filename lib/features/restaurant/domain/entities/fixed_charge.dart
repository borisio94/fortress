import '../../../../core/storage/schema_migrator.dart';

/// Charge fixe / échéance récurrente (module finances — PR-C) : loyer,
/// électricité, internet, impôts, salaires… Montant + fréquence + prochaine
/// échéance + rappel. Les paiements sont horodatés dans [paidDates] pour
/// distinguer une échéance réglée d'une échéance en attente.
class FixedCharge {
  final String id;
  final String shopId;
  final String name;

  /// Montant de l'échéance (FCFA entier).
  final int amount;

  /// 'monthly' · 'quarterly' · 'yearly' · 'once'.
  final String frequency;

  /// Prochaine échéance (date seule, sans heure).
  final DateTime nextDueDate;

  /// Nombre de jours avant l'échéance où l'alerte se déclenche.
  final int alertDaysBefore;

  /// 'loyer' · 'electricite' · 'internet' · 'impots' · 'salaires' · 'autre'.
  final String category;

  /// Dates (ISO `yyyy-MM-dd`) des échéances déjà réglées.
  final List<String> paidDates;

  final DateTime createdAt;

  const FixedCharge({
    required this.id,
    required this.shopId,
    required this.name,
    required this.nextDueDate,
    required this.createdAt,
    this.amount = 0,
    this.frequency = 'monthly',
    this.alertDaysBefore = 7,
    this.category = 'autre',
    this.paidDates = const [],
  });

  /// Clé `yyyy-MM-dd` d'une date (comparaison d'échéance sans l'heure).
  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Échéance courante déjà réglée ?
  bool get isCurrentPaid => paidDates.contains(dayKey(nextDueDate));

  /// Jours restants avant l'échéance (négatif = en retard).
  int daysUntilDue() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = DateTime(nextDueDate.year, nextDueDate.month, nextDueDate.day);
    return due.difference(today).inDays;
  }

  /// En retard : échéance passée et non réglée.
  bool get isOverdue => !isCurrentPaid && daysUntilDue() < 0;

  /// À régler bientôt : dans la fenêtre d'alerte et non réglée.
  bool get isDueSoon => !isCurrentPaid && daysUntilDue() <= alertDaysBefore;

  FixedCharge copyWith({
    String? name,
    int? amount,
    String? frequency,
    DateTime? nextDueDate,
    int? alertDaysBefore,
    String? category,
    List<String>? paidDates,
  }) =>
      FixedCharge(
        id: id,
        shopId: shopId,
        createdAt: createdAt,
        name: name ?? this.name,
        amount: amount ?? this.amount,
        frequency: frequency ?? this.frequency,
        nextDueDate: nextDueDate ?? this.nextDueDate,
        alertDaysBefore: alertDaysBefore ?? this.alertDaysBefore,
        category: category ?? this.category,
        paidDates: paidDates ?? this.paidDates,
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
        'name': name,
        'amount': amount,
        'frequency': frequency,
        'next_due_date': dayKey(nextDueDate),
        'alert_days_before': alertDaysBefore,
        'category': category,
        'paid_dates': paidDates,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory FixedCharge.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return FixedCharge(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      name: (m['name'] ?? '').toString(),
      amount: (m['amount'] as num?)?.toInt() ?? 0,
      frequency: (m['frequency'] ?? 'monthly').toString(),
      nextDueDate: m['next_due_date'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['next_due_date'].toString()) ??
              DateTime.now()),
      alertDaysBefore: (m['alert_days_before'] as num?)?.toInt() ?? 7,
      category: (m['category'] ?? 'autre').toString(),
      paidDates: (m['paid_dates'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }
}
