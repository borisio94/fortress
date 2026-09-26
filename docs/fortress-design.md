# Fortress POS — Document de design

Document de référence. Toute question du type « quelle couleur pour ce
texte ? », « faut-il un bouton ici ? », « à partir de quelle largeur ? » se
tranche ici, pas dans une discussion.

Dernière révision : session du 25/09/2026, après les lots 1 (tokens de marque
en sombre, `151b69e`) et 2 (cibles tactiles, `cf0fed4`) de l'audit UI.
Emplacement de référence : `docs/` du dépôt. Une règle qui ne vit que dans un
commentaire de code se périme sans que personne ne le sache — l'audit UI du
24/09/2026 en a trouvé dix, démentis par le code qu'ils décrivaient.

**Comment lire ce document.** Chaque règle porte l'un de ces statuts :

| Statut | Sens |
|---|---|
| **TRANCHÉ** | Décidé, appliqué, et vérifiable dans le code cité. Le changer demande une décision explicite. |
| **EN VIGUEUR AU RESTAURANT** | Tranché pour le module restaurant ; l'e-commerce ne l'applique pas encore. |
| **NON TRANCHÉ** | Constaté, pas décidé. Ne pas « appliquer » un non-tranché : le faire trancher d'abord. |

---

## 1. Portée et statut

**Deux secteurs, un seul thème.** Fortress sert deux familles de boutiques :
le restaurant (`shops.sector` ∈ restaurant, fastfood, mixed —
`kRestaurantSectors`) et l'e-commerce (tout le reste). Le module restaurant a
été épuré écran par écran (24–25/09/2026) ; l'e-commerce garde en grande
partie son dessin historique.

**Ce qui est partagé, et ce qui ne l'est pas.**

| Couche | Partagée ? | Conséquence |
|---|---|---|
| Thème (`core/theme/`) : couleurs, typographie, boutons | **Oui**, sans notion de secteur | Toute modification touche les deux secteurs. Le thème n'aura PAS de branche de secteur : un drapeau global mutable dans le thème serait pire que le défaut (décision du 25/09/2026). |
| Shell (`shared/widgets/adaptive_scaffold.dart`) | Oui, **aiguillé** par `isRestaurantShop` | Le restaurant a ses trois blocs détachés ; l'e-commerce son shell jointif. |
| Widgets partagés (`shared/widgets/`, `core/widgets/`) | Oui, **sans branche** | `app_snack`, `app_scaffold`, `adaptive_form_frame`, `app_primary_button`… : les modifier modifie la production e-commerce. |
| Écrans | Séparés, sauf exceptions | Écrans partagés : Commandes (`caisse_page.dart`, 33 branches `_isResto`), Accès à l'app, Paramètres, Hub. |

**TRANCHÉ — un écran partagé ne change qu'avec une décision explicite sur
son périmètre.** Avant de toucher un écran, établir s'il est partagé ; s'il
l'est, le dire AVANT de coder. Deux réponses possibles, déjà pratiquées :

- **restaurant seulement** : la nouvelle mise en page branche sur le secteur,
  l'e-commerce garde la sienne dans le même fichier (« Accès à l'app »,
  `477bc98`) ;
- **global** : quand le défaut est le même des deux côtés (texte illisible,
  cible trop petite — lots 1 et 2).

**Comment une règle s'applique à un écran partagé.** Une règle marquée
EN VIGUEUR AU RESTAURANT ne s'étend pas d'elle-même à la partie e-commerce
d'un écran partagé.

---

## 2. Principes

Six principes, tous issus des lots d'épuration. Chacun a une raison écrite ;
sans elle, il ne tiendrait pas une semaine.

1. **La hiérarchie passe par la typographie, pas par des pastilles ni des
   voiles.** Graisse, taille et couleur de texte distinguent ce qui compte
   (`resto_underline_tabs.dart`, `caisse_page.dart` « la hiérarchie par la
   typographie, pas par un voile »).
2. **On atténue les ÉLÉMENTS, jamais un GROUPE par opacité.** Une commande
   soldée, un membre suspendu s'effacent par la couleur de leur texte ; un
   `Opacity` posé sur un groupe délave aussi ce qui doit rester lisible
   (`caisse_page.dart` « DEUX SURFACES, PAS UN VOILE »). Seule exception
   admise : la PHOTO d'un plat indisponible.
3. **Une action, un appel par écran.** Ni bouton d'en-tête, ni case en fin de
   liste en plus du bouton flottant ; et rien sur un écran vide, dont l'état
   vide porte son propre bouton (`resto_fab.dart`).
4. **Seules les alertes gardent leur couleur.** Une information s'écrit en
   `textSecondary` ; une alerte en variante `*Text` du token sémantique
   (`resto_tab_kit.dart`, `RestoInlineTag`).
5. **Une couleur qui doit tenir un contraste se DÉRIVE, elle ne se choisit
   pas.** Par une fonction pure, testée, qui s'arrête au seuil
   (`brand_contrast.dart`). C'est ce qui couvre les palettes issues d'un logo.
6. **Une valeur de token ne s'invente pas.** Pas de `fontSize` en dur, pas de
   `Color(0x…)` dans un écran. Si les tokens ne suffisent pas, on s'arrête et
   on le dit.

---

## 3. Tokens de couleur

### Les tokens de TEXTE neutres — TRANCHÉ

Getters ADAPTATIFS (`AppColors`, suivent le mode) : ils ne s'utilisent donc
pas en `const`.

| Token | Clair | Sombre | Rôle |
|---|---|---|---|
| `textPrimary` / `colorScheme.onSurface` | `#111827` | `#F1F5F9` | Texte principal |
| `textSecondary` | `#4B5563` | `#94A3B8` | Tout l'atténué lisible : métadonnées, informations, onglets inactifs |
| `textHint` | `#5B6472` | `#64748B` | **Réservé aux onglets VIDES** (voir la section 4) |

### Les tokens SÉMANTIQUES — TRANCHÉ

`theme.semantic` (`AppSemanticColors`) porte, pour chaque famille (danger,
warning, success), trois variantes au rôle distinct :

| Variante | Rôle | Exemple |
|---|---|---|
| `danger` / `warning` / `success` / `info` | Icône, trait, remplissage, texte sur **fond sombre** | point d'alerte, jauge |
| `dangerSurface` / `warningSurface` / `successSurface` | Fond teinté d'un bandeau | bandeau d'erreur |
| `dangerText` / `warningText` / `successText` | **Texte** sur surface claire ou teintée | « stock bas », « coût manquant » |

**TRANCHÉ — le token suit son fond.** `warning` en texte sur blanc ne fait que
1,95:1, `success` 2,30:1, `danger` 3,42:1 (pires cas mesurés, section 4). En
texte sur surface claire : TOUJOURS la variante `*Text`. La base (`warning`…)
reste la couleur des icônes, des traits et du texte sur voile sombre.

⚠ **Sur sa propre teinte (10–14 %), `danger` de base échoue MÊME EN SOMBRE :
4,34:1.** Ni l'audit ni le lot 1 ne l'avaient vu. Une pastille teintée écrit
donc en `*Text` dans les deux modes (`dangerText` : 6,92 en clair, 6,32 en
sombre).

**EN VIGUEUR AU RESTAURANT (26/09/2026)** — ≈ 120 textes corrigés :

- `AppSemanticColors.textFor(couleur)` rend la variante texte d'une couleur
  d'état (le reste revient tel quel) : pour une couleur qui arrive par une
  variable, un ternaire ou un paramètre, et qui peint souvent AUSSI une icône
  ou une barre — seul le texte change.
- `restoTextOn(context, couleur)` (`resto_tab_kit.dart`) pour les composants
  qui reçoivent une couleur (`RestoPill`, `RestoMiniStat`) : état → `*Text`,
  primaire → `onSurface`, `info` → `textSecondary`.
- `info` n'a PAS de variante texte, et n'en aura pas : une information se dit
  sans couleur (`textSecondary`, section 16). L'icône, la teinte et le liseré
  gardent `info`.
- **Garde-fou** : `test/theme/semantic_text_guard_test.dart` échoue si un
  `TextStyle` / `copyWith` / `styleFrom` de `lib/features/restaurant/` reçoit
  de nouveau un token d'état de base, ou la primaire hors des éléments
  interactifs marqués « lot 1 clair ». Il ne voit pas une couleur passée par
  une variable : c'est à `textFor` de la corriger à la source.

### La couleur de marque (la primaire) — TRANCHÉ

La primaire vient de la palette choisie (8 palettes du catalogue, ou une
palette **générée depuis le logo**, aux couleurs arbitraires). Elle a
**plusieurs valeurs, une par usage**, parce qu'en sombre aucune valeur unique
ne sert deux usages opposés :

- être lisible SUR la carte sombre `#1E293B` exige une luminance ≥ **0,273** ;
- porter du texte blanc exige une luminance ≤ **0,183**.

| Usage | Clair | Sombre | Source |
|---|---|---|---|
| Texte, icône, trait, indicateur | `palette.primary` | `BrandContrast.darkText(primary)` — éclaircie jusqu'à 4,5:1 sur carte, piste, fond | `AppColors.primary`, `colorScheme.primary` |
| `brand` / `brandText` (vivent sur `brandSurface`) | `palette.primary` | `BrandContrast.darkBrandText(primary)` — tenu aussi sur `brandSurface` | `theme.semantic` |
| Fond d'un bouton plein, sous du blanc | `palette.primary` | `BrandContrast.fillUnderWhite(primaryLight)` | thème des Elevated / FilledButton |
| Contenu posé SUR la primaire (sombre) | blanc | `#0F172A` (fond du thème) | `colorScheme.onPrimary` |

**⚠ Ne jamais remettre une valeur de palette dans un getter sombre.** C'est
ce qu'il y avait avant le 25/09/2026 : sur Midnight, la primaire valait la
couleur même de la carte — 1,00:1, invisible, sur quelque 590 sites.

**TRANCHÉ — la primaire n'est pas une couleur de texte fiable EN CLAIR.** Sous
4,5:1 sur blanc pour cinq palettes (Ocean 2,77, Emerald 2,54, Sunset 2,80,
Amber 3,19, Rose 3,53). Pour une information, un texte neutre — `onSurface`
pour un chiffre ou un libellé (le précédent du Stock : « le prix en
onSurface, pas la couleur de marque »), `textSecondary` pour une propriété ;
pour une alerte, une variante `*Text`. La primaire reste un ACCENT : trait
d'onglet, bouton plein, sélection.

⚠ **Sur sa propre teinte (10–14 %), la primaire échoue AUSSI EN SOMBRE** :
3,68 à 4,58, sous 4,5:1 sur **sept palettes sur huit** (en clair : 2,22 à
2,97 sur cinq). C'est plus large qu'un défaut du mode clair : une pastille
teintée de marque n'écrit jamais en primaire.

**Les éléments INTERACTIFS gardent la primaire** (un lien qui perd sa couleur
perd son signal d'action) en attendant le lot 1 clair ; chacun porte le
marqueur `lot 1 clair` dans le code et figure NOMMÉMENT au backlog.

**NON TRANCHÉ — une primaire lisible en texte EN CLAIR.** Il n'existe pas de
token « primaire lisible en texte » en mode clair (`brandText` y vaut la
primaire brute). `BrandContrast` pourrait la dériver comme en sombre ; rien
n'est décidé.

### Le décor du restaurant — EN VIGUEUR AU RESTAURANT

Surfaces translucides d'une même famille quasi noire en sombre, blanche en
clair (`resto_surfaces.dart`) :

| Fonction | Sombre | Clair | Sert |
|---|---|---|---|
| `restoGlassFill` | `#0B0F14` à 86 % | blanc à 91 % | panneaux et bloc de contenu |
| `restoChromeFill` | `#0B0F14` à 82 % | blanc à 90 % | barre latérale |
| `restoChromeOpaque` | verre composé sur le décor, ≈ `#0C1015` | `colorScheme.surface` | barre du haut, AppBar mobile |
| `restoGlassInner` | blanc à 7 % | blanc à 72 % | élément DANS un panneau |

**TRANCHÉ — les surfaces modales sont opaques** (feuilles, dialogues) : même
translucide à 90 %, une feuille laissait lire l'écran qu'elle recouvre.

**TRANCHÉ — un bouton compose une couleur opaque** (`restoOpaqueOverlay`)
plutôt qu'un fond en alpha, qui laisserait passer le décor sous le libellé.

---

## 4. Contraste

### Les seuils visés — TRANCHÉ

| Élément | Seuil | Référence |
|---|---|---|
| Texte courant (≤ 18 px, ou ≤ 14 px gras) | **4,5:1** | WCAG 2.x, 1.4.3 (AA) |
| Grand texte, icône porteuse de sens, trait d'état | 3:1 | WCAG 1.4.3 / 1.4.11 |

### Les surfaces de référence

Sombre : carte `#1E293B`, piste `#1F2937`, fond `#0F172A`, verre ≈ `#0C1015`.
Clair : carte `#FFFFFF`, fond `#F8F7FC`, piste `#F3F4F6`, verre ≈ `#FEFEFE`.
**Mesurer sur la PIRE des surfaces où le texte peut se poser**, pas sur la
plus favorable.

### Matrice des tokens neutres (pire cas, calculée)

| Token | Clair | Sombre |
|---|---|---|
| `textPrimary` | 16,12 | 13,35 |
| `textSecondary` | 6,87 | 5,71 |
| `textHint` | 5,44 | **3,07** ✘ |
| `dangerText` / `warningText` / `successText` | ≥ 6,44 | ≥ 7,73 |
| `danger` / `warning` / `success` / `info` en TEXTE | **1,95 à 3,42** ✘ | ≥ 5,29 |
| `*Text` sur leur propre teinte (10–14 %) | ≥ 6,37 | ≥ 6,32 |
| `danger` de base sur sa teinte | **3,13** ✘ | **4,34** ✘ |
| primaire sur sa teinte | 2,22–11,18 (✘ sur 5) | **3,68–4,58** (✘ sur 7) |

### La primaire, 8 palettes × 2 modes

Après le lot 1, **le texte en primaire tient 4,5:1 en sombre sur les huit
palettes** (vérifié par `test/theme/brand_contrast_test.dart`, qui teste aussi
six palettes « logo » arbitraires : très sombre, noire, très claire,
désaturée, rouge saturé, vert fluo). En clair, voir la section 3.

### Palettes issues d'un logo

Couleurs arbitraires, cachées dans Hive (`logo_palette_cache`, sans
`schema_version`). **Aucune garantie de pire cas ne les couvre, sauf celles
qui passent par `BrandContrast`.** Toute nouvelle couleur de marque qui doit
tenir un contraste passe donc par une dérivation, pas par une valeur. Midnight
est imposée d'office quand le logo est monochrome.

### La dette ouverte (backlog)

`textHint` en sombre (3,07:1) ; texte en primaire sur `primarySurface` en
sombre (3,4 à 3,96:1) ; fonds pleins peints à la main en primaire sous du
blanc (lot 1b). Voir la section 21.

---

## 5. Typographie

### L'échelle — TRANCHÉ

Police **Inter**, embarquée (rendu identique web / Android / iOS). Sept
échelons, et un huitième pour les chiffres :

| Échelon | px | Poids | Usage |
|---|---|---|---|
| `micro` | 10 | 400 | badges, horodatage, métadonnées, titres de section en capitales |
| `caption` | 11 | 500 | légendes, labels, rôle sous un nom |
| `bodySm` | 12 | 400 | texte secondaire dense, onglets |
| `body` | 13 | 400 | **corps par défaut** |
| `label` | 14 | 600 | saisie, boutons, items de liste, titres d'écran du restaurant |
| `subtitle` | 16 | 600 | sous-titres, titres de carte ou de dialogue |
| `title` | 18 | 700 | titres de page |
| `display` | 24 | 800 | gros chiffres de KPI uniquement |

Chaque échelon a ses variantes `Secondary` (couleur atténuée) et `Bold`.

**TRANCHÉ — jamais de `fontSize` en dur.** On choisit l'échelon le plus proche,
puis on ajuste la couleur par `.copyWith(color: …)`. **Il n'existe pas de 9,
de 15 ni de 19** : une maquette qui en demande un se ramène à l'échelon voisin
(les titres de section en 9 px sont en `micro`, 10 px, espacés de 0,8).

**TRANCHÉ — se caler sur l'échelon de l'écran voisin**, pas sur l'échelle
seule : la caisse plafonne à 13 ; un bouton à 16 y paraît trop gros.

**Exception** : les générateurs PDF et d'impression (`core/services/*`,
tickets 80 mm) ont leurs propres tailles, en points PDF — hors de cette
échelle.

**État** : 300 `fontSize` en dur subsistent dans l'UI, dont 33 hors échelle,
0 au restaurant (audit du 24/09/2026).

---

## 6. Espacement, rayons, élévation

### Espacement — TRANCHÉ (tokens), NON TRANCHÉ (adoption)

`AppSpacing` (`core/theme/dimens.dart`), grille de 4 : `xxs` 2 · `xs` 4 ·
`sm` 8 · `md` 12 · `lg` 16 · `xl` 20 · `xxl` 24 · `xxxl` 32. Peu adopté
(42 usages) ; la plupart des écrans écrivent encore leurs valeurs.

**TRANCHÉ — gouttière latérale de 16 px** sur les écrans de liste du
restaurant ; **marge basse de 80 px** (`kRestoFabClearance` = 48 + 16 + 16)
dès qu'un bouton flottant est affiché, sinon la dernière rangée passe dessous.

### Rayons — NON TRANCHÉ

`AppRadius` nomme `xs` 6 · `sm` 8 · `md` 12 · `lg` 16 · `xl` 20 · `pill`. Mais
le code emploie surtout 8 (480 fois) et **10 (391 fois), qui n'est pas un
token**, puis 12, 20, 6, **14** (Stock, Menu — pas un token non plus).
Constaté au restaurant : blocs du shell 20, panneaux 14 à 16, tuiles 10. À
trancher : faire entrer 10 et 14 dans l'échelle, ou ramener le code à
l'échelle existante.

### Élévation — EN VIGUEUR AU RESTAURANT

Pas d'ombre sur les panneaux : la séparation se fait par la surface et le
filet `borderSubtle`. Ombre neutre (jamais teintée de la primaire) sur le
bouton flottant. L'e-commerce emploie encore des ombres (34 décorations avec
`boxShadow`).

---

## 7. Surfaces

### Carte, panneau, modale, décor

| Surface | Quand | Widget |
|---|---|---|
| **Panneau translucide** | contenu du restaurant sur le décor | `RestoGlassPanel`, `restoGlassFill` |
| **Carte opaque** | e-commerce, contenu hors décor | `colorScheme.surface` + `borderSubtle` |
| **Modale** | feuille, dialogue | opaque, fond du thème (`showFormSheet`) |
| **Décor** | fond de tout écran du restaurant | `RestoBackdrop`, géométrique |

### Le décor et le texte — TRANCHÉ

**Le texte peut vivre sur le décor géométrique, JAMAIS sur une photo.** Le
décor est calculable : texte primaire ≥ 12,2:1, secondaire ≥ 5,2:1 dessus
(`resto_surfaces.dart`, exception du 24/09/2026). Une photo ne l'est pas : sa
zone claire ou sombre passe au hasard sous le texte. Sur une photo de plat,
seules des pastilles sur voile opaque à 85 % sont admises ; le nom et le prix
vivent sous la photo. **Si le motif du décor dépasse ~15 % d'opacité, l'exception
tombe : REMESURER, pas supposer.**

### Les listes — EN VIGUEUR AU RESTAURANT

Les lignes d'une liste vivent dans **UN panneau par section**, séparées par
un filet `Divider(height: 1, thickness: 1, color: borderSubtle)` — pas une
carte par ligne (Stock `_StockLines`, Accès à l'app `_RestoLines`).
**NON TRANCHÉ** : aucun widget partagé ne porte ce motif ; il est refait à la
main, avec des filets de 0,5 à 1 px et des retraits de 0 à 56 selon l'écran.

---

## 8. Disposition et points de rupture

### Les seuils officiels — TRANCHÉ

| Seuil | Constante | Décide |
|---|---|---|
| **900** | `_kDesktopWidthBreakpoint` (`adaptive_scaffold.dart`) | Shell : ordinateur (barre latérale + barre du haut) ou mobile (AppBar + barre du bas + tiroir) |
| **720** | `kCartPaneFullWidthBelow` (`cart_pane_provider.dart`) | Volet panier en plein écran, disposition « téléphone » des écrans du restaurant |
| **600** | `kFormMobileBreakpoint` (`adaptive_form_frame.dart`) | Feuille en page pleine ou en dialogue |

**Ce sont les seuls qu'un nouvel écran doit employer.** L'application en
compte douze autres, écrits en dur (340, 500, 560, 640, 700, 760, 800, 860,
1100…) : dette, pas modèle. Le commentaire qui affirmait « l'app en a deux »
était faux.

**NON TRANCHÉ — les zones hybrides.** Entre 720 et 900 px, le volet panier
est latéral alors que le shell est celui du mobile ; entre 800 et 900, la
caisse e-commerce met son panier en ligne sous une barre du bas. Personne n'a
décidé si c'est voulu.

### Le conteneur, pas l'écran — TRANCHÉ

**Une décision de disposition qui dimensionne un CONTENU lit la largeur de
son conteneur (`LayoutBuilder`), pas celle de l'écran.** Sur ordinateur, la
largeur utile est l'écran moins la barre latérale (247 px) : lire l'écran a
fait prendre la branche « large » à une tuile de 342 px, et déborder de 70 px
(`caisse_page.dart`, commit `2d57517`). Seules les décisions qui portent sur
l'écran ENTIER (volet panier, shell) lisent l'écran.

---

## 9. Shell

### Restaurant : trois blocs détachés — EN VIGUEUR AU RESTAURANT

Sur ordinateur, barre latérale, barre du haut et contenu sont trois panneaux
à coins arrondis (rayon 20), séparés par 10 px de vide qui laissent voir le
décor. L'e-commerce garde son shell jointif historique : le détacher
changerait toutes ses pages.

- **Barre du haut** : opaque (`restoChromeOpaque` — de la même famille que le
  contenu ; `colorScheme.surface` valait en sombre le slate des cartes, un bloc
  bleuté au-dessus d'un contenu quasi noir, corrigé le 25/09/2026). Sur une
  page racine, RIEN à gauche ; sur une sous-page, le retour et le NOM de la
  page. À droite : la cloche (point ambre, pas de compteur rouge) et le menu
  du compte « Admin · <boutique> » — sur mobile aussi, avatar seul pour
  déclencheur.
- **Barre latérale** : `restoChromeFill`, translucide.

### Le titre de page — EN VIGUEUR AU RESTAURANT (lot Shell, 25/09/2026)

**Le titre d'une PAGE RACINE vit dans le corps ; celui d'une SOUS-PAGE dans
la barre**, sur ordinateur comme sur mobile.

- Page racine : `RestoSectionHeader` (titre + sous-titre qui cadre l'écran —
  décompte, effectif, rien si rien ne cadre la page entière, comme Finances
  dont la période vit dans un onglet). La barre du haut ET l'AppBar mobile se
  taisent.
- Sous-page : le retour et le nom, dans la barre. Le nom vient de
  `page_titles.dart` ; toute sous-page y a son `case`, avec le titre que la
  page se donne elle-même — sans lui, le repli dérive l'URL (« Cloture »,
  « Reconcile », « Setup »).
- Le corps et la barre nomment la page du même mot que le MENU
  (« Accès à l'app », pas « Membres »).

L'e-commerce n'applique pas encore ce modèle (backlog : 3 sous-pages en
« FORTRESS » seul, 2 titres dérivés fautifs, 17 sous-pages nommées par leur
section).

### La cloche — TRANCHÉ (25/09/2026)

**Pour tout membre, partout** : le service de notifications est activé pour
tout membre, et les notifications de tickets vont à leur destinataire,
employés compris. Une cloche presque vide pour un serveur n'est pas un
problème ; une notification qui n'arrive jamais à son destinataire en est un.
C'était `isShopAdmin` sur ordinateur et `isMember` sur mobile depuis mai, sous
un commentaire qui disait « réservée admin + owner ».

### Ce qui vit hors du shell — TRANCHÉ (25/09/2026)

**Seule la BADGEUSE vit hors du shell** : posée en libre-service sur le
compte connecté du gérant, elle ne donne accès à aucune autre page. Route de
premier niveau, fond uni, et une seule sortie — la croix, sous PIN gérant
(`ManagerGate`, action `exitTimeclock` : le PIN s'il existe, sinon le passage
libre et journalisé). Une route qui sort du shell **garde les deux gardes
d'accès** (boutique suspendue, membre suspendu) : `ShopAccessGuard`, partagé
avec `ShopShell`.

**L'ADDITION reste dans le shell** : c'est un écran de service, elle a besoin
de la navigation et des gardes. Elle ne remonte plus de second décor.

Limite : sur le web, la barre d'adresse et le bouton Précédent du navigateur
restent disponibles — on retire la navigation de l'app, pas celle du
navigateur.

### Divergences mobile / ordinateur

Menu du compte, cloche, titre : alignés par le lot Shell (25/09/2026). Le
tiroir filtre désormais ses sous-items par secteur, comme la barre latérale.
Reste : l'édition d'une commande qui n'ouvre pas le même écran selon la
largeur (section 19).

---

## 10. Catalogue des composants canoniques

Pour chacun des dix mécanismes recensés par l'audit : le widget de
RÉFÉRENCE, et ce qu'il remplace. Une copie locale d'un mécanisme qui a une
référence est une divergence en attente.

| Mécanisme | Référence restaurant | Référence e-commerce / partagée | À ne plus écrire |
|---|---|---|---|
| Carte / panneau | `RestoGlassPanel` | `colorScheme.surface` + `borderSubtle` | `_XxxCard` locales (99), `BoxDecoration` faits main |
| État vide | `RestoEmptyState` | `EmptyStateWidget` | `_EmptyState` locaux (≈ 21) |
| Étiquette d'état | `RestoInlineTag.info` / `.alert` | **NON TRANCHÉ** | pastilles locales (≈ 30) ; « stock bas » a cinq rendus |
| Onglets | `RestoUnderlineTabs` ; `RestoUnderlineTabBar` avec une `TabBarView` | **NON TRANCHÉ** (`TabBar`, pastilles…) | `_TabPill`, `_PillTab`, `TabBar` au restaurant |
| Bouton flottant | `RestoFab` | `DraggableFabContainer` | `FloatingActionButton` brut |
| Feuille à saisie | `showAdaptiveFormSheet` + `AdaptiveFormFrame` | idem | `AlertDialog` avec un champ |
| Confirmation | `AppConfirmDialog` ; `DangerConfirmDialog` si irréversible | idem | `AlertDialog` nu |
| Montant | `CurrencyFormatter` ; `RestoAmountText` pour l'appui visuel | `CurrencyFormatter` | `NumberFormat` direct, « XAF » en dur, `_compact` locaux |
| Période | `RestoPeriodButton` | `PeriodSelector` (un seul usage) | `_PeriodPicker`, `_CompactPeriodSelector` |
| Liste à filets | **NON TRANCHÉ** (`_StockLines`, local) | — | — |
| Avatar | **NON TRANCHÉ** | `ShopLogoAvatar` + `shopMonogram()` (testé) | sept fonctions d'initiales |
| Cible tactile faite main | `TouchTarget` (`core/widgets/touch_target.dart`) | idem | `GestureDetector` sur une boîte < 48 px |

---

## 11. États

### Vide — TRANCHÉ

**Un état vide est une CARTE, pas un texte flottant.** La zone existe, elle
est simplement vide ; un texte seul au milieu du vide se lit comme un écran
qui n'a pas fini de charger (`resto_empty_state.dart`). L'état vide porte son
propre bouton de création — c'est pourquoi le bouton flottant disparaît sur
un écran vide.

Exception écrite, à ne pas étendre : l'onglet Fournitures du Stock
(`_SuppliesEmptyState`). **NON TRANCHÉ** : les « Aucun… » en texte nu DANS une
sous-section ou une feuille (≈ 12 cas) — la règle vaut-elle à cette échelle ?

### Chargement, erreur, hors ligne

Indicateur de progression à la couleur de la primaire ; message d'erreur en
`danger` centré ; puce « hors ligne » et resynchronisation automatique à la
reconnexion (sonde de joignabilité réelle sur le web). **NON TRANCHÉ** : aucune
forme commune n'est imposée pour l'erreur.

### Soldé, désactivé, suspendu, archivé — TRANCHÉ

S'effacent **par la couleur du texte** (`textSecondary`), jamais par une
opacité de groupe. Une commande soldée passe « à plat ». Un membre suspendu
ou archivé n'affiche plus de jauge de droits — il n'en exerce aucun — mais
son état (« accès suspendu », « archivé »).

---

## 12. Actions

### Le bouton flottant — EN VIGUEUR AU RESTAURANT

`RestoFab` : 48 px, rond, marge 16. **Un seul appel de création par écran**
(Menu, Stock selon l'onglet, Plan de salle, Commandes dans les deux vues).
Masqué : sur un écran vide ; sans le droit de créer ; sur une liste où l'on
n'ajoute rien (plats retirés) ; panier ouvert sur mobile (il recouvrait
« Commander »).

Couleur : `primaryDark` en clair (le blanc sur `primary` descend sous 3:1 sur
trois palettes), `colorScheme.primary` en sombre ; ombre neutre.

### Le bouton plein, le bouton texte

Thème global : dimensionnés au CONTENU (padding 10 / 3) ; zone de 48 px au
doigt (section 17). **Piège connu** : dans une `Row`, un bouton dont le style
impose une largeur infinie écrase son `Expanded` — forcer
`minimumSize: Size(0, h)`.

### Le menu ⋮

Discret mais toujours visible (enfoui derrière un appui long, il serait
introuvable sur le web). Jamais vide. Jamais pour le propriétaire dans
« Accès à l'app ».

### Les actions dangereuses — TRANCHÉ

Trois portes de sortie d'argent sous PIN gérant au restaurant.
`DangerConfirmDialog` (saisie du nom de la cible) pour l'irréversible ;
`OwnerPinDialog.guard` pour ce qui engage le propriétaire.

---

## 13. Feuilles et dialogues

**TRANCHÉ — toute boîte avec un champ de saisie passe par
`showAdaptiveFormSheet` + `AdaptiveFormFrame`**, jamais par un `AlertDialog` :
le clavier y est géré, la feuille devient une page pleine sous 600 px. Une
seule violation au restaurant (`dish_form_sheet.dart`).

| Cas | Châssis |
|---|---|
| Saisie | `showAdaptiveFormSheet` + `AdaptiveFormFrame` |
| Confirmation simple | `AppConfirmDialog` (piège : il fait `pop` AVANT `onConfirm`) |
| Irréversible | `DangerConfirmDialog` |
| Choix dans une liste | feuille adaptative |

**NON TRANCHÉ** : `showFormSheet` (enveloppe verrouillée) et 56
`showModalBottomSheet` bruts coexistent avec le canonique ; 47 `AlertDialog`
subsistent, surtout côté super-admin et e-commerce.

---

## 14. Montants, nombres, dates et périodes

### Montants — TRANCHÉ

**Tout montant affiché passe par `CurrencyFormatter`** (devise de la boutique,
séparateur de milliers). `RestoAmountText` / `splitAmount` le découpent pour
mettre le nombre en valeur, sans le reformater. **Jamais** de
`toStringAsFixed(0)` suivi de « XAF » ou « FCFA » en dur — la page publique
de suivi le fait encore.

**NON TRANCHÉ — le compact.** `CurrencyFormatter.compact` rend 1 500 en
« 1.5k » ; six copies locales rendent « 2k ». Choisir, puis supprimer les
copies.

### Dates

`DateFormatter` (`dayMonthYear`…). « Depuis le … » pour une ancienneté.

### Périodes — EN VIGUEUR AU RESTAURANT

Un seul sélecteur au restaurant, `RestoPeriodButton` (tableau de bord,
hub Finances), sur l'état partagé `dashPeriodProvider`. **NON TRANCHÉ** : cinq
implémentations coexistent dans l'app, avec des listes de périodes
différentes (le trimestre existe au Hub, pas au restaurant).

---

## 15. Onglets, filtres et recherche

### Onglets — EN VIGUEUR AU RESTAURANT

`RestoUnderlineTabs` : ni fond ni contour ; le libellé, son compteur atténué,
un trait de 1,5 px sous l'onglet actif. **L'actif se lit AUSSI sans le trait**,
par sa graisse et sa couleur : sur une palette où la primaire est faible, le
trait seul ne suffirait pas. Un onglet vide s'efface en `textHint`, sauf
« Tous », qui n'est pas un filtre. Pictogramme facultatif quand le mot seul ne
suffit pas à distinguer (Stock : feuille et carton — la couleur seule ne tient
pas, ΔE 17,7 sur la palette Amber).

Finances et Personnel, qui balaient leurs onglets (`TabBarView`), passent
par `RestoUnderlineTabBar` : les mêmes onglets soulignés, reliés au
`TabController` (25/09/2026). Libellés seuls — leurs données se chargent dans
chaque onglet. Les `SegmentedButton` et `ChoiceChip` de ces écrans ne sont
PAS des onglets mais des champs de formulaire : ils restent.

### Recherche

Au restaurant, repliée en icône au bout de la ligne d'onglets ; la refermer
vide la requête (une requête invisible ferait paraître la liste incomplète).

---

## 16. Badges et étiquettes d'état

**TRANCHÉ — information contre alerte** (`RestoInlineTag`) :

| Nature | Couleur | Exemples |
|---|---|---|
| **Information** — une propriété | `textSecondary`, en texte, sans fond | « partagé », « actif », « archivé » |
| **Alerte** — quelque chose appelle une action | variante `*Text` du token | « stock bas » (`dangerText`), « coût manquant », « suspendu » (`warningText`) |

Les deux constructeurs (`.info`, `.alert`) rendent la règle impossible à
contourner : une information ne PEUT pas recevoir de couleur. Une pastille
teintée répétée sur une liste devient un mur de couleur, et la couleur ne
distingue plus rien.

Le point de notification est un **point ambre**, pas un compteur rouge.

### Liseré d'état — TRANCHÉ (26/09/2026)

**Contour non, liseré oui, sous deux conditions**
(`restaurant/presentation/widgets/state_stripe.dart`) :

- Un **contour** entoure une carte et la sépare du fond : **interdit**. Le
  fond, l'espace et la typographie font ce travail.
- Un **liseré** — un trait sur le seul bord gauche — ne sépare rien : il
  porte l'état. **Permis** quand (1) l'état est l'information principale de
  la carte, ET (2) un libellé écrit l'état à côté.

**Une seule épaisseur : 4 px** (`kStateStripeWidth`). Le Plan de salle
l'avait, la liste des commandes était à 3, la grille n'en avait pas — deux
épaisseurs pour la même grammaire, apparues sans décision.

**Une carte terminée recule, son liseré aussi** (`stripeColor`) :
`outlineVariant`, 1,59–1,60:1 sur son fond en clair, 1,90–1,92 en sombre —
visible, et sous le plus faible des liserés actifs (2,15 en clair, 4,50 en
sombre). Il portait `onSurfaceVariant` (8,78:1) : le trait le plus marqué de
l'écran, sur les cartes qui doivent s'effacer.

⚠ **Sous 3:1 en clair**, contre la carte : « En préparation » 2,15 et « À
servir » 2,54 sur toutes les palettes ; « À encaisser » 2,54 à 2,80 sur
emerald, ocean et sunset. Le liseré n'est admissible que par le badge qui
écrit l'état — **ne jamais retirer le badge pour alléger**.

EN VIGUEUR AU RESTAURANT : cartes de commande (liste et grille), cartes de
table du Plan de salle. Hors règle, au backlog : le liseré de NATURE des
tuiles du tableau de bord (3 px), les liserés de l'e-commerce.

---

## 17. Accessibilité

### Cibles tactiles — TRANCHÉ

**48 px au doigt, la densité d'origine à la souris**
(`core/widgets/touch_target.dart`, lot 2) :

- `isTouchPlatform` : Android ou iOS (sur le web, lu dans l'agent du
  navigateur). **Limite connue, non contournée** : un iPad sous Safari
  s'annonce comme un Mac et reste en densité de bureau.
- Thème : `tapTargetSize` adaptatif sur les quatre boutons.
- Cible faite main : `TouchTarget` ; `IconButton` compact : `compactUnlessTouch`.
- **Une cible ne peut pas dépasser sa boîte** : pour 48 px, la boîte fait
  48 px, et la rangée grandit. C'est le prix, accepté.
- **Deux pièges** : un parent à hauteur FIXE qui laisse sa colonne libre
  (tuile de table de 82 px) → la rangée agrandie DÉBORDE : superposer la zone
  au lieu d'envelopper. Un parent à hauteur fixe qui contraint (puce de 38 px)
  → la cible plafonne, sans erreur.

WCAG n'exige que 24 px en AA ; 48 est la mesure de Material, retenue pour les
gestes répétés du service.

### La couleur jamais seule — TRANCHÉ

Un état qui ne parle que par la couleur doit être doublé par un libellé ou
une icône (plan de salle : liseré + libellé + légende ; commandes : liseré +
badge écrit, section 16 ; stock : icône avant couleur). Cas ouverts : alerte
prix du panier, statut d'un ticket de messagerie, liseré « sans prix » de
l'inventaire.

### Taille du texte

Réglage « Taille du texte » dans les Paramètres (`text_scale`, local à
l'appareil). **NON TRANCHÉ** : aucun écran n'est vérifié à grande taille.

### Lecteur d'écran

**NON TRANCHÉ** : pas de règle ; les `tooltip` des `IconButton` en tiennent
lieu.

---

## 18. Iconographie

- **Famille** : Material Icons, variantes `_rounded` et `_outlined`
  majoritaires. **NON TRANCHÉ** : aucune règle ne dit laquelle employer quand.
- **TRANCHÉ — build avec `--no-tree-shake-icons`** : l'élagage des icônes
  produisait des carrés vides, différents entre web et mobile.
- **TRANCHÉ — éviter la famille `handshake`** (plan Unicode supplémentaire,
  mal rendue) : `local_shipping` pour les partenaires de livraison.
- **Un écran qui change de pictogramme entre son état vide et ses onglets
  fait douter qu'il parle de la même chose** (Stock).
- Tailles constatées : 14 à 22 px selon la densité. **NON TRANCHÉ** : pas
  d'échelle.

---

## 19. Mobile contre ordinateur

**Ce qui a le droit de différer — TRANCHÉ :** la navigation (barre latérale
contre barre du bas et tiroir), la densité (cibles de 48 px au doigt), les
colonnes d'une grille, le volet panier en plein écran sous 720 px, une ligne
qui passe de une à trois rangées (Accès à l'app).

**Ce qui n'a PAS le droit de différer :** une permission (qui voit quoi), un
libellé, une action disponible, un widget épuré d'un côté et resté tel quel
de l'autre.

**Comment documenter une différence voulue** : un commentaire à la branche,
qui dit POURQUOI. Une branche sans commentaire est présumée être un oubli.

**Oublis connus (audit du 24/09/2026)** : titre absent sur ordinateur, titre
répété sur mobile, menu du compte non épuré sur mobile, cloche réservée à des
publics différents — **corrigés par le lot Shell (25/09/2026)**. Reste :
l'édition d'une commande dans deux écrans selon la largeur. Voir la
section 21.

---

## 20. Règles écrites dans le code — registre

Les règles de design naissent dans les commentaires, pendant un lot. Ce
registre dit où elles vivent. **Quand une règle change, on change son
commentaire ET ce registre**, sinon l'un des deux ment.

| Règle | Écrite dans | Section |
|---|---|---|
| Deux valeurs de primaire, dérivées ; ne pas y remettre la palette | `core/theme/brand_contrast.dart`, `app_colors.dart` | 3 |
| Cibles de 48 px au doigt, pièges de hauteur fixe | `core/widgets/touch_target.dart` | 17 |
| Échelle typographique, jamais de `fontSize` en dur | `core/theme/app_text_styles.dart` | 5 |
| Le texte vit sur le décor, jamais sur une photo | `resto_surfaces.dart` | 7 |
| Surfaces modales opaques ; boutons en couleur composée | `resto_surfaces.dart` | 3 |
| Barre du haut de la famille du contenu | `resto_surfaces.dart` (`restoChromeOpaque`) | 9 |
| Un état vide est une carte | `resto_empty_state.dart` | 11 |
| Seules les alertes gardent leur couleur | `resto_tab_kit.dart` (`RestoInlineTag`) | 16 |
| Le token suit son fond | `restaurant_menu_page.dart`, `service_tab_visuals.dart` | 3 |
| Un seul appel de création par écran | `resto_fab.dart` | 12 |
| Pas d'opacité de groupe | `caisse_page.dart`, `service_tabs.dart` | 2 |
| La disposition lit le conteneur | `caisse_page.dart` | 8 |
| L'actif d'un onglet se lit sans le trait | `resto_underline_tabs.dart` | 15 |
| L'icône d'abord, la couleur ensuite | `restaurant_stock_page.dart` | 15 |
| L'aperçu d'une palette se LIT dans le thème réel, jamais dans une table | `theme_page.dart` (`themeSwatches`) | 3 |
| Segmenté : l'actif plus CLAIR que la piste en clair, plus FONCÉ en sombre | `theme_page.dart` (`_ModeSegmented`) | 15 |
| Un chronomètre mesure l'attente DANS L'ÉTAT (`service_state_at`), jamais l'âge ; sans date, rien | `restaurant/domain/service_wait.dart` | 14 |
| Le bouton d'action d'une carte est petit et en fond teinté ; le montant reste l'élément le plus lourd | `caisse_page.dart` (`_StateButton`) | 12 |

**Pour créer une règle** : l'écrire au plus près du code qu'elle gouverne,
AVEC sa raison mesurée (un contraste, un débordement, un cas), puis
l'inscrire ici. **Pour lever une règle** : écrire pourquoi, dater, et garder
la trace de l'ancienne raison — c'est ainsi que l'exception « texte sur le
décor » a pu être accordée sans rouvrir la question de la photo.

---

## 21. Dette connue et exceptions accordées

Le détail vit dans `docs/backlog.md` ; ici, l'index.

**Exceptions accordées (datées) :**

| Exception | Date | Tient tant que |
|---|---|---|
| Texte sur le décor géométrique | 24/09/2026 | le motif reste sous ~15 % d'opacité |
| État vide de l'onglet Fournitures | 24/09/2026 | ne pas l'étendre |
| iPad sous Safari en densité de bureau | 25/09/2026 | — |
| Cible de la croix de date plafonnée à 38 px de haut | 25/09/2026 | la barre d'outils garde 38 px |

**Dette ouverte :**

- Palette : `textHint` en sombre (3,07:1) ; texte sur `primarySurface` en
  sombre (3,4–3,96:1) ; lot 1b (≈ 153 fonds pleins en primaire sous du blanc,
  ≈ 3,2:1 sur Violet, Rose, Midnight, Indigo).
- Cibles tactiles : ≈ 154 sites hors lot, comptés par feature.
- Code mort : `KitchenTicketCard` (écran Préparation supprimé),
  `ExpenseFormSheet`, `PartnerLedgerDetailPage`, `DottedBorderBox`.
- Shell : titres de page de l'e-commerce (backlog) ; édition d'une commande
  selon la largeur (section 19).
- Doublons de mécanisme (section 10) : onglets, périodes, étiquettes d'état,
  montants compacts, avatars.
- Liserés hors de la règle de la section 16 : tuiles du tableau de bord
  restaurant (3 px, liseré de nature), liserés de l'e-commerce.

---

## 22. Procédure de vérification d'un lot

Un lot d'UI suit ces étapes, dans cet ordre.

1. **Inspecter avant de coder.** Établir si l'écran est PARTAGÉ avec
   l'e-commerce, et le dire avant toute ligne de code. Relever les
   modifications non commitées d'autres chantiers dans les fichiers visés.
2. **Plan, puis validation.** Le plan cite les règles de ce document qu'il
   applique, et signale ce que les tokens ne permettent pas (s'arrêter plutôt
   qu'inventer une valeur).
3. **Mesurer, pas supposer.**
   - Contraste : sur la PIRE surface, sur les **huit palettes × deux modes**,
     et Midnight en sombre en particulier (elle est sortie trois fois par le
     bas). Toute nouvelle couleur de marque passe par `BrandContrast`.
   - Cibles : au doigt, et vérifier la hauteur fixe des parents.
   - Débordement : aux trois seuils officiels (600, 720, 900).
4. **Pas de changement de logique dans un lot visuel.** Une action, une garde,
   un menu déplacé est comparé ligne à ligne avec l'original.
5. **Tests** : `flutter analyze` sans nouvelle alerte, suite complète verte,
   un test pour chaque règle nouvelle (le seuil calculé, pas recopié).
6. **Prévisualisation avant commit** : `firebase hosting:channel:deploy`
   depuis un worktree PROPRE (HEAD + les seuls fichiers du lot ; les blocs
   d'un autre chantier réappliqués à part). À regarder : l'écran visé, en
   clair ET en sombre, sur téléphone ET sur ordinateur, et au moins un écran
   de l'autre secteur si le lot touche du partagé.
7. **Commit après le regard de l'utilisateur**, avec seulement les fichiers
   du lot. Le compromis accepté s'inscrit au backlog LE JOUR MÊME, avec son
   compte et son périmètre ; une entrée du backlog ne se ferme qu'avec le
   titre du commit qui la referme.
8. **Déploiement** depuis un worktree propre de la HEAD, empreinte vérifiée
   en ligne ; puis push.
9. **Mettre à jour ce document** si le lot a produit ou levé une règle.
