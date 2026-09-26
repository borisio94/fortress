import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/service_tabs.dart';

/// LA COULEUR ET L'ICÔNE D'UN RANG DE SERVICE.
///
/// Séparé de `service_tabs.dart` pour que la règle reste du Dart pur : le
/// domaine dit DANS QUEL RANG tombe une commande, la présentation dit à quoi
/// ça ressemble. (`sale.dart` mélange déjà les deux, avec son `Color get
/// color` en plein domaine — on n'ajoute pas à cette dette.)
///
/// UNE SEULE SOURCE POUR TOUT L'ÉCRAN. L'onglet, la pastille de la carte et le
/// liseré lisent le même rang et donc la même couleur. Avant, la pastille
/// portait son propre vocabulaire — « Prête », « Servie », « Terminée » — et
/// un onglet nommé autrement l'aurait contredite à trois centimètres. Pire :
/// elle écrivait « Terminée » pour `finished` ET pour `completed`, deux états
/// qui n'ont rien à voir — l'un attend l'argent, l'autre l'a reçu.
///
/// LES GLYPHES SONT TOUS DÉJÀ UTILISÉS AILLEURS dans l'écran ou le module :
/// un glyphe Material absent de la police embarquée s'affiche en carré vide,
/// et c'est la précaution qui compte ici plus que le dessin idéal.
extension ServiceTabVisuals on ServiceTab {
  /// L'icône de l'ÉTAT, pas de l'action.
  ///
  /// Distinct du bouton de chronologie, qui porte l'icône de ce qu'on va
  /// FAIRE : « À envoyer » y montre une flamme parce qu'on va envoyer en
  /// préparation. Sur un onglet, la flamme dirait que la cuisine travaille —
  /// exactement le contraire.
  IconData get icon => switch (this) {
        ServiceTab.toutes => Icons.receipt_long_outlined,
        ServiceTab.aEnvoyer => Icons.inbox_outlined,
        ServiceTab.enPreparation => Icons.local_fire_department_rounded,
        ServiceTab.aServir => Icons.room_service_outlined,
        ServiceTab.aTerminer => Icons.check_circle_outline_rounded,
        ServiceTab.aEncaisser => Icons.payments_outlined,
        ServiceTab.encaissees => Icons.done_all_rounded,
        ServiceTab.sansSuite => Icons.cancel_outlined,
      };

  /// La couleur du rang — pastille, liseré et bouton principal la partagent.
  ///
  /// DEUX ALERTES SEULEMENT, et c'est le point. « À envoyer » est en danger
  /// parce qu'une commande que personne n'a acquittée est une anomalie, pas
  /// une étape ; « À servir » est en succès parce que le plat est PRÊT — la
  /// couleur dit « prends-le », pas « quelque chose ne va pas ».
  ///
  /// Les deux fins de course sont atténuées : elles n'appellent rien. Elles se
  /// distinguent par l'icône, jamais par la seule teinte — une alerte qui ne
  /// tient qu'à une couleur n'existe pas pour qui ne distingue pas le rouge.
  Color color(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    return switch (this) {
      ServiceTab.toutes => cs.onSurfaceVariant,
      ServiceTab.aEnvoyer => sem.danger,
      ServiceTab.enPreparation => sem.warning,
      ServiceTab.aServir => sem.success,
      ServiceTab.aTerminer => sem.info,
      ServiceTab.aEncaisser => cs.primary,
      ServiceTab.encaissees => cs.onSurfaceVariant,
      ServiceTab.sansSuite => cs.onSurfaceVariant,
    };
  }

  /// La couleur du LISERÉ d'état (`kStateStripeWidth`), liste ET grille.
  ///
  /// UNE COMMANDE TERMINÉE RECULE, SON LISERÉ AUSSI. Il portait
  /// `onSurfaceVariant` : 8,73–8,82:1 sur son fond en clair, le trait le plus
  /// marqué de l'écran, sur les cartes qui doivent s'effacer. Il passe à
  /// `outlineVariant`, le gris de la même famille neutre, mesuré sur les huit
  /// palettes contre le fond d'une carte terminée :
  ///
  ///               clair        sombre
  ///   terminée    1,59–1,60    1,90–1,92
  ///   active min  2,15         4,50
  ///
  /// Visible, et sous le plus faible des liserés actifs dans les deux modes.
  /// Écartés : `outline` (4,19–4,23 en clair, plus marqué que trois états
  /// actifs) et `borderSubtle` (1,16 en clair : il ne se voit plus).
  ///
  /// LES ACTIFS, contre la carte, en clair : « À envoyer » 3,76 · « En
  /// préparation » 2,15 · « À servir » 2,54 · « À terminer » 3,68 · « À
  /// encaisser » (la marque) de 2,54 (emerald) à 14,63 (midnight), sous 3:1
  /// sur ocean, emerald et sunset. En sombre, tous à 4,50 ou plus. Sous 3:1,
  /// le liseré n'est admissible QUE parce que le badge écrit l'état à côté —
  /// retirer le badge, c'est laisser la couleur seule.
  Color stripeColor(BuildContext context) => isSettled
      ? Theme.of(context).colorScheme.outlineVariant
      : color(context);

  /// Variante LISIBLE SUR FOND CLAIR — texte de pastille, libellé de liseré.
  ///
  /// Le token suit son fond, c'est la règle du module : `warning` est calibré
  /// pour un fond sombre ou une icône, `warningText` pour une surface claire.
  Color textColor(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    return switch (this) {
      ServiceTab.aEnvoyer => sem.dangerText,
      ServiceTab.enPreparation => sem.warningText,
      ServiceTab.aServir => sem.successText,
      // « À encaisser » écrit une INFORMATION (badge, chronomètre) : en
      // `onSurface`, pas en primaire — la primaire en texte tombe à 2,38–3,31
      // en clair sur 5 palettes, et sur sa propre teinte elle échoue aussi en
      // sombre (3,68–4,58 sur 7 palettes). L'ACTION garde la primaire :
      // `actionTextColor`.
      ServiceTab.aEncaisser => cs.onSurface,
      // `info` (« À terminer ») : une information se dit sans couleur (§ 16).
      _ => cs.onSurfaceVariant,
    };
  }

  /// Libellé d'un BOUTON d'action (`_StateButton`) — `textColor`, sauf
  /// « À encaisser », qui garde la couleur de marque : un bouton qui perd sa
  /// couleur perd son signal d'action. `brandText`, et non `colorScheme.
  /// primary` : le bouton pose son libellé sur SA TEINTE, où seule `brandText`
  /// tient 4,5:1 dans les deux modes (lot 1 clair, 26/09/2026).
  Color actionTextColor(BuildContext context) => this == ServiceTab.aEncaisser
      ? Theme.of(context).semantic.brandText
      : textColor(context);
}
