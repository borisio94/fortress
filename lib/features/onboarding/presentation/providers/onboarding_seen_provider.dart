import 'package:flutter_riverpod/flutter_riverpod.dart';

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
