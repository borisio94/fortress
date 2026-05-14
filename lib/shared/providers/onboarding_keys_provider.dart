import '../../core/storage/hive_boxes.dart';

// ═════════════════════════════════════════════════════════════════════════════
// Onboarding flag helpers — persistent dans `HiveBoxes.settingsBox`.
// Clé = `onboarding_done_<uid>` (booléen). Skip et finish marquent tous les
// deux la complétion — on n'afflige pas le user qui a fermé le modal.
//
// Nommé historiquement `*_keys_provider.dart` parce que la 1ʳᵉ version
// utilisait un coach mark ancré sur des GlobalKey du shell. Pivot vers un
// modal walkthrough (cf. `OnboardingTourService`) car les coach marks sur
// drawer fermé en mobile sont fragiles. Le nom de fichier reste pour ne pas
// casser les imports.
// ═════════════════════════════════════════════════════════════════════════════

const String _kOnboardingDonePrefix = 'onboarding_done_';

/// Vrai si l'utilisateur courant a déjà vu (ou skippé) le tour d'onboarding.
/// Lit `HiveBoxes.settingsBox`, fallback `false`. Idempotent — appelable
/// avant l'init Hive ne casse pas (catch silencieux).
bool isOnboardingDone(String uid) {
  if (uid.isEmpty) return true; // visiteur anonyme — pas de tour
  try {
    return HiveBoxes.settingsBox
            .get('$_kOnboardingDonePrefix$uid') as bool? ??
        false;
  } catch (_) {
    return true; // en cas de doute, ne pas afficher
  }
}

/// Marque le tour comme terminé pour `uid`. Appelé au skip OU au finish.
Future<void> markOnboardingDone(String uid) async {
  if (uid.isEmpty) return;
  try {
    await HiveBoxes.settingsBox
        .put('$_kOnboardingDonePrefix$uid', true);
  } catch (_) {/* settingsBox indisponible — silencieux */}
}
