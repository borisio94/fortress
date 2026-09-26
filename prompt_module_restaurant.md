# FORTRESS POS — MODULE RESTAURANT

## CONTEXTE
Fortress est un POS e-commerce existant.
J'ajoute un mode Restaurant sans toucher
au mode boutique existant.

## INSPECTE D'ABORD
- lib/features/caisse/ (CaissePage, OrderCreation, caisse_bloc, sale_local_datasource)
- lib/features/inventaire/ (produits, catégories)
- lib/features/parametres/ (ShopSettingsPage)
- lib/core/database/app_database.dart
- lib/core/theme/ (AppColors, AppTextStyles)
- Supabase : tables shops · products · orders
- app_router.dart · route_names.dart
- Hive : toutes les boxes existantes

**Règle : inspecte avant de créer · zéro impact sur le mode boutique existant · zéro hardcode · tokens Fortress uniquement · offline-first Hive d'abord · flutter analyze sans nouvelles erreurs**

---

## 1. TYPE D'ÉTABLISSEMENT — PARAMÈTRES

Dans ShopSettingsPage ajouter section "Type d'établissement" :

Options :
- Boutique (défaut · existant)
- Restaurant / Café
- Fast-food / Street food
- Les deux (boutique + restauration)

```sql
ALTER TABLE shops
  ADD COLUMN IF NOT EXISTS shop_type TEXT
  DEFAULT 'boutique'
  CHECK (shop_type IN (
    'boutique','restaurant','fastfood','mixed'));
```

Hive shopBox : ajouter champ shopType

---

## 2. NOUVELLES TABLES SUPABASE

### Table restaurant_tables
```sql
CREATE TABLE IF NOT EXISTS public.restaurant_tables (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id TEXT NOT NULL,
  number INTEGER NOT NULL,
  name TEXT NOT NULL,
  capacity INTEGER DEFAULT 4,
  status TEXT DEFAULT 'libre'
    CHECK (status IN ('libre','occupee','addition','reservee')),
  current_order_id UUID,
  reservation_time TIMESTAMPTZ,
  reservation_name TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

### Table menu_modifiers
```sql
CREATE TABLE IF NOT EXISTS public.menu_modifiers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id TEXT NOT NULL,
  product_id UUID REFERENCES products(id),
  name TEXT NOT NULL,
  options JSONB NOT NULL,
  price_impact INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

### Modifier orders
```sql
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS table_id UUID
    REFERENCES restaurant_tables(id),
  ADD COLUMN IF NOT EXISTS covers INTEGER,
  ADD COLUMN IF NOT EXISTS order_type TEXT
    DEFAULT 'takeaway'
    CHECK (order_type IN ('dine_in','takeaway','delivery')),
  ADD COLUMN IF NOT EXISTS sent_to_kitchen BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS kitchen_ready BOOLEAN DEFAULT false;
```

### RLS
- restaurant_tables : membres boutique
- menu_modifiers : membres boutique

### Hive boxes à créer
- restaurantTablesBox
- menuModifiersBox

---

## 3. NAVIGATION — MODE RESTAURANT

Si shop_type IN ('restaurant','fastfood','mixed')
ajouter dans sidebar et bottom nav :

- ti-layout-grid → "Plan de salle" → /restaurant/tables
- ti-chef-hat → "Cuisine" → /restaurant/cuisine
- ti-shopping-bag → "À emporter" → /restaurant/takeaway

L'onglet "Caisse" reste accessible pour les ventes directes au comptoir.

---

## 4. PAGE PLAN DE SALLE — /restaurant/tables

Affichage en grille des tables. Chaque table = une carte colorée :

| Statut | Couleur | Icône |
|--------|---------|-------|
| Libre | AppSemanticColors.success (vert clair) | ti-armchair |
| Occupée | AppSemanticColors.warning (orange clair) | ti-armchair |
| Addition | AppSemanticColors.danger (rouge clair) | ti-receipt |
| Réservée | bleu clair | ti-clock |

Chaque carte affiche :
- Numéro de table (T1, T2...)
- Statut en texte
- Nombre de couverts
- Heure réservation si réservée

Tap sur table :
- Si libre → créer nouvelle commande pour cette table
- Si occupée/addition → ouvrir commande en cours

Bouton + → créer nouvelle table (formulaire : nom · capacité)

Légende en haut : Libre · Occupée · Addition · Réservée

Sync Realtime Supabase sur restaurant_tables pour
mises à jour instantanées entre appareils.

---

## 5. PAGE COMMANDE PAR TABLE

Header : numéro table + heure ouverture

Sélecteur couverts (+/-) en haut

Tabs catégories (scrollable horizontal) :
Plats · Entrées · Desserts · Boissons · Extras
(lues depuis les catégories produits existantes)

Grille articles (2 colonnes) :
- Chaque article : nom · prix · bouton +
- Tap + → ajoute à la commande
- Tap long → ouvre les modificateurs

Modificateurs par article :
- Bottom sheet avec les options configurées
- (Cuisson · Options · Suppléments)
- Prix impact affiché si supplément

Récapitulatif commande (bas de page) :
- Liste articles + modificateurs + prix
- Total calculé
- Bouton "Envoyer cuisine" → sent_to_kitchen = true
- Bouton "Ajouter articles" → retour au menu

---

## 6. PAGE CUISINE — /restaurant/cuisine

Liste des commandes avec sent_to_kitchen = true ET kitchen_ready = false

Chaque ticket cuisine affiche :
- Numéro table + heure envoi
- Timer (temps écoulé depuis envoi)
  - Rouge si > 15 minutes
  - Orange si > 8 minutes
  - Vert si < 8 minutes
- Liste articles avec modificateurs
- Case à cocher par article (prêt/pas prêt)
- Bouton "Commande prête — servir"
  → kitchen_ready = true
  → Notification au serveur
  → Table passe en statut "occupee"

Sync Realtime Supabase pour mises à jour
instantanées entre appareils (tablette cuisine
et téléphone serveur).

---

## 7. PAGE ADDITION — /restaurant/addition/:tableId

Accessible depuis :
- Tap sur table en statut "addition"
- Bouton "Addition" dans commande table

Affichage :
- Infos table (numéro · couverts · serveur)
- Durée repas (heure ouverture → maintenant)
- Liste complète articles commandés + prix
- Total général

Partage addition :
- Boutons "÷ N personnes" (2 à couverts max)
- Calcul automatique par personne

Bouton "Encaisser [total] F" :
→ Ouvre le flux d'encaissement existant
→ Après encaissement :
  - table.status = 'libre'
  - table.current_order_id = null
  - table.covers = null
→ Facture PDF générée automatiquement
→ Table repasse en vert sur le plan

---

## 8. MENU RESTAURANT — CONFIGURATION

Dans Paramètres → Menu restaurant :

Section "Modificateurs" :
- Ajouter des groupes de modificateurs
  - ex: "Cuisson" → Saignant · À point · Bien cuit
  - ex: "Options" → Avec sauce · Sans sauce
  - ex: "Suppléments" → +Fromage (+500F)
- Lier chaque modificateur à un ou plusieurs produits
- Prix impact modifiable par option

---

## 9. COMMANDES À EMPORTER

Onglet "À emporter" dans la navigation restaurant.
Même flux que les commandes web existantes
mais avec order_type = 'takeaway'.
S'intègre avec le catalogue web existant
(commandes en ligne → arrive dans À emporter
avec une sonnerie).

---

## 10. CATALOGUE WEB EN MODE RESTAURANT

Si shop_type restaurant :
- Le catalogue web affiche le menu
- Organisé par catégories
- Les clients commandent à emporter
- Paiement à la réception
- La commande arrive dans "À emporter"
  avec une notification sonore

---

## PHASAGE — 4 PR

- **PR-1** → SQL + Hive boxes + type établissement dans Paramètres + plan de salle basique (tables colorées + tap pour créer commande)
- **PR-2** → Commande par table + modificateurs + envoi cuisine + ticket cuisine
- **PR-3** → Addition + partage + encaissement + libération automatique table
- **PR-4** → Catalogue web restaurant + À emporter + configuration modificateurs

**Montre le plan complet avant de commencer. Implémente PR-1 d'abord. Attends ma validation avant PR-2.**

---

## RÈGLES FINALES

- Mode boutique existant inchangé à 100%
- Tests avec les 2 modes actifs simultanément
- Zéro hardcode · AppColors · AppTextStyles
- Offline-first Hive pour tables et commandes
- Realtime Supabase sur restaurant_tables
- flutter analyze sans nouvelles erreurs
