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
| `textHint` | `#5B6472` | `#8190A6` (dérivée) | **Réservé aux onglets VIDES** (voir la section 4) |

**`textHint` en sombre est DÉRIVÉE** (26/09/2026) : `lerp(#64748B,
textSecondary #94A3B8, 0,60)` — le premier pas qui tient 4,5:1 sur la pire
surface sombre (la carte, 4,51). L'ancien slate-500 n'y faisait que 3,07.
Même valeur pour `AppTheme._dTextHint` (indices des champs, `labelSmall`).
Garantie sur le fond, la carte, la surface creusée et le verre du restaurant ;
**PAS sur la teinte de marque** (`brandSurface`, 3,10 à 3,96) — aucun gris
neutre n'y tient, `textSecondary` compris (4,07 à 4,40 sur quatre palettes) :
sur elle, le texte s'écrit en `brandText`. Vérifié par
`test/theme/text_hint_contrast_test.dart`.

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
  de nouveau un token d'état de base, ou la primaire (un texte de marque
  s'écrit en `brandText`). Il ne voit pas une couleur passée par
  une variable : c'est à `textFor` de la corriger à la source.

### La couleur de marque (la primaire) — TRANCHÉ

La primaire vient de la palette choisie (8 palettes du catalogue, ou une
palette **générée depuis le logo**, aux couleurs arbitraires). Elle a
**plusieurs valeurs, une par usage**, parce qu'en sombre aucune valeur unique
ne sert deux usages opposés :

- être lisible SUR la carte sombre `#1E293B` exige une luminance ≥ **0,273** ;
- porter du texte blanc exige une luminance ≤ **0,183**.

**En clair, les deux usages CONVERGENT** (lot 1 clair, 26/09/2026) : être
lisible sur le blanc et porter du blanc exigent tous deux une primaire assez
foncée. Une seule valeur dérivée, `BrandContrast.lightText`, sert donc le
texte, l'icône, le trait ET le fond des boutons — assombrie jusqu'à 4,5:1 sur
la carte, le fond, le verre, les teintes de la couleur brute ET **ses propres
teintes** (l'app teinte avec la valeur dérivée : calculée sans elles, Ocean
tombait à 4,37:1 sur la sélection du menu latéral).

| Palette | Avant | Après | Blanc dessus |
|---|---|---|---|
| Ocean | `#0EA5E9` | `#096B98` | 2,77 → 5,86 |
| Emerald | `#10B981` | `#0A7350` | 2,54 → 5,86 |
| Sunset | `#F97316` | `#A34B0E` | 2,80 → 5,86 |
| Rose | `#EC4899` | `#AE3571` | 3,53 → 5,91 |
| Amber | `#D97706` | `#985404` | 3,19 → 5,84 |

Violet, Midnight et Indigo ne bougent pas. Les palettes issues d'un logo
suivent la même règle. La graine du schéma et `brandSurface` partent de la
couleur BRUTE : les teintes gardent leur aspect.

| Usage | Clair | Sombre | Source |
|---|---|---|---|
| Texte, icône, trait, indicateur | `BrandContrast.lightText(primary)` | `BrandContrast.darkText(primary)` — éclaircie jusqu'à 4,5:1 sur carte, piste, fond | `AppColors.primary`, `colorScheme.primary` |
| `brand` / `brandText` (vivent sur `brandSurface`) | `BrandContrast.lightText(primary)` | `BrandContrast.darkBrandText(primary)` — tenu aussi sur `brandSurface` | `theme.semantic` |
| Fond d'un bouton plein, sous du blanc | `BrandContrast.lightText(primary)` (la même) | `BrandContrast.fillUnderWhite(primaryLight)` | thème des Elevated / FilledButton ; **`AppColors.primaryFill`** pour un fond peint à la main (lot 1b) |
| Contenu posé SUR la primaire (sombre) | blanc | `#0F172A` (fond du thème) | `colorScheme.onPrimary` |

**⚠ Ne jamais remettre une valeur de palette dans un getter sombre.** C'est
ce qu'il y avait avant le 25/09/2026 : sur Midnight, la primaire valait la
couleur même de la carte — 1,00:1, invisible, sur quelque 590 sites.

**TRANCHÉ — le rôle décide de la couleur d'un texte.** Une INFORMATION
s'écrit en neutre — `onSurface` pour un chiffre ou un libellé (le précédent du
Stock : « le prix en onSurface, pas la couleur de marque »), `textSecondary`
pour une propriété ; une ALERTE en variante `*Text`. Un texte de MARQUE (lien,
bouton, sélection) s'écrit en `semantic.brandText` — la seule valeur tenue sur
ses propres teintes dans les DEUX modes. Avant le lot 1 clair, la primaire
échouait en clair sur cinq palettes (Ocean 2,77, Emerald 2,54, Sunset 2,80,
Amber 3,19, Rose 3,53).

⚠ **Sur sa propre teinte (10–14 %), la primaire échoue AUSSI EN SOMBRE** :
3,68 à 4,58, sous 4,5:1 sur **sept palettes sur huit** (en clair : 2,22 à
2,97 sur cinq). C'est plus large qu'un défaut du mode clair : une pastille
teintée de marque n'écrit jamais en primaire.

**Les éléments INTERACTIFS** (un lien qui perd sa couleur perd son signal
d'action) — les huit que le lot précédent avait marqués « lot 1 clair » —
s'écrivent en `semantic.brandText` depuis le lot 1 clair : lisibles dans les
deux modes, marqueurs retirés. Le menu latéral, qui contournait le thème avec
la couleur BRUTE de la palette, lit lui aussi `brandText`. Le garde-fou n'admet
plus aucune primaire en couleur de texte au restaurant.

### Les tokens d'ÉTAT et la surface creusée — TRANCHÉ (26/09/2026)

Quatre tokens pensés ENSEMBLE pour le rendu coloré de Commandes, sur
`AppSemanticColors` (`app_theme.dart`). Tous DÉRIVÉS : c'est la FORMULE qui
fait foi — elle survit à un changement de palette, une valeur non. Mesurés
sur les huit palettes, dans les deux modes (`state_tokens_test.dart`).

| Token | Formule | Valeur, clair | Valeur, sombre | Garantit |
|---|---|---|---|---|
| `sunkenSurface` | clair : `lerp(elevatedSurface, borderSubtle, 0,5)` ; sombre : `lerp(elevatedSurface, kDarkBackground, 0,75)` | #F2F3F5 | #131C2E | plus sombre que la carte (1,11 / 1,17:1) ; texte, marque, payé, en attente ≥ 4,5:1 dessus |
| `stateOutline(état)` | l'état à `kStateOutlineAlpha` (0,40) | — | — | 1,36 à 2,57:1 contre la carte : DÉCORATION, admise parce que le badge écrit l'état |
| `stateShadow(état)` | l'état à `kStateShadowAlpha` (0,22), flou 12, décalage 3 (ceux de l'ombre de carte) | — | — | aucune hauteur |
| `onStateFill(fond)` | blanc ou l'encre sombre (`kDarkBackground`), celle qui contraste le plus | — | — | ≥ 4,74:1 sur danger, warning, success, info et la primaire |

`sunkenSurface` sert à deux endroits qui ne se croisent pas : le bloc de
contenu d'une carte ACTIVE de grille, et le fond d'une ligne TERMINÉE de liste
(la liste n'a pas de bloc). Une carte terminée de grille n'a PAS de bloc
creusé : son fond est déjà le plus sombre, le bloc y ressortirait en clair.

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
| `textHint` | 5,44 | 4,51 (3,07 avant le 26/09/2026) |
| `dangerText` / `warningText` / `successText` | ≥ 6,44 | ≥ 7,73 |
| `danger` / `warning` / `success` / `info` en TEXTE | **1,95 à 3,42** ✘ | ≥ 5,29 |
| `*Text` sur leur propre teinte (10–14 %) | ≥ 6,37 | ≥ 6,32 |
| `danger` de base sur sa teinte | **3,13** ✘ | **4,34** ✘ |
| primaire sur sa teinte (avant le lot 1 clair) | 2,22–11,18 (✘ sur 5) | **3,68–4,58** (✘ sur 7) |
| `brandText` sur sa teinte, et sur ses propres teintes (clair) | ≥ 4,5 | ≥ 4,5 |

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

Texte en primaire sur `primarySurface` en sombre (3,4 à 3,96:1). Voir la
section 21. (`textHint` en sombre, 3,07:1, a été levée le 26/09/2026.)

**TRANCHÉ — un fond de marque sous du BLANC s'écrit `AppColors.primaryFill`**
(lot 1b, 26/09/2026). En sombre, `AppColors.primary` est la variante TEXTE,
claire : le blanc n'y tenait que 2,54 à 3,25:1 sur les huit palettes.
`primaryFill` est le fond des boutons du thème (≥ 4,5:1 sous le blanc) ; en
clair il vaut `primary`, rien n'y change. 124 fonds repointés. Un contenu en
`onPrimary` (texte foncé en sombre) reste sur `primary` : il y tient (5,49 à
7,04:1), et le fond foncé le casserait. Garde-fou :
`test/theme/primary_fill_guard_test.dart` (boutons `styleFrom`).

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

### Le ticket de caisse du restaurant — TRANCHÉ (26/09/2026)

Ticket PROPRE au restaurant (`RestoTicket` pour le contenu, domaine pur ;
`RestoTicketPdf` pour le dessin), choisi sur `shop.sector` dans
`InvoiceService.generatePdf`. Le ticket e-commerce ne bouge pas. Il
s'imprime sur papier THERMIQUE, d'où ces règles :

- **Tout en noir.** Ni couleur de marque ni gris : une teinte sort tramée.
  La hiérarchie passe par la taille et la graisse. **Pas de logo**, pour la
  même raison.
- **Inter embarquée** (400/700, sous-ensemble : ~12 Ko par ticket). Helvetica,
  la police PDF par défaut, n'a ni le « − » (U+2212), ni l'apostrophe « ’ »
  (U+2019) : la remise s'imprimait sans son signe. L'espace fine U+202F de
  `CurrencyFormatter` n'existe dans aucune des deux polices : elle devient
  U+00A0 à l'impression (`RestoTicketPdf.money`).
- **Une ligne dont la donnée manque n'existe pas.** Jamais de champ vide,
  jamais de donnée inventée.
- **« Réf. » + les 6 derniers caractères de l'id**, comme le catalogue — pas
  « n° » : ce n'est pas une séquence.
- En-tête : nom en capitales, puis « Restaurant » SEUL (la ville n'existe pas
  en base, et le pays n'en est pas une).
- Règlement dans son propre bloc encadré : chaque règlement (espèces : ce que
  le client a tendu), le rendu, le reste dû. Le reste dû lit les règlements
  enregistrés, pas seulement `amountPaid` (voir `_settlement`).
- Largeurs : 80 mm et 58 mm ; sous 190 pt, le total passe de 14 à 12 pt et le
  nom de 13 à 11. Bancs : `resto_ticket_test.dart`, `resto_ticket_pdf_test.dart`.

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

### La grammaire du panier — EN VIGUEUR AU RESTAURANT (Commandes, 26/09/2026)

Relevée dans le panier restaurant (`cart_widget.dart`), appliquée d'abord à
l'écran Commandes, à étendre écran par écran si elle tient. TROIS principes,
et non cinq : deux de la première description n'étaient pas dans le panier.

1. **La couleur de marque réservée à ce qui compte** — le montant dû, le
   reste à encaisser, l'action. Écrite en `brandText`. Ce qui est payé ou clos
   s'atténue (`textSecondary`) ; libellés, compteurs et heures restent
   atténués (`caisse_page.dart`, `_amountColor`).
2. **Une seule action en fond plein par bloc.** Sur la carte de commande,
   l'action reste le PETIT bouton en fond teinté (`_StateButton`) : le bouton
   pleine largeur a été écarté, deux commandes visibles sur téléphone avant
   comme après, gain non démontré.
3. **Un filet, pas une surface de plus.** Le relief du panier vient du filet
   de son pied, pas d'un bloc creusé : sur la carte de grille, un filet
   `borderSubtle` sépare où en est la commande de ce qu'elle contient et
   coûte. Les totaux de la sélection vont sur le panneau de verre du module
   (`RestoGlassPanel`) — un composant qui existe, pas un niveau de plus.

**Écartés, et pourquoi** : le « bloc creusé » (aucun token de surface plus
sombre que la carte : `trackMuted` = la carte en sombre, 1,00:1 ;
`scaffoldBackgroundColor` = déjà la carte TERMINÉE) — on ne crée pas un
token au fil des besoins ; le bouton pleine largeur (ci-dessus).

**Grille et liste divergent, à dessein** : la grille sert à agir (filet,
trois lignes), la liste à voir beaucoup (une ligne alignée, sans filet). Elles
partagent le badge d'état et la couleur du montant.

**RENDU COLORÉ — le même jour, par décision produit** (rendu validé le
26/09/2026, priorité à la lisibilité du service) : sur les cartes ACTIVES, le
bloc creusé remplace le filet (`sunkenSurface`, +7 px mesurés), un contour
d'état peint PAR-DESSUS la carte (`foregroundDecoration`, 0 px — en bordure il
coûterait 3 px), une ombre teintée, un badge et un bouton PLEINS de la couleur
de l'état (`onStateFill`) : bouton, liseré, contour et badge disent la même
chose. Le bouton reste PETIT : la pleine largeur coûtait 30 px par carte (une
commande de moins sur téléphone), écartée. Les terminées reculent : filet,
badge teinté, « Facture » en contour. Outils (loupe, dates, export) dans le
panneau des totaux ; ligne comptée « N en cours · X F à encaisser ».

---

## 8. Disposition et points de rupture

### Les seuils officiels — TRANCHÉ

| Seuil | Constante | Décide |
|---|---|---|
| **900** | `_kDesktopWidthBreakpoint` (`adaptive_scaffold.dart`) | Shell : ordinateur (barre latérale + barre du haut) ou mobile (AppBar + barre du bas + tiroir) |
| **720** | `kCartPaneFullWidthBelow` (`cart_pane_provider.dart`) | Volet panier en plein écran, disposition « téléphone » des écrans du restaurant |
| **600** | `kFormMobileBreakpoint` (`adaptive_form_frame.dart`) | Feuille en page pleine ou en dialogue |

**Ce sont les seuls seuils d'ÉCRAN** — ils décident de l'écran entier
(shell, volet panier, feuille). Le commentaire qui affirmait « l'app en a
deux » était faux (corrigé le 26/09/2026).

### Seuils de CONTENU — TRANCHÉ (26/09/2026)

Un seuil qui dispose un CONTENU (colonnes d'une grille, deux cartes côte à
côte, légende à droite) n'est pas un seuil d'écran : il **lit son conteneur**,
**porte un nom**, est **posé à côté de son composant** et **dit ce qu'il
garantit au-dessus** — au mieux, il se DÉDUIT de ce que le contenu doit tenir
(`kOrderTileMin`, `kOrderListRowMin` : « déduits des colonnes, pas
choisis »). Au restaurant :

| Constante | Valeur | Garantit au-dessus |
|---|---|---|
| `kRestoKpiFourColumnsMin` | 760 | 4 tuiles d'indicateurs d'au moins 181 px |
| `kRestoServiceRowSideBySideMin` | 700 | Commandes (≥ 410 px) et Stock (≥ 274) côte à côte |
| `kRestoCardPairSideBySideMin` | 860 | deux cartes d'au moins 422 px |
| `kRoomLegendBesideMin` | 640 | la légende à droite du décompte de salle |
| `kDishIdentitySideBySideMin` | 560 | nom et prix (≥ 456 px) à côté de la photo |

Garde-fou : `test/theme/width_threshold_guard_test.dart` — au restaurant,
aucune largeur comparée à un nombre en dur, et seule la décision du volet
panier (Menu) lit la largeur d'écran. Hors du restaurant, les seuils en dur
(le 600 répété dix-sept fois, les 900 du panier e-commerce…) restent au
backlog.

**TRANCHÉ — la zone 720–900 du Menu est VOULUE** (26/09/2026). Le volet
panier y est latéral alors que le shell est déjà celui du mobile : une
tablette en portrait garde la carte et la commande côte à côte, ce qui est le
geste du service. Mesuré avec `menuGridLayout` (volet de 320 px, marges de
16) :

| Écran | Place de la carte | Grille |
|---|---|---|
| 720 | 390 px | 2 colonnes de 172 px |
| 800 | 470 px | 2 colonnes de 212 px |
| 899 | 569 px | 2 colonnes de 262 px |

La tuile passe sous son plancher de 200 px entre 720 et ~780, sans jamais
tomber à une colonne. Le seuil et sa raison vivent dans
`cart_pane_provider.dart` (`kCartPaneFullWidthBelow`).

**TRANCHÉ — le volet recouvre la carte quand elle n'a plus 390 px à côté
de lui** (26/09/2026, `cartPaneLayout`, domaine, sous test). 390 = 720 − 320
− 10 : la place qu'elle garde au seuil de la zone voulue. La LARGEUR du volet
lit l'écran (un tiers, 320 à 420) ; la décision de RECOUVRIR lit le CORPS de
page. En shell mobile rien ne change (bascule à 720). Barre latérale DÉPLIÉE
(247 px), le volet recouvre la carte jusqu'à 970 px d'écran — elle tombait à
2 colonnes de 138 px à 900 — puis se pose à côté, carte ≥ 390 px. Le bouton
« Carte » du panier suit la même décision (`CartWidget.coversMenu`).
Recouvrant, le volet prend le corps entier sans écart : l'écart ajouté le
faisait déborder de 10 px.

**TRANCHÉ — la caisse e-commerce intègre son panier tant que les produits
gardent 420 px à côté** (26/09/2026, `caisseCartInline`, domaine de la
caisse, sous test). 420 = 801 − 381 : la place qu'ils gardaient à la bascule
d'origine (`écran > 800`), 2 colonnes de 190 px. En dessous : onglets Panier /
Produits. La décision lit le CORPS de page. En shell mobile rien ne change
(bascule à 800 / 801) : la zone 800–900 garde son panier intégré, voulue
comme celle du Menu. Barre latérale DÉPLIÉE — le défaut de l'e-commerce —,
les produits tombaient à 2 colonnes de 116 px à 900 : onglets désormais
jusqu'à 1 047 px d'écran, panier intégré au-delà.

### Le conteneur, pas l'écran — TRANCHÉ

**Une décision de disposition qui dimensionne un CONTENU lit la largeur de
son conteneur (`LayoutBuilder`), pas celle de l'écran.** Sur ordinateur, la
largeur utile est l'écran moins la barre latérale (247 px) : lire l'écran a
fait prendre la branche « large » à une tuile de 342 px, et déborder de 70 px
(`caisse_page.dart`, commit `2d57517`). Seules les décisions qui portent sur
l'écran ENTIER lisent l'écran : le shell, et la LARGEUR du volet panier — sa
décision de recouvrir la carte lit le corps de page, comme celle de la caisse
e-commerce (ci-dessus).

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
Fermé : l'édition d'une commande au restaurant n'ouvre plus aucun écran : elle
dupliquait la commande, et n'est plus proposée (lot « Commandes / Caisse
restaurant », 26/09/2026 — section 19).

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
(`_SuppliesEmptyState`).

**TRANCHÉ (26/09/2026) — dans une section ou une feuille, une PHRASE, pas une
carte : `RestoEmptyNote`.** À cette échelle le texte est déjà posé sur une
surface (feuille opaque, section sous son titre) : la raison de la carte ne
joue pas, et une carte dans une feuille ferait une carte dans une carte. La
phrase dit ce qui manque et, s'il y a lieu, où agir ; elle s'écrit en
`caption` / `textSecondary` (6,87:1 en clair, 5,71 en sombre) — jamais en
`captionHint`, dont le `textHint` tombait à 3,07:1 en sombre (7 des 10 notes
de la liste y étaient). `RestoEmptyState` reste la règle quand l'état vide
EST l'écran : l'Addition (« Table introuvable », « Aucune commande en cours »
avec son bouton « Prendre une commande ») était le dernier écran du module en
texte nu.

Garde-fou : `test/theme/empty_state_guard_test.dart` — une phrase en
« Aucun / Rien » en `Text` nu, rendue sous un `…isEmpty`, échoue. Il ne voit
pas une liste vide testée autrement (la feuille Livreur teste un décompte).

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
le clavier y est géré, la feuille devient une page pleine sous 600 px. Le
restaurant n'en a plus aucune : la dernière (« Nouvelle catégorie » de la
fiche plat) a été convertie le 26/09/2026.

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

**TRANCHÉ (26/09/2026) — le compact : `CurrencyFormatter.compact`, une seule
règle** (KPI, graduations d'axe ; sans symbole) :

| 1 500 | 10 000 | 12 500 | 125 000 | 1 250 000 | −12 500 |
|---|---|---|---|---|---|
| 1,5k | 10k | 12,5k | 125k | 1,3M | -12,5k |

Une décimale seulement quand elle porte une information (jamais « ,0 »,
aucune dès 100) ; la VIRGULE décimale, comme `format` ; le signe géré. Avant :
« 10.0k », point décimal, « -12500 » pour une perte — et le graphique du
restaurant arrondissait à l'entier (« 3k, 5k, 8k » sur un pas de 2 500).
Testé valeur par valeur (`currency_compact_test`).

Au restaurant : aucun montant hors `CurrencyFormatter` (vérifié le
26/09/2026 — les `toStringAsFixed` restants sont des quantités, des
pourcentages ou des pré-remplissages de champ). Hors restaurant : six copies
locales du compact et ≥ 16 montants hors formateur, au backlog.

### Dates

`DateFormatter` (`dayMonthYear`…). « Depuis le … » pour une ancienneté.

### Périodes — TRANCHÉ AU RESTAURANT (26/09/2026)

**Un seul sélecteur de PÉRIODE au restaurant : `RestoPeriodButton`**
(`resto_period_sheet.dart` ; tableau de bord, hub Finances), sur l'état
partagé `dashPeriodProvider`. Périodes proposées : aujourd'hui, hier, semaine,
mois, année, personnalisée — **pas de trimestre** (quatre-vingt-dix jours
glissants, une fenêtre qu'aucun gérant ne demande).

Une DATE UNIQUE (date d'achat, de dépense, de réservation, jour de pointage,
bornes d'un concours) n'est pas une période : elle garde son
`showDatePicker` de champ (11 au restaurant, vérifiés un par un le
26/09/2026).

**NON TRANCHÉ hors du restaurant** — trois autres sélecteurs sur le même
état, au backlog : tableau de bord e-commerce (avec un miroir local),
Hub central (avec le trimestre), Finances e-commerce (`PeriodSelector`).

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
badge écrit, section 16 ; stock : icône avant couleur).

**Au restaurant, tous les cas de l'audit sont doublés** (lot « couleur jamais
seule », 26/09/2026) :

| État | Doublé par |
|---|---|
| Urgence en cuisine | sans objet : l'écran cuisine n'existe plus |
| Retard de service | « en retard » écrit dans la ligne de la tuile de commande |
| Âge d'une table | icône qui change + « oubliée ? » écrit |
| Note « à remplacer » (jauge compacte) | sous-titre et bandeau nominatif de la carte |
| Alerte prix du panier | bandeau « Alerte marge » écrit + icône ⚠ sur la pastille de la ligne |

Une couleur qui DOUBLE un texte se pose en variante texte (`warningText`,
`brandText`…) : l'orange de base écrit dans le panier tombait à 1,76–2,02:1 en
clair, 5,80–6,66:1 en `warningText` (`cart_text_color_guard_test`).

Cas ouverts, hors restaurant : statut d'un ticket de messagerie, lignes du
panier e-commerce, liseré « sans prix » de l'inventaire (backlog).

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

**Commandes au restaurant, sous 600 px (26/09/2026)** : pas de totaux — la
ligne comptée de l'en-tête donne déjà le reste dû, et « Encaissé » est un
chiffre de bilan. Mesuré à 390 × 844 : la première commande passe de 314 à
191 px, une commande de plus visible. Sur toutes les largeurs : la barre
« À planifier » (notion e-commerce) n'y est plus, et un titre de section ne
s'affiche que s'il en oppose deux (`caisse_page.dart`, `OrdersTab`).

**Ce qui n'a PAS le droit de différer :** une permission (qui voit quoi), un
libellé, une action disponible, un widget épuré d'un côté et resté tel quel
de l'autre.

**Comment documenter une différence voulue** : un commentaire à la branche,
qui dit POURQUOI. Une branche sans commentaire est présumée être un oubli.

**Oublis connus (audit du 24/09/2026)** : titre absent sur ordinateur, titre
répété sur mobile, menu du compte non épuré sur mobile, cloche réservée à des
publics différents — **corrigés par le lot Shell (25/09/2026)**.

**Édition d'une commande — FERMÉ (26/09/2026).** Au restaurant, « Modifier la
commande » chargeait la commande dans le panier et menait à la caisse
e-commerce, dont la mise en page changeait à 800 px (panier en ligne
au-dessus, invisible en dessous). Le vrai défaut était dessous : le
« Commander » du restaurant crée une commande au lieu de modifier celle
chargée — la commande était DUPLIQUÉE. L'action n'est plus proposée au
restaurant (`order_actions.dart`, test « 11 bis ») ; une commande s'y complète
par l'ajout de plats à la table et l'annulation d'une tournée. Après un
paiement, « Nouvelle vente » ramène au Menu, plus à la caisse. La caisse
`/caisse` n'est donc plus un écran du restaurant.

---

## 20. Règles écrites dans le code — registre

Les règles de design naissent dans les commentaires, pendant un lot. Ce
registre dit où elles vivent. **Quand une règle change, on change son
commentaire ET ce registre**, sinon l'un des deux ment.

| Règle | Écrite dans | Section |
|---|---|---|
| Deux valeurs de primaire, dérivées ; ne pas y remettre la palette | `core/theme/brand_contrast.dart`, `app_colors.dart` | 3 |
| Ticket restaurant : tout noir, Inter embarquée, ligne sans donnée absente | `features/restaurant/domain/resto_ticket.dart`, `core/services/resto_ticket_pdf.dart` | 5 |
| `textHint` sombre dérivée (lerp vers `textSecondary`, 0,60), 4,5:1 hors teinte de marque | `app_colors.dart`, `app_theme.dart` (`_dTextHint`) | 3 |
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
| ~~Le bouton d'action d'une carte est petit et en fond teinté~~ — **LEVÉE pour Commandes le 26/09/2026** (rendu validé, priorité à la lisibilité du service) : petit, en FOND PLEIN de l'état (`onStateFill`) | `caisse_page.dart` (`_StateButton`) | 12 |
| ~~Pas de contour sur les cartes~~ — **LEVÉE pour les cartes ACTIVES de Commandes le 26/09/2026** (même raison) : contour d'état peint par-dessus, `foregroundDecoration` | `caisse_page.dart` (`_buildRestoCard`) | 3 |
| ~~Pas de bouton pleine largeur en fond plein~~ — **LEVÉE pour Commandes le 26/09/2026**, non appliquée : 30 px par carte, écartée sur mesure | `caisse_page.dart` (`_StateButton`) | 12 |
| La hiérarchie par le fond, l'espace et la typographie — **ÉLARGIE pour Commandes le 26/09/2026** : le contour et le liseré y participent aussi | `caisse_page.dart` | 2 |
| Les largeurs se MESURENT en Inter : la police de test gonfle les largeurs de ~40 % — chargée pour TOUS les tests | `test/flutter_test_config.dart` | 22 |
| Un grand écran se découpe en `part` / `part of` par unité naturelle (onglet, bloc), la même bibliothèque — prouvé sans effet sur le programme compilé | en-tête de chaque fichier `*.xxx.dart` du restaurant ; backlog « Grands fichiers » | — |
| Le domaine est du Dart pur : la couleur et l'icône d'un état vivent en présentation (extensions `*Visuals`) | `table_status_visuals.dart`, `expense_kind_visuals.dart`, `service_tab_visuals.dart` ; garde-fou `domain_pure_dart_guard_test` | — |

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

- Palette : texte sur `primarySurface` en
  sombre (3,4–3,96:1) ; fond de marque sombre de Midnight à 1,93:1 contre la
  carte (bord du bouton) ; `printer_page.dart` (fichier d'un autre chantier,
  un bouton à repointer vers `primaryFill`).
- Cibles tactiles : ≈ 154 sites hors lot, comptés par feature.
- Code mort : `ExpenseFormSheet`, `PartnerLedgerDetailPage`,
  `DottedBorderBox` (e-commerce). Au restaurant, supprimé le 26/09/2026 :
  `KitchenTicketCard` et la pastille de service de `caisse_page`.
- Shell : titres de page de l'e-commerce (backlog).
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
