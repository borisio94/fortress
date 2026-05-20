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

  /// Abréviation compacte d'un nombre : `1 234 567 → "1.2M"`,
  /// `12 345 → "12.3k"`, sinon entier sans décimale.
  /// Forme canonique partagée par les KPI Finances/Dashboard (k à 1
  /// décimale, pas de gestion du signe, pas de symbole). Les écrans qui
  /// ont volontairement un format différent (symbole accolé, k à 0
  /// décimale, valeur absolue…) gardent leur propre implémentation.
  static String compact(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
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
    };
    return map[currency] ?? currency;
  }
}
