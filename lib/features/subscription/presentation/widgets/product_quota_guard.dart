import 'package:flutter/material.dart';

import '../../../../core/permisions/user_plan.dart';
import '../../../../core/storage/local_storage_service.dart';
import 'subscription_guard.dart' show UpgradeSheet;

/// CONTRÔLE DU QUOTA DE PRODUITS, juste avant d'ouvrir un formulaire de
/// création.
///
/// Le plafond lui-même vit dans [UserPlan.canAddProduct] et le refus s'affiche
/// avec [UpgradeSheet.showQuota] : ce n'est donc pas un second mécanisme, c'est
/// la SÉQUENCE des deux, écrite une fois. Elle était jusqu'ici recopiée à
/// chaque point de création, et le module restaurant — dont les plats sont des
/// produits comme les autres — avait tout simplement été oublié : on y
/// composait une carte sans plafond, quel que soit l'abonnement.
///
/// Le contrôle se fait AVANT d'ouvrir quoi que ce soit, jamais à
/// l'enregistrement : laisser quelqu'un saisir un plat, une photo et un prix
/// pour lui refuser la sauvegarde ensuite, c'est lui faire perdre sa saisie.
/// C'est aussi ce que fait l'inventaire e-commerce, qui teste avant de proposer
/// son choix de mode de création.
///
/// Le bouton, lui, reste actionnable — ni masqué ni grisé. C'est le geste qui
/// est intercepté, et il répond par une explication chiffrée : un bouton
/// disparu ou grisé n'aurait jamais dit qu'il s'agit d'une limite d'abonnement,
/// ni combien il en reste.
class ProductQuotaGuard {
  ProductQuotaGuard._();

  /// Libellé du quota côté restaurant.
  ///
  /// L'e-commerce affiche « Inventaire », le nom de son écran. Un restaurateur
  /// n'a pas d'écran Inventaire : sa carte s'appelle Menu et ce qu'il y compte,
  /// ce sont des plats. Même phrase, même chiffres, mais le mot désigne ce
  /// qu'il voit. Défini ici pour que les deux écrans du parcours restaurant ne
  /// puissent pas se mettre à dire deux choses différentes.
  static const String dishesLabel = 'Plats';

  /// La boutique peut-elle accueillir un produit de plus ?
  ///
  /// Renvoie `true` si oui — l'appelant continue. Sinon affiche la feuille
  /// « Limite atteinte » et renvoie `false`.
  ///
  /// Le compte est celui de [LocalStorageService.getProductsForShop], qui
  /// EXCLUT les produits supprimés : retirer un plat de la carte libère donc un
  /// emplacement, et le restaurer en reprend un.
  static bool ensureCanAdd(
    BuildContext context, {
    required UserPlan plan,
    required String shopId,
    required String label,
  }) {
    final count = LocalStorageService.getProductsForShop(shopId).length;
    if (plan.canAddProduct(count)) return true;
    UpgradeSheet.showQuota(context,
        label: label, current: count, max: plan.maxProducts);
    return false;
  }
}
