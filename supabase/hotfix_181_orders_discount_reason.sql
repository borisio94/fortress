-- hotfix_181_orders_discount_reason.sql
-- ═════════════════════════════════════════════════════════════════════════
-- REMISE SUR ADDITION — le motif voyage enfin avec la commande.
--
-- `bill_page` EXIGE un motif pour accorder une remise : le bouton refuse de
-- valider tant que le champ est vide. Ce motif partait ensuite dans
-- `ManagerGate.require(details: {...})`, donc dans `activity_logs` — et
-- `applyDiscount` n'écrivait que le montant sur la commande.
--
-- Résultat : un champ imposé au serveur, invisible partout ensuite. Ni sur
-- l'addition, ni sur la facture, ni dans les rapports. Le pire des deux
-- mondes — il coûte du temps et ne rend rien.
--
-- ── POURQUOI PAS SIMPLEMENT RELIRE `activity_logs` ─────────────────────────
--
-- Parce que le journal n'est pas lisible hors ligne, et qu'un restaurant
-- travaille hors ligne. `ActivityLogService.log` passe par
-- `AppDatabase.bgInsert`, qui écrit dans la FILE D'ATTENTE et pas dans Hive ;
-- la boîte locale `activity_logs_box` n'est remplie que par `syncActivityLogs`,
-- en tirant depuis le serveur. Une remise accordée pendant une coupure aurait
-- donc son motif nulle part de lisible jusqu'au retour du réseau.
--
-- Le motif doit voyager AVEC la commande. C'est l'objet de cette colonne.
--
-- ── L'E-COMMERCE NE BOUGE PAS ──────────────────────────────────────────────
--
-- Son chemin de remise (`caisse_bloc`, évènement `AddDiscount`) ne demande
-- aucun motif et n'en écrira aucun : la colonne y restera NULL. Additive,
-- nullable, sans défaut — aucune ligne existante n'est touchée, aucun
-- comportement existant n'est modifié.
--
-- ⚠ CE FICHIER S'APPLIQUE AVANT LE DÉPLOIEMENT DU CLIENT.
-- Une fois le client déployé, `saveOrder` et `updateOrder` envoient
-- `discount_reason` dans leur map. Sans la colonne, PostgREST rejette
-- l'écriture ENTIÈRE avec PGRST204 (« column not found ») — ce ne serait pas
-- le motif qui manquerait, ce serait la commande qui ne partirait plus.
--
-- ADD COLUMN sans défaut : métadonnée seule, aucune réécriture de table.
-- 100 % idempotent.
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS discount_reason TEXT;

COMMENT ON COLUMN public.orders.discount_reason IS
  'Motif de la remise accordée sur l''addition (restaurant). Saisi sous aval '
  'gérant, obligatoire dès qu''une remise est appliquée. NULL partout '
  'ailleurs, e-commerce compris.';

-- ── Vérification ──────────────────────────────────────────────────────────
-- 1. La colonne existe et accepte NULL :
--
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema = 'public'
--      AND table_name   = 'orders'
--      AND column_name  = 'discount_reason';
--
--   → attendu : discount_reason | text | YES
--
-- 2. Aucune ligne existante n'a été touchée — toutes à NULL :
--
--   SELECT count(*) AS total,
--          count(discount_reason) AS avec_motif
--     FROM public.orders;
--
--   → attendu : avec_motif = 0 juste après application.
--
-- 3. APRÈS déploiement du client et une remise accordée sur une addition,
--    le motif doit être remonté :
--
--   SELECT id, discount_amount, discount_reason
--     FROM public.orders
--    WHERE discount_amount > 0
--      AND discount_reason IS NOT NULL
--    ORDER BY created_at DESC
--    LIMIT 5;
