import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// ═════════════════════════════════════════════════════════════════════════════
// UrlShortenerService — raccourcit une URL en faisant la course entre deux
// services publics gratuits (sans clé API) :
//   • tinyurl.com  (`https://tinyurl.com/api-create.php?url=…`)
//   • is.gd        (`https://is.gd/create.php?format=simple&url=…`)
//
// Stratégie : on lance les deux requêtes en parallèle, on prend la
// première qui répond avec une URL valide. Avantages :
//   • Best case ≈ 500 ms (le plus rapide gagne)
//   • Worst case = le plus lent des deux (≈ 3 s)
//   • Deux services indépendants → forte tolérance aux pannes
//
// Fallback final : si les deux échouent (offline, timeout, rate-limit) on
// retourne l'URL longue d'origine — l'envoi WhatsApp n'est jamais bloqué.
// ═════════════════════════════════════════════════════════════════════════════

class UrlShortenerService {
  static const _timeout = Duration(seconds: 3);

  /// Raccourcit [longUrl]. Retourne l'URL courte si succès, sinon [longUrl]
  /// (jamais d'exception).
  static Future<String> shorten(String longUrl) async {
    final tinyFuture = _viaTinyUrl(longUrl);
    final isgdFuture = _viaIsgd(longUrl);
    try {
      // Course : on prend le premier `_Result.success`, sinon on attend
      // que les deux finissent et on retourne le fallback.
      final winner = await _firstSuccess([tinyFuture, isgdFuture]);
      if (winner != null) {
        debugPrint('[UrlShortener] $longUrl → $winner');
        return winner;
      }
    } catch (e) {
      debugPrint('[UrlShortener] Race échouée : $e');
    }
    debugPrint('[UrlShortener] Aucun shortener n\'a répondu — '
        'fallback long URL');
    return longUrl;
  }

  /// Attend la première Future qui retourne une chaîne non vide.
  /// Si toutes les Futures retournent `null` ou throw → renvoie `null`.
  static Future<String?> _firstSuccess(List<Future<String?>> futures) {
    final completer = Completer<String?>();
    var pending = futures.length;
    for (final f in futures) {
      f.then((value) {
        if (completer.isCompleted) return;
        if (value != null && value.isNotEmpty) {
          completer.complete(value);
        } else {
          pending--;
          if (pending == 0) completer.complete(null);
        }
      }).catchError((_) {
        if (completer.isCompleted) return;
        pending--;
        if (pending == 0) completer.complete(null);
      });
    }
    return completer.future;
  }

  static Future<String?> _viaTinyUrl(String longUrl) async {
    try {
      final uri = Uri.parse(
          'https://tinyurl.com/api-create.php?url=${Uri.encodeComponent(longUrl)}');
      final resp = await http.get(uri).timeout(_timeout);
      if (resp.statusCode == 200) {
        final s = resp.body.trim();
        if (s.startsWith('http')) return s;
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> _viaIsgd(String longUrl) async {
    try {
      final uri = Uri.parse(
          'https://is.gd/create.php?format=simple&url=${Uri.encodeComponent(longUrl)}');
      final resp = await http.get(uri).timeout(_timeout);
      if (resp.statusCode == 200) {
        final s = resp.body.trim();
        if (s.startsWith('http')) return s;
      }
    } catch (_) {}
    return null;
  }
}
