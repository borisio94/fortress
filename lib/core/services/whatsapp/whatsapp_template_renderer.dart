import '../../../features/parametres/domain/entities/whatsapp_template.dart';

// ═════════════════════════════════════════════════════════════════════════════
// WhatsappTemplateRenderer — interpole un template `body` avec des valeurs
// runtime.
//
// Le body contient des placeholders `{{nom_variable}}`. Le renderer fait un
// simple `replace` non-récursif (les valeurs d'entrée ne sont pas réinjectées
// si elles contiennent elles-mêmes des `{{...}}` — comportement attendu :
// pas d'injection de template par les données).
//
// Variables manquantes :
//   • Si une variable n'a pas de valeur dans [context], on remplace par une
//     chaîne vide (pas d'erreur — défensif pour l'envoi).
//   • Le caller peut vérifier `template.body.contains('{{var}}')` avant
//     l'envoi s'il veut faire un check stricte.
// ═════════════════════════════════════════════════════════════════════════════

class WhatsappTemplateRenderer {
  /// Construit le message final à envoyer via wa.me.
  ///
  /// - [template] : le WhatsappTemplate (typiquement le défaut du shop).
  /// - [context]  : map var → valeur. Clés sans `{{}}` (ex: `'client_name'`).
  static String render(
    WhatsappTemplate template,
    Map<String, String?> context,
  ) {
    var out = template.body;
    // Itère sur les variables connues du type pour limiter le scope et
    // éviter de remplacer accidentellement des `{{...}}` parasites laissés
    // dans le texte.
    for (final v in template.type.variables) {
      final value = context[v] ?? '';
      out = out.replaceAll('{{$v}}', value);
    }
    return out;
  }

  /// Aperçu textuel pour la page paramètres — utilise des données fictives
  /// pour montrer le rendu sans dépendre d'un Sale réel.
  static String preview(WhatsappTemplate template) {
    final sample = <String, String>{
      'client_name':    'Aïcha',
      'shop_name':      'Ma boutique',
      'link':           'https://fortress.cm/r/abc123',
      'total':          '24 500 XAF',
      'order_id':       'F-2042',
      'date':           '26/04/2026',
      'delivery_date':  '28/04/2026',
      'product_name':   'Montre élégance',
      'discount':       '30',
    };
    return render(template, sample);
  }
}
