import 'package:equatable/equatable.dart';
import '../../../auth/domain/entities/user.dart';

/// Type de boutique :
///   - [main]         : boutique principale, possède le catalogue source.
///   - [partnerDepot] : dépôt partenaire / boutique satellite, hérite du
///                       catalogue d'une boutique main via `parentShopId`.
enum ShopKind { main, partnerDepot }

extension ShopKindX on ShopKind {
  String get key => switch (this) {
    ShopKind.main         => 'main',
    ShopKind.partnerDepot => 'partner_depot',
  };

  static ShopKind fromKey(String? k) => switch (k) {
    'partner_depot' => ShopKind.partnerDepot,
    _               => ShopKind.main,
  };

  bool get isPartnerDepot => this == ShopKind.partnerDepot;
}

class ShopSummary extends Equatable {
  final String id;
  final String name;
  final String? logoUrl;
  final String currency;
  final String country;
  final String sector;
  final bool isActive;
  final double? todaySales;

  /// ID du créateur — devient automatiquement admin
  final String? ownerId;
  final String? phone;
  /// Numéro WhatsApp DÉDIÉ (commandes/catalogue). Distinct de [phone]
  /// (contact affiché). Si null/vide, les liens wa.me retombent sur [phone].
  final String? whatsappPhone;
  final String? email;

  /// ID du Pixel Meta (Facebook/Instagram) connecté par le commerçant.
  /// Optionnel. Quand renseigné, la page publique `/catalogue/:shopId` injecte
  /// le pixel et remonte les évènements de conversion vers Meta. Jamais utilisé
  /// sur les pages internes Fortress. Identifiant de tracking public (non
  /// sensible).
  final String? facebookPixelId;

  /// Ancienneté, EN JOURS, au-delà de laquelle une vente encaissée par un
  /// partenaire et non reversée est signalée (bandeau du tableau de bord,
  /// carte partenaire). Défaut 30 ; borné 1–365 côté SQL (hotfix_178).
  ///
  /// Porté par `shops` et NON par `ShopSettingsStore` : ce dernier n'écrit
  /// que dans Hive (cf. `caisse_tax_rate`), donc un seuil réglé sur le
  /// téléphone ne suivrait pas le commerçant sur sa tablette. Un réglage
  /// métier doit être partagé par tous les appareils de la boutique.
  final int partnerDebtAlertDays;

  /// SEUILS DE RETARD DU SERVICE, en minutes (hotfix_183, 25/09/2026).
  ///
  /// Au-delà, le chronomètre de la carte de commande passe en retard. Un par
  /// état, parce qu'un même délai n'a pas le même sens partout :
  ///   • [serviceLateSendMin] — « À envoyer » : personne n'a pris la commande
  ///     en charge (5 min) ;
  ///   • [serviceLateKitchenMin] — « En préparation » : le temps d'un plat
  ///     chaud (20 min) ;
  ///   • [serviceLatePassMin] — « À servir » : le plat refroidit au passe
  ///     (5 min).
  /// Colonnes `shops`, et non `ShopSettingsStore` (Hive local) : un seuil
  /// doit être le même sur le téléphone du serveur et celui du gérant.
  final int serviceLateSendMin;
  final int serviceLateKitchenMin;
  final int serviceLatePassMin;

  /// Date de création (pour le DatePicker période personnalisée)
  final DateTime? createdAt;

  /// Membres de la boutique avec leurs rôles
  final List<ShopMembership> members;

  /// Type de la boutique (cf. [ShopKind]). Défaut [ShopKind.main].
  final ShopKind kind;

  /// Pour kind=partnerDepot : id de la boutique main qui détient le
  /// catalogue. NULL pour main.
  final String? parentShopId;

  /// Statut administratif (cf. SA-1) — `'active'` | `'suspended'`.
  /// Distinct de [isActive] : `isActive` est le toggle de l'owner
  /// (visibilité), `status='suspended'` est une suspension imposée par le
  /// super-admin qui bloque TOTALEMENT l'accès des membres.
  final String status;
  final DateTime? suspendedAt;
  final String? suspendedReason;

  /// True si la boutique a été suspendue par le super-admin.
  bool get isSuspended => status == 'suspended';

  const ShopSummary({
    required this.id,
    required this.name,
    this.logoUrl,
    required this.currency,
    required this.country,
    required this.sector,
    this.isActive = true,
    this.todaySales,
    this.ownerId,
    this.phone,
    this.whatsappPhone,
    this.email,
    this.facebookPixelId,
    this.partnerDebtAlertDays = 30,
    this.serviceLateSendMin = kServiceLateSendDefault,
    this.serviceLateKitchenMin = kServiceLateKitchenDefault,
    this.serviceLatePassMin = kServiceLatePassDefault,
    this.createdAt,
    this.members = const [],
    this.kind = ShopKind.main,
    this.parentShopId,
    this.status = 'active',
    this.suspendedAt,
    this.suspendedReason,
  });

  /// Trouver le rôle d'un utilisateur dans cette boutique
  UserRole? roleOf(String userId) =>
      members.where((m) => m.shopId == id && m.shopId == userId).firstOrNull?.role
          ?? (userId == ownerId ? UserRole.admin : null);

  /// Raccourcis sémantiques.
  bool get isMain         => kind == ShopKind.main;
  bool get isPartnerDepot => kind == ShopKind.partnerDepot;

  @override
  // Les trois seuils y sont : sans eux, une boutique dont seul un seuil
  // change serait « égale » à l'ancienne, et l'écran qui le règle ne
  // verrait pas sa propre modification.
  List<Object?> get props => [id, name, currency, country, sector, isActive,
      ownerId, kind, parentShopId,
      serviceLateSendMin, serviceLateKitchenMin, serviceLatePassMin];
}

/// Défauts des seuils de retard — les mêmes que le `default` SQL de
/// hotfix_183. Une seule source côté client.
const int kServiceLateSendDefault = 5;
const int kServiceLateKitchenDefault = 20;
const int kServiceLatePassDefault = 5;
