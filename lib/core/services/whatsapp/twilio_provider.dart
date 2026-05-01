import '../whatsapp_service.dart' show IWhatsappProvider;

// ═════════════════════════════════════════════════════════════════════════════
// TwilioProvider — implémentation IWhatsappProvider via l'API Twilio
// WhatsApp Business.
//
// **NON IMPLÉMENTÉ** — toutes les méthodes lèvent `UnimplementedError`.
// Activer ce provider quand un compte Twilio sera provisionné et que la
// config sera disponible.
//
// Paramètres prévus (à stocker dans la table Supabase
// `shop_whatsapp_config` à créer plus tard) :
//   • account_sid       : identifiant compte Twilio
//   • auth_token        : token d'authentification API
//   • whatsapp_number   : numéro WhatsApp Twilio sandbox ou production
//                         (format `whatsapp:+14155238886` côté Twilio)
//
// Endpoint Twilio :
//   POST https://api.twilio.com/2010-04-01/Accounts/{sid}/Messages.json
//   Auth Basic (sid:token)
//   Body  : From=whatsapp:<number>&To=whatsapp:+<phone>&Body=<message>
//   Pour fichier : MediaUrl=<URL publique>
//
// Activation : changer `WhatsappProviderType` (whatsapp_service.dart) à
// `twilio` côté config Hive — aucune autre modif nécessaire si ce fichier
// est implémenté.
// ═════════════════════════════════════════════════════════════════════════════

class TwilioProvider implements IWhatsappProvider {
  // TODO: injecter accountSid / authToken / whatsappNumber depuis la
  //       table `shop_whatsapp_config` (Supabase) ou un Hive box dédié.
  final String? accountSid;
  final String? authToken;
  final String? whatsappNumber;

  const TwilioProvider({
    this.accountSid,
    this.authToken,
    this.whatsappNumber,
  });

  static const _err = 'TwilioProvider non implémenté — '
      'à brancher quand le compte Twilio WhatsApp Business sera actif. '
      'Voir lib/core/services/whatsapp/twilio_provider.dart pour les TODO.';

  @override
  Future<bool> sendMessage(String phone, String message) {
    // TODO: POST Messages.json avec Body=<message>, To=whatsapp:+<phone>,
    //       From=whatsapp:<whatsappNumber>. Auth Basic (sid:token).
    throw UnimplementedError(_err);
  }

  @override
  Future<bool> sendFile(String phone, String message, String fileUrl) {
    // TODO: même que sendMessage + MediaUrl=<fileUrl>. Twilio supporte
    //       jusqu'à 5 MB par fichier en sandbox, plus en production.
    throw UnimplementedError(_err);
  }

  @override
  Future<bool> sendCatalogue(
      String phone, String message, String catalogueUrl) {
    // TODO: identique à sendFile — Twilio ne distingue pas un catalogue
    //       d'un fichier joint au niveau API.
    throw UnimplementedError(_err);
  }

  @override
  Future<bool> share(String message) {
    // Pas de notion de "partage sans destinataire" côté serveur Twilio :
    // chaque envoi nécessite un numéro cible. À gérer côté UI (rejeter
    // l'action si le provider actif est Twilio).
    throw UnimplementedError(_err);
  }
}
