import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Rafraîchit le token Supabase avec retry + backoff exponentiel.
///
/// Le SDK Supabase rafraîchit automatiquement le token en tâche de fond,
/// mais sur réseau instable (3G mobile, captive portal, sortie d'avion
/// mode) le 1er essai peut échouer silencieusement et l'app se retrouve
/// avec un AccessToken expiré → 401 sur la prochaine requête.
///
/// Stratégie : 3 tentatives séparées par 1s, 2s, 4s. Si le 3e essai
/// échoue (vrai problème réseau), on lève [_tokenRefreshFailedFlag] —
/// la bannière offline s'étend pour informer l'utilisateur que le mode
/// dégradé est actif jusqu'au retour du réseau.
///
/// Distinction importante avec [SessionValidator] :
///   - Validator : "le compte existe-t-il toujours côté serveur ?"
///   - Refresher : "le token est-il encore frais ?"
class SessionRefresher {
  static const _backoffsMs = [1000, 2000, 4000];

  /// Tente de rafraîchir la session jusqu'à [maxAttempts] fois.
  ///
  /// Retourne `true` si succès, `false` si échec après tous les essais
  /// (= probable problème réseau persistant).
  static Future<bool> refresh({int maxAttempts = 3}) async {
    final supa = Supabase.instance.client;
    if (supa.auth.currentSession == null) return false;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        await supa.auth.refreshSession();
        debugPrint('[SessionRefresher] ✓ token rafraîchi '
            '(tentative ${attempt + 1}/$maxAttempts)');
        return true;
      } catch (e) {
        final isLast = attempt == maxAttempts - 1;
        debugPrint('[SessionRefresher] ✗ échec ${attempt + 1}/$maxAttempts : $e');
        if (isLast) return false;
        final waitMs = _backoffsMs[attempt.clamp(0, _backoffsMs.length - 1)];
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      }
    }
    return false;
  }
}
