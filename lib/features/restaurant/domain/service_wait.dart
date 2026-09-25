/// L'ATTENTE D'UNE COMMANDE DANS SON ÉTAT DE SERVICE (hotfix_183, 25/09/2026).
///
/// Trois fonctions pures, testées, et le seul endroit qui décide :
///   • [serviceStateStamp] — QUAND dater. Une seule règle, appliquée par
///     `RestaurantOrderService._patchOrder` et `sendRound` : toute écriture
///     qui touche un drapeau de service pose `service_state_at`.
///   • [serviceWait] — COMBIEN de temps dans l'état courant.
///   • [lateThresholdFor] / [isServiceLate] — À PARTIR DE QUAND c'est un
///     retard.
///
/// ─── PAS DE REPLI SUR `createdAt` ───────────────────────────────────────────
///
/// Une commande antérieure à la colonne n'a pas de date d'état : [serviceWait]
/// rend alors `null`, et l'écran n'affiche AUCUN chronomètre. Mesurer l'âge de
/// la commande à la place donnerait « 9 h » sur une table ouverte le matin et
/// encaissée le soir — mieux vaut pas de chronomètre qu'un faux.
library;

import '../../caisse/domain/entities/sale.dart';
import 'service_tabs.dart';

/// Les quatre drapeaux de la chronologie du service (`orders`). Toucher l'un
/// d'eux, c'est changer d'état — donc dater.
const Set<String> kServiceFlagKeys = {
  'sent_to_kitchen',
  'kitchen_ready',
  'served',
  'finished',
};

/// Colonne de l'instant d'entrée dans l'état courant.
const String kServiceStateAtKey = 'service_state_at';

/// Le patch à écrire, daté s'il change l'état de service.
///
/// Rend [fields] tel quel s'il ne touche aucun drapeau (un changement de
/// moyen de paiement seul, un motif d'annulation) : ce n'est pas une
/// transition, l'attente en cours ne doit pas repartir de zéro.
///
/// L'ENCAISSEMENT DATE AUSSI (il force `served` et `finished`) : une date
/// juste qui ne sert à rien aujourd'hui vaut mieux qu'un trou découvert le jour
/// où l'on voudra mesurer le temps entre le service et le paiement.
Map<String, dynamic> serviceStateStamp(
    Map<String, dynamic> fields, DateTime now) {
  if (!fields.keys.any(kServiceFlagKeys.contains)) return fields;
  return {...fields, kServiceStateAtKey: now.toUtc().toIso8601String()};
}

/// Le temps passé dans l'état de service courant, ou `null` si la commande
/// n'a pas de date d'état (antérieure au 25/09/2026) — jamais l'âge de la
/// commande à la place. Jamais négatif (horloges d'appareils décalées).
Duration? serviceWait(Sale order, DateTime now) {
  final since = order.serviceStateAt;
  if (since == null) return null;
  final d = now.difference(since);
  return d.isNegative ? Duration.zero : d;
}

/// Le seuil de retard d'un rang, en minutes, ou `null` pour un rang qui n'en
/// a pas.
///
/// Trois rangs seulement, ceux où l'attente coûte : une commande que personne
/// n'a prise en charge, une cuisine qui tarde, un plat qui refroidit au passe.
/// « À terminer » (le client mange) et « À encaisser » n'ont pas de retard :
/// leur durée appartient au client.
int? lateThresholdFor(
  ServiceTab tab, {
  required int sendMin,
  required int kitchenMin,
  required int passMin,
}) =>
    switch (tab) {
      ServiceTab.aEnvoyer => sendMin,
      ServiceTab.enPreparation => kitchenMin,
      ServiceTab.aServir => passMin,
      _ => null,
    };

/// La commande est-elle en retard dans son état ? `false` sans date d'état ou
/// sans seuil pour ce rang.
bool isServiceLate(
  Sale order,
  DateTime now, {
  required int sendMin,
  required int kitchenMin,
  required int passMin,
}) {
  final wait = serviceWait(order, now);
  final limit = lateThresholdFor(serviceTabOf(order),
      sendMin: sendMin, kitchenMin: kitchenMin, passMin: passMin);
  if (wait == null || limit == null) return false;
  return wait >= Duration(minutes: limit);
}

/// Le chronomètre, en mots courts : « 3 min », « 24 min », « 1 h 05 ».
///
/// Sous une minute : « < 1 min » — « 0 min » se lirait comme une panne.
String formatServiceWait(Duration d) {
  if (d.inMinutes < 1) return '< 1 min';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  return '$h h ${m.toString().padLeft(2, '0')}';
}
