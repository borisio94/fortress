import 'package:flutter/material.dart';

import 'restaurant_mode.dart';

/// COULEUR D'IDENTITÉ d'un secteur — sur les cartes de choix à la création.
///
/// Ce sont des couleurs de MARQUE, pas de statut, et c'est pour ça qu'elles
/// restent des valeurs fixes au lieu de passer par la palette ou les jetons
/// sémantiques.
///
/// Les mapper sur `semantic.warning / danger / success` aurait été une faute
/// de sens : « restaurant = danger » ne veut rien dire, et le jour où le rouge
/// d'erreur changerait, le secteur Restaurant changerait avec lui. Les mapper
/// sur la palette aurait été pire — les trois secteurs auraient changé de
/// couleur à chaque changement de thème, alors qu'un secteur est une identité
/// stable.
///
/// Elles étaient écrites en clair dans `create_shop_page`, au milieu d'un
/// écran par ailleurs tokenisé, où rien ne les distinguait d'un oubli.
///
/// FICHIER À PART, et non dans `restaurant_mode.dart` : celui-ci ne dépend
/// PAS de Flutter, et l'y faire entrer pour trois couleurs aurait alourdi un
/// fichier de configuration que des règles pures utilisent.
const Map<String, Color> kSectorColors = <String, Color>{
  'ecommerce':  Color(0xFFF59E0B), // ambre
  'restaurant': Color(0xFFEF4444), // rouge
  'fastfood':   Color(0xFF10B981), // vert
};

/// Couleur du secteur [key], avec un repli neutre.
///
/// Le repli ne devrait jamais servir : un test vérifie que chaque secteur
/// proposé à la création a la sienne. Il est là pour qu'un secteur legacy
/// — `retail`, `pharmacie` — n'ouvre pas une exception à l'écran.
Color sectorColor(String key) =>
    kSectorColors[key] ?? const Color(0xFF6B7280);

/// Les secteurs proposés à la création ont-ils tous une couleur ?
///
/// Exposé pour le test : c'est l'invariant qui empêche un quatrième secteur
/// d'arriver sans identité visuelle, et de tomber en gris sans que personne
/// ne le remarque.
Iterable<String> get sectorsWithoutColor =>
    kCreationSectors.map((s) => s.key).where((k) => !kSectorColors.containsKey(k));
