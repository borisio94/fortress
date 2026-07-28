import '../../../../core/storage/schema_migrator.dart';

/// Consigne d'emballages remise à un client (Lot B — hotfix_146).
///
/// Le client paie une caution par bouteille ; elle lui est rendue quand il
/// rapporte les emballages. Tant qu'ils sont dehors, la boutique a encaissé un
/// argent qui ne lui appartient pas — et si les bouteilles ne reviennent
/// jamais, c'est elle qui rachète le contenant à la brasserie.
///
/// Le MONTANT est facturé via les frais de la commande (`orders.fees`) ; cette
/// entité porte le SUIVI des retours, qui survit à l'addition.
class BottleDeposit {
  final String id;
  final String shopId;

  /// Commande d'origine. Référence logique, et nullable : une consigne peut
  /// être enregistrée hors commande (dépôt direct au comptoir).
  final String? orderId;

  /// Produit consigné, si c'en est un du catalogue. Référence logique.
  final String? productId;

  /// Libellé FIGÉ à la création (« Casier 12 × 65 cl »). Un produit renommé ou
  /// supprimé ne doit pas rendre la consigne illisible six mois plus tard.
  final String label;

  /// Nombre d'emballages remis.
  final int quantity;

  /// Caution par emballage (FCFA entier).
  final int depositPerUnit;

  /// Emballages déjà rapportés.
  final int returnedQuantity;

  /// `pending` · `partially_returned` · `fully_returned` · `lost`.
  final String status;

  /// Repère humain du débiteur : table, compte, nom du client. Une consigne se
  /// réclame à quelqu'un, pas à un identifiant de commande.
  final String? holder;

  final DateTime createdAt;

  const BottleDeposit({
    required this.id,
    required this.shopId,
    required this.createdAt,
    this.orderId,
    this.productId,
    this.label = 'Consigne',
    this.quantity = 0,
    this.depositPerUnit = 0,
    this.returnedQuantity = 0,
    this.status = 'pending',
    this.holder,
  });

  /// Emballages encore dehors, jamais négatif.
  int get outstanding {
    final n = quantity - returnedQuantity;
    return n < 0 ? 0 : n;
  }

  /// Montant total consigné.
  int get totalAmount => quantity * depositPerUnit;

  /// Caution encore due au client (ce qu'il récupérera s'il rapporte tout).
  int get outstandingAmount => outstanding * depositPerUnit;

  /// Consigne perdue : les emballages ne reviendront pas.
  bool get isLost => status == 'lost';

  /// Plus rien à réclamer — soit tout est revenu, soit c'est acté perdu.
  bool get isClosed => isLost || outstanding == 0;

  /// Statut DÉRIVÉ des quantités. Le stocker en base plutôt que de le calculer
  /// à la lecture n'est pas une duplication gratuite : la colonne porte un
  /// CHECK SQL et sert l'index partiel des consignes ouvertes.
  static String statusFor(int quantity, int returned) {
    if (returned <= 0) return 'pending';
    if (returned >= quantity) return 'fully_returned';
    return 'partially_returned';
  }

  /// Consigne après le retour de [count] emballages.
  ///
  /// PLAFONNÉ à ce qui reste dehors : accepter plus que le dû rendrait au
  /// client une caution qu'il n'a jamais versée, et afficherait un stock
  /// d'emballages négatif. Règle pure — c'est elle qui rembourse de l'argent.
  BottleDeposit withReturn(int count) {
    if (count <= 0) return this;
    final accepted = count > outstanding ? outstanding : count;
    final total = returnedQuantity + accepted;
    return copyWith(
      returnedQuantity: total,
      status: statusFor(quantity, total),
    );
  }

  BottleDeposit copyWith({
    String? label,
    int? quantity,
    int? depositPerUnit,
    int? returnedQuantity,
    String? status,
    String? holder,
  }) =>
      BottleDeposit(
        id: id,
        shopId: shopId,
        createdAt: createdAt,
        orderId: orderId,
        productId: productId,
        label: label ?? this.label,
        quantity: quantity ?? this.quantity,
        depositPerUnit: depositPerUnit ?? this.depositPerUnit,
        returnedQuantity: returnedQuantity ?? this.returnedQuantity,
        status: status ?? this.status,
        holder: holder ?? this.holder,
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
        'product_id': productId,
        'label': label,
        'quantity': quantity,
        'deposit_per_unit': depositPerUnit,
        'returned_quantity': returnedQuantity,
        'status': status,
        'holder': holder,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory BottleDeposit.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    final quantity = (m['quantity'] as num?)?.toInt() ?? 0;
    final returned = (m['returned_quantity'] as num?)?.toInt() ?? 0;
    final rawStatus = (m['status'] ?? '').toString();
    return BottleDeposit(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      orderId: _nullIfEmpty(m['order_id']),
      productId: _nullIfEmpty(m['product_id']),
      label: (m['label']?.toString().trim().isEmpty ?? true)
          ? 'Consigne'
          : m['label'].toString().trim(),
      quantity: quantity,
      depositPerUnit: (m['deposit_per_unit'] as num?)?.toInt() ?? 0,
      returnedQuantity: returned,
      // Une valeur hors CHECK serait rejetée par Postgres et l'upsert
      // abandonné après dix essais : on retombe sur le statut dérivé, qui est
      // toujours valide. « lost » est conservé tel quel — il ne se déduit pas
      // des quantités.
      status: rawStatus == 'lost'
          ? 'lost'
          : (const {'pending', 'partially_returned', 'fully_returned'}
                  .contains(rawStatus)
              ? rawStatus
              : statusFor(quantity, returned)),
      holder: _nullIfEmpty(m['holder']),
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }

  static String? _nullIfEmpty(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }
}
