import 'package:intl/intl.dart';
import '../../../features/inventaire/domain/entities/product.dart';
import '../../utils/currency_formatter.dart';

// ═════════════════════════════════════════════════════════════════════════════
// WhatsApp message templates — format ultra-court : `<libellé> : <url>`.
//
// Tous les messages WhatsApp (facture, relance commande, catalogue, marketing,
// promotion) suivent ce même format. Le libellé est éditable dans la page
// Paramètres > Modèles WhatsApp (ShopSettingsStore : clés `wa_label_*`).
// Les défauts sont définis dans [WaTemplateDefaults].
//
// Le format court a été choisi pour 3 raisons :
//   • prévisualisation WhatsApp : avec moins de texte, l'aperçu du lien
//     (image / titre / hostname) s'affiche correctement
//   • lisibilité mobile : le client voit l'action attendue en 1 ligne
//   • personnalisation : l'utilisateur écrit son propre call-to-action
// ═════════════════════════════════════════════════════════════════════════════

/// Libellés par défaut pour chaque type de message WhatsApp. Utilisés par
/// la page de paramètres comme valeur initiale, et par le code en fallback
/// quand l'utilisateur n'a rien renseigné.
class WaTemplateDefaults {
  static const String invoice   = 'Téléchargez votre facture';
  static const String order     = 'Voir la commande';
  static const String catalogue = 'Consultez le catalogue';
  static const String news      = 'Nouveautés';
  static const String promo     = 'Voir les produits';
}

/// Clés de persistance dans `ShopSettingsStore`. Centralisées ici pour
/// éviter les chaînes magiques dispersées.
class WaTemplateKeys {
  static const String invoice   = 'wa_label_invoice';
  static const String order     = 'wa_label_order';
  static const String catalogue = 'wa_label_catalogue';
  static const String news      = 'wa_label_news';
  static const String promo     = 'wa_label_promo';
}

class MessageTemplates {
  /// Construit un message WhatsApp court de la forme `<label> : <url>`.
  /// Si [label] est vide après trim, utilise [defaultLabel] en fallback.
  static String buildShareMessage({
    required String url,
    required String label,
    required String defaultLabel,
  }) {
    final cleaned = label.trim().isEmpty ? defaultLabel : label.trim();
    return '$cleaned : $url';
  }

  /// Message wa.me pour partager un produit (ou une variante donnée).
  /// Le format est conçu pour que WhatsApp affiche automatiquement un
  /// aperçu de l'image quand `imageUrl` est en première ligne.
  ///
  /// - [variant] : si renseignée, le titre devient "Produit — Variante" et
  ///   le prix/stock viennent de la variante. Sinon : prix de la variante
  ///   principale (ou produit), stock = stock total.
  /// - [stockOverride] : si fourni, remplace le stock affiché (variante ou
  ///   total). Permet au caller de passer le stock filtré par la vue
  ///   active (Boutique seule / Partenaire X) au lieu du cumul global.
  /// - Si l'image est absente, la première ligne `📸 …` est omise pour
  ///   ne pas envoyer un emoji orphelin sans aperçu.
  static String buildProductShareMessage({
    required Product product,
    ProductVariant? variant,
    String? currency,
    int? stockOverride,
  }) {
    currency ??= CurrencyFormatter.currentSymbol;
    final fmt = NumberFormat('#,###', 'fr_FR');
    final imageUrl = variant?.imageUrl?.isNotEmpty == true
        ? variant!.imageUrl
        : product.mainImageUrl;
    final title = variant != null
        ? '${product.name} — ${variant.name}'
        : product.name;
    final mainVariant = product.featuredVariant()
        ?? (product.variants.isNotEmpty ? product.variants.first : null);
    final price = variant?.priceSellPos
        ?? mainVariant?.priceSellPos
        ?? product.priceSellPos;
    final stock =
        stockOverride ?? variant?.stockAvailable ?? product.totalStock;

    final lines = <String>[];
    if (imageUrl != null && imageUrl.isNotEmpty) {
      lines.add('📸 $imageUrl');
    }
    lines.add('🏷️ $title');
    lines.add('💰 Prix : ${fmt.format(price)} $currency');
    lines.add('📦 Stock : $stock unité${stock > 1 ? 's' : ''} disponible'
        '${stock > 1 ? 's' : ''}');
    return lines.join('\n');
  }
}
