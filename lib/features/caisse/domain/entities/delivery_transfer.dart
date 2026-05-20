import 'package:equatable/equatable.dart';

/// Type de destinataire d'un transfert de commande au livreur.
/// Aligné sur le CHECK constraint SQL `delivery_transfers.target_type`.
enum DeliveryTargetType {
  /// Dépôt partenaire (FK vers stock_locations.id).
  partner,
  /// Employé du shop (FK vers auth.users.id via shop_memberships).
  employee,
  /// Numéro WhatsApp libre, non rattaché à une entité existante.
  free,
}

extension DeliveryTargetTypeX on DeliveryTargetType {
  String get key => switch (this) {
        DeliveryTargetType.partner  => 'partner',
        DeliveryTargetType.employee => 'employee',
        DeliveryTargetType.free     => 'free',
      };

  static DeliveryTargetType fromKey(String? s) => switch (s) {
        'partner'  => DeliveryTargetType.partner,
        'employee' => DeliveryTargetType.employee,
        _          => DeliveryTargetType.free,
      };
}

/// Audit immutable d'un transfert de commande effectué via WhatsApp.
/// Une fois créé (par la RPC `transfer_order_to_delivery`), un transfert
/// n'est JAMAIS modifié — seul `message_snapshot` reste source de vérité
/// de ce qui a réellement été envoyé.
///
/// Persistence :
///   • SQL  : table `delivery_transfers` (cf. hotfix_049, RLS members-only,
///            INSERT exclusivement via la RPC SECURITY DEFINER).
///   • Hive : non persisté (uniquement lecture remote, cache éphémère).
class DeliveryTransfer extends Equatable {
  final String              id;
  final String              orderId;
  final String              shopId;
  final String              senderUserId;
  final DeliveryTargetType  targetType;
  /// `stock_location.id` pour partner, `user_id` pour employee, null pour free.
  final String?             targetRef;
  final String              targetName;
  /// Format E.164 (ex: "+237699123456"). NULL si mode groupe (cf. hotfix_050).
  final String?             targetPhone;
  /// Lien d'invitation au groupe WhatsApp utilisé pour ce transfert
  /// (`https://chat.whatsapp.com/<code>`). NULL si mode 1-à-1.
  /// Au moins un des deux (`targetPhone` ou `targetGroupUrl`) est non null.
  final String?             targetGroupUrl;
  /// Soft-link vers le template utilisé. Reste consultable même si le
  /// template a été renommé ou supprimé (FK ON DELETE SET NULL).
  final String?             templateId;
  /// Texte exactement tel qu'envoyé sur WhatsApp (placeholders résolus,
  /// modifications manuelles incluses). Source de vérité de l'audit.
  final String              messageSnapshot;
  final DateTime            createdAt;

  const DeliveryTransfer({
    required this.id,
    required this.orderId,
    required this.shopId,
    required this.senderUserId,
    required this.targetType,
    this.targetRef,
    required this.targetName,
    this.targetPhone,
    this.targetGroupUrl,
    this.templateId,
    required this.messageSnapshot,
    required this.createdAt,
  });

  DeliveryTransfer copyWith({
    String?              id,
    String?              orderId,
    String?              shopId,
    String?              senderUserId,
    DeliveryTargetType?  targetType,
    String?              targetRef,
    String?              targetName,
    String?              targetPhone,
    String?              targetGroupUrl,
    String?              templateId,
    String?              messageSnapshot,
    DateTime?            createdAt,
  }) =>
      DeliveryTransfer(
        id:              id              ?? this.id,
        orderId:         orderId         ?? this.orderId,
        shopId:          shopId          ?? this.shopId,
        senderUserId:    senderUserId    ?? this.senderUserId,
        targetType:      targetType      ?? this.targetType,
        targetRef:       targetRef       ?? this.targetRef,
        targetName:      targetName      ?? this.targetName,
        targetPhone:     targetPhone     ?? this.targetPhone,
        targetGroupUrl:  targetGroupUrl  ?? this.targetGroupUrl,
        templateId:      templateId      ?? this.templateId,
        messageSnapshot: messageSnapshot ?? this.messageSnapshot,
        createdAt:       createdAt       ?? this.createdAt,
      );

  Map<String, dynamic> toMap() => {
        'id':               id,
        'order_id':         orderId,
        'shop_id':          shopId,
        'sender_user_id':   senderUserId,
        'target_type':      targetType.key,
        'target_ref':       targetRef,
        'target_name':      targetName,
        'target_phone':     targetPhone,
        'target_group_url': targetGroupUrl,
        'template_id':      templateId,
        'message_snapshot': messageSnapshot,
        'created_at':       createdAt.toIso8601String(),
      };

  static DeliveryTransfer fromMap(Map m) => DeliveryTransfer(
        id:           m['id']           as String,
        orderId:      m['order_id']     as String,
        shopId:       m['shop_id']      as String,
        senderUserId: m['sender_user_id'] as String,
        targetType:   DeliveryTargetTypeX.fromKey(
                         m['target_type'] as String?),
        targetRef:    m['target_ref']  as String?,
        targetName:   (m['target_name']  ?? '') as String,
        targetPhone:  m['target_phone'] as String?,
        targetGroupUrl: m['target_group_url'] as String?,
        templateId:   m['template_id']  as String?,
        messageSnapshot: (m['message_snapshot'] ?? '') as String,
        createdAt:    DateTime.tryParse(m['created_at']?.toString() ?? '')
                      ?? DateTime.now(),
      );

  @override
  List<Object?> get props => [id, orderId, createdAt];
}
