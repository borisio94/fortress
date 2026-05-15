// ═══════════════════════════════════════════════════════════════════════════
// Edge Function : share-preview
//
// Génère une preview HTML personnalisée pour les crawlers WhatsApp/Facebook/
// etc., et redirige les vrais navigateurs vers l'URL cible.
//
// Flow :
//   • L'app Flutter crée un share_link en base avec :
//       - token (8 chars)
//       - kind  (invoice / order_reminder / catalogue / ...)
//       - target_url (URL signée Supabase Storage du PDF)
//       - label, description, image_url
//   • Le message WhatsApp envoyé contient :
//       https://<projet>.supabase.co/functions/v1/share-preview/<token>
//   • WhatsApp fetch cette URL → on détecte le bot via User-Agent → on
//     renvoie un HTML avec <meta property="og:title"> = label, etc.
//     WhatsApp affiche une carte preview riche.
//   • Vrai user clique sur la carte → on renvoie 302 redirect vers
//     target_url (PDF) → téléchargement immédiat.
//
// Déploiement :
//   supabase functions deploy share-preview --no-verify-jwt
//   (--no-verify-jwt indispensable, sinon les crawlers ne peuvent pas appeler)
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';

const SUPABASE_URL  = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const BOT_UA_REGEX =
  /whatsapp|facebookexternalhit|facebot|twitterbot|telegrambot|linkedinbot|slackbot|discordbot|skypeuripreview|pinterest|googlebot|bingbot|applebot|embedly|preview/i;

function escapeHtml(s: string | null | undefined): string {
  if (!s) return '';
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function renderPreviewHtml(opts: {
  label: string;
  description?: string | null;
  imageUrl?: string | null;
  pageUrl: string;
  targetUrl: string;
}): string {
  const title       = escapeHtml(opts.label);
  const description = escapeHtml(opts.description || 'Cliquez pour ouvrir');
  const imageUrl    = opts.imageUrl ? escapeHtml(opts.imageUrl) : '';
  const pageUrl     = escapeHtml(opts.pageUrl);
  const targetUrl   = escapeHtml(opts.targetUrl);
  return `<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>${title}</title>
  <meta property="og:title" content="${title}">
  <meta property="og:description" content="${description}">
  ${imageUrl ? `<meta property="og:image" content="${imageUrl}">` : ''}
  <meta property="og:url" content="${pageUrl}">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="Fortress POS">
  <meta name="twitter:card" content="${imageUrl ? 'summary_large_image' : 'summary'}">
  <meta name="twitter:title" content="${title}">
  <meta name="twitter:description" content="${description}">
  ${imageUrl ? `<meta name="twitter:image" content="${imageUrl}">` : ''}
  <meta http-equiv="refresh" content="0; url=${targetUrl}">
</head>
<body>
  <p>Redirection en cours… <a href="${targetUrl}">Cliquez ici</a> si rien ne se passe.</p>
</body>
</html>`;
}

serve(async (req) => {
  // Extraire le token depuis l'URL : /share-preview/<token>
  const url = new URL(req.url);
  const segments = url.pathname.split('/').filter(Boolean);
  const token = segments[segments.length - 1];
  if (!token || token === 'share-preview') {
    return new Response('Missing token', { status: 400 });
  }

  // Lecture en service_role pour bypass RLS (l'Edge Function est appelée
  // par des crawlers anonymes, pas par un user authentifié).
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await supabase
    .from('share_links')
    .select('*')
    .eq('token', token)
    .maybeSingle();

  if (error) {
    console.error('[share-preview] DB error:', error);
    return new Response('Server error', { status: 500 });
  }
  if (!data) {
    return new Response('Not found', { status: 404 });
  }

  // Expiration
  if (data.expires_at && new Date(data.expires_at) < new Date()) {
    return new Response('Link expired', { status: 410 });
  }

  const ua = (req.headers.get('user-agent') || '').toLowerCase();
  const isBot = BOT_UA_REGEX.test(ua);

  if (isBot) {
    const html = renderPreviewHtml({
      label:       data.label,
      description: data.description,
      imageUrl:    data.image_url,
      pageUrl:     req.url,
      targetUrl:   data.target_url,
    });
    return new Response(html, {
      headers: {
        'Content-Type':  'text/html; charset=utf-8',
        'Cache-Control': 'public, max-age=86400',
      },
    });
  }

  // Vrai user → redirection 302 vers la ressource finale.
  return Response.redirect(data.target_url, 302);
});
