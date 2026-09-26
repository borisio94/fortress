import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/inventaire/domain/entities/product.dart';

/// CE QU'UNE SURFACE DE VENTE A LE DROIT DE VENDRE.
///
/// La règle existait, mais recopiée à la main partout où l'on vend — trois fois
/// dans la grille de la caisse e-commerce, et nulle part dans le module
/// restaurant. Résultat : un plat décoché restait à la carte, sans rien qui le
/// signale, et se commandait. Elle porte désormais un nom, `isSellable`.
///
/// Ce test verrouille la règle. Ce qu'il ne couvre pas, faute de test widget
/// dans ce dépôt : que la carte du restaurant l'applique bien, que le tampon
/// « RETIRÉ » s'affiche et que le bandeau « plats retirés » ramène au plat.
void main() {
  const enVente = Product(name: 'Ndolè');

  group('Produit vendable', () {
    test('un plat actif est vendable', () {
      expect(enVente.isSellable, isTrue);
    });

    test('un plat décoché ne se vend plus', () {
      expect(enVente.copyWith(isActive: false).isSellable, isFalse);
    });

    test('un brouillon ne se vend pas, même actif', () {
      // Un brouillon est normalement écrit inactif ; la garde ne s'appuie pas
      // là-dessus, sans quoi une fiche reprise à moitié pourrait partir en
      // vente.
      final brouillon =
          enVente.copyWith(status: ProductStatus.draft, isActive: true);
      expect(brouillon.isDraft, isTrue);
      expect(brouillon.isSellable, isFalse);
    });

    test('un plat supprimé ne se vend pas', () {
      // Ceinture : les lectures Hive excluent déjà les supprimés, mais une
      // liste venue de Supabase ou de l'écran super-admin ne le fait pas.
      final supprime = enVente.copyWith(deletedAt: DateTime.now());
      expect(supprime.isDeleted, isTrue);
      expect(supprime.isSellable, isFalse);
    });

    test('la vitrine publique demande PLUS que « vendable »', () {
      // La RPC publique filtre `is_active AND is_visible_web`. Les deux
      // drapeaux sont désormais indépendants dans la fiche plat : un plat peut
      // être à la carte de la salle sans être publié en ligne.
      final salleSeulement = enVente.copyWith(isVisibleWeb: false);
      expect(salleSeulement.isSellable, isTrue);
      expect(salleSeulement.isVisibleWeb, isFalse);

      // Et l'inverse ne se produit pas : décoché, il sort aussi de la vitrine,
      // puisque celle-ci filtre d'abord sur `is_active`.
      final retire = enVente.copyWith(isActive: false, isVisibleWeb: true);
      expect(retire.isSellable, isFalse);
    });
  });
}
