# 15-audit-perf — journal

Départ : dim. 11/10/2026, 05:38 UTC (horloge de la machine, `date`).
Branche `chantier/15-audit-perf`. Mission : section « 15-audit-perf » de
`missions.md`, et la priorité donnée au lancement : l'écart entre le banc et
le Pulse installé.

## Le constat de départ

Le chantier 01 a mesuré le Pulse installé (main, tous modules) à 1,15 –
1,35 % d'un cœur pendant les bancs de `./verifie.sh`, qui estimaient 0,80 –
0,83 %. Le 11/10 au matin, avant les modules, il était à 0,72 %. Plafond :
moins de 1 % panneau fermé.

## Plan en jalons

1. **Mesurer le Pulse installé tel qu'il est** : temps CPU cumulé
   (`proc_pid_rusage`, recoupé par `ps -o time=`) sur plusieurs minutes, les
   fenêtres qui contiennent une relance (fusion d'un chantier) écartées ;
   profil au `sample` sur son pid. Décomposer : relevé commun, libellé de
   barre, persistance (history.json, SQLite, journaux), chaque module.
2. **Ramener le Pulse installé sous 1 %** : corriger les postes trouvés,
   chacun mesuré avant et après, chiffres affichés inchangés (`--probe`,
   rendus et tests identiques). Correctif court s'il touche le module d'un
   chantier encore actif ; sinon décrit dans le rapport.
3. **Que `./verifie.sh` mesure ce qui compte** : le banc doit voir ce que
   l'app installée dépense vraiment (persistance active dans une copie,
   coût réel du libellé), pour que l'écart ne se reproduise pas.
4. **Endurance** : banc de longue durée, croissance de la mémoire, `leaks`,
   réveils par seconde, taille des fichiers de données.
5. **Situations dures, simulées dans les tests** : veille et réveil, disque
   débranché puis rebranché sous un autre nom, changement de réseau,
   fuseau, compteurs 32 bits, base corrompue. Ce qui ne se simule pas : une
   demande précise à Isma dans le rapport.
6. **Seuils** ajoutés à `./verifie.sh`, rapport chiffré.

## Avancement

### Jalons 1 à 3 — d'où vient l'écart, correctifs, banc fidèle (05:38 → 06:20)

Outils (scratchpad, lecture seule sur le Pulse installé) : un relevé de
`proc_pid_rusage` V6 toutes les 10 s — temps CPU, dont cœurs P
(`ri_user_ptime`), instructions, cycles, empreinte, octets écrits, âge — et
deux profils `sample` de 100 et 120 s sur son pid.

**Le Pulse installé (main, avant correctifs)** : 0,65 à 0,90 % par fenêtre de
10 s, 0,78 % en moyenne sur 190 s loin d'une relance ; 17 à 20 millions
d'instructions par seconde ; 97 % du temps CPU sur les cœurs E, à 2,4 GHz,
une instruction par cycle. Toutes les 60 s une bosse de 20 à 30 ms, toutes
les 120 s une de ~100 ms. Une relance coûte 0,25 à 0,3 s de CPU dans sa
première minute (cinq relances relevées entre 05:40 et 05:52).

**Au profileur (120 s, 868 échantillons hors attente de 1,3 ms)** :
- balayage des processus 297 (0,33 % d'un cœur), presque tout dans le noyau
  (`__proc_info`) : deux appels par processus ;
- libellé de barre 199 (`ImageRenderer` 145, `fixLengthOnce` 24), plus 76
  dans la transaction Core Animation (le dessin du bouton) et ~60 sur les
  fils Metal et RenderBox du rendu : ~0,37 % en tout ;
- réseau 33, GPU 18 (copie de toutes les propriétés du pilote),
  history.json 17 (encodage ~10 ms, écriture ~1,5 ms par minute : 0,02 %,
  pas la cause), capteurs 9 en régime établi.

**L'écart banc/app, c'étaient surtout les cœurs.** Même travail mesuré en
instructions (6,9 milliards par banc), mais le banc lancé d'un shell
tournait à 84–99 % sur les cœurs P (3,2 GHz, IPC 1,4) : 1,1 s de CPU contre
2,2 s sur les cœurs E. `taskpolicy -a` et `-c utility` : toujours les cœurs
P ; `-b` (arrière-plan Darwin) : cœurs E à 2,4 GHz, comme l'app. Banc sous
`-b` : 0,64 % ; Pulse installé aux mêmes secondes : 0,71 %. Les 1,15 à
1,35 % du chantier 01 : machine chargée, et fenêtres dans les premières
minutes après une relance, ou tombées sur une tâche de 2 min.

**Correctifs (commit 8986e5a)**, chiffres affichés inchangés :
- `ProcessMonitor` : un seul `proc_pid_rusage` V2 par processus au lieu de
  `PROC_PIDTASKINFO` + V6 (temps CPU identiques à 0,07 % près sur 670
  processus, zombies écartés comme avant) : 2,7 → 1,1 ms par balayage hors
  de l'app ;
- `GPUMonitor` : la seule clé `PerformanceStatistics` : 2,35 → 0,034 ms.
- A/B au banc sous `-b`, deux passes chacun : fermé/refermé 0,65–0,68 /
  0,78–0,82 % → 0,49–0,53 / 0,62–0,64 % (**−0,16 point**), 7,1–7,3 →
  6,5–6,7 milliards d'instructions par banc.

**Banc (commit 542c030)** : phases fermées sur les cœurs E
(`PRIO_DARWIN_BG`), ouverture au premier plan ; tâches lentes rendues dues
puis mesurées une à une (`Sampler.rendDues`) : disques et incidents 89 ms
toutes les 2 min, prévision, identités et écritures 15–19 ms par minute,
0,10 point ; `Banc.icone` 0,45 → 0,13 point (profileur) ; le Pulse installé
n'est comparé que s'il tourne depuis 2 min. Le banc dure ~95 s.
`./verifie.sh` : TOUT PASSE en 202 s, budget estimé 0,72 % (0,49 au banc +
0,10 de tâches lentes + 0,13 d'icône), 152 tests.

Réponses à la coordination : history.json coûte 0,02 % d'un cœur (11 ms par
minute sur les cœurs E), pas l'écart ; le pic de 156 ms est la tâche de
2 min (espace libre des volumes avec le purgeable, incidents) : 89 ms
mesurés au banc sur les cœurs E, 100 à 170 ms dans l'app selon la charge.

### Fusions (06:35 → 07:02)

Fusionné dans main : 3e71c1b (correctifs du relevé, banc fidèle), c67bea2
(veille et compteurs réseau, situations dures), 404e242 (espace purgeable,
icône recalée). La vérification avant fusion a passé en entier quatre fois
(TOUT PASSE, 202 à 266 s, 152 puis 172 tests) ; `main` bougeant toutes les
deux ou trois minutes, les deux dernières fusions ont été faites juste après
la synchronisation et revérifiées aussitôt après sur `main` (TOUT PASSE en
124 s pour c67bea2).

### Jalon 2 mesuré sur le Pulse installé — avant / après

Fenêtres longues, loin d'une relance (relevé `proc_pid_rusage` toutes les
10 s, lecture seule) :

| Pulse installé | fenêtre | CPU, 1 cœur | réveils/s | empreinte | écrit |
|---|---|---|---|---|---|
| main 06:04 (avant) | 18 min | 0,83 % | 3,2 | 19–30 Mo | 20,8 Mo/h |
| main 06:23 (avant) | 16 min | 0,82 % | 3,2 | 22–32 Mo | 20,0 Mo/h |
| main 06:41 (relevé corrigé + barre du 09) | 14 min | **0,46 %** | 1,4 | 17–24 Mo | 19,8 Mo/h |
| main 06:58 (+ veille réseau, chantiers 10 à 13) | 16 min | **0,43 %** | 1,4 | 17–22 Mo | 20,5 Mo/h |

Instructions : 23 → 11,5 millions par seconde. Fenêtres de 10 s ordinaires :
65–90 ms → 29–41 ms. Le banc, même code des deux côtés, aux mêmes secondes :
0,27 % contre 0,34 % pour l'app (d'où `Banc.icone` = 0,08).

### Le pic des 2 min (commit 0e789e8)

C'est la clé « pour usage important » de l'espace libre : 105 à 117 ms de
CPU par balayage sur les cœurs E, 1 ms pour toutes les autres clés
(`volumes.swift`, hors de l'app, sous `taskpolicy -b`). Fermé, elle n'est
plus relue que toutes les 10 min (le pas de l'historique des disques) ;
entre-temps, libre strict à chaque balayage, purgeable du dernier balayage
complet (`DiskMonitor.disponible`, testé). Ouvert : inchangé. Au banc :
63–89 ms → 17 ms toutes les 2 min, plus 112 ms toutes les 10 min ; tâches
lentes 0,09–0,11 → 0,07 point. Sur le Pulse installé relancé à 07:16
avec ce changement : 0,35 % sur ses 3 premières minutes utiles, à
confirmer sur une fenêtre longue.

### Situations dures (commit 352ec9f, dans c67bea2)

- **Veille + compteur réseau remis à zéro** : vrai défaut, trouvé par la
  simulation. Après une heure de veille, une interface recréée au réveil
  (partage iPhone par USB) repart de zéro ; le modulo 2³² en faisait 1,8 Go
  « reçus » à 0,5 Mo/s, plausibles pour la seule borne de débit, comptés
  dans le forfait iPhone. Au-delà de 30 s sans relevé, un compteur qui
  recule est écarté (`CompteursReseau.ecartMaxPourUnRebouclage`). Test vu
  échouer avant la correction.
- Rebouclage 32 bits au rythme ordinaire (2 s) : compté, testé.
- Disque rebranché sous un autre nom : même clé d'historique (UUID), base
  SQLite comprise ; deux disques au même point de montage ne se mélangent
  pas ; un partage sans UUID retombe sur son chemin (limite écrite).
- Déjà couverts par d'autres chantiers : base SQLite illisible mise de côté
  (02), history.json illisible jamais touché (02), veille sans décalage des
  points (02), disque débranché qui clôt un épisode d'écriture (05), trou de
  veille des règles (11).
- Non simulé : changement de fuseau. `HistoryStore.dayKey` relit
  `TimeZone.current` à chaque appel, mais savoir si Foundation le remet à
  jour sans relance demande de changer le fuseau du système — interdit ici.

### Endurance

Les instances ont vécu 14 à 18 min aujourd'hui (une relance par fusion, au
plus toutes les 15 min) : empreinte entre 17 et 32 Mo sans tendance (pentes
de −6 à +5 Mo/h, du bruit), réveils stables, aucun fichier qui grossit hors
de l'attendu. history.json reste l'essentiel des écritures : 300 ko chaque
minute, ~18 Mo/h sur ~20 ; le passer à 5 min (comme la base SQLite)
diviserait les écritures par quatre et ne gagnerait que 0,015 point de CPU —
laissé tel quel, décision à prendre. `leaks` et `sample` : deux profils pris
au début sans demande à l'écran ; plus utilisés ensuite, la coordination
signalant un risque de demande de mot de passe.

### Ensuite

- Confirmer le Pulse installé de 07:16 (espace purgeable) sur 15 min ou
  plus : attendu ~0,40 %.
- Le panneau détaché ouvert (chantier 13) : 7,7 % d'un cœur en continu,
  et l'ouverture au banc est montée de 4–5 % à 7–12 % avec les animations
  du 10 — le prochain poste à profiler, panneau ouvert cette fois.
- Endurance de plusieurs heures quand les fusions s'arrêtent : le relevé de
  `scratchpad/15-audit-perf/compteurs` suffit (empreinte, réveils, octets).
- `fixLengthOnce` refaisait des mesures de texte à chaque affichage (24
  échantillons sur 120 s) : à revoir dans la barre du 09 si elle l'a gardé.

### Fin de session (07:28)

- Banc, panneau ouvert : hors écran, les animations SwiftUI tournaient sans
  frein (chantier 10) ; le banc les coupe comme « Réduire les animations »
  (`Motion.sansAnimation`, jamais touché par l'app) : ouvert 6,1–12,4 % et
  12–15 réveils/s → 5,7 % et 3,8 réveils/s ; fermé inchangé, 0,27 %
  (commit cd20bcc).
- Dernier `./verifie.sh` complet : tout passe sauf trois tests du chantier
  18 (`ExtrasTests`, l'agenda), qui échouent aussi dans `main` ; budget
  estimé 0,42 %, Pulse installé (07:16, espace purgeable compris) 0,45 %
  aux mêmes secondes.
- Commits cd20bcc, 6e02ff6, fc3551d et a99de98 sur la branche, NON
  fusionnés : `outils/fusionne.sh` refuse tant que les tests du 18 échouent
  dans `main`. À fusionner tels quels dès qu'ils passent.
