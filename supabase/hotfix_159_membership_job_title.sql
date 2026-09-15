-- hotfix_159 — fonction métier portée par le COMPTE.
--
-- Jusqu'ici, `shop_memberships` ne connaissait que `role` = 'admin' | 'user',
-- c'est-à-dire un niveau de DROITS. Le métier de la personne — serveur,
-- cuisinier, livreur — vivait uniquement sur la fiche Personnel
-- (`staff_members.role`), et devait donc être ressaisi alors que la personne
-- existait déjà comme compte.
--
-- La fonction descend sur le compte : elle est saisie une fois, à la création
-- du compte, et la fiche Personnel en hérite.
--
-- AUCUNE RPC N'EST MODIFIÉE, à dessein. `list_shop_employees`,
-- `update_employee_profile` et `create_employee` gardent leur signature :
-- changer une signature impose un DROP FUNCTION, donc une fenêtre pendant
-- laquelle la gestion des comptes est cassée pour tout le monde. L'application
-- lit et écrit cette colonne EN DIRECT sur `shop_memberships`, ce que la
-- policy `shop_memberships_write` (FOR ALL, `_is_shop_admin`) autorise déjà.
--
-- Sans valeur, la colonne reste NULL : l'application la traite comme « aucune
-- fonction », exactement comme aujourd'hui.

ALTER TABLE shop_memberships
  ADD COLUMN IF NOT EXISTS job_title TEXT;

COMMENT ON COLUMN shop_memberships.job_title IS
  'Métier de la personne (Serveur, Cuisinier, Livreur…). Distinct de `role`, '
  'qui est un niveau de droits (admin/user). Alimente la fiche Personnel.';
