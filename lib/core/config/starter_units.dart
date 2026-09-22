/// LES UNITÉS QU'UNE BOUTIQUE NEUVE REÇOIT.
///
/// Elle n'en recevait aucune. `getUnits` rendait une liste vide, sans repli, et
/// `createShop` n'en écrivait pas : le premier produit saisi butait sur un
/// champ « unité » sans aucun choix, et il fallait comprendre qu'on pouvait en
/// créer — dans un écran de paramètres qu'on ne cherche pas quand on est en
/// train de saisir une fiche produit.
///
/// POURQUOI LES UNITÉS ET PAS LES CATÉGORIES. Une unité ne porte aucun sens
/// métier : « kg » est « kg » dans toutes les boutiques du monde, personne ne
/// va la renommer ni la supprimer. Une catégorie, si — en inventer pour le
/// commerçant l'obligerait à défaire avant de faire. Les catégories restent
/// donc vides, et c'est leur ÉTAT VIDE qui nomme la notion.
///
/// Ce sont des propositions, pas un cadre : la liste est modifiable dès le
/// premier jour, et rien ne casse si on la vide entièrement.
library;

import 'restaurant_mode.dart';

/// Commerce de détail et vente en ligne.
///
/// La pièce d'abord : c'est l'unité de la quasi-totalité des lignes, et celle
/// qu'on cherche en premier dans une liste déroulante.
const List<String> kStarterUnitsRetail = [
  'pièce',
  'kg',
  'g',
  'L',
  'carton',
];

/// Restauration.
///
/// Le poids d'abord, parce qu'un ingrédient s'achète au kilo. Le « sac »
/// figure parce que le riz, la farine et le charbon s'achètent ainsi au
/// Cameroun, et qu'aucune unité métrique ne le remplace dans la tête du
/// gérant au moment de saisir sa réception.
const List<String> kStarterUnitsRestaurant = [
  'kg',
  'g',
  'L',
  'cL',
  'pièce',
  'sac',
];

/// Les unités proposées à la création d'une boutique de ce [sector].
///
/// REPLI SUR LE DÉTAIL, jamais sur le vide : un secteur legacy — `supermarche`,
/// `pharmacie`, `autre` — ou un secteur absent n'a aucune raison de se
/// retrouver sans unités. C'est justement le cas qu'on vient de refermer.
List<String> starterUnitsFor(String? sector) => isRestaurantSector(sector)
    ? kStarterUnitsRestaurant
    : kStarterUnitsRetail;
