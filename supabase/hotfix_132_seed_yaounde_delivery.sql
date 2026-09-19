-- hotfix_132_seed_yaounde_delivery.sql
-- ═════════════════════════════════════════════════════════════════════════
-- Barème de livraison « Flash Livraison — Yaoundé 2026 ».
--
-- Pendant du hotfix_130 (Douala) pour la ville de Yaoundé, extrait du PDF
-- « Tarifs Yaoundé 2026 » (Flash Livraison, Efoulan).
--
-- DIFFÉRENCE CLÉ vs hotfix_130 : on NE purge PAS toute la boutique. On ne
-- touche QU'À Yaoundé (les 74 quartiers Douala du hotfix_130 sont conservés).
-- Purge ciblée : tout quartier dont la ville commence par « yaound » (couvre
-- l'unique « Tongolo / yaounde » saisi à la main, sans zone) + les 4 zones
-- Yaoundé de ce seed (idempotence).
--
-- Règles appliquées (calquées sur Douala) :
--   * 4 zones = paliers de prix : 1 000 / 1 500 / 2 000 / 2 500 FCFA.
--   * Quartiers multi-lieux du PDF gardés en une entrée (ex. « Odja B12 /
--     Nkonlda / Minkan » à 2 000).
--   * Ville normalisée « Yaoundé » (casse + accent propres, comme « Douala »).
--   * Frais de ramassage / vente entrepôt / stockage du PDF = frais
--     partenaires, PAS des frais de livraison par quartier → NON seedés
--     (hors périmètre, identique à Douala).
--
-- Total seedé : 4 zones + 62 quartiers (ville = Yaoundé).
--
-- Idempotent : ré-exécutable (purge Yaoundé uniquement puis réinsertion).
-- Après application : recharger l'app (F5) → la sync charge le nouveau barème.
-- ═════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_shop  TEXT;
  z_1000  TEXT := 'dz_yaounde_1000';
  z_1500  TEXT := 'dz_yaounde_1500';
  z_2000  TEXT := 'dz_yaounde_2000';
  z_2500  TEXT := 'dz_yaounde_2500';
  n_q     INTEGER;
  n_z     INTEGER;
BEGIN
  -- ── 1. Détecter la boutique cible ────────────────────────────────────
  -- Priorité à celle qui a déjà des quartiers Douala (même boutique), puis
  -- Yaoundé, puis l'unique boutique ayant des zones.
  SELECT shop_id INTO v_shop
    FROM public.delivery_quartiers
   WHERE lower(city) = 'douala'
   LIMIT 1;

  IF v_shop IS NULL THEN
    SELECT shop_id INTO v_shop
      FROM public.delivery_quartiers
     WHERE lower(city) LIKE 'yaound%'
     LIMIT 1;
  END IF;

  IF v_shop IS NULL THEN
    SELECT shop_id INTO v_shop FROM public.delivery_zones LIMIT 1;
  END IF;

  IF v_shop IS NULL THEN
    RAISE EXCEPTION
      'Aucune boutique détectée (ni quartier Douala/Yaoundé, ni zone). '
      'Renseigner v_shop manuellement en tête du bloc DO.';
  END IF;

  RAISE NOTICE 'Boutique cible : %', v_shop;

  -- ── 2. Purge CIBLÉE Yaoundé (Douala intact) ─────────────────────────
  -- Quartiers d'abord (FK zone_id), puis les zones Yaoundé de ce seed.
  DELETE FROM public.delivery_quartiers
   WHERE shop_id = v_shop AND lower(city) LIKE 'yaound%';
  DELETE FROM public.delivery_zones
   WHERE shop_id = v_shop AND id LIKE 'dz_yaounde_%';

  -- ── 3. Recréer les 4 zones (paliers de prix) ────────────────────────
  INSERT INTO public.delivery_zones (id, shop_id, name, schema_version) VALUES
    (z_1000, v_shop, 'Yaoundé · 1 000 FCFA', 1),
    (z_1500, v_shop, 'Yaoundé · 1 500 FCFA', 1),
    (z_2000, v_shop, 'Yaoundé · 2 000 FCFA', 1),
    (z_2500, v_shop, 'Yaoundé · 2 500 FCFA', 1);

  -- ── 4. Quartiers ────────────────────────────────────────────────────

  -- Zone 1 000 FCFA (4)
  INSERT INTO public.delivery_quartiers
    (id, zone_id, shop_id, city, name, price, schema_version)
  SELECT 'dq_y1000_' || lpad(ord::text, 2, '0'),
         z_1000, v_shop, 'Yaoundé', n, 1000, 1
  FROM unnest(ARRAY[
    'Efoulan','Nsam','Damas','Acacia'
  ]) WITH ORDINALITY AS t(n, ord);

  -- Zone 1 500 FCFA (35)
  INSERT INTO public.delivery_quartiers
    (id, zone_id, shop_id, city, name, price, schema_version)
  SELECT 'dq_y1500_' || lpad(ord::text, 2, '0'),
         z_1500, v_shop, 'Yaoundé', n, 1500, 1
  FROM unnest(ARRAY[
    'Poste centrale','Marché centrale','Mvan','Simbock','Mendong','Jouvence',
    'TamTam','Biyem-Assi','Odja (jusqu''à la borne 10)','Ekounou','Awae',
    'Nkomo','Biteng','Cité de la paix','Nlongkak','Melen','Olezoa','Kodingui',
    'Mimboman','Etoudi','Manguier','Tongolo','Carrefour MEC','Cité verte',
    'Mballa 2','Ahala Barrière carrefour','Messassi','Essos','Ngousso',
    'Omnisport','Carrière','Briqueterie','Mokolo','Stinga Fecafoot','Bastos'
  ]) WITH ORDINALITY AS t(n, ord);

  -- Zone 2 000 FCFA (17)
  INSERT INTO public.delivery_quartiers
    (id, zone_id, shop_id, city, name, price, schema_version)
  SELECT 'dq_y2000_' || lpad(ord::text, 2, '0'),
         z_2000, v_shop, 'Yaoundé', n, 2000, 1
  FROM unnest(ARRAY[
    'Mimboman (après le terminus)','Nkolmessing','Odja B12 / Nkonlda / Minkan',
    'Nyom','Ahala Barrière (après le carrefour)','Eloumdem II','Eleveur',
    'Fougerolle','Stinga village','Nkouabang','Nomayos','Mbankolo','Mont Fébé',
    'Nkolfoulou','Monti','Nkolbison','Badoumou'
  ]) WITH ORDINALITY AS t(n, ord);

  -- Zone 2 500 FCFA (6)
  INSERT INTO public.delivery_quartiers
    (id, zone_id, shop_id, city, name, price, schema_version)
  SELECT 'dq_y2500_' || lpad(ord::text, 2, '0'),
         z_2500, v_shop, 'Yaoundé', n, 2500, 1
  FROM unnest(ARRAY[
    'Soa','Nkozoa','Nsimalen','Mbankomo','Nkometou','Leboudi – Zamangoué'
  ]) WITH ORDINALITY AS t(n, ord);

  -- ── 5. Contrôle ─────────────────────────────────────────────────────
  SELECT count(*) INTO n_z FROM public.delivery_zones
    WHERE shop_id = v_shop AND id LIKE 'dz_yaounde_%';
  SELECT count(*) INTO n_q FROM public.delivery_quartiers
    WHERE shop_id = v_shop AND lower(city) LIKE 'yaound%';
  RAISE NOTICE 'Seed Yaoundé terminé : % zones, % quartiers (attendu : 4 / 62).',
    n_z, n_q;
END $$;

-- ── Vérification manuelle (optionnel) ───────────────────────────────────
--   SELECT z.name AS zone, q.name AS quartier, q.price
--     FROM public.delivery_quartiers q
--     LEFT JOIN public.delivery_zones z ON z.id = q.zone_id
--    WHERE lower(q.city) LIKE 'yaound%'
--    ORDER BY q.price, q.name;
--
-- Fin — hotfix_132_seed_yaounde_delivery.sql
