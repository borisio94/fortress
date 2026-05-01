/// Données pays : code ISO, indicatif, drapeau emoji, format regex
class CountryPhoneData {
  final String isoCode;    // CM, FR, US...
  final String dialCode;   // +237, +33...
  final String flag;       // emoji drapeau
  final String name;       // nom natif
  final String nameFr;     // nom en français
  final RegExp pattern;    // regex de validation
  final String example;    // exemple affiché

  const CountryPhoneData({
    required this.isoCode,
    required this.dialCode,
    required this.flag,
    required this.name,
    required this.nameFr,
    required this.pattern,
    required this.example,
  });
}

final List<CountryPhoneData> kCountries = [
  CountryPhoneData(
    isoCode: 'CM', dialCode: '+237', flag: '🇨🇲',
    name: 'Cameroon', nameFr: 'Cameroun',
    pattern: RegExp(r'^\+237[26]\d{8}$'),
    example: '+237 6XX XXX XXX',
  ),
  CountryPhoneData(
    isoCode: 'SN', dialCode: '+221', flag: '🇸🇳',
    name: 'Senegal', nameFr: 'Sénégal',
    pattern: RegExp(r'^\+221[37]\d{8}$'),
    example: '+221 7X XXX XXXX',
  ),
  CountryPhoneData(
    isoCode: 'CI', dialCode: '+225', flag: '🇨🇮',
    name: "Côte d'Ivoire", nameFr: "Côte d'Ivoire",
    pattern: RegExp(r'^\+225\d{10}$'),
    example: '+225 07 XX XX XXXX',
  ),
  CountryPhoneData(
    isoCode: 'NG', dialCode: '+234', flag: '🇳🇬',
    name: 'Nigeria', nameFr: 'Nigeria',
    pattern: RegExp(r'^\+234[789]\d{9}$'),
    example: '+234 8XX XXX XXXX',
  ),
  CountryPhoneData(
    isoCode: 'GH', dialCode: '+233', flag: '🇬🇭',
    name: 'Ghana', nameFr: 'Ghana',
    pattern: RegExp(r'^\+233[235]\d{8}$'),
    example: '+233 2X XXX XXXX',
  ),
  CountryPhoneData(
    isoCode: 'MA', dialCode: '+212', flag: '🇲🇦',
    name: 'Morocco', nameFr: 'Maroc',
    pattern: RegExp(r'^\+212[5-7]\d{8}$'),
    example: '+212 6XX XXX XXX',
  ),
  CountryPhoneData(
    isoCode: 'TN', dialCode: '+216', flag: '🇹🇳',
    name: 'Tunisia', nameFr: 'Tunisie',
    pattern: RegExp(r'^\+216[2-9]\d{7}$'),
    example: '+216 2X XXX XXX',
  ),
  CountryPhoneData(
    isoCode: 'FR', dialCode: '+33', flag: '🇫🇷',
    name: 'France', nameFr: 'France',
    pattern: RegExp(r'^\+33[67]\d{8}$'),
    example: '+33 6XX XXX XXX',
  ),
  CountryPhoneData(
    isoCode: 'BE', dialCode: '+32', flag: '🇧🇪',
    name: 'Belgium', nameFr: 'Belgique',
    pattern: RegExp(r'^\+32[4]\d{8}$'),
    example: '+32 4XX XXX XXX',
  ),
  CountryPhoneData(
    isoCode: 'US', dialCode: '+1', flag: '🇺🇸',
    name: 'United States', nameFr: 'États-Unis',
    pattern: RegExp(r'^\+1[2-9]\d{9}$'),
    example: '+1 (XXX) XXX-XXXX',
  ),
  CountryPhoneData(
    isoCode: 'GB', dialCode: '+44', flag: '🇬🇧',
    name: 'United Kingdom', nameFr: 'Royaume-Uni',
    pattern: RegExp(r'^\+44[7]\d{9}$'),
    example: '+44 7XXX XXX XXX',
  ),
  CountryPhoneData(
    isoCode: 'CD', dialCode: '+243', flag: '🇨🇩',
    name: 'DR Congo', nameFr: 'RD Congo',
    pattern: RegExp(r'^\+243[89]\d{8}$'),
    example: '+243 8XX XXX XXX',
  ),
  CountryPhoneData(
    isoCode: 'GA', dialCode: '+241', flag: '🇬🇦',
    name: 'Gabon', nameFr: 'Gabon',
    pattern: RegExp(r'^\+241[067]\d{6,7}$'),
    example: '+241 06 XX XX XX',
  ),
  CountryPhoneData(
    isoCode: 'CG', dialCode: '+242', flag: '🇨🇬',
    name: 'Congo', nameFr: 'Congo',
    pattern: RegExp(r'^\+242[06]\d{7}$'),
    example: '+242 06 XXX XXXX',
  ),
  CountryPhoneData(
    isoCode: 'BJ', dialCode: '+229', flag: '🇧🇯',
    name: 'Benin', nameFr: 'Bénin',
    pattern: RegExp(r'^\+229[4-9]\d{7}$'),
    example: '+229 9X XX XX XX',
  ),
  CountryPhoneData(
    isoCode: 'TG', dialCode: '+228', flag: '🇹🇬',
    name: 'Togo', nameFr: 'Togo',
    pattern: RegExp(r'^\+228[79]\d{7}$'),
    example: '+228 9X XX XX XX',
  ),
];

/// Pays par défaut selon la locale système (simple heuristique)
CountryPhoneData defaultCountry() => kCountries.first; // Cameroun

/// Trouver un pays par code ISO
CountryPhoneData? countryByIso(String iso) =>
    kCountries.where((c) => c.isoCode == iso).firstOrNull;
