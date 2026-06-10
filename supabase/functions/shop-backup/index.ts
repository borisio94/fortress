// ═══════════════════════════════════════════════════════════════════════════
// Edge Function : shop-backup
//
// Sauvegarde / restauration APPLICATIVE par boutique (cf. hotfix_102).
// Utilise la service_role pour lire/écrire les données et le bucket privé
// `shop-backups`. Les RPC SQL (export_shop_snapshot / restore_shop_snapshot)
// portent la logique métier ; cette fonction gère l'I/O Storage + l'auth.
//
// Modes (POST JSON) :
//   { mode: "snapshot",     shop_id }   → sauvegarde 1 boutique.
//        Auth : super-admin, membre de la boutique, OU secret cron.
//   { mode: "snapshot-all" }            → sauvegarde toutes les boutiques
//        dont backup_enabled = true.   Auth : secret cron OU super-admin.
//   { mode: "restore",      backup_id } → restaure un snapshot (écrase).
//        Auth : super-admin uniquement.
//   { mode: "download",     backup_id } → URL signée de téléchargement.
//        Auth : super-admin OU membre de la boutique.
//
// Rétention : snapshots > 30 jours supprimés (métadonnée + objet Storage).
//
// Déploiement :
//   supabase functions deploy shop-backup
//   supabase secrets set CRON_SECRET=<chaine-aleatoire-longue>
//   (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY sont
//    injectés automatiquement par Supabase.)
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY')!;
const CRON_SECRET  = Deno.env.get('CRON_SECRET') ?? '';

const BUCKET = 'shop-backups';
const RETENTION_DAYS = 30;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-cron-secret',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE, {
      auth: { persistSession: false },
    });

    let body: { mode?: string; shop_id?: string; backup_id?: string } = {};
    try { body = await req.json(); } catch (_) { /* corps vide */ }
    const mode = body.mode ?? '';

    // ── Authentification de l'appelant ────────────────────────────────────
    const cronHeader = req.headers.get('x-cron-secret') ?? '';
    const isCron = CRON_SECRET.length > 0 && cronHeader === CRON_SECRET;

    let callerId: string | null = null;
    let callerIsSA = false;
    if (!isCron) {
      const authHeader = req.headers.get('Authorization');
      if (!authHeader) return json({ error: 'missing_authorization' }, 401);
      // Valide le JWT de l'appelant en le passant EXPLICITEMENT à getUser :
      // getUser() sans argument lit la session interne (vide ici) et non le
      // header → renvoyait invalid_token. admin.auth.getUser(token) valide le
      // jeton via la service_role.
      const token = authHeader.replace(/^Bearer\s+/i, '');
      const { data: u, error: uErr } = await admin.auth.getUser(token);
      if (uErr || !u.user) return json({ error: 'invalid_token' }, 401);
      callerId = u.user.id;
      const { data: prof } = await admin
        .from('profiles').select('is_super_admin').eq('id', callerId).maybeSingle();
      callerIsSA = prof?.is_super_admin === true;
    }

    const isMember = async (shopId: string): Promise<boolean> => {
      if (!callerId) return false;
      const { data } = await admin
        .from('shop_memberships')
        .select('shop_id')
        .eq('user_id', callerId)
        .eq('shop_id', shopId)
        .maybeSingle();
      return !!data;
    };

    // ── snapshot-all (cron quotidien) ─────────────────────────────────────
    if (mode === 'snapshot-all') {
      if (!isCron && !callerIsSA) return json({ error: 'not_authorized' }, 403);
      const { data: shops, error: sErr } = await admin
        .from('shops').select('id').eq('backup_enabled', true).eq('is_active', true);
      if (sErr) return json({ error: 'cannot_list_shops: ' + sErr.message }, 500);
      const results: unknown[] = [];
      const errors: string[] = [];
      for (const s of shops ?? []) {
        try {
          results.push(await snapshotShop(admin, String(s.id), true, null));
        } catch (e) {
          errors.push(`${s.id}: ${String(e)}`);
          await admin.from('shop_backups').insert({
            shop_id: String(s.id), status: 'failed', is_auto: true,
            error: String(e),
          });
        }
      }
      return json({ snapshotted: results.length, errors });
    }

    // ── snapshot (1 boutique) ─────────────────────────────────────────────
    if (mode === 'snapshot') {
      const shopId = body.shop_id;
      if (!shopId) return json({ error: 'missing_shop_id' }, 400);
      const ok = isCron || callerIsSA || await isMember(shopId);
      if (!ok) return json({ error: 'not_authorized' }, 403);
      try {
        const r = await snapshotShop(admin, shopId, isCron, callerId);
        return json({ ok: true, ...r });
      } catch (e) {
        await admin.from('shop_backups').insert({
          shop_id: shopId, status: 'failed', is_auto: isCron,
          created_by: callerId, error: String(e),
        });
        return json({ error: String(e) }, 500);
      }
    }

    // ── restore ───────────────────────────────────────────────────────────
    if (mode === 'restore') {
      if (!callerIsSA) return json({ error: 'not_super_admin' }, 403);
      const backupId = body.backup_id;
      if (!backupId) return json({ error: 'missing_backup_id' }, 400);
      const { data: meta, error: mErr } = await admin
        .from('shop_backups').select('shop_id, storage_path')
        .eq('id', backupId).maybeSingle();
      if (mErr || !meta || !meta.storage_path) {
        return json({ error: 'backup_not_found' }, 404);
      }
      const { data: file, error: dErr } = await admin
        .storage.from(BUCKET).download(meta.storage_path);
      if (dErr || !file) return json({ error: 'download_failed' }, 500);
      const payload = JSON.parse(await file.text());
      const { data: res, error: rErr } = await admin
        .rpc('restore_shop_snapshot', {
          p_shop_id: meta.shop_id, p_payload: payload,
        });
      if (rErr) return json({ error: 'restore_failed: ' + rErr.message }, 500);
      return json({ ok: true, result: res });
    }

    // ── download (URL signée 5 min) ───────────────────────────────────────
    if (mode === 'download') {
      const backupId = body.backup_id;
      if (!backupId) return json({ error: 'missing_backup_id' }, 400);
      const { data: meta } = await admin
        .from('shop_backups').select('shop_id, storage_path')
        .eq('id', backupId).maybeSingle();
      if (!meta || !meta.storage_path) return json({ error: 'backup_not_found' }, 404);
      const ok = callerIsSA || await isMember(meta.shop_id);
      if (!ok) return json({ error: 'not_authorized' }, 403);
      const { data: signed, error: sgErr } = await admin
        .storage.from(BUCKET).createSignedUrl(meta.storage_path, 300);
      if (sgErr || !signed) return json({ error: 'sign_failed' }, 500);
      return json({ ok: true, url: signed.signedUrl });
    }

    return json({ error: 'unknown_mode' }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

// ── Sauvegarde d'une boutique : export → upload → métadonnée → rétention ───
async function snapshotShop(
  admin: ReturnType<typeof createClient>,
  shopId: string,
  isAuto: boolean,
  createdBy: string | null,
) {
  const { data: payload, error } = await admin
    .rpc('export_shop_snapshot', { p_shop_id: shopId });
  if (error) throw new Error('export_rpc: ' + error.message);

  const jsonStr = JSON.stringify(payload);
  const tables = (payload as { tables?: Record<string, unknown> })?.tables ?? {};
  const counts: Record<string, number> = {};
  for (const k of Object.keys(tables)) {
    if (Array.isArray(tables[k])) counts[k] = (tables[k] as unknown[]).length;
  }

  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const path = `shops/${shopId}/${ts}.json`;
  const { error: upErr } = await admin.storage.from(BUCKET).upload(
    path, new Blob([jsonStr], { type: 'application/json' }),
    { contentType: 'application/json', upsert: false },
  );
  if (upErr) throw new Error('upload: ' + upErr.message);

  const { data: row, error: insErr } = await admin.from('shop_backups').insert({
    shop_id: shopId, storage_path: path,
    size_bytes: jsonStr.length, row_counts: counts,
    status: 'completed', is_auto: isAuto, created_by: createdBy,
  }).select('id').single();
  if (insErr) throw new Error('insert_meta: ' + insErr.message);

  await pruneOld(admin, shopId);
  return { backup_id: row.id, path, size_bytes: jsonStr.length, row_counts: counts };
}

// ── Rétention : purge des snapshots > RETENTION_DAYS ───────────────────────
async function pruneOld(
  admin: ReturnType<typeof createClient>,
  shopId: string,
) {
  const cutoff = new Date(Date.now() - RETENTION_DAYS * 86400_000).toISOString();
  const { data: olds } = await admin
    .from('shop_backups').select('id, storage_path')
    .eq('shop_id', shopId).lt('created_at', cutoff);
  if (!olds || olds.length === 0) return;
  const paths = olds.map((o: { storage_path: string | null }) => o.storage_path)
    .filter((p): p is string => !!p);
  if (paths.length) await admin.storage.from(BUCKET).remove(paths);
  await admin.from('shop_backups').delete()
    .in('id', olds.map((o: { id: string }) => o.id));
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
