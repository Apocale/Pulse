# 06-batterie — batterie, alimentation, Bluetooth

Départ : dimanche 11/10/2026, 04:23 (heure de la machine). Arrêt au plus tard
06:23, ou plus tôt si la mission est finie.

Branche `chantier/06-batterie`, fichiers à moi : `Sources/Pulse/Metrics/Power/`.

## Ce que la machine donne, relevé au départ (04:25)

Sur secteur (140 W USB-C), 74 %, « not charging ». Rien n'exige de droit
particulier, rien ne passe par le Bluetooth :

- `AppleSmartBattery` (IORegistry), lu en entier par un binaire signé ad hoc :
  niveau, capacités en mAh (d'origine 8 694, nominale 7 150, pleine charge
  actuelle 6 906), 359 cycles sur 1 000 prévus, tension, courant, et
  `PowerTelemetryData` — la puissance que tire la machine (77 W pendant un
  montage, recoupée par la clé SMC `PSTR` au même instant).
- `IOPowerSources` : état, temps restant, chargeur
  (`IOPSCopyExternalPowerAdapterDetails`), et — fonction privée
  `IOPSCopyPowerSourcesByType(4)` — les **accessoires** : AirPods Pro #3,
  écouteurs 100 %, boîtier 50 %. C'est la source du widget Batteries de macOS ;
  aucune autorisation Bluetooth n'est demandée.
- La santé qu'affiche macOS (81 %) vient d'une fonction réservée
  (`IOPSCopyPowerSourcesByTypePrecise` → `kIOReturnNotPrivileged`) : seul
  `system_profiler SPPowerDataType` la rend, 0,09 s de processeur par appel.

## Jalons

1. **Lecteur** (`Metrics/Power/`) : batterie, alimentation, accessoires, en
   fonctions pures sur des dictionnaires — testées sur ceux de cette machine.
   Section ÉNERGIE dans `--probe`, chaque valeur recoupée quand une seconde
   source existe.
2. **Carte « Énergie »** : anneau du niveau, anneau de la santé, lignes de
   détail, appareils. Rendue par `--snapshot x.png --carte energie`, sombre et
   clair, contraste mesuré. Échantillonneur à moi, à cadence propre, budget
   mesuré panneau fermé.
3. **Journée de charge** : le niveau des dernières 24 h en mémoire, prêt pour
   la base du 02 (une ligne quand elle arrive).
4. **Segment de barre de menus** optionnel, désactivé par défaut.
5. **Branchement** sur le registre du 01 dès qu'il est dans `main`.

## Journal

### Jalon 1 — lecteur, ÉNERGIE dans `--probe`, carte rendue (04:45)

Fait :
- `Metrics/Power/` : `PowerReader` (fonctions pures), `PowerMonitor` (appels
  IOKit), `PowerSampler` (cadence propre), `EnergyCard`, `PowerProbe`.
- Section ÉNERGIE dans `--probe` : niveau recoupé en mAh, santé selon macOS
  (81 %) et calculée (82 %), pleine charge (79 %), 359 cycles sur 1 000,
  température recoupée par `VirtualTemperature`, consommation, chargeur,
  mode d'énergie, AirPods Pro #3 (100 % · boîtier 50 %).
- `--snapshot x.png --energie` : la carte seule, sombre et clair, regardée.
  Contraste sur son fond (#393939 / #FBFBFB) : toutes les teintes entre 3,13
  et 5,09:1.
- 12 tests (`PowerTests`) sur les dictionnaires réels ; celui de la
  température vu échouer avec la lecture en centièmes.

Mesures :
- Température : dixièmes de kelvin, pas centièmes de degré (34,0 °C contre
  33,8 · 32,6 · 33,8 °C aux sondes SMC ; 30,7 °C en centièmes).
- Consommation : `SystemLoad` 76,9 W quand la clé SMC `PSTR` lisait 77,5 W.
- Coût d'une lecture (binaire isolé, 200 lectures) : batterie 1,12 ms de
  processeur, accessoires 0,07 ms. Panneau fermé (une lecture / 5 min) :
  0,0004 % d'un cœur ; ouvert (5 s et 30 s) : 0,023 %. `system_profiler` :
  0,09 s toutes les 6 h au plus.
- Aucune demande d'autorisation : ni IOBluetooth, ni CoreBluetooth.

Pas encore : la carte n'est pas dans le panneau — elle attend le registre du
01 (une ligne). L'app ne crée pas encore de `PowerSampler` : son budget est
inchangé.

Fusionné : 38b4730, `./verifie.sh` passé (42 tests, contraste 3,16:1 au plus
bas, rendus regardés).

### Jalon 2 — carte compacte, carte masquée à coût nul, « la batterie aide » (04:48)

Fait :
- `EnergyCard(compact:)` : titre et anneaux seuls, pour le réglage
  « compact » du socle. Rendu : `--snapshot x.png --energie --compacte`.
- `PowerSampler.update(enabled:panelOpen:)` : carte masquée, plus aucun
  relevé ; c'est l'appel que `stateDidChange` du registre fera.
- Santé de macOS lue une fois au lancement : sans cela, l'anneau passait de
  82 à 81 % sous les yeux d'Isma à la première ouverture.
- « Sur secteur, la batterie aide (12 W) » : le cas d'un export sur un
  chargeur trop faible. Seuil à 5 W : relevé sur ce Mac, sur secteur sans
  charger, un filet de −89 mA (1,1 W) à 114 W tirés d'un chargeur de 140 W,
  qui suffisait largement — afficher « la batterie aide » à 1 W était faux.
- Lignes réordonnées : alimentation d'abord (état, consommation, chargeur,
  mode), usure ensuite (température, cycles, pleine charge). Liste
  d'appareils et journée masquées quand elles sont vides.
- 14 tests `PowerTests`.

Prêt pour le registre du 01 (branche `chantier/01-socle`, pas encore dans
`main`) : `EnergyModule` tiendra en un fichier à moi et une ligne au
registre, `probeSection` remplaçant mes deux lignes de `Probe.swift`.

### Jalon 3 — la carte dans le panneau, par le registre du 01 (04:55)

Le socle est arrivé dans `main` (d374710) pendant le jalon 2.

Fait :
- `EnergyModule` (fichier à moi) inscrit en une ligne dans
  `ModuleRegistry.all`, colonne de gauche. Réglages déclarés : « AirPods et
  accessoires », « Charge de la journée » ; séries « charge » et « santé »
  à teinte réglable ; segment de barre « BAT / 74 % » fourni au chantier 09 ;
  `stateDidChange` → `PowerSampler.update` (carte masquée : coût nul) ;
  section ÉNERGIE de `--probe` par `probeSection`, mes deux lignes de
  `Probe.swift` retirées.
- `--snapshot x.png --carte energie` remplace mon `--energie` ; le rendu
  hors écran appelle désormais `ModuleRegistry.panelDidChange(open: true)`
  comme l'ouverture du popover, pour que les modules qui mesurent eux-mêmes
  aient leurs chiffres (une ligne dans `Snapshot.swift`).
- Les tests de disposition du socle vérifiaient le registre réel : toute
  inscription de module en cassait cinq. Ils portent maintenant sur les cinq
  cartes du socle, nommées (`ModuleRegistryTests.socle`).
- Ligne « Pleine charge » retirée de la carte (79 % sous un anneau à 81 %) ;
  elle reste dans `--probe`.

Mesures : panneau 626 × 987 pt (763 avant la carte, plafond 1 290) ;
`./verifie.sh` : 65 tests, contraste 3,16:1 au plus bas, tout passe.

Fusionné : 0a0f868.

### Jalon 4 — l'historique du 02, la consommation du SMC (05:27)

Le 02 (historique longue durée) et le 04 (capteurs) sont arrivés dans
`main` pendant le jalon 3.

Fait :
- Deux séries déclarées et alimentées : `energie.charge` (fraction, sur
  1) et `energie.consommation` (watts, sans dénominateur : la machine peut
  tirer plus que son chargeur). Panneau fermé, la consommation versée est
  la MOYENNE des 5 min, tirée du compteur de la jauge
  (`AccumulatedSystemLoad` / `SystemLoadAccumulatorCount`, un relevé par
  seconde) : relevé le 11/10, +5 640 086 mW sur 55 relevés, 102,5 W. Un
  instant tous les 5 min serait un tirage au sort entre deux pics d'export.
- Le graphique de la carte devient le `HistoryChart` commun (1 h → 90 j,
  survol), qui survit aux relances ; ma traînée en mémoire disparaît. Il
  s'ouvre depuis le titre de la carte, comme celui des disques : déplié
  d'office, il faisait passer le panneau à 1 316 pt (plafond 1 290).
- Consommation : la carte lit `PSTR` au SMC (le `SMCReader` du 04, sa
  propre connexion), comme la carte Capteurs. Avant, côte à côte, Énergie
  disait 93 W (jauge, rafraîchie toutes les 40 à 60 s) et Capteurs 103 W.
  `--probe` imprime les deux, et la moyenne du compteur.
- Les tests de disposition du socle ne cassent plus quand un chantier
  inscrit sa carte (jalon 3).
- 16 tests `PowerTests`.

Mesures (`./verifie.sh`, 05:21) : 113 tests ; panneau 626 × 1 216 pt ;
contraste 3,16:1 au plus bas ; banc 60 s : 0,88 % d'un cœur panneau fermé
estimés (plafond 1 %), 46 Mo, panneau ouvert 8,6 %. Un seul échec,
antérieur et commun : `historique.sqlite-shm` modifié dans la maison de
copie — reproduit par le 04 sur `main` pur avec un seul `--probe` (lecteur
SQLite en WAL qui réécrit l'index partagé) ; une `--snapshot` de cette
branche, lancée seule sur les vraies données, ne le modifie pas (vérifié).
À trancher par le 02 (`immutable=1` quand la persistance est coupée) ou le
03 (ne pas compter les `-shm`).

Fusionné : 91ab310.

## Pas vérifié, faute de situation réelle

- **Sur batterie.** Tout a été relevé sur secteur. À vérifier débranché :
  l'état « sur batterie · reste … », la consommation (SMC) contre tension ×
  courant de la jauge, le temps restant de macOS, l'historique qui passe à
  la charge, l'orange sous 20 %.
- **Casque Bluetooth tiers** (JBL TUNE 510BT, soundcore Liberty 4 NC, les
  deux appairés). Seuls des AirPods ont été vus dans les accessoires de
  powerd. Si un casque tiers n'y paraît pas, `system_profiler
  SPBluetoothDataType` donne son niveau sans demander d'autorisation (il
  porte le droit `com.apple.bluetooth.system`), mais coûte un processus :
  à ne brancher que si le besoin est vérifié.
- **Souris, clavier, trackpad Magic** : lus dans l'IORegistry
  (`BatteryPercent`), aucun n'était connecté.

## Vu en passant, pour la coordination

- `Sensors/SensorProbe.swift` (04) lit la clé `Temperature` de la jauge en
  centièmes de degré : la ligne de recoupement de CAPTEURS dit « 30 °C
  Temperature » quand la jauge en dit 31,6 (dixièmes de kelvin, voir le
  README). La carte Capteurs n'est pas touchée (elle lit le SMC).
- Un Pulse lancé par un agent a planté à 04:41:44 dans
  `SuiviSockets.demarrer()` (rapport `Pulse-2026-10-11-044150.ips`,
  EXC_BREAKPOINT 0,5 s après le lancement). Aucun autre plantage depuis.
- L'historique (02) ne garde pas l'unité d'une série en base : hors du
  processus qui la déclare, elle retombe en « nombre ». Dans `--probe`, où
  la section HISTORIQUE passe avant le registre des modules,
  `energie.charge` s'écrit « 1 » au lieu de « 74 % », `energie.consommation`
  « 82 » sans watts — et les `capteurs.*` du 04 pareil. Le graphique de
  l'app n'est pas touché (les séries y sont déclarées au lancement). À
  corriger côté 02 : garder l'unité avec le libellé et le total, ou faire
  déclarer les séries des modules avant HISTORIQUE.

Fusionné : 823f496 (system_profiler borné à 10 s, notes ci-dessus).
`./verifie.sh` à 05:34 : 119 tests, panneau 626 × 1 235 pt, contraste
3,16:1 au plus bas, banc 0,86 % d'un cœur panneau fermé ; seul échec,
l'antérieur `-shm`. Sur le rendu, Énergie et Capteurs disent la même
consommation (97 W).

## Ensuite

1. Sur batterie, une fois : relire ÉNERGIE dans `--probe` (voir « Pas
   vérifié »), puis ajuster ce qui diffère.
2. Casque tiers connecté : s'il manque, brancher `system_profiler
   SPBluetoothDataType` à faible cadence, panneau ouvert seulement.
3. Le segment « BAT / 74 % » est fourni au chantier 09 (`menuBarSegment`),
   qui le dessinera.

### Relance de la coordination — budget (05:40)

Le Pulse installé mesure 1,15 à 1,35 % d'un cœur, le banc 0,80 % : la
coordination demande le coût du module panneau fermé, et qu'il ne travaille
pas plus que nécessaire carte masquée ou panneau fermé.

- **Coût mesuré, panneau fermé : 0,0004 % d'un cœur.** Un relevé toutes
  les 5 min ; un relevé coûte 1,24 ms de processeur (test
  `unReleveResteBonMarche`, code réel, temps du fil, 40 relevés). Ouvert :
  0,025 % (5 s, accessoires toutes les 30 s). Hors de ce compte, un
  `system_profiler` au lancement (0,09 s, processus à part) puis toutes les
  6 h au plus, panneau ouvert seulement. Le banc de 60 s ne peut pas voir
  ce module : sa phase fermée dure 20 s, moins que la cadence.
- **Corrigé : une carte masquée créait quand même son échantillonneur.**
  `stateDidChange(enabled: false)` touchait l'instance paresseuse : une
  lecture complète, les accessoires et un `system_profiler` au lancement,
  pour l'arrêter aussitôt. Elle n'est plus créée tant que la carte n'est
  pas affichée (`EnergyModule.needsSampler`, test
  `uneCarteMasqueeNeCreeRien`).
- Panneau fermé, le module ne lit ni les accessoires, ni le Bluetooth, ni
  `system_profiler`, et n'a aucun abonné : la publication toutes les 5 min
  ne redessine rien. L'écart du Pulse installé n'est pas ici.
