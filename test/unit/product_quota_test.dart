import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/permisions/user_plan.dart';

/// PLAFOND DE PRODUITS DE L'ABONNEMENT.
///
/// Les plats d'un restaurant sont des produits comme ceux d'une boutique en
/// ligne : ils tombent sous le même plafond, `UserPlan.canAddProduct`. Les deux
/// entrées de création du module restaurant — l'écran Menu et le parcours de
/// mise en route — ne l'appelaient pas : on y composait une carte sans limite,
/// quel que soit l'abonnement.
///
/// Ce test verrouille la RÈGLE (le plafond, ses bords, et les cas où il ne
/// s'applique pas). Ce qu'il ne couvre pas : que les écrans l'appellent bien —
/// il faudrait rendre les pages, et ce dépôt n'a pas de test widget. Le compte
/// lui-même vient de `LocalStorageService.getProductsForShop`, qui lit Hive et
/// exclut les produits supprimés.
void main() {
  // 50 : le défaut que le super-admin propose pour un plan personnalisé, donc
  // le cas où ce plafond se déclenche réellement (Starter en est à 500).
  const petitPlan = UserPlan(maxProducts: 50, subStatus: 'active');

  group('Quota produits', () {
    test('sous le plafond, on peut créer', () {
      expect(petitPlan.canAddProduct(49), isTrue);
    });

    test('au plafond, on ne peut plus — bord exact', () {
      // 50 produits pour un maximum de 50 : le prochain serait le 51ᵉ.
      expect(petitPlan.canAddProduct(50), isFalse);
      expect(petitPlan.canAddProduct(51), isFalse);
    });

    test('un plat retiré de la carte libère un emplacement', () {
      // Le compte passé ici EXCLUT les produits supprimés (cf. la doc de
      // `ProductQuotaGuard.ensureCanAdd`) : une carte au plafond dont on retire
      // un plat repasse sous la limite, sans changer d'abonnement.
      expect(petitPlan.canAddProduct(50), isFalse);
      expect(petitPlan.canAddProduct(49), isTrue);
    });

    test('un maximum à zéro veut dire ILLIMITÉ, pas interdit', () {
      // Piège du modèle : `maxProducts <= 0` désactive le quota. C'est le cas
      // des plans Business et Essai, et de tout plan dont la base ne renvoie
      // pas la colonne.
      const illimite = UserPlan(maxProducts: 0, subStatus: 'active');
      expect(illimite.canAddProduct(100000), isTrue);
    });

    test('un abonnement inactif refuse, même très en dessous du plafond', () {
      // Et ce n'est PAS le zéro de `maxProducts` qui l'interdirait — c'est
      // `isActive`. Sans lui, un plan expiré serait lu comme illimité.
      const expire = UserPlan(maxProducts: 0, subStatus: 'expired');
      expect(expire.canAddProduct(0), isFalse);

      const expireAvecPlafond = UserPlan(maxProducts: 50, subStatus: 'expired');
      expect(expireAvecPlafond.canAddProduct(1), isFalse);
    });

    test('un essai en cours compte comme actif', () {
      const essai = UserPlan(maxProducts: 50, subStatus: 'trial');
      expect(essai.canAddProduct(49), isTrue);
      expect(essai.canAddProduct(50), isFalse);
    });

    test('un abonnement échu à la date ne passe plus', () {
      final echu = UserPlan(
        maxProducts: 50,
        subStatus: 'active',
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(echu.canAddProduct(0), isFalse);
    });

    test('le super-admin ignore le plafond', () {
      const sa = UserPlan(maxProducts: 50, subStatus: 'expired',
          isSuperAdmin: true);
      expect(sa.canAddProduct(9999), isTrue);
    });

    test('un compte bloqué ne crée rien', () {
      const bloque =
          UserPlan(maxProducts: 50, subStatus: 'active', isBlocked: true);
      expect(bloque.canAddProduct(0), isFalse);
    });
  });
}
