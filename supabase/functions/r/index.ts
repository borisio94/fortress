// ═══════════════════════════════════════════════════════════════════════════
// Edge Function : r (redirect)
//
// Raccourcisseur d'URL maison. Résout un slug 6 chars depuis la table
// `short_links` et renvoie une 302 vers la long_url. Incrémente click_count
// en arrière-plan pour les analytics.
//
// URL : https://<projet>.supabase.co/functions/v1/r/<slug>
//
// Déploiement :
//   supabase functions deploy r --no-verify-jwt
//   (--no-verify-jwt indispensable : les clients qui cliquent sur le lien
//   depuis WhatsApp ne portent aucun JWT)
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY')!;

serve(async (req: Request) => {
  const url  = new URL(req.url);
  const slug = url.pathname.split('/').filter(Boolean).pop();
  if (!slug || slug === 'r') {
    return new Response('Lien invalide', { status: 404 });
  }

  // 1. Résoudre slug → long_url (lecture publique via RLS).
  let longUrl: string | null = null;
  try {
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/short_links?slug=eq.${encodeURIComponent(slug)}&select=long_url`,
      {
        headers: {
          apikey:        ANON_KEY,
          Authorization: `Bearer ${ANON_KEY}`,
        },
      },
    );
    if (res.ok) {
      const data = await res.json();
      if (Array.isArray(data) && data.length > 0 && data[0]?.long_url) {
        longUrl = data[0].long_url as string;
      }
    }
  } catch (e) {
    console.error('[r] résolution slug échouée:', e);
  }

  if (!longUrl) {
    return new Response('Lien introuvable ou expiré', { status: 404 });
  }

  // 2. Incrément click_count en background (fire-and-forget, ne bloque pas
  //    la redirection — l'expérience utilisateur prime sur les stats).
  fetch(`${SUPABASE_URL}/rest/v1/rpc/increment_link_click`, {
    method: 'POST',
    headers: {
      apikey:        ANON_KEY,
      Authorization: `Bearer ${ANON_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ link_slug: slug }),
  }).catch(() => {});

  // 3. Redirection 302.
  return new Response(null, {
    status:  302,
    headers: { Location: longUrl },
  });
});
