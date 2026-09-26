# Fortress POS — Backlog

Ce qui est constaté, accepté pour l'instant, et doit revenir. Chaque entrée
dit OÙ elle a été vue, ce qu'elle coûte, et pourquoi elle n'a pas été
corrigée sur place. Une entrée n'en sort qu'avec le titre du commit qui la
referme.

---

## ⚠ PRIORITAIRE — Mentions légales du ticket

### Le NIU n'existe pas : les tickets n'ont pas de valeur fiscale

*Constaté à la refonte du ticket de caisse restaurant (26/09/2026). Inscrit
PRIORITAIRE par décision produit : plus grave que tout le chantier visuel, et
invisible.*

Une facture émise par un commerce déclaré au Cameroun doit porter son **NIU**
(Numéro d'Identifiant Unique). Fortress ne le stocke NULLE PART — ni `shops`,
ni `ShopSummary`, ni les réglages, ni les migrations. Pas davantage le RCCM, la
raison sociale, le régime fiscal, l'adresse ni la ville de la boutique. Les
utilisateurs impriment aujourd'hui des tickets sans valeur devant
l'administration.

Le ticket restaurant est prêt à les recevoir : la ligne NIU n'apparaît pas
tant que la donnée n'existe pas (pied de `RestoTicket`).

Coût du lot de données : un hotfix (`shops` : `niu`, `rccm`, `legal_name`,
`tax_regime`, `address`, `city`) ; les champs dans `ShopSummary` et les deux
chemins de synchronisation ; un formulaire dans les réglages de la boutique.
**Repoussé derrière l'autre chantier** : `shop_settings_page.dart` y est déjà
modifié, c'est là qu'est le vrai coût — ne pas y ouvrir un second front.

### Pas de numéro de commande court

Le ticket restaurant imprime « Réf. » + les 6 derniers caractères de l'id.
Un vrai numéro séquentiel est un lot à part : une séquence serveur ne marche
pas hors ligne (le ticket s'imprime avant la synchro), un compteur local entre
en collision dès deux postes.

### Les ids de commande du restaurant sont encore horodatés

`restaurant_order_service.dart` (lignes 249, 343, 408, 539) crée ses commandes
en `order_<millisecondes>`, alors que la caisse est passée à l'UUID v4 (id
devinable, collision de deux commandes dans la même milliseconde). C'est ce
format qui imprimait « ORDER_17 » sur tous les tickets.

### Ticket e-commerce — les glyphes absents de Helvetica

Le ticket e-commerce (non touché, décision de secteur) imprime toujours en
Helvetica : le « − » de la remise et l'apostrophe « ’ » n'y sortent pas.
Correctif connu : celui du restaurant (Inter embarquée, `RestoTicketPdf`).

---

## Dette de palette

Des tokens dont la valeur ne tient pas le contraste là où ils servent. Ce ne
sont pas des défauts d'un écran : c'est la PALETTE qui est en cause, et un
écran ne peut que les contourner. Les contournements sont nommés ci-dessous
pour qu'on sache quoi défaire le jour où le token sera corrigé.

### ~~`AppColors.textHint` en sombre — sous le seuil AA du petit texte~~ — RÉSOLU

*Soldé le 26/09/2026 par « fix(thème): textHint en sombre dérivé à 4,5:1 ».*
Valeur dérivée `#8190A6` = `lerp(#64748B, textSecondary, 0,60)`, 4,51 sur la
carte, dans `AppColors` ET `AppTheme._dTextHint` ; garde-fou
`text_hint_contrast_test.dart`. Global : l'e-commerce bouge aussi, en sombre
seulement ; le clair est inchangé. Le contournement de l'écran Commandes
(`textHint` réservé aux onglets vides) RESTE : c'est une règle de hiérarchie,
plus une rustine. Hors garantie : la teinte de marque (aucun gris n'y tient,
voir la section 3 du document de design).

Historique :

*Signalé deux fois : lot 1 des marges (3,95:1 sur le panneau de verre du mode
restaurant, cf. `resto_surfaces.dart`), puis épuration de l'écran Commandes
(24/09/2026).*

`#64748B` en sombre fait **3,07:1 sur `surface` (`#1E293B`)** et **3,75:1 sur
le fond (`#0F172A`)**. Le seuil AA d'un texte de 11 à 12 px est 4,5:1. En clair
le token passe (5,98:1).

Il manque un niveau « éteint mais lisible » entre `textSecondary` (5,71:1) et
`textHint`. Aucun écran ne doit l'inventer.

Contournement en place : l'écran Commandes (restaurant) n'emploie `textHint`
QUE pour les onglets vides ; tout le reste de l'atténué y passe par
`textSecondary`.

### Midnight en sombre — la primaire disparaît sur la carte

*Signalé deux fois : c'est la seconde fois que Midnight sort d'un lot par le
bas. Constaté à l'épuration de l'écran Commandes (24/09/2026).*

**Mesure corrigée par l'audit UI du 24/09/2026 : le vrai chiffre était 1,00:1,
pas 1,93.** Il y avait TROIS primaires en sombre, et l'entrée n'en décrivait
qu'une :

- `colorScheme.primary` = `primaryLight` = `#475569` : 1,93:1 sur `surface`
  (la seule décrite ici jusqu'alors) ;
- `AppColors.primary` = la primaire BRUTE `#1E293B`, sans variante sombre :
  **identique à la carte, 1,00:1** — ≈ 249 textes, 226 icônes, 117 traits ;
- `sem.brand` / `sem.brandText` = la même primaire brute : 1,00:1, y compris
  sur leur propre `brandSurface`.

Midnight est en outre IMPOSÉE d'office quand le logo est monochrome
(`LogoThemeBuilder.buildFromLogo`).

**Refermée par `fix(theme): la primaire en sombre est dérivée — plus de texte
à 1,00:1 sur Midnight` (lot 1, tokens de marque en sombre, 25/09/2026).** Les trois
primaires sont désormais DÉRIVÉES par `core/theme/brand_contrast.dart` :
`#8A8F99` pour Midnight, 4,51:1 sur la carte. Voir les deux entrées qui
suivent pour ce que ce lot laisse ouvert (lot 1b, `primarySurface`).

Les contournements de l'écran Commandes (l'onglet actif se lit aussi par la
graisse et la couleur de son libellé ; les montants sont en texte primaire et
non en couleur de marque) restent en place : ils ne dépendaient pas du
contraste de la primaire et n'ont rien à défaire.

### ~~Lot 1b — fonds pleins peints à la main en primaire, sous du texte blanc~~ — RÉSOLU

*Compromis accepté le 25/09/2026 avec le lot 1 ; soldé en clair par le lot 1
clair, puis en sombre par le lot 1b (26/09/2026).*

Token `AppColors.primaryFill` : le fond des boutons du thème en sombre
(`fillUnderWhite(primaryLight)`, ≥ 4,5:1 sous le blanc), `primary` en clair.
144 fonds pleins en primaire inventoriés dans 78 fichiers ; **124 repointés**
(dont le bouton plein du tiroir, caché dans un ternaire, et 2 boutons de
`shop_settings_page` que seul HEAD contient encore — un autre chantier les
supprime)
(113 à contenu blanc, et 13 `FilledButton` dont le libellé venait du thème —
blanc lui aussi — moins les cas écartés). Restent sur `primary`, à raison :
16 à contenu `onPrimary` (5,49–7,04:1), 3 sans contenu (points « filtre
actif », barre du tiroir super-admin), le bouton de connexion (`onPrimary`
revendiqué). Garde-fou : `primary_fill_guard_test` (boutons `styleFrom`).

### `printer_page.dart` — un bouton à repointer vers `primaryFill`

*Inscrit le 26/09/2026 avec le lot 1b.* Fichier NON SUIVI d'un autre chantier
(`lib/features/parametres/presentation/pages/printer_page.dart`), laissé
intact : un `styleFrom(backgroundColor: primary)` sous un libellé blanc, à la
ligne ≈ 181. Le garde-fou `primary_fill_guard_test` le signale dans le dossier
de travail tant qu'il n'est pas corrigé — c'est voulu.

### Midnight en sombre — le fond de marque se confond avec la carte

*Inscrit le 26/09/2026.* Le fond des boutons sombres de Midnight (`#475569`)
ne se distingue de la carte qu'à 1,93:1 (les sept autres palettes : 3,25). Le
bouton reste reconnaissable par son libellé blanc (7,58:1) ; défaut antérieur
au lot 1b, partagé avec les boutons du thème.

### Texte en primaire sur `AppColors.primarySurface` en sombre — sous l'AA

*Inscrit le 25/09/2026 avec le lot 1, par décision : « une variante par
usage ».*

En sombre, `AppColors.primarySurface` est la primaire BRUTE à 22 % sur la carte
(`app_colors.dart`, `_refreshPrimarySurface`) : élément sélectionné du tiroir,
puces, bandeaux teintés — **131 sites** `AppColors.primarySurface` (HEAD
`19d0048`). Le texte ou l'icône en `AppColors.primary` posé dessus :

| Palette | Avant le lot 1 | Après |
|---|---|---|
| Violet | 1,92 | 3,91 |
| Rose | 3,24 | 3,51 |
| Midnight | 1,00 | 4,51 |
| Indigo | 1,99 | 3,85 |
| Ocean / Emerald / Sunset / Amber | 3,43–3,96 | inchangé |

Le lot 1 AMÉLIORE ou laisse égal chaque cas, mais sept palettes sur huit
restent sous 4,5:1.

Pourquoi ce n'est pas réglé : tenir 4,5:1 sur cette teinte demande
d'éclaircir la primaire des huit palettes, et les fonds pleins peints à la
main en `AppColors.primary` sous du blanc (lot 1b) tomberaient alors à
2,2–2,8:1. `brand` / `brandText`, eux, sont calculés AVEC leur teinte
(`BrandContrast.darkBrandText`) : ils vivent dessus par construction.

Piste, sans décision : une teinte `primarySurface` plus sombre en mode sombre,
ou un token texte dédié à cette surface. Ne PAS élargir `BrandContrast.darkText`
aux teintes — c'est l'option écartée ci-dessus.

### Mode clair — deux tokens manquants : l'OMBRE et le FOND TEINTÉ

*Signalés DEUX FOIS : au lot Apparence (page Thème) et au lot Carte de
commande (25/09/2026). Inscrits à la seconde.*

Le mode clair n'a jamais été vérifié (audit du 24/09/2026), et deux lots de
suite ont buté sur les mêmes absences :

- **Pas de token d'OMBRE.** En clair, une carte blanche posée sur un fond
  blanc n'a plus de bord (1,00:1) : la séparation doit passer par une ombre
  légère. Chaque écran l'écrit à la main — la grille des Commandes
  (`shadowColor` à 7 %, flou 12), la liste (`Colors.black` à 3 %), la page
  Thème n'en a aucune faute de token. En sombre, c'est l'écart de fond qui
  sépare, pas l'ombre.
- **Pas de token de FOND DE PAGE TEINTÉ** vers la primaire. Le seul candidat,
  `primarySurface`, est d'intensité très inégale selon la palette (Amber
  `#FEF3C7`, franchement jaune ; Violet `#F5F0FF`, discret) ;
  `AppColors.background` (`#F8F7FC`) est fixe et ne suit pas la palette.

À faire : trancher les deux tokens (valeurs, et pour le fond : dérivé de la
palette par une fonction qui s'arrête à une teinte faible, comme
`BrandContrast`), puis les poser sur les écrans qui les attendent. Aucun lot
ne doit les inventer en attendant.

## Cibles tactiles

### Lot 2 — les ≈ 154 cibles sous 48 px laissées hors du lot

*Inscrit le 25/09/2026 avec le lot 2 (cibles tactiles), à la demande : compté
PAR FEATURE, pour savoir où chercher le jour où l'on ouvrira chacune.*

Le lot 2 a rendu le thème adaptatif (tous les Elevated / Outlined / Text /
FilledButton sans style propre montent à 48 px au doigt) et corrigé les gestes
du service et de la caisse un par un (cf. `core/widgets/touch_target.dart`).
Restent les sites qui dimensionnent LEUR cible à la main : `IconButton`
contraints ou compacts, `shrinkWrap` local, `InkWell` / `GestureDetector`
autour d'une boîte de moins de 48 px.

Heuristique (regex, arbre de travail du 25/09/2026), sans les 6 faux positifs
connus déjà couverts par une zone extérieure :

| Feature | Sites |
|---|---|
| inventaire | 43 |
| shared/widgets | 21 |
| parametres | 16 |
| caisse | 13 |
| restaurant | 13 |
| super_admin | 10 |
| onboarding | 8 |
| crm | 6 |
| auth | 4 |
| catalogue | 4 |
| hub_central | 4 |
| hr | 3 |
| promo_campaigns, subscription, tickets | 2 chacun |
| expenses, finances, marketing | 1 chacun |
| **Total** | **≈ 154** |

Par nature : ≈ 82 `InkWell`/`GestureDetector` sur une boîte < 48, 36
`IconButton` contraints, 29 compacts, 13 `shrinkWrap` locaux.

Côté restaurant, ce qui reste n'est PAS un geste de service : Finances,
tableau de bord (flèches du carrousel), fiche plat, réglages du personnel,
feuille de période, réservation (`_RoundBtn` 44 × 44).

Deux pièges à relire avant d'en corriger un (ils sont dans l'en-tête de
`touch_target.dart`) : un parent à hauteur FIXE qui laisse sa colonne libre
fait DÉBORDER (tuile de table, `mainAxisExtent: 82` — d'où la zone superposée
du ⋮) ; un parent à hauteur fixe qui contraint PLAFONNE la cible sans erreur
(puce de date de 38 px dans les Commandes e-commerce).

Code mort signalé en passant : `KitchenTicketCard` — **supprimé le
26/09/2026** (lot « nettoyage de forme ») ; il n'avait plus d'appelant depuis
la suppression de l'écran Préparation (`66c6c2f`, 07/08/2026).

## Shell

### Titres de page de l'e-commerce — « FORTRESS » seul, titres dérivés de l'URL

*Inscrit le 25/09/2026 avec le lot Shell (restaurant) : même défaut, sur un
secteur en production et hors du lot.*

Le titre d'une page du shell se résout ainsi (`adaptive_scaffold.dart`,
`_MobileShell`) : `titleForLocation` (`page_titles.dart`), sinon l'enfant de
navigation actif, sinon l'item de navigation dont la route est un PRÉFIXE,
sinon un repli qui dérive le dernier segment de l'URL. Le lot Shell a donné
leurs titres aux sous-pages du restaurant ; côté e-commerce (compté sur HEAD
`2e8bdb0`, à partir des routes du routeur) :

- **3 sous-pages n'affichent que « FORTRESS » sur ordinateur** (aucun item de
  navigation ne les couvre) : `/aide`, `/apropos`, `/employees` (en
  e-commerce, cette route n'est pas dans le menu).
- **2 titres dérivés de l'URL, fautifs, sur mobile** : « Apropos » (sans
  espace ni accent) et « Employees » (en anglais). `/aide` donne « Aide »,
  juste par chance.
- **17 sous-pages portent le nom de leur SECTION, pas le leur** (mobile ;
  « FORTRESS › <section> » sur ordinateur) : `/caisse/payment`,
  `/campaigns/:id/send`, `/crm/notify`, `/inventaire/purchase-orders`,
  `/inventaire/quick-add`, `/inventaire/receptions`, `/inventaire/returns`,
  `/inventaire/stock-movements`, `/parametres/caisse`, `/parametres/exports`,
  `/parametres/livraison`, `/parametres/marketing`,
  `/parametres/partner-accounts`, `/parametres/partner/:id`,
  `/parametres/section/:key`, `/parametres/text-size`, `/tickets/:id`.
- **2 clés périmées dans `page_titles.dart`** : `/inventaire/movements` alors
  que la route est `/inventaire/stock-movements`, `/inventaire/arrivals` alors
  qu'elle est `/inventaire/receptions` — deux titres écrits qui ne
  s'affichent jamais.

À faire : un `case` par route dans `page_titles.dart`, avec le titre que la
page se donne elle-même, et le même modèle que le restaurant (titre dans le
corps pour une page racine, dans la barre pour une sous-page) — à décider
pour l'e-commerce, dont le shell historique garde son fil d'ariane.

## Liserés

### Liserés hors de la règle « contour non, liseré d'état oui »

*Inscrit le 26/09/2026 avec le lot « liseré en grille ».*

La règle (document de design, section 16) : un liseré sur le seul bord
gauche, 4 px (`kStateStripeWidth`), permis quand l'état est l'information
principale de la carte ET qu'un libellé l'écrit à côté. Ne la suivent pas
encore :

- **Tableau de bord restaurant** (`restaurant_dashboard_page.dart:299`) :
  liseré de **3 px** sur les tuiles d'indicateurs, qui porte la NATURE de
  l'indicateur (l'argent en vert…), pas un état. À trancher : la règle
  s'étend-elle aux liserés de nature (→ 4 px), ou ce liseré devient-il autre
  chose ?
- **E-commerce** (hors périmètre sans décision) : liseré « stock bas / sans
  prix » de l'inventaire (`inventaire_page.dart:2479`), liseré de tendance du
  Hub central (`hub_dashboard_page.dart:877`), liseré primaire de la section
  Propriétaire (`employees_page.dart:1121`).
- **Point d'état de 6 px** sur les membres d'« Accès à l'app »
  (`employees_page.dart:1307`) : même fonction, avec libellé ; mais l'état
  n'y est pas l'information principale (c'est la personne) → la règle du
  liseré ne s'y applique pas telle quelle.

## Couleurs en texte

### ~~Lot 1 clair — les éléments interactifs qui gardent la primaire en texte~~ — RÉSOLU

*Inscrit le 26/09/2026, résolu le même jour par le lot 1 clair.* La primaire
du mode clair est dérivée (`BrandContrast.lightText`) ; les huit éléments
(lien « Voir » du Menu, « Voir la carte » et « Tout masquer » du tableau de
bord, choix de secteur sélectionné, « Nouvelle » de la fiche plat, puce de
partage de l'addition, bouton « Encaisser », boutons d'action non pleins)
s'écrivent en `semantic.brandText`, marqueurs retirés.

### Informations écrites en couleur d'état — écart à la section 16

*Inscrit le 26/09/2026 avec le même lot.*

Le lot a corrigé le CONTRASTE (variante `*Text`) sans changer le SENS : ces
textes sont des informations, que la section 16 voudrait sans couleur
(`textSecondary`). Ne pas faire les deux à la fois : on ne saurait plus lequel
a causé quoi si le rendu déplaît. À trancher écran par écran :

- **Personnel** — « Déjà payées de la main à la main » / « Déjà portées sur
  une fiche de paie » et « Reportées… » (vert) ; « payée » (vert) ; montant
  d'une avance retenue (vert) ; casse soldée (vert) ; ligne « heures sup ·
  casse · mise à pied » (ambre/vert) ; verdict « +1h · payées » (vert) ;
  statut d'excuse « acceptée » (vert) ; absence en cours (ambre).
- **Addition / récapitulatif** — options d'un article (ambre) ; montant de la
  remise (vert).
- **Emballages** — « Ajouté au total de la commande, et déduit de votre
  stock » (ambre).
- **Fiche plat** — marge positive (vert).
- **Clôture de caisse** — écart équilibré (vert).
- **Tableau de bord** — food cost « bon » (vert) ; étapes « prête » / « en
  cuisine » d'une commande en cours (vert / ambre).
- **Notation** — note et bonus « +N » (vert).

### Limite du garde-fou

`semantic_text_guard_test` ne lit que les couleurs posées DIRECTEMENT dans un
style ; une couleur passée par une variable lui échappe (le lot en a trouvé
≈ 50 à la main). Et il ne couvre que `lib/features/restaurant/` : les écrans
restaurant logés ailleurs (`caisse_page.dart`) n'y sont pas.

Le panier restaurant (`cart_widget.dart`) a désormais son garde-fou ciblé,
`cart_text_color_guard_test` (26/09/2026) : il lit TOUTE couleur de base
dans la ligne restaurant et le bandeau « Alerte marge », variables comprises,
et n'admet que fonds teintés, icônes et variables `…Fill`. Sa méthode
pourrait remplacer celle du garde-fou général.

### Couleur seule — les trois cas e-commerce de l'audit

*Inscrit le 26/09/2026, en clôturant le lot « couleur jamais seule » côté
restaurant.*

- Statut d'un ticket de messagerie : pastille de 8 px sans libellé
  (`tickets_page.dart`).
- Lignes du panier e-commerce : seul le montant passe en `warning` sur une
  alerte prix (`cart_widget.dart`, `_CartItemRow`) — le bandeau « Alerte
  marge », partagé, est déjà écrit et lisible. Ces montants sont aussi en
  orange de BASE écrit (≈ 2:1 en clair), comme l'était la ligne restaurant.
- Liseré de 3 px « sans prix de vente » de l'inventaire : rouge seul
  (`inventaire_page.dart`, porte des modifications d'un autre chantier).

## États vides

### Les chemins écrits des notes vides deviendraient des liens

*Inscrit le 26/09/2026 avec le lot « états vides », par décision : pas dans
ce lot (ajouter des navigations dépasse un lot visuel).* Des `RestoEmptyNote`
disent où agir sans y mener : « Créez-les dans « Accès à l'app » »
(`staff_settings_sheet`), « dans Finances → Activités » (`dish_form_sheet`,
secteurs), « dans Finances → Fournitures » (`order_type_sheet`,
`packaging_sheet`), « avec le poste « Livreur » dans Personnel »
(`courier_sheet`).

### L'e-commerce garde ≈ 21 états vides locaux

*Hors périmètre du lot restaurant.* `_EmptyState` ×5, `_Empty` ×3,
`_EmptyHint` ×2, `_EmptyCart`, `_EmptyProducts`, trois dans `dashboard_page`…
face à `EmptyStateWidget`, partagé, dont le bouton n'est pas centré (raison
pour laquelle le restaurant a le sien).

### Pas de banc de test pour un écran sous `AppScaffold`

*Inscrit le 26/09/2026.* L'Addition n'a pas pu être montée en test : son
`AppScaffold` ouvre un canal Supabase et exige tout l'habillage de l'app
(bloc du panier, abonnement, notifications). Ses deux états vides sont
couverts par le garde-fou de sources, pas par un test d'écran.

## Périodes

### Trois sélecteurs de période hors du restaurant, sur le même état

*Inscrit le 26/09/2026, en clôturant le lot « sélecteur de période unique »
côté restaurant (déjà unifié : `RestoPeriodButton`, `e8851af` / `89476ca`).*

Tous lisent et écrivent `dashPeriodProvider`, avec des listes différentes :

- **Tableau de bord e-commerce** (`dashboard_page.dart`) — `_PeriodPicker` +
  `_DateRangePicker` ; aujourd'hui, hier, semaine, mois, année,
  personnalisée. Garde en plus un **miroir local** de l'état, synchronisé à la
  main : le supprimer touche sa logique d'état, pas seulement l'affichage.
- **Hub central** (`hub_dashboard_page.dart`) — `_CompactPeriodSelector` ;
  aujourd'hui, mois, **trimestre**, année ; forme compacte.
- **Finances e-commerce** (`finances_page.dart`) — `PeriodSelector`
  (`shared/widgets/period_selector.dart`), qui se dit « composant unique » et
  n'a qu'un usage ; toutes les périodes, **trimestre compris**.

**Effet visible de la divergence** : l'état étant partagé, un trimestre
choisi au Hub s'applique au tableau de bord du restaurant, qui l'affiche
(« Trimestre ») mais ne le propose pas — aucune ligne de son menu n'est alors
active. À trancher : le trimestre partout ou nulle part ; un seul sélecteur
partagé pour l'e-commerce et le Hub.

## Montants

### Hors du restaurant : copies du compact et montants hors formateur

*Inscrit le 26/09/2026 avec le lot « montants » (règle compacte unique posée
dans `CurrencyFormatter.compact` ; le restaurant est en règle).*

- **Six copies locales du compact**, qui ne suivent pas la règle (« 2k »,
  point décimal…) : `hub_dashboard_page` (×2), `clients_page` (×2),
  `admin_subscriptions_page`, et les `_compact` / `_fmt` de l'e-commerce qui,
  eux, délèguent déjà au canonique.
- **≥ 16 montants affichés hors `CurrencyFormatter`** (audit, § d) — les plus
  exposés d'abord : la **page publique de suivi de commande**
  (`order_tracking_page`, « XAF » en dur, vue par les CLIENTS) et le **message
  WhatsApp** du catalogue (`catalogue_page`) ; puis `admin_panel_page`
  (« XAF »), `stock_movements_page`, `dashboard_page` (sans séparateur de
  milliers), `caisse_page`, `new_product_draft_sheet`,
  `product_quick_add_page`, `new_web_order_banner`.
- **14 `NumberFormat` directs** et 3 boucles `StringBuffer` identiques de
  séparation des milliers (`subscription_page`, `super_admin_page`,
  `delivery_message_builder`).

## Disposition

### ~~Zones hybrides entre 720 et 900 px~~ — TRANCHÉES

*26/09/2026 :* les deux zones sont TRANCHÉES « voulues » (document de design
§ 8, mesures à l'appui) : le Menu (`cartPaneLayout`) et la caisse e-commerce
(`caisseCartInline`) décident désormais sur le CORPS de page, ce qui corrige
au passage la barre latérale dépliée au-dessus de 900. Historique :


*Laissé NON TRANCHÉ le 26/09/2026 (lot « seuils de largeur »).* Entre 720 et
900 px, le Menu du restaurant ouvre son panier en volet LATÉRAL alors que le
shell est déjà en disposition « téléphone » (barre du bas, tiroir) ; entre
800 et 900, la caisse e-commerce met son panier en ligne sous une barre du
bas. À juger à l'œil, à ~800 px, avant de décider : voulu, ou à aligner sur
le 900 du shell.

*26/09/2026 :* la caisse (`/caisse`, seuil 800 lu sur l'ÉCRAN dans
`_PrincipalTab`) n'est plus atteinte par le restaurant — « Modifier la
commande » ne lui est plus proposé, et « Nouvelle vente » ramène au Menu. Ce
cas (audit N6) est désormais purement e-commerce.

### Caisse e-commerce : le bouton panier ouvre un second panier

*Inscrit le 26/09/2026, en tranchant la zone 800–900 (non vérifié à
l'écran).* En e-commerce, le bouton 🛒 de la barre du haut ouvre TOUJOURS une
feuille contenant un panier (`adaptive_scaffold.dart`, `_openCart`) — y
compris sur la caisse quand le panier y est déjà intégré à côté des produits.
Deux paniers à l'écran, le même contenu. `adaptive_scaffold.dart` porte des
modifications d'un autre chantier.

### ~~Menu, barre latérale dépliée entre 900 et ~1 060 px~~ — CORRIGÉ

*Corrigé le 26/09/2026* : la décision de recouvrir lit le corps de page
(`cartPaneLayout`, document de design § 8). Constat d'origine :

*Inscrit le 26/09/2026, en tranchant la zone 720–900.* Le volet panier du
Menu vaut le tiers de l'ÉCRAN, barre latérale comprise. Barre DÉPLIÉE
(247 px) : la carte tombe à 2 colonnes de 138 px à 900, et reste sous le
plancher de 200 px jusqu'à ~1 060. Barre repliée (défaut du restaurant) : pas
de problème (224 px à 900). Correctif possible : le volet mesure le CORPS de
page (tiers du corps, plein écran quand la carte à côté tomberait sous deux
colonnes de 200) — lève la règle « le volet lit l'écran » (§ 8), touche le
bouton « Carte » du panier partagé et `width_threshold_guard_test`.

### Seuils de largeur en dur hors du restaurant

*Inscrit le 26/09/2026.* Le restaurant n'a plus que des seuils nommés (§ 8).
Ailleurs : le **600** écrit dix-sept fois à côté de `kFormMobileBreakpoint`
(`dashboard_page`, `employees_page`, `forgot_password_page`,
`product_grid_widget`…), les **900** du panier e-commerce (`cart_widget` ×4,
`product_grid_widget`) à côté de la constante du shell, 700 (`catalogue_page`,
`inventaire_page`, `super_admin_page`), 800 (`caisse_page`, `login_page`),
340, 500, 720 en dur (`landing_page`, `public_footer`). À classer en seuils
d'écran (→ constante officielle) ou de contenu (→ nommé et justifié).

## Nettoyage de forme

### Fonds colorés sous du blanc, hors de la primaire

*Inscrit le 26/09/2026 avec le lot « nettoyage de forme ».* En complétant le
lot 1b (18 fonds primaires en ternaire, plus le cercle d'option des
Paramètres), deux fonds d'une AUTRE couleur sous du blanc sont apparus :

- `shop_list_page` : le bouton « Nouvelle boutique » a, hors survol, un fond
  `textPrimary` — clair en sombre — sous une icône et un texte blancs ;
- `tickets_page` : la priorité « haute » d'un ticket peint `danger` sous du
  texte blanc (3,76:1 en clair, sous le seuil du petit texte).

### La route `/dev/alerts-demo` n'est PAS en production

*Constat du 26/09/2026, qui corrige l'audit du 24/09.* L'audit la disait
« présente en prod » (garde non déterminée). Elle est enregistrée sous
`if (kDebugMode)` et sa chaîne est ABSENTE du `main.dart.js` servi en
production (vérifié). Rien à faire.

## Architecture

### Cinq fichiers de domaine importent encore Flutter (hors restaurant)

*Inscrit le 26/09/2026, en clôturant le lot « domaine sans Flutter » côté
restaurant (`restaurant_table.dart`, `daily_expense.dart` : couleurs et
icônes passées en présentation ; garde-fou `domain_pure_dart_guard_test`).*
L'audit supposait une migration de format (« `IconData` est stocké ») :
c'est FAUX — les entités se sérialisent par leurs clés ; le déplacement est
de la pure présentation, sans `SchemaMigrator`.

- `caisse/domain/entities/sale.dart` — `Color get color` sur deux enums de
  statut (e-commerce, au cœur de la caisse) ;
- `expenses/domain/entities/expense.dart` — icônes et couleurs des dépenses
  e-commerce ;
- `caisse/domain/invoice_theme.dart` — une `Color` ;
- `caisse/domain/usecases/order_receipt_usecase.dart` — importe
  `material.dart` sans usage apparent ;
- `inventaire/domain/entities/product.dart` — `foundation.dart`.

### Le journal d'activité exige Supabase, même pour une écriture locale

*Inscrit le 26/09/2026, trouvé en montant le banc de test de la fiche plat.*
`AppDatabase.saveCategory` écrit la catégorie dans Hive, puis appelle
`ActivityLogService.log`, qui lit `Supabase.instance` sans garde. Si
`Supabase.initialize` a échoué au démarrage (`main.dart` le tolère : mode hors
ligne), la catégorie est bien enregistrée mais l'appel lève — l'écran qui
l'attend (fiche plat, « + Nouvelle ») s'arrête en erreur. Même risque pour
tout appelant de `ActivityLogService.log`. Le banc contourne en initialisant
un Supabase factice ; le correctif serait une garde dans `log` (acteur `null`
quand Supabase est absent — la ligne part déjà dans la file).

## Grands fichiers

### Le restaurant est découpé ; restent les classes géantes et les fichiers partagés

*Inscrit le 26/09/2026 avec le lot « grands fichiers ».*

**Fait** : les 7 fichiers du restaurant de plus de 1 500 lignes sont découpés
en `part` / `part of` par unité naturelle (18 fichiers `part`) —
`restaurant_staff_page` 2 871 → 334 l. (+ équipe, pointage, paie),
`restaurant_dashboard_page` 2 542 → 700 (+ service, finances, activité),
`dish_form_sheet` 1 913 → 1 360 (+ recette, pièces), `restaurant_stock_page`
1 877 → 293 (+ ingrédients, fournitures), `restaurant_menu_page` 1 759 → 770
(+ en-tête, grille), `finances_hub_page` 1 693 → 169 (+ un fichier par
onglet), `restaurant_tables_page` 1 603 → 664 (+ carte, feuilles).

**Preuve** : le build compilé est le MÊME programme que celui d'avant —
seuls l'ordre des tables, des listes d'héritage et la numérotation des
signatures changent (comparaison canonique : chaque index de signature
remplacé par la signature qu'il désigne ; contrôle négatif : un seul
caractère changé dans une chaîne est détecté).

**Restent — les classes géantes** (un `part` découpe un fichier, pas une
classe ; les réduire, c'est extraire de vrais composants, avec un risque sur
le comportement : un lot à part, AVEC des tests d'écran d'abord) :
l'état de la fiche plat (≈ 1 260 l. → 696 le 26/09/2026 : sections
d'affichage et enregistrement extraits sous un banc de 12 tests,
`test/widget/dish_form_sheet_test.dart` — FAIT), l'onglet Paie (≈ 1 030 l.
→ 402 le 26/09/2026 : sorti de la page Personnel dans
`widgets/staff_payroll_tab.dart`, feuilles et listes extraites sous un banc de
12 tests — FAIT), la fiche employé (≈ 745 → 433 : sortie de la page dans
`widgets/staff_editor_sheet.dart`, décisions et sections extraites sous un banc
de 20 tests — FAIT), la page Menu (≈ 643 → 474 : sous `AppScaffold`, donc
sans banc d'écran ; filtres et cas d'écran vide sortis en domaine pur
`domain/menu_view.dart` sous 16 tests unitaires, feuille « Stock du jour »
publique sous 8 tests, volet panier en widget — FAIT), la page Plan de salle
(≈ 590 → 416 : sous `AppScaffold` aussi ; le choix des actions d'une table
sorti en domaine pur `domain/table_actions.dart` sous 7 tests unitaires,
feuille des couverts publique sous 6 tests, menu d'actions en widget — FAIT).

**Lot « classes géantes » CLOS le 26/09/2026.** Reste de sa portée : aucun
test d'ÉCRAN pour les pages Menu et Plan de salle (voir « Pas de banc de test
pour un écran sous `AppScaffold` »).

**Restent — les grands fichiers hors restaurant**, à reprendre quand l'autre
chantier aura commité (la plupart portent ses modifications) :
`caisse_page` 7 289 l. (M), `inventaire_page` 5 208 (M), `super_admin_page`
4 972, `product_form_page` 4 538 (M), `cart_widget` 2 921,
`catalogue_page` 2 913 (M), `adaptive_scaffold` 2 727 (M), `parametres_page`
2 050 (M), `product_grid_widget` 1 942 (M), `employees_page` 1 819,
`caisse_bloc` 1 508 (M).

### Onglet Paie — la saisie perdue sur un champ oublié

*Inscrit le 26/09/2026, en préparant l'extraction de l'onglet Paie.*
« Avance sur salaire » et « Imputer une casse » vérifient le motif, le bien,
la valeur et les circonstances APRÈS la fermeture de la feuille : un champ
oublié ferme la feuille sur un message, et toute la saisie est à refaire.
La vérification devrait se faire dans la feuille, bouton grisé ou message
sous le champ. Changement de comportement : hors du lot d'extraction.

### Carte de liste du restaurant recopiée dans Notation et Primes

*Inscrit le 26/09/2026.* `RestoListCard` (`resto_surfaces.dart`) est la carte
de liste de la page Personnel, rendue publique avec la sortie de l'onglet
Paie. `staff_rating_tab.dart` et `staff_contest_tab.dart` en gardent chacun
une copie à la main ; Notation colore sa bordure selon le score — il faudrait
un paramètre de bordure avant de les rebrancher.

## Code mort

### ~~`_ServiceChip` — une pastille que plus rien ne rend~~ — SUPPRIMÉ

*Inscrit et supprimé le 26/09/2026.* `_ServiceChip`, `_channelChip` et
`_serviceStateChip` (`caisse_page.dart`, 92 lignes) ne s'affichaient plus
nulle part.

### `EmptyCartDashboard` — un réglage qui ne commandait rien

*Inscrit le 25/09/2026 avec la refonte de la page Apparence.*

`caisse/presentation/widgets/empty_cart_dashboard.dart` (mini-tableau de bord
à la place du panier vide) n'est monté par AUCUN écran, et ne l'a jamais été
depuis sa création (`25a2334`, 20/05/2026 — vérifié dans l'historique git).
Son interrupteur « Tableau de bord dans le panier vide » vivait sur la page
Thème : il écrivait un booléen (`settings_box`) que personne ne lisait. La
carte a été retirée de la page ; le widget et ses deux fonctions
(`isEmptyCartDashboardEnabled`, `setEmptyCartDashboardEnabled`) restent en
place. À trancher : le monter enfin dans le panier, ou le supprimer.
