/// LA DEVISE D'UNE BOUTIQUE, DÉDUITE DE SON PAYS.
///
/// Elle n'est demandée nulle part à l'inscription : elle se déduit de
/// l'indicatif téléphonique saisi, et fixe le `CurrencyFormatter` de toute
/// l'application. Une déduction fausse se lit donc sur chaque montant de
/// chaque écran.
///
/// La carte vivait en privé dans `register_page.dart`, là où personne ne
/// pouvait la comparer à la liste des pays réellement proposés. Elle est ici
/// pour que les deux puissent être confrontées — c'est ainsi que le trou est
/// apparu.
///
/// CE QU'ELLE NE FAIT PAS : convertir. `CurrencyFormatter` ne change que le
/// symbole et le nombre de décimales ; les montants stockés sont des nombres
/// nus. Corriger une devise RENOMME, elle ne recalcule rien.
library;

/// Devise officielle par code ISO de pays.
///
/// Plus large que les seize pays du sélecteur téléphonique, à dessein : un
/// numéro saisi à la main peut porter un indicatif hors liste, et mieux vaut
/// le reconnaître que de le renvoyer au repli.
const Map<String, String> kCountryCurrency = <String, String>{
  // Zone BEAC
  'CM': 'XAF', 'TD': 'XAF', 'CF': 'XAF', 'CG': 'XAF', 'GA': 'XAF', 'GQ': 'XAF',
  // Zone BCEAO
  'SN': 'XOF', 'CI': 'XOF', 'BF': 'XOF', 'ML': 'XOF', 'NE': 'XOF', 'TG': 'XOF',
  'BJ': 'XOF', 'GW': 'XOF',
  // Reste de l'Afrique
  'NG': 'NGN', 'GH': 'GHS', 'MA': 'MAD', 'TN': 'TND',
  // LA RDC. Elle manquait, et c'était le SEUL pays proposé par le sélecteur
  // dont la devise était inconnue : ses commerçants recevaient XAF en
  // silence, et l'écran de devise ne proposait même pas le franc congolais
  // pour se corriger.
  'CD': 'CDF',
  // Europe et Amérique du Nord
  'FR': 'EUR', 'BE': 'EUR', 'DE': 'EUR', 'IT': 'EUR', 'ES': 'EUR',
  'US': 'USD', 'CA': 'CAD', 'GB': 'GBP',
};

/// Devise à retenir pour [isoCode], avec repli sur le franc CFA BEAC.
///
/// LE REPLI EST UN AVEU, pas un défaut : il vaut mieux une devise plausible
/// qu'un plantage à l'inscription. Mais il doit rester INATTEIGNABLE pour les
/// pays que l'application propose elle-même — un commerçant qui choisit son
/// pays dans une liste ne doit pas tomber dedans. Un test le vérifie pays par
/// pays, pour que l'ajout d'un dix-septième n'ouvre pas un nouveau trou.
String currencyForCountry(String? isoCode) =>
    kCountryCurrency[(isoCode ?? '').toUpperCase()] ?? 'XAF';
