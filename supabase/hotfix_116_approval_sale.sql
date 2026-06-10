-- ════════════════════════════════════════════════════════════════════════
-- hotfix_116 : vente « à choisir sur place » (vente-ou-retour)
-- ════════════════════════════════════════════════════════════════════════
-- Certains clients pré-sélectionnent plusieurs articles que le livreur
-- apporte ; le client en garde certains sur place, le reste revient.
-- L'app RÉSERVE le stock à la création (décrément) et le réconcilie à la
-- clôture (gardé = vendu, retourné = remis en stock) → aucune perte de stock.
--
-- Ces 2 colonnes portent l'état sur la commande SYNCHRONISÉE : indispensable
-- pour que la complétion normale ne re-décrémente pas un stock déjà réservé
-- (anti-double-comptage), y compris vu depuis un autre appareil de la boutique.
--
-- Idempotent (IF NOT EXISTS). À appliquer dans le SQL editor Supabase AVANT
-- de déployer la build qui envoie ces colonnes (sinon les upserts de commande
-- échoueraient : colonne inconnue).
-- ════════════════════════════════════════════════════════════════════════

alter table public.orders
  add column if not exists is_approval_sale boolean not null default false,
  add column if not exists stock_reserved   boolean not null default false;

comment on column public.orders.is_approval_sale is
  'Vente « à choisir sur place » : le livreur porte plusieurs articles, '
  'réconciliés à la clôture (gardé vendu / retourné remis en stock).';
comment on column public.orders.stock_reserved is
  'Garde-fou anti-double-comptage : true une fois les articles réservés '
  '(décrémentés). Empêche de re-décrémenter à la complétion.';
