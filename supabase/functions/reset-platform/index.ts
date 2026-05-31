// ═══════════════════════════════════════════════════════════════════════════
// Edge Function : reset-platform
//
// Supprime des comptes auth.users en utilisant la service_role_key (seule clé
// capable de faire du auth.admin.deleteUser).
//
// Le RPC SQL (reset_all_data / delete_user_account) ne peut pas toujours
// supprimer auth.users sur Supabase Cloud (privilèges insuffisants — le rôle
// postgres n'a pas DELETE sur auth.users). Cette Edge Function sert de fallback
// garanti.
//
// Contrat — deux modes :
//   1. { mode: "auth-cleanup" }
//        → supprime TOUS les auth.users SAUF les super admins.
//        Auth   : super_admin dans profiles.
//   2. { mode: "delete-user", user_id: "<uuid>" }
//        → supprime UN seul auth.users.
//        Auth   : super_admin OU l'utilisateur supprimant son propre compte.
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

    // Lire le mode demandé (défaut historique : auth-cleanup global)
    let body: { mode?: string; user_id?: string } = {};
    try { body = await req.json(); } catch (_) { /* corps vide → défaut */ }
    const mode = body.mode ?? 'auth-cleanup';

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE, {
      auth: { persistSession: false },
    });

    // Profil de l'appelant (pour les contrôles d'autorisation)
    const { data: callerProfile } = await admin
      .from('profiles')
      .select('is_super_admin')
      .eq('id', callerId)
      .maybeSingle();
    const callerIsSuperAdmin = callerProfile?.is_super_admin === true;

    // ── Mode 2 : suppression d'un seul utilisateur ──────────────────────────
    if (mode === 'delete-user') {
      const targetId = body.user_id;
      if (!targetId) return json({ error: 'missing_user_id' }, 400);

      // Autorisé si super admin OU suppression de son propre compte.
      if (!callerIsSuperAdmin && callerId !== targetId) {
        return json({ error: 'not_authorized' }, 403);
      }

      const { error: delErr } = await admin.auth.admin.deleteUser(targetId);
      if (delErr) {
        // "user not found" = déjà supprimé → succès idempotent.
        const notFound = /not.?found/i.test(delErr.message);
        if (notFound) return json({ deleted_auth_users: 0, errors: [] });
        return json({ deleted_auth_users: 0, errors: [delErr.message] }, 500);
      }
      return json({ deleted_auth_users: 1, errors: [] });
    }

    // ── Mode 1 : nettoyage global (réservé super admin) ─────────────────────
    if (!callerIsSuperAdmin) {
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
