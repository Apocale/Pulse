# 19-suivis — les suites techniques des chantiers 03 à 17

Départ : dimanche 11/10/2026, 09 h 17 UTC (`date` : 09:17:36). Butée :
11 h 17 UTC, ou plus tôt si tout est fait ou bloqué. Branche
`chantier/19-suivis`, seul chantier actif.

## Plan en jalons, dans l'ordre de priorité

1. **Fenêtre Réglages cachée** (signalé par le 17) : elle garde le rythme
   « panneau ouvert » tant qu'elle n'est pas fermée, même derrière
   Premiere, réduite ou sur un autre bureau. Rythme ouvert seulement si une
   surface est réellement visible (observateur d'occlusion, comme le
   panneau détaché). Mesuré avant et après, sans rien ouvrir à l'écran.
2. **Taille du binaire** : 9,2 Mo pour un plafond de 10 Mo, dont ~5 Mo de
   symboles. La réduire sans perdre de quoi symboliser un rapport de
   plantage, ou poser un plafond justifié. Choix documenté.
3. **Carte Médias figée** (suite du 03) : un relevé fixe injectable, pour
   qu'elle entre dans `Rendu.cartesFigees` et les comparaisons d'images.
4. **Débits disque dans l'historique longue durée** (suite du 05), dans la
   limite de place de la base (mesurée).
5. **Règles** : copie de rushes terminée publiée panneau fermé (05) ;
   « Export terminé » qui nomme le fichier et dit s'il a réussi (08 + 11).
   Coût nul règles éteintes.
6. **En fond, tout le long** : endurance du Pulse installé, en lecture
   seule, un relevé par minute regroupé par 10 min (CPU, mémoire, réveils,
   octets écrits, taille des fichiers de données), fenêtres de relance
   écartées. Rapport chiffré, tendance comprise.

## Journal

### Jalon 1 — la fenêtre Réglages cachée (09 h 20 → 10 h 05)

`SettingsWindow` disait « visible » à l'ouverture, « fermée » à la
fermeture, rien entre les deux : derrière Premiere en plein écran, réduite
ou sur un autre espace, elle gardait la cadence du panneau ouvert (relevé à
1,5 s, capteurs, réseau, aperçu de carte redessiné). Désormais elle relit sa
visibilité à chaque changement d'occlusion et quand elle est réduite ou
rouverte du Dock : `Surfaces.isSeen(fenêtre)` — à l'écran (`isVisible`), pas
réduite, pas entièrement recouverte ni sur un autre espace
(`occlusionState`). Hors de vue : contenu vidé (`SurfaceHost.freeze`),
cadence fermée ; sa page est gardée (`SettingsView.pageDidChange`) et le
contenu revient dessus. Le panneau détaché et le tableau de bord avaient le
même trou, signalé par le 17 pour le tableau de bord réduit : leur
observateur s'arrêtait sur `isVisible` faux — une fenêtre réduite ou
masquée gardait la cadence ouverte. Même règle pour les trois.

Mesuré sans rien ouvrir : `--banc 620 --reglages memoire` (nouveau), la
vraie fenêtre jamais posée à l'écran (0 fenêtre à l'écran relevée pendant
chaque phase), page « Mémoire » et son aperçu en direct, phases de 120 s
(chacune porte les tâches de 1 et 2 min du relevé), bascules hors mesure,
phases hors de vue sur les cœurs E comme l'app :

| phase | passe 1 (09 h 41, 4 phases) | passe 2 (09 h 50, Mac sur batterie à 3 %) |
|---|---|---|
| fermée | 0,24 % · 0,7 réveil/s | 0,59 % · 0,6 |
| visible (premier plan) | 1,10 % · 1,9 | 6,79 % · 1,2 |
| cachée comme AVANT (cadence ouverte, contenu vivant) | — | 6,00 % · 0,8 |
| cachée, APRÈS | 0,24 % · 0,8 | 0,64 % · 0,6 |
| refermée | 0,23 % · 0,8 | 0,45 % · 0,3 |

La passe 2, qui mesure l'avant, a tourné pendant que le Mac, sur batterie
à 3 %, bridait ses cœurs : le Pulse installé, au même moment, faisait le
même travail (mêmes instructions par seconde) en trois fois plus de temps
processeur pour deux fois moins d'énergie. Toutes ses phases sont gonflées
d'autant ; les rapports tiennent : cachée avant = 10 fois cachée après,
cachée après ≈ fermée.

Une fenêtre cachée coûte désormais exactement une fenêtre fermée. Vu en
route, une première version du banc qui n'annonçait pas la fenêtre — la
cadence ne retombait donc jamais — : cadence ouverte seule, contenu vidé,
1,48 % sur les cœurs E. C'est l'essentiel du coût d'une fenêtre cachée ;
vider le contenu ne suffisait pas. Test
`laFenetreReglagesCacheeRepasseALaCadenceFermee` (une annonce par bascule,
contenu vidé, page gardée), fenêtre jamais affichée.

### Jalon 2 — taille du binaire (09 h 25 → 09 h 30)

Le binaire de SwiftPM, 9 214 408 octets : `__TEXT` 3,65 Mo, `__DATA_CONST`
0,10, `__DATA` 0,21, `__LINKEDIT` 5,36 — 95 185 symboles, dont 65 206
entrées de débogage (« stabs », la carte qui renvoie aux `.o` de `.build/`
pour `dsymutil`), et 3,6 Mo de chaînes. Essayé sur des copies :

| binaire | taille | symboles | rapport de plantage |
|---|---|---|---|
| tel quel | 9,2 Mo | 95 185 | fonctions nommées |
| `strip -S` (carte de débogage retirée) | 8,1 Mo | 29 978 | fonctions nommées |
| `strip -x` (symboles locaux retirés) | 4,2 Mo | 2 617 | adresses seules, sauf avec LE dSYM de cette compilation |
| `strip` | 4,2 Mo | 1 997 | idem |

`dsymutil` : 1,1 s, dSYM de 21 Mo (fichiers et lignes). Choix : la carte de
débogage ne sert qu'à `dsymutil`, et pointe sur des `.o` que la compilation
suivante réécrit — `build.sh` en tire `Pulse.app.dSYM` à côté du bundle
(non versionné), puis la retire du binaire installé (`strip -S`). La table
des symboles reste : Pulse est recompilé à chaque fusion, et un rapport
`.ips` d'une compilation précédente ne se lirait plus si les noms
n'étaient que dans un dSYM remplacé depuis. Le plafond de `./verifie.sh`
porte désormais sur le code et les données du binaire installé, 6 Mo pour
4,0 aujourd'hui : c'est ce qu'une ressource ou une bibliothèque embarquée
par erreur fait bondir ; les symboles, qui suivent le code, sont imprimés
sans plafond.

### Jalon 3 — carte Médias figée (09 h 30 → 09 h 40)

Elle restait vivante au rendu figé pour trois raisons : `Sampler(figé:)`
ne posait pas `medias` (la carte disait « mesure en cours ») ; son
`mediaTracker` créait au premier regard un `ExportHistory()` qui lisait le
vrai exports.json et le journal d'AME d'Isma ; et le graphique de la
semaine, la ligne « Dernier » comptaient leurs jours à partir de l'heure du
rendu. Désormais : `Releve.medias` et `Releve.exports` (une semaine type :
huit exports, un échec, un avertissement, l'export en cours et son
fichier), `ExportHistory(figé:)` en mémoire, sans fichier, et « aujourd'hui »
lu dans `Sampler.maintenantFige`, comme le forfait. La carte entre dans
`Rendu.cartesFigees`.

### Jalon 4 — débits disque dans l'historique (09 h 32 → 09 h 38)

Deux séries, `disques.lecture` et `disques.ecriture` : le débit total des
disques physiques, celui que le miroir des 3 min montre déjà, enregistré à
chaque relevé, panneau fermé compris (deux valeurs sous le verrou de
l'enregistreur, rien de plus), moyenné par 10 s. Graphique « Débit des
disques » au tableau de bord. Pas deux séries par disque : chaque disque
branché une fois en ouvrirait deux de plus pour 90 jours.

Place, mesurée (`HistoryTests.toutesLesSeriesTiennentSousCinquanteMo`, la
méthode du 02 : remplissage dans l'ordre d'écriture de l'app, puis purge
réelle) : les 14 séries de base, les 9 de modules au pire — capteurs (4),
énergie (2), calibration (1), débits disque (2), toutes relevées toutes les
10 s alors que l'énergie ne l'est que toutes les 5 min panneau fermé — et
trois volumes : sous 50 Mo à 90 jours (taille exacte : sortie du test, pas encore lancé — Mac sur batterie) sous
50 Mo.

### Jalon 5 — règles : copie de rushes, export nommé (09 h 35 → 09 h 45)

- **Copie de rushes terminée**, huitième préréglage, éteint : mesure
  `disques.copieTerminee`, un événement par épisode clos de genre « carte »
  ou « copie » (1 Go au moins, 60 s de calme), panneau fermé compris :
  « Copie de carte vers Ssd 2 · 128 Go en 14 min ». Le 05 ne publiait ses
  épisodes clos que panneau ouvert ; il les pousse désormais vers le fil
  principal (`DiskActivity.copiesTerminees`, 20 au plus) — quelques fois par
  jour, et seulement si `DiskActivity.ecouteCopies`, posé par le
  surveillant quand une règle allumée les demande. Règles éteintes : rien.
- **Export terminé** nomme le fichier et son issue : à la fin d'un export,
  le surveillant fait relire la fin du journal d'AME sur la file du relevé
  (`Sampler.exportsTermines`, la file où `MediaTracker` le lit déjà — jamais
  deux fils sur `ExportHistory`), garde l'événement un relevé, puis le dit :
  « Interview 6.mp4 · réussi · 4,2 Go », « Interview 6.mp4 · échec », « 3 fichiers ·
  1 échec : B.mp4 ». Sans ligne au journal ou sans réponse en 20 s : l'app et
  la durée, comme avant. Règle éteinte : aucune relecture.
- Tests (`SuivisReglesTests`, 6) : les textes, la fenêtre des fichiers d'un
  export, l'attente puis la réponse du journal, le repli à 20 s, une copie
  dite une fois et pas les téléchargements ni les exports, l'écoute
  posée et retirée avec la règle.

### Jalon 6 — endurance du Pulse installé, en fond

Lecture seule, du début à la fin du chantier : un relevé par minute de
`proc_pid_rusage` (temps CPU, empreinte, réveils, octets écrits) et de la
taille des fichiers de `~/Library/Application Support/Pulse`, `ps -o
time=,rss=` en recoupement toutes les 10 min, puis des fenêtres de 10 min ;
une fenêtre qui contient une relance ou commence dans les 3 premières
minutes d'un processus est écartée. Outils dans le bloc-notes de la
session (`endurance.swift`, `analyse.py`), rien d'installé.

Pulse installé de 09 h 09 (pid 3842, aucune relance pendant la mesure) :

| fenêtre (UTC) | âge | CPU, 1 cœur | réveils/s | écrit | empreinte | données |
|---|---|---|---|---|---|---|
| 09:19–09:29 | 10 min | 0,34 % | 1,23 | 19,8 Mo/h | 15,9–16,1 Mo | 1,84 Mo |
| 09:29–09:39 | 20 min | 0,33 % | 1,25 | 21,5 Mo/h | 16,0–16,1 Mo | 1,88 Mo |
| 09:39–09:49 | 30 min | 0,34 % | 1,27 | 20,0 Mo/h | 16,0 Mo | 1,91 Mo |
| 09:49–09:59 | 40 min | 0,89 % | 1,20 | 21,5 Mo/h | 16,0 Mo | 1,94 Mo |

Sur secteur, plat : 0,33 à 0,34 % d'un cœur, 1,2 réveil par seconde,
empreinte 16 Mo sans dérive (−0,3 Mo/h, du bruit), `ps` d'accord à la
seconde près (2,27 s à 09:19, 6,29 s à 09:39). Écrit ~20 Mo/h, presque
tout history.json réécrit chaque minute (300 ko) ; historique.sqlite
grossit de ~170 ko/h, la base de 24 h qui se remplit. La dernière fenêtre
n'est pas Pulse : à 09 h 51 le Mac est passé sur batterie à 3 % et a bridé
ses cœurs — mêmes instructions par seconde, trois fois plus de temps
processeur, moitié moins d'énergie (piège ajouté au README).

## Point à 10 h 05 — Mac sur batterie à 1 %

Tout est commité sur la branche, propre, une tâche par commit, `main`
fusionné dedans. NON fusionné dans `main` : `./verifie.sh` n'a pas tourné
sur cet état (5 min de calcul sur une batterie à 1 %, il aurait raccourci
le temps qu'il restait à Isma) ; le banc, les rendus (18 identiques) et la
compilation sans avertissement, si. Le test de taille à 90 jours et les
6 tests des règles sont écrits, pas encore lancés.
