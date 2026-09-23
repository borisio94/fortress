/// DEPUIS COMBIEN DE TEMPS CETTE TABLE EST-ELLE OUVERTE.
///
/// Le plan de salle ne le disait pas. Une table ouverte depuis dix minutes et
/// une table oubliée depuis vendredi soir s'y affichaient de façon
/// **strictement identique** : même couleur, même libellé, même tout.
///
/// La donnée existait pourtant déjà. `RestaurantTable.openedAt` est écrit à
/// l'ouverture du service et remis à `null` à la libération ; et
/// `RestaurantOrderService.mealDuration` la lit — mais depuis un seul endroit,
/// `bill_page.dart`. Le temps de repas n'était donc visible qu'en ouvrant
/// l'addition, une table à la fois, c'est-à-dire jamais pour celle que
/// personne ne regarde plus.
///
/// POURQUOI DEUX SEUILS ET NON UN.
///
/// Un seuil unique assez bas pour attraper la table oubliée peindrait en
/// alerte, un samedi soir, toutes les tablées de douze qui dînent depuis
/// quatre heures — et une alerte qui se déclenche pendant le service normal
/// cesse d'être lue au bout d'une semaine. Un seuil unique assez haut, lui,
/// laisserait passer la table qu'on aurait pu rattraper le soir même.
///
/// Les deux faits sont distincts et méritent deux réponses :
///   • un repas LONG est un fait de service, pas une anomalie — on le signale
///     sans dramatiser, parce qu'il change la façon dont on place les clients ;
///   • une table DORMANTE a traversé une fermeture. Plus personne n'y est
///     assis. C'est une erreur de saisie ou un départ non enregistré, et il
///     faut aller voir.
///
/// AUCUNE LIBÉRATION AUTOMATIQUE n'est déduite d'ici, et c'est délibéré :
/// `RestaurantTableService.release` détache les commandes non réglées de la
/// table. Un ménage automatique ferait donc disparaître des additions
/// impayées du plan de salle sans que personne l'ait décidé. Ce fichier
/// DÉCRIT ; il ne décide pas.
library;

/// Ce que le temps écoulé dit du service en cours.
enum TableService {
  /// Un service en cours, d'une durée ordinaire. Rien à signaler.
  courte,

  /// Un repas qui dure. Fait de service, pas anomalie.
  longue,

  /// La table a traversé une fermeture : personne n'y est plus assis.
  dormante,
}

/// Au-delà, le repas est LONG — une grande tablée, un groupe qui s'attarde.
///
/// Quatre heures et non trois : un déjeuner d'affaires ou une tablée du samedi
/// soir tient trois heures sans que rien n'aille mal, et une alerte qui se
/// déclenche en plein service ordinaire n'est plus lue au bout d'une semaine.
const Duration kTableServiceLong = Duration(hours: 4);

/// Au-delà, la table est DORMANTE : elle a traversé la fermeture.
///
/// Douze heures couvrent le cas qui a motivé ce fichier — la table ouverte un
/// vendredi soir et retrouvée occupée le lundi — sans jamais pouvoir se
/// déclencher pendant un service, fût-il le plus long de l'année.
const Duration kTableServiceDormant = Duration(hours: 12);

/// Depuis quand cette table est ouverte, ou `null` si on ne peut pas le dire.
///
/// `null` dans deux cas, et un seul est une absence de donnée :
///   • la table n'a pas d'heure d'ouverture — elle est libre, ou sa fiche est
///     antérieure au champ ;
///   • l'écart est NÉGATIF. L'horloge de l'appareil est mal réglée, ou la
///     table a été ouverte depuis un autre poste moins en retard. Mieux vaut
///     ne rien afficher qu'un « ouverte depuis −3 h », qui ferait douter de
///     tout le reste de l'écran. C'est la même garde que
///     `RestaurantOrderService.mealDuration`, tenue au même endroit qu'elle.
Duration? tableOpenFor({DateTime? openedAt, required DateTime now}) {
  if (openedAt == null) return null;
  final d = now.difference(openedAt);
  return d.isNegative ? null : d;
}

/// Le niveau d'alerte correspondant à une durée d'ouverture.
TableService tableServiceOf(Duration open) {
  if (open >= kTableServiceDormant) return TableService.dormante;
  if (open >= kTableServiceLong) return TableService.longue;
  return TableService.courte;
}

/// La durée, écrite comme un serveur la lit d'un coup d'œil en passant.
///
/// TROIS FORMES, ET LA PRÉCISION DÉCROÎT AVEC L'ANCIENNETÉ. Sous l'heure, la
/// minute compte — c'est le temps d'attente d'un client. Au-delà, l'heure
/// suffit. Au-delà du jour, seul le nombre de jours a un sens : « 62 h » ne se
/// lit pas, « 2 j » se comprend sans compter.
String tableServiceLabel(Duration open) {
  if (open.inDays >= 1) return '${open.inDays} j';
  if (open.inHours >= 1) {
    final m = open.inMinutes % 60;
    return m == 0 ? '${open.inHours} h' : '${open.inHours} h ${m.toString().padLeft(2, '0')}';
  }
  return '${open.inMinutes} min';
}
