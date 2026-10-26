# 04-capteurs — journal

Départ : dimanche 11/10/2026, 04 h 22 (UTC+0 sur la machine). Limite : 06 h 22.
Branche `chantier/04-capteurs`, dossier `Sources/Pulse/Metrics/Sensors/`.

## Plan en jalons

1. **Lecteurs et relevé.** Lecture seule, sans sudo :
   températures par `IOHIDEventSystemClient`, ventilateurs et clés de
   température par le SMC (`AppleSMC`, commandes de LECTURE seulement : infos
   de clé, lecture, énumération — jamais l'écriture), puissance et
   fréquences par IOReport (`Energy Model`, `CPU Stats`, `GPU Stats`),
   pression thermique par `notify`. Section CAPTEURS dans `--probe`, chaque
   valeur recoupée par une source indépendante quand il y en a une (HID ↔
   SMC, batterie ↔ `AppleSmartBattery`, puissance des composants ↔ `PSTR`).
   Coût d'une lecture mesuré en temps CPU dans `--probe`. Tests de décodage
   SMC (octets → valeur) et IOReport (unités, résidences → fréquence).
   Correction de la doc : « températures = sudo » est faux.
2. **Carte Capteurs.** Trois anneaux (processeur, carte graphique,
   ventilateurs), puis Températures et Puissance en listes, noms en
   français regroupés (Processeur, Carte graphique, Mémoire, SSD, Batterie,
   Air). Autonome, prête pour le registre du 01 ; rendue avec
   `--snapshot x.png --capteurs`. Teintes de `Palette` seulement, contraste
   remesuré.
3. **Cadence et barre.** Lecture au rythme du panneau ouvert, toutes les
   30 s fermé ; budget < 1 % d'un cœur mesuré. Segment de barre de menus
   optionnel « CPU 62° », éteint par défaut, rendu hors écran.
4. **Branchement** au registre du 01 dès qu'il est dans `main` (une ligne).

## Avancement

### Jalon 1 — lecteurs et relevé (04 h 22 → 04 h 45)

Fait :
- `Sources/Pulse/Metrics/Sensors/` : `SMC.swift` (lecture seule, la commande
  d'écriture 6 n'existe pas dans `SMCCommand`), `HIDThermometer.swift`,
  `IOReport.swift` (+ tables DVFS du `pmgr`), `SensorMonitor.swift`
  (catalogue des clés, relevé), `SensorProbe.swift` (section CAPTEURS).
- Tout se lit SANS sudo, depuis le binaire compilé et signé ad hoc. Relevé
  sous charge (Isma travaille) : cœurs perf. 76 °C, eff. 77 °C, carte
  graphique 69 °C, SSD 31 °C, batterie 32 °C ; ventilateurs 4 342 et
  4 674 tr/min (81 % du max) ; processeur 19 W, carte graphique 9,7 W,
  mémoire 4,8 W, machine entière 70 W ; P 3,70 GHz, E 2,41 GHz, carte
  graphique 771 MHz ; pression thermique modérée.
- Recoupements : processeur 76 °C (12 cœurs) contre 75 °C (54 clés Tp,
  méthode macmon) ; carte graphique 69 contre 66 °C ; puce HID « PMU tdie »
  contre SMC TPD : **0,1 °C** d'écart ; SSD 31 / 30 °C ; batterie SMC 32,
  HID 32, AppleSmartBattery 33 °C ; PSTR 70 W contre 79 W en entrée secteur.
- Coût : 3,9 ms de CPU par lecture (médiane de 5) → 0,013 % d'un cœur à 30 s,
  0,26 % à 1,5 s. Création 375 ms, une fois.
- Piège trouvé : `.map(Double.init)` sur un UInt64 = `Double(bitPattern:)`
  (aucun ventilateur affiché). Test vu échouer sans la correction.
- 16 tests de décodage SMC / IOReport / DVFS / formats.
- Doc corrigée : « températures = sudo » était faux (CLAUDE.md, README).

Choix : les anneaux de la carte n'afficheront PAS la température — elle n'a
pas de dénominateur réel (règle dure n°7 : aucune limite thermique n'est
publiée, cherchée dans l'IORegistry). Processeur et carte graphique :
fréquence sur fréquence maximale (table DVFS) ; ventilateurs : vitesse sur
maximum d'Apple (`F0Mx`). Les températures vont en liste et en tête de carte.

Fusionné dans `main` à 04 h 46 (6f35513), `./verifie.sh` : tout passe.
Budget : inchangé — à ce jalon, l'app ne lit aucun capteur (seuls `--probe`
et `--snapshot` le font).

### Jalon 2 — carte Capteurs (04 h 46 → 04 h 55)

Fait :
- `SensorsCard.swift` : titre « Capteurs · Processeur 88 °C », trois
  anneaux à dénominateur réel (fréquence P / max DVFS, carte graphique /
  max DVFS, ventilateurs / somme des `F0Mx`, plafond écrit sous chaque
  anneau), pression thermique (pastille seule teintée), puis Températures,
  Puissance (« moyenne sur 1,5 s »), Ventilateurs. `SensorStore.swift` :
  file et minuterie propres, 1,5 s ouvert / 30 s fermé, lecteur créé sur la
  file. `SensorBarSegment` : « CPU » sur « 88° », éteint.
- `--snapshot x.png --capteurs` (+ `--light`, `--barre`) : une ligne dans
  `Snapshot.swift`. Rendus regardés, sombre et clair, sous forte charge
  (ventilateurs à 94 %, 113 W).
- Contraste sur les rendus de la carte : fond lu #393939 / #FBFBFB (celui des
  cartes du panneau), teintes de 3,13 à 5,09:1. Aucune nouvelle couleur.
- Défaut trouvé au rendu : à froid, machine chargée, la création du lecteur
  a pris 1,3 s et la lecture suivante est tombée 0,2 s après — puissance
  moyennée sur 0,2 s. IOReport ne rend plus d'écart sous 0,5 s (la
  référence est gardée), et `--snapshot --capteurs` attend la seconde
  lecture au lieu de 3,6 s fixes (un rendu clair était sorti sans
  puissance ni fréquences).

Fusionné dans `main` à 04 h 52 (560374c), `./verifie.sh` : tout passe.

### Jalon 3 — branchement au registre, cadence (04 h 52 → 05 h 05)

Le registre du 01 est arrivé dans `main` pendant le jalon 2.
- `SensorsModule.swift` : inscrit en une ligne (`SensorsModule(),` à la
  place de `// 04-capteurs`), colonne de gauche. `stateDidChange` règle la
  cadence : 1,5 s panneau ouvert, 30 s fermé, ARRÊT si la carte est masquée
  et le segment éteint. Carte compacte (anneaux et pression seuls) suivant
  le réglage du socle. Option « Température du processeur dans la barre de
  menus » (éteinte) → `menuBarSegment` « CPU 88° », sans `fraction`
  (pas de dénominateur réel). Section CAPTEURS fournie par
  `probeSection()` : retirée de `Probe.swift`.
- `SensorStore.shared`, piloté par le module ; `Snapshot.swift` prévient les
  modules que le panneau s'ouvre (une ligne), comme l'app.
- Défaut vu au rendu du panneau entier : anneaux « illisible », pas de
  puissance. La création du lecteur coûte 0,4 s de CPU, à 97 %
  l'abonnement IOReport (mesuré : SMC 0,1 ms, tables DVFS 0,6 ms, IOReport
  386 ms) ; la référence arrivait trop tard pour la lecture suivante. Une
  seconde lecture 0,6 s après la première règle le cas, en rendu comme dans
  l'app (premier relevé fermé, à 30 s du lancement).
- Une lecture : 4,2 ms de CPU, ~10 ms d'horloge (le SMC répond en
  quelques ms, sur la file des capteurs, jamais le main thread).
- Rendu du panneau entier avec Énergie (06) et Capteurs dans la colonne de
  gauche : 1 510 pt, plus que les 1 290 utiles. Capteurs passe à droite,
  paires de températures sur une ligne, Wi-Fi et détail par ventilateur
  laissés à `--probe` : 1 184 pt.

Fusionné dans `main` à 05 h 03 (9157c3e). `./verifie.sh` (avec le banc du
03, désormais) : tout passe — budget panneau fermé 0,86 % d'un cœur estimés
(0,41 % au banc + l'icône), plafond 1 %.

### Jalon 4 — coût de création, cadence testée (05 h 03 → 05 h 15)

- L'abonnement IOReport coûtait 390 ms de CPU : chaque
  `IOReportCopyChannelsInGroup` parcourt tous les pilotes (130 ms par
  groupe, mesuré). Une seule copie de tous les canaux, filtrée : création
  du lecteur 137–152 ms (`--probe`), puissance et fréquences inchangées.
- `SensorsModule.cadence(enabled:panelOpen:bar:)` extraite et testée : carte
  masquée sans segment → arrêt ; fermé → 30 s ; ouvert → 1,5 s.
- README : le piège IOReport (utile au chantier 08, qui lira les moteurs
  médias par la même voie).
- Historique longue durée (chantier 02, arrivé dans `main`) : quatre séries
  déclarées et alimentées à chaque lecture — `capteurs.processeur`,
  `capteurs.graphique` (°C), `capteurs.ventilateurs` (tr/min, sur le
  maximum d'Apple), `capteurs.puissance` (W, machine entière). Rien n'est
  écrit persistance coupée : `--snapshot --capteurs` laisse les données
  intactes (vérifié sur une copie de la maison, comme `verifie.sh`).

`./verifie.sh` à 05 h 20 : tout passe (102 tests, panneau 1 214 pt, budget
0,84 % d'un cœur estimés) SAUF « données de Pulse intactes » :
`historique.sqlite-shm` modifié. Défaut antérieur, pas de ce chantier :
`main` pur (d50a7be, construit à part) échoue pareil sur un seul `--probe`.
Un lecteur d'une base SQLite en WAL réécrit l'index partagé `-shm`, même
ouvert en lecture seule ; la copie de la maison le prend sur le vif pendant
que le Pulse installé écrit. À trancher par 02 (ouvrir en `immutable=1`
quand la persistance est coupée) ou 03 (ne pas compter les `-shm`, qui ne
sont pas des données).

Fusionné dans `main` à 05 h 21 (8c0b888, séries d'historique).

### Jalon 5 — historique dans la carte (05 h 21 → 05 h 40)

- Le titre de la carte ouvre l'historique des températures (moyenne des
  cœurs, carte graphique), plages 1 h → 90 j, par le graphique du 02 :
  courbe sur le maximum observé, jamais « sur 100 °C ». Rendu ouvert
  regardé (`--carte capteurs --ouvert capteurs`, lancé sur une COPIE des
  données : un lecteur de la base réécrit son `-shm`).
- Sous l'anneau des ventilateurs, « · imposée » si un logiciel a pris la
  main (`F0Md`) — pour le jour où le chantier 14 pilotera.
- Fusionné à 05 h 35 (cfada86) ; `./verifie.sh` : tout passe sauf le
  défaut `-shm` antérieur (ci-dessus).

Mesure réelle du Pulse installé, panneau fermé, temps CPU cumulé par
tranches de 30 s (une tranche écartée si une fusion a relancé l'app) :
**0,97 % d'un cœur** sur 300 s (main 8c0b888, tous chantiers fusionnés).
La part des capteurs : 4,2 ms toutes les 30 s = 0,014 %. Le total frôle le
plafond de 1 % : à surveiller par 15-audit-perf, ce n'est pas la lecture
des capteurs qui le porte.

### Jalon 6 — budget panneau fermé, demande de la coordination (05 h 37 → 05 h 50)

Le Pulse installé mesure plus de 1 % d'un cœur (coordination : 1,15 à
1,35 % sur 60 s ; ici 1,05 % sur 211 s, main cfada86). Ce que fait le module
quand personne ne regarde, vérifié et réduit :
- Panneau fermé : IOReport n'est plus lu du tout — puissance et
  fréquences ne servent qu'à la carte ouverte. SMC seul (historique,
  segment) : **0,6 ms de CPU toutes les 30 s = 0,002 % d'un cœur** (mesuré
  par `--probe`, médiane de 5), contre 4,4 ms avant (IOReport = 80 % d'une
  lecture : 3,6 ms, mesuré à part).
- L'abonnement IOReport (145 ms, une fois) n'est créé qu'à la première
  ouverture du panneau : avant, il tombait 30 s après le lancement, donc
  dans toute mesure « panneau fermé » de 60 s prise juste après une fusion
  (0,25 % d'un cœur sur une telle fenêtre).
- Carte masquée et segment éteint : aucune lecture (règle testée). HID n'est
  jamais lu par l'app, seulement par `--probe` pour les recoupements.
- À l'ouverture : référence IOReport, puis seconde lecture 0,6 s plus tard ;
  entre les deux, « mesure… » sous les anneaux, plus « illisible ».
- Ouvert : 4,4 ms toutes les 1,5 s = 0,29 % d'un cœur.

Défaut signalé par 06 : la ligne de recoupement batterie de `--probe` lisait
`Temperature` en centièmes de degré (30 °C) ; c'est en dixièmes de kelvin
(31,5 °C, comme `VirtualTemperature`). Corrigé avec la fonction du 06,
test ajouté (`lesDeuxTemperaturesDeLaBatterie`). La carte n'était pas touchée.

Pour le chantier 15 : le banc compte des phases de 20 s ; tout travail
périodique plus lent (capteurs 30 s, disques 2 min, incidents 2 min,
écritures de l'historique 1 min…) lui échappe, d'où une part de l'écart
banc / Pulse installé. Et une mesure de 60 s juste après un lancement
compte les créations (lecteurs, abonnements) : mesurer plusieurs minutes,
loin du lancement.

Fusionné dans `main` à 05 h 47 (d6bb4f8) ; `./verifie.sh` : TOUT PASSE
(134 tests, 10 rendus identiques à leur référence, budget estimé 0,83 %,
données intactes).

## Bilan (05 h 55)

Pulse installé après la dernière fusion (main d6bb4f8, tous chantiers),
panneau fermé, tranches de 30 s : **0,79 % d'un cœur** sur 271 s (contre
1,05 % sur 211 s à cfada86). La part des capteurs fermés : 0,002 %.

Fait : mission 1 à 5 — lecteurs sans sudo (SMC lecture seule, HID,
IOReport, notify), noms français par organe, recoupements dans `--probe`,
carte Capteurs au registre (anneaux à dénominateur réel, pression
thermique, températures, puissance, historique des températures), segment
« CPU 62° » en option, section CAPTEURS, 18 tests, coût mesuré et réduit.

Ensuite :
- Le segment « CPU 62° » s'allume dans Réglages › Capteurs ; il ne se
  dessinera dans la barre qu'avec le chantier 09.
- Le chantier 14 réutilise `SMCReader` (lecture) ; l'écriture reste à lui,
  par son helper.
- Pas de capteur de mémoire identifié sur ce M2 Max : rien d'affiché plutôt
  qu'une clé devinée. Le canal IOReport « GPU0 » lit plus que « GPU
  Energy » (retenu, comme macmon) : sens à établir.
- L'historique de la puissance (`capteurs.puissance`) est enregistré mais
  pas tracé : la place manque dans la colonne tant que le panneau est à
  deux colonnes.
- VoiceOver de la carte : arbre non relu à l'API (il faudrait ouvrir le
  panneau) — pour 16-audit-ux.
