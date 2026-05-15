import 'package:intl/intl.dart';
import '../../../features/inventaire/domain/entities/product.dart';
import '../../utils/currency_formatter.dart';

// ═════════════════════════════════════════════════════════════════════════════
// MessageTemplates — utilitaires de formatage de messages WhatsApp non
// templatables (partage de produit avec aperçu d'image).
//
// Les messages templatables (facture, relance, catalogue, nouveautés, promo)
// sont gérés par le système CRUD `WhatsappTemplate` (cf. hotfix_067) + le
// renderer `WhatsappTemplateRenderer`. Cette classe ne contient plus que les
// helpers qui ne s'inscrivent pas dans le modèle template (partage produit).
// ═════════════════════════════════════════════════════════════════════════════

class MessageTemplates {
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
