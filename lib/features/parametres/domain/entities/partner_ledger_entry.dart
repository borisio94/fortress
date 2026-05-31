import '../../../../core/storage/schema_migrator.dart';

/// Mouvement comptable lié à un partenaire de livraison.
///
/// Modélise les flux financiers croisés entre la boutique et un dépôt
/// partenaire (StockLocation type='partner') :
///   * `saleCollected` (+) : le partenaire a encaissé un client pour le
///     compte de la boutique → il nous doit ce montant.
///   * `deliveryOwed` (-)  : le partenaire a effectué une livraison → la
///     boutique lui doit les frais de livraison.
///   * `remittance`        : versement physique (boutique ↔ partenaire)
///     enregistré manuellement, qui solde une partie du compte. Le signe
///     dépend du sens (positif = partenaire verse à la boutique, négatif
///     = boutique verse au partenaire).
///
/// **Convention de signe sur le solde** :
///   `solde = SUM(amount)` filtré sur le partenaire.
///   * solde > 0 → le partenaire DOIT cet argent à la boutique.
///   * solde < 0 → la boutique DOIT cet argent au partenaire.
///   * solde = 0 → comptes à jour.
enum PartnerLedgerEntryType {
  saleCollected,
  deliveryOwed,
  remittance,
  /// Charge que la boutique doit au partenaire, hors livraison réussie
  /// (course refusée, stockage, commission, abonnement…). Toujours négatif.
  /// La sous-nature précise est portée par [PartnerLedgerEntry.category].
  partnerCharge;

  String get key => name;

  static PartnerLedgerEntryType fromKey(String? k) {
    return PartnerLedgerEntryType.values.firstWhere(
      (e) => e.name == k,
      orElse: () => PartnerLedgerEntryType.remittance,
    );
  }

  String get labelFr => switch (this) {
        PartnerLedgerEntryType.saleCollected => 'Vente encaissée',
        PartnerLedgerEntryType.deliveryOwed  => 'Frais de livraison',
        PartnerLedgerEntryType.remittance    => 'Versement',
        PartnerLedgerEntryType.partnerCharge => 'Charge partenaire',
      };
}

/// Sous-catégorie d'une entrée [PartnerLedgerEntryType.partnerCharge].
/// Permet de classer/filtrer les charges sans multiplier les types d'enum
/// (donc sans migration à chaque nouveau motif).
enum PartnerChargeCategory {
  failedDelivery,
  storage,
  commission,
  subscription,
  handling,
  other;

  String get key => name;

  static PartnerChargeCategory fromKey(String? k) {
    return PartnerChargeCategory.values.firstWhere(
      (e) => e.name == k,
      orElse: () => PartnerChargeCategory.other,
    );
  }

  String get labelFr => switch (this) {
        PartnerChargeCategory.failedDelivery => 'Livraison refusée',
        PartnerChargeCategory.storage        => 'Stockage / dépôt',
        PartnerChargeCategory.commission     => 'Commission',
        PartnerChargeCategory.subscription   => 'Abonnement',
        PartnerChargeCategory.handling       => 'Manutention',
        PartnerChargeCategory.other          => 'Autre',
      };
}

class PartnerLedgerEntry {
  final String id;
  final String shopId;
  final String partnerLocationId;
  /// Référence à la commande source (null pour un versement manuel).
  final String? orderId;
  final PartnerLedgerEntryType type;
  /// Sous-catégorie, renseignée uniquement pour [type] ==
  /// [PartnerLedgerEntryType.partnerCharge]. Null sinon.
  final PartnerChargeCategory? category;
  /// Montant SIGNÉ en FCFA. Cf. doc en tête de fichier pour la convention.
  final double amount;
  final DateTime createdAt;
  /// Note libre (raison du versement, n° de reçu, etc.).
  final String? note;
  /// Auteur du mouvement (utilisateur Supabase). Optionnel pour les
  /// mouvements générés automatiquement.
  final String? createdByUserId;

  const PartnerLedgerEntry({
    required this.id,
    required this.shopId,
    required this.partnerLocationId,
    this.orderId,
    required this.type,
    this.category,
    required this.amount,
    required this.createdAt,
    this.note,
    this.createdByUserId,
    this.deletedAt,
  });

  /// Suppression douce : si non-null, l'entrée est supprimée (filtrée des
  /// soldes et de l'historique). Permet une suppression qui converge en
  /// multi-appareils / offline-first sans résurrection par re-push.
  final DateTime? deletedAt;

  // Schema versioning — cf. lib/core/storage/schema_migrator.dart.
  static const int currentSchemaVersion = 1;
  static final SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: const {},
  );

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id': id,
        'shop_id': shopId,
        'partner_location_id': partnerLocationId,
        'order_id': orderId,
        'type': type.key,
        'category': category?.key,
        'amount': amount,
        'created_at': createdAt.toUtc().toIso8601String(),
        'note': note,
        'created_by_user_id': createdByUserId,
        'deleted_at': deletedAt?.toUtc().toIso8601String(),
      };

  factory PartnerLedgerEntry.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return PartnerLedgerEntry(
      id: m['id'] as String,
      shopId: m['shop_id'] as String,
      partnerLocationId: m['partner_location_id'] as String,
      orderId: m['order_id'] as String?,
      type: PartnerLedgerEntryType.fromKey(m['type'] as String?),
      category: m['category'] == null
          ? null
          : PartnerChargeCategory.fromKey(m['category'] as String?),
      amount: (m['amount'] as num).toDouble(),
      createdAt: DateTime.parse(m['created_at'] as String).toLocal(),
      note: m['note'] as String?,
      createdByUserId: m['created_by_user_id'] as String?,
      deletedAt: m['deleted_at'] == null
          ? null
          : DateTime.tryParse(m['deleted_at'].toString())?.toLocal(),
    );
  }
}
