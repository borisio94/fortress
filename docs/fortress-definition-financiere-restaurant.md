# Fortress POS — Définition financière, module restaurant

Document de référence. Toute question du type « est-ce que X compte dans
le CA ? » se tranche ici, pas dans une discussion.

Dernière révision : session du 18/09/2026.
Périmètre : boutiques dont `shops.sector` vaut restaurant, fastfood ou mixed.
Emplacement de référence : `docs/` du dépôt. Une définition qui vit ailleurs se
périme sans que personne ne le sache.

---

## 1. La règle de décision

Avant d'ajouter une ligne d'argent au système, répondre à trois questions
dans cet ordre.

**Est-ce que l'argent reste à la boutique ?**
Non → ce n'est ni une recette ni une charge. C'est un flux de passage.
Les consignes de bouteilles sont le seul cas aujourd'hui : encaissées puis
rendues, elles n'entrent nulle part.

**Est-ce que le client paie pour l'obtenir ?**
Oui → c'est une recette, donc du chiffre d'affaires.
Un emballage vendu, un supplément, un couvert facturé : ce sont des
recettes. Le fait qu'ils ne soient pas des plats ne change rien.

**Est-ce que la boutique paie pour l'obtenir ?**
Oui → c'est une charge. Elle se classe selon ce qu'elle achète :
matière si elle finit dans une assiette, exploitation sinon.

**Règle de symétrie, non négociable.** Si le coût d'achat d'une chose entre
en charge, sa vente doit entrer en recette. L'inverse aussi. Toute exception
doit être écrite ici avec sa raison, sinon c'est un bug.

---

## 2. Le chiffre d'affaires

**Compte** : les commandes au statut `completed`, et elles seules.

**Formule** : `(articles − remise de commande) × (1 + TVA) + livraison`

Les **frais de livraison** s'ajoutent **bruts**, ni remisés ni taxés : la
remise de l'addition porte sur les plats, pas sur la course. Ils sont entrés
dans le CA le **21/09/2026** ; jusque-là ils en étaient exclus, faute d'une
ligne qui portât le coût du livreur — voir la section 9.

**N'entre pas dans le CA :**

| Élément | Raison |
|---|---|
| Consignes de bouteilles | Caution rendue au client, flux de passage |

**Le CA n'est pas le chiffre des plats.** Deux montants, et les confondre
fausse tous les ratios de matière :

| Montant | Ce qu'il porte | Ce qu'il sert à calculer |
|---|---|---|
| **CA** | plats + livraison | recette, bénéfice, courbe du tableau de bord |
| **Ventes de plats** | plats seuls | food cost, couverture du coût, marge par secteur |

Une course ne porte **aucune matière** : la compter au dénominateur du food
cost diluerait le taux exactement comme le faisaient les boissons sans coût
connu (section 9). Elle n'appartient pas davantage à une **activité** : la somme
des secteurs vaut donc les ventes de plats, jamais le CA.

**Ce qui n'existe pas aujourd'hui** : TVA (`taxRate` reste à 0), pourboire,
frais de service.

**Les drapeaux de service** — envoyé en cuisine, prêt, servi, terminé — sont
indépendants du CA. Une commande servie et non payée ne compte pas.

### Les trois montants

Une même commande porte **trois montants différents**, et les confondre est la
source d'écarts que personne n'explique. Ils ne sont pas en désaccord : ils
répondent à trois questions distinctes.

| Montant | Question | Calcul | Où il sert |
|---|---|---|---|
| **Facturé** | ce que le client doit | `Sale.total` = articles − remise + TVA + livraison + frais | facture, reçu, export |
| **Encaissé** | ce qui est entré dans le tiroir | part réellement payée, espèces uniquement pour la caisse | clôture X/Z |
| **Recette** | ce qui compte comme chiffre d'affaires | la formule ci-dessus, livraison et consignes exclues | bénéfice, food cost, marges |

**Ils diffèrent, et c'est normal.** Le facturé dépasse la recette du montant des
livraisons et des consignes. L'encaissé est inférieur au facturé tant qu'un
client n'a pas soldé. Un restaurant qui vend 500 000 F de plats, 40 000 F de
livraisons et 15 000 F de consignes facture 555 000 F, encaisse 555 000 F si
tout est payé, et déclare 500 000 F de chiffre d'affaires.

**Ce qu'il faut en retenir** : ne JAMAIS rapprocher deux écrans qui n'affichent
pas le même montant sans dire lequel chacun montre. Un export qui somme le
facturé ne tombera jamais d'accord avec un tableau de bord qui affiche la
recette, et aucun des deux n'est faux.

**Règle** : tout écran qui affiche un total d'argent doit pouvoir dire lequel
des trois il montre. Un libellé « Montant » seul est une erreur — c'est
exactement pourquoi l'export des commandes porte « Montant CA » et « Montant
perte » en plus de « Montant ».

---

## 3. Le coût matière

Le choix de méthode se fait **par ingrédient**, et les deux s'additionnent
au sein d'un même plat.

**Répartition** (défaut) — les achats de la période sont partagés entre les
plats vendus, pondérés par la générosité de portion.

```
coût unitaire = achats de l'ingrédient
                ÷ Σ(quantité vendue × poids de portion)
```

Conséquence à connaître : le coût d'un plat dépend de ce qui a été acheté
sur la période, pas de ce qu'il contient. Un ingrédient non acheté ce mois-ci
ne coûte rien au plat qui le porte.

**Fiche technique** — `quantité par portion × coût unitaire`, le coût unitaire
venant des réceptions.

Un plat dont une ligne de fiche est incomplète sort entièrement du calcul :
rendre sa seule part répartie afficherait un coût amputé.

### Un ingrédient sans plat

La conséquence ci-dessus a un revers, et il est arrivé à l'écran le
**21/09/2026** : un ingrédient peut désormais être créé **depuis l'écran
Stock**, sans passer par la recette d'un plat. Auparavant il fallait ouvrir un
plat et composer sa recette — un détour que rien n'annonçait, pour inscrire de
l'huile rouge dans sa réserve.

**Ce que ça produit.** Un achat saisi sur un ingrédient qu'aucun plat ne
contient entre dans l'assiette à répartir et **n'en sort par aucun plat**. Il
grossit le `unallocated` de la répartition, donc les **achats non rattachés**
que la section 9 a appris au tableau de bord à nommer.

**Le chiffre reste juste.** L'identité de cette section l'absorbe —
`vendu + perdu + non réparti + retiré = acheté` — et la décomposition du lot 8
le montre pour ce qu'il est au lieu de l'attribuer à un gaspillage. Ce n'est
pas un écart à corriger : c'est une dépense réelle, en attente d'un plat.

**Règle** : *créer un ingrédient hors recette est permis, et l'écran doit dire
ce que ça implique — jamais l'interdire.* Interdire renverrait le gérant au
détour par la fiche d'un plat, qui était le vrai défaut. Deux garde-fous, et
aucun blocage :

- la feuille de création ouverte **depuis Stock** avertit, dès qu'un montant
  est saisi, que cet achat apparaîtra en achats non rattachés — avec les mots
  exacts du tableau de bord, pour qu'on les reconnaisse aux deux endroits ;
- la liste des ingrédients marque **« aucun plat »** sur ceux qu'aucune recette
  ne reprend. Discret quand rien n'a été acheté — l'ingrédient ne coûte alors
  rien à personne —, en avertissement dès qu'un montant y est rattaché.

**Le geste qui referme** : ajouter l'ingrédient à la recette d'un plat. À
partir de la période suivante, son achat s'impute normalement.

---

## 4. Les pertes

Une perte de matière est **retirée de l'assiette avant le partage**, jamais
ajoutée aux charges. L'identité à vérifier :

```
coût matière + pertes = achats
```

**Une perte entre dans ce mécanisme si elle porte un rattachement** — des
assiettes, ou un ingrédient. C'est le rattachement qui décide, pas la
catégorie.

| Rattachée | Non rattachée |
|---|---|
| Matière : retirée de l'assiette | Charge ordinaire |

Cas sans rattachement possible : casse de vaisselle, matériel endommagé,
écart d'inventaire sur une fourniture. Ils restent des charges.

Une commande annulée, refusée ou remboursée sort du CA et entre en pertes.
Seules les tournées envoyées en cuisine comptent comme matière perdue :
la matière n'est perdue que si elle a été engagée.

---

## 5. Le bénéfice net

```
bénéfice net = chiffre d'affaires
             − coût matière
             − dépenses courantes
             − charges fixes
             − paie
             − pertes non rattachées
```

---

## 6. Les fenêtres de temps

**Une seule fenêtre fait autorité : le mois.**

En répartition, les achats d'une période sont répartis sur les ventes de la
même période. Un marché fait lundi donne un food cost énorme lundi et proche
de zéro mardi. **Aucune marge journalière ou hebdomadaire n'a de sens.**

Toute période plus courte que le mois sert à consulter des volumes — nombre
de commandes, ventes encaissées — pas des marges.

**Appliqué le 21/09/2026.** « Mois » est désormais le **mois civil** sur le
tableau de bord — il valait trente jours glissants, où une paie mensuelle
pouvait tomber deux fois ou pas du tout. Et les indicateurs de marge —
bénéfice, marge brute, food cost — **ne s'affichent plus sur une fenêtre de
moins de 28 jours** (la longueur du plus court mois civil : février doit porter
sa marge).

La règle porte sur la **nature de la période**, et non sur sa durée écoulée.
Un mois en cours EST le mois, même le 3 — il est court, donc bruyant, et le
gérant le sait puisqu'il vient de le choisir. Juger la durée écoulée aurait
masqué les marges du 1er au 28, soit vingt-huit jours sur trente, sur la seule
fenêtre que cette section rend autoritaire.

Seule la période **libre** se juge à la longueur : elle n'annonce aucune
intention et peut valoir trois jours comme trois ans.

À la place, le tableau de bord dit la mécanique plutôt que l'absence — « Les
achats d'une période se répartissent sur ses ventes : sur moins d'un mois, la
marge n'a pas de sens. » Un vide silencieux se lirait comme une panne.

**Les volumes restent visibles sur toutes les périodes** : ventes encaissées,
nombre de commandes, pertes. « Hier » sert tous les matins, et ce n'est pas une
rentabilité qu'on y cherche.

### La convention de bornes

**Une fenêtre est DEMI-OUVERTE : `[début, fin[`.** Le début lui appartient, la
fin appartient à la suivante.

Elle était inclusive des deux côtés sur vingt-deux sites. Or les fenêtres
s'enchaînent — « Hier » finit à minuit, « Aujourd'hui » commence à minuit — et
une vente enregistrée à exactement `00:00:00.000` tombait donc **dans les
deux**. Il suffit d'une commande transférée à minuit pile pour qu'un total
cesse d'être juste, sans que rien ne le signale.

**Règle** : *le double comptage doit être impossible par construction, pas
évité par vigilance.* Un vingt-troisième site de comparaison écrit demain ne
doit pas avoir à se poser la question.

**Toute fenêtre se ferme au minuit suivant, jamais à l'instant présent.** Elles
finissaient à `now` : une vente faite deux minutes plus tard n'était pas « ce
mois-ci » alors qu'elle était « aujourd'hui », et le mois se rallongeait à
chaque consultation. La journée en cours entre désormais entière.

Une **période libre** se ferme au minuit qui suit le dernier jour choisi. Le
sélecteur rend des jours à minuit : « du 1er au 15 » perdait le 15 entier,
sauf sa première milliseconde.

*Appliqué le 21/09/2026.*

### La journée de service finit à minuit

**Une vente appartient au JOUR CIVIL de son horodatage.** Un service qui
commence à 19 h et se termine à 1 h du matin est donc coupé en deux : la
clôture Z, le chiffre du jour, le coût matières journalier et le pointage se
séparent au milieu du service.

**C'est assumé, et ce n'est pas satisfaisant.** La règle est écrite ici pour
qu'elle soit un choix et non un oubli.

**Pourquoi ce choix.** Les deux alternatives coûtaient plus qu'elles ne
réglaient :

- **Une heure de bascule paramétrable** aurait pu réutiliser
  `staff_settings.closing_time`, qui existe déjà. Mais ce réglage ne sert
  aujourd'hui qu'à juger un départ anticipé (`shift_evaluation`) ; lui donner
  un second sens — découper les finances — en ferait un champ dont on ne peut
  plus changer la valeur sans **redécouper tout l'historique**. Et une boutique
  qui ne l'a pas saisi devrait retomber sur le jour civil, donc deux
  comportements à tenir.
- **Une coupure fixe**, cinq heures par exemple, est un arbitraire imposé à
  tous. Un établissement qui ferme à 6 h resterait coupé.

**Ce qu'il faudra faire le jour où un restaurateur s'en plaint** — et c'est la
bonne réponse à ce moment-là, pas avant :

*Une heure de bascule PAR BOUTIQUE, propre aux finances et distincte de l'heure
de fermeture du personnel.* Son coût, à connaître avant de la promettre :

1. **tout l'historique se redécoupe** quand elle change. Une vente de 00 h 30
   passe d'un jour à l'autre, donc d'un mois à l'autre en fin de mois, donc
   d'une assiette de répartition à l'autre. Les marges déjà consultées
   changent ;
2. **la clôture de caisse doit suivre**, sinon le tiroir est compté sur une
   fenêtre et le chiffre calculé sur une autre ;
3. **le pointage aussi**, sans quoi une nuit de travail se répartit sur deux
   journées de paie ;
4. **toutes les fenêtres de la section 6 se décalent** : « aujourd'hui » ne
   commence plus à minuit.

Ce n'est donc pas un réglage : c'est un changement de référentiel. Il se décide
après avoir vu tourner un service, pas avant.

---

## 7. La caisse

```
montant système = fond de caisse
                − sorties d'espèces
                + règlements espèces détaillés
                + commandes payées cash sans ligne de règlement
```

Les huit canaux de sortie d'espèces sont branchés : dépenses et achats
marché, consigne rendue, **versement au livreur**, avances sur salaire,
quinzaines, salaires versés, heures supplémentaires payées le jour même,
primes de concours.

État au 21/09/2026, après le lot « livraison » : `StaffService.cashOut` en
couvre QUATRE — avances en espèces, salaires payés en espèces, heures
supplémentaires réglées de la main à la main, primes de concours. Les
QUATRE autres — dépenses, achats marché, consigne rendue, versement au
livreur — ne passent pas par ce service mais par `DailyExpenseService`.

Le versement au livreur est le dernier arrivé, et il est de la même famille
que les avances et les heures supplémentaires : de l'argent sorti du tiroir le
soir même, que le comptage ne savait pas expliquer. **Seul le versement en
espèces y entre** — un règlement Mobile Money est une charge, mais rien n'est
sorti de la caisse ; le retrancher du fond attendu créerait un excédent aussi
faux que le manquant qu'il corrige.

Contrôle aveugle : le montant système n'est jamais affiché avant la saisie
du comptage réel.

---

## 8. Écarts connus, non corrigés

**Aucun au 21/09/2026.** Le dernier — « la livraison est encaissée sans charge
de livreur » — est passé en section 9 ce jour-là.

Une section vide n'est pas une fin : c'est l'état à un instant. Tout écart
constaté se pose ICI, par ordre de gravité, et n'en sort qu'avec le titre du
commit qui l'a refermé.

---

## 9. Écarts corrigés

Un écart effacé se redécouvre. Chacun sort de la section 8 pour venir ici, daté,
avec le commit qui l'a refermé et ce qu'on a appris en le refermant.

Le commit est désigné par son TITRE et non par son empreinte : un commit ne peut
pas contenir sa propre empreinte, elle est calculée sur son contenu. Les titres
de cette section se retrouvent par `git log --grep`, et sont donc cités
LITTÉRALEMENT — y compris le lot 1, dont le titre est sans accents : le
normaliser ici le rendrait introuvable.

### La courbe et la tuile du tableau de bord divergeaient

*Corrigé le 18/09/2026 — lot 1.*
*Commit : « fix(restaurant): la courbe des depenses cesse de contredire le
benefice affiche ».*

La courbe des dépenses basculait sur les achats réels dès 1 F saisi, la tuile
et le bénéfice à partir de 50 % de couverture. Sur un mois à 300 000 F de
matières théoriques et 20 000 F d'achats déclarés, le total affichait 350 000 F
de dépenses et la courbe 70 000 F — **280 000 F d'écart entre deux chiffres du
même écran**, et le défaut se déclenchait précisément quand quelqu'un
commençait à saisir ses achats sans aller au bout.

**Ce que la correction a révélé, et que cette section ne disait pas :** unifier
le seuil ne suffisait pas. La branche théorique de la courbe additionnait le
coût théorique **et** les achats marché, que sa série de dépenses quotidiennes
contenait. Le défaut était invisible tant que la bascule se faisait au premier
franc, puisque la branche théorique n'était alors atteinte qu'avec zéro achat ;
corriger le seuil l'a rendu atteignable avec des achats non nuls, et donc
visible. Le principe « jamais les deux coûts à la fois » n'était tenu que par
le total.

**Correction** : la décision de bascule est une fonction unique
(`usesRealFoodCostFor`), appelée par le total comme par la courbe ; la lecture
des achats l'est aussi (`netRealFoodCostOf`), les deux côtés lisant désormais
le montant NET de la matière perdue ; et les dépenses quotidiennes sont
ventilées en deux séries — achats de matières d'un côté, exploitation de
l'autre — pour qu'une branche puisse en ignorer une sans ignorer l'autre.

**Invariant désormais tenu par un test** : `somme(expenseSeries) == expenses`.

Effet de bord utile : `partialFoodCostEntry`, qui prévient que des achats sont
saisis mais trop partiels pour porter le bilan, est enfin cohérent avec ce que
montre la courbe.

---

### Une dépense rattachée à un ingrédient était comptée deux fois

*Corrigé le 18/09/2026 — lot 2.*
*Commit : « fix(restaurant): une dépense rattachée à un ingrédient cesse
d'être comptée deux fois ».*

La répartition retenait toute ligne portant un identifiant d'ingrédient, **quelle
que soit sa catégorie**, pendant que le bilan comptait cette même ligne en
charge d'exploitation parce qu'elle n'était pas un « achat marché ». Un
transport de 30 000 F rattaché au poulet pesait 60 000 F sur le bénéfice.

Le défaut s'auto-entretenait : le coût théorique ainsi gonflé relevait le seuil
de bascule vers les achats réels, donc maintenait le bilan dans le mode
théorique — le seul où le double comptage frappe.

**Comment la donnée apparaissait** : le formulaire ne propose le rattachement
que sur « achat marché », mais l'enregistrement envoyait `ingredientId` sans
condition. On créait un achat marché rattaché, on changeait la catégorie, le
champ disparaissait de l'écran — et le lien restait, invisible.

**Décision prise** : *la catégorie décide, pas le rattachement.* Seul un achat de
matières premières finit dans une assiette, ce que dit déjà la section 1.
Retenir le transport dans le coût du plat était défendable — un ingrédient
coûte ce qu'il coûte rendu en cuisine — mais rendait le food cost incomparable
d'une boutique à l'autre, selon qu'elle rattache ou non ses frais de transport.
Sur l'exemple ci-dessus, le taux passait de 10 % à 25 % pour les mêmes achats.

**Correction** : `feedsIngredientAllocation` exige désormais la catégorie
« achat marché » ; et le formulaire efface le rattachement dès qu'on quitte
cette catégorie — un réglage qu'on ne voit plus ne doit plus exister.

**Invariant tenu par un test**, vérifié sur TOUTES les catégories : aucune
dépense n'est à la fois répartie sur les plats et comptée en exploitation. Une
catégorie ajoutée demain sans y penser rouvrirait le double comptage ; le test
l'attrape sans qu'on ait à s'en souvenir.

---

### Une paie mensuelle tombait entière sur une journée

*Corrigé le 18/09/2026 — lot 3.*
*Commit : « fix(restaurant): une paie mensuelle cesse de tomber entière sur une
journée ».*

Chaque mois touché par la fenêtre apportait sa paie ENTIÈRE. « Aujourd'hui »
retirait donc un salaire mensuel complet du bénéfice — sur une masse salariale
de 300 000 F et un chiffre d'affaires de 50 000 F par jour, le tableau de bord
annonçait une perte massive chaque matin.

**Ce que la correction a révélé, et que cette section ne disait pas :** le
défaut ne se limitait pas aux fenêtres courtes. `DashPeriod.month` ne vaut pas
le mois civil mais **30 jours glissants**, et chevauche donc presque toujours
deux mois : la fenêtre nommée « Mois » comptait **deux** salaires mensuels
complets, 600 000 F là où il en était sorti 300 000. Le trimestre en comptait
quatre.

**Décision prise** : *la paie d'un mois se répartit sur ses jours, et la fenêtre
en prend sa part.* L'autre option — ne pas afficher de bénéfice net sous le
mois — a été écartée pour deux raisons : elle ne corrigeait pas le
chevauchement, puisqu'au-dessus du seuil elle comptait toujours les paies
entières ; et elle exigeait de décider à partir de quelle durée une fenêtre
« est » un mois, arbitraire de plus tant que les trois fenêtres de la section 6
ne sont pas unifiées. Cette question aura une réponse à ce moment-là, et le
masquage pourra se poser alors.

**Correction** : `payrollShareOf` rend la part du mois couverte par la fenêtre,
au prorata des jours RÉELS du mois — une journée de février pèse plus lourd
qu'une journée de janvier. Les bornes sont demi-ouvertes sur la fin : une
fenêtre « aujourd'hui » va de minuit à minuit, et compter le lendemain donnait
deux jours de paie pour une journée.

La paie est aussi **étalée** sur les jours couverts au lieu d'être posée d'un
bloc sur la fin du mois : puisqu'elle se compte au jour, la courbe doit le
montrer. Le bloc unique dessinait un pic qui faisait croire à une dépense ce
jour-là.

---

### La paie valait zéro tant que la fiche n'était pas générée

*Corrigé le 18/09/2026 — lot 4.*
*Commit : « fix(restaurant): un salaire non encore arrêté pèse quand même sur
le bénéfice ».*

Un restaurant à 300 000 F de salaires mensuels affichait, le 18 du mois, un
bénéfice surévalué de 180 000 F. Puis le chiffre s'effondrait d'un coup le jour
où le gérant générait ses fiches — et, depuis le lot 3, l'effondrement se
propageait rétroactivement sur tout le mois par le prorata, sans qu'aucune
vente n'ait changé.

**Ce que l'inspection a révélé** : `generatePayslip` n'est pas un calcul mais
une ÉCRITURE. Elle solde les avances, marque les heures supplémentaires
réglées, recouvre les pénalités et déduit les absences. Le repli ne pouvait
donc en aucun cas passer par une génération automatique : il devait rester en
lecture seule.

**Décision prise** : *un salaire non encore arrêté est dû quand même, et il est
affiché comme estimé.* Ni A seul — un chiffre estimé qui se lit comme arrêté —
ni B seul — un bénéfice faux, seulement signalé à qui lit la mention.

**Correction** : `payrollEstimateFor` somme les salaires de base des employés
actifs, proratisés par `hireDate` pour qui arrive en cours de mois, sur les
jours réels du mois. `payrollOrEstimate` rend les fiches quand elles existent,
l'estimation sinon, et dit lequel des deux. Le tableau de bord écrit alors
« paie X **estimée** ».

**Ce que l'estimation ignore, et c'est assumé** : primes, heures
supplémentaires, absences et retenues ne sont connues qu'à l'établissement de
la fiche. Le chiffre bougera donc à ce moment-là — vers le haut avec les
primes, vers le bas avec les absences.

**Limite connue** : `isActive` est l'état d'aujourd'hui, pas un historique. Sur
un mois passé où un employé a depuis quitté la maison, l'estimation le
sous-estime. En pratique les mois passés ont leurs fiches ; l'estimation sert
surtout au mois en cours, où l'effectif est à jour.

---

### Une avance sur salaire ne pesait jamais sur le bénéfice

*Corrigé le 18/09/2026 — lot 5, pour sa moitié « avances ».*
*Commit : « fix(restaurant): une avance déjà versée compte dans la masse
salariale ».*

`computeNet` retranche les avances, et c'est juste pour le SALARIÉ : qui a pris
50 000 F le 10 n'en touche que 50 000 à la fin du mois. Mais le restaurant, lui,
a bien dépensé 100 000 F. Le bilan sommait les nets : **250 000 F pour une
équipe qui en avait coûté 300 000**, et un bénéfice surévalué du montant exact
sorti en avance.

L'argent était pourtant bien parti, et le reste du logiciel le savait :
`StaffService.cashOut` compte les avances en espèces pour que la clôture de
caisse ne crie pas au manquant. Seul le bilan les ignorait.

**Décision prise** : *la paie du bilan est le COÛT DU TRAVAIL, pas l'argent
versé le jour de la paie.* L'autre option — garder la paie au montant versé et
sortir l'avance en charge distincte — aurait exigé d'ajouter une ligne à la
formule du bénéfice de la section 5.

**Ce qui a tranché** vient du lot 4 : l'estimation contractuelle
(`payrollEstimateFor`) somme les salaires de base, donc rend déjà le coût du
travail. Sans cette correction, la masse salariale **changeait de nature** au
moment où le gérant générait ses fiches — 300 000 avant, 250 000 après, pour la
même équipe.

**Correction** : `Payslip.laborCost` vaut `netSalary + advancesDeducted`, et
`payrollTotal` le somme. L'affichage du bulletin, lui, continue de montrer le
net — le salarié touche bien net d'avance.

**Cet écart n'est refermé qu'à moitié.** Les heures supplémentaires payées en
espèces restent en section 8 : la notion n'existe pas dans le dépôt.

---

### Un plat sans coût verdissait le food cost

*Corrigé le 18/09/2026 — lot 6.*
*Commit : « fix(restaurant): le food cost cesse de verdir quand le coût d'un
plat manque ».*

Le taux théorique divisait le coût des plats CHIFFRÉS par le chiffre d'affaires
ENTIER. Les plats sans coût connu — typiquement les boissons, sans fiche recette
ni prix d'achat saisi — apportaient du dénominateur sans apporter de numérateur.

Sur 150 000 F de coût pour 500 000 F de ventes chiffrées et 500 000 F de ventes
muettes, le taux affichait **15 % au lieu de 30**, et la carte annonçait « sous
les 30 % — bonne maîtrise des matières ».

Le défaut s'aggravait à mesure que la donnée manquait : à 80 % de ventes non
chiffrées, le taux tombait à 6 %. **L'indicateur était d'autant plus vert que le
restaurant en savait moins sur ses coûts** — il rassurait au moment où il aurait
dû alerter.

**Périmètre** : le défaut ne frappait qu'en mode THÉORIQUE. En mode réel,
`netRealFoodCost` vient des achats, qui couvrent tous les plats.

**Décision prise** : *le taux se calcule sur les ventes dont le coût est connu,
et la couverture est affichée.* Ni A seul — un taux de 30 % qui semble porter
sur toute la carte alors qu'il en couvre la moitié — ni B seul, qui laissait
l'indicateur vert faire son office auprès de qui ne lit pas la mention.

**Correction** : `coveredRevenue` mesure le chiffre d'affaires des plats dont le
coût est connu, `costedRevenue` sert de dénominateur au taux théorique, et
`costCoverage` expose la part couverte. Le tableau de bord écrit alors « ce taux
ne porte que sur X % de vos ventes ».

**Ce qui n'est PAS corrigé, et ne peut pas l'être** : le bénéfice reste
surévalué du coût manquant. On ne peut pas inventer un coût qu'aucune donnée ne
porte. Seul le renseignement des fiches recettes ou du prix d'achat des plats
concernés le comblera — et la mention de couverture est précisément là pour y
inviter.

---

### Une heure supplémentaire payée le soir ne pesait pas sur le bénéfice

*Corrigé le 19/09/2026 — lot 7. Il referme la moitié restée ouverte au lot 5.*
*Commit : « fix(restaurant): une heure supplémentaire payée le soir compte dans
la masse salariale ».*

Le gérant tranche en fin de service : payées de suite, ou reportées sur la paie
du mois. « Payées de suite » sort l'argent du tiroir immédiatement et marque le
pointage soldé — ces heures n'entrent donc **jamais** dans une fiche de paie, et
c'est voulu : les y porter aussi les paierait deux fois.

Mais le bilan sommait les fiches. Cet argent, bien sorti, n'apparaissait nulle
part en charge. La clôture de caisse, elle, le savait déjà : `cashOut` le déduit
pour ne pas crier au manquant. **Seul le bilan l'ignorait** — exactement la
maladie des avances.

**Aucune décision nouvelle n'a été nécessaire** : la règle avait été tranchée au
lot 5. La paie du bilan est le coût du travail, pas l'argent versé le jour de la
paie.

**Correction** : `overtimePaidInCashFor` somme les heures réglées `paidNow` du
mois, et `payrollOrEstimate` les ajoute aux DEUX branches — fiches ou estimation
contractuelle — puisque l'argent est sorti quelle que soit l'avancée de la paie.

**Mois d'imputation** : celui de la SORTIE, comme partout ailleurs pour les
heures supplémentaires. Un service commencé le 31 à 21 h et fini le 1er à 2 h
appartient au mois où il s'est terminé — c'est la nuit qui a été payée, pas la
soirée.

**Pas de double comptage** : `settleOvertime` marque `overtimeSettled` à
l'instant de la décision, ce qui exclut ces heures d'`overtimeToSettle`, donc de
toute fiche.

---

### L'écart théorique / réel s'annonçait comme un gaspillage

*Corrigé le 19/09/2026 — lot 8.*
*Commit : « fix(restaurant): l'écart d'achats dit ce qu'il mesure au lieu
d'accuser un gaspillage ».*

En mode répartition, le coût théorique est dérivé des achats eux-mêmes.
L'identité de la section 3 le dit : `vendu + perdu + non réparti + retiré =
acheté`. En la développant, l'écart vaut **non réparti + perdu** — et le perdu
est déjà sorti en pertes. **Il ne peut donc rien révéler sur le gaspillage.**

L'écran annonçait pourtant « stock constitué, gaspillage ou fiche recette à
revoir ». Sur 200 000 F d'achats dont 50 000 F sur un ingrédient qu'aucun plat
vendu ne contient, il affichait un écart de 50 000 F attribué à ces trois
causes, **dont deux fausses**. Le gérant partait chercher un voleur ou un
cuisinier négligent là où il suffisait de rattacher un ingrédient.

**Périmètre** : la part FICHE TECHNIQUE échappe à ce raisonnement — son
théorique vient des quantités pesées, indépendamment des achats, et l'écart y
mesure bien un gaspillage. Mais la répartition est le mode par défaut.

**Décision prise** : *nommer ce que l'écart mesure, plutôt que de le restreindre
à la part fiche.* Restreindre aurait supprimé l'indicateur pour la majorité des
boutiques sans rien mettre à la place, alors que le nommer transforme un chiffre
trompeur en chiffre actionnable — « rattachez cet ingrédient » est une action,
« cherchez un gaspillage » n'en est pas une quand il n'y en a pas.

**Correction** : `unallocatedPurchases` remonte `AllocationResult.unallocated`
jusqu'au bilan, et l'écart se décompose en `gapFromUnallocated` — plafonné à
l'écart lui-même, car des pertes peuvent le rendre plus petit que le
non-rattaché — et `gapBeyondUnallocated`. Le tableau de bord affiche deux
messages distincts : le non-rattaché nommé pour ce qu'il est, puis le reliquat,
qui seul conserve les trois causes historiques.

**Le chiffre ne change pas** : seule son interprétation est corrigée.

**D'OÙ VIENT LE NON-RATTACHÉ, depuis le 21/09/2026.** Ce lot a nommé la chose ;
la sous-section « Un ingrédient sans plat » de la section 3 dit désormais ce
qui la produit. La création d'un ingrédient hors recette, ouverte avec l'écran
Stock, en est une source directe — assumée, avertie à la saisie et signalée
dans la liste, mais jamais bloquée.

---

### Une fourniture manquante se payait deux fois

*Corrigé le 19/09/2026 — lot 9.*
*Commit : « fix(restaurant): un manque de fourniture sort des achats au lieu de
s'y ajouter ».*

Un réassort de barquettes entre en charge d'exploitation. L'inventaire constate
ensuite qu'il en manque : cet écart tombait en perte, **à son montant**, alors
que les barquettes manquantes font partie de celles déjà payées. 30 000 F
d'achats plus 8 000 F de manque retiraient **38 000 F du bénéfice pour 30 000 F
dépensés**.

Les INGRÉDIENTS ne connaissaient pas ce défaut : leur manque est retiré des
achats avant partage, plafonné à ces achats — la voie (b) de la section 4.
Seules les fournitures en étaient exclues, parce qu'elles ne sont pas réparties
sur les plats. Ce qui n'est pas une raison pour les payer deux fois.

**Correction** : `spendBySupply` trace les achats par fourniture — jumelle de
`spendByIngredient`, pour l'autre nature de rattachement —, `supplyWithdrawalsOf`
plafonne le manque à ces achats, et l'exploitation baisse d'autant. Le retrait
touche le total **et** la série, sans quoi l'invariant du lot 1
(`somme(expenseSeries) == expenses`) casserait.

**CE QUE LE PREMIER JET A EU FAUX, et qu'un test existant a rattrapé** : j'avais
fait valoir la perte ce qui avait pu être retiré, par symétrie avec les
ingrédients. `restaurant_loss_attachment_test.dart` l'a refusé — un manque de
gaz de 2 000 F sans achat de gaz sur la période tombait à 0 et **disparaissait
de l'affichage**.

Le test avait raison : quand l'achat est **antérieur** à la période, la charge
de ce mois ne contient pas cette fourniture, il n'y a donc aucun double
comptage à corriger. Faire disparaître la perte réparait un problème inexistant.

**La règle retenue** : *le plafonnement porte sur le RETRAIT, jamais sur la
valeur de la perte.* Achat dans la période — l'exploitation baisse, la perte
reste, le total est juste. Achat antérieur — rien n'est retiré, la perte est
comptée, ce qui est correct puisque cette période ne l'a pas payée.

---

### Une dépense du restaurant pouvait être abandonnée sans un mot

*Corrigé le 19/09/2026 — « fix(sync): les tables qui portent de l'argent ne
perdent plus une écriture en silence », après « feat(sync): la file de
synchronisation devient visible, et s'abandonne op par op ».*

Ce n'est pas un calcul faux, c'est de la perte de données : les sections 1 à 10
définissent des calculs et supposent que leurs entrées existent. La file
abandonnait une écriture de `daily_expenses` dès la première erreur permanente,
et toute table non protégée après dix tentatives. La dépense restait sur
l'appareil qui l'avait saisie, le bilan de tous les autres était faux, et rien
ne l'annonçait.

**Correction** : une liste unique de vingt-huit tables, trois prédicats qui en
dérivent, et un test qui refuse qu'ils divergent. Les deux écarts que les trois
listes manuelles avaient laissés s'installer sont refermés au passage :
`partner_ledger_entries` survivait à l'erreur permanente mais était supprimée
après dix tentatives ; `restaurant_tables` survivait aux deux sans jamais
alerter.

L'écran de synchronisation est venu **avant** : protéger sans permettre
d'abandonner au cas par cas aurait concentré la perte au lieu de l'étaler.

---

### Une clé étrangère manquante était jugée sans espoir

*Corrigé le 21/09/2026 — « fix(sync): un parent en retard n'est pas une
écriture perdue ».*

Dix codes Postgres faisaient abandonner une opération. 23503 — la violation de
clé étrangère — en faisait partie, et n'avait rien à y faire : les neuf autres
décrivent une écriture INVALIDE, celui-là dit seulement que la ligne parente
n'est pas encore arrivée.

Le cas est devenu concret en protégeant `stock_movements`, `receptions` et
`incidents` sans protéger `products`, `purchase_orders` et `suppliers`.

**Correction** : `isDefinitiveSyncError(err, table)` remplace
`_isPermanentError(err)`. 23503 devient temporaire **sur une table protégée
seulement** — ailleurs, elle reste définitive, sinon on changerait le
comportement de toute la file pour un cas de bord. Un test le vérifie code par
code, pour les dix.

**Ce que ce correctif ne fait pas** : sur une table protégée, l'opération
restait déjà en file. Le sort de l'op est inchangé. Ce qui change est la
justesse de la classification, sa testabilité, et un journal moins bavard.

---

### La livraison était encaissée sans charge de livreur

*Corrigé le 21/09/2026 — « feat(restaurant): une livraison paie son livreur,
et ses frais entrent enfin en recette ».*

Le dernier écart de la section 8, et le plus ancien. Le client payait des
frais, l'établissement les encaissait, un livreur était nommé sur la commande
— et **rien ne disait ce qu'il recevait**. Ni recette, ni charge : deux flux
réels, invisibles tous les deux.

**Le plus grave n'était pas le bilan, c'était la caisse.** Le livreur de
dépannage est payé en espèces, du tiroir, le soir même. `cashOut` ne le savait
pas : chaque course ainsi réglée apparaissait au comptage aveugle comme un
**manquant imputé au caissier**. C'est le même défaut que les avances sur
salaire et les heures supplémentaires payées de la main à la main, refermé
deux fois déjà ailleurs dans cette section.

**Trois cas coexistent**, et la règle les porte tous les trois :

- les frais reviennent **en entier** au livreur — le cas courant ;
- ils sont **partagés**, l'établissement garde la différence ;
- le livreur est un **salarié**, dont le coût est déjà dans la paie. Le champ
  se met alors à **zéro tout seul**, avec sa mention : un zéro qu'il faudrait
  saisir à la main serait oublié, et la course serait payée deux fois — une
  fois en espèces le soir, une fois dans la quinzaine.

**CE LOT FAIT MONTER LE CHIFFRE D'AFFAIRES SANS QU'AUCUNE VENTE N'AIT
CHANGÉ.** C'est sa conséquence la plus visible et il faut s'y attendre : à
articles strictement identiques, un bilan qui lisait 5 000 F lit désormais
6 000 F si la course valait 1 000 F. Rien n'a été vendu de plus — une recette
qui existait depuis toujours est simplement entrée dans le compte.

La contrepartie est écrite en face, le même jour, sur la même commande : une
dépense de transport de ce que le livreur a reçu. Le bénéfice net ne bouge donc
que de la **différence** — 300 F sur une course facturée 1 000 et reversée 700.
C'est exactement ce que l'établissement gagne à livrer, et il ne le savait pas.

**Ce que ce correctif ne fait pas.** Les ratios de matière ne changent pas : le
food cost et la couverture du coût se rapportent aux **ventes de plats**, pas
au CA (section 2). La somme des secteurs non plus : une course n'appartient à
aucune activité, et la ranger dans « Sans secteur » y ferait apparaître un
montant que rien ne permet de rattacher — le gérant chercherait indéfiniment un
plat manquant qui n'existe pas.

**Le circuit de livraison e-commerce n'est pas concerné** : quartiers tarifés,
partenaire-livreur, transferts de stock et livre partenaire sont un autre
parcours, avec sa propre comptabilité de versements. Ce lot ne touche que la
livraison prise au comptoir du restaurant.

---

## 10. Ce que le tableau de bord doit expliquer

Un commerçant doit pouvoir répondre seul à « pourquoi mon bénéfice a baissé ».
Aujourd'hui il voit des totaux, pas une chaîne.

Trois choses à rendre lisibles :

- ce que contient chaque agrégat — « Direct » englobe les charges partenaire,
  ce que son libellé ne dit pas ;
- sur quelle fenêtre chaque chiffre est calculé ;
- quand un indicateur est vert parce qu'il manque des données, et non parce
  que la gestion est bonne.

---

## 11. Ce qui doit survivre

Les dix sections précédentes définissent des CALCULS. Aucune ne dit à quelle
condition leurs entrées existent encore. Un bilan juste sur des données
absentes reste un bilan faux.

### Les tables qui ne doivent jamais être abandonnées

La file de synchronisation hors-ligne abandonne une opération dans deux cas :
après dix tentatives, ou immédiatement sur une erreur permanente. Une opération
abandonnée reste dans Hive sur l'appareil qui l'a saisie et n'existe nulle part
ailleurs.

**Règle** : *toute table qui porte de l'argent, ou qui sert à en calculer, est
protégée.* Elle n'a pas à être « importante » pour l'utilisateur — il suffit
qu'un chiffre du bilan ou de la caisse en dépende.

#### Il y a TROIS protections, pas deux

La première rédaction de cette section n'en annonçait que deux. C'était faux, et
la troisième est celle qui décide si les deux autres servent à quelque chose :

| Protection | Ce qu'elle empêche | Sans elle |
|---|---|---|
| **survit à l'erreur permanente** | l'abandon immédiat sur colonne absente, contrainte violée, droit refusé | l'écriture est jetée au premier essai |
| **survit au plafond** | l'abandon après dix tentatives | l'écriture est jetée le jour où le réseau est mauvais |
| **alerte** | le silence | l'écriture est gardée et **personne ne l'apprend** |

Une opération protégée par les deux premières sans la troisième est **une
opération perdue avec un délai** : elle reste en file indéfiniment, invisible,
jusqu'à la prochaine purge ou au prochain appareil. C'est précisément ce qui
arrivait à `restaurant_tables`.

Les trois protections dérivent désormais d'**une seule liste**,
`kProtectedSyncTables` (`lib/core/database/sync_protected_tables.dart`), et un
test vérifie pour toute table que les trois répondent la même chose. Trois
listes tenues à la main à trois endroits avaient divergé sans que rien ne le
signale.

#### La liste exacte

`orders` · `sales` · `payments` · `cash_closures` · `bottle_deposits` ·
`expenses` · `daily_expenses` · `fixed_charges` · `receptions` · `payroll` ·
`salary_advances` · `time_records` · `staff_penalties` · `staff_absences` ·
`staff_contests` · `staff_ratings` · `employees` · `job_titles` ·
`staff_settings` · `ingredients` · `recipe_ingredients` · `losses` ·
`incidents` · `stock_movements` · `stock_items` · `restaurant_activities` ·
`restaurant_tables` · `partner_ledger_entries`

**La liste de seize de la première rédaction était fausse dans les deux sens.**
Elle omettait `employees`, `job_titles`, `staff_settings`,
`restaurant_activities`, `incidents`, `receptions` et `stock_movements` — sept
tables qui passent bien par la file. Et elle présentait les cinq déjà protégées
comme absentes, alors qu'elles y étaient. Le décompte réel au moment de l'écrire
était : cinq protégées, vingt-trois à ajouter.

`job_titles` et `staff_settings` ont été vérifiées une par une plutôt que
supposées : les deux passent par `_bgWrite`, donc par la file.

⚠ **`stock_movements` et `receptions` sont PARTAGÉES avec l'e-commerce.** Les
protéger change le comportement des quatre boutiques en production : leur file
peut désormais grossir au lieu de se vider en perdant des mouvements. C'est le
compromis retenu — hotfix_176 a montré qu'un mouvement de stock abandonné en
silence est un scénario réel, pas théorique — et il n'est tenable que parce que
l'écran de synchronisation permet d'abandonner une opération isolée.

⚠ **Piège de nommage** : `expenses` était protégée, mais c'est la table de
l'e-commerce. Les dépenses du restaurant vivent dans `daily_expenses`, avec sa
propre boîte Hive, et n'étaient PAS protégées. Deux noms proches, deux sorts
opposés. Les deux le sont désormais.

⚠ **`sales` est protégée, n'est jamais mise en file par une vente, et la table
N'EXISTE PAS en base.** Trois constats qui se recoupent, établis séparément :

- le seul chemin qui l'enfile est la remise à zéro d'une boutique
  (`op: delete`) ; `SaleRepositoryImpl.createSale` et `refundSale`
  l'enfileraient, mais `saleRepositoryProvider` n'est lu nulle part — ce code
  est inatteignable ;
- une vente est écrite dans `orders` ;
- **vérifié en base le 20/09/2026 : il n'y a pas de table `sales`.**

Elle n'est retirée d'aucune liste pour l'instant : le jour où ce chemin revit,
l'oubli coûterait des ventes. Mais tant qu'elle figure dans les listes sans
exister, elle est du bruit — à trancher, pas à oublier.

#### Le corollaire : l'enfant orphelin

**Protéger une table ne protège pas ce dont elle dépend**, et la règle
ci-dessus ne le disait pas.

Une ligne qui porte une clé étrangère ne peut pas être écrite avant son parent.
`ON DELETE SET NULL` ne gouverne que la suppression : à l'insertion, la ligne
parente doit EXISTER, sinon la base répond 23503. Or les trois tables partagées
ont toutes un parent que rien ne protège :

| Enfant (protégé) | Clé étrangère | Parent | Parent protégé ? |
|---|---|---|---|
| `stock_movements.product_id` | → `products(id)` | `products` | **non** |
| `receptions.purchase_order_id` | → `purchase_orders(id)` | `purchase_orders` | **non** |
| `receptions.supplier_id` | → `suppliers(id)` | `suppliers` | **non** |
| `incidents.product_id` | → `products(id)` | `products` | **non** |

Le scénario tient en une ligne : un parent abandonné après dix tentatives
laisse derrière lui un enfant que la base refusera à chaque envoi. Avant la
protection, l'enfant mourait avec son parent, en silence. Depuis, **il lui
survit et se rejoue.**

**Règle** : *la protection d'une table est un engagement sur ses parents.*
Soit on les protège aussi, soit on accepte un résidu qui se rejoue — mais on ne
le découvre pas six mois plus tard en regardant grossir une file.

Deux réponses possibles, et **aucune des deux n'éteint le rejeu** :

- **protéger les parents** — cohérent, mais `products`, `purchase_orders` et
  `suppliers` ont leurs propres parents : le problème se déplace d'un cran ;
- **reclasser 23503 en erreur TEMPORAIRE sur une table protégée** — ce qui a
  été retenu (`sync_error_verdict.dart`). Une clé étrangère manquante dit « le
  parent n'est pas encore là », pas « cette écriture est invalide » : c'est une
  question d'ordre d'arrivée. L'exception s'arrête aux tables protégées, sinon
  toute la file se mettrait à rejouer des écritures réellement invalides.

**Ce que la seconde ne fait pas, et il faut le dire** : sur une table protégée,
l'opération restait DÉJÀ en file quand 23503 était classée définitive. Le
verdict ne change donc pas son sort — il rend la règle vraie et lisible, et
évite qu'on relise un jour « 23503 = permanent » en concluant qu'une clé
étrangère manquante est sans espoir.

**Ce qui rend l'enfant orphelin visible** : rien de neuf n'a été ajouté, la
chaîne existait. L'opération emporte sa cause serveur dès le premier échec,
entre dans le journal à la troisième tentative, et rejoint les opérations
bloquées de l'écran de synchronisation à la dixième — où elle s'abandonne à la
main. Le compteur de tentatives suffit ; un seuil supplémentaire n'apporterait
rien.

#### Ce que la protection coûte

Une opération définitivement invalide reste en file et se rejoue à chaque
vidage. Sans moyen d'en abandonner une seule, la protection **concentrerait** la
perte au lieu de l'étaler : la seule issue serait « Vider la queue », qui les
perd toutes d'un coup. L'écran de synchronisation — la liste des opérations en
file, leur nature, leur dernière erreur, et l'abandon op par op — a donc été
livré **avant** cette liste, et non après.

### Ce qu'affiche un bilan incomplet

La section 10 demande de signaler « quand un indicateur est vert parce qu'il
manque des données ». Cette exigence ne couvrait jusqu'ici que les manques
CONNUS — un plat sans coût, une paie non arrêtée, des achats partiellement
saisis. Trois mentions existent à ce titre : `partialFoodCostEntry`, « paie
estimée », « ce taux ne porte que sur X % de vos ventes ».

**Il existe un second genre de manque, et rien ne le couvre** : la donnée qui
aurait dû être là. Une table jamais descendue sur cet appareil rend une boîte
Hive VIDE — le calcul réussit, l'agrégat vaut zéro, et le bilan a exactement
l'apparence d'un bilan juste. Les blocs de lecture du reporting attrapent leurs
exceptions, les journalisent et poursuivent : un `debugPrint` invisible en
production est la seule trace.

**Règle** : *un bilan qui ne peut pas garantir la complétude de ses entrées
doit le dire, et ne jamais présenter un zéro comme une mesure.* Un domaine dont
la lecture a échoué, ou dont la table n'a jamais été synchronisée sur cet
appareil, n'affiche pas « 0 F » — il affiche qu'il ne sait pas.

La distinction à tenir, et elle est concrète : **zéro dépense parce qu'il n'y en
a pas** est une information ; **zéro dépense parce que la table est vide** est
une absence d'information. Les deux s'écrivent aujourd'hui de la même façon.
