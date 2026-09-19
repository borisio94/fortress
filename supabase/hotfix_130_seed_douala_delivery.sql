-- hotfix_130_seed_douala_delivery.sql
-- ═════════════════════════════════════════════════════════════════════════
-- Barème de livraison « Flash Livraison — Douala 2026 ».
--
-- Objectif : SUPPRIMER les zones/quartiers de livraison déjà saisis pour la
-- boutique (tu n'avais inséré QUE Douala + quelques quartiers) puis RECRÉER
-- proprement le barème complet extrait du PDF.
--
-- Règles appliquées (validées avec l'utilisateur) :
--   * 4 zones = paliers de prix : 1 250 / 1 500 / 2 000 / 2 500 FCFA.
--   * « Prix haut de fourchette » : les suppléments conditionnels sont
--     intégrés au prix de base :
--       - Logbessou / Kotto / Ndobong : 1 250 + 250 → 1 500.
--       - Bonaberi (Bonassama → château) : 1 500 (si dans le quartier 2 000)
--         → 2 000 retenu.
--   * « Zones interdites » CONSERVÉES avec leur prix (Nkoumassi, Bonanjo,
--     Bonapriso, Bali) — pas d'exclusion.
--   * Quartiers « Sur demande » NON seedés : ils restent gérés par le flux
--     forfait « à confirmer » côté web (quartier non répertorié) et sont
--     ajoutés DIRECTEMENT dans la liste côté boutique au moment de la
--     commande (DeliveryZoneService.addQuartier). Raison technique : la
--     colonne price est NOT NULL ; un price=0 s'afficherait « 0 FCFA / gratuit »
--     (et non « à confirmer ») → trompeur pour le client.
--       Sur demande exclus : Dibamba (après le pont), Bomono, Mbanga-Pongo,
--       Petit Robert, PK22, PK23, PK24, Bekoko (après le pont).
--
-- Total seedé : 4 zones + 74 quartiers (ville = Douala).
--
-- Idempotent : ré-exécutable (purge complète puis réinsertion).
-- Après application : recharger l'app (F5) → la sync purge l'ancien Hive et
-- charge le nouveau barème.
-- ═════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_shop  TEXT;
  z_1250  TEXT := 'dz_douala_1250';
  z_1500  TEXT := 'dz_douala_1500';
  z_2000  TEXT := 'dz_douala_2000';
  z_2500  TEXT := 'dz_douala_2500';
  n_q     INTEGER;
  n_z     INTEGER;
BEGIN
  -- ── 1. Détecter la boutique cible ────────────────────────────────────
  -- Celle qui a déjà des quartiers Douala ; sinon repli sur l'unique
  -- boutique ayant des zones de livraison.
  SELECT shop_id INTO v_shop
    FROM public.delivery_quartiers
   WHERE lower(city) = 'douala'
   LIMIT 1;

  IF v_shop IS NULL THEN
    SELECT shop_id INTO v_shop FROM public.delivery_zones LIMIT 1;
  END IF;

  IF v_shop IS NULL THEN
    RAISE EXCEPTION
      'Aucune boutique détectée (ni quartier Douala, ni zone). '
      'Renseigner v_shop manuellement en tête du bloc DO.';
  END IF;

  RAISE NOTICE 'Boutique cible : %', v_shop;

  -- ── 2. Purge complète des données livraison de cette boutique ────────
  -- (tu n'avais que Douala — on repart d'une base propre).
  DELETE FROM public.delivery_quartiers WHERE shop_id = v_shop;
  DELETE FROM public.delivery_zones     WHERE shop_id = v_shop;

  -- ── 3. Recréer les 4 zones (paliers de prix) ────────────────────────
  INSERT INTO public.delivery_zones (id, shop_id, name, schema_version) VALUES
    (z_1250, v_shop, 'Douala · 1 250 FCFA', 1),
    (z_1500, v_shop, 'Douala · 1 500 FCFA', 1),
    (z_2000, v_shop, 'Douala · 2 000 FCFA', 1),
    (z_2500, v_shop, 'Douala · 2 500 FCFA', 1);

  -- ── 4. Quartiers ────────────────────────────────────────────────────

  -- Zone 1 250 FCFA (5)
  INSERT INTO public.delivery_quartiers
    (id, zone_id, shop_id, city, name, price, schema_version)
  SELECT 'dq_d1250_' || lpad(ord::text, 2, '0'),
         z_1250, v_shop, 'Douala', n, 1250, 1
  FROM unnest(ARRAY[
    'Logpom','Hôpital Général','Bonamoussadi','Makèpè','Beedi'
  ]) WITH ORDINALITY AS t(n, ord);

  -- Zone 1 500 FCFA (57) — inclut Logbessou/Kotto/Ndobong (+250 intégré)
  -- et les zones interdites conservées (Nkoumassi, Bonapriso, Bali).
  INSERT INTO public.delivery_quartiers
    (id, zone_id, shop_id, city, name, price, schema_version)
  SELECT 'dq_d1500_' || lpad(ord::text, 2, '0'),
         z_1500, v_shop, 'Douala', n, 1500, 1
  FROM unnest(ARRAY[
    'Logbessou','Kotto','Ndobong','Boaba Bonangang',
    'Lendi (avant la maison blanche)','Bonadibong','Mboppi','Bonadouma',
    'Nkoulouloum','Bessengue','Bepanda','Deido','Akwa Nord','Akwa','Komondo',
    'Ancien troisième','Marché Congo','La Douche','Nkouloulou','Camp Yabassi',
    'Nkoumassi','Marché central de Douala','Bonapriso','Bali','Bois des Singes',
    'New-Bell','Dakar','Brazzaville','Bilongue','OYACK','Ndogbassi et Village',
    'Elf','Saint Michel','Youpwe','Km5','Zone industrielle Bassa','Aéroport',
    'Génie militaire','Yassa','Japoma','Ari','Nyala','Logbaba','Ndokoti',
    'Ndogsimbi','Ange Raphaël','BP Cité',
    'PK8','PK9','PK10','PK11','PK12','PK13','PK14','PK15','PK16','PK17'
  ]) WITH ORDINALITY AS t(n, ord);

  -- Zone 2 000 FCFA (11) — inclut Bonanjo (zone interdite) et Bonaberi
  -- (Bonassama → château) remonté à 2 000.
  INSERT INTO public.delivery_quartiers
    (id, zone_id, shop_id, city, name, price, schema_version)
  SELECT 'dq_d2000_' || lpad(ord::text, 2, '0'),
         z_2000, v_shop, 'Douala', n, 2000, 1
  FROM unnest(ARRAY[
    'Lendi (après la maison blanche → chefferie)','Bonanjo','Ngodi Bakoko',
    'Dibamba (avant le pont)','Yatika','PK18','PK19','PK20','PK21',
    'Bonaberi (RAIL → Carrefour Music)','Bonaberi (Bonassama → château)'
  ]) WITH ORDINALITY AS t(n, ord);

  -- Zone 2 500 FCFA (1)
  INSERT INTO public.delivery_quartiers
    (id, zone_id, shop_id, city, name, price, schema_version)
  SELECT 'dq_d2500_' || lpad(ord::text, 2, '0'),
         z_2500, v_shop, 'Douala', n, 2500, 1
  FROM unnest(ARRAY[
    'Bonaberi (Carrefour Music → Échangeur)'
  ]) WITH ORDINALITY AS t(n, ord);

  -- ── 5. Contrôle ─────────────────────────────────────────────────────
  SELECT count(*) INTO n_z FROM public.delivery_zones     WHERE shop_id = v_shop;
  SELECT count(*) INTO n_q FROM public.delivery_quartiers WHERE shop_id = v_shop;
  RAISE NOTICE 'Seed terminé : % zones, % quartiers (attendu : 4 / 74).',
    n_z, n_q;
END $$;

-- ── Vérification manuelle (optionnel) ───────────────────────────────────
--   SELECT z.name AS zone, q.name AS quartier, q.price
--     FROM public.delivery_quartiers q
--     LEFT JOIN public.delivery_zones z ON z.id = q.zone_id
--    WHERE lower(q.city) = 'douala'
--    ORDER BY q.price, q.name;
--
-- Fin — hotfix_130_seed_douala_delivery.sql
