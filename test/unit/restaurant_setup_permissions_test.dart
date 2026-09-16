import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/permisions/app_permissions.dart';
import 'package:fortress/core/permisions/user_plan.dart';
import 'package:fortress/core/services/restaurant_setup_service.dart';
import 'package:fortress/features/hr/domain/models/employee_permission.dart';

/// DROITS DES ÉTAPES DE LA PAGE « CONFIGURATION » DU RESTAURANT.
///
/// L'écran de mise en route enchaîne des gestes gardés ailleurs : composer la
/// carte (écran Menu) et enregistrer un achat d'ingrédient (hub Finances). Tant
/// qu'il ne consultait aucune permission, il les rouvrait tous les deux à
/// n'importe quel membre — un serveur créait un plat, fixait son prix et
/// inscrivait une dépense dans la comptabilité.
///
/// Ce test porte sur `RestaurantSetupStep.allowedFor`, c'est-à-dire sur la règle
/// que l'écran applique RÉELLEMENT — pas sur `AppPermissions` en général, qu'il
/// aurait passé aussi bien avant le correctif qu'après.
///
/// Ce qu'il ne couvre pas, et qu'aucun test de ce dépôt ne couvre : le rendu
/// lui-même (le bouton cède la place à une mention). Il n'y a pas de test widget
/// ici, et la page dépend de Hive, de Riverpod et du shell — la vérification
/// visuelle reste manuelle.
void main() {
  // Abonnement actif : sans lui, `canAddProduct` et `canManageExpenses` sont
  // faux pour tout le monde et les cas ne se distingueraient plus.
  const plan = UserPlan(plan: PlanName.pro, subStatus: 'active');

  const serveur = AppPermissions(plan: plan, shopRole: 'user');
  const gerant = AppPermissions(plan: plan, shopRole: 'admin');

  group('Configuration restaurant — droits des étapes', () {
    test('un serveur ne compose pas la carte et ne saisit aucun achat', () {
      expect(RestaurantSetupStep.needsMenuItem.allowedFor(serveur), isFalse,
          reason: 'étape 2 — créer un plat et fixer son prix');
      expect(
          RestaurantSetupStep.needsIngredientCost.allowedFor(serveur), isFalse,
          reason: 'étape 3 — enregistrer un achat d\'ingrédient');
    });

    test('créer une table reste ouvert à tout membre', () {
      // Le Plan de salle, vers lequel l'étape 1 ne fait que renvoyer, ne garde
      // pas la création non plus. Fermer ici et pas là-bas déplacerait
      // l'incohérence au lieu de la corriger.
      expect(RestaurantSetupStep.needsTable.allowedFor(serveur), isTrue);
    });

    test('le gérant fait les trois étapes', () {
      for (final step in RestaurantSetupStep.values) {
        expect(step.allowedFor(gerant), isTrue, reason: step.name);
      }
    });

    test(
        'un employé à qui le gérant a délégué la carte la compose ici aussi, '
        'sans toucher aux achats', () {
      // C'est le cas qui interdit de garder cet écran sur le simple rôle : cet
      // employé compose la carte depuis l'écran Menu. S'il en était écarté ici,
      // le même droit vaudrait ou non selon l'écran par lequel il passe.
      const delegue = AppPermissions(
        plan: plan,
        shopRole: 'user',
        customPermissions: MemberPermissions(
          grants: {EmployeePermission.inventoryWrite},
        ),
      );

      expect(RestaurantSetupStep.needsMenuItem.allowedFor(delegue), isTrue);
      expect(
          RestaurantSetupStep.needsIngredientCost.allowedFor(delegue), isFalse,
          reason: 'déléguer la carte ne délègue pas la comptabilité');
    });

    test('le propriétaire passe partout, sans grant explicite', () {
      const owner =
          AppPermissions(plan: plan, shopRole: 'user', isShopOwner: true);

      for (final step in RestaurantSetupStep.values) {
        expect(step.allowedFor(owner), isTrue, reason: step.name);
      }
    });

    test('un abonnement expiré referme les deux étapes d\'écriture', () {
      // `canAddProduct` et `canManageExpenses` exigent un abonnement actif. Un
      // gérant dont le plan a expiré ne doit donc pas non plus passer par ce
      // parcours pour écrire.
      const expire = AppPermissions(
        plan: UserPlan(plan: PlanName.pro, subStatus: 'expired'),
        shopRole: 'admin',
      );

      expect(RestaurantSetupStep.needsMenuItem.allowedFor(expire), isFalse);
      expect(
          RestaurantSetupStep.needsIngredientCost.allowedFor(expire), isFalse);
    });
  });
}
