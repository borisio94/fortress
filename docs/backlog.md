# Fortress POS — Backlog

Ce qui est constaté, accepté pour l'instant, et doit revenir. Chaque entrée
dit OÙ elle a été vue, ce qu'elle coûte, et pourquoi elle n'a pas été
corrigée sur place. Une entrée n'en sort qu'avec le titre du commit qui la
referme.

---

## Dette de palette

Des tokens dont la valeur ne tient pas le contraste là où ils servent. Ce ne
sont pas des défauts d'un écran : c'est la PALETTE qui est en cause, et un
écran ne peut que les contourner. Les contournements sont nommés ci-dessous
pour qu'on sache quoi défaire le jour où le token sera corrigé.

### `AppColors.textHint` en sombre — sous le seuil AA du petit texte

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

### Lot 1b — fonds pleins peints à la main en primaire, sous du texte blanc

> **Mise à jour du 26/09/2026 (lot 1 clair)** : EN CLAIR, la dette est
> soldée — la primaire claire dérivée porte le blanc à ≥ 5,84:1 sur les huit
> palettes. Ce qui suit ne vaut plus que pour le mode SOMBRE.

*Compromis ACCEPTÉ le 25/09/2026 avec le lot 1 (tokens de marque en sombre).
Inscrit le jour même pour ne pas devenir une dette oubliée.*

Le lot 1 fait de `AppColors.primary` et `colorScheme.primary`, en sombre, une
variante « texte » DÉRIVÉE (cf. `core/theme/brand_contrast.dart`) : lisible à
4,5:1 comme texte, icône ou trait sur la carte sombre. Une même couleur ne peut
pas être aussi un fond sous du texte blanc — les deux conditions sont
incompatibles (luminance ≥ 0,273 pour la première, ≤ 0,183 pour la seconde).

Les boutons du THÈME (Elevated, Filled) ont reçu leur propre fond dérivé. Mais
les fonds peints À LA MAIN en primaire (`backgroundColor: AppColors.primary`,
`BoxDecoration(color: AppColors.primary)`, `Material(color: cs.primary)`…) avec
un contenu blanc ne sont pas couverts :

- **≈ 153 sites dans 79 fichiers** (heuristique, HEAD `19d0048`) : 128 en
  `AppColors.primary` — tous hors du module restaurant —, 25 en
  `colorScheme.primary` dont 3 au restaurant. Les plus chargés :
  `super_admin_page` 12, `catalogue_page` 10, `cart_widget` 8,
  `shop_settings_page` 6, `inventaire_page` 5, `product_form_page` 5.
- **Régression, en sombre seulement, sur quatre palettes : Violet, Rose,
  Midnight, Indigo.** Le blanc sur ces fonds passe d'environ 6:1 à environ
  3,2:1 — lisible, mais sous l'AA du petit texte. C'est le prix accepté pour
  sortir environ 590 textes, icônes et traits de 1,00:1 (Midnight) ou 2,2:1
  (Violet, Indigo).
- **Déjà en échec AVANT le lot 1, inchangé** : Ocean, Emerald, Sunset, Amber —
  le blanc sur leur primaire ne fait que 2,5 à 3,2:1, en clair comme en sombre.

À faire : repointer ces sites vers un token de FOND dérivé (la fonction
`BrandContrast.fillUnderWhite` existe déjà), un par un, en vérifiant ce qui est
posé dessus. Ne PAS « corriger » en remettant une valeur de palette dans
`AppColors.primary` : c'est elle qui rendait le texte invisible.

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

Code mort signalé en passant : `KitchenTicketCard`
(`restaurant/presentation/widgets/kitchen_ticket_card.dart`, ≈ 230 lignes)
n'a plus aucun appelant depuis la suppression de l'écran Préparation
(`66c6c2f`, 07/08/2026). L'audit UI du 24/09 l'avait compté comme geste
fréquent (§4b) et comme couleur seule (§4c-1) : ces deux constats portent sur
du code mort.

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

## Code mort

### `_ServiceChip` — une pastille que plus rien ne rend

*Inscrit le 26/09/2026.* `_ServiceChip`, `_channelChip` et `_serviceStateChip`
(`caisse_page.dart`) ne s'affichent plus nulle part : les deux fonctions
rendent `[]` hors du restaurant, et au restaurant la carte est toujours en
grille ou en liste dense, jamais dans la branche qui les appelle. Elles
portaient encore des tokens de base en texte ; laissées en l'état.

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
