# Sons d'alerte — placeholders

PLACEHOLDERS — remplacer par de vrais sons libres de droits
(pixabay / freesound / mixkit) avant production.

| Fichier            | Niveau                                    | Caractère attendu                        |
|--------------------|-------------------------------------------|------------------------------------------|
| `alarm_soft.mp3`   | INFO (J-1 à 07h00)                        | Doux, court (≤ 1 s), une seule note      |
| `alarm_medium.mp3` | WARNING (H-2 le jour J)                   | Plus présent, 2 notes ou ding-dong       |
| `alarm_strong.mp3` | CRITICAL / CRITICAL_REPEAT / MAX / OVERDUE| Sirène ou alarme, 1-3 s, attire l'œil    |

Pour l'instant, les 3 fichiers sont des MP3 silencieux d'environ 0.1 s —
juste assez pour valider le pipeline audio (chargement asset, déverrouillage
AudioContext web, lecture sans erreur). Ils ne produisent aucun son audible.

## Remplacement

1. Choisir 3 sons libres de droits (CC0 ou licence permissive).
2. Renommer en respectant exactement les noms du tableau ci-dessus.
3. Garder une durée raisonnable (≤ 3 s) pour ne pas alourdir le bundle web.
4. Tester via les logs `[AlarmSound] play <level>` après une commande
   programmée à H-2 / H-1 / etc. dans la base.
