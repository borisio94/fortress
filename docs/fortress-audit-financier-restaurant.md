# Fortress POS — Audit financier du module restaurant

Constat daté, en lecture seule. Aucun correctif n'a été appliqué pendant sa
rédaction.

Réalisé le 19/09/2026 sur `HEAD` = `54edd3a`, c'est-à-dire le code **déployé**.
Quand un fichier diverge dans l'arbre de travail, c'est signalé au constat
concerné.

Référence normative : `docs/fortress-definition-financiere-restaurant.md`.

---

## Ce que cet audit n'est pas

Neuf écarts ont été refermés par les lots 1 à 9, guidés par la définition
financière. Cet audit **ne revient pas** sur ces corrections : elles sont
testées, commitées, déployées.

Il cherche l'inverse — **ce que le document ne couvre pas**, les zones
qu'aucun audit n'avait traversées.

Chaque constat est qualifié :

* **écart à une règle écrite** — le document a raison, le code a tort ;
* **zone non couverte** — le document est muet, une règle manque.

La seconde catégorie est la plus nombreuse, et de loin.

---

## 1. La caisse

### 1.1 Les sept canaux de sortie — tous présents

`systemCash` (`cash_closure_service.dart:135-137`) additionne
`DailyExpenseService.cashOut` et `StaffService.cashOut`.

| Canal annoncé §7 | Où | État |
|---|---|---|
| Dépenses et achats marché | `daily_expense_service.dart:161-164` | ✓ |
| Consigne rendue | idem — le filtre est `e.isCash`, sans exclusion de catégorie | ✓ |
| Avances sur salaire | `staff_service.dart`, boucle `advances` | ✓ |
| Quinzaines | même boucle : `SalaryAdvance.kind` vaut `advance` ou `fortnight`, et `cashOut` ne filtre pas le kind (`salary_advance.dart:37-47`) | ✓ |
| Salaires versés | boucle `payslips`, `paidCash` | ✓ |
| Heures sup du jour même | boucle `timeRecords`, `OvertimeSettlement.paidNow` | ✓ |
| Primes de concours | `StaffContestService.cashOut:118` | ✓ |

Le constat porté au lot 5 — « `cashOut` n'en connaît que deux » — était vrai
**avant** `6f2953e` et ne l'est plus.

*Nuance* : `DailyExpenseService.cashOut` ne distingue pas ses canaux, il somme
toute dépense `isCash`. Les trois premiers canaux du document sont **un seul
mécanisme** — plus robuste, mais le document décrit une structure que le code
n'a pas.

### 1.2 Les entrées d'espèces — deux seulement

`computeSystemCash:187-205` :

```
total = fond de caisse − sorties
      + règlements détaillés dont mode == cash
      + commandes completed, méthode cash, non couvertes par un règlement
```

Aucune autre entrée n'existe :

* **apport du gérant** — n'existe nulle part ;
* **remboursement d'une casse en liquide** — `staff_penalty.dart:184-190` :
  `recover()` n'est alimenté que par la retenue sur paie. Un employé qui
  rembourse en espèces n'a aucun chemin ; l'argent entre dans le tiroir et
  apparaît en **excédent** ;
* **fond de caisse** — compté, mais voir 1.4.

**Zone non couverte.** La §7 énumère sept canaux de *sortie* et n'évoque aucune
entrée autre que les ventes.

### 1.3 X et Z — trois comportements non spécifiés

`periodStart:103-109` : la période part du `closedAt` du dernier Z, ou de minuit
s'il n'y en a jamais eu. Un X n'avance pas la période.

**Double clôture Z** : aucun garde. `_close(isZ: true)` demande une confirmation
(`cash_closure_page.dart:73-87`) sans vérifier s'il existe déjà un Z récent. Un
second Z immédiat prend comme `periodStart` le `closedAt` du premier — période
quasi vide, `systemCash ≈ openingFloat`, **excédent massif affiché**.

**Jour sauté** : la période s'étend sur plusieurs jours et agrège tout. Aucun
argent perdu — c'est le bon comportement — mais rien n'avertit que la fenêtre
couvre 72 h.

**Deux appareils simultanés** : aucun verrou, aucune transaction. Deux Z
concurrents produisent deux clôtures au **même `periodStart`**, comptant les
mêmes ventes.

**Zone non couverte.** Le document décrit le contrôle aveugle sans rien dire du
cycle X/Z : ni unicité du Z, ni définition de la période, ni multi-appareil.

### 1.4 Le fond de caisse

`openingFloat:43-49` : lu d'abord sur la dernière clôture enregistrée qui porte
un `openingFloat > 0`, sinon sur une **préférence locale Hive**
(`cash_float_<shopId>`, `_floatKey:32`).

Deux observations. Le fond **n'est jamais remis ni ajusté** au démarrage d'une
journée : il se propage de clôture en clôture. Et sa première valeur vient d'une
préférence **non synchronisée** — le piège déjà connu de `ShopSettingsStore`.
Le repli est atténué (la clôture synchronisée prend le dessus dès la première),
mais avant celle-ci, deux appareils peuvent diverger.

**Zone non couverte.** Le document mentionne le fond dans sa formule sans dire
d'où il vient ni qui l'arrête.

### 1.5 L'écart de caisse — enregistré, imputé, jamais repris au bilan

`variance` est calculé, stocké, synchronisé, et imputé : `cashierId` et
`cashierName` sont enregistrés (`cash_closure_page.dart:105-106`), avec une
entrée au journal d'activité.

Mais `grep "variance|CashClosure"` dans `restaurant_reporting_service.dart` →
**aucun résultat**. Un manquant de 15 000 F n'apparaît nulle part dans le
bénéfice.

**Zone non couverte, et c'est le constat le plus lourd de la section.** La §5
définit le bénéfice net par six termes ; aucun ne couvre l'écart de caisse. La
question n'a jamais été posée : *un manquant de caisse est-il une perte ?* Le
rapprochement s'impose avec la §4, qui traite les pertes non rattachées comme
des charges.

### 1.6 Couverture

`cash_closure_test.dart` : **21 tests**, bien fournis sur `computeSystemCash`.

Aucun ne couvre le cycle X/Z, l'origine du fond, ni le sort de la `variance`.

---

## 2. Les chemins d'argent non tracés

### 2.1 Remboursement client — le chemin n'existe pas

`SaleStatus.refunded` et `PaymentStatus.refunded` existent (`sale.dart:13, 25`),
mais **aucun code du module restaurant ne les produit** : les occurrences dans
`restaurant_order_service.dart:800` sont des filtres d'exclusion.

Un client remboursé après encaissement n'a aucun geste. L'argent sort du
tiroir : la caisse affiche un manquant, le CA reste intact, le bénéfice aussi.

**Écart à une règle écrite** (§4 : « annulée, refusée ou remboursée sort du CA
et entre en pertes »).

### 2.2 Commande annulée APRÈS encaissement — impossible

`cancelPendingRound` (`restaurant_order_service.dart:447`) et `cancelSentRound`
(`service_incident_service.dart:99`) opèrent sur des commandes **ouvertes**.
Aucune transition ne part de `completed`.

*Point vérifié et écarté* : `cancelPendingRound` ne crée aucune perte, et c'est
**conforme** — la tournée n'ayant pas été envoyée en cuisine, aucune matière
n'a été engagée, ce que la §4 prescrit explicitement.

**Zone non couverte** : une fois `completed`, une commande est figée. Le
document décrit ce qui sort du CA, jamais quand ni comment.

### 2.3 Acompte et paiement partiel — les deux écrans divergent

`settleAndRelease` accepte `amountPaid` (`restaurant_order_service.dart:699`) ;
le statut passe néanmoins à `completed`.

| | Valeur retenue | Référence |
|---|---|---|
| Chiffre d'affaires | le **total facturé** | `restaurant_reporting_service.dart:444` |
| Caisse | le **montant encaissé** | `cash_closure_service.dart:200` |

Les deux sont justes séparément — engagement contre flux. Mais la **créance qui
les sépare n'existe nulle part** au restaurant. Un client qui part en devant
10 000 F laisse un bénéfice inchangé, une caisse juste, et aucune liste
d'impayés.

**Zone non couverte.**

### 2.4 Vente à crédit — écartée par conception

`payment.dart:38-43` : `PaymentMode.credit` existe mais est **exclu des modes
proposés**, parce que « dans Fortress la créance est DÉRIVÉE (montant encaissé
< total), elle n'est pas saisie comme un règlement ».

La décision est juste et explicitée. Elle renvoie à 2.3 : la créance est
dérivable mais n'est dérivée nulle part.

### 2.5 Paiement par un tiers — non déterminé

`Payment` porte `orderId`, `method`, `amount`, `reference`, `changeGiven`
(`payment.dart:61-80`). Aucun champ ne désigne le payeur.

Rien n'indique que ce besoin ait été exprimé. **Question ouverte.**

### 2.6 Pourboire — n'existe pas, conformément au document

Aucune occurrence fonctionnelle. La §2 l'annonce : « Ce qui n'existe pas
aujourd'hui : TVA, pourboire, frais de service. »

*Reste non posé* : un pourboire en espèces entre physiquement dans le tiroir et
produit un excédent au comptage. Même mécanique qu'en 1.2.

### 2.7 Erreur de saisie corrigée — deux régimes opposés

Avant encaissement, les transitions passent par `_patchOrder` : la commande est
modifiable. Après `completed` : plus aucun chemin.

Mais `PaymentService.delete` existe (`payment_service.dart:237`). Supprimer un
règlement d'une commande `completed` retirerait son montant de la caisse **sans
toucher au CA**. Je n'ai pas vérifié si l'interface l'expose après
encaissement : **non déterminé**.

### 2.8 Du code mort dans la chaîne des pertes

`ServiceIncidentService.reportBadDish` (`service_incident_service.dart:159`) —
*plat raté* — **n'a aucun appelant**.

Les deux autres portes sont câblées : `reportUnpaid` depuis
`restaurant_tables_page.dart:998`, `cancelSentRound` depuis `:1053`.

Le plat raté est l'un des trois cas que la documentation du service décrit comme
« là où l'argent se perd » — et c'est précisément celui qu'aucun écran ne permet
de déclarer.

**Écart à une règle écrite** : `plat_mal_fait` figure dans
`Loss.materialCategories`. La catégorie existe, le service existe, l'écran
manque.

---

## 3. Le temps et les bornes

### 3.1 Recensement — dix définitions de période

| # | Définition | Où | Nature |
|---|---|---|---|
| 1 | `today` = minuit → minuit+1j | `dashboard_providers.dart:82-84` | jour civil |
| 2 | `yesterday` | `:85-88` | jour civil |
| 3 | `week` = 6 jours glissants | `:89-92` | glissante |
| 4 | `month` = 29 jours glissants | `:93-96` | glissante |
| 5 | `quarter` = 89 jours glissants | `:97-102` | glissante |
| 6 | `year` = 1er du mois, 1 an avant | `:103-105` | mixte |
| 7 | `custom` | `:106-107` | libre |
| 8 | Mois civil | `dish_cost_service.dart:135-139`, `ingredient_allocation_service.dart:141` | civile |
| 9 | Période de caisse = dernier Z → maintenant | `cash_closure_service.dart:103-108` | événementielle |
| 10 | Histogramme 7 jours, indépendant du sélecteur | `restaurant_dashboard_providers.dart:164-165` | glissante |

**La §6 en annonce trois.** Il y en a dix.

### 3.2 Là où elles divergent — le mois n'est pas le mois

Trois définitions du « mois » cohabitent : `DashPeriod.month` (30 jours
glissants), `DishCostService.forMonth` (mois civil), `SalaryAdvance.monthKey`
(clé `yyyy-MM`, utilisée par paie, avances, pénalités, absences, notation).

Le `payrollShareOf` du lot 3 proratise correctement, mais il **compense** une
divergence de définition — il ne la supprime pas.

**Écart à une règle écrite** (§6 : « une seule fenêtre fait autorité »). Le
sélecteur propose sept périodes, dont cinq plus courtes que le mois, et toutes
affichent des marges.

### 3.3 Les bornes — trois conventions

| Convention | Où | Effet |
|---|---|---|
| Inclusive | `restaurant_reporting_service.dart:453`, `:998`, `loss_service.dart:116-117`, `payment_service.dart:180-181`, `staff_service.dart:287-288`, `staff_contest_service.dart:123-124`, `ingredient_allocation_service.dart:242` | `to` compris |
| Inclusive, écrite en négatif | `cash_closure_service.dart:122`, `staff_service.dart:1036` | identique |
| **Demi-ouverte** | `restaurant_reporting_service.dart:952` (`payrollDaysOf`) | `to` exclu |

`rangeFor(today)` rend `[minuit, minuit+1j]` avec des bornes **inclusives**
partout ailleurs : **une vente encaissée le lendemain à 00:00:00 pile est
comptée dans la journée d'hier.** Idem pour une dépense, une perte, un
paiement.

Probabilité faible — il faut la seconde exacte — mais le défaut est
systématique, présent sur sept chemins, et inversé sur le huitième.

**Zone non couverte.**

### 3.4 Fuseau horaire — l'appareil, jamais la boutique

Aucun fuseau de boutique n'existe. Le stockage est correct (`toUtc()` à
l'écriture, `toLocal()` à la lecture), mais `DateTime.now()` et
`DateTime(y, m, d)` sont **locaux** : les journées suivent l'appareil.

*Atténuation* : pertes et dépenses stockent une **date nue** (`dayKey`), donc
insensible au fuseau. Ce sont les ventes, paiements et pointages qui portent des
horodatages complets et y sont sensibles.

**Zone non couverte.**

### 3.5 Le service qui finit à 1 h du matin

| | Date retenue | Journée |
|---|---|---|
| Chiffre d'affaires | `completed_at` (`:449`) | l'encaissement → le lendemain |
| Caisse | `_settledAt` = `completed_at` (`:151-163`) | le lendemain, **mais** la période court depuis le dernier Z |
| Heures supplémentaires | `clockOut` | la sortie → le lendemain |

Les trois sont cohérents **sauf la caisse**, qui suit le cycle Z. Un service de
nuit apparaît donc dans la **caisse de la veille** et le **CA du lendemain**.

**Zone non couverte, et la plus concrète de la section** : le document ne
définit pas la « journée de service » d'un restaurant qui ferme après minuit —
le cas normal du métier.

### 3.6 Ce qui est déjà juste

Le choix de la **date de rattachement** est bon partout : `completed_at` et non
`created_at` pour le CA et la caisse, `clockOut` pour les heures
supplémentaires, `paidAt` pour les salaires. Ces choix sont explicites et
documentés. Le problème n'est pas *quelle date*, mais *quelle fenêtre* et *avec
quelles bornes*.

---

## 4. Les partenaires et la livraison

### 4.1 Un restaurant peut-il avoir un partenaire — oui

`StockLocationType.partner` (`stock_location.dart:15`) n'est lié à aucun
secteur. L'item « Partenaires » a été retiré du tiroir
(`shell_nav_items.dart:488-491`) mais « la page `/parametres/partner-accounts`
reste accessible par deeplink » — route `app_router.dart:1100`, **sans garde de
secteur**.

Le mécanisme est atteignable depuis un restaurant, mais par aucun chemin de
l'interface restaurant. Ni interdit, ni proposé.

### 4.2 Le pot commun — atteignable, incohérent avec le bilan

Le livre partenaire est alimenté depuis six endroits, **tous e-commerce**
(`caisse_page.dart:1871, 1886, 1904, 2006`,
`partner_ledger_detail_page.dart:174, 200`). Le restaurant n'y écrit jamais.

Les cinq natures d'écriture (`partner_ledger_entry.dart:25-47`) :
`saleCollected`, `deliveryOwed`, `remittance`, `partnerCharge`, `advance`. Seule
`partnerCharge` est reprise en dépense, par `dashboard_providers` et
`expenses_page`.

**L'incohérence** : une `partnerCharge` saisie par un restaurateur serait reprise
par le tableau de bord **e-commerce** — mais `RestaurantReportingService` ne lit
jamais le livre partenaire. La charge existerait sans entrer dans le bénéfice du
restaurant.

*Risque théorique* : le chemin est un deeplink, pas un bouton. Il grandira si
quelqu'un remet l'item dans le tiroir.

**Zone non couverte** : la définition financière ne mentionne les partenaires
nulle part.

### 4.3 La livraison — le tracé complet

**Où la recette entre.** `sale.dart:481-482` :

```dart
double get total =>
    subtotal - discountAmount + taxAmount + (deliveryPrice ?? 0) + totalFees;
```

Les frais de livraison sont dans `Sale.total`, et la **caisse les compte** :
`computeSystemCash` retient `o.isFullyPaid ? o.total : o.amountPaid`.

**Où elle n'entre pas.** Le CA additionne `_grossLine(it)` article par article.
`deliveryPrice` n'y figure jamais — exclusion documentée
(`restaurant_reporting_service.dart:469-471`).

| | Livraison comptée ? |
|---|---|
| Caisse | **oui** |
| Chiffre d'affaires | **non** |
| Charge du livreur | **n'existe pas** |

**Conséquence que le document ne décrit pas** : la livraison crée un écart
permanent entre la caisse et le CA. 500 000 F de plats plus 40 000 F de
livraisons donnent 540 000 F au tiroir et 500 000 F de chiffre d'affaires, sans
explication à l'écran.

**Le restaurant peut livrer**, depuis peu : `order_type_sheet.dart:27-32`
(dans `HEAD`) — « TROIS TYPES : sur place, à emporter, à livrer. La livraison,
longtemps exclue, a été rouverte — mais volontairement SANS le circuit
e-commerce : on saisit une adresse et des frais, point. »

⚠ *La mémoire du projet affirme le contraire (« pas de livraison ») : elle est
périmée.*

**Ce qui existe et serait réutilisable** : `PartnerLedgerEntryType.deliveryOwed`
— ce que la boutique doit au partenaire pour une livraison réussie — est
**exactement** la charge manquante, déjà modélisée et synchronisée. Plus
`partnerCharge`, et `Sale.deliveryMode`/`inHouse` (`sale.dart:249`) pour le
livreur interne.

`grep "deliveryCost|courierCost|riderCost"` sur tout `lib/` → **une seule
occurrence : le commentaire qui constate le manque.** Ce qui manque n'est pas un
modèle de données, mais une saisie et un branchement.

---

## 5. Ce qui est exportable

### 5.1 Aucun export ne parle restaurant

Sept exports existent (`exports_page.dart:42-122`). `find lib/features/restaurant
-name "*export*"` → **aucun résultat**.

| Donnée financière restaurant | Exportable ? |
|---|---|
| Ventes | via **Commandes** (export e-commerce) |
| Dépenses quotidiennes | via **Dépenses** |
| Pertes | **non** |
| Coût matière / food cost | **non** |
| Paie, avances, heures supplémentaires | **non** |
| Clôtures de caisse, écarts | **non** |
| Ingrédients, fiches recettes | **non** |
| Notation, primes, casse, absences | **non** |

**Zone non couverte** : le document ne mentionne l'export nulle part.

### 5.2 Les définitions divergent — et c'est écrit dans le code

`orders_export_source.dart:14-29` documente **deux limites explicitement non
corrigées** : aucun filtre de période, et un total calculé deux fois dont les
formules « n'ont PAS été prouvées identiques ».

Pour le restaurant, c'est pire — ce commentaire compare l'export au tableau de
bord *e-commerce* :

| | Formule |
|---|---|
| Export (`_totalFromMap:134-161`) | `(articles − remise) × (1+TVA) + frais + livraison` |
| CA restaurant (`:473-481`) | `(articles − remise) × (1+TVA)` |
| `Sale.total` (`sale.dart:481`) | `sous-total − remise + TVA + livraison + frais` |

**Trois formules**, et l'export en applique une quatrième variante : il
privilégie un cache `amount_total`/`total` s'il existe (`:135-136`).

500 000 F de plats, 40 000 F de livraisons, 15 000 F de consignes → **555 000 F**
dans l'export, **500 000 F** sur le tableau de bord. L'écart de 55 000 F n'est
expliqué nulle part.

**Écart à une règle écrite** (§2 et son tableau d'exclusions).

### 5.3 Une colonne bien conçue

L'export porte `Montant`, **`Montant CA`** et **`Montant perte`**, ajoutées
parce que « "Montant" seul induit en erreur ». Le classement statut→nature est
**partagé** (`classifyOrderStatus`) ; c'est le montant qui ne l'est pas encore.

### 5.4 Facture et reçu — la bonne formule, un troisième périmètre

La facture affiche `sale.subtotal`, `sale.deliveryPrice`, `sale.total` — les
montants viennent de **l'entité**, pas d'un recalcul. C'est le seul des trois
chemins qui ne réimplémente rien. Le restaurant imprime bien par là
(`bill_page.dart:224`, `restaurant_checkout.dart:97`).

Mais la facture affiche `Sale.total`, livraison comprise, quand le CA l'exclut.
Le client reçoit un document à 555 000 F pour un chiffre d'affaires de
500 000 F. **Ce n'est pas un défaut de la facture** — elle doit afficher ce que
le client paie. C'est la preuve que trois notions coexistaient sans être
nommées.

*Le ticket de cuisine est cohérent par construction : aucun prix.*

---

## 6. La robustesse

### 6.1 Les tables de protection — aucune table financière restaurant

```dart
criticalTables  = {'orders', 'sales', 'expenses', 'restaurant_tables'}
neverDropTables = {'partner_ledger_entries', 'orders', 'sales',
                   'expenses', 'restaurant_tables'}
```
(`app_database.dart:1485-1487`, `1768-1774`)

Sur les 28 tables restaurant synchronisées, **la seule protégée n'est pas
financière** : c'est le plan de salle.

**Piège de nommage** : la liste protège `expenses`, la table e-commerce. Les
dépenses restaurant vivent dans `daily_expenses`, avec sa propre boîte Hive
(`hive_boxes.dart:40` contre `:137`).

Une erreur permanente sur une table non protégée fait **supprimer l'opération de
la file** (`:1775-1784`). L'achat marché de 200 000 F saisi hors-ligne disparaît
silencieusement : il reste en Hive local et n'existe sur aucun autre appareil.

### 6.2 Hors-ligne — le bilan ne dit jamais qu'il est incomplet

`build()` enveloppe **sept** blocs de lecture dans des `try/catch` qui
`debugPrint` et continuent : catalogue (`:411`), ventes (`:528`), pertes
(`:571`), charges (`:652`), dépenses (`:764`), paie (`:808`), activités
(`:818`). Chaque échec produit un agrégat à zéro.

Aucun indicateur de complétude n'existe.

Le cas « table jamais remontée » est pire : **il ne lève pas d'exception**. Hive
rend une boîte vide, le calcul réussit, et le chiffre est partiel sans qu'aucune
trace ne le signale.

**Zone non couverte, la plus grave de la section.**

### 6.3 Division par zéro — aucune n'est possible

Onze divisions dans la chaîne financière, **toutes gardées** : `marginRate` ×2,
`costCoverage`, `theoreticalFoodCostRate`, `realFoodCostRate`,
`supplyLossSeries`, `share` ingrédient, `daily` paie, `payrollShareOf`,
`perPart`, prorata d'embauche.

### 6.4 Arrondis — un point d'accumulation

Deux arrondis seulement : `losses.round()` (`:735`) et `payroll.round()`
(`:869`). Les accumulations se font en `double`, l'arrondi n'intervient qu'à la
fin — l'erreur ne s'accumule pas.

**Mais une asymétrie subsiste.** `expenses` utilise `payroll` **arrondi**,
`expenseSeries` utilise `payrollSeries` **non arrondi**. L'invariant du lot 1 —
`somme(expenseSeries) == expenses` — n'est donc pas exactement tenu :

```
payrollSeries somme : 116129.032258     (août, 12 jours sur 31, 300 000 F)
payroll (arrondi)   : 116129
écart               : 0.032258 F
```

Borné à 0,5 F par mois couvert, invisible à l'écran. Mais **le test du lot 1 ne
l'attrape pas** : son helper passe `payrollSeries: [0]`, donc il vérifie
l'invariant sur le seul cas où il ne peut pas échouer.

### 6.5 Un point positif structurel

Pertes et dépenses stockent une **date nue** ; les montants sont des `int` en
FCFA dans `DailyExpense`, `Loss`, `Payslip`, `SalaryAdvance`, `CashClosure`.
**Aucune dérive de virgule flottante sur les montants stockés.**

---

## 7. La couverture de tests

### 7.1 Le compte

**850 tests** dans le dépôt. **413 touchent l'argent au restaurant**, soit 49 %.

| Domaine | Tests |
|---|---|
| Personnel et paie | 157 |
| Coût matière | 97 |
| Pertes et consignes | 42 |
| Bilan | 22 |
| Caisse et règlements | 44 |
| **Les neuf lots** | **51** |

### 7.2 Ce qu'aucun test ne couvre

* **§1** — cycle X/Z, origine du fond, sort de la `variance`, entrées d'espèces
* **§2** — remboursement, commande figée, écart facturé/encaissé, suppression
  d'un règlement, et le fait qu'aucun écran n'appelle `reportBadDish`
* **§3** — cohérence des bornes entre les huit chemins, fuseau, service de nuit
* **§4** — atteignabilité du livre partenaire, écart caisse/CA de la livraison
* **§5** — accord entre la formule de l'export et celle du CA
* **§6** — appartenance aux listes de protection, table manquante, **et
  l'invariant du lot 1 en présence de paie**

### 7.3 Le motif que révèle ce croisement

Les 51 tests des lots 1 à 9 couvrent **tous des fonctions pures**, extraites
exprès pour être testables sans Hive.

**Aucun ne teste `build()`**, la fonction de 500 lignes qui les assemble — sa
documentation le dit depuis l'origine. C'est exactement pourquoi l'écart
d'arrondi de 6.4 a survécu : il ne vit pas dans une fonction pure, mais dans
l'assemblage.

---

## Classement général

### Argent faux ou perdu

| # | Constat | § | Nature |
|---|---|---|---|
| 1 | Une opération de synchronisation financière est abandonnée après dix tentatives | 6.1 | règle manquante |
| 2 | Un bilan partiel a l'apparence d'un bilan juste | 6.2 | règle manquante |
| 3 | L'écart de caisse n'entre pas au bilan | 1.5 | règle manquante |
| 4 | Aucun chemin de remboursement client | 2.1 | **écart écrit** (§4) |
| 5 | Le plat raté ne peut pas être déclaré | 2.8 | **écart écrit** (§4) |
| 6 | La livraison encaissée sans charge | 4.3 | **écart écrit** (§2) |
| 7 | Un remboursement de casse en liquide n'a pas de chemin | 1.2 | règle manquante |
| 8 | Double clôture Z sans garde | 1.3 | règle manquante |
| 9 | Bornes inclusives sur `to` | 3.3 | règle manquante |

### Incohérence entre deux écrans

| # | Constat | § | Nature |
|---|---|---|---|
| 10 | Trois définitions du « mois » | 3.2 | **écart écrit** (§6) |
| 11 | L'export applique une formule différente du CA — 55 000 F | 5.2 | **écart écrit** (§2) |
| 12 | Caisse et CA divergent du montant des livraisons | 4.3 | règle manquante |
| 13 | Facturé contre encaissé : la créance n'est nulle part | 2.3 | règle manquante |
| 14 | L'export ignore la période | 5.2 | **écart écrit** (§6) |
| 15 | Deux appareils divergent après abandon de synchronisation | 6.1 | règle manquante |
| 16 | Clôtures concurrentes : deux Z, mêmes ventes | 1.3 | règle manquante |
| 17 | Une charge partenaire au bilan e-commerce, pas restaurant | 4.2 | règle manquante |
| 18 | Un service de nuit : caisse de la veille, CA du lendemain | 3.5 | règle manquante |

### Zone non couverte par le document

19. Les entrées d'espèces — 1.2
20. Le cycle de caisse : période, Z unique, multi-appareil — 1.3
21. L'origine du fond de caisse — 1.4
22. Comment défaire une commande encaissée — 2.2
23. La créance client au restaurant — 2.3, 2.4
24. Dix définitions de période là où la §6 en annonce trois — 3.1
25. Aucun fuseau de boutique — 3.4
26. La « journée de service » après minuit — 3.5
27. Les partenaires : ni interdits, ni intégrés — 4.1, 4.2
28. Aucun export restaurant — 5.1
29. Trois montants sans nom — 5.4
30. La durabilité et la complétude des données — 6.1, 6.2

### Dette de forme

31. `expenses` protégée, `daily_expenses` non — 6.1
32. L'invariant du lot 1 n'est pas exactement tenu : 0,03 F — 6.4
33. Le total calculé à trois endroits, « pas prouvés identiques » — 5.2
34. Une convention de borne inversée entre `payrollDaysOf` et le reste — 3.3
35. `reportBadDish` sans appelant — 2.8
36. La page Partenaires atteignable par deeplink sans garde de secteur — 4.1
37. L'histogramme à 7 jours recalcule sa propre fenêtre — 3.1
38. La mémoire du projet affirme « pas de livraison » — périmé — 4.3
39. `build()` non testable : 51 tests sur les fonctions pures, zéro sur
    l'assemblage — 7.3

---

## Ce qu'il manque au document

**Six règles**, en trois familles.

### Le temps

La §6 pose un principe — « une seule fenêtre fait autorité : le mois » — et
s'arrête là. Il manque :

1. une **convention de bornes**, écrite une fois et appliquée partout ;
2. une **définition de la journée de service**, qui ne peut pas être le jour
   civil dans un métier qui ferme à 1 h ;
3. une décision sur **le sort des périodes courtes** — sept boutons affichent
   des marges que la §6 déclare dépourvues de sens.

### Les trois montants

Le manque le plus structurant, apparu dans trois sections indépendamment. Le
document définit le chiffre d'affaires (§2) et le contenu de la caisse (§7) sans
jamais poser qu'ils diffèrent. La livraison le révèle (§4), l'export le confirme
(§5), le paiement partiel l'aggrave (§2).

4. **Nommer les trois montants** — payé par le client, entré en caisse, compté
   en recette — et dire lequel va où.

### Ce qui doit survivre

Dix sections de calculs, zéro ligne sur la condition de leur validité.

5. **Quelles tables ne doivent jamais être abandonnées.**
6. **Ce que doit afficher un bilan qui sait qu'il lui manque quelque chose.**
   Les lots 4 et 6 ont appris à dire « estimé » pour un manque *connu* ; rien ne
   couvre le manque *inconnu*.

### Et deux règles écrites ne sont pas tenues

Le remboursement (§4 prévoit `refunded`, le code ne sait pas le produire) et le
plat raté (§4 liste `plat_mal_fait`, aucun écran ne le déclare). Ce sont les
deux seuls cas où le document a raison et le code a tort — partout ailleurs,
c'est le document qui est muet.

---

## Suite donnée

Les règles **4, 5 et 6** étaient déductibles — elles décrivent ce qui existe ou
étendent un principe déjà posé — et ont été écrites le 19/09/2026 : « Les trois
montants » en §2, « Ce qui doit survivre » en §11 de la définition financière.

Les règles **1, 2 et 3** exigent un arbitrage métier et restent ouvertes.
