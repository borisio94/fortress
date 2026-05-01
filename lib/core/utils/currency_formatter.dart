import 'package:intl/intl.dart';

class CurrencyFormatter {
  static String format(double amount, {String currency = 'XAF', String? locale}) {
    final fmt = NumberFormat.currency(
      locale: locale ?? 'fr_CM',
      symbol: _symbol(currency),
      decimalDigits: currency == 'XAF' ? 0 : 2,
    );
    return fmt.format(amount);
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
    };
    return map[currency] ?? currency;
  }
}
