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

/// Workflow de paiement orthogonal au `SaleStatus`. Permet de distinguer
/// les commandes avec acompte partiel (versement boutique avant livraison)
/// des commandes entièrement payées. Le partenaire-livreur ne doit
/// rapporter à la boutique que le SOLDE (= total − amountPaid), pas le
/// total brut. Voir `hotfix_065_orders_payment_tracking.sql`.
enum PaymentStatus {
  unpaid,    // Rien d'encaissé
  partial,   // Acompte versé, solde restant
  paid,      // Totalement encaissée, la boutique a l'argent
  refunded,  // Remboursée

  /// Le CLIENT a tout payé, mais au PARTENAIRE-LIVREUR, qui n'a pas encore
  /// versé à la boutique.
  ///
  /// Sans cette valeur, la clôture « partenaire encaisseur » écrivait `paid` :
  /// la commande passait pour soldée côté boutique alors que l'argent était
  /// ailleurs, et la contrepartie ne subsistait que dans le livre partenaire.
  /// Rien ne le signalait sur la commande elle-même.
  ///
  /// Ce n'est PAS une créance client — le client ne doit plus rien. C'est une
  /// créance sur le partenaire, que le livre partenaire porte déjà.
  /// Cf. `hotfix_175_payment_status_paid_by_partner.sql`.
  paidByPartner,
}

extension PaymentStatusX on PaymentStatus {
  /// Clé canonique côté SQL et JSON.
  String get key => switch (this) {
    PaymentStatus.unpaid        => 'unpaid',
    PaymentStatus.partial       => 'partial',
    PaymentStatus.paid          => 'paid',
    PaymentStatus.refunded      => 'refunded',
    PaymentStatus.paidByPartner => 'paid_by_partner',
  };
  String get label => switch (this) {
    PaymentStatus.unpaid        => 'Non payé',
    PaymentStatus.partial       => 'Acompte',
    PaymentStatus.paid          => 'Payé',
    PaymentStatus.refunded      => 'Remboursé',
    PaymentStatus.paidByPartner => 'Encaissé par le partenaire',
  };
  Color get color => switch (this) {
    PaymentStatus.unpaid        => const Color(0xFFEF4444),
    PaymentStatus.partial       => const Color(0xFFF59E0B),
    PaymentStatus.paid          => const Color(0xFF10B981),
    PaymentStatus.refunded      => const Color(0xFF9CA3AF),
    // Ambre comme l'acompte : le client ne doit rien, mais quelque chose
    // reste en attente — le versement du partenaire.
    PaymentStatus.paidByPartner => const Color(0xFFF59E0B),
  };
  static PaymentStatus fromKey(String? s) => switch ((s ?? '').toLowerCase()) {
    'partial'         => PaymentStatus.partial,
    'paid'            => PaymentStatus.paid,
    'refunded'        => PaymentStatus.refunded,
    'paid_by_partner' => PaymentStatus.paidByPartner,
    _                 => PaymentStatus.unpaid,
  };

  /// `true` si le CLIENT a tout réglé — que la boutique ait l'argent en main
  /// ou que le partenaire le détienne encore. Sert partout où l'on demande
  /// « reste-t-il quelque chose à recouvrer AUPRÈS DU CLIENT ? ».
  bool get isSettledByClient =>
      this == PaymentStatus.paid || this == PaymentStatus.paidByPartner;

  /// Dérive le statut de paiement à partir du montant encaissé et du total
  /// facturé. Convention unique partagée par la création de commande,
  /// l'enregistrement d'acompte et la clôture (vente à crédit) :
  ///   • `amountPaid >= total`  → `paid`   (soldée — couvre aussi total = 0)
  ///   • `amountPaid <= 0`      → `unpaid` (rien encaissé)
  ///   • sinon                  → `partial` (acompte / créance partielle)
  static PaymentStatus fromAmount(double amountPaid, double total) {
    if (amountPaid >= total) return PaymentStatus.paid;
    if (amountPaid <= 0) return PaymentStatus.unpaid;
    return PaymentStatus.partial;
  }
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

// ════════════════════════════════════════════════════════════════════════════
// GF-4 — Automate de transitions d'état (verrou anti erreurs humaines).
//
// Règle générale : completed / cancelled / refused / refunded sont
// (quasi-)terminaux. Une commande complétée ne repart PAS « en cours » ou
// « programmée » — seul `refunded` est accessible depuis `completed` (et
// strictement via le flow Retour). Toute tentative de re-modifier un état
// terminal lève `TransitionInterditeException`.
//
// `→ cancelled` exige un motif (`cancellation_reason` non vide) — sinon
// `MotifRequiredException`. Code d'erreur lisible : `transition_interdite`
// / `motif_required` (cohérent avec la spec PR-B).
// ════════════════════════════════════════════════════════════════════════════

class SaleStatusTransitions {
  SaleStatusTransitions._();

  /// `from → toAllowed` : ensembles autorisés.
  /// La transition `from == to` est toujours acceptée (no-op).
  static const _allowed = <SaleStatus, Set<SaleStatus>>{
    SaleStatus.scheduled:  {
      SaleStatus.processing,
      SaleStatus.completed,
      SaleStatus.cancelled,
      SaleStatus.refused,
    },
    SaleStatus.processing: {
      SaleStatus.completed,
      SaleStatus.scheduled, // reprogrammation
      SaleStatus.cancelled,
      SaleStatus.refused,
    },
    SaleStatus.completed:  {
      SaleStatus.refunded, // retour client
      // Correction d'erreur / re-finalisation : repasser une commande
      // complétée en « programmée ». Le datasource restitue alors le stock
      // et remet le paiement à zéro ; l'appelant (caisse_page) purge les
      // écritures partenaire de la commande. Action réservée admin.
      SaleStatus.scheduled,
    },
    SaleStatus.cancelled:  {},
    SaleStatus.refused:    {},
    SaleStatus.refunded:   {},
  };

  /// Statuts qui exigent `cancellation_reason` non vide.
  static const _motifRequired = <SaleStatus>{
    SaleStatus.cancelled,
  };

  static bool canTransition(SaleStatus from, SaleStatus to) {
    if (from == to) return true;
    return _allowed[from]?.contains(to) ?? false;
  }

  static bool requiresMotif(SaleStatus to) => _motifRequired.contains(to);
}

class TransitionInterditeException implements Exception {
  final SaleStatus from;
  final SaleStatus to;
  const TransitionInterditeException(this.from, this.to);
  String get code => 'transition_interdite';
  String get message =>
      'Transition interdite : « ${from.label} » → « ${to.label} ».';
  @override
  String toString() => 'TransitionInterditeException($from → $to)';
}

class MotifRequiredException implements Exception {
  final SaleStatus to;
  const MotifRequiredException(this.to);
  String get code => 'motif_required';
  String get message =>
      'Motif obligatoire pour passer le statut à « ${to.label} ».';
  @override
  String toString() => 'MotifRequiredException($to)';
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

  /// POURQUOI cette remise a été accordée — restauration uniquement.
  ///
  /// Exigé par la feuille de remise, qui refuse de valider sans lui. Il partait
  /// jusqu'au 22/09/2026 dans `activity_logs` et nulle part ailleurs : un champ
  /// imposé au serveur, invisible sur l'addition comme sur la facture.
  ///
  /// Il voyage désormais avec la commande (`orders.discount_reason`,
  /// hotfix_181) — le journal n'est pas lisible hors ligne, et c'est là qu'un
  /// restaurant travaille.
  ///
  /// NUL CÔTÉ E-COMMERCE : son chemin de remise ne demande aucun motif.
  final String? discountReason;
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

  /// Quartier de livraison sélectionné (système frais par quartier, PR-2).
  /// Texte (nom du quartier), figé sur la commande.
  final String? deliveryQuartier;

  /// Zone de livraison (regroupement) du quartier choisi, si renseignée.
  final String? deliveryZone;

  /// Prix de livraison (FCFA) du quartier choisi. **AJOUTÉ au [total]**
  /// facturé au client (contrairement aux [fees] absorbés par la boutique).
  /// `null` = « frais à fixer » (commande web dont le quartier n'est pas
  /// répertorié — le marchand fixera le prix). `0` = livraison gratuite.
  /// `>0` = montant. Cf. système frais par quartier (PR-2/PR-3).
  final double? deliveryPrice;

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

  /// Origine de la commande (canal). `'pos'` (par défaut) pour les ventes
  /// saisies en boutique, `'web'` pour celles passées via le catalogue
  /// public, `'whatsapp'` pour les futures intégrations conversationnelles.
  /// Orthogonal au [status] (workflow). Cf. hotfix_047.
  final String source;

  /// Somme effectivement encaissée à ce jour (par la boutique en acompte
  /// ou par le partenaire-livreur à la livraison). Orthogonal à [total]
  /// qui est le montant facturé.
  final double amountPaid;

  /// Statut de paiement orthogonal au [status] (workflow commande).
  /// Cf. [PaymentStatus] et hotfix_065_orders_payment_tracking.sql.
  final PaymentStatus paymentStatus;

  /// Clé d'idempotence (UUID v4) générée à l'OUVERTURE du panier dans
  /// `CaisseBloc` — garde-fou GF-1. Empêche les doublons de vente quand
  /// le sync queue rejoue plusieurs fois la même création (perte réseau,
  /// double-tap, etc.). Côté Supabase, contrainte `UNIQUE` sur la colonne
  /// `idempotency_key` → l'INSERT en doublon échoue silencieusement.
  /// Null pour les commandes legacy pré-PR-A.
  final String? idempotencyKey;

  /// Secret du lien de suivi public (hotfix_171), distinct de [id].
  ///
  /// Le lien `/track/<token>` envoyé au client ne porte plus l'identifiant :
  /// celui des commandes créées dans l'app est `order_<horodatage>`, donc
  /// énumérable, et servait pourtant de seul secret. Le jeton est GÉNÉRÉ PAR
  /// LE SERVEUR et n'est jamais écrit par le client — il est seulement relu.
  ///
  /// `null` tant que la commande n'a pas été synchronisée (création hors
  /// ligne) : l'appelant retombe alors sur [id], qui reste lisible.
  final String? trackingToken;

  /// Soft-delete (hotfix_084). Quand non-null, la commande est masquée
  /// des listes membres et n'est plus visible qu'aux super-admins via
  /// l'écran « Commandes supprimées ». L'UPDATE est exécuté par la RPC
  /// `delete_sale` côté serveur, et propagé en local par realtime + par
  /// le `DeleteSaleUseCase` (qui marque Hive immédiatement, sans attendre
  /// l'écho serveur). Le rollback de stock est appliqué en parallèle via
  /// `StockService.reverseSale(...)`.
  final DateTime? deletedAt;
  /// `auth.users.id` de l'utilisateur qui a supprimé. Null si non
  /// supprimée. Persisté pour audit (visible dans `activity_logs` aussi).
  final String?   deletedBy;
  /// Motif fourni par l'opérateur (min 10 caractères, vérifié côté
  /// dialog Flutter ET côté RPC SQL). Toujours non-vide si `deletedAt`
  /// est non-null. Null si non supprimée.
  final String?   deleteReason;

  /// Vente « à choisir sur place » : le livreur emporte plusieurs articles
  /// candidats, le client en garde certains, le reste revient. Le stock est
  /// RÉSERVÉ (décrémenté) dès la création, puis réconcilié à la clôture
  /// (gardé = vendu, retourné = remis en stock). Cf. ApprovalClosure.
  final bool isApprovalSale;
  /// Garde-fou anti-double-comptage : `true` une fois les articles candidats
  /// décrémentés (réservés). Évite de re-décrémenter à la complétion.
  final bool stockReserved;

  // ── Module restaurant (hotfix_137) ────────────────────────────────────
  /// Table du plan de salle rattachée à la commande. `null` pour toute
  /// commande non servie en salle (e-commerce, à emporter, comptoir).
  final String? tableId;
  /// Compte (addition) auquel appartient la commande — libellé libre :
  /// « Compte 1 », « M. Ali »… (hotfix_143).
  ///
  /// Plusieurs comptes coexistent sur une même [tableId] : c'est ce champ qui
  /// distingue deux additions à la même table. Il vit sur la COMMANDE et non
  /// sur la table, car un compte peut exister sans table (plats à emporter).
  /// `null` = commande sans compte nommé.
  final String? tabLabel;

  /// Nombre de couverts du service. `null` hors service en salle.
  final int? covers;
  /// Canal de service : `dine_in` (salle) · `takeaway` · `delivery`.
  /// Non-nullable avec défaut, comme [source] — la colonne est NOT NULL.
  final String orderType;
  /// Bon envoyé en préparation (alimente l'écran Préparation, tous postes).
  final bool sentToKitchen;
  /// Préparation terminée, prête à être servie.
  final bool kitchenReady;

  /// Plats effectivement APPORTÉS au client.
  ///
  /// Distinct de [kitchenReady], et c'est tout l'intérêt : entre le moment où
  /// la cuisine pose l'assiette au passe et celui où le serveur la dépose sur
  /// la table, il s'écoule un temps pendant lequel le plat refroidit sans que
  /// personne ne soit alerté. Ce drapeau est ce qui permet de faire ressortir
  /// la table tant que le service n'est pas fait.
  final bool served;

  const Sale({
    this.id,
    required this.shopId,
    required this.items,
    this.discountAmount = 0,
    this.discountReason,
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
    this.deliveryQuartier,
    this.deliveryZone,
    this.deliveryPrice,
    this.shipmentCity,
    this.shipmentAgency,
    this.shipmentHandler,
    this.cancellationReason,
    this.rescheduleReason,
    this.source = 'pos',
    this.amountPaid = 0,
    this.paymentStatus = PaymentStatus.unpaid,
    this.idempotencyKey,
    this.trackingToken,
    this.deletedAt,
    this.deletedBy,
    this.deleteReason,
    this.isApprovalSale = false,
    this.stockReserved  = false,
    this.tableId,
    this.tabLabel,
    this.covers,
    this.orderType      = 'takeaway',
    this.sentToKitchen  = false,
    this.kitchenReady   = false,
    this.served         = false,
    this.finished       = false,
  });

  /// True si la commande est soft-deleted (cf. hotfix_084).
  bool get isDeleted => deletedAt != null;

  /// LA CUISINE A FINI, LE CLIENT N'A RIEN. C'est l'état qui doit alerter :
  /// c'est là, et seulement là, que des plats refroidissent au passe.
  bool get isWaitingService => kitchenReady && !served;

  /// Service TERMINÉ, mais pas encore encaissé.
  ///
  /// En salle : le client a fini de manger. Au comptoir : il a récupéré sa
  /// commande. En livraison : le livreur l'a remise. Trois réalités, un seul
  /// fait — il n'y a plus rien à faire pour le service, il ne reste que
  /// l'argent.
  ///
  /// Étape DISTINCTE de l'encaissement à dessein : on dessert une table bien
  /// avant que le client ne demande l'addition, et une commande à emporter
  /// part souvent payée d'avance. Confondre les deux, c'est soit libérer la
  /// table trop tôt, soit la garder occupée après le départ.
  final bool finished;

  /// Prête à encaisser : le service est fait, l'argent non.
  bool get isFinished => finished;

  double get subtotal  => items.fold(0, (s, i) => s + i.subtotal);
  /// Somme des dépenses supplémentaires de la commande (emballage, etc.).
  /// Elles s'AJOUTENT au total facturé au client (voir [total]) — elles ne
  /// sont plus « absorbées » par la boutique.
  double get totalFees => fees.fold(0.0, (s, f) => s + ((f['amount'] as num?)?.toDouble() ?? 0));
  double get taxAmount => (subtotal - discountAmount) * taxRate / 100;
  /// Total facturé au client = PRIX DE VENTE + TOUTES les dépenses
  /// supplémentaires, qui s'ajustent PAR-DESSUS le prix de vente (sans s'y
  /// intégrer) :
  ///   • prix de vente = prix des articles (prix MODIFIÉ pris en compte)
  ///     − remise + TVA ;
  ///   • [deliveryPrice] = frais de livraison (quartier / saisis) ;
  ///   • [totalFees]     = autres dépenses (emballage…).
  /// Plus aucun frais absorbé : chaque dépense majore le total.
  double get total =>
      subtotal - discountAmount + taxAmount + (deliveryPrice ?? 0) + totalFees;

  /// `true` si c'est une commande web dont les frais de livraison restent à
  /// fixer par le marchand (quartier non répertorié → `deliveryPrice` null).
  bool get deliveryFeeToFix => deliveryPrice == null && source == 'web';

  /// Reste à payer PAR LE CLIENT = total − amountPaid, jamais négatif. Zéro
  /// dès que le client a soldé, y compris lorsqu'il a payé au partenaire
  /// (couvre aussi les commandes legacy pré-hotfix_065 où `amountPaid` n'est
  /// pas peuplé).
  double get amountDue =>
      paymentStatus.isSettledByClient
          ? 0
          : (total - amountPaid).clamp(0, double.infinity);

  /// `true` si la commande est totalement encaissée — en une fois, via
  /// acompte + solde, ou par le partenaire-livreur. Du point de vue du
  /// client il n'y a plus rien à percevoir dans les trois cas ; ce que le
  /// partenaire doit encore verser relève du livre partenaire.
  bool get isFullyPaid => paymentStatus.isSettledByClient;

  Sale copyWith({
    String? id, String? shopId, List<SaleItem>? items,
    double? discountAmount, String? discountReason, double? taxRate,
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
    String? deliveryQuartier,
    String? deliveryZone,
    double? deliveryPrice,
    String? shipmentCity,
    String? shipmentAgency,
    String? shipmentHandler,
    String? cancellationReason,
    String? rescheduleReason,
    String? source,
    double? amountPaid,
    PaymentStatus? paymentStatus,
    String? idempotencyKey,
    String? trackingToken,
    DateTime? deletedAt,
    String?   deletedBy,
    String?   deleteReason,
    bool      clearDeleted = false,
    bool?     isApprovalSale,
    bool?     stockReserved,
    String?   tableId,
    String?   tabLabel,
    int?      covers,
    String?   orderType,
    bool?     sentToKitchen,
    bool?     kitchenReady,
    bool?     served,
    bool?     finished,
    /// Détache la commande de sa table (libération après encaissement).
    /// Indispensable : ce `copyWith` résout les nullables par `??`, donc
    /// `copyWith(tableId: null)` serait un no-op silencieux et la commande
    /// resterait accrochée à une table déjà libérée. Même mécanisme que
    /// [clearDeleted] ci-dessus.
    bool      clearTable = false,
  }) => Sale(
    id:                 id             ?? this.id,
    shopId:             shopId         ?? this.shopId,
    items:              items          ?? this.items,
    discountAmount:     discountAmount ?? this.discountAmount,
    discountReason:     discountReason ?? this.discountReason,
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
    deliveryQuartier:   deliveryQuartier   ?? this.deliveryQuartier,
    deliveryZone:       deliveryZone       ?? this.deliveryZone,
    deliveryPrice:      deliveryPrice      ?? this.deliveryPrice,
    shipmentCity:       shipmentCity       ?? this.shipmentCity,
    shipmentAgency:     shipmentAgency     ?? this.shipmentAgency,
    shipmentHandler:    shipmentHandler    ?? this.shipmentHandler,
    cancellationReason: cancellationReason ?? this.cancellationReason,
    rescheduleReason:   rescheduleReason   ?? this.rescheduleReason,
    source:             source             ?? this.source,
    amountPaid:         amountPaid         ?? this.amountPaid,
    paymentStatus:      paymentStatus      ?? this.paymentStatus,
    idempotencyKey:     idempotencyKey     ?? this.idempotencyKey,
    trackingToken:      trackingToken      ?? this.trackingToken,
    deletedAt:    clearDeleted ? null : (deletedAt    ?? this.deletedAt),
    deletedBy:    clearDeleted ? null : (deletedBy    ?? this.deletedBy),
    deleteReason: clearDeleted ? null : (deleteReason ?? this.deleteReason),
    isApprovalSale: isApprovalSale ?? this.isApprovalSale,
    stockReserved:  stockReserved  ?? this.stockReserved,
    tableId:        clearTable ? null : (tableId ?? this.tableId),
    // Le compte SURVIT au détachement de la table : une commande à emporter
    // garde son compte, et un compte transféré ne doit pas perdre son nom.
    tabLabel:       tabLabel ?? this.tabLabel,
    covers:         clearTable ? null : (covers  ?? this.covers),
    orderType:      orderType      ?? this.orderType,
    sentToKitchen:  sentToKitchen  ?? this.sentToKitchen,
    kitchenReady:   kitchenReady   ?? this.kitchenReady,
    served:         served         ?? this.served,
    finished:       finished       ?? this.finished,
  );

  /// True si la commande est servie en salle (rattachée à une table).
  bool get isDineIn => orderType == 'dine_in';

  /// True si le bon est en cours de préparation en cuisine.
  bool get isInKitchen => sentToKitchen && !kitchenReady;

  @override
  // `sentToKitchen`/`kitchenReady`/`tableId` sont dans props À DESSEIN :
  // sans eux, un ticket qui passe « envoyé » → « prêt » ne changerait pas
  // l'égalité Equatable et l'écran Cuisine resterait figé alors que la
  // donnée a bougé.
  List<Object?> get props =>
      [id, shopId, items, total, status,
       tableId, sentToKitchen, kitchenReady, served, finished];
}