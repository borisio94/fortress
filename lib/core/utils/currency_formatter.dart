import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../storage/hive_boxes.dart';

/// Formatage centralisé des montants. La devise active est globale et
/// modifiée via la page Paramètres → Devise. Les widgets qui veulent
/// réagir aux changements en temps réel peuvent écouter [notifier].
///
/// Stockage : `HiveBoxes.settingsBox` avec clé
/// `shop_<shopId>_currency_code` (format `ShopSettingsStore`).
class CurrencyFormatter {
  static String _current = 'XAF';

  /// Devise active. Lecture seule — pour modifier, passer par
  /// [setCurrent] ou [loadForShop].
  static String get current => _current;

  /// Symbole d'affichage de la devise courante (ex: "FCFA", "€", "$").
  /// Utile quand on formate des montants à la main (ex: KPIs avec
  /// abbreviation "k" / "M") sans passer par [format].
  static String get currentSymbol => _symbol(_current);

  /// Notifier global — rebuild automatique des `ValueListenableBuilder`
  /// qui s'abonnent quand la devise change.
  static final ValueNotifier<String> notifier = ValueNotifier<String>('XAF');

  /// Modifie la devise courante (et notifie les listeners). Persiste
  /// la valeur dans Hive pour le shop fourni si non null.
  static void setCurrent(String code, {String? shopId}) {
    if (code == _current) return;
    _current = code;
    notifier.value = code;
    if (shopId != null && shopId.isNotEmpty) {
      try {
        HiveBoxes.settingsBox.put('shop_${shopId}_currency_code', code);
      } catch (_) {/* fail silent */}
    }
  }

  /// Charge la devise sauvegardée pour [shopId] depuis Hive et met à
  /// jour [current] / [notifier]. Appeler au boot du shell et à chaque
  /// changement de shop (cf. AppScaffold).
  static void loadForShop(String shopId) {
    if (shopId.isEmpty) return;
    try {
      final raw = HiveBoxes.settingsBox.get('shop_${shopId}_currency_code');
      final c = (raw is String && raw.isNotEmpty) ? raw : 'XAF';
      if (c != _current) {
        _current = c;
        notifier.value = c;
      }
    } catch (_) {/* fail silent — on garde la valeur courante */}
  }

  /// Formate [amount] dans la devise actuelle (ou [currency] explicite
  /// si fourni — utile pour comparaisons multi-shops).
  static String format(double amount, {String? currency, String? locale}) {
    final c = currency ?? _current;
    final fmt = NumberFormat.currency(
      locale: locale ?? 'fr_CM',
      symbol: _symbol(c),
      decimalDigits: (c == 'XAF' || c == 'XOF') ? 0 : 2,
    );
    return fmt.format(amount);
  }

  /// Abréviation compacte d'un nombre, SANS symbole — KPI, graduations
  /// d'axe (règle unique, document de design § 14, 26/09/2026) :
  ///
  ///     1 500 → « 1,5k »     10 000 → « 10k »     12 500 → « 12,5k »
  ///     125 000 → « 125k »   1 250 000 → « 1,3M »  −12 500 → « -12,5k »
  ///
  /// - UNE décimale seulement quand elle porte une information : jamais
  ///   « ,0 », et aucune au-delà de 100 (« 125k », pas « 125,0k ») ;
  /// - la VIRGULE décimale, comme [format] (locale `fr_CM`) ;
  /// - le SIGNE géré : une perte reste une perte (« -12,5k »).
  ///
  /// Avant : « 10.0k », point décimal, et « -12500 » pour un négatif ; le
  /// graphique du restaurant avait sa propre copie, qui arrondissait à
  /// l'entier — sur un pas de 2 500, l'axe lisait « 3k, 5k, 8k ».
  static String compact(double v) {
    final a = v.abs();
    final String body;
    // Seuils pris APRÈS arrondi : 999 950 donne « 1M », pas « 1000k ».
    if (a >= 999500) {
      body = '${_compactUnit(a / 1000000)}M';
    } else if (a >= 999.5) {
      body = '${_compactUnit(a / 1000)}k';
    } else {
      body = a.round().toString();
    }
    return (v < 0 && body != '0') ? '-$body' : body;
  }

  /// [x] (≥ 0) à une décimale au plus, virgule française, sans « ,0 » ;
  /// entier dès 100.
  static String _compactUnit(double x) {
    if (x >= 100) return x.round().toString();
    final tenths = (x * 10).round();
    return tenths % 10 == 0
        ? '${tenths ~/ 10}'
        : '${tenths ~/ 10},${tenths % 10}';
  }

  static String _symbol(String currency) {
    const map = {
      'XAF': 'FCFA',
      'XOF': 'FCFA',
      'USD': '\$',
      'EUR': '€',
      'GHS': '₵',
      'NGN': '₦',
      'MAD': 'MAD',
      'GBP': '£',
      'CDF': 'FC',
      'TND': 'DT',
      'CAD': 'C\$',
    };
    return map[currency] ?? currency;
  }
}
