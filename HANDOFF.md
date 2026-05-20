# HANDOFF — Fortress POS

> Document de migration / reprise — destiné à être lu en premier dans un nouveau contexte Claude Code.
>
> **Date** : 2026-05-02 · **État** : production beta · **Build** : `1.0.0+1` · **Flutter** : `>=3.0.0 <4.0.0`

Fortress est une **application de point-de-vente multi-boutiques** (POS) construite en Flutter. Backend = Supabase (Auth + Postgres + Realtime + Storage). Frontend = offline-first via Hive avec sync vers Supabase. UI majoritairement en français.

🌐 **Production** : https://fortress-pos.web.app (Firebase Hosting)

---

## 1. ARCHITECTURE COMPLÈTE

### 1.1. Structure des dossiers `lib/`

```
lib/
├── main.dart                       Boot séquence (Sentry + Hive + Supabase + AppDB)
├── app.dart                        PosApp ConsumerStatefulWidget — Blocs créés une fois,
│                                   BlocProvider.value pour éviter Duplicate GlobalKey
├── core/
│   ├── config/
│   │   ├── admin_config.dart       Whitelist emails super admin
│   │   ├── supabase_config.dart    URL + anonKey Supabase + acceptInviteBaseUrl Netlify
│   │   └── supabase_client.dart
│   ├── database/
│   │   ├── app_database.dart       Singleton offline-first : Realtime + Hive + queue
│   │   └── supabase_migrations.dart Push SQL via exec_sql (chunk-based, dev only)
│   ├── di/
│   │   └── injection_container.dart Riverpod providers (repositories, use cases, blocs)
│   ├── error/                      exceptions.dart + failures.dart
│   ├── i18n/
│   │   ├── app_localizations.dart  i18n delegate FR/EN (manuel, non gen-l10n)
│   │   ├── locale_provider.dart    Riverpod state locale
│   │   └── l10n/                   Fichiers .arb (non utilisés en pratique)
│   ├── network/                    dio_client + api_endpoints (REST fallback)
│   ├── permisions/                 ⚠ typo dans le nom du dossier (à conserver)
│   │   ├── app_permissions.dart    RBAC : UserPlan + shopRole + permissions JSONB
│   │   ├── subscription_provider.dart Riverpod state plan + cache Hive
│   │   ├── user_plan.dart          enum tiers
│   │   ├── permission_guard.dart
│   │   └── admin_panel_page.dart   Page gestion utilisateurs (super admin)
│   ├── router/
│   │   ├── app_router.dart         GoRouter unique + AuthRouterNotifier
│   │   └── route_names.dart
│   ├── services/
│   │   ├── supabase_service.dart   Init + accesseurs client/auth
│   │   ├── session_service.dart    active_sessions (register, heartbeat 5min, listener kick)
│   │   ├── notification_service.dart In-app notifs Hive (50 max, dedup 60s, owner only)
│   │   ├── whatsapp_service.dart   Abstraction provider (wa.me OK, Twilio/Meta = stub)
│   │   ├── whatsapp/
│   │   │   ├── meta_direct_provider.dart  ⚠ STUB
│   │   │   └── twilio_provider.dart       ⚠ STUB
│   │   ├── storage_service.dart    Upload images (file ET bytes web) → product-images
│   │   ├── invoice_storage_service.dart   Upload facture PDF → bucket factures
│   │   ├── catalogue_storage_service.dart Upload catalogue → bucket catalogues
│   │   ├── activity_log_service.dart Logging actions métier
│   │   ├── delivery_reminder_service.dart Notifs locales (flutter_local_notifications)
│   │   ├── presence_service.dart   Realtime presence
│   │   ├── session_refresher.dart  Refresh token + retry exponentiel
│   │   ├── session_validator.dart  Validation session online/offline
│   │   ├── danger_action_service.dart Logging actions critiques
│   │   ├── stock_service.dart      Logique stock multi-emplacement
│   │   ├── deep_link_service.dart  fortress:// + universal links
│   │   ├── catalogue_pdf_builder.dart, catalogue_html_builder.dart
│   │   ├── export_service.dart
│   │   ├── device_id_service.dart  UUID v4 stable (Hive settings_box)
│   │   ├── pin_service.dart        PIN propriétaire (zone dangereuse)
│   │   └── url_shortener_service.dart
│   ├── storage/
│   │   ├── hive_boxes.dart         Box names + accessors + safe init
│   │   ├── local_storage_service.dart CRUD wrapper
│   │   └── secure_storage.dart     flutter_secure_storage (tokens / mots de passe)
│   ├── theme/
│   │   ├── app_theme.dart          ThemeData light + dark + AppSemanticColors
│   │   ├── app_colors.dart         Palette runtime-mutable
│   │   ├── theme_palette.dart      kAllPalettes + ThemePaletteNotifier
│   │   ├── theme_mode_provider.dart Light/Dark/System persisté Hive
│   │   └── app_text_styles.dart
│   ├── utils/                      currency_formatter, date_formatter, phone_formatter,
│   │                               input_validators, password_policy, country_phone_data
│   ├── validators/
│   └── widgets/                    danger_confirm_dialog, owner_pin_dialog, fortress_logo
├── features/                        Clean Architecture par feature (domain/data/presentation)
│   ├── auth/                        Login, register, reset password, accept invite
│   ├── caisse/                      Point-of-sale (panier, paiement, commandes)
│   ├── catalogue/                   Vitrine publique /catalogue/:shopId (sans auth)
│   ├── crm/                         Gestion clients
│   ├── dashboard/                   KPI dashboard boutique
│   ├── expenses/                    Dépenses opérationnelles
│   ├── finances/                    Reporting financier
│   ├── hr/                          Gestion employés (RH, permissions granulaires)
│   ├── hub_central/                 Dashboard multi-boutiques
│   ├── inventaire/                  Gestion stock complet
│   ├── parametres/                  Settings utilisateur/boutique
│   ├── shop_selector/               Sélection boutique
│   ├── subscription/                Gestion abonnements
│   └── super_admin/                 Dashboard super-admin
└── shared/
    ├── widgets/
    │   ├── adaptive_scaffold.dart   Layout responsive (sidebar desktop / drawer mobile)
    │   ├── plan_card.dart           Card affichage plan (4 tiers, partagé)
    │   ├── form_sheet.dart          showFormSheet helper + FormSheetHeader
    │   ├── app_select_menu.dart     Popup menu positionné
    │   ├── app_field, app_primary_button, app_scaffold, app_snack, app_section_card,
    │   ├── app_switch, empty_state_widget, language_switcher, etc. (~25 widgets)
    └── providers/
        └── auth_provider.dart       authStateProvider + localeProvider Riverpod
```

### 1.2. Packages utilisés (`pubspec.yaml`)

```yaml
name: fortress
description: Fortress POS — Application de gestion multi-boutiques
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  sentry_flutter: ^9.19.0
  flutter: { sdk: flutter }
  flutter_localizations: { sdk: flutter }

  # State management — DUAL STACK voulu (Riverpod = DI / Bloc = UI state)
  flutter_riverpod: ^2.5.1
  riverpod_annotation: ^2.3.5
  flutter_bloc: ^8.1.5
  bloc: ^8.1.4

  # Navigation
  go_router: ^13.2.1

  # Backend / Cloud
  supabase_flutter: ^2.8.4         # Auth + DB + Realtime + Storage
  cached_network_image: ^3.4.1

  # Network REST fallback
  dio: ^5.4.3
  http: ^1.2.1

  # Local storage offline-first
  hive_flutter: ^1.1.0
  path_provider: ^2.1.3
  path: ^1.9.0

  # Sécurité
  flutter_secure_storage: ^9.0.0
  crypto: ^3.0.3

  # i18n
  intl: ^0.20.2

  # Téléphone
  phone_numbers_parser: ^5.0.3

  # Charts
  fl_chart: ^0.68.0

  # Utilitaires
  equatable: ^2.0.5
  dartz: ^0.10.1
  json_annotation: ^4.9.0
  logger: ^2.3.0
  connectivity_plus: ^6.0.3
  url_launcher: ^6.3.0
  pdf: ^3.11.0
  printing: ^5.13.0
  share_plus: ^10.0.0
  open_filex: ^4.3.4
  shared_preferences: ^2.2.3

  # Notifications + images
  flutter_local_notifications: ^17.2.3
  timezone: ^0.9.4
  image_picker: ^1.1.2

  # Deep links
  app_links: ^6.3.2

dev_dependencies:
  sentry_dart_plugin: ^3.3.0
  flutter_test: { sdk: flutter }
  build_runner: ^2.4.11
  json_serializable: ^6.8.0
  riverpod_generator: ^2.4.0
  flutter_lints: ^4.0.0
  mocktail: ^1.0.4
  image: ^4.0.0
  flutter_launcher_icons: ^0.14.1
  flutter_native_splash: ^2.4.0
```

### 1.3. Fichiers critiques (par ordre d'importance pour la reprise)

| Fichier | Rôle |
|---|---|
| `lib/main.dart` | Boot : binding → splash conditionnel (mobile only) → Hive + Supabase + AppDB en parallèle → runApp(PosApp) → init background (Sentry + notifs + migrations) |
| `lib/app.dart` | `PosApp` ConsumerStatefulWidget. Crée `ShopSelectorBloc`/`CaisseBloc`/`HubBloc` une seule fois en `initState`. Listener AuthBloc → `AuthRouterNotifier.update()` + `SessionService.start(onKicked)`. |
| `lib/core/database/app_database.dart` | Cœur offline-first. Listeners Realtime (products/orders/clients), Hive write-through, queue offline, `_initialPullForShop`/`pullAllForShop`, hooks notifications stock + commandes. |
| `lib/core/router/app_router.dart` | `GoRouter` unique. `AuthRouterNotifier` (flag `_initialized` pour éviter redirect prématuré au refresh). Routes publiques : `/auth/*`, `/accept-invite`, `/catalogue/:shopId`. |
| `lib/core/storage/hive_boxes.dart` | Liste centralisée des boxes : products, sales, clients, orders, suppliers, receptions, incidents, stock_movements, purchase_orders, stock_arrivals, activity_logs, expenses, notifications, stock_locations, stock_levels, stock_transfers + cart, settings, offline_queue, shops, users, memberships. |
| `lib/core/services/supabase_service.dart` | Init `Supabase.initialize` + accesseurs `client` / `auth`. |
| `lib/core/services/session_service.dart` | RPC `register_session` au login, heartbeat 5min, Realtime listener sur DELETE → soft-kick + `onKicked()` callback (snack + redirect login). |
| `lib/core/services/notification_service.dart` | `NotifKind` enum (6 valeurs), Hive `notifications_box` (50 max FIFO), dedup 60s, `ValueNotifier rev` pour rebuild UI. Filtre `enabledForCurrentUser=isOwner`. |
| `lib/core/services/whatsapp_service.dart` | Façade + 3 providers (`WameProvider` actif, `TwilioProvider` stub, `MetaDirectProvider` stub). Choix par clé Hive `whatsapp_provider`. |
| `lib/core/services/storage_service.dart` | `uploadImage(File)` + `uploadImageBytes(Uint8List)` (compatible web). Bucket `product-images` public. |
| `lib/core/permisions/app_permissions.dart` | Combine `UserPlan` (tier) + `shopRole` (`owner`/`admin`/`user`) + permissions JSONB → booléens (`canEditProduct`, `canAccessCaisse`, etc.). |
| `lib/core/permisions/subscription_provider.dart` | Riverpod `subscriptionProvider`, cache plan en Hive (offline). RPC `get_user_plan`. |
| `lib/core/i18n/app_localizations.dart` | Fichier manuel (~1500 lignes) avec getters `_isFr ? 'fr' : 'en'`. **Ne pas confondre avec `flutter gen-l10n`** qui n'est pas réellement utilisé. |
| `lib/core/theme/app_theme.dart` | `AppTheme.light()` / `AppTheme.dark()`. `AppSemanticColors` extension (success/warning/danger/info/elevatedSurface/borderSubtle/trackMuted) accessibles via `theme.semantic`. |
| `lib/core/theme/theme_palette.dart` | Palettes runtime + `themePaletteProvider` Riverpod persisté Hive. |
| `lib/shared/widgets/adaptive_scaffold.dart` | Layout responsive : sidebar 190px ≥ 900px / drawer caché < 900px. `_NotifBtn` (badge cloche live) + `_CartBadgeBtn`. Active `NotificationService.enabledForCurrentUser` selon `perms.isOwner`. |
| `lib/shared/widgets/plan_card.dart` | Widget partagé pour les 4 tiers (Trial / Starter / Pro / Business). `PlanDisplay.fromMap` adapte rows Supabase + fallback `PlanLimits`. |
| `lib/shared/widgets/form_sheet.dart` | `showFormSheet<T>` helper (force `isDismissible: false` + `enableDrag: false`) + `FormSheetHeader` (titre + X). |
| `lib/features/inventaire/presentation/pages/product_form_page.dart` | Formulaire produit (4 étapes, multi-variantes, multi-images). Tous les images en `Uint8List` pour compatibilité web. |
| `lib/features/caisse/presentation/widgets/cart_widget.dart` | Panier interactif (quantités, remises, prix custom, mode e-commerce, paiements multiples). |
| `lib/features/super_admin/presentation/pages/super_admin_page.dart` | Dashboard SA : KPIs, utilisateurs, boutiques, paiements récents, plans tarifaires (utilise `PlanCard` partagé), logs. |

---

## 2. BASE DE DONNÉES SUPABASE

### 2.1. Tables principales

| Table | Description |
|---|---|
| `profiles` | Profils utilisateurs (email, name, phone, is_super_admin, prof_status, blocked_at, blocked_reason) |
| `shops` | Boutiques (owner_id, name, sector, currency, country, is_active) |
| `shop_memberships` | Membres par boutique (shop_id, user_id text, role, permissions JSONB) |
| `pending_invitations` | Invitations magic-link (invited_email, shop_id, role, token, expires_at) |
| `pending_admin_actions` | Approbations en attente (action_type, requester_id, owner_id, status, expires_at) |
| `products` | Produits (store_id, name, sku, price_buy, price_sell_pos, stock_qty, stock_min_alert, image_url, is_visible_web, is_active, variants JSONB) |
| `categories` | Catégories produits par shop |
| `clients` | Clients (store_id, name, phone, email, city, district, notes, archived_at) |
| `orders` | Commandes (shop_id, items JSONB, status, payment_method, client_id, scheduled_at, completed_at) |
| `subscriptions` | Abonnements (user_id, plan_id, billing_cycle, sub_status, started_at, expires_at, amount_paid) |
| `plans` | Plans tarifaires (name, label, price_monthly/quarterly/yearly, is_active, sort_order, max_shops, max_users_per_shop, offline_enabled, features JSONB) |
| `super_admin_whitelist` | Emails autorisés à devenir super admin |
| `suppliers` | Fournisseurs |
| `purchase_orders` + `purchase_order_items` | Bons de commande |
| `receptions` + `reception_items` | Réceptions marchandise |
| `stock_movements` | Mouvements stock (entrée/sortie/ajustement) |
| `incidents` | Incidents stock (casse, perte, vol) |
| `stock_arrivals` | Arrivages prévus |
| `stock_locations` | Emplacements physiques (warehouse / partner_depot) |
| `stock_levels` | Niveaux stock par emplacement |
| `stock_transfers` | Transferts inter-emplacements |
| `expenses` | Dépenses opérationnelles |
| `activity_logs` | Audit trail actions métier |
| `danger_action_logs` | Audit actions critiques (delete, reset, élévations) |
| `active_sessions` | Sessions multi-device (user_id, device_id, platform, last_seen) |

### 2.2. Migrations versionnées (`supabase/migrations/`)

```
001_activity_and_rpcs.sql            Bootstrap activity_logs + RPCs métier
001b_fix_reset_all_data.sql          Hotfix : remplacé par hotfix_019 (à conserver pour rétrocompat)
002_shop_admin_activity_policy.sql   RLS activity_logs
003_activity_logs_realtime.sql       Publication Realtime activity_logs
004_orders_completed_at.sql          Colonne completed_at
005_orders_fees.sql                  Frais (livraison, etc.)
006_expenses.sql                     Table expenses
007_purge_activity_logs.sql          RPC purge_shop_activity_logs
008_clients_address.sql              city/district/notes
009_shops_rls_policies.sql           Renforcement RLS shops
010_fix_purge_keep_owner.sql         Garder owner après purge
011_danger_action_logs.sql           Audit actions critiques
012_danger_action_logs_user_email.sql Email dans logs
013_keep_memberships_on_reset.sql    Préserver memberships au reset
014_unique_full_edit_admin.sql       Trigger : 1 admin full_edit max
015_row_version_clock.sql            Optimistic locking via row_version
```

### 2.3. Hotfixes (`supabase/hotfix_*.sql`)

```
hotfix_002_table_names                Renommage tables legacy
hotfix_003_where_true                 Fix policies sans WHERE
hotfix_004_invitations                Workflow magic-link (RPC create_invitation, accept_invitation)
hotfix_005_super_admin_whitelist      Bootstrap super admins
hotfix_006_reset_password             RPC reset_password_via_otp
hotfix_007_reset_shop_allow_admin     Élargir reset_shop_data à admin
hotfix_010_product_lifecycle          Workflows réception/incident
hotfix_011_stock_arrivals             Table arrivages prévus
hotfix_012_reset_lifecycle_tables     Reset cycle de vie
hotfix_013_variant_4_stocks           4 stocks par variante
hotfix_014_stock_locations            Multi-location (warehouse + dépôts)
hotfix_015_order_delivery_mode        Mode livraison sur commandes
hotfix_016_client_archived            Archivage client (soft delete)
hotfix_017_subscriptions              Bootstrap subscriptions + plans
hotfix_018_employees                  RPC create_employee + permissions JSONB
hotfix_019_purge_complete             Purge totale (remplace 001b)
hotfix_020_trial_self_signup_only     Trial = self-signup uniquement
hotfix_021_security_hardening         Verrouillage RLS critiques
hotfix_022_delete_account_cascade     RPC delete_user_account
hotfix_023_dev_switch_plan            DEV ONLY : bascule plan arbitraire
hotfix_024_roles_permissions          Permissions JSONB granulaires
hotfix_025_is_owner_column            Flag is_owner sur shop_memberships
hotfix_026_orders_created_by          Traçabilité created_by
hotfix_027_pending_admin_actions      Workflow approbation owner
hotfix_028_delete_employee_full_purge Purge complète employee
hotfix_029_orders_delivery_details    Détails livraison
hotfix_030_orders_reasons             Raisons annulation/report
hotfix_031_factures_bucket            Bucket privé `factures`
hotfix_032_catalogues_bucket          Bucket public `catalogues`
hotfix_033_catalogues_public          Politiques public read
hotfix_034_catalogues_pdf             PDF generation
hotfix_035_catalogues_cover_png       PNG cover
hotfix_036_account_deletion_fix       Fix cascade orpheline
hotfix_037_reenforce_max_admins       Trigger max admins
hotfix_038_create_employee_with_role  v2 create_employee
hotfix_039_order_mutation_perms       Trigger sur UPDATE/DELETE orders
hotfix_040_lock_exec_sql              Verrouillage exec_sql (super admin only)
hotfix_041_rls_critical_tables        Renforcement RLS tables sensibles
hotfix_042_items_rls                  RLS sur PO_items / reception_items
hotfix_043_functions_hardening        SECURITY DEFINER + search_path verrouillé
hotfix_044_active_sessions            Table + RPCs sessions simultanées
```

### 2.4. RPC functions principales

| Fonction | Rôle |
|---|---|
| `is_super_admin_email(p_email)` | Bootstrap : retourne true si email dans whitelist |
| `get_user_plan(p_user_id)` | Retourne PlanType de l'utilisateur (cached côté Hive) |
| `expire_subscriptions()` | Marque expirés les subs dépassés |
| `dev_switch_plan(p_user_id, p_new_plan)` | DEV ONLY |
| `create_invitation(...)` | Génère token magic-link + insère row pending_invitations |
| `accept_invitation(p_token)` | Convertit invitation en membership |
| `reset_shop_data(p_shop_id)` | Efface ventes/clients/stock — produits gardés |
| `delete_user_account(p_user_id)` | Cascade purge (shops + data + auth.users) |
| `purge_shop_activity_logs(p_shop_id)` | Purge logs |
| `_purge_shop_dependents(p_shop_ids[])` | Cascade interne |
| `_purge_auth_user(p_user_id)` | Fallback delete auth.users |
| `create_employee(p_shop_id, p_email, p_role, ...)` | Crée user + invite + membership + perms |
| `update_employee_permissions(p_member_id, p_perms)` | Update JSONB perms |
| `update_employee_profile(p_member_id, ...)` | Update nom/phone |
| `set_employee_status(p_member_id, p_active)` | Soft delete |
| `delete_employee(p_member_id)` | Purge complète |
| `list_shop_employees(p_shop_id)` | Liste employees + perms |
| `request_admin_action(p_shop_id, p_action_type, ...)` | Demande approbation owner |
| `approve_admin_action(p_action_id)` | Owner approuve |
| `reject_admin_action(p_action_id, p_reason)` | Owner rejette |
| `expire_pending_admin_actions()` | Cron : marque expirés |
| `register_session(p_device_id, p_platform, p_user_agent)` | Insert/upsert session + cleanup |
| `heartbeat_session(p_device_id)` | Update last_seen |
| `revoke_session(p_device_id)` | Logout volontaire |
| `revoke_other_sessions(p_keep_device_id)` | Logout autres devices |
| `list_my_sessions()` | Lister sessions du user |
| `_session_limit(p_user_id)` | Helper : limite selon rôle (5/3/2/1) |
| `is_owner_online(p_shop_id)` | Heartbeat presence |
| `update_my_last_seen()` | Heartbeat presence |
| `_is_shop_admin(p_shop_id)` | Helper RLS |
| `_is_shop_member(p_shop_id)` | Helper RLS |
| `_is_super_admin()` | Helper RLS |
| `user_shop_ids()` | Helper RLS — UUIDs des boutiques accessibles |
| `user_owned_shop_ids()` | Helper RLS — UUIDs des boutiques possédées |
| `enforce_max_admins()` (TRIGGER) | Max 1 admin "full_edit" par shop |
| `enforce_order_mutation_perms()` (TRIGGER) | Vérifier perms avant mutation order |
| `bump_row_version()` (TRIGGER) | Optimistic locking |
| `apply_super_admin_whitelist()` (TRIGGER) | Sync auto whitelist → is_super_admin |
| `protect_owner_delete()` (TRIGGER) | Empêcher suppression owner |
| `exec_sql(sql)` | super_admin uniquement (lockdown hotfix_040) |

### 2.5. Politiques RLS importantes

| Politique | Table | Règle |
|---|---|---|
| `shops_select` | shops | `owner_id = auth.uid() OR id IN user_shop_ids()` |
| `shops_insert/update/delete` | shops | owner only (delete) ou admin |
| `products_*` | products | `store_id IN user_shop_ids()` + perms granulaires (canEditProduct) |
| `orders_*` | orders | `shop_id IN user_shop_ids()` + trigger `enforce_order_mutation_perms` |
| `clients_*` | clients | `store_id IN user_shop_ids()` |
| `profiles_select` | profiles | `id = auth.uid() OR is_super_admin` |
| `profiles_update` | profiles | `id = auth.uid()` (self only) |
| `shop_memberships_*` | shop_memberships | Read shop_id IN user_shop_ids OR self ; write avec triggers |
| `subs_select/write` | subscriptions | `user_id = auth.uid() OR is_super_admin` |
| `plans_select` | plans | `true` (public) |
| `active_sessions_self_select` | active_sessions | `user_id = auth.uid()` |
| `pending_actions_no_direct_write` | pending_admin_actions | `false` (write via RPC only) |
| `factures_*` | storage.objects | `owner = auth.uid()` (4 policies upload/read/update/delete) |
| `catalogues_*` | storage.objects | `metadata.shop_id IN user_shop_ids()` |
| `pending_invitations_self_read` | pending_invitations | `invited_email = auth.email()` |

---

## 3. FONCTIONNALITÉS IMPLÉMENTÉES

### 3.1. Authentification & gestion des comptes

| Feature | Statut |
|---|---|
| Login / Register | ✅ |
| Reset password OTP (Supabase recovery flow) | ✅ |
| Accept invite via magic-link | ✅ |
| Refresh token automatique avec retry exponentiel | ✅ |
| Persistance session navigateur (refresh navigateur) | ✅ — via `AuthCheckRequested` au boot |
| Multi-session control par rôle (owner=3 / admin=2 / user=1 / SA=5) | ✅ |
| Soft-kick realtime quand session révoquée par autre device | ✅ |
| Page Sessions actives (Paramètres → Sécurité) | ✅ |
| PIN propriétaire (zone dangereuse) | ✅ |
| Suppression de compte 3 étapes | ✅ |

### 3.2. Multi-boutiques

| Feature | Statut |
|---|---|
| Création boutique | ✅ |
| Sélecteur boutiques (responsive 2 cols mobile) | ✅ |
| Membres par boutique avec rôles | ✅ |
| Permissions granulaires JSONB | ✅ |
| Workflow approbation owner pour actions critiques | ✅ |
| Boutique unique → skip shop-selector → dashboard direct | ✅ |

### 3.3. Inventaire / Produits

| Feature | Statut |
|---|---|
| CRUD produits avec multi-variantes | ✅ |
| Multi-images par produit + par variante | ✅ — Uint8List bytes (compatible web) |
| Catégories / Marques / Unités custom (avec rename/delete) | ✅ |
| Stock multi-location (warehouse + dépôts) | ✅ |
| Mouvements stock + journal | ✅ |
| Incidents (casse / perte / vol) | ✅ |
| Bons de commande fournisseur | ✅ |
| Réceptions marchandise | ✅ |
| Transferts inter-emplacements | ✅ |
| Catalogue WhatsApp (PDF export + share) | ✅ |
| Image picker compatible web (Uint8List + uploadImageBytes) | ✅ |
| Crop centré 1.2× sur grille inventaire desktop uniquement | ✅ |

### 3.4. Caisse / Vente

| Feature | Statut |
|---|---|
| Panier interactif (qty, remises, prix custom) | ✅ |
| Variantes : sélection produit avec popup bottom sheet | ✅ |
| Mode e-commerce (livraison + adresse) | ✅ |
| Paiements multiples par commande | ✅ |
| Statuts commande : scheduled / processing / completed / cancelled / refused | ✅ |
| Génération facture PDF + upload Supabase Storage | ✅ |
| Envoi facture WhatsApp (wa.me + URL signée 30j) | ✅ |
| Bouton "Relancer le client" (scheduled/processing) | ✅ |
| Filtres + tri commandes | ✅ |
| Filtres + tri produits sur grille caisse (popup positionné) | ✅ |
| Grille produits responsive (mobile 2 col, tablette 3, desktop 5+) | ✅ |
| Panier desktop 380px largeur | ✅ |

### 3.5. CRM / Clients

| Feature | Statut |
|---|---|
| CRUD clients | ✅ |
| Autocomplete villes / quartiers | ✅ |
| Téléphone international | ✅ |
| Bouton WhatsApp message libre | ✅ |
| Bouton "Envoyer le catalogue" (lien public) | ✅ |
| Archivage client (soft delete) | ✅ |
| Détail client + historique commandes | ✅ |

### 3.6. Catalogue public

| Feature | Statut |
|---|---|
| Page publique `/catalogue/:shopId` (sans auth) | ✅ |
| Filtre `is_visible_web=true` + `is_active=true` | ✅ |
| Grille responsive 2/3 colonnes | ✅ |
| Filtre par catégorie | ✅ |
| Bouton "Commander" → wa.me boutique | ✅ |

### 3.7. Finances / Reporting

| Feature | Statut |
|---|---|
| Dashboard KPIs (CA, marges, panier moyen) | ✅ |
| Graphiques fl_chart | ✅ |
| Breakdown paiements | ✅ |
| Hub central multi-boutiques | ✅ |

### 3.8. Notifications

| Feature | Statut |
|---|---|
| Notifications in-app owner-only | ✅ |
| 6 triggers : stockLow/Out, orderNew/Completed/Cancelled/Rejected | ✅ |
| Hive box 50 entries FIFO + dedup 60s | ✅ |
| Badge live cloche topbar + panel déroulant | ✅ |
| Notifications locales rappels livraison (flutter_local_notifications) | ✅ |
| Notifications externes (push FCM / Twilio / Meta) | 🟡 — providers stubs en place |

### 3.9. Super admin

| Feature | Statut |
|---|---|
| Dashboard SA (KPIs globaux, paiements récents) | ✅ |
| Gestion utilisateurs + blocage | ✅ |
| Gestion abonnements + reset password | ✅ |
| Gestion plans tarifaires (`PlanCard` partagé) | ✅ |
| Logs activité globaux | ✅ |
| Filtre `is_super_admin=false` sur listes utilisateurs/paiements | ✅ |
| Bouton "+ Ajouter un plan" | 🟡 — UI seulement, pas de RPC create_plan |

### 3.10. Personnalisation

| Feature | Statut |
|---|---|
| 5 palettes couleurs runtime | ✅ |
| Light / Dark / System theme | ✅ — persisté Hive |
| Locale FR / EN | ✅ |
| Splash screen web (HTML inline + flutter-first-frame) | ✅ |
| Splash Flutter mobile uniquement (skip sur web) | ✅ |

### 3.11. Bugs connus / TODO restants

**Bugs restants (non bloquants)** :
- `flutter analyze` : 0 erreurs, **145 warnings**, ~750 infos (majoritairement `withOpacity` deprecated, imports inutiles, `prefer_const_constructors`).
- Sentry capture parfois "Script error. at ?:0:0" sur web (cross-origin, faux positif).
- `web/index.html` est aujourd'hui le template Flutter (déjà restauré). `DEPLOYMENT.md` mentionne encore l'ancienne landing page Netlify — doc obsolète à mettre à jour.
- `supabase/migrations/001b_fix_reset_all_data.sql` est conservé pour rétrocompat mais remplacé fonctionnellement par `hotfix_019`.
- 2 FK doublons côté Supabase entre `subscriptions` et `plans` (`subs_plan_fk` + `subscriptions_plan_id_fkey`) — code utilise `plans!subscriptions_plan_id_fkey(...)` explicite. Cleanup SQL recommandé : `DROP CONSTRAINT subs_plan_fk;` + `subs_user_fk;`.

**TODO marqués dans le code** :
- `lib/core/services/whatsapp/twilio_provider.dart` : 3 TODO — POST messages.json, sendFile, config injection.
- `lib/core/services/whatsapp/meta_direct_provider.dart` : 3 TODO — POST messages, document, config.
- `lib/features/subscription/domain/models/plan_type.dart:28` : Brancher intégration WhatsApp automatique quand `whatsappAuto` feature activable.
- `lib/features/subscription/presentation/pages/subscription_page.dart` : 2 TODO — bouton WhatsApp pré-rempli.

**Features non implémentées (futur)** :
- Envoi externe via Twilio / Meta Direct (stubs en place).
- Pull-to-refresh manquant sur quelques pages (caisse onglet Principal, finances).
- Action "Ajouter un plan" UI sans RPC backend (`create_plan` à créer côté SQL).
- Migration SQL pour table `notifications` côté Supabase (actuellement local-only).
- WCAG : zéro `Semantics` widgets ajoutés.
- Service worker PWA (manifest présent mais pas de SW custom).
- Re-uploader images existantes en haute résolution si pixellisation perçue.

---

## 4. CONFIGURATION

### 4.1. Variables / clés (hardcodées dans le code)

| Service | Valeur | Fichier |
|---|---|---|
| **Supabase URL** | `https://hyxvussnlnvbkalqzovb.supabase.co` | `lib/core/config/supabase_config.dart` |
| **Supabase anon key** | `sb_publishable_R7Jg-Tx4WRMkVI5TMC4jpQ_p8NHq4bd` | `lib/core/config/supabase_config.dart` |
| **Sentry DSN** | `https://5e24ab164b4eecefc3756bd5aa3b902c@o4511301758222336.ingest.de.sentry.io/4511301770477648` | `lib/main.dart` |
| **Sentry org/project** | `fortresspos / flutter` | `pubspec.yaml` (sentry block) |
| **Sentry properties** | `sentry.properties` | racine projet (jamais commité, `.gitignore`) |
| **Netlify (Accept Invite)** | `https://stately-sunshine-3593ef.netlify.app/accept-invite` | `lib/core/config/supabase_config.dart` |
| **Firebase Hosting** | `https://fortress-pos.web.app` | `firebase.json` + `deploy.ps1` |
| **Domain Netlify (App Links)** | `stately-sunshine-3593ef.netlify.app` | `web/.well-known/*`, `lib/core/services/deep_link_service.dart`, `android/app/src/main/AndroidManifest.xml` |
| **Storage Buckets** | `product-images` (public), `factures` (privé), `catalogues` (public) | `lib/core/services/storage_service.dart`, `invoice_storage_service.dart`, `catalogue_storage_service.dart` |

### 4.2. Fichiers de config par plateforme

- `firebase.json` — Hosting config (rewrites `**` → `/index.html` pour SPA).
- `web/manifest.json` — PWA manifest (icons 192/512 + maskable, `theme-color: #534AB7`).
- `web/index.html` — Template Flutter + splash HTML inline (logo + spinner CSS).
- `web/.well-known/assetlinks.json` + `apple-app-site-association` — App Links / Universal Links (mobile dormant).
- `android/app/build.gradle.kts` — `applicationId = com.example.fortress` ⚠ **à corriger en `com.fortress.pos`** avant publication Play Store.
- `ios/Runner/Runner.entitlements` — Associated Domains.
- `pubspec.yaml` blocks `flutter_launcher_icons` + `flutter_native_splash`.

### 4.3. URLs importantes

- Production web : `https://fortress-pos.web.app`
- Console Firebase : `https://console.firebase.google.com/project/fortress-pos/overview`
- Sentry : `https://fortresspos.sentry.io/projects/flutter/`
- Supabase Dashboard : `https://supabase.com/dashboard/project/hyxvussnlnvbkalqzovb`
- Catalogue public : `https://fortress-pos.web.app/#/catalogue/<shopId>`

---

## 5. DÉCISIONS TECHNIQUES IMPORTANTES

### 5.1. State management — dual stack VOULU

**Riverpod** = container DI + état app-wide (auth, subscription, current shop, locale, theme, palette).
**flutter_bloc** = état UI par feature (auth, caisse, shop_selector, hub, inventaire, crm).

Les Blocs sont **construits via Riverpod providers** (`injection_container.dart`), puis injectés via `BlocProvider.value`. Dans `app.dart` : `ShopSelectorBloc` / `CaisseBloc` / `HubBloc` créés **une seule fois** dans `initState` du `_PosAppState` pour éviter `Duplicate GlobalKey` au rebuild.

### 5.2. Routing

`go_router` 13.2 — un seul `appRouterProvider`. `AuthRouterNotifier` listenable :
- Flag `_initialized` pour empêcher redirect prématuré au refresh navigateur (sinon utilisateur connecté envoyé sur `/login` car AuthBloc encore en `AuthInitial`).
- `BlocListener<AuthBloc>` dans `app.dart` propage les états → `notifier.update(state)`.
- Routes publiques : `/auth/*`, `/accept-invite`, `/catalogue/:shopId`.
- Sub-pages calculent leur back via `_smartBack` (pop si stack, sinon parent route calculée).

### 5.3. Offline-first via Hive + AppDatabase

`AppDatabase` est un singleton :
- Boot : `Hive.init` puis `Supabase.init` (peut échouer = mode offline) puis `AppDatabase.init()` qui écoute `connectivity_plus`.
- Toutes écritures vont en Hive immédiatement ; si offline → append à `offline_queue_box`.
- À la reconnexion : `_onNetworkRestored` flush la queue + re-sync chaque shop.
- Lectures : Hive d'abord. Realtime channels (`subscribeToShop`) push remote → Hive + `addListener` notifiant les widgets.
- **Toute box** doit être déclarée dans `HiveBoxes` (pas de string hardcodé). Ouverture défensive avec retry + fallback in-memory.

### 5.4. Permissions / Subscription

`AppPermissions` combine 3 sources :
1. **`UserPlan`** (tier d'abonnement : free/basic/pro/business).
2. **`shopRole`** (`owner` / `admin` / `user` / `null`).
3. **Permissions JSONB** custom (`canEditProduct`, `canCancelSale`, `canDoFullShopEdit`, etc. — granulaires depuis hotfix_024).

Gates UI + use-case via les booléens `canX` du `permissions(shopId)` provider, jamais via `role.toString()` direct.

### 5.5. i18n

⚠ **Le projet utilise un fichier i18n manuel** (`lib/core/i18n/app_localizations.dart` ~1500 lignes avec getters `_isFr ? 'fr' : 'en'`). Le bloc `flutter: { generate: true }` du pubspec et les `.arb` dans `lib/core/i18n/l10n/` ne sont **pas réellement utilisés**. Pour ajouter une clé : éditer `app_localizations.dart` directement.

### 5.6. Lints

`analysis_options.yaml` = `flutter_lints` + règles : `prefer_const_constructors`, `prefer_const_widgets`, `use_key_in_widget_constructors`, `avoid_print`. Toujours utiliser `debugPrint` (jamais `print`).

### 5.7. Web spécifique

- Pas de `dart:io File` côté images : utiliser `Uint8List` + `Image.memory(bytes)` + `StorageService.uploadImageBytes`.
- `image_picker` web peut ignorer `imageQuality` / `maxWidth` : éviter ces paramètres.
- `FilterQuality.high` + `cacheWidth/Height = size × DPR` pour images haute résolution sans flou.
- Splash HTML dans `web/index.html` masqué sur évènement `flutter-first-frame` (fallback timeout 8s).
- Sur web `kIsWeb`, on **skip** le `_BootSplashApp` Flutter dans `main.dart` (sinon double splash).
- Routes desktop : largeur ≥ 900px → sidebar fixe. Sinon drawer caché. Critère **uniquement largeur fenêtre** (pas OS).

### 5.8. Conventions de code

- **Commentaires `//` en français** (UI strings + comments).
- Pas de `print` → `debugPrint`.
- Texte en dur **interdit** : tout via `app_localizations.dart` (`context.l10n.xxx`).
- Couleurs : utiliser `Theme.of(context).colorScheme.*`, `theme.semantic.*`, `AppColors.primary*` (palette runtime). Hex `Color(0xFF...)` autorisé uniquement pour cas explicitement neutres ou couleurs de marque (ex Business `#1A1A2E`).
- Form sheets : utiliser `showFormSheet()` + `FormSheetHeader` (force X close + non-dismissible).
- Permissions : passer par `permissionsProvider(shopId)` jamais via role direct.
- Tests : `flutter test` (peu de tests actuellement, à étoffer).

### 5.9. Points d'attention pour la reprise

1. **Le dossier `lib/core/permisions/` a une typo** (`permisions` sans le second `s`). À ne pas "corriger" automatiquement — beaucoup d'imports en dépendent.
2. **`AppDatabase` singleton très central** — toute nouvelle table métier doit y être branchée (sync + listener Realtime + Hive box).
3. **Provider WhatsApp** par défaut = `WameProvider` (URL `wa.me`). Twilio + Meta sont des **stubs** (TODO).
4. **`exec_sql` lockdown** depuis `hotfix_040` : super_admin uniquement. Les migrations auto au boot via `SupabaseMigrations.runIfNeeded()` peuvent échouer pour les non-SA — comportement attendu.
5. **Sessions simultanées** : le code Flutter assume que `hotfix_044_active_sessions.sql` est appliqué en base. Sans ça, les RPCs `register_session` échouent silencieusement (try/catch + debugPrint).
6. **Web et image_picker** : toujours utiliser `Uint8List` (jamais `dart:io File`).
7. **Profile super admin** : créer manuellement dans Supabase nécessite `email_confirmed_at = now()` + insertion dans `profiles` + `is_super_admin = true`. Sinon login échoue avec "Invalid credentials".
8. **Filtre `is_super_admin=false`** doit être appliqué partout où on liste les utilisateurs / abonnements.

---

## 6. ÉTAT DES BUILDS

### 6.1. Dernier `flutter analyze`

```
903 issues found.
  - 0 errors
  - 145 warnings (majoritairement unused_import, unused_local_variable, unnecessary_cast)
  - ~750 infos (withOpacity deprecated, prefer_const_constructors)
```

→ **Pas d'erreurs bloquantes**. Les warnings sont quasi tous antérieurs au sprint actuel et concernent du code legacy (`super_admin_page.dart`, `inventaire_page.dart`).

### 6.2. Plateformes supportées

| Plateforme | État | Notes |
|---|---|---|
| **Web** | ✅ Production | Firebase Hosting `fortress-pos.web.app`. Cible principale actuelle. |
| **Android** | 🟡 Configuré, dormant | `applicationId = com.example.fortress` à corriger avant Play Store. App Links pré-configurés sur domaine Netlify. |
| **iOS** | 🟡 Configuré, dormant | `Runner.entitlements` créé, Associated Domains à activer dans Xcode. Team ID à renseigner. |
| **Windows / macOS / Linux** | 🟡 Dossiers présents | `flutter build windows/macos/linux` fonctionne mais non testé en pratique. |

### 6.3. Commandes de build

```bash
# Dev
flutter pub get
flutter run -d chrome           # web local
flutter run                     # mobile (device/émulateur)

# Codegen (riverpod_generator + json_serializable)
dart run build_runner build --delete-conflicting-outputs
dart run build_runner watch --delete-conflicting-outputs

# Lint + tests
flutter analyze
flutter test                                  # tous
flutter test test/unit/login_usecase_test.dart  # un fichier
flutter test --name "substring"               # filtre

# Build production
flutter build web --release           # → build/web/
flutter build apk --release           # → build/app/outputs/flutter-apk/
flutter build appbundle --release     # → build/app/outputs/bundle/
flutter build ipa --release           # → build/ios/ipa/ (macOS only)
flutter build windows --release       # → build/windows/x64/runner/Release/

# Régénération assets
dart run flutter_launcher_icons       # icons Android/iOS/Web
dart run flutter_native_splash:create # splash mobile
dart run tools/generate_logos.dart    # logos PNG depuis SVG

# Déploiement web (Windows PowerShell)
.\deploy.ps1                          # build web release + firebase deploy
# OU directement :
firebase deploy --only hosting
```

### 6.4. Pré-requis production avant publication mobile

- [ ] Renommer `applicationId` Android : `com.example.fortress` → `com.fortress.pos`.
- [ ] Créer keystore Android + enregistrer SHA-256 dans `web/.well-known/assetlinks.json`.
- [ ] Renseigner Apple Team ID dans `web/.well-known/apple-app-site-association`.
- [ ] Activer Associated Domains dans Xcode pour iOS.
- [ ] Activer Play App Signing (recommandé).
- [ ] Bump `version: 1.0.0+1` dans `pubspec.yaml` à chaque release.

---

## 7. ÉTAT GIT ACTUEL

```
Branch : main
Recent commits :
  53647f2 Add Supabase hotfixes 042 and 043
  a3927cb ci: switch from GitHub Pages to Firebase Hosting
  576a26f feat(web): set up GitHub Pages deployment via Actions
  46bda0b chore: gitignore sentry-wizard.exe and .sentry-native runtime data
  06f2b3d Remove build folder
```

Modifications **non commitées** (à la date du HANDOFF) — incluent toutes les features récentes :
- Splash screen web + dark mode + sessions simultanées + page catalogue + notifications + plan card refonte + filtres super admin, etc.

🚀 **Bon pour reprise.** Lire en priorité dans l'ordre :
1. `CLAUDE.md` — instructions projet (court).
2. Ce `HANDOFF.md`.
3. `lib/main.dart` — séquence boot.
4. `lib/app.dart` — wiring des providers/blocs.
5. `lib/core/database/app_database.dart` — sync/realtime/queue offline.
6. `lib/core/router/app_router.dart` — guards + redirects.
