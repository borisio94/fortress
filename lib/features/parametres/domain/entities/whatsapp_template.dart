import 'package:equatable/equatable.dart';

// ═════════════════════════════════════════════════════════════════════════════
// WhatsappTemplate — modèle de message WhatsApp envoyé aux CLIENTS du shop
// (facture, relance commande, catalogue, nouveautés, promotion).
//
// Distinct de `DeliveryTemplate` (hotfix_049) qui cible les LIVREURS internes.
//
// `body` peut contenir des placeholders `{{variable}}` remplacés au moment de
// l'envoi par [WhatsappTemplateRenderer]. La liste des variables disponibles
// dépend du `type` (cf. [WhatsappTemplateTypeX.variables]).
//
// Persistence :
//   • SQL  : table `whatsapp_templates` (hotfix_067).
//   • Hive : `HiveBoxes.whatsappTemplatesBox` (cache offline).
// ═════════════════════════════════════════════════════════════════════════════

/// Type de template : détermine les variables disponibles et le call site
/// qui utilise le template comme défaut.
enum WhatsappTemplateType {
  invoice,
  orderReminder,
  catalogue,
  news,
  promo;
}

extension WhatsappTemplateTypeX on WhatsappTemplateType {
  /// Identifiant persistant côté SQL (colonne `type`).
  String get key => switch (this) {
        WhatsappTemplateType.invoice       => 'invoice',
        WhatsappTemplateType.orderReminder => 'order_reminder',
        WhatsappTemplateType.catalogue     => 'catalogue',
        WhatsappTemplateType.news          => 'news',
        WhatsappTemplateType.promo         => 'promo',
      };

  /// Libellé affiché en UI.
  String get label => switch (this) {
        WhatsappTemplateType.invoice       => 'Facture',
        WhatsappTemplateType.orderReminder => 'Relance commande',
        WhatsappTemplateType.catalogue     => 'Catalogue',
        WhatsappTemplateType.news          => 'Nouveautés',
        WhatsappTemplateType.promo         => 'Promotion',
      };

  /// Description du cas d'usage — affichée comme hint dans la page liste.
  String get description => switch (this) {
        WhatsappTemplateType.invoice       =>
          'Envoyé après une vente avec le lien du PDF facture.',
        WhatsappTemplateType.orderReminder =>
          'Envoyé pour confirmer une commande programmée non livrée.',
        WhatsappTemplateType.catalogue     =>
          'Envoyé pour partager le catalogue produits avec un client.',
        WhatsappTemplateType.news          =>
          'Annonce de nouveaux produits ajoutés au catalogue.',
        WhatsappTemplateType.promo         =>
          'Campagne promotionnelle (réductions, soldes).',
      };

  /// Liste des variables `{{var}}` disponibles pour ce type. Les chips
  /// cliquables du form sheet sont rendues à partir de cette liste.
  List<String> get variables => switch (this) {
        WhatsappTemplateType.invoice       => const [
            'client_name', 'shop_name', 'link',
            'total', 'order_id', 'date',
          ],
        WhatsappTemplateType.orderReminder => const [
            'client_name', 'shop_name', 'link',
            'total', 'delivery_date',
          ],
        WhatsappTemplateType.catalogue     => const [
            'client_name', 'shop_name', 'link',
          ],
        WhatsappTemplateType.news          => const [
            'client_name', 'shop_name', 'link', 'product_name',
          ],
        WhatsappTemplateType.promo         => const [
            'client_name', 'shop_name', 'link', 'discount',
          ],
      };

  /// Corps par défaut utilisé au seed initial.
  String get defaultBody => switch (this) {
        WhatsappTemplateType.invoice       =>
          'Bonjour {{client_name}} 👋\n\n'
              'Votre facture est disponible.\n\n'
              '📄 {{link}}\n\n'
              'Merci pour votre confiance.\n\n'
              '{{shop_name}}',
        WhatsappTemplateType.orderReminder =>
          'Bonjour {{client_name}} 👋\n\n'
              'Petit rappel pour votre commande prévue le {{delivery_date}}.\n\n'
              '📦 {{link}}\n\n'
              'Êtes-vous disponible pour la livraison ?\n\n'
              '{{shop_name}}',
        WhatsappTemplateType.catalogue     =>
          'Bonjour {{client_name}} 👋\n\n'
              'Découvrez notre catalogue.\n\n'
              '🛍️ {{link}}\n\n'
              'À très bientôt !\n\n'
              '{{shop_name}}',
        WhatsappTemplateType.news          =>
          'Bonjour {{client_name}} 👋\n\n'
              'Nouveautés disponibles : {{product_name}}.\n\n'
              '✨ {{link}}\n\n'
              'À très bientôt !\n\n'
              '{{shop_name}}',
        WhatsappTemplateType.promo         =>
          'Bonjour {{client_name}} 👋\n\n'
              'Promotion exceptionnelle jusqu\'à {{discount}}% !\n\n'
              '🔥 {{link}}\n\n'
              'Offre limitée — profitez-en vite !\n\n'
              '{{shop_name}}',
      };

  /// Nom par défaut du template seedé pour ce type.
  String get defaultName => switch (this) {
        WhatsappTemplateType.invoice       => 'Facture (défaut)',
        WhatsappTemplateType.orderReminder => 'Relance (défaut)',
        WhatsappTemplateType.catalogue     => 'Catalogue (défaut)',
        WhatsappTemplateType.news          => 'Nouveautés (défaut)',
        WhatsappTemplateType.promo         => 'Promotion (défaut)',
      };

  static WhatsappTemplateType fromKey(String? k) => switch (k) {
        'order_reminder' => WhatsappTemplateType.orderReminder,
        'catalogue'      => WhatsappTemplateType.catalogue,
        'news'           => WhatsappTemplateType.news,
        'promo'          => WhatsappTemplateType.promo,
        _                => WhatsappTemplateType.invoice,
      };
}

class WhatsappTemplate extends Equatable {
  final String               id;
  final String               shopId;
  final WhatsappTemplateType type;
  final String               name;
  final String               body;
  final bool                 isDefault;
  final DateTime             createdAt;
  final DateTime             updatedAt;

  const WhatsappTemplate({
    required this.id,
    required this.shopId,
    required this.type,
    required this.name,
    required this.body,
    this.isDefault = false,
    required this.createdAt,
    required this.updatedAt,
  });

  WhatsappTemplate copyWith({
    String?               id,
    String?               shopId,
    WhatsappTemplateType? type,
    String?               name,
    String?               body,
    bool?                 isDefault,
    DateTime?             createdAt,
    DateTime?             updatedAt,
  }) =>
      WhatsappTemplate(
        id:        id        ?? this.id,
        shopId:    shopId    ?? this.shopId,
        type:      type      ?? this.type,
        name:      name      ?? this.name,
        body:      body      ?? this.body,
        isDefault: isDefault ?? this.isDefault,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'id':         id,
        'shop_id':    shopId,
        'type':       type.key,
        'name':       name,
        'body':       body,
        'is_default': isDefault,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  static WhatsappTemplate fromMap(Map m) => WhatsappTemplate(
        id:        m['id']      as String,
        shopId:    m['shop_id'] as String,
        type:      WhatsappTemplateTypeX.fromKey(m['type']?.toString()),
        name:      (m['name']   ?? '') as String,
        body:      (m['body']   ?? '') as String,
        isDefault: m['is_default'] == true,
        createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '')
            ?? DateTime.now(),
        updatedAt: DateTime.tryParse(m['updated_at']?.toString() ?? '')
            ?? DateTime.now(),
      );

  @override
  List<Object?> get props => [id, shopId, type, name, body, isDefault];
}
