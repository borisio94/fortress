-- hotfix_168_product_draft_status.sql
-- ═════════════════════════════════════════════════════════════════════════
-- BROUILLON DE FICHE PRODUIT — statut `draft` + échéance de purge.
--
-- Une fiche produit demande une à deux minutes de saisie. Quitter l'écran,
-- rafraîchir la page ou perdre la connexion effaçait tout : rien n'était
-- conservé tant que « Enregistrer » n'avait pas été pressé.
--
-- La fiche inachevée peut désormais être gardée en brouillon. Elle n'est ni
-- vendable ni publiée (`is_active = false`, `is_visible_web = false`), reste
-- visible dans l'inventaire avec un badge, et s'efface d'elle-même au bout
-- de 7 jours — d'où `draft_expires_at`, purgé au démarrage par le client.
--
-- `products.status` est une colonne TEXT sous contrainte CHECK (hotfix_010,
-- 9 valeurs) : sans extension, tout UPDATE en 'draft' serait rejeté.
--
-- Les RPC publiques ne sont volontairement PAS touchées : elles filtrent
-- déjà `is_active = true`, ce qui exclut tout brouillon — y compris
-- `get_delivery_products`, qui contourne pourtant `is_visible_web`.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- ── 1. Échéance du brouillon ───────────────────────────────────────────
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS draft_expires_at TIMESTAMPTZ;

COMMENT ON COLUMN public.products.draft_expires_at IS
  'Échéance d''un brouillon (status = draft). NULL pour tout produit '
  'publié. Passé cette date, la fiche est supprimée. Voir hotfix_168.';

-- ── 2. Extension de la contrainte de statut ────────────────────────────
-- Reprend les 9 valeurs de hotfix_010 et ajoute 'draft'.
ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_status_check;

ALTER TABLE public.products
  ADD CONSTRAINT products_status_check CHECK (
    status IN (
      'available',     -- En vente
      'discounted',    -- Prix réduit / promo
      'to_inspect',    -- À inspecter
      'damaged',       -- Endommagé
      'defective',     -- Défectueux
      'in_repair',     -- En réparation
      'scrapped',      -- Mis au rebut
      'returned',      -- Retourné
      'discontinued',  -- Arrêté / fin de vie
      'draft'          -- Brouillon jamais publié (hotfix_168)
    )
  );

-- Recharge le cache de schéma PostgREST (sinon PGRST204 quelques minutes).
NOTIFY pgrst, 'reload schema';
