-- ════════════════════════════════════════════════════════════════════════════
-- hotfix_121_sa_tickets_overview.sql
--
-- 🟢 Vision SUPER-ADMIN de la messagerie hiérarchique (tickets).
-- Complète hotfix_055 (tables) + hotfix_056 (escalade). Ajoute la couche de
-- LECTURE TRANSVERSALE pour le super-admin : voir TOUS les tickets de TOUTES
-- les boutiques, même ceux NON remontés à son niveau (admin/owner).
--
-- Pourquoi ça NE CASSE RIEN :
--   • Aucune table/colonne/policy existante modifiée — uniquement 2 RPC en
--     LECTURE, `SECURITY DEFINER`, gardées par `_is_super_admin()` (hotfix_041).
--   • Le SA peut DÉJÀ lire/écrire les tickets via la RLS existante
--     (`shop_tickets_select` = `_is_shop_member` ⊇ `_is_super_admin`). Ces RPC
--     ne font qu'AGRÉGER + ENRICHIR (nom boutique, auteur, nb messages) pour
--     éviter un N+1 côté client. La réponse/résolution du SA continue de passer
--     par les chemins existants (RLS), pas par ce fichier.
--   • 100 % IDEMPOTENT (CREATE OR REPLACE).
--
-- Contrat consommé par le Dart (TicketRepository.saListTickets / saTicketCounters).
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. Liste transversale enrichie ──────────────────────────────────────────
-- Filtres optionnels (NULL = pas de filtre). Tri : tickets ouverts d'abord,
-- puis activité la plus récente. Limite de sécurité à 1000 lignes.
CREATE OR REPLACE FUNCTION public.sa_list_tickets(
  p_status  text DEFAULT NULL,   -- open | resolved | closed | NULL(tous)
  p_level   text DEFAULT NULL,   -- admin | owner | super_admin | NULL(tous)
  p_shop_id text DEFAULT NULL    -- filtre boutique | NULL(toutes)
)
RETURNS TABLE (
  id             text,
  shop_id        text,
  shop_name      text,
  opened_by      text,
  opener_label   text,
  current_level  text,
  category       text,
  subject        text,
  status         text,
  priority       text,
  created_at     timestamptz,
  updated_at     timestamptz,
  resolved_at    timestamptz,
  message_count  bigint,
  last_message_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    t.id,
    t.shop_id,
    s.name AS shop_name,
    t.opened_by,
    -- Libellé auteur : nom de membership > email profil > id brut.
    COALESCE(
      NULLIF(trim(sm.full_name), ''),
      NULLIF(trim(p.email), ''),
      t.opened_by
    ) AS opener_label,
    t.current_level,
    t.category,
    t.subject,
    t.status,
    t.priority,
    t.created_at,
    t.updated_at,
    t.resolved_at,
    COALESCE(mc.cnt, 0)      AS message_count,
    mc.last_at               AS last_message_at
  FROM shop_tickets t
  LEFT JOIN shops s ON s.id = t.shop_id
  LEFT JOIN profiles p ON p.id::text = t.opened_by
  LEFT JOIN shop_memberships sm
         ON sm.user_id::text = t.opened_by
        AND sm.shop_id::text = t.shop_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS cnt, max(m.created_at) AS last_at
    FROM shop_ticket_messages m
    WHERE m.ticket_id = t.id
  ) mc ON true
  WHERE (p_status  IS NULL OR t.status        = p_status)
    AND (p_level   IS NULL OR t.current_level  = p_level)
    AND (p_shop_id IS NULL OR t.shop_id        = p_shop_id)
  ORDER BY (t.status = 'open') DESC,
           COALESCE(mc.last_at, t.updated_at) DESC
  LIMIT 1000;
END;
$fn$;

ALTER FUNCTION public.sa_list_tickets(text, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.sa_list_tickets(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sa_list_tickets(text, text, text) TO authenticated;


-- ── 2. Compteurs pour le badge SA ───────────────────────────────────────────
-- `escalated_open` = tickets ouverts remontés jusqu'à super_admin (ceux qui
-- réclament l'attention directe du SA → pilotent le badge temps réel).
CREATE OR REPLACE FUNCTION public.sa_ticket_counters()
RETURNS TABLE (open_total bigint, escalated_open bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NOT public._is_super_admin() THEN
    RAISE EXCEPTION 'forbidden: super-admin requis' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    count(*) FILTER (WHERE status = 'open') AS open_total,
    count(*) FILTER (WHERE status = 'open' AND current_level = 'super_admin')
      AS escalated_open
  FROM shop_tickets;
END;
$fn$;

ALTER FUNCTION public.sa_ticket_counters() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.sa_ticket_counters() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sa_ticket_counters() TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- Vérifications (super-admin connecté requis ; échouent en SQL Editor anonyme) :
--   SELECT * FROM public.sa_list_tickets(NULL, NULL, NULL) LIMIT 5;
--   SELECT * FROM public.sa_ticket_counters();
-- ════════════════════════════════════════════════════════════════════════════
