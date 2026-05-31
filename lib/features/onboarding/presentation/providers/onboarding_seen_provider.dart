import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/onboarding_prefs.dart';

/// Cache mémoire du flag `OnboardingPrefs.hasSeenSlides()` pour qu'il soit
/// lisible **synchroniquement** par la fonction `redirect` de GoRouter
/// (qui ne peut pas être async).
///
/// • `null` au boot tant que SharedPreferences n'est pas lu.
/// • `true` une fois lu et le flag positionné.
/// • `false` une fois lu et le flag absent → déclenche le redirect vers
///   les slides marketing.
///
/// Lecture initiale orchestrée par `app.dart` au démarrage. Setter exposé
/// pour les pages qui marquent le flag (slides + auth-choice).
final onboardingSeenCacheProvider =
    StateProvider<bool?>((ref) => null);

/// Init au boot — lit SharedPreferences UNE FOIS et alimente le cache.
/// Appelée depuis `app.dart` immédiatement après le ProviderScope.
///
/// Accepte `WidgetRef` (depuis un widget Consumer) ou `Ref` (depuis un
/// Provider) — l'interface commune `Refreshable.read` couvre les deux.
Future<void> primeOnboardingSeenCache(WidgetRef ref) async {
  final seen = await OnboardingPrefs.hasSeenSlides();
  ref.read(onboardingSeenCacheProvider.notifier).state = seen;
}

/// Flag SERVEUR `profiles.onboarding_slides_seen` (cf. hotfix_099).
///
/// Contrairement à [onboardingSeenCacheProvider] qui est device-scoped, ce
/// flag est lié au COMPTE : les slides d'intro ne s'affichent qu'UNE SEULE
/// FOIS, à la première connexion, et plus jamais ensuite — même sur un autre
/// appareil.
///
/// • `null`  : pas encore chargé (au boot / pendant la sync post-login). Le
///   `redirect` GoRouter attend (ne route pas) tant que c'est null pour éviter
///   un flash dashboard → slides.
/// • `false` : compte neuf jamais onboardé → afficher les slides.
/// • `true`  : déjà vu (ou compte existant backfillé) → ne rien afficher.
///
/// Chargé au login par `AuthRouterNotifier`, réinitialisé à `null` au logout.
final onboardingSlidesSeenProvider = StateProvider<bool?>((ref) => null);

/// Lit le flag serveur pour l'utilisateur courant et alimente
/// [onboardingSlidesSeenProvider]. Appelé dans le `Future.wait` du login.
///
/// Fail-safe : en cas d'erreur (réseau, colonne absente, pas de session) on
/// considère les slides comme VUES (`true`) — on ne bloque jamais l'entrée
/// dans l'app et on ne spamme jamais les slides à tort.
Future<void> loadOnboardingSlidesSeen(Ref ref) async {
  final client = Supabase.instance.client;
  final uid = client.auth.currentUser?.id;
  final notifier = ref.read(onboardingSlidesSeenProvider.notifier);
  if (uid == null) {
    notifier.state = true;
    return;
  }
  try {
    final row = await client
        .from('profiles')
        .select('onboarding_slides_seen')
        .eq('id', uid)
        .maybeSingle();
    notifier.state = (row?['onboarding_slides_seen'] as bool?) ?? true;
  } catch (_) {
    notifier.state = true;
  }
}
