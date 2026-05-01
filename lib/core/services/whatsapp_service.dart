import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../storage/hive_boxes.dart';
import 'whatsapp/meta_direct_provider.dart';
import 'whatsapp/twilio_provider.dart';

// ═════════════════════════════════════════════════════════════════════════════
// WhatsappService — couche d'abstraction extensible pour l'envoi de messages
// WhatsApp depuis Fortress.
//
// Aujourd'hui le seul provider actif est `WameProvider` (URL https://wa.me/…
// + url_launcher → ouverture native de l'app WhatsApp côté utilisateur).
//
// Deux autres providers sont prévus dans :
//   • lib/core/services/whatsapp/twilio_provider.dart       (stub)
//   • lib/core/services/whatsapp/meta_direct_provider.dart  (stub)
//
// Le provider actif est lu depuis Hive (clé `whatsapp_provider` dans le
// `settingsBox`). Pour basculer sur Twilio/Meta plus tard : implémenter le
// provider correspondant + écrire la valeur dans Hive — aucun caller à
// modifier.
// ═════════════════════════════════════════════════════════════════════════════

/// Identifiant persistant du provider WhatsApp actif.
enum WhatsappProviderType { wame, twilio, metaDirect }

extension WhatsappProviderTypeX on WhatsappProviderType {
  /// Identifiant persistant en Hive.
  String get key => switch (this) {
    WhatsappProviderType.wame       => 'wame',
    WhatsappProviderType.twilio     => 'twilio',
    WhatsappProviderType.metaDirect => 'meta_direct',
  };

  static WhatsappProviderType fromKey(String? k) => switch (k) {
    'twilio'      => WhatsappProviderType.twilio,
    'meta_direct' => WhatsappProviderType.metaDirect,
    _             => WhatsappProviderType.wame,
  };
}

/// Contrat commun à tous les providers WhatsApp.
abstract class IWhatsappProvider {
  /// Envoie (ou pré-remplit) un message texte vers [phone].
  /// Retourne `true` si l'envoi (ou l'ouverture du chat) a réussi.
  Future<bool> sendMessage(String phone, String message);

  /// Envoie un message accompagné d'un fichier.
  /// [fileUrl] doit être une URL publique (ou signed URL) que le destinataire
  /// peut ouvrir directement.
  Future<bool> sendFile(String phone, String message, String fileUrl);

  /// Envoie un message accompagné d'un lien catalogue.
  /// Sémantiquement équivalent à [sendFile], mais ce slot existe pour qu'un
  /// futur provider serveur puisse formater différemment (template Meta).
  Future<bool> sendCatalogue(
      String phone, String message, String catalogueUrl);

  /// Diffuse un message sans destinataire imposé : WhatsApp ouvre le picker
  /// de contact côté utilisateur (utile pour partager un produit ou un
  /// catalogue). Pas pertinent pour les providers serveur (Twilio/Meta).
  Future<bool> share(String message);
}

// ─── WameProvider (actif) ────────────────────────────────────────────────────

/// Provider basé sur l'URL `https://wa.me/<phone>?text=<msg>` ouverte par
/// `url_launcher`. Aucune clé API, aucune approbation Meta nécessaire :
/// l'utilisateur final tape "Envoyer" dans son app WhatsApp.
///
/// Limites :
///   • Pas d'upload de fichier — `sendFile`/`sendCatalogue` injectent le lien
///     dans le corps du message. Le destinataire le tape pour ouvrir.
///   • L'envoi n'est pas réellement automatique côté utilisateur.
class WameProvider implements IWhatsappProvider {
  const WameProvider();

  /// Garde uniquement les chiffres — wa.me refuse les `+`, espaces, tirets.
  String _normalize(String phone) => phone.replaceAll(RegExp(r'[^\d]'), '');

  Future<bool> _open(String phone, String message) async {
    final p = _normalize(phone);
    if (p.isEmpty) return false;
    final uri = Uri.parse(
        'https://wa.me/$p?text=${Uri.encodeComponent(message)}');
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> sendMessage(String phone, String message) =>
      _open(phone, message);

  /// Compose [message] avec [fileUrl] :
  /// - Si [message] contient le placeholder `{file}`, il est remplacé par
  ///   l'URL → le caller contrôle exactement où le lien apparaît.
  /// - Sinon, l'URL est ajoutée à la fin (compat ascendant).
  ///
  /// wa.me ne supporte pas l'upload de pièce jointe : on injecte le lien
  /// dans le corps du message, le destinataire tape dessus pour ouvrir.
  String _compose(String message, String url) =>
      message.contains('{file}')
          ? message.replaceAll('{file}', url)
          : '$message\n\n$url';

  @override
  Future<bool> sendFile(String phone, String message, String fileUrl) =>
      _open(phone, _compose(message, fileUrl));

  @override
  Future<bool> sendCatalogue(
          String phone, String message, String catalogueUrl) =>
      _open(phone, _compose(message, catalogueUrl));

  /// Ouvre wa.me **sans numéro** : WhatsApp affiche le picker de contact à
  /// l'utilisateur, qui choisit où envoyer le message pré-rempli.
  @override
  Future<bool> share(String message) async {
    final uri = Uri.parse(
        'https://wa.me/?text=${Uri.encodeComponent(message)}');
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}

// Stubs `TwilioProvider` et `MetaDirectProvider` extraits dans :
//   lib/core/services/whatsapp/twilio_provider.dart
//   lib/core/services/whatsapp/meta_direct_provider.dart
// Importés en haut de ce fichier — restent enregistrés via le switch de
// `whatsappProviderProvider` ci-dessous.

// ─── Façade ──────────────────────────────────────────────────────────────────

/// Façade utilisée par le reste de l'app : reçoit un [IWhatsappProvider]
/// par injection, expose la même API. Ça permet aux callers d'ignorer
/// totalement quel canal est actif.
class WhatsappService {
  final IWhatsappProvider provider;
  const WhatsappService({required this.provider});

  Future<bool> sendMessage(String phone, String message) =>
      provider.sendMessage(phone, message);

  Future<bool> sendFile(String phone, String message, String fileUrl) =>
      provider.sendFile(phone, message, fileUrl);

  Future<bool> sendCatalogue(
          String phone, String message, String catalogueUrl) =>
      provider.sendCatalogue(phone, message, catalogueUrl);

  Future<bool> share(String message) => provider.share(message);
}

// ─── Riverpod ────────────────────────────────────────────────────────────────

/// Provider du `IWhatsappProvider` actif. Le type est lu depuis Hive
/// (`settingsBox['whatsapp_provider']`), défaut = `wame`. Pour basculer :
/// `HiveBoxes.settingsBox.put('whatsapp_provider', 'twilio')`.
///
/// Override possible dans les tests ou pour forcer un provider en debug.
final whatsappProviderProvider = Provider<IWhatsappProvider>((_) {
  final raw = HiveBoxes.settingsBox.get('whatsapp_provider') as String?;
  final type = WhatsappProviderTypeX.fromKey(raw);
  switch (type) {
    case WhatsappProviderType.twilio:
      debugPrint('[WhatsappService] Provider actif : Twilio (stub)');
      return const TwilioProvider();
    case WhatsappProviderType.metaDirect:
      debugPrint('[WhatsappService] Provider actif : Meta Direct (stub)');
      return const MetaDirectProvider();
    case WhatsappProviderType.wame:
      return const WameProvider();
  }
});

/// Façade prête à l'emploi — la majorité des callers consomment ceci.
final whatsappServiceProvider = Provider<WhatsappService>((ref) {
  return WhatsappService(provider: ref.watch(whatsappProviderProvider));
});
