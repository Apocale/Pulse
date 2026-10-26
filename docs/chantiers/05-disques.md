# 05-disques — activité, santé, ce qui remplit

Départ : dim. 11/10/2026, 04:22 UTC (`date` de la machine). Branche
`chantier/05-disques`. Fichiers à moi : `Sources/Pulse/Metrics/DiskActivity/`.
Retouches courtes ailleurs : `ProcessMonitor.swift` (écarts d'E/S par app),
`Sampler.swift` (un appel par relevé), `Probe.swift` (une section),
`Snapshot.swift` (une option de rendu).

## Ce que la machine dit (relevé du 11/10, avant tout code)

| Disque physique | BSD | Volume | Liaison | SMART sans root |
|---|---|---|---|---|
| APPLE SSD AP1024Z | disk0 | Macintosh HD | Apple Fabric, interne | **oui** — 33 °C, usure 3 %, 71,8 To écrits |
| SanDisk Extreme Pro 55AF | disk8 | Extreme Pro | USB | **oui** — 47 °C, usure 0 % |
| ASMT ASM246X (boîtier) | disk10 | Ssd 2 | USB | non : le boîtier ne relaie pas |
| Lexar E300 | disk6 | SSD 1 | USB | non |

- Compteurs d'E/S : `Statistics` de chaque `IOBlockStorageDriver`, cumulés
  depuis le branchement, lisibles sans privilège.
- SMART NVMe : plug-in `NVMeSMARTLib` (propriété « NVMe SMART Capable »),
  lu en 1 à 4 ms, sans mot de passe.
- Historique FSEvents : ~3 jours sur le disque interne, **moins de 6 h sur
  Ssd 2** — il repart de zéro au remontage. Ne peut pas, seul, dire ce qui a
  grossi en 7 jours.
- Ssd 2 : 58 000 fichiers, 84 % plein, « plein vers lundi » à 183 Go par jour.
  Un ffmpeg y fabrique des proxies pendant ce relevé : le disque travaille.

## Jalons

1. **Activité** — lecture et écriture par disque physique (IOKit) et par
   application (`ri_diskio_*`, écarts calculés dans le balayage existant).
   Section DISQUES de `--probe`. Tests du calcul de débit (compteur remis à
   zéro, disque débranché).
2. **Ingestion** — nommer une écriture massive : copie de carte, copie entre
   disques, téléchargement, export, avec la source, la cible, l'app, le
   volume écrit et la durée. Live, dans `--probe` et la carte. Tests sur des
   séquences fabriquées.
3. **Ce qui remplit** — par volume externe, les dossiers où sont arrivés le
   plus d'octets sur 24 h et 7 jours, d'après la date d'ajout de chaque
   fichier. Inventaire unique au premier passage, en tâche de fond bridée,
   puis incrémental par FSEvents. Jamais de parcours complet en boucle.
4. **Santé** — SMART NVMe : état, usure, température, écrits à vie. Les
   boîtiers qui ne relaient pas sont dits tels quels.
5. **Carte Disques** — vue autonome (`--snapshot x.png --disques`), prête
   pour le registre du 01 ; contraste mesuré ; budget mesuré.
6. **Branchement** sur le registre du 01 dès qu'il est dans `main`.

## Journal

### J1 — activité par disque et par app (04:22 → 04:40 UTC), fusionné (d89e478)

- `DiskIO` : compteurs `Statistics` des `IOBlockStorageDriver`, rattachés
  aux volumes en remontant l'IORegistry depuis le support du volume
  (`getmntinfo` en `MNT_NOWAIT` : aucun appel vers un volume réseau muet).
- `ProcessMonitor` : écarts `ri_diskio_bytesread` / `written` dans le
  balayage existant ; `ProcessGroup.diskRead` / `diskWrite` / `pids`.
- Mesures : 63 µs par relevé des compteurs (4 disques), soit 0,0013 % d'un
  cœur à 5 s ; carte volume → disque 1,8 ms, recalculée seulement quand les
  volumes changent ; balayage des processus 2,0 ms médian avant comme après.

### J2 — ingestion nommée et santé (04:40 → 04:52 UTC)

- `IngestionDetector` : épisode ouvert à 2 Mo/s sur un disque EXTERNE,
  clos après 60 s de calme, montré au-delà de 1 Go. Nature votée à chaque
  relevé, pondérée par les octets : carte (un disque amovible lit), copie (un
  autre disque lit), téléchargement (le réseau reçoit), export (un encodeur),
  écriture. Journal `disques.json` (30 j, tolérant, mis à jour chaque minute
  pendant un épisode pour que `--probe` le voie).
- Écrivain : l'app qui tient un fichier ouvert EN ÉCRITURE sur ce disque
  (`WrittenDevices`, `PROC_PIDFDVNODEINFO`, sans chemin). Le rapprochement
  des débits désignait Xcode (3,1 Mo/s, sur l'interne) pour des proxies
  ffmpeg sur Ssd 2 ; le test le reproduit et échoue avec l'ancienne règle.
  Coût : 0,04 ms (ffmpeg) à 1,1 ms (Premiere, 64 processus), lu seulement
  pendant une écriture massive, mis en cache 30 s.
- `DiskHealth` / `SMARTReader` : interne 29–33 °C, usure 3 %, 71,8 To
  écrits ; Extreme Pro 47 °C, usure 0 %. Ssd 2 et SSD 1 : « non publiée ».

### J3 — la carte (04:52 → 05:00 UTC)

- `DiskActivitySection` (mon dossier), branchée par une ligne dans
  `UI/Cards/DisksCard.swift` : épisode en cours ou dernier des 24 h, débit
  écriture/lecture et miroir des 3 min (60 cases de 3 s, rééchantillonnées :
  les relevés tombent à 5 s fermé, 1,5 s ouvert), apps qui écrivent, santé.
  Compacte : épisode et miroir seulement.
- `--snapshot x.png --carte disques`, sombre et clair, regardés ; panneau
  entier 626 × 1060 pt (plafond 1290) ; contraste inchangé (3,16:1 au plus
  bas) : seules des teintes mesurées de `Palette`.
- `swift test` : 23 tests dont 14 du chantier.

### J3 bis — SMART exclusif, section repliée (05:00 → 05:19 UTC), fusionné (2ab86d2)

- Le client SMART est exclusif : un second lecteur reçoit
  `kIOReturnNoResources` (0xe00002be), et un simple `Release` le garde tenu
  jusqu'à la fin du processus. `IODestroyPlugInInterface` + quatre
  tentatives en 0,5 s : trois `--probe` simultanés lisent les deux SSD
  (2/2/2, contre 0/1/1 avant).
- Les cartes de Capteurs (04) et d'Énergie (06) arrivées, le panneau tout
  déplié mesurait 1457 pt : la section se replie sur une ligne de débit
  (« écrit · lu ») et l'épisode en cours ; miroir, apps et santé dans le
  dépliant « activite-disques ». Panneau à 987 pt (1214 après les fusions
  suivantes).
- `./verifie.sh` complet : budget 0,82 à 0,91 % estimés (0,37 à 0,46 % au
  banc, + l'icône), plafond 1 %. Ma part, mesurée à part : 63 µs par relevé
  pour les compteurs, balayage des processus inchangé, SMART 1 à 4 ms toutes
  les 10 min — de l'ordre de 0,003 % d'un cœur.
- Échec de `./verifie.sh` hors de mon périmètre : `historique.sqlite-shm`
  modifié par `--probe`/`--snapshot` dans la maison de rechange (base SQLite
  du chantier 02, index WAL). Signalé dans le rapport.

### J4 — ce qui remplit (05:19 → 05:40 UTC)

- Parcourir Ssd 2 soi-même : abandonné, mesuré — 7 min 45 à priorité
  d'arrière-plan sans finir, ffmpeg lisant le disque. L'index Spotlight
  répond : 943 fichiers arrivés en 7 jours, 810 Go (Client A › 01 Rushes
  385 Go, Client B › 01 Rushes 349 Go), 29 Go en 24 h ; 0,27 s de
  processeur pour Pulse, 89 s d'attente de `mds` sur machine chargée.
- `SpotlightArrivals` + `FillReport` (deux niveaux, « Client › Catégorie »),
  requête toutes les 30 min sur sa propre file, la première 2 min après le
  lancement ; dernier bilan gardé dans disques.json et montré dans le
  dépliant et dans `--probe` (`--probe --remplissage` refait la requête,
  bornée à 20 s).
- Classement corrigé : un transcodage n'est pas une copie (le disque interne
  lisait 109 Mo/s pour d'autres pendant que Ssd 2 recevait des proxies).
- Tests : 4 de plus pour le bilan, 1 pour le transcodage.
- **Requête automatique coupée** (`DiskActivity.fillAutomatic = false`) :
  lancée par l'app elle-même, une requête sur un disque externe pourrait
  faire afficher à macOS « Pulse souhaite accéder aux fichiers d'un volume
  amovible » — interdit par le contrat du 11/10, et invérifiable sans en
  courir le risque. Mes essais tournaient depuis le terminal, dont ils
  héritent les droits. `--probe --remplissage` marche ; la carte montre le
  dernier bilan connu s'il y en a un. À rallumer sur accord d'Isma.

### Budget, à la demande de la coordination (05:40 UTC), fusionné (a507805)

Panneau fermé, ce que fait le module à chaque relevé (5 s) :
- compteurs IOKit des 4 disques, débits, miroir, détecteur d'ingestion :
  **209 µs par relevé** mesurés en temps processeur du fil
  (`CoutDisquesTests`, compilation de débogage — 63 µs pour les seuls
  compteurs en `-O`), soit **0,004 % d'un cœur** ;
- débit disque par app : les écarts `ri_diskio_*` dans le balayage existant,
  2,0 ms médian avant comme après (dans le bruit) ;
- SMART : **plus rien panneau fermé** (lu à l'ouverture, puis toutes les
  10 min tant qu'il reste ouvert ; 1 à 4 ms par SSD) ;
- fichiers ouverts (`WrittenDevices`) : seulement pendant une écriture
  massive sur un disque externe, 3 apps au plus, cache 30 s — 0,04 à 1,1 ms
  par app, ≤ 0,006 % ;
- balayage des dossiers : **aucun** ; la requête Spotlight est coupée (et,
  rallumée, 0,27 s toutes les 30 min, 0,015 % amorti, la première 2 min
  après le lancement) ;
- publication vers le main thread : **aucune** panneau fermé.
Carte masquée mais panneau ouvert : la vue n'existe pas, rien ne
s'abonne ; le modèle publie au rythme du relevé ouvert (1,5 s), sans
dessin. `./verifie.sh` complet : budget 0,75 % estimés (0,30 % au banc).

## État

Fait : J1 à J4, fusionnés. En attente : l'accord d'Isma pour la requête
Spotlight automatique ; un vrai épisode (copie de carte, téléchargement)
vu de bout en bout par l'app installée.
