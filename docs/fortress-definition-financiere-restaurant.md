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

**Formule** : `(articles − remise de commande) × (1 + TVA)`

**N'entre pas dans le CA :**

| Élément | Raison |
|---|---|
| Consignes de bouteilles | Caution rendue au client, flux de passage |
| Livraison | Recette réelle, mais aucune ligne ne retranche le coût du livreur. Dette ouverte : à intégrer avec sa charge, pas seule. |

**Ce qui n'existe pas aujourd'hui** : TVA (`taxRate` reste à 0), pourboire,
frais de service.

**Les drapeaux de service** — envoyé en cuisine, prêt, servi, terminé — sont
indépendants du CA. Une commande servie et non payée ne compte pas.

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

État actuel, non conforme : trois fenêtres coexistent — mois civil pour la
fiche plat, 30 jours glissants pour le tableau de bord, 7 jours pour la
semaine. À unifier.

---

## 7. La caisse

```
montant système = fond de caisse
                − sorties d'espèces
                + règlements espèces détaillés
                + commandes payées cash sans ligne de règlement
```

Les sept canaux de sortie d'espèces sont branchés : dépenses et achats
marché, consigne rendue, avances sur salaire, quinzaines, salaires versés,
heures supplémentaires payées le jour même, primes de concours.

Contrôle aveugle : le montant système n'est jamais affiché avant la saisie
du comptage réel.

---

## 8. Écarts connus, non corrigés

À traiter, dans cet ordre de gravité.

**La paie du mois entier tombe sur toute période.** « Aujourd'hui » retire un
salaire mensuel complet. Et tant que la fiche n'est pas générée, la paie vaut
0 et le bénéfice est gonflé.

**Les avances sur salaire sortent du net et n'entrent jamais au bilan.** La
masse salariale est sous-évaluée. Idem pour les heures supplémentaires payées
en espèces le soir même.

**Un plat sans coût verdit le food cost.** Son CA est compté, son coût non :
le taux baisse et la carte annonce une bonne maîtrise des matières. L'indicateur
rassure au moment où il devrait alerter.

**La comparaison théorique / réel ne mesure pas le gaspillage** en mode
répartition : le théorique est calculé depuis les achats eux-mêmes. L'écart
mesure ce qui n'a pas été rattaché ou réparti.

**Les fournitures — emballages, gaz — sont comptées deux fois** sur un écart
d'inventaire : leur achat est déjà en charge d'exploitation.

**La livraison est encaissée sans charge de livreur.**

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

## 10. Ce que le tableau de bord doit expliquer

Un commerçant doit pouvoir répondre seul à « pourquoi mon bénéfice a baissé ».
Aujourd'hui il voit des totaux, pas une chaîne.

Trois choses à rendre lisibles :

- ce que contient chaque agrégat — « Direct » englobe les charges partenaire,
  ce que son libellé ne dit pas ;
- sur quelle fenêtre chaque chiffre est calculé ;
- quand un indicateur est vert parce qu'il manque des données, et non parce
  que la gestion est bonne.
