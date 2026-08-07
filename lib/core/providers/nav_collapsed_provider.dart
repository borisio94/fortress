import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../storage/hive_boxes.dart';

/// Clé Hive de l'état rétracté de la barre de navigation desktop.
const String kNavCollapsedKey = 'nav_rail_collapsed';

/// Barre de navigation desktop rétractée (icônes seules) ou déployée.
///
/// L'état est **volontairement à trois valeurs** :
///   * `true`  — l'utilisateur a rétracté la barre ;
///   * `false` — l'utilisateur l'a déployée ;
///   * `null`  — il n'a rien choisi, on applique le défaut du secteur.
///
/// Sans le troisième cas, il faudrait choisir un défaut unique pour toute
/// l'app : la restauration s'ouvrirait déployée (alors que le service réclame
/// l'écran entier pour la carte), ou l'e-commerce s'ouvrirait rétracté et
/// changerait d'aspect sans que personne l'ait demandé. Le défaut par secteur
/// est calculé à l'affichage — cf. `navCollapsedFor`.
///
/// Persisté dans la box `settings` : sur web l'utilisateur recharge la page à
/// chaque déploiement, un état en mémoire seule serait perdu à chaque fois.
final navCollapsedProvider =
    NotifierProvider<NavCollapsedNotifier, bool?>(NavCollapsedNotifier.new);

class NavCollapsedNotifier extends Notifier<bool?> {
  @override
  bool? build() {
    try {
      if (!Hive.isBoxOpen(HiveBoxes.settings)) return null;
      final v = HiveBoxes.settingsBox.get(kNavCollapsedKey);
      return v is bool ? v : null;
    } catch (e) {
      debugPrint('[NavCollapsed] read error: $e');
      return null;
    }
  }

  Future<void> set(bool collapsed) async {
    if (state == collapsed) return;
    state = collapsed;
    try {
      await HiveBoxes.settingsBox.put(kNavCollapsedKey, collapsed);
    } catch (e) {
      debugPrint('[NavCollapsed] persist error: $e');
    }
  }
}

/// État effectif pour une boutique donnée : le choix de l'utilisateur s'il en
/// a fait un, sinon le défaut du secteur.
///
/// **Défaut restauration = rétracté** : la prise de commande se fait sur la
/// carte, et les libellés de navigation lui prenaient un quart de la largeur
/// pour une information que les icônes portent déjà. **Défaut ailleurs =
/// déployé** : l'e-commerce garde exactement l'aspect qu'il avait.
bool navCollapsedFor(bool? stored, {required bool isRestaurant}) =>
    stored ?? isRestaurant;
