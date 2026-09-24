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

En sombre, `colorScheme.primary` vaut `primaryLight`, soit `#475569` pour
Midnight : **1,93:1 sur `surface`**, 2,36:1 sur le fond. Tout ce qui ne parle
QUE par la primaire y est à peine visible — soulignement d'onglet actif,
couleur de l'état « À encaisser », montants teintés en primaire. Les sept autres
palettes sont au-dessus de 3,2:1.

Contournements en place, écran Commandes : l'onglet actif se lit aussi par la
graisse et la couleur de son libellé ; les montants sont en texte primaire et
non en couleur de marque.
