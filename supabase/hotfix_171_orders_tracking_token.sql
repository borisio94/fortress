-- hotfix_171_orders_tracking_token.sql
-- ═════════════════════════════════════════════════════════════════════════
-- UN JETON DE SUIVI, DISTINCT DE L'IDENTIFIANT DE COMMANDE.
--
-- Le lien de suivi envoyé au client — `/track/<id>` — reposait sur
-- l'identifiant de la commande comme unique secret. Ce modèle ne tient que
-- si l'identifiant est imprévisible. C'est le cas des commandes web
-- (`gen_random_uuid()`), mais PAS des commandes saisies dans l'application :
-- leur identifiant est `order_<horodatage en millisecondes>`, donc énumérable.
--
-- Conséquence mesurée avant ce correctif : en itérant sur des horodatages, un
-- tiers lisait le nom, le téléphone, le panier et l'adresse de livraison de
-- n'importe quelle commande, toutes boutiques confondues.
--
-- On sépare donc les deux rôles :
--   * `id`             — clé technique, peut rester prévisible ;
--   * `tracking_token` — secret de 128 bits, seul porté par le lien public.
--
-- Les commandes existantes reçoivent un jeton par le backfill. Leurs anciens
-- liens continuent de FONCTIONNER EN LECTURE (cf. hotfix_172, qui accepte
-- l'un ou l'autre) mais perdent le droit de VALIDER (cf. hotfix_173) — la
-- validation est une écriture, elle exige le secret.
--
-- `gen_random_uuid()` et non `uuid_generate_v4()` : la seconde exige
-- l'extension `uuid-ossp`, la première est native depuis PostgreSQL 13 et
-- disponible d'office sur Supabase.
--
-- Colonne NULLABLE à dessein : un client hors ligne insère sans la connaître,
-- le DEFAULT la remplit côté serveur, et l'application retombe sur `id` tant
-- qu'elle n'a pas relu la ligne. Aucune écriture cliente ne doit la fournir.
--
-- 100 % idempotent (ré-exécutable sans effet de bord).
-- ═════════════════════════════════════════════════════════════════════════

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS tracking_token TEXT DEFAULT gen_random_uuid()::text;

COMMENT ON COLUMN public.orders.tracking_token IS
  'Secret du lien de suivi public (/track/<token>). Distinct de `id`, qui '
  'reste prévisible sur les commandes créées dans l''app. Généré côté '
  'serveur ; jamais fourni par le client.';

-- Backfill : toute commande antérieure reçoit son jeton. Sans cela, les
-- commandes existantes n'auraient aucun lien sécurisé à ré-émettre.
UPDATE public.orders
   SET tracking_token = gen_random_uuid()::text
 WHERE tracking_token IS NULL;

-- Unicité : c'est la clé de lecture publique, une collision donnerait accès
-- à la mauvaise commande. Un index UNIQUE tolère les NULL (aucun après le
-- backfill, mais une insertion concurrente pendant la migration en laisse).
CREATE UNIQUE INDEX IF NOT EXISTS orders_tracking_token_key
  ON public.orders (tracking_token);
