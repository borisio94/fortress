-- ═══════════════════════════════════════════════════════════════════════════
-- hotfix_134 — Nettoyage des versions en DOUBLE de public.place_public_order
--
-- PROBLÈME : la fonction a évolué au fil des hotfix (046→129) en AJOUTANT des
-- paramètres. Comme chaque nouvelle signature (liste de types) diffère,
-- `CREATE OR REPLACE FUNCTION` a créé une NOUVELLE surcharge à chaque fois au
-- lieu de remplacer → plusieurs versions coexistent en base. Résultat : un
-- appel avec un sous-ensemble de paramètres peut renvoyer `PGRST203`
-- (« could not choose the best candidate function ») car PostgREST ne sait pas
-- laquelle choisir. Le catalogue fonctionne aujourd'hui (il envoie tous les
-- paramètres de la version courante), mais ces doublons sont un piège latent.
--
-- OBJECTIF : ne garder QUE la version COURANTE = celle du hotfix_129, la seule
-- qui possède les paramètres de livraison (`p_delivery_quartier`, etc.) :
--   place_public_order(
--     p_shop_id text, p_items jsonb, p_client_name text, p_client_phone text,
--     p_client_city text, p_client_district text, p_notes text,
--     p_scheduled_at timestamptz, p_location_id text, p_idempotency_key text,
--     p_delivery_price int, p_delivery_quartier text, p_delivery_zone text)
--
-- Anciennes versions supprimées (par nb de paramètres) : 6 (hotfix_046),
-- 7 (047), 8 (048), 9 (078/079), 10 (080).
--
-- SÛR & IDEMPOTENT : ne touche jamais la version courante ; relançable sans
-- effet. Aucune donnée impactée (seule la DÉFINITION des fonctions est nettoyée).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. AVANT — lister les surcharges présentes (optionnel, pour contrôle) ────
-- SELECT p.oid::regprocedure AS signature,
--        pg_get_function_arguments(p.oid) AS arguments
-- FROM pg_proc p
-- JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public' AND p.proname = 'place_public_order'
-- ORDER BY p.pronargs;

-- ── 2. Suppression robuste : DROP de toute surcharge qui N'A PAS le paramètre
--       `p_delivery_quartier` (= toutes les anciennes versions). Garde la
--       courante. Introspection dynamique → ne dépend pas des types exacts.
DO $$
DECLARE
  r record;
  dropped int := 0;
  kept    int := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig,
           pg_get_function_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'place_public_order'
  LOOP
    IF position('p_delivery_quartier' IN r.args) = 0 THEN
      EXECUTE 'DROP FUNCTION ' || r.sig::text;
      dropped := dropped + 1;
      RAISE NOTICE 'Supprimée (ancienne version) : %', r.sig;
    ELSE
      kept := kept + 1;
      RAISE NOTICE 'Conservée (version courante)  : %', r.sig;
    END IF;
  END LOOP;
  RAISE NOTICE '=> % ancienne(s) supprimée(s), % conservée(s).', dropped, kept;

  IF kept <> 1 THEN
    RAISE EXCEPTION 'Attendu 1 version courante, trouvé % — vérifiez avant de continuer.', kept;
  END IF;
END $$;

-- ── 3. Filet explicite (belt-and-suspenders) : DROP IF EXISTS des signatures
--       historiques connues, au cas où l'introspection en aurait manqué une.
--       IF EXISTS → no-op si déjà supprimée par l'étape 2.
DROP FUNCTION IF EXISTS public.place_public_order(text, jsonb, text, text, text, text);                                  -- 046 (6 params)
DROP FUNCTION IF EXISTS public.place_public_order(text, jsonb, text, text, text, text, text);                            -- 047 (7 params)
DROP FUNCTION IF EXISTS public.place_public_order(text, jsonb, text, text, text, text, text, timestamptz);               -- 048 (8 params)
DROP FUNCTION IF EXISTS public.place_public_order(text, jsonb, text, text, text, text, text, timestamptz, text);         -- 078/079 (9 params)
DROP FUNCTION IF EXISTS public.place_public_order(text, jsonb, text, text, text, text, text, timestamptz, text, text);   -- 080 (10 params)

-- ── 4. APRÈS — vérifier qu'il ne reste QU'UNE surcharge (la courante) ────────
-- SELECT p.oid::regprocedure AS signature
-- FROM pg_proc p
-- JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public' AND p.proname = 'place_public_order';
-- -> doit renvoyer 1 seule ligne (13 paramètres).
