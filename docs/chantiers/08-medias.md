# 08-medias — journal du chantier

Départ : dimanche 11/10/2026, 04:23 (heure du Mac).
Branche `chantier/08-medias`, worktree `agent-a5263be7e919c19fc`.
Arrêt au plus tard vers 06:23, travail commité.

## Relevés de départ (11/10, 04:25–04:35, Premiere fermé)

- **IOReport sans root** (`/usr/lib/libIOReport.dylib`, chargé par `dlopen`) :
  groupe « Energy Model » → `GPU Energy` (nJ), `AVE0` (encodeur vidéo,
  mJ), `MSR0` (scaler), `ANE0`, `ISP0`, `DRAM0`. « SoC Stats › Cluster
  Power States » → `AVEMSR` (INACT/ACT). « GPU Stats › GPU Performance
  States » → résidence OFF, P1…P15. Abonnement 2 ms, relevé 3 ms.
  **Aucun canal pour le décodeur (AVD) ni pour ProRes** : ni énergie, ni
  état. Ils ne seront pas inventés.
- **Fréquences du GPU** : `pmgr` › `voltage-states9`, couples (Hz, mV) :
  0, 444, 612, 808, 968, 1110, 1236, 1338, 1398 MHz. P1 → 444 MHz.
- **GPU par application** : chaque `AGXDeviceUserClient` porte
  `IOUserClientCreator` (« pid 451, WindowServer ») et `AppUsage` →
  `accumulatedGPUTime` en ns. 71 clients au repos.
- **Mémoire du GPU** : `PerformanceStatistics` › `In use system memory`
  (1,67 Go au relevé), `Alloc system memory`.
- **Journal d'AME** : `~/Documents/Adobe/Adobe Media Encoder/26.0/AMEEncodingLog.txt`,
  UTF-16, 3,4 Mo. 3 212 exports depuis le 25/03 (2 988 réussis, 212 avec
  avertissement, 12 échecs), chacun avec fichier de sortie, durée
  d'encodage, durée de la séquence, débit cible, heure de fin. 3 209 viennent
  d'une copie de projet Premiere (`/var/folders/…/T/*.prproj`) : la file
  d'AME est la voie d'export ordinaire d'Isma. Dernier : 03:54 ce matin,
  « Interview 5.mp4 », 4K, 8 min 09 d'encodage.
- **Cache média** : `com.Adobe.Common 26.0.plist` › `Media Cache` ›
  `FolderPath` = `~/Library/Application Support/Adobe/Common/`.

## Jalons

1. **Moteurs médias et carte graphique** — `Metrics/Media/` : IOReport
   (puissance GPU, fréquence moyenne, encodeur vidéo, scaler), mémoire du
   GPU, GPU par application. Lu panneau ouvert seulement. Section MÉDIAS de
   `--probe`. Coût mesuré.
2. **Historique des exports** — journal d'AME relu (seulement quand il
   change), exports observés par Pulse persistés dans `exports.json`
   (`decodeIfPresent`). « 3 exports aujourd'hui, 1 h 20 ». Tests.
3. **Cache média** — emplacement lu dans les préférences, taille calculée
   en tâche de fond, bouton Finder. Jamais de suppression.
4. **Carte Montage enrichie et carte graphique** — vue à moi,
   `--snapshot x.png --carte medias`, contraste mesuré.
5. **Export direct depuis Premiere** — outil de mesure prêt, demande exacte
   à Isma dans le rapport.

## Avancement

### Jalons 1 à 4, première passe (04:23 → 04:50)

Fait :
- `MediaEngines.swift`
  (`MediaMonitor`), `GPUClients.swift`, `ExportHistory.swift` (journal d'AME
  + `exports.json`), `MediaCache.swift`, `MediaTracker.swift` (branché sur le
  `Sampler` : 1 propriété publiée, 1 ligne par relevé), `MediaProbe.swift`
  (section MÉDIAS), `MediaCard.swift` (carte autonome).
- `--snapshot x.png --carte medias` : un cas dans `Snapshot.swift`.
- 8 tests dans `Tests/PulseTests/MediaTests.swift` (journal réel rejoué,
  UTF-16, ingestion idempotente, `decodeIfPresent`, export vu en direct qui
  cède au journal, table `pmgr` réelle, fréquence moyenne, créateur).

Mesures (11/10, Premiere ouvert, Claude occupe le GPU) :
- GPU par application : Claude 84 %, WindowServer 16 % — la somme colle à
  « Device Utilization » (100 %). Fréquence 1 398 MHz, 27,5 W, 2,2 Go tenus.
- Encodeur vidéo au repos : 0,00 à 0,01 W.
- Journal d'AME : 3 212 exports lus en 23 ms (209 ms puis 1,3 s sous charge
  avant la lecture en octets). Aujourd'hui 3 exports, 8 min ; 7 jours civils
  60 exports, 55 min.
- Cache média : 109 Go, 63 510 fichiers, dont 90,1 Go non modifiés depuis
  30 jours ; parcours 0,6 à 2,3 s selon la charge, au plus toutes les 30 min,
  panneau ouvert.
- Coût panneau fermé : un `stat` du journal, 69 µs par relevé à 5 s, soit
  0,0014 % d'un cœur. Ouvert : 4,4 ms par relevé à 1,5 s (IOReport + 71
  clients GPU).
- Contraste : aucune teinte nouvelle ; `outils/contraste.swift` inchangé
  (3,16 à 5,14:1).

Synchronisation avec main (04:55) : le chantier 04 a livré son propre
lecteur IOReport (`Sensors/IOReport.swift` : `IOReportSampler`,
`IOReportMath`, `DVFSTables`). Le mien est supprimé, `MediaMonitor` lit par
le sien — un seul code pour la même bibliothèque privée. `./verifie.sh` :
tout passe (48 tests, contraste 3,16:1 au plus bas, banc pas encore livré).

Seconde synchronisation (05:05) : le registre du 01 est dans main. La carte
s'y inscrit en une ligne (`MediaModule`, colonne de gauche sous Réseau), sa
section de `--probe` passe par `probeSection()`, la carte lit son contexte
(compacte, nombre d'apps, teintes « exports » et « gpu »). Le cas spécial
de `Snapshot.swift` est retiré au profit de `--carte medias` du socle. Le
moteur d'échantillonnage s'appelle désormais `MediaTracker`. Carte masquée
dans les Réglages : plus d'IOReport ni de clients GPU, même panneau ouvert.
Panneau complet : 626 × 1 101 pt (plafond 1 290).

### Jalon 5 : l'instrument de l'export direct (05:00 → 05:10)

`./.build/release/Pulse --probe --suivi-export [secondes] [--csv dossier]` :
toutes les 2 s, avec le code de l'app, la charge de Premiere, d'AME, des
`VTEncoderXPCService` / `VTDecoderXPCService`, l'encodeur matériel (W), le
GPU, TOUS les fichiers ouverts en écriture par les processus d'Adobe (sans
filtre, un second CSV note chaque chemin nouveau avec l'heure et le
processus), la taille du journal d'AME et la date d'`AMERequestDB`. Rien ne
s'ouvre, rien n'est écrit dans Application Support. `OpenFiles` gagne
`written(by:)`, la liste brute ; `mediaWritten` la filtre comme avant.

Essai à vide (05:03, Premiere ouvert, pas d'export) : Premiere 20 à 24 %,
AME absent, VTEncoder 1,4 à 1,7 % — **pas 0 %** comme le 25/08 : une autre
app encode (signal non attribuable, confirmé) —, GPU 80 %, encodeur matériel
0,005 W, 427 fichiers déjà ouverts en écriture par Adobe (panneaux CEP),
aucun fichier média. `AMERequestDB` daté de 03:54:14, à la seconde près la
fin du dernier export d'AME : Premiere y note ses envois à AME — à vérifier
s'il y note aussi un export direct.

Coût du module, panneau ouvert : 4,1 ms (moteurs, GPU) + 0,6 ms (fichiers de
4 processus) par relevé, + 6,6 ms toutes les 30 s pour retrouver les
processus. Les 60 `CEPHtmlEngine` de Premiere sont écartés (5,9 ms sinon).

**Ce qu'il faut d'Isma** (aucune détection ne sera écrite sans) : un export
réel lancé DIRECTEMENT depuis Premiere — voir le rapport.

### Panneau plein, budget (05:15 → 05:40)

- Les cartes Réseau (07), Énergie (06) et Capteurs (04) sont arrivées :
  panneau à 1 232 pt sans Médias, 1 449 avec (plafond 1 290). La carte a
  été resserrée (385 → 227 pt : une ligne par fait, fréquence et puissance
  du GPU laissées à la carte Capteurs, qui les affiche déjà — 1 384 MHz
  contre 1,39 GHz au même rendu), puis **masquée par défaut** : aucune
  colonne ne la loge. Elle s'active dans Réglages ; à rendre visible
  d'office quand le panneau passera à trois colonnes (socle, 01).
- Journal d'AME lu par la fin : les 2 derniers Mo au lancement, puis
  seulement ce qui s'ajoute (16 ko de recouvrement, ingestion idempotente).
  Mémoire après fermeture au banc : 52 → 46 Mo.
- Demande de la coordination (budget) : carte masquée, le module ne fait
  RIEN — ni `stat`, ni abonnement IOReport, ni `exports.json` chargé (tout
  est créé à la première utilisation) ; test `carteMasqueeAucunTravail`
  (1 000 relevés < 5 ms), vu échouer sans sa garde. Carte affichée, panneau
  fermé : un `stat` de 69 µs par relevé à 5 s (0,0014 % d'un cœur), la fin
  du journal relue à chaque export (~1 ms). Ouvert : 4,1 ms (IOReport, 71
  clients GPU) + 0,6 ms (fichiers de 4 processus) par relevé à 1,5 s,
  + 6,6 ms toutes les 30 s (liste des processus), + le cache média 0,6 à
  2,3 s toutes les 30 min en tâche de fond. Banc de 60 s, branche entière :
  0,83 à 0,89 % estimés, contre 0,81 à 0,89 % pour le Pulse installé de
  main mesuré aux mêmes secondes — l'écart est dans le bruit (charge
  machine 15 à 20).
- `historique.sqlite-shm` modifié pendant `verifie.sh` : défaut antérieur
  relevé par 04 (main pur échoue pareil) ; disparu après la synchronisation
  de 05:31.

### Carte Montage enrichie, sans un point de plus (05:40 → 05:50)

Demande de la coordination : le panneau fait 1 216 pt sur 1 290, la carte
Montage ne doit rien ajouter. La ligne « Export » devient dépliable, MÊME
hauteur (« aucun en cours · 3 aujourd'hui › », ou « Export Media Encoder
depuis 4 min › ») ; le dépliant montre tout le contenu de la carte Médias
(`MediaDetail` : semaine d'exports, dernier export, anneau GPU, mémoire
tenue, encodeur, application qui occupe le GPU, cache). Un seul dépliant
ouvert à la fois, comme les autres. Rendus : `--carte montage` et
`--carte montage --ouvert exports`. La carte Médias reste au registre,
masquée par défaut.

Budget, nouvelle règle du module : **panneau fermé, rien** (ni `stat`, ni
IOReport, carte affichée ou non — la fin du journal d'AME se relit à
l'ouverture, rien n'est perdu). Ouvert : le `stat` du journal (69 µs) pour
la ligne Export ; IOReport, clients GPU, fichiers et cache seulement si la
carte Médias est affichée ou le dépliant ouvert (`onAppear` /
`onDisappear`). Tests `panneauFermeAucunTravail` (1 000 relevés < 5 ms) et
`sansCarteNiDepliantPasDeMoteurs`. Les tests du module n'écrivent plus que
des fichiers jetables : un essai de 05:39, garde désactivée, avait créé le
vrai `exports.json` d'Isma (336 ko, les exports relus de son journal d'AME
— le fichier même que l'app créera). Laissé tel quel, rien d'autre touché.

## Bilan au 11/10, 05:55

Fusionné dans `main` (06075b0), Pulse réinstallé et relancé par
`outils/fusionne.sh`. `./verifie.sh` : tout passe (151 tests, panneau
1 216 pt, 10 rendus figés identiques, contraste 3,16:1 au plus bas, aucune
écriture ; banc complet : 0,82 % d'un cœur estimés contre 0,84 % pour le
Pulse de main aux mêmes secondes).

**Fait** : jalons 1 (GPU détaillé et encodeur, sans root), 3 (historique
des exports persisté), 4 (cache média), 5 (Montage enrichie, carte Médias,
instrument de mesure). **Bloqué** : jalon 2, la détection de l'export
direct depuis Premiere — il faut un export réel (voir le rapport).

**Ensuite** :
- relever un export direct avec `--probe --suivi-export 600`, puis une
  détection sur seuils mesurés (fichier de sortie tenu par Premiere,
  encodeur matériel), et l'export direct dans l'historique ;
- quand le panneau passe à trois colonnes (01), rendre la carte Médias
  visible d'office ;
- partager l'abonnement IOReport avec la carte Capteurs (deux abonnements
  aujourd'hui ; le mien seulement panneau ouvert, carte ou dépliant
  affichés).
