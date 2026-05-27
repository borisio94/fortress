import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'app.dart';
import 'core/storage/hive_boxes.dart';
import 'core/storage/secure_storage.dart';
import 'core/services/supabase_service.dart';
import 'core/database/app_database.dart';
import 'core/database/supabase_migrations.dart';
import 'core/services/delivery_reminder_service.dart';
import 'core/services/scheduled_order_alert_service.dart';
import 'shared/widgets/alerts/alarm_sound_player.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Boot séquence.
///
/// **Web** : le splash HTML inline (`web/index.html` → `#fortress-splash`)
/// reste visible jusqu'au `flutter-first-frame`. On saute le splash Flutter
/// `_BootSplashApp` pour éviter un double écran de chargement.
///
/// **Mobile** : on relaie le splash natif Android/iOS (image figée) par un
/// splash Flutter animé pendant l'init. Sans ce relais, l'utilisateur voit
/// l'image figée pendant 2-5s et croit l'app gelée. Stratégie :
///   1. Binding minimal (~50ms).
///   2. `runApp(_BootSplashApp)` — fond violet + logo + spinner animé.
///   3. Init parallélisé (Hive + Supabase + AppDB).
///   4. `runApp(PosApp)` — remplace le splash par l'app réelle.
///
/// Sentry + notifs + migrations cloud sont lancés en background dans
/// `_initBackgroundServices` (non bloquant).
void main() async {
  // [BOOT-1] log très tôt — confirme que CETTE version de main.dart
  // s'exécute. Si absent de la console : cache navigateur tenace.
  debugPrint('[BOOT] main() entered — Fortress build 2026-05-09 sync-banner');

  // 1. Binding minimal — requis avant tout `runApp`.
  SentryWidgetsFlutterBinding.ensureInitialized();

  // 1bis. Web : passe en path routing (sans #). Élimine le fragment qui
  //       posait problème quand un lien court (Edge `r` → 302) était
  //       suivi par certains in-app browsers WhatsApp (iOS notamment),
  //       qui strippaient le hash et faisaient atterrir le livreur sur
  //       la landing page au lieu du catalogue. Le rewrite Firebase
  //       Hosting (`** → /index.html`) est déjà en place côté
  //       firebase.json, donc toute route deeplink fonctionne sans
  //       changement serveur. À appeler AVANT runApp pour ne pas voir
  //       un flash de hash dans la barre d'adresse.
  if (kIsWeb) usePathUrlStrategy();

  // 2. Splash Flutter animé — uniquement mobile/desktop.
  // Sur web, le splash HTML inline est déjà visible (cf. web/index.html).
  if (!kIsWeb) {
    runApp(const _BootSplashApp());
  }

  // 3. Init séquencé : Hive d'abord (AppDatabase + Notif en dépendent),
  //    puis Supabase + AppDatabase + purge SecureStorage en parallèle.
  //    Lancer AppDatabase.init() en parallèle de HiveBoxes.init() crée une
  //    race condition : _bootstrapAntiStaleMarkers utilise settingsBox qui
  //    peut ne pas être encore ouverte → HiveError uncaught au boot.
  try {
    await HiveBoxes.init();
  } catch (e) {
    debugPrint('Hive init error: $e');
  }
  await Future.wait([
    // Migration mots de passe legacy → SecureStorage. Idempotent.
    () async {
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
    }(),
    SupabaseService.init().catchError((Object e) {
      debugPrint('Supabase init error: $e');
    }),
    AppDatabase.init().catchError((Object e) {
      debugPrint('AppDatabase init error: $e');
    }),
  ]);

  // 4. Bascule vers l'app réelle. Le runApp précédent est remplacé.
  //    Le wrapper `_AudioUnlocker` capte le 1er pointer down (web only)
  //    pour déverrouiller l'AudioContext — sans ça le navigateur refuse
  //    de jouer un son issu du Timer du ScheduledOrderAlertService.
  runApp(SentryWidget(
      child: const ProviderScope(child: _AudioUnlocker(child: PosApp()))));

  // 5. Tâches non-critiques en background — Sentry, notifs, migrations,
  //    moteur d'alertes commandes programmées. Erreurs swallow car non
  //    fatales (cf. catchError sur chaque init).
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
    // Moteur d'alertes commandes programmées — surveille ordersBox et
    // déclenche sons/Stream selon les seuils J-1, H-2, H-1, etc.
    // Non bloquant : retry interne 2s si AppDatabase pas prêt.
    ScheduledOrderAlertService.instance.start().catchError((Object e) {
      debugPrint('ScheduledOrderAlertService init error: $e');
    }),
  ]);
}

/// Wrap l'app pour déverrouiller l'AudioContext web au 1er pointer down.
/// Sans ça, le navigateur (Chrome, Safari, Firefox) refuse tout `play()`
/// qui ne provient pas d'un événement utilisateur synchrone — y compris
/// ceux issus des Timer périodiques du ScheduledOrderAlertService.
///
/// Sur natif (mobile/desktop), l'AudioContext n'a pas ce verrou et le
/// wrapper est transparent (no-op).
class _AudioUnlocker extends StatefulWidget {
  final Widget child;
  const _AudioUnlocker({required this.child});
  @override
  State<_AudioUnlocker> createState() => _AudioUnlockerState();
}

class _AudioUnlockerState extends State<_AudioUnlocker> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (_done || !kIsWeb) return;
        _done = true;
        // ignore: discarded_futures
        AlarmSoundPlayer.instance.unlock();
      },
      child: widget.child,
    );
  }
}