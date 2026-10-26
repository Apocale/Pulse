# 02-historique — journal du chantier

Départ : dim. 11 oct. 2026, 04:22 (heure de la machine, `date`).
Arrêt au plus tard : 06:22, ou mission finie.

Mission : `missions.md`, section 02-historique. Base de séries temporelles
SQLite, plages 1 h → 90 j, composant graphique réutilisable avec survol.

## Principes

- L'historique d'Isma est précieux : aucune migration ne touche ses vrais
  fichiers avant d'avoir été prouvée sur des copies (dossier temporaire de la
  session). `history.json` n'est jamais réécrit par ce chantier : la base est
  un AJOUT, la série d'une heure de `HistoryStore` reste en place pour le
  verdict et les cartes.
- Une base illisible est déplacée sous un nom daté, jamais effacée.
- `Persistence.enabled == false` (`--snapshot`, `--probe`) : lecture seule,
  aucune création, aucune écriture.

## Jalons

1. **Moteur** (`Sources/Pulse/History/`) : schéma SQLite (libsqlite3 du
   système), trois étages — points bruts 10 s gardés 24 h, minutes 7 j,
   tranches de 10 min 90 j (moyenne, min, max, nombre) —, écriture groupée
   sur une file à soi, agrégation incrémentale, purge, mise de côté d'une base
   illisible. Tests : agrégation, purge, base corrompue, plages.
2. **Enregistrement** : catalogue des séries (processeur total, utilisateur,
   système, clusters P et E ; carte graphique ; mémoire apps, système,
   compressée, utilisée ; pression ; swap ; débit ↑ ↓ ; espace libre par
   volume) et API de déclaration pour les modules des chantiers 04 à 08.
   Branchement d'une ligne dans `Sampler`. Migration de `history.json`
   (série d'une heure + 30 jours de disques), prouvée sur une copie du vrai
   fichier. Section HISTORIQUE dans `--probe`.
3. **Lecture et composant** : API par plage (1 h, 24 h, 7 j, 30 j, 90 j),
   composant graphique (sélecteur de plage, survol valeur + heure, barres ou
   courbe, échelle à dénominateur réel — règle n° 7), exemple rendu par
   `--snapshot`.
4. **Mesures et fusion** : taille disque à 90 jours (remplissage simulé),
   coût CPU mesuré, budget panneau fermé, README et CLAUDE.md, fusion.

## Avancement

### Jalons 1 à 3 — fait (11/10, 04:22 → 04:57)

Code : `Sources/Pulse/History/` (SQLite.swift, SeriesDatabase.swift,
SeriesCatalog.swift, SeriesRecorder.swift, LegacyImport.swift,
HistoryChart.swift, HistoryProbe.swift). Branchements d'une ligne dans
`Sampler.swift` (5), `Probe.swift` (1 section), `Snapshot.swift`
(`--historique`).

- **Base** `historique.sqlite` : bruts 10 s / 24 h, minutes / 7 j, 10 min /
  90 j (moyenne, min, max, nombre). Agrégation sans état : chaque lot
  recalcule les tranches qu'il touche, jamais en deçà de ce que l'étage du
  dessous garde entier. WAL, `synchronous = NORMAL`, cache 512 Kio.
- **Écriture** : fenêtres de 10 s moyennées (seuil 9,5 s — la série d'une
  heure de history.json tombait à 14,85 s en médiane avec un seuil de 10 s
  pile), lot écrit toutes les 60 s sur une file à soi. Aucune minuterie
  ajoutée : les fenêtres se ferment au fil des relevés du Sampler.
- **Base illisible** : `quick_check` à l'ouverture ; renommée
  `historique.illisible-<date>.sqlite` (avec son -wal), jamais effacée ;
  une base d'un Pulse plus récent est lue, jamais écrite ni déplacée.
- **Migration** prouvée sur une COPIE du vrai history.json (288 ko,
  SHA-256 identique avant/après) : 196 points de série, 3 155 points de
  disque sur 6 volumes, 3 939 valeurs écrites, **3 939 retrouvées, 0
  absente**. history.json n'est ni réécrit ni déplacé.
- **Mesures** :
  - taille à 90 jours, 14 séries + 3 volumes, régime établi (remplissage dans
    l'ordre de l'app, puis purge réelle) : **21,4 Mo** (cible < 50 Mo) ; il
    reste la place de ~18 séries de modules relevées toutes les 10 s.
    Remplissage des pages mesuré à 88–91 % (dbstat), après rotation aussi ;
  - coût : une heure simulée (720 relevés Sampler, 1 800 relevés réseau,
    60 lots) sur une base qui porte déjà 24 h : **69 à 99 ms de CPU, soit
    0,002 à 0,003 % d'un cœur** (cible < 0,05 %). L'app mesure aussi son
    propre coût en continu (temps CPU des fils) et l'écrit dans la base :
    `--probe` le montre ;
  - contraste du composant (rendu `--historique`) : 3,13 à 5,09:1.
- **Tests** : 18 dans `HistoryTests` (agrégation, minute coupée entre deux
  lots, purge par étage, base illisible, base abîmée au milieu, base plus
  récente, colonne ajoutée après coup, lecture seule sans création,
  migration, import qui n'écrase rien, JSON illisible, plages et alignement
  sur l'heure locale, points pas encore écrits, échelle sans dénominateur,
  fenêtres de 10 s, vrais capteurs, taille, coût).

### Jalon 4 — synchronisation, documentation, fusion (05:00 → 05:15)

- `git merge main` (socle, banc, capteurs, disques, énergie) : un conflit,
  `Snapshot.swift`, les deux options gardées (`--capteurs`, `--historique`).
- `./verifie.sh` : TOUT PASSE (compilation, 85 tests, --probe 213 lignes,
  rendus 626 × 987 pt, contraste ≥ 3,16:1). Le banc n'est pas livré : coût de
  ma partie mesuré à part (ci-dessus).
- Un point de fenêtre est daté de son dernier relevé, plus de sa fermeture :
  une fenêtre ouverte avant une veille aurait daté du réveil des valeurs de
  la veille (test `uneVeilleNeDecalePasLesPoints`, 19 tests en tout).
- README (Diagnostic, deux pièges, Stockage) et CLAUDE.md (Fait), en fin de
  section.
- `--probe` sur le vrai dossier d'Isma avant fusion : « pas encore de base »,
  rien créé (vérifié par `ls`). Les rendus `--snapshot` non plus.
- **Fusionné** dans main (df4a963, 05:08). Pulse relancé : base créée,
  history.json repris — 283 points de série, 3 175 points de disque sur
  6 volumes, 4 307 valeurs. Vérifié sur des COPIES prises juste après
  (`verifie_import.py`) : chaque point antérieur à l'import est dans la base
  à sa valeur ; le seul écart signalé est une tranche de 10 min qui contient
  à la fois le point repris et le premier relevé vivant — moyenne des deux,
  min et max les montrent, c'est le comportement voulu.

### Jalon 5 — écrire moins sur le SSD (05:10 →)

- Mesuré (`ri_diskio_byteswritten` du processus, heure simulée sur une base
  de 24 h) : un lot par minute et une purge par lot écrivaient **19,3 Mo par
  heure** (464 Mo par jour) — autant que la réécriture de history.json
  (300 ko chaque minute, 432 Mo par jour). Chaque lot salit au moins une page
  par série et par étage, quelle que soit sa taille.
- Lot toutes les 5 min, purge une fois par heure : **6,9 Mo par heure**
  (166 Mo par jour), CPU 0,0013 % d'un cœur. Une coupure de courant coûte
  5 min de points au plus ; une fermeture normale, aucun (`flush`).
- Budget de l'app : le banc (`verifie.sh`) mesure 0,88 % d'un cœur panneau
  fermé, persistance coupée — donc SANS l'historique ; s'y ajoutent les
  0,0013 % mesurés ici.

### Jalon 6 — schéma 2 : les lecteurs n'écrivent rien, 2,9 Mo par heure (05:15 → 05:35)

- `verifie.sh` (maison de rechange, empreintes MD5) a vu une écriture dans
  `historique.sqlite-shm` pendant `--probe`, `--snapshot` et `--banc` : en
  WAL, un lecteur écrit ses marques dans `-shm`. Passage au journal de retour
  arrière, où un lecteur ne pose que des verrous ; une base encore en WAL se
  lit « immuable ». Tests `lireNEcritRienDansLeDossier`,
  `uneBaseEnWALSeLitSansRienEcrireEtSeConvertit` (contenu du dossier
  identique à l'octet).
- Le journal de retour arrière écrivait 16,1 Mo par heure avec la clé
  (s, t) : chaque série a ses pages, chacune écrite deux fois. Clé (t, s) :
  **2,9 Mo par heure** (69 Mo par jour). Lectures sur une base pleine de
  90 jours : 14 ms pour 90 j, 5 ms pour 30 j, 2 ms pour 24 h.
- Migration schéma 1 → 2 en une transaction (recopie ligne à ligne, puis
  renommage) ; en cas d'échec, annulée en bloc et retentée au lancement
  suivant. **Prouvée sur une copie de la vraie base** prise à 05:23 :
  7 916 lignes avant, 7 916 après, identiques ; copie inchangée (SHA-256).
  Test `laBaseDuSchema1PasseAuSchema2SansPerdreUneLigne` (1 660 lignes).
- **Fusionné** (abbbd6b, 05:35). Vraie base relue après relance : schéma 2,
  en-tête en journal de retour arrière (octets 18-19 = 01 01), toutes les
  séries là (cpu.total : 449 points bruts, contre 284 à 05:08 — rien de
  perdu, les nouveaux en plus). Un `historique.sqlite-shm` de 32 ko de l'ère
  WAL reste dans le dossier : SQLite ne s'en sert plus, je ne l'ai pas
  supprimé (fichier du dossier d'Isma).
- Les chantiers 04 (capteurs) et 06 (énergie) enregistrent déjà leurs séries
  par `History.declare` / `History.record`.

### Jalon 7 — unités des modules, budget (05:37 →)

- `--probe` affichait « 79 », « 4551 » pour les séries des capteurs : la
  déclaration d'un module ne vit que dans le processus de l'app. Le libellé,
  l'unité et le dénominateur d'une série déclarée sont désormais gardés dans
  la base (colonne `unit`, ajoutée en douceur) : `--probe` lit « 79 °C »,
  « 4 551 tr/min ». Test `uneSerieDeclareeGardeSonUniteDansLaBase`, vu
  échouer sans la correction (unité non transmise : 2 échecs), puis passer.
  Fusionné (8f28fef, 05:41) ; sur la vraie base, `energie.charge` s'écrit
  « 74 % » et `energie.consommation` « 91,4 W » dans `--probe`. Les séries
  `capteurs.*` prennent leur unité au lot suivant : le module des capteurs
  déclare ses séries à son premier relevé, après le premier lot. Vérifié à
  05:46 sur la vraie base : « 81 °C », « 85,2 W », « 4 289 tr/min », « 74 % ».
- Ce relevé a montré une colonne de `--probe` qui coupait « 4 671 tr/min »
  en « 4 671 tr/ » (`padding(toLength:)` tronque) : colonnes qui
  s'élargissent, test `leProbeNeTronqueAucunChiffre` vu échouer sans la
  correction.
- Budget (demande de la coordination) : l'historique n'a pas de carte et ne
  dépend pas du panneau. Panneau fermé, il ne fait que ce qu'il doit : un
  cumul en mémoire à chaque relevé du Sampler (déjà existant, pas de
  minuterie à lui) et un lot écrit toutes les 5 min. Mesuré : 0,0012 % d'un
  cœur (heure simulée, temps CPU des fils), et l'app le mesure elle-même en
  continu (ligne « coût mesuré » de `--probe`). Le graphique, quand il sera
  branché, ne se rafraîchit que tant qu'il est à l'écran (`.task` annulée
  à la fermeture). Au lancement, une fois : ouverture et `quick_check` d'une
  base pleine de 90 jours, 50 ms de CPU. Le banc tourne persistance coupée : il ne voit pas
  l'historique, mais 0,0012 % ne peut pas expliquer l'écart de 0,35 à 0,55 %
  entre le banc et l'app installée. Pistes, non mesurées, pour le chantier
  15 : ce que seule l'app installée fait — réécrire history.json (300 ko de
  JSON chaque minute), reseau.json —, et la cadence réelle de l'icône.
