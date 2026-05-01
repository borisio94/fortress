# Fortress POS — Handoff Technique

> Document de passation exhaustif couvrant tout le travail effectué sur le projet.
> À fournir intégralement à une IA ou un développeur pour reprendre le travail.

---

## 1. Vue d'ensemble du projet

**Fortress POS** est une application Flutter multi-boutiques de point de vente. Backend Supabase (Auth + Postgres + Realtime + Storage), stockage local Hive (offline-first).

- **SDK Dart** : `>=3.0.0 <4.0.0`
- **UI** : français par défaut, bilingue FR/EN
- **Architecture** : Clean Architecture par feature + dual state (Riverpod DI + flutter_bloc UI)

---

## 2. Fichiers créés durant cette session

### Nouvelles pages paramètres
| Fichier | Rôle |
|---------|------|
| `lib/features/parametres/presentation/pages/caisse_config_page.dart` | Config caisse : reçu, TVA, préfixe commande, raccourcis |
| `lib/features/parametres/presentation/pages/notifications_page.dart` | Switches alertes stock, ventes, récap quotidien, son/vibration |
| `lib/features/parametres/presentation/pages/whatsapp_page.dart` | WhatsApp Business : numéro, template message, envoi reçu/promo |
| `lib/features/parametres/presentation/pages/payments_page.dart` | 7 méthodes de paiement avec comptes associés + méthode par défaut |
| `lib/features/parametres/presentation/pages/theme_page.dart` | Sélection de thème avec grille responsive de palettes + mini-mockup UI |
| `lib/features/parametres/presentation/widgets/settings_widgets.dart` | Widgets partagés : SettingsSectionCard, SettingsField, SettingsSwitchTile, ReadOnlyBanner |
| `lib/features/parametres/data/shop_settings_store.dart` | Helper Hive pour settings scopés par shopId |

### Dashboard
| Fichier | Rôle |
|---------|------|
| `lib/features/dashboard/data/dashboard_providers.dart` | Provider Riverpod central : DashData, DashPeriod, DashRange, TopProd, RecentTx, dashDataProvider, dashSignalProvider |

### Thème
| Fichier | Rôle |
|---------|------|
| `lib/core/theme/theme_palette.dart` | 8 palettes de couleurs (ThemePalette) + themePaletteProvider + persistance SharedPreferences |

### Supabase
| Fichier | Rôle |
|---------|------|
| `supabase/migrations/002_fix_reset_all_data.sql` | Fix RPC reset_all_data : retourne JSONB, OWNER postgres, log auth_error |
| `supabase/functions/reset-platform/index.ts` | Edge Function avec service_role_key pour supprimer auth.users (fallback si RPC échoue) |

---

## 3. Fichiers modifiés (et pourquoi)

### Core

**`lib/core/theme/app_colors.dart`** — REFONTE MAJEURE
- `primary`, `primaryLight`, `primaryDark`, `primarySurface` transformés de `static const` en `static Color` (getters vers des champs mutables)
- Nouvelle méthode `applyPalette(ThemePalette p)` met à jour les couleurs runtime
- Les couleurs fixes (error, warning, textes, surfaces) restent `const`
- **Impact** : 19 sites `const` dans super_admin_page.dart et parametres_page.dart corrigés (retrait du `const`)

**`lib/core/theme/app_theme.dart`**
- `light()` et `dark()` acceptent un paramètre optionnel `ThemePalette? palette`
- Toutes les refs `AppColors.primary*` dans le ThemeData remplacées par `p.primary*`
- Le ColorScheme, les widgets Material (Switch, Checkbox, ElevatedButton, TextField focus, DatePicker, TimePicker, SegmentedButton, NavigationBar) suivent la palette

**`lib/app.dart`**
- Watch `themePaletteProvider` + appel `AppColors.applyPalette(palette)` avant le build
- `AppTheme.light(palette: palette)` passé au MaterialApp

**`lib/core/i18n/app_localizations.dart`** — ~120 clés ajoutées
- Paramètres : `paramTheme`, `paramThemeHint`, `paramThemeSubtitle`, `paramBoutiqueSubtitle`, `paramCaisseSubtitle`, `paramEmployesSubtitle`, `paramReadOnly`, etc.
- Rôles : `roleSuperAdmin`, `roleAdmin`, `roleEmployee`
- Permissions : `permissionDenied`, `permissionDeniedDetails`, `lockedBadge`
- Config caisse : `caisseConfigTitle`, `caisseReceipt`, `caisseTaxEnabled`, `caisseOrderPrefix`, etc.
- Notifications : `notifsTitle`, `notifsStockLow`, `notifsBigSale`, `notifsDaily`, etc.
- WhatsApp : `whatsappTitle`, `whatsappEnabled`, `whatsappNumber`, `whatsappTemplate`, etc.
- Paiements : `paymentsTitle`, `paymentCash`, `paymentMobileMoney`, `paymentCard`, etc.
- Profil : `profileTitle`, `profileName`, `profileChangePassword`, etc.
- Dashboard : `dashChartSales`, `dashChartProfit`, `dashChartLoss`, `dashNoSalesYet`, `dashNewProducts`, `dashStockOk`, `dashLoss`, `dashProfit`, etc.
- Commun : `commonSave`, `commonCancel`, `commonSaved`, `commonError`, `commonLoading`

**`lib/core/router/app_router.dart`**
- Import Supabase + AppDatabase pour sync memberships au login
- `AuthRouterNotifier.update()` : charge plan + memberships en `Future.wait` (plus de race condition)
- Redirect CAS 2 : vérifie `shopRolesMapProvider.isNotEmpty` avant d'appliquer le paywall (fix invité sans plan)
- Logout : clear `shopRolesMapProvider`, `currentShopProvider.clearShop()`, `AppDatabase.notifyAllChanged()`
- Nouvelle méthode `_syncMemberships(Ref ref)` avec fallback Hive
- 5 nouvelles routes : `/parametres/caisse`, `/parametres/notifications`, `/parametres/whatsapp`, `/parametres/payments`, `/parametres/theme`

**`lib/core/router/route_names.dart`**
- Ajouté : `caisseConfigPage`, `notificationsPage`, `whatsappPage`, `paymentsPage`, `themePage`

**`lib/core/database/app_database.dart`**
- `saveProduct()` : ajout `_notify('products', p.storeId!)` après write Hive
- `deleteProduct()` : lecture shopId avant delete + `_notify`
- `syncProducts()` : ajout `_notify('products', shopId)` en fin de sync
- `syncOrders()` : ajout `_notify('orders', shopId)` en fin de sync
- `flushOfflineQueue()` : ajout `notifyAllChanged()` après flush réussi
- `_supabaseToProduct()` : lecture `created_at` depuis Supabase
- Nouvelles méthodes publiques : `notifyOrderChange(shopId)`, `notifyProductChange(shopId)`, `notifyAllChanged()`
- `notifyAllChanged()` : scanne les boxes pour extraire les shopIds, utilise `_all` comme sentinelle si vide

**`lib/core/storage/local_storage_service.dart`**
- `_productToMap()` : ajout `created_at`
- `_productFromMap()` : lecture `created_at` (compat String/DateTime)

**`lib/core/storage/hive_boxes.dart`** — inchangé (la structure existe déjà)

**`lib/core/permisions/subscription_provider.dart`**
- `_shopRolesMapProvider` renommé en `shopRolesMapProvider` (public, utilisé par le router)

### Features

**`lib/features/inventaire/domain/entities/product.dart`**
- Ajout `final DateTime? createdAt` + propagation dans constructor et copyWith

**`lib/features/inventaire/presentation/pages/inventaire_page.dart`**
- `_ProductImage` : refonte complète avec gradient coloré + initiales quand pas d'image, loading skeleton pendant download, fallback icône
- `_onRealtimeChange` : reset `_page = 1` et clear filtres catégorie/marque pour que le nouveau produit soit toujours visible
- Bouton ajout AppBar : carré 36×36 arrondi, fond `AppColors.primary`, icône + blanche centrée

**`lib/features/dashboard/presentattion/pages/dashboard_page.dart`** — REFONTE MAJEURE
- Graphique : `_SalesChart` (barres) → `_SalesLineChart` (fl_chart LineChart, 3 séries : ventes/bénéfices/pertes, tooltip, légende, courbes lissées, gradient sous les courbes)
- KPIs : branchés sur `dashDataProvider` (vraies données Hive), plus de mock
- Cards cliquables : chaque KPI navigue vers la page correspondante (rapports, caisse, CRM)
- Card Pertes : affichée seulement si > 0, en rouge, distincte de Bénéfices
- `_TopProductsCard` : médailles or/argent/bronze, barre de progression, quantité + CA
- `_RecentTxCard` : vrais dernières ventes, icônes par méthode de paiement, temps relatif, badge annulée
- `_InventoryAlertsCard` : vrais produits en stock faible, bouton "Commander" vers le produit
- `_NewProductsCard` : produits créés < 72h, avec image/initiales, temps relatif, prix
- `_DashEmpty` : composant empty state réutilisable
- Listener `AppDatabase.addListener` dans initState + signal bump en `addPostFrameCallback` pour forcer refresh au montage
- Import `fl_chart`

**`lib/features/parametres/presentation/pages/parametres_page.dart`**
- Import `HapticFeedback`
- `_Tile` : ajout `locked` (bool) — cadenas + grisé + snackbar "Accès non autorisé" au tap
- Tous les onglets visibles pour tous les rôles (plus masqués conditionnellement)
- Intégrations : visibles pour tous mais verrouillées si pas admin
- `_ProfileHeader` : badge de rôle coloré (Super Admin jaune, Admin vert, Employé bleu)
- `_DangerSection` : Reset données verrouillé pour non-admins
- Toutes les subtitles internationalisées (plus de chaînes FR hardcodées)
- Tile "Thème" ajouté dans la section Préférences
- Reset app : clear complet de TOUTES les boxes Hive + `notifyAllChanged()`

**`lib/features/parametres/presentation/pages/user_profile_page.dart`** — REFONTE COMPLÈTE
- Était un stub de 16 lignes → maintenant page complète avec avatar, édition nom/téléphone via Supabase, changement mot de passe avec ré-authentification

**`lib/features/parametres/presentation/pages/currency_page.dart`** — REFONTE COMPLÈTE
- 8 devises avec symboles, sélection radio, persistance Hive, ListView.builder, feedback haptique

**`lib/features/parametres/presentation/pages/shop_settings_page.dart`**
- Bouton invitation : `ElevatedButton` → `AppPrimaryButton` avec icône send

**`lib/features/caisse/presentation/widgets/product_grid_widget.dart`**
- Nouveau widget `_ProductImageSmart` : détecte URL HTTP vs chemin local → `Image.network` ou `Image.file`
- Appliqué dans : `_ProductCard`, `_PosProductTile`, header `_VariantPickerSheet`, miniatures variantes
- Ombres/icônes : `Color(0xFF6C3FC7)` hardcodé → `AppColors.primary`
- Import `dart:io`

**`lib/features/caisse/data/repositories/sale_local_datasource.dart`**
- `saveOrder()` : items Hive incluent maintenant `price_buy`, `custom_price`, `variant_name`, `product_name` (clés longues)
- `saveOrder()` : appel `AppDatabase.notifyOrderChange(shopId)` après write
- `updateOrder()` : même structure items + notify
- `updateOrderStatus()` : ajout `notifyOrderChange(shopId)`
- `deleteOrder()` : lecture shopId avant delete + notify
- `_itemToMap()` : inclut `price_buy`, `custom_price`, `variant_name`, clés longues
- `_mapToSale()` : lecture `priceBuy`, `customPrice` depuis items Hive (rétrocompat clés courtes)

**`lib/features/caisse/data/repositories/sale_repository_impl.dart`**
- `_saleToMap()` : items incluent `price_buy`, `custom_price`, `variant_name`

**`lib/features/super_admin/presentation/pages/super_admin_page.dart`**
- Reset : appel `reset_all_data` RPC qui retourne JSONB → lecture `auth_error`, `deleted_profiles`, `deleted_auth_users`
- Clear Hive complet (toutes les boxes + `usersBox` + `SecureStorageService.clearAll()`)
- Fallback Edge Function `reset-platform` si RPC ne peut pas supprimer auth.users
- Snackbar explicite selon succès/échec
- Logout forcé 800ms après le snackbar
- `notifyAllChanged()` après reset
- 19 corrections `const` → non-const pour `AppColors.primary*` devenu runtime

**`lib/features/subscription/presentation/pages/subscription_page.dart`**
- AppBar : fond blanc + texte sombre (plus de barre violette)
- Fond : `#FAFAFB` (plus neutre)
- Plan Pro : même `AppColors.primary` (plus de 2e violet hardcodé)
- Bouton s'abonner : `AppPrimaryButton`

**`lib/shared/widgets/app_drawer.dart`**
- Header mode expanded : refonte complète avec carte dégradée, avatar boutique 40×40, nom + libellé secteur, chips pays/devise, badge rôle
- Badge propriétaire : `const Color(0xFF6C3FC7)` → `AppColors.primary` (suit le thème)
- Nouveau widget `_Chip` pour les métadonnées
- Méthode `_sectorLabel(s)` pour le label du secteur

---

## 4. Bugs corrigés

### Auth & Permissions
1. **Membre invité redirigé vers paywall** : le router vérifiait seulement `plan.isActive` sans considérer les memberships. Fix : vérifie `shopRolesMapProvider.isNotEmpty` avant d'appliquer le paywall.
2. **Race condition memberships au login** : `syncMemberships` était non-bloquant. Fix : `Future.wait([load plan, sync memberships])` avant de notifier le router.
3. **Reset ne supprimait pas auth.users** : le RPC SQL avalait silencieusement `insufficient_privilege`. Fix : migration 002 + Edge Function avec service_role_key.
4. **Fallback offline après reset** : mots de passe stockés dans `usersBox._pwd` et `SecureStorage._pwd_*` permettaient un login offline même après suppression du compte. Fix : clear `usersBox` + `SecureStorageService.clearAll()` au reset.

### Dashboard & Sync
5. **Dashboard ne se met pas à jour après vente** : `saveOrder` n'appelait pas `_notify`. Fix : ajout `notifyOrderChange(shopId)`.
6. **Bénéfice = 0** : (a) `price_buy` n'était pas persisté dans les items Hive, (b) la condition `cost > 0` excluait les produits sans prix d'achat. Fix : persistance `price_buy` + retrait condition.
7. **Dashboard stale après reset/logout** : le `Provider.family` cachait l'ancien résultat. Fix : bump `dashSignalProvider` dans `initState` via `addPostFrameCallback`.
8. **syncProducts/syncOrders sans notification** : les données arrivaient dans Hive mais les listeners n'étaient pas notifiés. Fix : `_notify` en fin de sync.
9. **flushOfflineQueue sans notification** : idem. Fix : `notifyAllChanged()` après flush réussi.
10. **updateOrderStatus sans notification** : changement de statut silencieux. Fix : ajout `notifyOrderChange`.

### Inventaire & Caisse
11. **Produit n'apparaît pas après ajout** : `_onRealtimeChange` ne resetait pas la pagination ni les filtres. Fix : `_page = 1` + clear filtres.
12. **Images non affichées en caisse** : `Image.network` sur chemin local échouait silencieusement. Fix : widget `_ProductImageSmart` qui détecte HTTP vs file path.
13. **Placeholder "card vide"** pour produits sans image : remplacé par avatar coloré avec initiales du produit + gradient.

### Page devise
14. **Page devise ne scroll pas** : `AbsorbPointer` bloquait les gestes. Fix : retrait du guard (la devise est un réglage personnel, pas admin).

---

## 5. Décisions architecturales

### Thème runtime vs const
`AppColors.primary` est passé de `static const` à `static Color` (getter mutable). C'est un compromis : les widgets qui lisent `AppColors.primary` changent au prochain rebuild, mais les expressions `const` qui l'utilisaient ont dû être corrigées (19 sites). Alternative rejetée : créer une classe séparée `AppPalette` — aurait laissé 500+ sites inchangés et sans changement visuel.

### Notifications sync
Plutôt que d'utiliser `Hive.box.listenable()` (qui cause des rebuilds trop fréquents), le pattern choisi est :
- `AppDatabase._notify(table, shopId)` → listeners manuels
- Les listeners appellent `dashSignalProvider++` → rebuild ciblé du provider
- Les pages s'abonnent dans `initState` et se désabonnent dans `dispose`

### Bénéfice = prix encaissé − coût total
```
coût = price_buy (figé à la vente) + douane/stock + expenses/stock
bénéfice = (customPrice ?? unitPrice − coût) × quantité × (1 − discount%)
```
Si `price_buy` est absent de l'item Hive (anciennes ventes), fallback sur le coût actuel du produit. Si le coût est 0 (pas rempli), le bénéfice = prix de vente complet.

### Provider dashboard — invalidation par signal
`dashDataProvider` est un `Provider.family<DashData, String>` paramétré par shopId. Il lit directement `HiveBoxes.ordersBox.values` et `productsBox.values`. Pour forcer un rebuild, on incrémente `dashSignalProvider` (StateProvider<int>). Le bump se fait :
- À chaque `_notify` reçu par le listener du dashboard
- À chaque montage du widget dashboard (`initState` → `addPostFrameCallback`)

---

## 6. État des lieux — ce qui marche

- ✅ Auth : login, register, forgot password, accept invite, logout, reset password
- ✅ Offline-first : Hive écrit immédiat, Supabase en background, queue offline
- ✅ Realtime : Supabase channels par boutique, notifications locales
- ✅ Permissions : AppPermissions(plan, shopRole), PermissionGuard, cadenas sur tiles
- ✅ Dashboard : 6 KPIs cliquables, LineChart 3 séries, top produits, transactions récentes, alertes stock, nouveaux produits — tout branché sur données réelles
- ✅ Sync instantanée : saveProduct, saveOrder, updateOrder, updateOrderStatus, deleteProduct, deleteOrder, syncProducts, syncOrders, flushOfflineQueue, reset — tous notifient
- ✅ Thèmes : 8 palettes sélectionnables, persistance SharedPreferences, AppColors runtime, ThemeData dynamique
- ✅ i18n : ~550 clés FR/EN dans app_localizations.dart
- ✅ Paramètres : 10 pages (boutique, caisse config, employés, profil, langue, devise, notifications, WhatsApp, paiements, thème)
- ✅ Reset super admin : RPC SQL + Edge Function + clear Hive complet + logout forcé
- ✅ Images produits : gestion URL HTTP + chemin local + placeholder initiales + loading skeleton

## 7. Ce qui reste à faire / points d'attention

### Bugs potentiels
- PaymentPage (`lib/features/caisse/presentation/pages/payment_page.dart`) est un **stub total** — montant hardcodé, boutons vides. Le flow de paiement standard (non e-commerce) ne crée aucune vente.
- Les anciennes ventes dans Hive (avant les fixes) n'ont pas de `price_buy` dans leurs items → le bénéfice utilise le coût actuel du produit en fallback, pas le coût au moment de la vente.
- `ProcessSale` event dans CaisseBloc est du code mort (jamais émis).
- Les widgets qui utilisent `AppColors.primary` hardcodé changent avec le thème. Ceux qui utilisent `Color(0xFF6C3FC7)` en dur ne changent PAS — quelques sites restent (palettes d'avatars CRM, couleur secteur retail, statut SaleStatus.scheduled). C'est volontaire pour ces cas.

### Améliorations à faire
- Implémenter la vraie PaymentPage (sélection méthode de paiement, montant, validation, création Sale avec status=completed)
- Ajouter le calcul du delta (% variation vs période précédente) sur les KPIs au lieu de le laisser vide
- Migrer les derniers `Color(0xFF6C3FC7)` hardcodés vers `AppColors.primary` si pertinent
- La migration 002 SQL doit être appliquée manuellement sur Supabase (Dashboard → SQL Editor)
- L'Edge Function `reset-platform` doit être déployée (`supabase functions deploy reset-platform`)
- Tests unitaires absents pour les providers dashboard et le calcul de bénéfice

### Convention de code
- Pas de commentaires sauf WHY non-évident
- `debugPrint` au lieu de `print` (lint `avoid_print`)
- `const` constructors quand possible (lint `prefer_const_constructors`) — SAUF pour `AppColors.primary*` qui n'est plus const
- Chaînes UI dans `app_localizations.dart`, jamais hardcodées
- Hive keys dans `HiveBoxes`, jamais hardcodées
- Permissions via `permissionsProvider(shopId)`, jamais de checks ad-hoc

---

## 8. Commandes utiles

```bash
flutter pub get                                    # install deps
flutter run                                        # dev run (hot reload)
flutter analyze                                    # lint — doit retourner 0 error
flutter build apk                                  # release Android
dart run build_runner build --delete-conflicting-outputs  # codegen

# Supabase
supabase login
supabase link --project-ref <ref>
supabase db push                                   # appliquer migrations
supabase functions deploy reset-platform           # déployer Edge Function
```
