import 'package:flutter/material.dart';
import 'package:equatable/equatable.dart';
import 'sale_item.dart';

enum PaymentMethod { cash, mobileMoney, card, credit }

enum SaleStatus {
  completed,   // Encaissée (standard)
  scheduled,   // Programmée (e-commerce — nouvelle commande)
  processing,  // En cours de traitement
  cancelled,   // Annulée
  refused,     // Refusée
  refunded,    // Remboursée
}

/// Mode de livraison d'une vente.
/// - `pickup`   : retrait en boutique (aucune livraison).
/// - `inHouse`  : livraison par un membre/coursier de la boutique.
/// - `partner`  : livraison par un dépôt partenaire géré localement
///                (multi-shop interne). Stock décrémenté depuis la location.
/// - `shipment` : expédition par une agence externe (DHL, Express Union).
///                Pas de stock partenaire à décrémenter ; on note la ville
///                d'expédition + l'agence + le responsable de l'envoi.
enum DeliveryMode { pickup, inHouse, partner, shipment }

extension DeliveryModeX on DeliveryMode {
  String get key => switch (this) {
    DeliveryMode.pickup   => 'pickup',
    DeliveryMode.inHouse  => 'in_house',
    DeliveryMode.partner  => 'partner',
    DeliveryMode.shipment => 'shipment',
  };
  String get labelFr => switch (this) {
    DeliveryMode.pickup   => 'Retrait en boutique',
    DeliveryMode.inHouse  => 'Livraison par notre équipe',
    DeliveryMode.partner  => 'Livraison partenaire',
    DeliveryMode.shipment => 'Expédition par agence',
  };
  static DeliveryMode? fromKey(String? k) => switch (k) {
    'pickup'   => DeliveryMode.pickup,
    'in_house' => DeliveryMode.inHouse,
    'partner'  => DeliveryMode.partner,
    'shipment' => DeliveryMode.shipment,
    _          => null,
  };
}

extension SaleStatusX on SaleStatus {
  String get label => switch (this) {
    SaleStatus.completed  => 'Complétée',
    SaleStatus.scheduled  => 'Programmée',
    SaleStatus.processing => 'En cours',
    SaleStatus.cancelled  => 'Annulée',
    SaleStatus.refused    => 'Refusée',
    SaleStatus.refunded   => 'Remboursée',
  };

  Color get color => switch (this) {
    SaleStatus.completed  => const Color(0xFF10B981),
    SaleStatus.scheduled  => const Color(0xFF6C3FC7),
    SaleStatus.processing => const Color(0xFF3B82F6),
    SaleStatus.cancelled  => const Color(0xFF9CA3AF),
    SaleStatus.refused    => const Color(0xFFEF4444),
    SaleStatus.refunded   => const Color(0xFFF59E0B),
  };
}

class Sale extends Equatable {
  final String? id;
  final String  shopId;
  final List<SaleItem> items;
  final double  discountAmount;
  final double  taxRate;
  final List<Map<String, dynamic>> fees; // frais de commande [{id, label, amount}]
  final PaymentMethod paymentMethod;
  final SaleStatus    status;
  final String? clientId;
  final String? clientName;
  final String? clientPhone;
  final String? notes;
  final DateTime createdAt;
  final DateTime? scheduledAt;
  final bool syncedToCloud;

  /// Mode de livraison. `null` pour les ventes antérieures à l'introduction
  /// du champ (historique non classé).
  final DeliveryMode? deliveryMode;

  /// Si `deliveryMode == partner`, l'id de la StockLocation du partenaire
  /// qui effectue la livraison. Null sinon.
  final String? deliveryLocationId;

  /// Si `deliveryMode == inHouse`, nom du livreur (texte libre).
  /// Peut aussi être renseigné pour partner (contact chez le partenaire).
  final String? deliveryPersonName;

  /// Identifiant de l'utilisateur (auth.users.id) qui a créé la vente.
  /// Utilisé par le dashboard pour filtrer "mes ventes" pour les rôles
  /// `user` (un vendeur ne voit que ses propres ventes).
  /// Null pour les ventes historiques antérieures à hotfix_026.
  final String? createdByUserId;

  /// Ville où le client souhaite être livré (peut différer de son adresse
  /// par défaut). Utilisé pour inHouse / partner / shipment.
  final String? deliveryCity;

  /// Adresse précise de livraison (rue, quartier, immeuble).
  final String? deliveryAddress;

  /// Ville d'origine de l'expédition (où l'agence prend le colis).
  /// Utilisé uniquement quand `deliveryMode = shipment`.
  final String? shipmentCity;

  /// Nom de l'agence d'expédition (DHL, Express Union, La Poste...).
  /// Utilisé uniquement quand `deliveryMode = shipment`.
  final String? shipmentAgency;

  /// Personne responsable de l'expédition (qui a déposé le colis à l'agence).
  /// Utilisé uniquement quand `deliveryMode = shipment`.
  final String? shipmentHandler;

  /// Raison fournie par l'opérateur quand la commande est annulée par le
  /// client (statut `cancelled`). Permet de tracer pourquoi sans devoir
  /// chercher dans des notes libres.
  final String? cancellationReason;

  /// Raison fournie quand la commande est reprogrammée (statut repasse à
  /// `scheduled` après un empêchement d'une des parties). La présence de
  /// cette valeur sert également de marqueur "commande reprogrammée" pour
  /// l'affichage dans la liste.
  final String? rescheduleReason;

  const Sale({
    this.id,
    required this.shopId,
    required this.items,
    this.discountAmount = 0,
    this.taxRate        = 0,
    this.fees           = const [],
    required this.paymentMethod,
    this.status = SaleStatus.completed,
    this.clientId,
    this.clientName,
    this.clientPhone,
    this.notes,
    required this.createdAt,
    this.scheduledAt,
    this.syncedToCloud = false,
    this.deliveryMode,
    this.deliveryLocationId,
    this.deliveryPersonName,
    this.createdByUserId,
    this.deliveryCity,
    this.deliveryAddress,
    this.shipmentCity,
    this.shipmentAgency,
    this.shipmentHandler,
    this.cancellationReason,
    this.rescheduleReason,
  });

  double get subtotal  => items.fold(0, (s, i) => s + i.subtotal);
  /// Somme des frais de commande (livraison, emballage…). Ces frais sont
  /// comptabilisés comme **dépenses absorbées par la boutique** : ils
  /// réduisent la marge mais n'augmentent **pas** le prix de vente
  /// facturé au client (voir [total]).
  double get totalFees => fees.fold(0.0, (s, f) => s + ((f['amount'] as num?)?.toDouble() ?? 0));
  double get taxAmount => (subtotal - discountAmount) * taxRate / 100;
  /// Total facturé au client = prix articles (après remise) + TVA.
  /// Les frais sont absorbés et ne s'ajoutent PAS au prix de vente — ils
  /// sont répartis proportionnellement comme dépenses sur le prix de revient
  /// des articles côté dashboard/rapports.
  double get total     => subtotal - discountAmount + taxAmount;

  Sale copyWith({
    String? id, String? shopId, List<SaleItem>? items,
    double? discountAmount, double? taxRate,
    List<Map<String, dynamic>>? fees,
    PaymentMethod? paymentMethod, SaleStatus? status,
    String? clientId, String? clientName, String? clientPhone,
    String? notes, DateTime? createdAt, DateTime? scheduledAt,
    bool? syncedToCloud,
    DeliveryMode? deliveryMode,
    String? deliveryLocationId,
    String? deliveryPersonName,
    String? createdByUserId,
    String? deliveryCity,
    String? deliveryAddress,
    String? shipmentCity,
    String? shipmentAgency,
    String? shipmentHandler,
    String? cancellationReason,
    String? rescheduleReason,
  }) => Sale(
    id:                 id             ?? this.id,
    shopId:             shopId         ?? this.shopId,
    items:              items          ?? this.items,
    discountAmount:     discountAmount ?? this.discountAmount,
    taxRate:            taxRate        ?? this.taxRate,
    fees:               fees           ?? this.fees,
    paymentMethod:      paymentMethod  ?? this.paymentMethod,
    status:             status         ?? this.status,
    clientId:           clientId       ?? this.clientId,
    clientName:         clientName     ?? this.clientName,
    clientPhone:        clientPhone    ?? this.clientPhone,
    notes:              notes          ?? this.notes,
    createdAt:          createdAt      ?? this.createdAt,
    scheduledAt:        scheduledAt    ?? this.scheduledAt,
    syncedToCloud:      syncedToCloud  ?? this.syncedToCloud,
    deliveryMode:       deliveryMode       ?? this.deliveryMode,
    deliveryLocationId: deliveryLocationId ?? this.deliveryLocationId,
    deliveryPersonName: deliveryPersonName ?? this.deliveryPersonName,
    createdByUserId:    createdByUserId    ?? this.createdByUserId,
    deliveryCity:       deliveryCity       ?? this.deliveryCity,
    deliveryAddress:    deliveryAddress    ?? this.deliveryAddress,
    shipmentCity:       shipmentCity       ?? this.shipmentCity,
    shipmentAgency:     shipmentAgency     ?? this.shipmentAgency,
    shipmentHandler:    shipmentHandler    ?? this.shipmentHandler,
    cancellationReason: cancellationReason ?? this.cancellationReason,
    rescheduleReason:   rescheduleReason   ?? this.rescheduleReason,
  );

  @override
  List<Object?> get props => [id, shopId, items, total, status];
}