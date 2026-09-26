// Un commerçant de Kinshasa comptait en francs CFA.
//
// La devise d'une boutique n'est demandée nulle part à l'inscription : elle se
// déduit de l'indicatif téléphonique saisi (`register_page._countryFromPhone`)
// puis d'une carte pays → devise. Elle fixe ensuite le `CurrencyFormatter` de
// TOUTE l'application : une déduction fausse se lit sur chaque montant de
// chaque écran.
//
// L'application propose SEIZE pays dans son sélecteur téléphonique. La carte
// en couvrait vingt-six — mais pas les mêmes. Un seul tombait dans le trou :
// CD, la République démocratique du Congo. Un commerçant de Kinshasa recevait
// XAF au lieu de CDF, en silence, et l'écran de devise ne proposait même pas
// le franc congolais pour se corriger.
//
// Le repli sur XAF n'est pas le défaut : il vaut mieux une devise plausible
// qu'un plantage à l'inscription. Le défaut est qu'il soit ATTEIGNABLE depuis
// la liste que l'application propose elle-même.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/utils/country_currency.dart';
import 'package:fortress/core/utils/country_phone_data.dart';

void main() {
  group('La devise déduite du pays', () {
    test('LA RDC COMPTE EN FRANCS CONGOLAIS', () {
      // LE test de ce lot. C'est le seul pays que l'application propose et
      // dont elle ignorait la devise.
      expect(currencyForCountry('CD'), 'CDF');
    });

    test('AUCUN PAYS PROPOSÉ NE TOMBE DANS LE REPLI', () {
      // L'invariant qui referme la classe de défaut. Un dix-septième pays
      // ajouté au sélecteur sans sa devise fera tomber ce test, au lieu de
      // donner silencieusement des francs CFA à ses commerçants.
      //
      // Le Cameroun est exclu du contrôle : sa devise EST le repli, on ne
      // peut pas distinguer les deux.
      for (final c in kCountries) {
        if (c.isoCode == 'CM') continue;
        expect(kCountryCurrency.containsKey(c.isoCode), isTrue,
            reason: '${c.isoCode} (${c.nameFr}) n\'a pas de devise — il '
                'recevrait XAF en silence');
      }
    });

    test('les zones CFA sont bien distinguées', () {
      // BEAC et BCEAO portent le même symbole « FCFA » mais ne sont pas la
      // même monnaie. Les confondre passerait inaperçu à l'écran.
      expect(currencyForCountry('CM'), 'XAF');
      expect(currencyForCountry('GA'), 'XAF');
      expect(currencyForCountry('SN'), 'XOF');
      expect(currencyForCountry('CI'), 'XOF');
    });

    test('la casse ne compte pas', () {
      expect(currencyForCountry('cd'), 'CDF');
      expect(currencyForCountry('Fr'), 'EUR');
    });

    test('un pays inconnu ou absent retombe sur le franc CFA BEAC', () {
      // Repli assumé : une inscription ne doit pas échouer parce qu'un
      // indicatif n'est pas répertorié.
      expect(currencyForCountry('ZZ'), 'XAF');
      expect(currencyForCountry(null), 'XAF');
      expect(currencyForCountry(''), 'XAF');
    });
  });
}
