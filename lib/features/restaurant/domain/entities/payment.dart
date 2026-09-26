import '../../../../core/storage/schema_migrator.dart';
import '../../../caisse/domain/entities/sale.dart' show PaymentMethod;

/// Mode de règlement FIN, tel qu'il est encaissé au comptoir (hotfix_145).
///
/// Distinct de [PaymentMethod], l'énumération historique de la caisse
/// e-commerce, qui ne connaît qu'un « Mobile Money » générique. Au Cameroun,
/// MTN Money et Orange Money sont deux caisses différentes qu'il faut pouvoir
/// rapprocher séparément en fin de journée — d'où ce jeu de valeurs.
///
/// [PaymentMethod] n'a PAS été étendu : il est sérialisé dans les exports, les
/// factures, les tableaux de bord et le tracking web de toutes les boutiques,
/// restaurant ou non. Chaque mode fin déclare donc son équivalent générique
/// ([generic]) pour que `orders.payment_method` reste juste.
enum PaymentMode {
  cash('cash', 'Espèces', PaymentMethod.cash),
  mtnMoney('mtn_money', 'MTN Money', PaymentMethod.mobileMoney),
  orangeMoney('orange_money', 'Orange Money', PaymentMethod.mobileMoney),
  card('card', 'Carte', PaymentMethod.card),
  credit('credit', 'Crédit', PaymentMethod.credit);

  const PaymentMode(this.key, this.label, this.generic);

  /// Valeur persistée — doit rester dans le CHECK SQL de `payments.method`.
  final String key;
  final String label;

  /// Équivalent dans l'énumération historique de la caisse.
  final PaymentMethod generic;

  /// Le rendu monnaie n'a de sens qu'en espèces : sur un transfert mobile ou
  /// une carte, le montant reçu est exactement le montant imputé.
  bool get allowsChange => this == PaymentMode.cash;

  /// Un règlement « à crédit » n'entre pas dans le tiroir : c'est une créance
  /// client, pas de l'argent encaissé.
  bool get isCredit => this == PaymentMode.credit;

  /// Modes proposés au caissier. [credit] en est ABSENT à dessein : dans
  /// Fortress la créance est DÉRIVÉE (montant encaissé < total), elle n'est pas
  /// saisie comme un règlement. L'enregistrer comme tel le compterait deux fois
  /// — une fois en encaissé, une fois en dette.
  static List<PaymentMode> get selectable =>
      PaymentMode.values.where((m) => !m.isCredit).toList();

  static PaymentMode fromKey(String? k) {
    final v = (k ?? '').trim().toLowerCase();
    for (final m in PaymentMode.values) {
      if (m.key == v) return m;
    }
    return PaymentMode.cash;
  }
}

/// Un règlement reçu sur une addition (hotfix_145).
///
/// Une addition réglée en plusieurs fois porte plusieurs [Payment] : c'est la
/// somme de leurs [amount] qui fait le montant encaissé. Le [changeGiven] n'y
/// est PAS compté — c'est de l'argent rendu au client, pas encaissé.
class Payment {
  final String id;
  final String shopId;

  /// Commande réglée. Référence logique (pas de FK, cf. hotfix_145).
  final String orderId;

  /// Mode de règlement fin (`cash` · `mtn_money` · `orange_money` · `card` ·
  /// `credit`).
  final String method;

  /// Montant IMPUTÉ à l'addition, hors rendu (FCFA entier).
  final int amount;

  /// Référence de transaction de l'opérateur (numéro MTN/OM, ticket carte).
  final String? reference;

  /// Rendu monnaie, espèces uniquement : `reçu − amount`.
  final int changeGiven;

  final DateTime createdAt;

  const Payment({
    required this.id,
    required this.shopId,
    required this.orderId,
    required this.createdAt,
    this.method = 'cash',
    this.amount = 0,
    this.reference,
    this.changeGiven = 0,
  });

  PaymentMode get mode => PaymentMode.fromKey(method);

  /// Ce que le client a effectivement tendu (espèces) : imputé + rendu.
  int get received => amount + changeGiven;

  Payment copyWith({
    String? method,
    int? amount,
    String? reference,
    int? changeGiven,
  }) =>
      Payment(
        id: id,
        shopId: shopId,
        orderId: orderId,
        createdAt: createdAt,
        method: method ?? this.method,
        amount: amount ?? this.amount,
        reference: reference ?? this.reference,
        changeGiven: changeGiven ?? this.changeGiven,
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
        'order_id': orderId,
        'method': method,
        'amount': amount,
        'reference': reference,
        'change_given': changeGiven,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory Payment.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return Payment(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      orderId: (m['order_id'] ?? '').toString(),
      // Normalisé via l'enum : une valeur hors CHECK ferait rejeter l'upsert
      // par Postgres, et l'op serait droppée après dix essais sans bruit.
      method: PaymentMode.fromKey(m['method']?.toString()).key,
      amount: (m['amount'] as num?)?.toInt() ?? 0,
      reference: (m['reference']?.toString().trim().isEmpty ?? true)
          ? null
          : m['reference'].toString().trim(),
      changeGiven: (m['change_given'] as num?)?.toInt() ?? 0,
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }
}
