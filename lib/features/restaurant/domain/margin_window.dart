/// À QUELLE FENÊTRE UNE MARGE A-T-ELLE UN SENS — règles pures.
///
/// En mode répartition — le mode par défaut — les achats d'une période sont
/// partagés entre les plats vendus de CETTE période. Un marché fait lundi
/// donne donc un coût matières énorme lundi et proche de zéro mardi, sur
/// exactement les mêmes plats. Le chiffre existe ; il ne mesure rien.
///
/// La section 6 de `docs/fortress-definition-financiere-restaurant.md` le
/// tranche : « Une seule fenêtre fait autorité : le mois. Aucune marge
/// journalière ou hebdomadaire n'a de sens. Toute période plus courte que le
/// mois sert à consulter des volumes — nombre de commandes, ventes
/// encaissées — pas des marges. »
///
/// LES VOLUMES RESTENT VISIBLES PARTOUT. « Hier » sert tous les matins : ce
/// sont les ventes encaissées qu'on y cherche, pas une rentabilité. Seuls les
/// indicateurs qui divisent des achats par des ventes se retirent.
library;

import '../../dashboard/data/dashboard_providers.dart';

/// Durée minimale, en jours, pour qu'une marge signifie quelque chose.
///
/// 28 et non 30 : c'est la longueur du plus court mois civil. Une fenêtre qui
/// couvre un février entier doit porter sa marge, sinon la règle contredirait
/// la section 6 deux jours par an.
///
/// Ne sert QU'À LA PÉRIODE LIBRE — voir [marginsMakeSenseOn].
const int kMinMarginDays = 28;

/// Cette période permet-elle d'afficher une marge ?
///
/// LA RÈGLE PORTE SUR LA NATURE DE LA PÉRIODE, pas sur sa durée écoulée, et
/// c'est le piège de cette règle — il a été livré une fois avant d'être vu.
///
/// Le mois civil commence le 1er. Juger ce qu'il s'en est écoulé masquerait
/// les marges du 1er au 28, soit vingt-huit jours sur trente, sur la SEULE
/// fenêtre que la section 6 rend autoritaire : « Mois » n'aurait plus montré
/// ses marges que les 29 et 30. L'inverse exact de l'intention.
///
/// Un mois en cours EST le mois, même le 3. Il est court, donc bruyant, et le
/// gérant le sait puisqu'il a choisi « Mois » en début de mois. Le trimestre
/// et l'année commencent courts pour la même raison et comptent de même.
///
/// [DashPeriod.custom] fait exception parce qu'elle n'annonce aucune
/// intention : elle peut valoir trois jours comme trois ans, et seule sa
/// longueur renseigne.
bool marginsMakeSenseOn(DashPeriod period, DashRange range) =>
    switch (period) {
      DashPeriod.today || DashPeriod.yesterday || DashPeriod.week => false,
      DashPeriod.month || DashPeriod.quarter || DashPeriod.year => true,
      DashPeriod.custom => range.duration.inDays >= kMinMarginDays,
    };

/// Ce qu'on dit à la place, quand elles n'en ont pas.
///
/// LA RAISON, ET NON L'ABSENCE. « Non disponible sur cette période » ne
/// s'apprend pas : le gérant change de période, ne comprend pas, et finit par
/// croire à une panne. La mécanique, elle, s'apprend une fois — et elle
/// explique du même coup pourquoi son food cost bougeait tant d'un jour à
/// l'autre.
String get marginsUnavailableReason =>
    'Les achats d\'une période se répartissent sur ses ventes : '
    'sur moins d\'un mois, la marge n\'a pas de sens. '
    'Choisissez « Mois » pour la consulter.';
