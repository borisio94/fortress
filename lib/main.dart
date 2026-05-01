import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/storage/hive_boxes.dart';
import 'core/storage/secure_storage.dart';
import 'core/services/supabase_service.dart';
import 'core/database/app_database.dart';
import 'core/database/supabase_migrations.dart';
import 'core/services/delivery_reminder_service.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Boot séquence — optimisé pour que l'utilisateur voie une UI Flutter
/// animée IMMÉDIATEMENT au lieu du splash natif statique pendant 2-5s.
/// Stratégie en 3 temps :
///
///   1. **Binding only** (~50ms) : SentryWidgetsFlutterBinding init.
///      C'est le minimum pour pouvoir appeler `runApp`.
///   2. **runApp(_BootSplashApp)** : Flutter prend le relais du splash
///      natif et affiche fond violet + logo + spinner ANIMÉ. Sans ce
///      relais, le user voit l'image violette figée du splash natif
///      pendant tout l'init (et croit l'app freezée).
///   3. **Init parallélisé** (Hive + Supabase + AppDB), puis
///      `runApp(PosApp)` qui remplace le splash Flutter par l'app
///      réelle. Le 2e `runApp` est supporté par le framework — il
///      remplace le widget root proprement.
///
/// Pour l'arrière-plan : Sentry + notifs + migrations cloud sont lancés
/// dans `_initBackgroundServices` après le 2e runApp. Sentry n'est pas
/// dans le pre-runApp parce que son init réseau (validation DSN + crash
/// handler natif) prend 1-2s — bloquerait inutilement.
///
/// `SentryWidgetsFlutterBinding` (au lieu du standard
/// `WidgetsFlutterBinding`) active le frame tracking Sentry visible
/// dans les transactions performance.
void main() async {
  // 1. Binding minimal — requis avant tout `runApp`.
  SentryWidgetsFlutterBinding.ensureInitialized();

  // 2. Splash Flutter ANIMÉ rendu immédiatement. Le splash natif
  // (statique) disparaît dès le first frame Flutter — donc le user
  // passe d'image violette figée → spinner qui tourne en ~50-100ms,
  // sans la sensation de freeze.
  runApp(const _BootSplashApp());

  // 3. Init essentiels en PARALLÈLE pendant que le splash Flutter anime.
  // Total ≈ max(Hive, Supabase, AppDB) au lieu de la somme.
  await Future.wait([
    HiveBoxes.init().then((_) async {
      // Sécurité : migre les mots de passe stockés en clair par les versions
      // antérieures (champ `_pwd` dans usersBox + clés `_pwd_<email>` dans
      // settingsBox) vers SecureStorage. Idempotent — ne fait rien si clean.
      try {
        final migrated =
            await SecureStorageService.purgeLegacyPlaintextPasswords();
        if (migrated > 0) {
          debugPrint('[Security] $migrated mot(s) de passe legacy migrés '
              'vers SecureStorage (Hive nettoyé)');
        }
      } catch (e) {
        debugPrint('SecureStorage purge error: $e');
      }
    }).catchError((Object e) {
      debugPrint('Hive init error: $e');
    }),
    SupabaseService.init().catchError((Object e) {
      debugPrint('Supabase init error: $e');
    }),
    AppDatabase.init().catchError((Object e) {
      debugPrint('AppDatabase init error: $e');
    }),
  ]);

  // 4. Bascule vers l'app réelle. Le runApp précédent est remplacé.
  runApp(SentryWidget(child: const ProviderScope(child: PosApp())));

  // 5. Tâches non-critiques en background — Sentry, notifs, migrations.
  // Erreurs swallow car non fatales (cf. catchError sur chaque init).
  unawaited(_initBackgroundServices());
}

/// Splash Flutter affiché entre le splash natif (Android `windowBackground`)
/// et le premier rendu de [PosApp]. Couleur de fond identique au splash
/// natif (#6C3FC7) pour une transition sans flash.
///
/// Ne PAS dépendre de `Theme.of(context)` ici — aucun thème n'est encore
/// monté. On utilise des constantes en dur + `Image.asset` (l'asset bundle
/// est dispo dès `WidgetsFlutterBinding.ensureInitialized`).
class _BootSplashApp extends StatelessWidget {
  const _BootSplashApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Color(0xFF6C3FC7),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo PNG (asset packagé) — pas le widget FortressLogo
                // car celui-ci a besoin d'un Theme et nous n'avons pas
                // encore monté ProviderScope/PosApp.
                SizedBox(
                  width: 96, height: 96,
                  child: Image(
                    image: AssetImage('assets/logos/fortress_app_icon.png'),
                    gaplessPlayback: true,
                  ),
                ),
                SizedBox(height: 28),
                SizedBox(
                  width: 28, height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

/// Init non-bloquant : Sentry + notifications + migrations cloud
/// lancés en parallèle. Appelé après runApp pour ne pas retarder le
/// premier frame.
Future<void> _initBackgroundServices() async {
  await Future.wait([
    // Sentry init — peut prendre 500-2000ms (validation DSN + native
    // crash handler). Capturé en background, l'app est déjà visible.
    SentryFlutter.init((options) {
      options.dsn = 'https://5e24ab164b4eecefc3756bd5aa3b902c@o4511301758222336.ingest.de.sentry.io/4511301770477648';
      options.tracesSampleRate = 1.0;
      // ignore: experimental_member_use
      options.profilesSampleRate = 1.0;
    }).catchError((Object e) {
      debugPrint('Sentry init error: $e');
    }),
    // Notifications locales (rappels de livraison à date échue) —
    // crée les channels Android, peut prendre 100-300ms.
    DeliveryReminderService.init().catchError((Object e) {
      debugPrint('DeliveryReminderService init error: $e');
    }),
    // Migration idempotente : ne s'exécute que si activity_logs est
    // absente. Network-bound, peut être lente.
    SupabaseMigrations.runIfNeeded().catchError((Object e) {
      debugPrint('Supabase migrations error: $e');
    }),
  ]);
}