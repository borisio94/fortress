# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Fortress POS — multi-shop point-of-sale app (Flutter, Dart SDK `>=3.0.0 <4.0.0`). UI strings and code comments are in French. Uses Supabase (auth + Postgres + Realtime + Storage) as the backend with Hive for offline-first local storage.

## Common commands

```bash
flutter pub get                                    # install deps
flutter run                                        # dev run
flutter analyze                                    # lint (flutter_lints + rules in analysis_options.yaml)
flutter test                                       # all tests
flutter test test/unit/login_usecase_test.dart     # single test file
flutter test --name "substring of test name"       # filter by test name
flutter build apk                                  # release build
dart run build_runner build --delete-conflicting-outputs  # codegen (riverpod_generator, json_serializable)
dart run build_runner watch --delete-conflicting-outputs  # codegen in watch mode
```

## Architecture

### Layering (Clean Architecture per feature)
Every feature under `lib/features/<feature>/` has the same three folders:
- `domain/` — entities, repository interfaces, use cases (pure Dart, no Flutter/Supabase imports).
- `data/` — `datasources/` (remote = Supabase, local = Hive), `models/` (JSON serializable), `repositories/` (impls that combine remote + local).
- `presentation/` — `bloc/` (flutter_bloc), `pages/`, `widgets/`.

Features: `auth`, `caisse`, `crm`, `dashboard`, `hub_central`, `inventaire`, `parametres`, `rapports`, `shop_selector`, `subscription`, `super_admin`.

### State management — dual stack, by design
Both **Riverpod** and **flutter_bloc** are used together and this is intentional:
- **Riverpod** (`lib/core/di/injection_container.dart`, `lib/shared/providers/`) is the DI container. It builds repositories, use cases, and Blocs, and holds cross-cutting app state (auth status, current shop, subscription plan, locale).
- **flutter_bloc** handles per-feature UI state. Blocs are constructed via Riverpod providers and then injected into the widget tree with `BlocProvider.value`.
- `PosApp` (`lib/app.dart`) is a `ConsumerStatefulWidget`: long-lived Blocs (`ShopSelectorBloc`, `CaisseBloc`, `HubBloc`) are created **once** in `initState` and passed via `.value()` to avoid `Duplicate GlobalKey` on rebuild. Do not create these Blocs inside `build()`.

### Routing
`go_router` with a single `appRouterProvider` (`lib/core/router/app_router.dart`). Route names in `route_names.dart`. Auth-driven redirect is handled by `AuthRouterNotifier`: it listens to `AuthBloc` via a `BlocListener` in `app.dart`, and on login it first loads the subscription plan, then calls `notifyListeners()` so `GoRouter` re-runs its redirect. A dedicated `_shellNavigatorKey` is used for the shell route — don't reuse navigator keys.

### Offline-first data layer
`lib/core/database/app_database.dart` is the central singleton that wires Supabase Realtime + Hive + a pending-ops queue:
- `main.dart` boots Hive first (must succeed), then tries Supabase (may fail → offline mode), then `AppDatabase.init()` which listens to `connectivity_plus`.
- Writes go to Hive immediately; if offline, they are appended to the `offline_queue_box`. On reconnect, `_onNetworkRestored` flushes the queue and re-syncs every subscribed shop.
- Reads prefer Hive; Supabase Realtime channels (`subscribeToShop`) push remote changes into Hive and fan out via `AppDatabase.addListener((table, shopId) => …)`.
- All Hive box names live in `lib/core/storage/hive_boxes.dart` — use the accessors (`HiveBoxes.productsBox`, etc.), don't hardcode strings.

When adding a new synced entity: add a Hive box in `HiveBoxes`, add a `sync<Entity>` + realtime handler in `AppDatabase`, and have the repository write-through to Hive then enqueue or push to Supabase.

### Permissions & subscription
`lib/core/permisions/` (note the typo in the folder name — it's the real path):
- `AppPermissions` combines `UserPlan` (subscription tier) + `shopRole` (`admin` | `user` | null) into boolean capabilities (`canEditProduct`, `canAccessCaisse`, …). Gate UI and use-case calls through these, not ad-hoc role checks.
- `subscription_provider.dart` (Riverpod) caches the plan in Hive via `AppDatabase._cachePlanToHive` so offline users retain their tier.
- `permission_guard.dart` wraps widgets/routes.

### Supabase config
`lib/core/config/supabase_config.dart` holds `url` and `anonKey` as hardcoded constants. The file is marked `NE PAS COMMITER` in a comment but is currently tracked — treat it as secret-adjacent when editing. Backend RPCs used include `get_user_plan`; tables include `profiles`, `shop_memberships`, `products`, `categories`, plus realtime channels per-shop.

### i18n
ARB files in `lib/core/i18n/l10n/` (`app_en.arb`, `app_fr.arb`). `generate: true` in `pubspec.yaml` drives codegen via `flutter gen-l10n` (runs automatically on `flutter pub get` / `flutter run`). `localeProvider` (Riverpod) drives `MaterialApp.router`'s `locale`.

### Lints
`analysis_options.yaml` enforces `prefer_const_constructors`, `prefer_const_widgets`, `use_key_in_widget_constructors`, and `avoid_print` — use `debugPrint` (already used throughout `AppDatabase`) instead of `print`.
