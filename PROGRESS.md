# 📊 Progression — Audit P0 Fortress

> Snapshot du **2026-04-29** · 8/8 P0 livrés, BÊTA-ready.

---

## 1. Bilan P0 — 8/8 ✅

| # | P0 | Status | Fichier(s) clé(s) |
|---|---|---|---|
| 1 | **`getShopMembers` PostgrestException** | ✅ | `lib/core/database/app_database.dart` (utilise RPC `list_shop_employees` au lieu d'un JOIN PostgREST) |
| 2 | **Race condition stock realtime** | ✅ | `supabase/migrations/015_row_version_clock.sql` + checks `row_version` dans `_onProductChange` et `syncProducts` |
| 3 | **Ventes offline abandonnées silencieusement** | ✅ | `lib/core/database/app_database.dart` — tables critiques (`orders`/`sales`/`expenses`) jamais purgées de la queue ; payload conservé dans `sync_errors` ; getter `stuckCriticalOpsCount` |
| 4 | **Migrations 002 dupliquées** | ✅ | `002_fix_reset_all_data.sql` → `001b_fix_reset_all_data.sql` |
| 5 | **Employé suspendu peut vendre offline** | ✅ | `lib/core/database/app_database.dart` (`syncMemberships`, `canActInShop`, `getMembershipStatus`) + `lib/features/caisse/presentation/pages/payment_page.dart` |
| 6 | **Crash reporter Sentry** | ✅ | `lib/main.dart` — `SentryFlutter.init()` + `SentryWidget` wrap (config wizard ; suppression du sample exception de test) ; deps `sentry_flutter ^9.19.0` + `sentry_dart_plugin ^3.3.0` |
| 7 | **Validation stock pré-ajout panier** | ✅ | `lib/features/caisse/presentation/widgets/product_grid_widget.dart` — helper `_tryAddToCart` ; branché sur les 4 points d'ajout (`_addToCart`, `_VariantPickerSheet.itemBuilder`, `_PosProductPanel._handleTap`, `_addVariantToCart`) ; opacités rupture portées à 0.4 |
| 8 | **Steppers 48dp + contrastes WCAG** | ✅ | `cart_widget.dart` (`_QtyBtn` 28→48px, icône 14→20), `product_grid_widget.dart` (boutons + grille/liste 36→48px, icône 20→24), `app_colors.dart` (`textHint` `#9CA3AF` → `#6B7280`, contraste 3:1 → 5.5:1, WCAG AA) |

**`flutter analyze --no-pub` global : 0 error** (warnings/info pré-existants : `withOpacity` deprecated, `prefer_final_fields`, `experimental_member_use` sur `profilesSampleRate`).

---

## 2. Fichiers modifiés — session 2026-04-29

### Côté Flutter
- `lib/main.dart` — P0-6 (Sentry init wizard, retrait sample exception)
- `lib/features/caisse/presentation/widgets/product_grid_widget.dart` — P0-7 + P0-8 (helper stock + boutons +)
- `lib/features/caisse/presentation/widgets/cart_widget.dart` — P0-8 (`_QtyBtn` 48dp)
- `lib/core/theme/app_colors.dart` — P0-8 (`textHint` WCAG AA)
- `lib/features/super_admin/presentation/pages/super_admin_page.dart` — observabilité BÊTA : nouveau chip `stuck` (alerte rouge sur ops critiques bloquées) + paramètre `alert` ajouté à `_HiveChip`
- `pubspec.yaml` — P0-6 (deps Sentry, dans la session précédente)

### Côté Supabase
- `supabase/migrations/015_row_version_clock.sql` — P0-2 (à appliquer)
- `supabase/migrations/001b_fix_reset_all_data.sql` — P0-4 (renommé)
- `supabase/hotfix_018_employees.sql` — patché pour idempotence (suppression du `DROP FUNCTION (TEXT)`, remplacé par `CREATE OR REPLACE` ; `DROP (UUID) CASCADE` conservé)

### À appliquer côté Supabase Studio (ordre)
```sql
-- 1. Si pas déjà fait : migrations 011..014 (sessions précédentes)
-- 2. hotfix_018_employees.sql (RPC list_shop_employees) — version patchée
-- 3. hotfix_041_rls_critical_tables.sql (RLS _is_shop_member)
-- 4. supabase/migrations/015_row_version_clock.sql

-- Toujours pour finir
NOTIFY pgrst, 'reload schema';
```

---

## 3. Runbook BÊTA contrôlée — 1 boutique pilote

### 3.1 Pré-flight checklist (J-1)

| Check | Commande / Action | Critère OK |
|---|---|---|
| Migrations Supabase | `SELECT proname FROM pg_proc WHERE proname IN ('list_shop_employees','_is_shop_admin','_is_shop_member');` | 3 lignes |
| Realtime row_version | `SELECT column_name FROM information_schema.columns WHERE table_name='products' AND column_name='row_version';` | 1 ligne |
| RLS critiques | `SELECT polname FROM pg_policy WHERE polrelid IN ('orders'::regclass,'sales'::regclass,'expenses'::regclass);` | ≥ 3 lignes |
| Sentry projet | dashboard Sentry → projet Fortress, DSN actif | events de test reçus |
| `flutter analyze` | `flutter analyze --no-pub` | 0 error |
| Lint cible Android | `flutter build apk --debug` | build OK |

### 3.2 Build BÊTA

```bash
# Variables d'environnement de la build BÊTA
flutter build apk --release \
  --dart-define=APP_ENV=beta \
  --build-name=1.0.0-beta.1 \
  --build-number=1001
```

> Le DSN Sentry est actuellement hardcodé dans `main.dart` (config wizard). Si tu veux passer en `String.fromEnvironment('SENTRY_DSN')`, c'est un patch trivial — à faire en J+7 si tu veux durcir avant la GA.

Artefact attendu : `build/app/outputs/flutter-apk/app-release.apk`. Renomme-le en `fortress-1.0.0-beta.1.apk` avant distribution.

### 3.3 Boutique pilote retenue : **Mr Original**

Boutique créée directement dans l'app par l'owner (pas d'import depuis une autre source). État de départ vierge → idéal pour observer la queue offline et le realtime sans bruit hérité.

Critères que la boutique doit néanmoins satisfaire pendant la BÊTA :
- **Volume modéré** : viser 30–100 ventes/jour les 7 premiers jours.
- **Connectivité mixte** : au moins 1 micro-coupure/semaine pour valider l'offline-first.
- **1 admin + 1 employé minimum** : couvre le cas P0-5 (suspension d'employé).
- **Disponibilité owner** : joignable en moins d'une heure J+1 → J+7.
- **Données saines** : pas de queue offline héritée, pas de produit "fantôme" en stock négatif (vérifier après les premiers ajouts produits).

À surveiller spécifiquement sur Mr Original : comme la boutique est neuve, les premières ventes sont aussi le **premier round-trip realtime products → stock_levels**. Vérifier dans la première heure que le stock côté caissier reste cohérent avec le stock côté admin.

### 3.4 Briefing pré-installation (15 min avec l'owner)

À couvrir explicitement :
1. **Snackbar rouge "Stock insuffisant"** sur ajout au panier — comportement nouveau, attendu, c'est une protection.
2. **Boutons +/− plus gros** sur le panier et la grille produits — pas un bug, c'est volontaire (cible tactile).
3. **Contraste hint plus marqué** (placeholders dans les champs) — aussi volontaire.
4. **Caissier suspendu** : si l'owner suspend un employé via Paramètres → Employés, ce dernier ne peut **plus encaisser** même offline (jusque-là, il pouvait).
5. **Coupure réseau** : les ventes restent enregistrables, elles partent au cloud quand le réseau revient. Le badge offline en haut indique l'état.
6. **Crash reporting** : si l'app plante, un rapport part automatiquement (anonyme, pas de PII). Inutile de screenshoter.

Documents à laisser : 1 pager A4 avec les 6 points + numéro WhatsApp/téléphone support **+237 697 926 045** (joignable J+1 → J+7, fenêtre 8h–20h sauf urgence vente perdue).

### 3.5 Métriques à surveiller (Sentry + queries Supabase)

#### Sentry — vue projet Fortress
| Indicateur | Seuil OK | Seuil alerte | Seuil rollback |
|---|---|---|---|
| Events/heure | < 0.5 | 0.5 – 2 | > 2 soutenu sur 4h |
| Crash-free sessions | > 99.5% | 98 – 99.5% | < 98% |
| Erreurs `PostgrestException` non-42501 | 0 | 1–3/jour | > 3/jour |
| Erreurs auth (token refresh, login) | 0 | 1–5/jour | > 5/jour |

#### Côté app (sur le device caisse) — queue offline

⚠ La queue d'opérations offline est **locale (Hive box `offline_queue_box`)**, pas dans Supabase. Pas de query SQL possible. Procédure :

| Quoi | Où | Critère OK |
|---|---|---|
| Compteur ops en attente | écran **Super Admin → Diagnostic Hive**, chip `queue` (lit `HiveBoxes.offlineQueueBox.length`) | ≤ 5 hors période de coupure réseau ; revient à 0 en moins d'1 min après reconnexion |
| Compteur ops critiques bloquées | écran **Super Admin → Diagnostic Hive**, chip `stuck` (lit `AppDatabase.stuckCriticalOpsCount`, passe en **rouge** dès count > 0) | 0 strict — un chip rouge = vente potentiellement perdue → appel support immédiat |
| `sync_errors` (Hive box `settingsBox` clé `sync_errors`) | écran Super Admin → Diagnostic Hive (déjà affiché) | 0 entry sur 7 jours pour `table IN ('orders','sales','expenses')` |

#### Supabase — queries de santé (à exécuter J+1, J+3, J+7)

```sql
-- a) Détection conflits realtime (P0-2) — row_version monotone croissant
SELECT id, name, row_version, updated_at
  FROM products
 WHERE store_id = '<id_mr_original>'
   AND updated_at > now() - interval '24 hours'
 ORDER BY updated_at DESC
 LIMIT 30;
-- Attendu : row_version strictement croissant par produit. Si un produit
-- voit son row_version reculer, alerte rouge (race condition non corrigée).

-- b) Memberships suspendus encore actifs (P0-5)
SELECT user_id, shop_id, status, role
  FROM shop_memberships
 WHERE shop_id = '<id_mr_original>'
   AND status = 'suspended';
-- Si l'owner a suspendu quelqu'un, croiser avec Sentry pour confirmer
-- qu'aucune vente n'a été passée par cet user_id après la suspension.

-- c) Ventes encaissées sur la période (volume + santé globale)
SELECT date_trunc('day', created_at) AS jour,
       COUNT(*) AS n_orders,
       SUM(total_amount) AS ca
  FROM orders
 WHERE shop_id = '<id_mr_original>'
   AND created_at > now() - interval '7 days'
 GROUP BY jour
 ORDER BY jour DESC;

-- d) Stock négatif (sentinelle conflit / décrément double)
SELECT sl.location_id, sl.variant_id, sl.stock_qty
  FROM stock_levels sl
  JOIN stock_locations loc ON loc.id = sl.location_id
 WHERE loc.shop_id = '<id_mr_original>'
   AND sl.stock_qty < 0;
-- Attendu : 0 ligne. Si > 0, race condition stock à creuser immédiatement.
```

> Remplacer `<id_mr_original>` par l'`id` réel après création de la boutique. Récupérable via `SELECT id FROM shops WHERE name ILIKE '%Mr Original%';`.

#### Côté terrain — entretien owner J+1, J+3, J+7
- Combien de ventes encaissées depuis hier ?
- Une seule snackbar rouge "stock insuffisant" est-elle apparue à tort (alors qu'il y avait du stock) ?
- Les caissiers se plaignent-ils des nouveaux boutons (trop gros, mal placés) ?
- Une coupure réseau a-t-elle été ressentie ? Combien de temps ? Tout est-il remonté ensuite ?
- Un crash visible (app qui ferme seule) ?

### 3.6 Critères de sortie BÊTA → ouverture progressive

| Critère | Seuil minimum |
|---|---|
| Durée écoulée | ≥ 7 jours civils |
| Ventes encaissées | ≥ 100 sur la boutique pilote |
| Crash-free sessions | ≥ 99.5% sur 7 j |
| `stuckCriticalOpsCount` jamais > 0 | chip `stuck` reste à 0 sur la durée ; un passage en rouge doit être résolu en < 1h |
| 0 incident "vente perdue" | confirmé par owner + cross-check Sentry |
| 0 régression UX bloquante | retour owner explicite |

Si tous validés → ouverture phase 2 : 3 boutiques supplémentaires sous le même build.

### 3.7 Critères de rollback (stop & revert)

Déclenchent un retour à la version pré-BÊTA dans l'heure :
- Crash-free < 98% sur une fenêtre de 4 h
- > 3 ventes effectivement perdues (queue purgée à tort, RLS qui rejette en boucle, etc.)
- Une vente passée par un employé `status='suspended'` (régression P0-5)
- Conflit realtime non résolu (stock négatif visible côté caissier alors que +0 côté owner)

Procédure rollback :
```bash
# 1. Distribuer l'APK pré-BÊTA (à conserver à part dans /releases/pre-beta)
# 2. Côté Supabase : aucune migration à rollback — les changements sont
#    additifs (row_version, RPCs, RLS). Inutile de les retirer.
# 3. Demander à l'owner de réinstaller l'APK pré-BÊTA et de relancer
#    l'app. Les données Hive locales restent compatibles.
# 4. Documenter l'incident → /docs/incidents/2026-04-XX-rollback-beta.md
```

### 3.8 Calendrier proposé

| Jour | Action |
|---|---|
| J-1 | Pré-flight checklist (§3.1), build APK (§3.2), brief owner (§3.4) |
| J0 | Installation sur device caisse, smoke test (1 vente offline + 1 online), check Sentry receive |
| J+1 matin | Queries §3.5 a-d + appel owner 5 min |
| J+3 | Mêmes queries + entretien owner ~15 min |
| J+7 | Bilan complet : critères §3.6, décision GO / NO-GO phase 2 |

### 3.9 Carnet d'incidents — template

À remplir au fil de l'eau dans `/docs/incidents/2026-04-XX.md` :
```markdown
## Incident YYYY-MM-DD HH:MM
- **Symptôme** :
- **Sentry event ID** :
- **Boutique** :
- **Impact** : (vente perdue / UX dégradée / cosmétique)
- **Cause racine** :
- **Fix appliqué** :
- **Postmortem** : (créer un P1/P2 si pas un P0)
```

---

## 🔖 Repères rapides

- **`flutter analyze` global** : 0 erreur (snapshot 2026-04-29)
- **Migrations Supabase à appliquer** : `015_row_version_clock.sql` (les 011-014 + hotfix_018 patché + hotfix_041 doivent être en place)
- **Build BÊTA** : `flutter build apk --release --dart-define=APP_ENV=beta --build-name=1.0.0-beta.1`
- **Sentry DSN** : actuellement hardcodé dans `main.dart` (config wizard) — durcissement optionnel post-BÊTA
- **Tests réels boutique physique** : ⏳ à démarrer après pré-flight §3.1
