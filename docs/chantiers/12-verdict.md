# 12-verdict — conseils chiffrés et boutons

Départ : dimanche 11/10/2026, 07 h 38 (heure de Paris), 05:38 UTC.
Branche `chantier/12-verdict`. Fin au plus tard 09 h 38 (07:38 UTC).

## Ce qu'on sait au départ (relevé sur une copie du journal, 05:40 UTC)

- `verdicts.jsonl` : 18 jours (24/09 → 11/10), 746 lignes. Temps affiché par
  règle : 9 (disque plein sous 30 j) 37,8 %, 4 (sous 7 j) 17,8 %, 8 (disque à
  90 %) 16,3 %, 7 (le swap monte) 13,7 %, 12 (rien) 10,5 %, 3 (95 %) 2,2 %,
  6 (pression élevée) 1,7 %, 11 et 10 : presque rien (1 seul « Vivaldi
  occupe le processeur » en 18 jours).
- Le bilan de `--probe` compte comme « changement » chaque ligne écrite au
  redémarrage de Pulse : « 38,8 par jour » sur 7 jours, alors que depuis le
  délai de tenue (09/10, 21 h 58 UTC) il y a eu 13 vrais changements en
  1,3 jour, soit 9,9 par jour. 8 des 13 sont des allers-retours de la règle 7.
- Aucun incident (plantage Adobe, processus tué) sur 14 jours, alors que le
  swap a atteint 22,5 Go en séance.
- Contrainte de la coordination : le panneau fait 1 216 pt sur 1 290. Le
  conseil n'ajoute pas de hauteur : une ligne au plus, le détail en infobulle.

## Plan en jalons

**J1 — Un conseil chiffré par règle** (`Sources/Pulse/Metrics/Advice/`)
- Fonction pure : verdict + relevés existants → une phrase de conseil, ses
  chiffres, et l'action d'un bouton. Rien ne tourne panneau fermé : le
  conseil se calcule à l'ouverture, sur ce que le `Sampler` publie déjà.
- Mémoire (règles 1, 2, 6, 7) : la plus grosse app hors montage, « Vivaldi
  tient 6,0 Go : le fermer en libère autant ». Disques (3, 4, 8, 9) : le
  volume qui a de la place, et combien de jours il donne au rythme du
  disque qui se remplit. Processeur (10), plantage (5).
- Section CONSEIL de `--probe` : chaque conseil, ses chiffres, ce que ferait
  le bouton (sans jamais le faire).
- Tests : chaque conseil vu échouer sans sa correction.

**J2 — Le bouton, dans le bandeau, sans hauteur de plus**
- Deux lignes comme aujourd'hui : le conseil à droite de la phrase, le
  bouton à droite de la preuve. Trois lignes seulement sur une colonne.
- Boutons : ouvrir le disque dans le Finder, le Moniteur d'activité, les
  réglages de stockage. Jamais quitter ni tuer une app. Rien n'est cliqué
  pendant les essais.
- Rendus sombre et clair, contraste, hauteur dans `./verifie.sh`.

**J3 — Seuils des règles 7, 9 et 10, calibrés sur les données**
- Bilan de `--probe` corrigé (un redémarrage n'est pas un changement).
- Règle 9 : rejeu de la prévision sur les 30 jours de points de disque.
- Règle 7 : le journal et la série de swap de l'historique.
- Règle 10 : ce qui existe, et l'instrument qui manque.
- Méthode et chiffres dans le README ; chaque seuil vu échouer sans sa
  correction.

## Journal

### J1 — un conseil chiffré par règle (05:38 → 06:15 UTC)

Fait :
- `Metrics/Advice/Advice.swift` : `Advisor.advice(for:_:)`, fonction pure
  sur le verdict et les relevés que le `Sampler` publie déjà — rien ne tourne
  panneau fermé. `AdviceAction` : Finder, Moniteur d'activité, réglages de
  stockage, et rien d'autre ; une valeur, jamais exécutée hors du clic.
- `Verdict.object` : le volume (règles 3, 4, 8, 9) ou l'app (règle 10) que
  la phrase nomme. Le conseil part du même objet, pas d'une seconde
  sélection. `VerdictEngine.actives` pour `--probe`.
- Conseils : mémoire (1, 2, 6, 7) — la plus lourde des apps qu'on peut
  fermer, à partir de 1 Go, montage exclu (« Vivaldi tient 6,0 Go : le
  fermer en libère autant »), sinon « Premiere tient 21 Go, les autres
  moins de 1 Go » ; disque plein (3, 8) — ce qu'il faut retirer pour passer
  sous 90 %, et le disque externe qui peut le recevoir ; disque qui se
  remplit (4, 9) — l'espace d'un autre disque externe, en jours au rythme du
  premier (« Extreme Pro a 719 Go libres, ~9 jours à ce rythme »), sinon ce
  qu'il faut libérer pour une semaine ; plantage (5) — la mémoire à l'heure
  du plantage, lue dans la série de l'heure ; processeur (10) — « Fermer
  Vivaldi rend 2,5 cœurs à Premiere ». Jamais l'interne comme destination.
- Section CONSEIL de `--probe` : la règle affichée et toutes les règles
  vraies, la ligne, le calcul, ce que ferait le bouton.

Mesures :
- `--probe` du 11/10 06:05 UTC : « Extreme Pro a 719 Go libres, ~9 jours à
  ce rythme » (719 ÷ 77,8 Go par jour, rythme des 24 h de Ssd 2).
- 12 tests (`AdviceTests`), 135 au total. Chacun vu échouer sous sa
  mutation, en trois lots : montage non exclu, interne accepté comme
  destination, premier point de la série au lieu du plus proche, règle 12
  conseillée, seuil de 1 Go retiré, Finder pour l'interne, jours comptés
  sur le disque plein, cœurs non divisés, agents système acceptés, arrondi
  au plus proche (« 40 Go » laissait le disque à 90,0 %).

### J2 — le bouton, dans le bandeau, sans hauteur de plus (06:00 → 06:12 UTC)

Fait :
- `Advice/AdviceView.swift` : `VerdictLines`, deux lignes partagées chacune
  de leur côté — la phrase et le conseil, la preuve et le bouton. Une seule
  colonne de cartes : le conseil sur une troisième ligne, seule exception.
  `PopoverView` : 4 lignes changées. Accessibilité : `.contain` quand il y a
  un conseil, le bouton reste un bouton (à relire à l'API, chantier 16 : un
  arbre jamais affiché reste vide hors écran).
- Bouton dessiné comme « Régler le forfait iPhone » (`.secondary` et
  chevron) : le lien système tombe à 4,08:1 sur le fond sombre. Action au
  clic seulement : `selectFile(nil, inFileViewerRootedAtPath:)` pour le
  Finder, le Moniteur d'activité par son identifiant, et
  `x-apple.systempreferences:com.apple.settings.Storage` (extension
  `Storage.appex` vérifiée sur la machine). Jamais cliqué pendant les essais.
- Idée de la coordination (chantier 05) : une écriture massive EN COURS
  sur le disque prend la ligne — « Copie de carte en cours (ffmpeg,
  1,3 Go) » —, le geste passe dans l'infobulle. API du 05 telle quelle
  (`DiskActivity.state.ingestions`, `disques.json` pour `--probe`).
- Textes raccourcis après le rendu `--conseils` : à côté de « La mémoire
  commence à manquer », 47 caractères seulement ; « Vivaldi tient 6,0 Go :
  le fermer en libère autant » se coupait avant son verbe, d'où « Fermer
  Vivaldi libère 6,0 Go ».

Mesures :
- Hauteur : première carte à 61,5 pt du haut avant comme après (rendu du
  même relevé), panneau 626 × 1 216 pt. Une première version gagnait 1 pt
  (chevron en `Image` à côté du texte) : chevron mis DANS le texte.
- `./verifie.sh` : tout passe sauf les rendus figés du panneau (1 517 et
  1 354 pixels, le conseil et son bouton seulement, vus sur la carte de
  l'écart) ; références régénérées et regardées. Contraste au plus bas
  3,18:1 (aucune teinte ajoutée). Budget panneau fermé 0,86 % estimés.
- 13 tests de conseil (la copie en cours vue échouer quand on ne filtre plus
  par disque).
- Fusionné dans main (8274943) après `./verifie.sh` : TOUT PASSE, budget
  panneau fermé 0,88 % estimés, Pulse installé 0,80 % aux mêmes secondes.

### J3 — seuils 7, 9, 10 (06:12 → 06:25 UTC)

Fait :
- `outils/rejoue-seuils.py` : rejoue les règles 7, 9 et 10 sur des COPIES
  de history.json et historique.sqlite (jamais ouverts en place). Règle 9 :
  la prévision copiée de `HistoryStore.forecast`, recalculée à chaque point
  des 30 jours de disques ; par seuil, la part du temps où la règle est
  vraie et ses entrées ; par tranche d'échéance, ce qu'elle devient 24 h et
  3 jours plus tard.
- Règle 9 : 30 → 14 jours (`VerdictEngine.forecastSoonDays`).
- Bilan du journal dans `--probe` : `VerdictJournal.changes` ne compte plus
  les relances (53 sur 7 jours), et les épisodes par règle non plus.
- `verdicts.jsonl` porte la preuve de chaque verdict (`evidence`).
- Règles 7 et 10 : laissées à 1 Gio/h et 90 % / 200 %, dites provisoires
  dans `--probe`, avec l'outil de rejeu.

Mesures (11/10, 06:15 UTC) :
- Disque interne, 13 jours : règle 9 vraie 43,4 % du temps à 30 j, 26,7 % à
  14 j, 5,6 % à 7 j. Échéances de 14 à 30 j disparues 24 h après : 145 sur
  201 (72 %) ; de 7 à 14 j : 97 sur 294 (33 %). Disque plus plein 3 jours
  après : 29 % et 36 %.
- Journal, règle 7 : 210 épisodes avant le délai de tenue (43,9 h, médiane
  4,3 min), 5 depuis (1,4 h) ; aucune règle grave (1, 2, 5) en 18 jours,
  aucun incident en 14 : rien pour dire si 1 Gio/h annonce un problème.
  L'historique : 2,1 h de swap, un matin de compilations (+6,5 Go en
  26 min sans incident) — pas un échantillon de montage.
- Règle 10 : la charge par app n'est dans aucune série ; processeur total
  au-dessus de 90 % 11 à 23 % des 2 h relevées (compilations des agents).
- Tests : `CalibrationTests`, 2 tests, chacun vu échouer (seuil remis à
  30 jours ; chaque ligne comptée comme un changement).
- Fusionné dans main (90a62f6). La fusion a couru derrière `main` cinq fois
  (09, 10, 15, 18 fusionnaient pendant chaque `./verifie.sh` de 3 min ;
  deux conflits de README et CLAUDE.md, les deux ajouts gardés). Vérifié :
  `./verifie.sh` complet, banc compris, TOUT PASSE à 278876d (0,80 % d'un
  cœur estimés panneau fermé) ; `--rapide` TOUT PASSE après 18-extras ;
  pour les 6 fichiers du 09 arrivés ensuite, compilation et 37 tests
  (conseil, calibration, verdict, barre), puis fusion aussitôt.

### J4 — l'instrument de la règle 10 (06:40 → 06:50 UTC)

- `Advice/CalibrationSeries.swift` : la série `processeur.hors-montage`,
  charge de l'app hors montage la plus occupée, en % d'un cœur, une valeur
  par relevé, prise sur le balayage que le `Sampler` fait déjà (un maximum
  sur quelques centaines de groupes). Une ligne dans `Sampler.tick`.
- `outils/rejoue-seuils.py` croise `cpu.total` et cette série, au même
  étage de l'historique, pour les seuils 80/90 % × 100/200/300 %.
- Test : `laSerieDeLaRegle10IgnoreLeMontage`, vu échouer quand le filtre
  du montage saute (Premiere à 300 % comptait).
- `./verifie.sh` complet sur J4 avant fusion : TOUT PASSE, budget panneau
  fermé 0,52 % estimés (la série comprise), Pulse installé 0,54 %. Fusionné
  dans main (9677f98) juste après une synchronisation sans conflit (thèmes du
  10) ; `./verifie.sh` complet APRÈS fusion, sur l'état fusionné : TOUT
  PASSE, 246 tests, 0,50 % estimés, panneau 626 × 1 253 pt, contraste au
  plus bas 3,18:1.

## Bilan à 07:01 UTC

Fait : un conseil chiffré par règle (1 à 10), son bouton, sans hauteur de
plus ; la copie en cours qui remplit un disque (chantier 05) ; règle 9
calibrée à 14 jours ; bilan du journal corrigé ; preuve dans le journal ;
outil de rejeu des seuils ; série de la règle 10. Fusionnés : 8274943 (J1,
J2), 90a62f6 (J3), 9677f98 (J4).

En cours : rien.

Bloqué, par le temps seulement : les règles 7 et 10 n'ont que 2 h de série
(un matin de compilations). Vers le 17/10, `python3 outils/rejoue-seuils.py`
sur une semaine de montage ; le journal porte désormais la preuve de chaque
bascule.

Il faut d'Isma : un clic sur « Ouvrir Ssd 2 › », sous le conseil du
bandeau, quand il ouvrira le panneau — une fenêtre du Finder sur Ssd 2 doit
s'ouvrir, rien d'autre. Aucun bouton n'a jamais été cliqué pendant les
essais. « Réglages de stockage » n'apparaît que pour le disque interne :
l'adresse `x-apple.systempreferences:com.apple.settings.Storage` est
vérifiée dans le système, pas à l'écran.

Ensuite : accessibilité du bandeau à relire à l'API panneau ouvert
(chantier 16) ; « ce qui remplit » (chantier 05, `FillReport`) dans le
détail du conseil quand Isma aura dit oui à Spotlight ; destination d'un
export (chantier 08) pour un conseil de la règle 11.
