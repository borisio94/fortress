/// CE QUE COÛTE UNE LIVRAISON — règles pures.
///
/// Le client paie des frais, l'établissement les encaisse, un livreur est
/// nommé — et rien ne disait ce qu'il reçoit. Ni recette, ni charge : deux
/// flux réels, invisibles tous les deux. C'était le dernier écart de la
/// section 8 de `docs/fortress-definition-financiere-restaurant.md`.
///
/// LE PLUS GRAVE N'ÉTAIT PAS LE REPORTING, C'ÉTAIT LA CAISSE. Le livreur de
/// dépannage est payé en espèces, du tiroir, le soir même. `cashOut` ne le
/// savait pas — il ne somme que les dépenses du jour et les sorties du
/// personnel. Chaque livraison ainsi payée apparaissait donc à la clôture
/// aveugle comme un MANQUANT imputé au caissier, exactement comme les avances
/// sur salaire avant qu'on les y ajoute.
///
/// Écrire la dépense suffit à refermer ce manquant : `cash_closure_service`
/// somme déjà `DailyExpenseService.cashOut`, qui filtre sur `isCash`.
library;

import 'entities/daily_expense.dart';

/// Montant proposé au livreur, avant modification.
///
/// LES FRAIS EN ENTIER pour un livreur de dépannage — c'est le cas courant :
/// le client paie mille francs de course, le voisin qui l'a faite les reçoit.
/// Le champ reste modifiable pour l'établissement qui garde une part.
///
/// ZÉRO POUR UN SALARIÉ, et automatiquement. C'est le piège de cette règle :
/// laisser le champ pré-rempli sur quelqu'un dont le coût est déjà dans la
/// paie ferait payer la même course DEUX FOIS — une fois en espèces le soir,
/// une fois à la quinzaine. Le remettre à zéro à la main suppose que personne
/// n'oublie ; s'en remettre à cette hypothèse, c'est la voir échouer.
double courierPayDefault({
  required double deliveryFee,
  required bool courierIsStaff,
}) =>
    courierIsStaff ? 0 : deliveryFee;

/// Ce versement donne-t-il lieu à une dépense ?
///
/// Un versement nul n'en produit aucune : le salarié, ou la course offerte.
/// Une dépense à zéro polluerait le journal sans rien apprendre, et ferait
/// apparaître une ligne « Transport · 0 F » à chaque livraison interne.
bool courierPayNeedsExpense(double paidToCourier) => paidToCourier > 0;

/// Catégorie sous laquelle le versement est enregistré.
///
/// UNE CHARGE, jamais un coût matière : payer un livreur n'achète aucun
/// ingrédient, et le montant ne doit pas entrer dans l'assiette répartie sur
/// les plats vendus — il gonflerait leur coût sans les avoir nourris.
const ExpenseKind kCourierExpenseKind = ExpenseKind.transport;

/// Recette d'une commande : articles nets, ET les frais de livraison.
///
/// La section 2 les excluait, avec sa raison : « recette réelle, mais aucune
/// ligne ne retranche le coût du livreur. Dette ouverte : à intégrer avec sa
/// charge, pas seule. » La charge existe désormais ; la condition est remplie.
///
/// CONSÉQUENCE À CONNAÎTRE : le chiffre d'affaires affiché MONTE du montant
/// des livraisons, sans qu'aucune vente ait changé. Le bénéfice, lui, ne bouge
/// que de la différence entre les frais encaissés et ce qui est versé au
/// livreur — ce qui est exactement ce que l'établissement gagne à livrer.
double orderRevenueOf({
  required double itemsNet,
  required double deliveryFee,
}) =>
    itemsNet + deliveryFee;
