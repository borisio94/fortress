-- ════════════════════════════════════════════════════════════════════════════
-- diagnostic_prod_readiness.sql   (LECTURE SEULE — n'écrit RIEN)
--
-- À coller tel quel dans Supabase → SQL Editor → Run.
-- Retourne une table : pour chaque objet critique attendu par l'app, son
-- statut OK / ❌ MANQUANT + le hotfix qui le fournit.
--
-- Si une ligne est ❌ MANQUANT : la fonctionnalité associée échouera
-- silencieusement en prod (erreur 404 RPC / 42501 / colonne absente).
-- Appliquer le hotfix indiqué (dossier supabase/) puis relancer ce script.
--
-- Aucune modification de schéma. Réexécutable autant de fois que voulu.
-- ════════════════════════════════════════════════════════════════════════════

WITH checks(categorie, objet, genre, hotfix) AS (
  VALUES
    -- ── Sécurité RLS + permissions (BLOQUANT) ───────────────────────────────
    ('Sécurité',    '_is_super_admin',                  'function', 'hotfix_041'),
    ('Sécurité',    '_is_shop_member',                  'function', 'hotfix_041'),
    ('Sécurité',    '_is_shop_admin',                   'function', 'hotfix_024'),
    ('Sécurité',    '_user_has_permission',             'function', 'hotfix_039'),
    ('Sécurité',    'exec_sql',                         'function', 'hotfix_040'),
    ('Sécurité',    'trg_enforce_order_mutation_perms', 'trigger',  'hotfix_039'),
    ('Sécurité',    'trg_enforce_max_admins',           'trigger',  'hotfix_024'),
    ('Sécurité RLS','shops',                            'rls',      'hotfix_041'),
    ('Sécurité RLS','products',                         'rls',      'hotfix_041'),
    ('Sécurité RLS','orders',                           'rls',      'hotfix_041'),
    ('Sécurité RLS','clients',                          'rls',      'hotfix_041'),
    ('Sécurité RLS','profiles',                         'rls',      'hotfix_041'),
    ('Sécurité RLS','sale_items',                       'rls',      'hotfix_042'),
    -- ── Abonnement / plans ──────────────────────────────────────────────────
    ('Abonnement',  'get_user_plan',                    'function', 'migrations/001 + hotfix_017'),
    -- ── Sessions actives ────────────────────────────────────────────────────
    ('Sessions',    'active_sessions',                  'table',    'hotfix_044'),
    ('Sessions',    'register_session',                 'function', 'hotfix_044'),
    ('Sessions',    'revoke_session',                   'function', 'hotfix_044'),
    -- ── Catalogue public + commandes publiques ──────────────────────────────
    ('Catalogue',   'products.is_visible_web',          'column',   'hotfix_045'),
    ('Catalogue',   'place_public_order',               'function', 'hotfix_046/047/048'),
    -- ── Livraison ───────────────────────────────────────────────────────────
    ('Livraison',   'transfer_order_to_delivery',       'function', 'hotfix_049/050'),
    -- ── Suivi commande client ───────────────────────────────────────────────
    ('Suivi',       'get_tracked_order',                'function', 'hotfix_057'),
    ('Suivi',       'validate_order_by_client',         'function', 'hotfix_057'),
    -- ── Tickets / escalade ──────────────────────────────────────────────────
    ('Tickets',     'escalate_ticket',                  'function', 'hotfix_056'),
    -- ── Liens courts ────────────────────────────────────────────────────────
    ('Liens',       'short_links',                      'table',    'hotfix_066'),
    -- ── Templates WhatsApp ──────────────────────────────────────────────────
    ('WhatsApp',    'whatsapp_templates',               'table',    'hotfix_067'),
    -- ── Campagnes promo ─────────────────────────────────────────────────────
    ('Promo',       'promo_campaigns',                  'table',    'hotfix_068'),
    ('Promo',       'increment_promo_sent',             'function', 'hotfix_068'),
    ('Promo',       'increment_promo_view',             'function', 'hotfix_068'),
    -- ── Livre partenaire ────────────────────────────────────────────────────
    ('Partenaire',  'partner_ledger_entries',           'table',    'hotfix_062/072'),
    -- ── Réinitialisation données ────────────────────────────────────────────
    ('Reset',       'reset_shop_data',                  'function', 'hotfix_058'),
    -- ── Realtime ────────────────────────────────────────────────────────────
    ('Realtime',    'supabase_realtime',                'publication','hotfix_074')
)
SELECT
  categorie,
  objet,
  genre,
  hotfix,
  CASE
    WHEN genre = 'function'    AND EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                                            WHERE n.nspname='public' AND p.proname = objet)
                               THEN '✅ OK'
    WHEN genre = 'table'       AND to_regclass('public.'||objet) IS NOT NULL THEN '✅ OK'
    WHEN genre = 'column'      AND EXISTS (SELECT 1 FROM information_schema.columns
                                            WHERE table_schema='public'
                                              AND table_name = split_part(objet,'.',1)
                                              AND column_name = split_part(objet,'.',2))
                               THEN '✅ OK'
    WHEN genre = 'trigger'     AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = objet AND NOT tgisinternal)
                               THEN '✅ OK'
    WHEN genre = 'rls'         AND EXISTS (SELECT 1 FROM pg_tables
                                            WHERE schemaname='public' AND tablename = objet
                                              AND rowsecurity = true)
                               THEN '✅ OK'
    WHEN genre = 'publication' AND EXISTS (SELECT 1 FROM pg_publication WHERE pubname = objet)
                               THEN '✅ OK'
    ELSE '❌ MANQUANT — appliquer ' || hotfix
  END AS statut
FROM checks
ORDER BY
  CASE WHEN categorie LIKE 'Sécurité%' THEN 0 ELSE 1 END,
  categorie, objet;

-- ── Bonus : combien de policies RLS par table critique ? ───────────────────
-- (0 policy + rowsecurity=true = table verrouillée pour tous = anormal)
SELECT tablename,
       (SELECT count(*) FROM pg_policies p
         WHERE p.schemaname='public' AND p.tablename = t.tablename) AS nb_policies,
       rowsecurity AS rls_active
FROM pg_tables t
WHERE schemaname='public'
  AND tablename IN ('shops','products','orders','clients','profiles',
                    'sale_items','shop_memberships','expenses')
ORDER BY tablename;
