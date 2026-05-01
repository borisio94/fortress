import 'package:intl/intl.dart';
import '../../../features/caisse/domain/entities/sale.dart';
import '../../../features/inventaire/domain/entities/product.dart';
import '../../../features/shop_selector/domain/entities/shop_summary.dart';

// ═════════════════════════════════════════════════════════════════════════════
// WhatsApp message templates — utilisés pour formater le message envoyé au
// client lors de l'envoi d'une facture (wa.me).
//
// 3 styles disponibles :
//   • standard : version équilibrée, illustrée, lisible (par défaut)
//   • short    : ultra-condensé pour les achats rapides
//   • premium  : présentation soignée + invitation à noter l'achat
//
// `buildMessage()` retourne le **texte brut prêt à être encodé** par
// `Uri.encodeComponent` côté caller (WameProvider). Aucun encoding ici —
// ça reste un simple générateur de chaîne lisible.
// ═════════════════════════════════════════════════════════════════════════════

enum WhatsappMessageStyle { standard, short, premium }

extension WhatsappMessageStyleX on WhatsappMessageStyle {
  /// Identifiant persistant en Hive.
  String get key => switch (this) {
    WhatsappMessageStyle.standard => 'standard',
    WhatsappMessageStyle.short    => 'short',
    WhatsappMessageStyle.premium  => 'premium',
  };

  static WhatsappMessageStyle fromKey(String? k) => switch (k) {
    'short'   => WhatsappMessageStyle.short,
    'premium' => WhatsappMessageStyle.premium,
    _         => WhatsappMessageStyle.standard,
  };
}

class MessageTemplates {
  /// Construit le message WhatsApp à partir de la commande, des coordonnées
  /// boutique et de l'URL (déjà raccourcie) de la facture.
  ///
  /// - [order]        : la vente (montant, items, paiement, dates).
  /// - [shop]         : la boutique (nom, etc.). Optionnel — fallback "votre boutique".
  /// - [shortUrl]     : URL courte de la facture (TinyURL ou URL longue de
  ///                    fallback). Présente toujours.
  /// - [ratingUrl]    : URL de notation (Premium uniquement) — si null le
  ///                    champ est OMIS, pas remplacé par une chaîne vide.
  /// - [style]        : style à utiliser (standard / short / premium).
  /// - [currency]     : devise affichée à côté du montant (défaut XAF).
  static String buildMessage({
    required Sale order,
    required String shortUrl,
    ShopSummary? shop,
    String? ratingUrl,
    WhatsappMessageStyle style = WhatsappMessageStyle.standard,
    String currency = 'XAF',
  }) {
    final firstName = _firstName(order.clientName);
    final shopName  = shop?.name ?? 'votre boutique';
    final invoiceNo = order.id ?? 'N/A';
    final productLine = _productLine(order);
    final fmt = NumberFormat('#,###', 'fr_FR');
    final amount = '${fmt.format(order.total)} $currency';
    final date = _date(order.createdAt);
    final time = _time(order.createdAt);
    final paymentLabel = _paymentLabel(order.paymentMethod);

    switch (style) {
      case WhatsappMessageStyle.short:
        return _short(firstName, amount, shortUrl);

      case WhatsappMessageStyle.premium:
        return _premium(
          firstName: firstName,
          shopName:  shopName,
          productLine: productLine,
          amount:    amount,
          date:      date,
          time:      time,
          shortUrl:  shortUrl,
          ratingUrl: ratingUrl,
        );

      case WhatsappMessageStyle.standard:
        return _standard(
          firstName:    firstName,
          shopName:     shopName,
          invoiceNo:    invoiceNo,
          productLine:  productLine,
          amount:       amount,
          date:         date,
          paymentLabel: paymentLabel,
          shortUrl:     shortUrl,
        );
    }
  }

  /// Aperçu textuel du message — utilisé par la page paramètres pour
  /// montrer ce que le client va recevoir. Construit le texte sur des
  /// données fictives sans dépendre des entités réelles (évite les
  /// constructions de Sale / ShopSummary qui requièrent beaucoup de champs).
  static String preview(WhatsappMessageStyle style, {String? shopName}) {
    final firstName = 'Aïcha';
    final shop      = shopName ?? 'Votre boutique';
    final productLine = 'T-shirt × 2 · Casquette × 1';
    final amount    = '24 500 XAF';
    final date      = '26/04/2026';
    final time      = '14h32';
    final url       = 'https://tinyurl.com/fac042';
    switch (style) {
      case WhatsappMessageStyle.short:
        return _short(firstName, amount, url);
      case WhatsappMessageStyle.premium:
        return _premium(
          firstName: firstName, shopName: shop,
          productLine: productLine,
          amount: amount, date: date, time: time, shortUrl: url,
        );
      case WhatsappMessageStyle.standard:
        return _standard(
          firstName: firstName, shopName: shop,
          invoiceNo: 'F-2042', productLine: productLine,
          amount: amount, date: date,
          paymentLabel: 'Espèces', shortUrl: url,
        );
    }
  }

  /// Message wa.me pour partager un produit (ou une variante donnée).
  /// Le format est conçu pour que WhatsApp affiche automatiquement un
  /// aperçu de l'image quand `imageUrl` est en première ligne.
  ///
  /// - [variant] : si renseignée, le titre devient "Produit — Variante" et
  ///   le prix/stock viennent de la variante. Sinon : prix de la variante
  ///   principale (ou produit), stock = stock total.
  /// - Si l'image est absente, la première ligne `📸 …` est omise pour
  ///   ne pas envoyer un emoji orphelin sans aperçu.
  static String buildProductShareMessage({
    required Product product,
    ProductVariant? variant,
    String currency = 'XAF',
  }) {
    final fmt = NumberFormat('#,###', 'fr_FR');
    // Image
    final imageUrl = variant?.imageUrl?.isNotEmpty == true
        ? variant!.imageUrl
        : product.mainImageUrl;
    // Titre
    final title = variant != null
        ? '${product.name} — ${variant.name}'
        : product.name;
    // Prix : variante si fournie, sinon variante principale, sinon produit
    final mainVariant = product.variants.where((v) => v.isMain).firstOrNull
        ?? (product.variants.isNotEmpty ? product.variants.first : null);
    final price = variant?.priceSellPos
        ?? mainVariant?.priceSellPos
        ?? product.priceSellPos;
    // Stock : variante si fournie, sinon total agrégé
    final stock = variant?.stockAvailable ?? product.totalStock;

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

  /// Message wa.me pour partager un catalogue PDF.
  ///
  /// - [coverShortUrl] : URL d'une image PNG (1ʳᵉ page du PDF rasterisée)
  ///   placée en première ligne — c'est elle que WhatsApp utilise pour
  ///   générer l'aperçu visuel dans la conversation. Si null, on n'a pas
  ///   d'aperçu mais le lien PDF reste partageable.
  /// - [pdfShortUrl]   : URL du PDF complet (catalogue paginé). C'est le
  ///   lien sur lequel le client va taper pour télécharger / consulter
  ///   tous les produits.
  static String buildCatalogueShareMessage({
    required String pdfShortUrl,
    String? coverShortUrl,
  }) {
    final lines = <String>[];
    lines.add('Bonjour ! Découvrez nos produits disponibles 🛍️');
    if (coverShortUrl != null && coverShortUrl.isNotEmpty) {
      lines.add(coverShortUrl);
    }
    lines.add('📄 Catalogue complet : $pdfShortUrl');
    lines.add('Répondez pour commander.');
    return lines.join('\n');
  }

  /// Message wa.me pour partager un catalogue **promotionnel** (étape 6).
  /// `validUntil` (date) est omis si null.
  static String buildPromoCatalogueShareMessage({
    required String title,
    required int discountPercent,
    required String shortUrl,
    DateTime? validUntil,
  }) {
    final lines = <String>[];
    lines.add('🔥 PROMOTION — ${title.toUpperCase()}');
    lines.add('Jusqu\'à $discountPercent% de réduction !');
    lines.add(shortUrl);
    if (validUntil != null) {
      final d = '${validUntil.day.toString().padLeft(2, '0')}/'
          '${validUntil.month.toString().padLeft(2, '0')}/${validUntil.year}';
      lines.add('Valable jusqu\'au $d');
    }
    return lines.join('\n');
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

  static String _firstName(String? full) {
    if (full == null || full.trim().isEmpty) return 'cher(e) client(e)';
    return full.trim().split(RegExp(r'\s+')).first;
  }

  static String _productLine(Sale order) {
    final items = order.items;
    if (items.isEmpty) return '— × 0';
    if (items.length <= 3) {
      return items
          .map((i) => '${i.productName} × ${i.quantity}')
          .join(' · ');
    }
    final first = items
        .take(3)
        .map((i) => '${i.productName} × ${i.quantity}')
        .join(' · ');
    final extra = items.length - 3;
    return '$first et $extra autre${extra > 1 ? 's' : ''}';
  }

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  static String _time(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}h'
      '${d.minute.toString().padLeft(2, '0')}';

  static String _paymentLabel(PaymentMethod m) => switch (m) {
    PaymentMethod.cash        => 'Espèces',
    PaymentMethod.mobileMoney => 'Mobile Money',
    PaymentMethod.card        => 'Carte bancaire',
    PaymentMethod.credit      => 'Crédit',
  };

  // ─── Templates ─────────────────────────────────────────────────────────

  static String _standard({
    required String firstName,
    required String shopName,
    required String invoiceNo,
    required String productLine,
    required String amount,
    required String date,
    required String paymentLabel,
    required String shortUrl,
  }) =>
      'Bonjour $firstName 👋\n'
      'Merci pour votre achat chez *$shopName* ! 🛍️\n'
      '\n'
      '🧾 *Facture #$invoiceNo*\n'
      '📦 $productLine\n'
      '💰 Montant : *$amount*\n'
      '📅 Date : $date · 💳 $paymentLabel\n'
      '\n'
      '⬇️ Facture : $shortUrl\n'
      '\n'
      'Bonne journée ! 😊';

  static String _short(String firstName, String amount, String shortUrl) =>
      '✅ Merci $firstName ! Facture : *$amount*\n'
      '⬇️ $shortUrl';

  static String _premium({
    required String firstName,
    required String shopName,
    required String productLine,
    required String amount,
    required String date,
    required String time,
    required String shortUrl,
    String? ratingUrl,
  }) {
    final ratingLine = (ratingUrl == null || ratingUrl.trim().isEmpty)
        ? ''
        : '\n⭐ Notez votre achat : $ratingUrl';
    return 'Bonjour $firstName 👋\n'
        '*$shopName* vous remercie ! 🙏\n'
        '━━━━━━━━━━━━━━━━━━\n'
        '📦 $productLine\n'
        '💰 *$amount* · 📅 $date · $time\n'
        '━━━━━━━━━━━━━━━━━━\n'
        '⬇️ *Facture :* $shortUrl'
        '$ratingLine';
  }
}
