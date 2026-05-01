import 'package:intl/intl.dart';
import '../../features/inventaire/domain/entities/product.dart';
import '../../features/shop_selector/domain/entities/shop_summary.dart';

// ═════════════════════════════════════════════════════════════════════════════
// CatalogueHtmlBuilder — génère une page HTML statique légère qui présente
// une sélection de produits sous forme de catalogue partageable.
//
// Caractéristiques :
//   • Page autonome : tout le CSS est inline, aucune dépendance externe
//     hors les images des produits (URLs publiques Supabase product-images)
//   • Fond blanc, layout responsive, system fonts (rendu rapide partout)
//   • Header : logo boutique + nom + date · footer : invitation WhatsApp
//   • Badges variantes + badge PROMO optionnel (étape 6)
//   • Tout texte est échappé HTML pour éviter une injection via nom produit
//
// Le builder est *pur* : aucune dépendance Flutter / IO. Il prend des
// entités domain et retourne une `String` HTML — testable trivialement.
// ═════════════════════════════════════════════════════════════════════════════

/// Métadonnées optionnelles pour rendre un catalogue "promotion".
class CataloguePromo {
  /// Titre court de la promo, ex : "Black Friday".
  final String title;
  /// Pourcentage de remise (0–100). Affiché en badge.
  final int discountPercent;
  /// Date d'expiration de la promo (incluse).
  final DateTime? validUntil;
  /// IDs de variantes (ou de produits, fallback) marqués PROMO. Si vide :
  /// tous les produits du catalogue reçoivent le badge.
  final Set<String> highlightProductIds;
  const CataloguePromo({
    required this.title,
    required this.discountPercent,
    this.validUntil,
    this.highlightProductIds = const {},
  });
}

class CatalogueHtmlBuilder {
  /// Construit le HTML d'un catalogue.
  ///
  /// - [products] : liste de produits à afficher (image, nom, prix, stock,
  ///   nb variantes). Si la liste est vide, le HTML reste valide (page
  ///   "aucun produit") — l'appelant doit éviter ce cas en amont.
  /// - [promo]    : si non null → bandeau promo + badges sur les produits
  ///   ciblés (ou tous si highlightProductIds est vide).
  /// - [whatsappContact] : numéro à afficher dans le footer (format libre).
  ///   Si vide, on affiche juste l'invitation textuelle.
  /// - [currency] : devise affichée (défaut XAF).
  static String build({
    required ShopSummary shop,
    required List<Product> products,
    CataloguePromo? promo,
    String? whatsappContact,
    String currency = 'XAF',
    DateTime? generatedAt,
  }) {
    final fmt = NumberFormat('#,###', 'fr_FR');
    final at  = generatedAt ?? DateTime.now();
    final dateStr = _date(at);

    // ─── Métadonnées pour la carte d'aperçu WhatsApp / réseaux ──────────────
    // (Open Graph + Twitter Card). Sans ces balises, WhatsApp prend la
    // première `<img>` du HTML — résultat aléatoire selon les produits.
    final ogTitle = promo == null
        ? '${shop.name} — Catalogue'
        : '${shop.name} — Promo ${promo.title}';
    final ogDesc = promo == null
        ? '${products.length} produit${products.length > 1 ? 's' : ''} '
            'disponible${products.length > 1 ? 's' : ''} · $dateStr'
        : 'Jusqu\'à -${promo.discountPercent}% sur ${products.length} '
            'produit${products.length > 1 ? 's' : ''}';
    // og:image — priorité au logo boutique, sinon 1ʳᵉ image produit dispo.
    String? ogImage = (shop.logoUrl ?? '').isNotEmpty ? shop.logoUrl : null;
    if (ogImage == null) {
      for (final p in products) {
        final img = p.mainImageUrl;
        if (img != null && img.isNotEmpty) { ogImage = img; break; }
      }
    }

    final buf = StringBuffer();
    buf.writeln('<!DOCTYPE html>');
    buf.writeln('<html lang="fr">');
    buf.writeln('<head>');
    buf.writeln('<meta charset="utf-8">');
    buf.writeln('<meta name="viewport" '
        'content="width=device-width,initial-scale=1">');
    buf.writeln('<title>${_esc(ogTitle)}</title>');
    buf.writeln('<meta name="description" content="${_esc(ogDesc)}">');
    // Open Graph
    buf.writeln('<meta property="og:type" content="website">');
    buf.writeln('<meta property="og:title" content="${_esc(ogTitle)}">');
    buf.writeln('<meta property="og:description" '
        'content="${_esc(ogDesc)}">');
    if (ogImage != null) {
      buf.writeln('<meta property="og:image" content="${_esc(ogImage)}">');
    }
    buf.writeln('<meta property="og:site_name" '
        'content="${_esc(shop.name)}">');
    // Twitter Card (utilisée par certains agrégateurs / LinkedIn aussi)
    buf.writeln('<meta name="twitter:card" content="summary_large_image">');
    buf.writeln('<meta name="twitter:title" content="${_esc(ogTitle)}">');
    buf.writeln('<meta name="twitter:description" '
        'content="${_esc(ogDesc)}">');
    if (ogImage != null) {
      buf.writeln('<meta name="twitter:image" content="${_esc(ogImage)}">');
    }
    buf.writeln('<style>${_css()}</style>');
    buf.writeln('</head>');
    buf.writeln('<body>');

    // ─── Header ───────────────────────────────────────────────────────────
    buf.writeln('<header class="hdr">');
    if ((shop.logoUrl ?? '').isNotEmpty) {
      buf.writeln('<img class="logo" src="${_esc(shop.logoUrl!)}" alt="logo">');
    } else {
      buf.writeln('<div class="logo logo-fallback">'
          '${_esc(_initials(shop.name))}</div>');
    }
    buf.writeln('<div class="hdr-text">');
    buf.writeln('<h1>${_esc(shop.name)}</h1>');
    buf.writeln('<p class="date">$dateStr</p>');
    buf.writeln('</div>');
    buf.writeln('</header>');

    // ─── Bandeau promo (étape 6) ──────────────────────────────────────────
    if (promo != null) {
      final until = promo.validUntil == null
          ? ''
          : ' · valable jusqu\'au ${_date(promo.validUntil!)}';
      buf.writeln('<section class="promo-banner">');
      buf.writeln('<span class="promo-badge">PROMO</span>');
      buf.writeln('<span class="promo-title">'
          '${_esc(promo.title)}</span>');
      buf.writeln('<span class="promo-discount">'
          '-${promo.discountPercent}%</span>');
      if (until.isNotEmpty) {
        buf.writeln('<span class="promo-until">${_esc(until)}</span>');
      }
      buf.writeln('</section>');
    }

    // ─── Liste produits ───────────────────────────────────────────────────
    buf.writeln('<main class="grid">');
    if (products.isEmpty) {
      buf.writeln('<p class="empty">Aucun produit dans ce catalogue.</p>');
    } else {
      for (final p in products) {
        buf.write(_productCard(p, fmt: fmt, currency: currency,
            promo: promo));
      }
    }
    buf.writeln('</main>');

    // ─── Footer ───────────────────────────────────────────────────────────
    buf.writeln('<footer class="ftr">');
    buf.writeln('<p>Pour commander, contactez-nous sur WhatsApp.</p>');
    if ((whatsappContact ?? '').isNotEmpty) {
      buf.writeln('<p class="contact">${_esc(whatsappContact!)}</p>');
    }
    buf.writeln('</footer>');
    buf.writeln('</body></html>');
    return _toAsciiSafe(buf.toString());
  }

  /// Convertit tous les caractères non-ASCII en entités numériques HTML
  /// (`&#NNN;`). Évite les problèmes d'affichage quand le serveur ne
  /// renvoie pas un `Content-Type: text/html; charset=utf-8` complet —
  /// cas observé sur certaines configurations Supabase Storage. Les
  /// entités sont toujours rendues correctement, indépendamment du
  /// charset HTTP. Le CSS inline étant pur ASCII, aucun risque de
  /// casser le rendu.
  static String _toAsciiSafe(String html) {
    final out = StringBuffer();
    for (final r in html.runes) {
      if (r < 128) {
        out.writeCharCode(r);
      } else {
        out.write('&#$r;');
      }
    }
    return out.toString();
  }

  // ── Carte produit ───────────────────────────────────────────────────────

  static String _productCard(Product p, {
    required NumberFormat fmt,
    required String currency,
    CataloguePromo? promo,
  }) {
    final name = _esc(p.name);
    final stock = p.totalStock;
    final main = p.variants.where((v) => v.isMain).firstOrNull
        ?? (p.variants.isNotEmpty ? p.variants.first : null);
    final priceVal = main?.priceSellPos ?? p.priceSellPos;
    final price = '${fmt.format(priceVal)} $currency';
    final img = p.mainImageUrl;
    final variants = p.variants.length;

    final isPromo = promo != null && (
        promo.highlightProductIds.isEmpty
        || (p.id != null && promo.highlightProductIds.contains(p.id))
        || p.variants.any((v) =>
            v.id != null && promo.highlightProductIds.contains(v.id)));

    final buf = StringBuffer();
    buf.writeln('<article class="card">');
    if (img != null && img.isNotEmpty) {
      buf.writeln('<div class="img-wrap">');
      buf.writeln('<img class="img" src="${_esc(img)}" alt="${_esc(name)}" '
          'loading="lazy">');
      if (isPromo) {
        buf.writeln('<span class="card-promo">PROMO</span>');
      }
      buf.writeln('</div>');
    } else {
      buf.writeln('<div class="img-wrap img-fallback">');
      buf.writeln('<span>${_esc(_initials(p.name))}</span>');
      if (isPromo) {
        buf.writeln('<span class="card-promo">PROMO</span>');
      }
      buf.writeln('</div>');
    }
    buf.writeln('<div class="info">');
    buf.writeln('<h3 class="name">$name</h3>');
    buf.writeln('<p class="price">$price</p>');
    buf.writeln('<p class="meta">');
    buf.writeln('<span class="stock '
        '${stock <= 0 ? "stock-out" : "stock-ok"}">'
        'Stock : $stock</span>');
    if (variants > 1) {
      buf.writeln('<span class="badge">$variants variantes</span>');
    }
    buf.writeln('</p>');
    buf.writeln('</div>');
    buf.writeln('</article>');
    return buf.toString();
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  /// Échappe les caractères HTML dangereux. Évite les XSS via nom produit.
  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    final first = parts.first[0].toUpperCase();
    final second = parts.length > 1 && parts[1].isNotEmpty
        ? parts[1][0].toUpperCase()
        : '';
    return '$first$second';
  }

  // ── CSS inline ──────────────────────────────────────────────────────────

  static String _css() => '''
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,
  "Helvetica Neue",Arial,sans-serif;background:#fff;color:#0f172a;
  line-height:1.4}
.hdr{display:flex;align-items:center;gap:14px;padding:18px 20px;
  border-bottom:1px solid #e5e7eb}
.logo{width:56px;height:56px;border-radius:12px;object-fit:cover;
  background:#f3f4f6}
.logo-fallback{display:flex;align-items:center;justify-content:center;
  font-weight:800;font-size:18px;color:#6c3fc7;background:#ede9fe}
.hdr-text h1{font-size:18px;font-weight:800;letter-spacing:-.01em}
.date{font-size:12px;color:#6b7280;margin-top:2px}
.promo-banner{display:flex;flex-wrap:wrap;align-items:center;gap:10px;
  padding:14px 20px;background:linear-gradient(90deg,#fef3c7,#fde68a);
  border-bottom:1px solid #fcd34d}
.promo-badge{background:#dc2626;color:#fff;font-weight:800;font-size:11px;
  padding:4px 8px;border-radius:6px;letter-spacing:.04em}
.promo-title{font-weight:700;font-size:14px}
.promo-discount{font-weight:800;font-size:18px;color:#b91c1c}
.promo-until{font-size:11px;color:#92400e}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));
  gap:14px;padding:20px}
.card{background:#fff;border:1px solid #e5e7eb;border-radius:12px;
  overflow:hidden;display:flex;flex-direction:column}
.img-wrap{position:relative;aspect-ratio:1;background:#f9fafb;
  display:flex;align-items:center;justify-content:center;overflow:hidden}
.img{width:100%;height:100%;object-fit:cover;display:block}
.img-fallback{font-weight:800;font-size:32px;color:#9ca3af}
.card-promo{position:absolute;top:8px;left:8px;background:#dc2626;
  color:#fff;font-weight:800;font-size:10px;padding:3px 7px;border-radius:4px;
  letter-spacing:.04em}
.info{padding:10px 12px}
.name{font-size:13px;font-weight:700;color:#0f172a;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;
  overflow:hidden;line-height:1.3;min-height:34px}
.price{font-size:14px;font-weight:800;color:#6c3fc7;margin-top:6px}
.meta{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
.stock{font-size:10px;font-weight:600;padding:3px 6px;border-radius:4px}
.stock-ok{background:#ecfdf5;color:#065f46}
.stock-out{background:#fef2f2;color:#991b1b}
.badge{font-size:10px;font-weight:600;padding:3px 6px;border-radius:4px;
  background:#eef2ff;color:#4338ca}
.empty{padding:40px 20px;text-align:center;color:#9ca3af;font-size:13px}
.ftr{padding:18px 20px;border-top:1px solid #e5e7eb;text-align:center}
.ftr p{font-size:12px;color:#6b7280}
.contact{margin-top:4px;font-weight:700;color:#0f172a}
@media(max-width:480px){
  .hdr{padding:14px}
  .grid{grid-template-columns:repeat(auto-fill,minmax(140px,1fr));
    gap:10px;padding:14px}
  .info{padding:8px 10px}
  .name{font-size:12px;min-height:30px}
  .price{font-size:13px}
}
''';
}
