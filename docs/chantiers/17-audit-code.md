# 17-audit-code — revue, nettoyage, sécurité, Swift 6

Départ : dimanche 11/10/2026, 07 h 30 UTC (`date` : 07:29:57). Limite :
09 h 30 UTC, ou plus tôt si la mission est finie ou bloquée.
Branche `chantier/17-audit-code`. Fichiers : ce journal, des tests de
non-régression (`Tests/PulseTests/`), des correctifs courts et localisés.
Pas de grand déplacement de fichiers tant que 09-barre et 16-audit-ux
tournent : la coordination dira quand.

## Plan en jalons

1. **Le helper des ventilateurs, avant qu'Isma l'installe.** Il tournera en
   root. Chaque entrée XPC, la vérification du client, les bornes, les
   replis, l'installateur, la désinstallation : relus ligne à ligne,
   corrigés s'il le faut, revue écrite ici.
2. **Revue du reste** : bugs, concurrence (files, verrous, fil principal),
   persistance (règle n°2), unités (n°3), cohérence `--probe` / interface,
   rien qui sorte sur Internet sans accord (IP publique du 07, météo du 18),
   aucune demande d'autorisation sans geste d'Isma. Correctifs localisés,
   chacun avec son test.
3. **Inventaire des API privées** (IOReport, NetworkStatistics, HID, SMC,
   AppleSmartBattery…) : le risque, le repli si macOS change.
4. **Un test de non-régression par piège du README** qui n'en a pas.
5. **Gros changements, sur feu vert de la coordination seulement** (09 et
   16 finis) : code mort (`UI/Rows.swift`, parties de
   `UI/DetailPanels.swift`, `UI/Cards/NetworkCard.swift`…), fichiers trop
   longs découpés, `swift-tools-version 6.0` et concurrence stricte —
   rendus, `--probe` et tests identiques avant et après.

## Journal

### Jalon 1 — le helper des ventilateurs, relu avant l'installation (07 h 30 → 08 h 15)

Relu ligne à ligne, sur la version de main c3cf8d0 (`geteuid`) :
`Daemon/main.swift`, `Installer.swift`, `SMCFans.swift`, `HelperLog.swift`,
`Kit/FanXPC.swift`, `FanController.swift`, `FanProtocol.swift`,
`FanCurve.swift`, `FanBytes.swift`, `FanSigning.swift` ; côté Pulse
`FanHelperService`, `FanPilot`, `FanProbe`, la page Ventilateurs.

**Verdict : bon pour l'essai réel, avec les correctifs ci-dessous.**

Corrigé :
1. **Un retour en automatique refusé restait imposé jusqu'au redémarrage.**
   Si le SMC refusait `F<n>Md = 0`, le contrôleur se disait quand même
   « automatique », le chien de garde s'arrêtait, et plus rien ne
   retentait : Pulse en mode Automatique n'envoie plus rien, et le helper
   sortait à vide 60 s plus tard. Désormais le ventilateur que le SMC relit
   imposé reste dans `pendingRestore` ; le chien de garde retente à 1 s,
   puis 2, 4… une minute au plus, le dit au journal quand il aboutit, et le
   helper ne sort pas tant qu'il en reste un. Trois tests, vus échouer sans
   la correction (retentative ôtée : 7 attentes fausses ; sortie à vide
   remise sur `isManual` : le helper sortait).
2. **Installation : la copie est vérifiée, pas seulement la source.** La
   signature `com.isma.pulse.helper` était lue sur le binaire du bundle,
   inscriptible par Isma, puis le fichier relu pour la copie : entre les
   deux, il pouvait changer. Elle est revérifiée sur la copie, dans le
   dossier de root, avant qu'elle ne prenne sa place.
3. **Un client refusé pour sa signature se lit au journal** (macOS 15 et
   plus). Avant, un Pulse refusé ne voyait qu'un helper muet, journal vide.
   Nouveau test de bout en bout : le processus des tests, qui n'est pas
   `com.isma.pulse`, est refusé par la vraie exigence XPC — aucune écriture,
   ligne au journal. Aucun test ne prouvait jusqu'ici que l'exigence
   s'applique. `codesign -R='identifier "com.isma.pulse"'` : Pulse.app la
   satisfait, le helper non.
4. `FanProtocol.plistName`, inutilisé, au commentaire faux, retiré.

Vérifié, rien à changer :
- **Entrées XPC** : entiers 64 bits seulement, clé par clé ; version 1,
  commande connue, 1 à 8 consignes de 0 à 100 000 ; toute autre forme →
  « mal formé », rien touché. Aucun client ne nomme une clé SMC : les noms
  sont formés d'un indice < `FNum` ≤ 8, quatre familles (`Md`, `Tg`, et en
  lecture `Ac`, `Mn`, `Mx`). Écriture limitée aux types `flt `/4,
  `fpe2`/2, `ui8 `/1, `flag`/1 ; octet de résultat du SMC lu.
- **Bornes** : minimum et maximum relus au SMC à chaque consigne, bornes
  absurdes refusées, NaN ramené au minimum puis borné.
- **Client** : uid effectif non root, propriétaire de `/dev/console`,
  exigence de signature posée avant `resume`. Côté Pulse, service du
  domaine système seulement (`MACH_SERVICE_PRIVILEGED`).
- **Replis** : connexion fermée, 15 s sans battement, veille (puis 10 s),
  pression thermique ≥ 2 (puis 10 min), SMC muet, budget, démarrage du
  helper, SIGTERM/SIGINT/SIGHUP ; `KeepAlive` sur sortie en échec.
- **Fichiers écrits en root** : dossiers relevés root:wheel 755 sur la
  machine (`/Library/Logs`, `/private/var/db`, `/Library/LaunchDaemons`,
  `/Library/PrivilegedHelperTools` en 1755) ; `O_NOFOLLOW`, `O_EXCL`,
  renommage ; journal écrit seulement dans un fichier ordinaire à root à un
  seul lien. Désinstallation : trois chemins fixes, `unlink`, sans suivre de
  lien. Rien n'est installé aujourd'hui (aucun des trois fichiers).
- **Mot de passe** : chemin échappé puis `quoted form of`, argument parmi
  deux fixes ; installation derrière une alerte, puis la demande de macOS.

Ce qui reste, à savoir avant l'essai :
- **Ad hoc** (aujourd'hui) : tout processus d'Isma peut se dire
  `com.isma.pulse`. Borné : régler les ventilateurs entre le minimum et le
  maximum d'Apple, ou désinstaller le helper. Connu (14).
- **Avec une identité « Apple Development »**, l'exigence d'équipe ne tient
  que si Pulse est AUSSI signé en runtime durci (`--options runtime`).
  Sans lui, un processus d'Isma lance le vrai Pulse avec
  `DYLD_INSERT_LIBRARIES` : son code tourne dans un processus signé par
  l'équipe et passe l'exigence. À faire dans `build.sh` le jour où
  `PULSE_IDENTITE` est posé, en vérifiant alors `sample` (chantier 15) et
  `do shell script` sous runtime durci.
- **Budget de 60 écritures par démarrage** : en Courbe, chaque pas de 5 %
  coûte 2 écritures ; une journée d'exports peut l'épuiser en moins d'une
  heure, puis automatique jusqu'au redémarrage. Sûr, mais à regarder à
  l'étape 5 de l'essai (`écriture(s) sur 60` dans `--probe`).
- **Battement** toutes les 5 s pour 15 s de délai : si macOS met Pulse en
  sieste (App Nap), « Pulse ne répondait plus depuis 15 s » apparaîtra au
  journal sans que Pulse ait quitté — chaque reprise coûte 4 écritures.
- SMC inaccessible au démarrage : `exit(70)`, relancé par launchd toutes
  les 10 s. Improbable, sans danger.
- Un retour refusé PENDANT l'arrêt (SIGTERM, désinstallation) n'est pas
  retenté : le helper sort. Le redémarrage rend la main à macOS.

Fusionné : 42d960b (07 h 51), `./verifie.sh` complet avant (budget
0,40 % d'un cœur estimés, 325 tests), revérifié sous verrou.

### Jalon 2 — revue du reste (07 h 50 →)

Cinq relectures en parallèle (persistance, unités et cohérence `--probe`,
sorties et demandes d'autorisation, concurrence, pièges du README), chaque
constat revérifié dans le code avant d'y toucher.

Corrigé, chacun avec son test (`AuditCodeTests`), vu échouer sans sa
correction :
1. **history.json élément par élément** (règle n°2). `AppRecord` gardait le
   décodeur synthétisé, et `apps`, `sessions`, `series`, `volumes` se
   lisaient chacun d'un bloc sous un `try?` : un seul enregistrement
   abîmé — ou le premier champ ajouté à `AppRecord` — vidait le tableau,
   que la sauvegarde suivante (au premier relevé) écrasait : 90 jours de
   temps par app ou de sessions. Désormais `Lossy` par élément,
   `decodeIfPresent` partout, une session sans nom prend son bundle.
2. **reseau.json** : lu d'un bloc (`as? [String: [String: [String: Any]]]`),
   tout tombait à la première valeur d'une autre forme, et le premier
   relevé réécrivait le fichier deux secondes après le lancement : 90
   jours de forfait effacés. Lu jour par jour, réseau par réseau ;
   illisible, mis de côté.
3. **exports.json** : une liste d'une autre forme ou un fichier qui n'est
   pas du JSON étaient chargés vides puis écrasés ; désormais mis de côté.
4. **Mises de côté** : chacune supprimait la précédente
   (`history`, `reglages`, `regles`, `disques`.illisible.json) — un second
   incident emportait la seule copie du premier. Une fonction commune
   (`Persistence.setAside`) garde le nom documenté pour la première,
   horodate les suivantes.
5. **La base SQLite saine n'est plus renommée** : TOUTE erreur à
   l'ouverture (base tenue ailleurs plus de 2 s, disque lent) la mettait de
   côté, par exemple sous les pieds d'une autre instance qui l'écrivait.
   Seule une base abîmée (`SQLITE_CORRUPT`, `NOTADB`) l'est ; sinon rien
   n'est écrit et l'enregistreur rouvre au lot suivant. Test : verrou
   exclusif tenu, la base reste en place, ses points aussi.
6. **`--probe` en lecture seule d'un bout à l'autre** : la persistance
   n'était coupée qu'à la dernière section. Avant elle, un fichier
   illisible aurait été mis de côté par un simple relevé, et
   `--probe --forfait 20` écrivait le forfait d'essai dans reglages.json.
7. **Rien ne sort sur Internet hors de l'app installée** : l'IP publique
   (api.ipify.org) et la sonde 1.1.1.1 étaient gardées par la
   persistance, que `--banc --ecrit` rallume — `./verifie.sh`, lancé avec
   une copie des vrais réglages, les aurait envoyées à chaque fois, option
   cochée. Même garde que la météo (`Extras.appReelle`).
8. **Unités de `--probe`** : pics de mémoire et de swap des sessions en
   base 1000 (règle n°3 : 30,1 Go dans `--probe` pour 28,0 Go au panneau) ;
   occupation des disques arrondie au plus près quand l'anneau, la barre et
   les widgets arrondissent vers le bas (« 95 % » à 94,6 %, règle 3 non
   partie) — même correction dans la phrase des règles.
9. **Une seconde instance s'arrête avant de créer son Sampler.** Le
   contrôle des jumeaux venait après : le Sampler, créé avec l'AppDelegate,
   ouvrait la base, relevait, et la sortie réécrivait history.json et
   reseau.json avec la copie lue au lancement (marques fantômes au journal
   des verdicts en prime). Contrôlé désormais dans `main`, avant tout ;
   l'ancien contrôle reste en renfort. Non testable sans lancer deux
   Pulse : relu, et le code de sortie est celui d'avant (un retour).
10. **Météo** : une requête annulée (carte masquée) rendait son échec
    après coup, effaçait la poignée de la requête suivante — d'où une
    requête en double possible, plus que « une toutes les 30 min » — et
    affichait un faux échec. Une annulation est désormais ignorée.
11. **Client XPC des ventilateurs** : une connexion interrompue était
    abandonnée sans être annulée (retenue par son gestionnaire) ; le
    client de « Désinstaller » n'était jamais fermé.
12. Les 21 avertissements du compilateur (`as? T` sans effet dans les
    décodeurs) disparaissent avec les décodeurs réécrits.

Vu, laissé à qui de droit (rien de cassé aujourd'hui, ou une décision) :
- **Le réglage « Débit en bits » ne faisait plus rien** (seule l'ancienne
  carte Réseau, plus inscrite au registre, le lisait) : corrigé entre-temps
  par le 16 (ea4356a).
- **La fenêtre Réglages compte comme un panneau ouvert même cachée** (derrière
  Premiere, réduite, autre bureau) : relevé à 1,5 s, capteurs, réseau,
  aperçu redessiné — plusieurs % d'un cœur au lieu de moins de 1 %, tant
  qu'elle n'est pas fermée. Le panneau détaché a déjà l'observateur
  d'occlusion qu'il faudrait (`FloatingWindow`). Non corrigé ici : rien ne
  se vérifie sans ouvrir la fenêtre sur l'écran d'Isma.
- **Moniteur réseau à deux écrivains** : le module (fenêtres visibles) et
  chaque `CarteReseau` (`onAppear`/`onDisappear`) règlent le même
  interrupteur ; popover refermé pendant que le panneau détaché montre la
  carte → section Connexion vide jusqu'au prochain changement.
- Tableau de bord réduit dans le Dock : `isVisible` faux, la cadence
  ouverte peut rester (à confirmer par `ps -o time=`).
- Un partage réseau (SMB) mort figerait le balayage des volumes, sur la
  file du relevé (débit de la barre et verdict figés) — non observé, Isma
  n'en monte pas aujourd'hui.
- Sonde Starlink (TCP 192.168.100.1:9200) au lancement et à chaque
  changement de réseau, sans réglage : adresse routée par la passerelle sur
  Starlink et sur le partage iPhone, donc pas « réseau local » pour macOS ;
  sur un réseau 192.168.100.0/24 (certaines box 4G), la demande « Réseau
  local » pourrait apparaître.
- Journal d'AME lu dans `~/Documents/Adobe/…` à la première ouverture du
  panneau (exports) : `~/Documents` est protégé par macOS ; en signature
  ad hoc, la demande « accéder au dossier Documents » pourrait revenir à
  chaque recompilation. Non observé (le journal de `tccd` n'est pas
  conservé) : demander à Isma s'il l'a vue.
- La série d'une heure de history.json garde `> 10 s` (un point toutes les
  ~15 s, piège du README) : sans effet visible, et 9,5 s grossirait le
  fichier réécrit chaque minute. Laissé tel quel, sciemment.
- `kern.memorystatus_vm_pressure_level` illisible → pression « normale »
  par défaut, sans le dire (la règle de pression ne peut plus partir).
- Le plafond de 10 Mo du binaire (`verifie.sh`) : 9,0 Mo ce matin, dont
  5,1 Mo de table des symboles (`__LINKEDIT`) ; il cassera sur la
  croissance normale du code. Mesurer `__TEXT` + `__DATA`, ou relever le
  plafond : à décider (03).

### Jalon 3 — inventaire des API privées

Aucun symbole privé n'est LIÉ : tous sont résolus à l'exécution
(`dlopen`/`dlsym`), donc aucun ne peut empêcher Pulse de se lancer. Le
risque est ailleurs : une fonction gardée mais dont la signature change
(appel indéfini), ou une clé qui garde son nom et change de sens (chiffre
faux sans erreur).

| API | Où | Si macOS change | Ce que Pulse montre alors |
|---|---|---|---|
| IOReport (`/usr/lib/libIOReport.dylib`) | `Sensors/IOReport.swift:61` | symbole absent → nil ; signature changée → appel indéfini, plantage possible ; unité d'énergie inconnue → nil | « IOReport indisponible » : puissance et fréquences absentes, le reste des cartes vit |
| Tables DVFS du `pmgr` (`voltage-states…`) | `IOReport.swift:257` | propres au M2 Max : longueur différente → « illisible » ; même longueur, autre sens → MHz faux, sans le dire | fréquences fausses |
| NetworkStatistics (cadre privé) | `NetworkPlus/DebitParApp.swift:238` | absent → « débit par app indisponible » ; clés renommées (`rxBytes`, `processID`, `rttAverage`) → liste vide SANS « indisponible » | apps et latence Internet passive vides |
| IOHIDEventSystemClient | `Sensors/HIDThermometer.swift:36` | absent → nil | recoupement des températures seulement |
| SMC (`AppleSMC`, sélecteur 2, message de 80 octets) | `Sensors/SMC.swift:109`, helper `SMCFans.swift` | disposition changée → appel en erreur → nil ; clé qui change de sens → valeur fausse | carte Capteurs sans températures ; helper : « le SMC n'a pas répondu », automatique |
| Plug-in `NVMeSMARTLib` | `DiskActivity/DiskHealth.swift:160` | appels à décalage fixe (24, 40), version non lue : une table changée sous le même UUID → mauvais appel (convention COM : peu probable) | santé « non publiée » |
| `IOPSCopyPowerSourcesByType` (type 4 privé), `IOPMCopyActivePMPreferences` | `Power/PowerMonitor.swift:72` | absent → « source indisponible » | accessoires (AirPods), mode d'énergie |
| Clés IORegistry : `AppleSmartBattery`, `PowerTelemetryData`, `PerformanceStatistics` | `PowerReader.swift:83`, `GPU.swift:21` | clé absente → « non disponible » ; unité changée → faux (le piège des dixièmes de kelvin) | — |
| `kern.memorystatus_vm_pressure_level` | `Memory.swift:89` | lecture échouée → « normale » par défaut, sans le dire | la règle de pression ne part plus |
| `com.apple.system.thermalpressurelevel` (notify) | `SensorMonitor.swift:196`, helper | nom changé → 0 « nominale », silencieux | le helper perd ce garde-fou (les autres restent) |
| libproc : `proc_pid_rusage` V2/V6, `PROC_PIDFDVNODEINFO` | `ProcessMonitor`, `WrittenDevices` | dans le SDK, versionnés, tailles vérifiées | sûr |
| `x-apple.systempreferences:…`, `AXExtrasMenuBar`, `kMDItemPhysicalSize` | conseils, `--probe`, Spotlight | échec doux | Réglages Système ouverts à l'accueil, etc. |

À surveiller à chaque mise à jour de macOS : `--probe` sections CAPTEURS
(« IOReport indisponible »), APPS du réseau (liste vide alors que du trafic
passe), ÉNERGIE (« source indisponible »). Le seul appel qui pourrait faire
planter Pulse sur un macOS nouveau est une signature IOReport changée ou une
table `NVMeSMARTLib` changée sous le même UUID.

Fusionné : 8de5b5c (08 h 06), `./verifie.sh` complet avant (335 tests,
0 avertissement au lieu de 21, budget 0,40 % d'un cœur), revérifié sous
verrou.

### Jalon 4 — un test par piège du README (08 h 07 →)

Le README compte 79 pièges, pas une cinquantaine. Relevé un par un : 25
avaient un test qui échoue si le bug revient, 12 un test partiel, 23
aucun alors qu'ils se testent, 19 ne se testent pas en `swift test`
(dessin de la barre, fenêtres d'AppKit, signature, ordonnanceur…).

Ajoutés (`PiegesTests`, `AuditCodeTests`), chacun vu échouer en
réintroduisant le défaut décrit par le README :
- Apple mélange les conventions d'unités (base 1000 / 1024) ;
- le CPU de Premiere ne dit pas s'il exporte (bornes du 25 août, pic
  isolé) ;
- la position d'une icône ne prouve pas qu'elle se voit, et les icônes
  sont des fenêtres de Control Center (`MenuBarRoom.place`) ;
- une prévision sans échéance ne dit pas que le volume se vide ;
- le mouvement est un ressort critique, jamais une durée fixe ;
- un `ForEach` aux identités en double : quatre Wi-Fi le même jour font
  une seule entrée ;
- une image disque se lit pleine à 100 % (`DiskMonitor.counts`, extrait
  tel quel de la boucle) ;
- le premier ping réveille la radio (`Ping.plusCourt`, extrait) ;
- les moteurs web des extensions de Premiere (`MediaTracker.ignore`,
  extrait) ;
- un boîtier qui ne relaie pas le SMART dit « non publiée », sans
  inventer ;
- un seuil de 10 s pile : des relevés un peu en avance donnent toujours un
  point par 10 s (le test d'avant, à pas exacts, ne voyait pas `>= 10`) ;
- le décodeur `Codable` synthétisé : sessions, points de disque, apps et
  séries de history.json (`AuditCodeTests`).
- `pti_total_user` n'est pas en nanosecondes : le processus des tests
  calcule 0,6 s sans s'arrêter, son groupe doit lire au moins 40 % d'un
  cœur (lu en nanosecondes : 2 %) ;
- le seuil de débit se règle par le bas : 12 h d'export à 30 Mo/s ne sont
  pas une copie (à 400 Go par jour, chaque intervalle était écarté) ;
- les batteries Bluetooth se lisent sans le Bluetooth : aucun fichier de
  `Sources` n'importe IOBluetooth ni CoreBluetooth. (Que leurs classes
  soient chargées dans le processus ne prouve rien : CoreWLAN et d'autres
  les chargent sans rien demander — vu en écrivant le test.)

Mutations : 14 défauts réintroduits un à un (scripts dans le scratchpad du
chantier), 14 tests rouges, puis le code rendu.

Ajoutés ensuite (08 h 25), le dossier devenu un paramètre (le vrai par
défaut, rien ne change pour l'app) :
- Adobe ne produit aucun `.ips` : les plantages se lisent dans la base
  Crashpad, les deux étapes (`pending`, `completed`), datés par l'attribut
  étendu, la version prise dans le chemin ;
- les diagnostics « disk writes » et « cpu usage » sont du bruit : seuls
  les JetsamEvent comptent, et seulement leurs victimes au motif
  inquiétant (les fichiers d'essai porteraient une victime chacun s'ils
  étaient lus). Quatre mutations, quatre tests rouges.

- `RegisterEventHotKey` attend une position de touche : sur l'ABC-AZERTY,
  le M du raccourci est la touche 41, pas `kVK_ANSI_M` (46) — vérifié sur
  les deux dispositions installées, sans toucher au clavier actif
  (`AppDelegate.keyCode(for:layout:)`, la disposition devenue un
  paramètre).

Restent sans test, et pourquoi :
- les deux dictionnaires de NetworkStatistics (`Source.decrire/compter`
  privés, une API privée à ouvrir) ;
- intégration lourde ou coût mesuré : empreinte `ri_phys_footprint`
  contre `pti_resident_size`, client SMART exclusif rendu, coût d'une
  copie IOReport, coût du journal d'AME, requête Spotlight ;
- partiels : `PopoverView.historyOwners` (chaque clé de dépliant a sa
  carte), le titre de l'élément de barre (`"\u{2009}"`) ;
- ne se testent pas en `swift test` (19) : dessin de la barre de menus,
  ancrage et redimensionnement du popover, `contentShape`, App Sandbox,
  signature (linkd, widget, SMAppService), écran mis à l'échelle,
  ordonnanceur (cœurs E du banc), fenêtre hors écran.

Fusionné : 186a280 (08 h 16), `./verifie.sh` complet avant (350 tests,
budget 0,41 % d'un cœur), revérifié sous verrou.

### Jalon 2 bis — `--probe` montre ce que montrent les cartes (08 h 17 →)

Règle du dépôt : un chiffre affiché se retrouve dans `--probe`. Il en
manquait trois, ajoutés dans leurs sections, par le même code que la carte :
- MÉMOIRE : le pourcentage de l'anneau de pression ;
- PROCESSEUR : la charge 1 · 5 · 15 min et le temps allumé ;
- PAR APPLICATION : le classement de la carte Mémoire, par empreinte — un
  Premiere au repos à 15 Go n'était pas dans les huit premiers par
  processeur.
Relevé : « pression modérée · anneau de la carte 32 % », « charge 31,04 ·
37,69 · 22,43 », « allumé depuis 4 h 40 », « par mémoire : Premiere
6,7 Go · Vivaldi 5,8 Go… ». Restent hors de `--probe`, cosmétiques : le
total du jour par réseau de la carte (rx + tx, et « iPhone ») et la
moyenne des ventilateurs de l'anneau (chaque ventilateur y est).

Vu en écrivant ces tests, pour le 16 (il travaille sur `PopoverView`) :
**le dépliant « Export » de la carte Montage n'est pas dans
`PopoverView.historyOwners`**. Ouvert, il ne compacte pas sa colonne comme
les autres : rendu hors écran (`--snapshot x.png --ouvert exports`), le
panneau passe de deux à trois colonnes (932 × 1 240 pt, la carte Capteurs
saute à droite), quand « session » garde ses deux colonnes (626 × 1 218 pt).
Rien n'est rogné ; une ligne à ajouter (`"exports": "montage"`).

### Jalon 5 — prêt, en attente du feu vert (16 encore actif)

Inventaire fait, rien de touché :
- **Code mort, chaque usage vérifié** (grep des types, dans `Sources` et
  `Tests`) : `UI/Rows.swift` entier (`MetricRow`, `Qualifier`,
  `Sparkline` : zéro usage hors du fichier) ; `UI/Cards/NetworkCard.swift`
  (`NetworkModule` et `NetworkCard` : remplacés par `ReseauModule`, cités
  seulement par `ModuleRegistryTests.socle`, à remplacer) ; dans
  `UI/DetailPanels.swift` (2 050 lignes), `MemoirePanel`, `GpuPanel`,
  `CoeursPanel`, `SwapPanel` et `ExportPanel` (~1 000 lignes, zéro usage) —
  `SessionPanel`, `AppsPanel`, `IncidentsPanel`, `VolumesPanel` et
  `TraceShape` restent.
- **Fichiers longs** après le code mort : `Verdict.swift` (720),
  `SeriesDatabase.swift` (638), `SettingsView.swift` (592),
  `CarteReseau.swift` (547), `PulseApp.swift` (539) ; à découper seulement
  là où un fichier porte deux sujets.
- **Swift 6** : une compilation à part (`-strict-concurrency=complete`,
  dossier de compilation séparé) relève 81 avertissements de concurrence
  hors des 21 `as? T` déjà corrigés : 41 captures non `Sendable` dans des
  fermetures `@Sendable` (gestionnaires XPC et minuteries des classes à
  file), 15 « sending » risqués, 11 appels au fil principal depuis un
  contexte non isolé, 12 propriétés statiques mutables, 6 variables
  capturées. Sampler (19), FanXPC (11), ExportHistory et DiskActivity (9),
  Store et DiskHealth (8) en tête. Une session de 1 à 2 h, fichier par
  fichier, rendus et `--probe` comparés avant et après.

Fusionné : 1f6e7c8 (08 h 40). Puis, feu vert de la coordination (16 fini).

### Jalon 5 — accessibilité, code mort, Swift 6 (08 h 41 →)

**Restes d'accessibilité du 16** (fusionné 518d9e8) : l'alerte qui arrive
dans la barre, panneau fermé, est annoncée à VoiceOver
(`announcementRequested`, une fois par alerte ; ni au lancement, ni les
avertissements, ni la cloche) ; les deux derniers conteneurs `.ignore`
(aperçu de la barre, 09 ; courbe des ventilateurs, 14) passent en
`.combine`. Deux tests : l'annonce, et plus aucun `.ignore` dans `Sources`.

**Code mort** (fusionné 518d9e8) : 1 300 lignes — `UI/Rows.swift`,
`UI/Cards/NetworkCard.swift`, et dans `DetailPanels.swift` (2 034 → 1 038
lignes) les panneaux mémoire, GPU, cœurs, swap et exports. Un relevé de
tous les types de premier niveau n'en trouve plus aucun sans usage. 16
rendus identiques, `--probe` à l'identique (459 lignes, 34 sections).

**`swift-tools-version 6.0` et concurrence stricte.** Toutes les cibles
compilent sous la vérification COMPLÈTE de Swift 6, zéro avertissement :
- classes confinées à une file ou à un verrou déclarées
  `@unchecked Sendable`, chacune avec sa règle écrite (Sampler,
  PowerSampler, SensorStore, DiskActivity, DiskJournal, SuiviSockets,
  MediaCacheProbe, AppTracker, et côté helper FanXPCServer et
  FanXPCClient) — les verrous et files relus un par un ;
- rappels `@Sendable` (XPC, sockets, cache média, notifications,
  calendrier), copies figées avant le passage au fil principal, valeurs
  lues sur une autre file rangées sous verrou (`Verrouille` dans les
  tests) ;
- aides de formatage pures des vues en `nonisolated`, constantes
  CFUUID et poignée `dlopen` en `nonisolated(unsafe)` ;
- `String(cString:)` sur un tableau, déprécié : `String(nulTerminated:)`,
  qui ne lit jamais au-delà d'un tableau plein.

**Mais le mode de langage reste Swift 5**, sciemment. En mode 6, le
compilateur pose aussi des vérifications d'isolation À L'EXÉCUTION
(SE-0423) : relevées au désassemblage, 784 fonctions de Pulse et 5 du
helper appellent `swift_task_reportUnexpectedExecutor`, qui arrête le
processus si une fermeture isolée au fil principal est rappelée ailleurs
par une API C ou Objective-C. Essayé à part : un gestionnaire
`notify_register_dispatch` formé au premier niveau — exactement celui de
la pression thermique du helper, et ses gestionnaires de SIGTERM — finit
en SIGTRAP (code 133) en mode 6, tourne en mode 5 (code 0). Le helper, en
root, se serait arrêté net à sa désinstallation au lieu de rendre la main
à macOS. Les tests, le banc et les rendus passaient pourtant en mode 6 :
ces chemins ne s'y exercent pas. D'où `swiftLanguageMode(.v5)` +
`StrictConcurrency` dans `Package.swift` : la vérification complète à la
compilation, aucun piège à l'exécution (aucun binaire n'importe plus
`swift_task_reportUnexpectedExecutor`), comportement identique. Le mode 6
attend une passe dédiée : rendre non isolées les fermetures données aux
API C et Objective-C (le code de premier niveau du helper d'abord), puis
vérifier chaque chemin d'événement (veille, pression thermique, signaux,
notifications, calendrier, réseau).

Vérifié : `./verifie.sh` complet, 355 tests, 16 rendus identiques,
`--probe` 459 lignes et 34 sections comme avant, budget 0,40 % d'un cœur,
binaire 9,2 Mo ; `PulseHelper --simule` : consigne bornée (4 000 / 5 777),
retour en automatique 15 s plus tard.

**Fichiers longs** : `DetailPanels.swift` est passé de 2 034 à 1 038 lignes
avec le code mort. `SettingsView.swift` (638 lignes, six types) est découpé
par simple déplacement : la fenêtre (110), la page générale avec le plan et
la mesure du panneau (`GeneralSettingsPage.swift`, 303), la page d'un
module avec le choix de teinte (`ModuleSettingsPage.swift`, 230) — chaque
ligne d'origine se retrouve une fois, seuls les `import` s'ajoutent.
`Verdict.swift` (720), `SeriesDatabase.swift` (649) et `PulseApp.swift`
(549) portent chacun un seul sujet : laissés entiers.

Fusionné : 1d14a7d et f39043d (09 h 09, Pulse réinstallé et relancé : il
tourne, 1,37 s de processeur sur ses six premières minutes, démarrage
compris, aucun rapport de plantage), puis 57321f1 (09 h 15).

## Bilan (09 h 15)

Mission faite, sauf le mode de langage Swift 6 lui-même (ci-dessus :
pourquoi, et ce qu'il faut d'abord).

Pour Isma, dans le rapport de la coordination :
- **Ventilateurs** : la revue du helper est faite, il peut être installé
  pour l'essai (étapes du 14). Pendant l'essai, regarder le compte
  « écriture(s) sur 60 » en mode Courbe.
- **Une question** : a-t-il déjà vu une fenêtre « Pulse souhaite accéder
  aux fichiers de votre dossier Documents » ? (le journal d'AME est lu dans
  `~/Documents/Adobe` à l'ouverture du panneau ; signé ad hoc, la demande
  pourrait revenir à chaque recompilation).
- **À effacer lui-même s'il veut** (inutiles, rien ne les lit) :
  `~/Library/Application Support/Pulse/historique.sqlite-shm` (reste d'une
  base passée en journal classique) et les deux dossiers d'essai
  `~/Library/Containers/com.isma.essaiwidget.app.widgets` et
  `~/Library/Containers/com.isma.essaiwidget.sonde`.
- **Le jour où il crée l'identité « Apple Development »** : signer aussi
  Pulse en runtime durci, sinon l'exigence d'équipe du helper se contourne.

Pour la coordination :
- `PopoverView.historyOwners` : ajouter `"exports": "montage"` (le
  dépliant Export fait passer le panneau à trois colonnes) — quand le choix
  A/B du rangement sera tranché.
- La fenêtre Réglages cachée garde la cadence ouverte (plusieurs % d'un
  cœur tant qu'elle n'est pas fermée) : un observateur d'occlusion, comme
  le panneau détaché.
- Plafond de 10 Mo du binaire (`verifie.sh`) : 9,2 Mo, dont 5 Mo de
  symboles ; il cassera sur la croissance normale.
- Le mode Swift 6 : une passe dédiée (fermetures données aux API C non
  isolées, code de premier niveau du helper dans une fonction), puis chaque
  chemin d'événement vérifié.

