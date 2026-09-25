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
