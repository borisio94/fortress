import '../../../../core/storage/schema_migrator.dart';

/// Contrôle de caisse aveugle (Lot C — hotfix_147).
///
/// Le caissier compte le tiroir SANS voir le total attendu ; l'écart n'apparaît
/// qu'après validation. C'est ce qui rend un manquant visible : si le total
/// système était affiché d'abord, il suffirait de recopier le chiffre.
///
///   * [isX] — contrôle intermédiaire (passage de relais, milieu de service).
///     Ne clôt rien, la période continue de courir.
///   * [isZ] — clôture de journée : la période suivante repart de cette date.
class CashClosure {
  final String id;
  final String shopId;

  /// `auth.users.id` de celui qui a compté. Référence logique.
  final String? cashierId;

  /// Libellé figé : un identifiant ne parle à personne trois semaines plus tard.
  final String? cashierName;

  /// 'X' (contrôle) ou 'Z' (clôture de journée).
  final String closureType;

  /// Espèces comptées dans le tiroir.
  final int declaredCash;

  /// Espèces attendues = fond de caisse + encaissements espèces de la période.
  final int systemCash;

  /// `declaredCash − systemCash`. Négatif = manquant, positif = excédent.
  ///
  /// STOCKÉ et non recalculé : c'est un constat daté. Si la définition du total
  /// système évolue, l'écart réellement constaté ce soir-là doit rester lisible.
  final int variance;

  /// Fond de caisse présent avant le premier encaissement de la période.
  final int openingFloat;

  /// Début de la période couverte (fin de la clôture Z précédente).
  final DateTime? periodStart;

  /// Explication d'un écart connu, saisie sur le moment.
  final String? note;

  final DateTime closedAt;

  const CashClosure({
    required this.id,
    required this.shopId,
    required this.closedAt,
    this.cashierId,
    this.cashierName,
    this.closureType = 'X',
    this.declaredCash = 0,
    this.systemCash = 0,
    this.variance = 0,
    this.openingFloat = 0,
    this.periodStart,
    this.note,
  });

  bool get isZ => closureType == 'Z';
  bool get isX => !isZ;

  /// Caisse juste : ni manquant ni excédent.
  bool get isBalanced => variance == 0;

  /// Il manque de l'argent dans le tiroir.
  bool get isShort => variance < 0;

  /// Écart en valeur absolue — ce qu'on affiche, le signe étant porté par
  /// [isShort].
  int get gap => variance < 0 ? -variance : variance;

  String get varianceLabel => isBalanced
      ? 'Caisse juste'
      : (isShort ? 'Manquant' : 'Excédent');

  /// L'écart d'un comptage. Fonction pure : c'est LE calcul du module, et il
  /// doit avoir exactement une définition.
  static int varianceOf(int declared, int system) => declared - system;

  CashClosure copyWith({String? note}) => CashClosure(
        id: id,
        shopId: shopId,
        closedAt: closedAt,
        cashierId: cashierId,
        cashierName: cashierName,
        closureType: closureType,
        declaredCash: declaredCash,
        systemCash: systemCash,
        variance: variance,
        openingFloat: openingFloat,
        periodStart: periodStart,
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
        'cashier_id': cashierId,
        'cashier_name': cashierName,
        'closure_type': closureType,
        'declared_cash': declaredCash,
        'system_cash': systemCash,
        'variance': variance,
        'opening_float': openingFloat,
        'period_start': periodStart?.toUtc().toIso8601String(),
        'note': note,
        'closed_at': closedAt.toUtc().toIso8601String(),
      };

  factory CashClosure.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    final declared = (m['declared_cash'] as num?)?.toInt() ?? 0;
    final system = (m['system_cash'] as num?)?.toInt() ?? 0;
    final rawType = (m['closure_type'] ?? '').toString().toUpperCase();
    return CashClosure(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      cashierId: _nullIfEmpty(m['cashier_id']),
      cashierName: _nullIfEmpty(m['cashier_name']),
      // Une valeur hors CHECK ferait rejeter l'upsert par Postgres et l'op
      // serait droppée après dix essais : on retombe sur le contrôle, qui ne
      // clôt aucune période et ne peut donc rien fausser.
      closureType: rawType == 'Z' ? 'Z' : 'X',
      declaredCash: declared,
      systemCash: system,
      // Un écart absent (donnée partielle) se recalcule ; un écart présent est
      // conservé tel quel — c'est le constat d'origine.
      variance: (m['variance'] as num?)?.toInt() ??
          varianceOf(declared, system),
      openingFloat: (m['opening_float'] as num?)?.toInt() ?? 0,
      periodStart: _parseDate(m['period_start']),
      note: _nullIfEmpty(m['note']),
      closedAt: _parseDate(m['closed_at']) ?? DateTime.now(),
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
