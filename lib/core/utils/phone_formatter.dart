class PhoneFormatter {
  /// Normalise un numéro en format E.164 pour WhatsApp Business API
  static String toE164(String phone, {String defaultCountryCode = '237'}) {
    final cleaned = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (cleaned.startsWith('+')) return cleaned;
    if (cleaned.startsWith('00')) return '+${cleaned.substring(2)}';
    return '+$defaultCountryCode$cleaned';
  }

  /// Format pour wa.me : chiffres uniquement, indicatif pays inclus, sans `+`.
  /// - Strip `+`, espaces, tirets, parenthèses
  /// - `00<CC>...` → `<CC>...`
  /// - `0XXXXXXXXX` (9 chiffres après le 0) → `<defaultCountryCode>XXXXXXXXX`
  /// - Numéro local sans indicatif (commence par 6 ou 2, < 11 chiffres)
  ///   → `<defaultCountryCode>...`
  /// - Sinon, on suppose que l'indicatif est déjà inclus.
  static String toWame(String phone, {String defaultCountryCode = '237'}) {
    final cleaned = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (cleaned.isEmpty) return '';
    if (cleaned.startsWith('00')) return cleaned.substring(2);
    if (cleaned.startsWith('0')) {
      return '$defaultCountryCode${cleaned.substring(1)}';
    }
    // Numéro Cameroun typique : 9 chiffres commençant par 6 ou 2.
    final isLocal = cleaned.length <= 10
        && (cleaned.startsWith('6') || cleaned.startsWith('2'));
    if (isLocal) return '$defaultCountryCode$cleaned';
    return cleaned;
  }

  static String display(String e164) {
    if (e164.startsWith('+237')) {
      final local = e164.substring(4);
      return local.replaceAllMapped(RegExp(r'(\d{3})(\d{3})(\d{3})'), (m) => '${m[1]} ${m[2]} ${m[3]}');
    }
    return e164;
  }
}
