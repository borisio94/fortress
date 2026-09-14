-- hotfix_178_partner_debt_alert_and_advance.sql
-- ═════════════════════════════════════════════════════════════════════════
-- PARTENAIRES — ancienneté de dette configurable, et avance commerciale.
--
-- Deux changements indépendants, réunis parce qu'ils servent la même
-- livraison et qu'ils doivent être en base AVANT le déploiement du client.
--
-- 1. `shops.partner_debt_alert_days` — au bout de combien de jours une vente
--    encaissée par un partenaire et non reversée doit-elle être signalée.
--    Ce seuil est un réglage MÉTIER : il doit suivre le commerçant d'un
--    appareil à l'autre. Il ne pouvait donc PAS vivre dans
--    `ShopSettingsStore` (lib/features/parametres/data/shop_settings_store.dart)
--    qui n'écrit que dans Hive, jamais dans Supabase — c'est le cas de
--    `caisse_tax_rate` & consorts, locaux à l'appareil par conception.
--
-- 2. `advance` ajouté au CHECK de `partner_ledger_entries.type`. Une avance
--    commerciale (la boutique verse au partenaire d'avance, créant une
--    créance) porte aujourd'hui le type `remittance`, indistinguable à la
--    relecture d'un règlement de dette. Les deux mouvements ont le même
--    sens et le même signe — seule l'INTENTION diffère, et elle se perd.
--
-- ⚠ CE FICHIER S'APPLIQUE AVANT LE DÉPLOIEMENT DU CLIENT.
--
-- Si une écriture `advance` partait vers un CHECK resté à quatre valeurs,
-- Postgres répondrait 23514 — classé erreur PERMANENTE depuis le commit
-- b157964. Mais `partner_ledger_entries` figure dans `neverDropTables`
-- (app_database.dart) : l'opération n'est donc PAS abandonnée, elle est
-- rejouée INDÉFINIMENT, avec une bannière « Synchro incomplète » que rien
-- ne vient résoudre. C'est exactement le scénario de la catégorie
-- « Stockage » corrigée hier par hotfix_177.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════════
-- 1. CHECK sur `partner_ledger_entries.type` — élargi, jamais rétréci.
-- ══════════════════════════════════════════════════════════════════════════
-- Postgres ne sait pas étendre une contrainte : on remplace. La nouvelle
-- liste est un SUR-ENSEMBLE de celle de hotfix_071 — aucune ligne existante
-- n'est invalidée.

ALTER TABLE public.partner_ledger_entries
  DROP CONSTRAINT IF EXISTS partner_ledger_entries_type_check;

-- ⚠ FILET DE SÉCURITÉ. Le CHECK d'ORIGINE (hotfix_062, ligne 20) est déclaré
-- EN LIGNE dans le CREATE TABLE, il porte donc un nom AUTO-GÉNÉRÉ. hotfix_071
-- l'a remplacé par un nom explicite, mais si hotfix_071 n'avait pas été
-- appliqué sur une base donnée, le DROP ci-dessus ne ferait rien, l'ADD plus
-- bas réussirait, et la table se retrouverait avec DEUX contraintes — la plus
-- ancienne rejetant toujours `advance`. La migration paraîtrait réussie sans
-- rien changer. On balaie donc aussi par définition.
--
-- Le filtre porte sur une VALEUR (`saleCollected`) et non sur le nom de la
-- colonne : un filtre sur '%type%' emporterait toute contrainte mentionnant
-- ce mot très courant. La leçon vient de hotfix_176, où
-- `stock_movements_reason_required` mentionnait `type` sans être le CHECK visé.
DO $drop_ple_type_chk$
DECLARE v_conname text;
BEGIN
  FOR v_conname IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'public.partner_ledger_entries'::regclass
       AND contype  = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%saleCollected%'
  LOOP
    EXECUTE format(
        'ALTER TABLE public.partner_ledger_entries DROP CONSTRAINT %I',
        v_conname);
  END LOOP;
END $drop_ple_type_chk$;

ALTER TABLE public.partner_ledger_entries
  ADD CONSTRAINT partner_ledger_entries_type_check
  CHECK (type IN (
    'saleCollected', 'deliveryOwed', 'remittance', 'partnerCharge',
    'advance'));

COMMENT ON COLUMN public.partner_ledger_entries.type IS
  'saleCollected (+, le partenaire a encaissé pour la boutique) · '
  'deliveryOwed (−, frais de livraison dus au partenaire) · '
  'remittance (signe variable : versement reçu du partenaire, ou règlement '
  'émis par la boutique) · partnerCharge (−, charge due au partenaire, '
  'sous-classée par `category`) · advance (+, avance commerciale versée au '
  'partenaire — même sens et même signe qu''un règlement, mais elle CRÉE '
  'une créance au lieu d''en solder une ; ajoutée par hotfix_178). '
  'Doit rester aligné sur PartnerLedgerEntryType '
  '(lib/features/parametres/domain/entities/partner_ledger_entry.dart), '
  'sérialisé en camelCase brut via `key => name`.';

-- ══════════════════════════════════════════════════════════════════════════
-- 2. Seuil d'alerte d'ancienneté, par boutique.
-- ══════════════════════════════════════════════════════════════════════════
-- Patron éprouvé sur cette table : ADD COLUMN IF NOT EXISTS + DEFAULT, puis
-- CHECK posé séparément (cf. `status` en hotfix_088, `backup_enabled` en
-- hotfix_102). Les lignes existantes reçoivent 30, qui satisfait le CHECK.

ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS partner_debt_alert_days INTEGER NOT NULL DEFAULT 30;

ALTER TABLE public.shops
  DROP CONSTRAINT IF EXISTS shops_partner_debt_alert_days_check;

ALTER TABLE public.shops
  ADD CONSTRAINT shops_partner_debt_alert_days_check
  CHECK (partner_debt_alert_days BETWEEN 1 AND 365);

COMMENT ON COLUMN public.shops.partner_debt_alert_days IS
  'Au-delà de ce nombre de jours, une vente encaissée par un partenaire et '
  'non reversée est signalée (bandeau du tableau de bord, carte partenaire). '
  'Défaut 30. Borné 1–365. Réglé depuis l''en-tête de la page Partenaires.';

-- ══════════════════════════════════════════════════════════════════════════
-- 3. Rechargement du cache de schéma PostgREST.
-- ══════════════════════════════════════════════════════════════════════════
-- Sans cela, PostgREST peut ignorer la nouvelle colonne (PGRST204 sur
-- `partner_debt_alert_days`) et continuer d'appliquer l'ancien CHECK.
NOTIFY pgrst, 'reload schema';

-- ── Vérification ───────────────────────────────────────────────────────────
--   1) Le CHECK de type doit être UNIQUE et contenir 'advance' :
--      SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--       WHERE conrelid = 'public.partner_ledger_entries'::regclass
--         AND contype = 'c';
--      → attendu : partner_ledger_entries_type_check, AVEC 'advance', et
--        AUCUNE autre contrainte CHECK mentionnant 'saleCollected'. Si une
--        seconde apparaît, le balayage a échoué : ne pas déployer.
--
--   2) La colonne doit exister avec son défaut :
--      SELECT column_name, data_type, column_default, is_nullable
--        FROM information_schema.columns
--       WHERE table_name = 'shops'
--         AND column_name = 'partner_debt_alert_days';
--      → attendu : integer · 30 · NO
--
--   3) Écriture de contrôle d'une avance (à supprimer ensuite) :
--      INSERT INTO public.partner_ledger_entries
--        (id, shop_id, partner_location_id, type, amount)
--      VALUES ('ple_test_178', '<shop>', '<partner_location>', 'advance', 1);
--      → doit réussir.
--      Puis : DELETE FROM public.partner_ledger_entries WHERE id='ple_test_178';
--
--   4) Les lignes existantes restent valides (le CHECK est un sur-ensemble) :
--      SELECT type, count(*) FROM public.partner_ledger_entries GROUP BY type;
--      → aucune erreur, et les 4 types historiques toujours présents.
-- ────────────────────────────────────────────────────────────────────────────
