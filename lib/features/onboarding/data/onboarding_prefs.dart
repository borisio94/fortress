import 'package:shared_preferences/shared_preferences.dart';

/// Helpers SharedPreferences pour les flags d'onboarding device-scoped.
///
/// Pourquoi SharedPreferences (et pas Hive comme `onboarding_done_<uid>`)
/// ─────────────────────────────────────────────────────────────────────
/// Les flags ici sont **device-scoped** (pas user-scoped) :
///   • `onboarding_seen` : vu UNE FOIS sur ce navigateur/téléphone — pas
///     besoin de re-voir les slides au re-login ou au changement de
///     compte.
///   • `first_sale_tooltip_seen` : idem device-scoped (l'astuce visuelle
///     n'a pas à se ré-afficher pour chaque user du même device).
///
/// Hive + uid est utilisé pour les flags user-scoped (cf. `OnboardingTour`
/// pour le walkthrough interne post-login). Les deux systèmes coexistent
/// par design : tour interne = par utilisateur ; slides marketing +
/// astuces = par device.
///
/// Convention : toutes les clés sont **préfixées `onboarding_`** pour
/// rester groupées et facilement nettoyables si on doit reset l'état.
class OnboardingPrefs {
  OnboardingPrefs._();

  // ─── Clés (toutes préfixées 'onboarding_') ──────────────────────────────
  /// True si l'utilisateur a vu (ou skippé) les slides marketing.
  /// Une fois positionné, l'app n'affichera plus les slides au démarrage.
  static const _kSlidesSeen          = 'onboarding_seen';
  /// Tooltip d'aide première vente (PR-3).
  static const _kFirstSaleTooltip    = 'onboarding_first_sale_tooltip_seen';
  /// Bannière "Confirmez votre email" — l'utilisateur peut la fermer.
  /// Key user-scoped (préfixe + uid) car l'email à confirmer dépend du user.
  static String emailConfirmBannerKey(String uid) =>
      'onboarding_email_confirm_banner_dismissed_$uid';
  /// Bannière J+1 — affichée une fois par jour. Stocke la date du dernier
  /// affichage au format yyyy-MM-dd.
  static const _kJ1BannerLastDay     = 'onboarding_j1_banner_last_day';
  /// Bannière "essai dans 2 jours" — affichée une fois (à J+12).
  static String trialEndBannerKey(String uid) =>
      'onboarding_trial_end_banner_dismissed_$uid';
  /// Checklist activation — clé par étape (4 booleans).
  /// Key user-scoped car la progression doit être par compte.
  static String checklistStepKey(String uid, String step) =>
      'onboarding_checklist_${uid}_$step';

  // ─── Slides ────────────────────────────────────────────────────────────
  static Future<bool> hasSeenSlides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kSlidesSeen) ?? false;
    } catch (_) {
      // Fallback safe : considère que oui pour ne pas spammer les slides
      // si SharedPreferences est cassé (cas test ou plateforme exotique).
      return true;
    }
  }

  static Future<void> markSlidesSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSlidesSeen, true);
    } catch (_) {/* silencieux */}
  }

  // ─── First-sale tooltip (PR-3) ─────────────────────────────────────────
  static Future<bool> hasSeenFirstSaleTooltip() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kFirstSaleTooltip) ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> markFirstSaleTooltipSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kFirstSaleTooltip, true);
    } catch (_) {/* silencieux */}
  }

  // ─── Bannière email confirm (PR-1) ─────────────────────────────────────
  static Future<bool> isEmailConfirmBannerDismissed(String uid) async {
    if (uid.isEmpty) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(emailConfirmBannerKey(uid)) ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> dismissEmailConfirmBanner(String uid) async {
    if (uid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(emailConfirmBannerKey(uid), true);
    } catch (_) {/* silencieux */}
  }

  // ─── Checklist d'activation (PR-2) ─────────────────────────────────────
  static Future<bool> isChecklistStepDone(String uid, String step) async {
    if (uid.isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(checklistStepKey(uid, step)) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> markChecklistStepDone(String uid, String step) async {
    if (uid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(checklistStepKey(uid, step), true);
    } catch (_) {/* silencieux */}
  }

  // ─── Bannière J+1 (PR-3) ───────────────────────────────────────────────
  /// True si la bannière J+1 a déjà été affichée aujourd'hui.
  static Future<bool> wasJ1BannerShownToday() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString(_kJ1BannerLastDay) ?? '';
      return last == _todayKey();
    } catch (_) {
      return true;
    }
  }

  static Future<void> markJ1BannerShownToday() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kJ1BannerLastDay, _todayKey());
    } catch (_) {/* silencieux */}
  }

  static String _todayKey() {
    final now = DateTime.now();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '${now.year}-$m-$d';
  }

  // ─── Bannière fin d'essai (PR-3) ───────────────────────────────────────
  static Future<bool> isTrialEndBannerDismissed(String uid) async {
    if (uid.isEmpty) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(trialEndBannerKey(uid)) ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> dismissTrialEndBanner(String uid) async {
    if (uid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(trialEndBannerKey(uid), true);
    } catch (_) {/* silencieux */}
  }
}
