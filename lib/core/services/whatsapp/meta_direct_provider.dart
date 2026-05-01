import '../whatsapp_service.dart' show IWhatsappProvider;

// ═════════════════════════════════════════════════════════════════════════════
// MetaDirectProvider — implémentation IWhatsappProvider via l'API
// WhatsApp Business Cloud directement chez Meta (graph.facebook.com).
//
// **NON IMPLÉMENTÉ** — toutes les méthodes lèvent `UnimplementedError`.
// Activer ce provider quand l'app Meta WhatsApp Business sera approuvée
// et que le numéro sera vérifié.
//
// Paramètres prévus (à stocker dans la table Supabase
// `shop_whatsapp_config` à créer plus tard) :
//   • access_token         : token Bearer permanent (System User Token)
//   • phone_number_id      : ID du numéro WhatsApp Business côté Meta
//   • whatsapp_business_id : ID du compte WhatsApp Business
//
// Endpoint Meta :
//   POST https://graph.facebook.com/v19.0/{phone_number_id}/messages
//   Header Authorization: Bearer <access_token>
//   Body JSON : {messaging_product: "whatsapp", to: "<phone>",
//                type: "text|template|document|image", ...}
//
// Activation : changer `WhatsappProviderType` (whatsapp_service.dart) à
// `metaDirect` côté config Hive — aucune autre modif nécessaire si ce
// fichier est implémenté.
// ═════════════════════════════════════════════════════════════════════════════

class MetaDirectProvider implements IWhatsappProvider {
  // TODO: injecter accessToken / phoneNumberId depuis la table
  //       `shop_whatsapp_config` (Supabase) ou un Hive box dédié.
  final String? accessToken;
  final String? phoneNumberId;

  const MetaDirectProvider({
    this.accessToken,
    this.phoneNumberId,
  });

  static const _err = 'MetaDirectProvider non implémenté — '
      'à brancher quand l\'app Meta WhatsApp Business sera approuvée. '
      'Voir lib/core/services/whatsapp/meta_direct_provider.dart pour '
      'les TODO.';

  @override
  Future<bool> sendMessage(String phone, String message) {
    // TODO: POST {phone_id}/messages avec body JSON :
    //       { "messaging_product": "whatsapp", "to": "<phone>",
    //         "type": "text", "text": { "body": "<message>" } }
    //       Limitation Meta : hors de la fenêtre de 24h depuis la dernière
    //       interaction client, il faut utiliser un *template* approuvé.
    throw UnimplementedError(_err);
  }

  @override
  Future<bool> sendFile(String phone, String message, String fileUrl) {
    // TODO: 2 messages séparés OU type "document" avec caption :
    //       { "type": "document",
    //         "document": { "link": "<fileUrl>", "caption": "<message>" } }
    throw UnimplementedError(_err);
  }

  @override
  Future<bool> sendCatalogue(
      String phone, String message, String catalogueUrl) {
    // TODO: identique sendFile pour un PDF de catalogue. Pour les
    //       catalogues natifs Meta (produits depuis le Catalog Manager),
    //       utiliser type "interactive" + product_list.
    throw UnimplementedError(_err);
  }

  @override
  Future<bool> share(String message) {
    // Pas de notion de "partage sans destinataire" côté API serveur :
    // chaque envoi nécessite un numéro cible.
    throw UnimplementedError(_err);
  }
}
