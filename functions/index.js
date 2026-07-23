// ═════════════════════════════════════════════════════════════════════════════
// Cloud Function — Open Graph dynamique du catalogue public (aperçu Facebook).
//
// Pourquoi : le crawler Facebook (et WhatsApp/Twitter) NE LIT PAS le JavaScript.
// Il ne voit que le HTML statique servi. Un SPA Flutter ne peut donc pas
// injecter d'OG « dynamiques » côté client. Cette fonction s'interpose sur
// `/catalogue/<shopId>` (via un rewrite Firebase Hosting), récupère le nom + le
// logo de la boutique depuis Supabase, et renvoie le MÊME shell `index.html`
// avec les balises OG injectées par boutique. Le SPA Flutter boote ensuite
// normalement (base href « / », GoRouter lit le path réel).
//
// Déploiement : voir les instructions fournies (nécessite le plan Blaze).
// ═════════════════════════════════════════════════════════════════════════════

const { onRequest } = require("firebase-functions/v2/https");
const { logger } = require("firebase-functions");

// Credentials PUBLIQUES — identiques à celles embarquées dans le build web
// (clé « publishable »/anon, non secrète). Le RPC get_public_shop_info est
// SECURITY DEFINER + GRANT anon (hotfix_095/122).
const SUPABASE_URL  = "https://hyxvussnlnvbkalqzovb.supabase.co";
const SUPABASE_ANON = "sb_publishable_R7Jg-Tx4WRMkVI5TMC4jpQ_p8NHq4bd";

const SITE_ORIGIN   = "https://fortress-pos.web.app";
const DEFAULT_IMAGE = SITE_ORIGIN + "/icons/Icon-512.png";
const DEFAULT_DESC  =
  "Commandez en ligne · Livraison à domicile · Paiement à la réception";

function esc(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// Récupère { name, logo_url, ... } depuis le RPC public. Null si échec.
async function fetchShop(shopId) {
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_public_shop_info`, {
      method: "POST",
      headers: {
        "apikey": SUPABASE_ANON,
        "Authorization": `Bearer ${SUPABASE_ANON}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_shop_id: shopId }),
    });
    if (!r.ok) return null;
    const data = await r.json();
    return data && typeof data === "object" ? data : null;
  } catch (e) {
    logger.warn("fetchShop failed", { shopId, err: String(e) });
    return null;
  }
}

// Récupère UN produit public (deep-link `?product=`) via le RPC SECURITY
// DEFINER `get_delivery_products` (mêmes données que le catalogue). Renvoie
// la 1ʳᵉ ligne, ou null. Le bypass `is_visible_web` du RPC est OK : un lien
// pub est un consentement explicite d'exposer ce produit.
async function fetchProduct(shopId, productId) {
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_delivery_products`, {
      method: "POST",
      headers: {
        "apikey": SUPABASE_ANON,
        "Authorization": `Bearer ${SUPABASE_ANON}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_shop_id: shopId, p_product_ids: [productId] }),
    });
    if (!r.ok) return null;
    const data = await r.json();
    return Array.isArray(data) && data.length ? data[0] : null;
  } catch (e) {
    logger.warn("fetchProduct failed", { shopId, productId, err: String(e) });
    return null;
  }
}

// Prix d'un produit pour l'OG : prix variante 1 si dispo, sinon price_sell_pos.
function productPrice(p) {
  const v = Array.isArray(p.variants) && p.variants.length ? p.variants[0] : null;
  const raw = (v && v.price_sell_pos != null)
    ? v.price_sell_pos
    : p.price_sell_pos;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : null;
}

// Formatage FCFA léger (séparateur de milliers fr-FR).
function fmtPrice(n) {
  try { return Number(n).toLocaleString("fr-FR"); }
  catch (_) { return String(Math.round(n)); }
}

function truncate(s, max) {
  const t = String(s == null ? "" : s).trim();
  if (t.length <= max) return t;
  return t.slice(0, max - 1).trimEnd() + "…";
}

// Récupère le shell index.html servi par Hosting (statique, hors /catalogue).
async function fetchIndexHtml() {
  const r = await fetch(`${SITE_ORIGIN}/index.html`, {
    headers: { "User-Agent": "fortress-og-function" },
  });
  if (!r.ok) throw new Error("index.html fetch " + r.status);
  return await r.text();
}

function buildOgTags({ title, description, image, url }) {
  return [
    `<meta property="og:type" content="website"/>`,
    `<meta property="og:site_name" content="Fortress"/>`,
    `<meta property="og:title" content="${esc(title)}"/>`,
    `<meta property="og:description" content="${esc(description)}"/>`,
    `<meta property="og:image" content="${esc(image)}"/>`,
    `<meta property="og:url" content="${esc(url)}"/>`,
    `<meta name="twitter:card" content="summary_large_image"/>`,
    `<meta name="twitter:title" content="${esc(title)}"/>`,
    `<meta name="twitter:description" content="${esc(description)}"/>`,
    `<meta name="twitter:image" content="${esc(image)}"/>`,
  ].join("\n  ");
}

exports.catalogueOg = onRequest(
  { region: "us-central1", memory: "256MiB", maxInstances: 10, cors: false },
  async (req, res) => {
    let html;
    try {
      html = await fetchIndexHtml();
    } catch (e) {
      // Impossible de récupérer le shell : repli sur la racine du SPA pour ne
      // jamais laisser une page blanche (cas très rare).
      logger.error("catalogueOg: index fetch failed", { err: String(e) });
      res.redirect(302, SITE_ORIGIN);
      return;
    }

    // /catalogue/<shopId>[/...]
    const m = (req.path || "").match(/^\/catalogue\/([^/?#]+)/);
    const shopId = m ? decodeURIComponent(m[1]) : null;
    // Deep-link pub : ?product=<id> → OG par produit (sinon OG boutique).
    const productId = req.query && req.query.product
      ? String(req.query.product) : null;

    const shop = shopId ? await fetchShop(shopId) : null;
    const product = (shopId && productId)
      ? await fetchProduct(shopId, productId) : null;

    let title, image, description, url;
    if (product && product.name) {
      // ── OG PRODUIT ──
      const price = productPrice(product);
      title = price != null
        ? `${product.name} — ${fmtPrice(price)} FCFA`
        : String(product.name);
      image = product.image_url
        || (shop && shop.logo_url) || DEFAULT_IMAGE;
      description = truncate(product.description, 150) || DEFAULT_DESC;
      url = `${SITE_ORIGIN}/catalogue/${shopId}?product=${encodeURIComponent(productId)}`;
    } else {
      // ── OG BOUTIQUE ──
      title = shop && shop.name
        ? `${shop.name} — Catalogue en ligne`
        : "Fortress — Catalogue en ligne";
      image = shop && shop.logo_url ? shop.logo_url : DEFAULT_IMAGE;
      description = DEFAULT_DESC;
      url = `${SITE_ORIGIN}/catalogue/${shopId || ""}`;
    }

    const og = buildOgTags({ title, description, image, url });

    const out = html
      .replace(/<title>.*?<\/title>/i, `<title>${esc(title)}</title>`)
      .replace(/<\/head>/i, `  ${og}\n</head>`);

    res.set("Content-Type", "text/html; charset=utf-8");
    // Cache CDN court : propage vite un changement de logo/nom tout en évitant
    // de réinvoquer la fonction à chaque hit.
    res.set("Cache-Control", "public, max-age=300, s-maxage=300");
    res.status(200).send(out);
  }
);
