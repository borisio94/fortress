// ═══════════════════════════════════════════════════════════════════════════
// Edge Function : reset-platform
//
// Supprime tous les comptes auth.users SAUF les super admins en utilisant
// la service_role_key (seule clé capable de faire du auth.admin.deleteUser).
//
// Le RPC SQL reset_all_data() ne peut pas toujours supprimer auth.users sur
// Supabase Cloud (privilèges insufficient). Cette Edge Function sert de
// fallback garanti.
//
// Contrat :
//   Input  : { mode: "auth-cleanup" }
//   Auth   : JWT de l'appelant (doit être super_admin dans profiles)
//   Output : { deleted_auth_users: number, errors: string[] }
//
// Déploiement :
//   supabase functions deploy reset-platform --no-verify-jwt=false
//   supabase secrets set SUPABASE_URL=https://<ref>.supabase.co
//   supabase secrets set SUPABASE_SERVICE_ROLE_KEY=<ta-service-role-key>
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY      = Deno.env.get('SUPABASE_ANON_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // 1. Vérifier le JWT de l'appelant
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return json({ error: 'missing_authorization' }, 401);
    }

    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } =
      await userClient.auth.getUser();
    if (userErr || !userData.user) {
      return json({ error: 'invalid_token' }, 401);
    }
    const callerId = userData.user.id;

    // 2. Vérifier que l'appelant est super admin
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE, {
      auth: { persistSession: false },
    });
    const { data: profile, error: profileErr } = await admin
      .from('profiles')
      .select('is_super_admin')
      .eq('id', callerId)
      .maybeSingle();

    if (profileErr || !profile?.is_super_admin) {
      return json({ error: 'not_super_admin' }, 403);
    }

    // 3. Lister les IDs super admin à conserver
    const { data: superAdmins, error: saErr } = await admin
      .from('profiles')
      .select('id')
      .eq('is_super_admin', true);
    if (saErr) return json({ error: 'cannot_list_super_admins' }, 500);
    const keepIds = new Set(
      (superAdmins ?? []).map((r: { id: string }) => r.id),
    );

    // 4. Lister tous les auth.users et supprimer ceux hors keepIds
    const errors: string[] = [];
    let deleted = 0;
    let page = 1;
    const perPage = 200;

    while (true) {
      const { data, error } = await admin.auth.admin.listUsers({
        page,
        perPage,
      });
      if (error) {
        errors.push(`list page ${page}: ${error.message}`);
        break;
      }
      const users = data?.users ?? [];
      if (users.length === 0) break;

      for (const u of users) {
        if (keepIds.has(u.id)) continue;
        const { error: delErr } = await admin.auth.admin.deleteUser(u.id);
        if (delErr) {
          errors.push(`${u.email ?? u.id}: ${delErr.message}`);
        } else {
          deleted++;
        }
      }

      if (users.length < perPage) break;
      page++;
    }

    return json({
      deleted_auth_users: deleted,
      errors,
    });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
