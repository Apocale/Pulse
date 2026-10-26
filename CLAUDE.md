# Pulse — état du projet

Application de barre de menus macOS pour monteur vidéo (Adobe Premiere Pro).
Interface **en français**. Machine cible : MacBook Pro 16" M2 Max, 32 Gio,
**macOS 26.6.2 Tahoe** (SDK 27, Swift 6.4). Écran en résolution mise à l'échelle,
**2056 × 1329 points** — pas 1728. Clavier **ABC-AZERTY**.

Lis `README.md` avant de toucher au code : il documente une dizaine de pièges
vérifiés sur la machine, dont plusieurs correspondent à des bugs qui ont
réellement existé ici.

## Vérifier que tout marche

```
./build.sh                      # compile et signe Pulse.app (pas d'Xcode requis)
swift test                      # scénarios du verdict et de la prévision
./.build/release/Pulse --probe  # relevé texte de tous les capteurs
open Pulse.app
```

Si un chiffre est faux dans l'interface, il l'est aussi dans `--probe`. C'est le
point d'entrée du débogage, pas la capture d'écran.

Pour inspecter le popover sans cliquer : `./Pulse.app/Contents/MacOS/Pulse --show`
(ajouter `--light` pour l'apparence claire). La géométrie de la fenêtre est
imprimée sur stderr ; c'est elle qui fait foi, pas une largeur d'écran supposée.
Si l'utilisateur est en plein écran dans Premiere, capturer par identifiant de
fenêtre (`screencapture -l`).

**`--show`, le raccourci ⌃⌥M et les clics simulés ouvrent le popover sur l'écran
de l'utilisateur.** Il travaille pendant ce temps : ne pas le faire en boucle.
Préférer `--probe` pour les chiffres, l'API d'accessibilité
(`AXUIElementCopyAttributeValue`, pas System Events) pour l'interface, et
`./.build/release/Pulse --snapshot fichier.png` pour voir le panneau entier :
rendu hors écran avec les vraies mesures, rien ne s'ouvre, rien ne s'écrit
(`--light`, `--barre`, `--reseau` : voir le README). Après tout changement de
couleur ou de fond : `swift outils/contraste.swift sombre.png clair.png`.

L'état du lancement à l'ouverture de session ne se lit que depuis le bundle :
`./Pulse.app/Contents/MacOS/Pulse --probe`.

**`./verifie.sh` enchaîne tout cela** — compilation, tests, `--probe`, rendus
sombre et clair, contraste, budget — et sort en erreur si un seuil casse. C'est
lui qui fait foi avant une fusion ; sorties et images dans `.build/verifie/`.
Les cartes du socle, rendues sur un relevé figé, y sont comparées pixel à pixel
à `Tests/References` : après un changement d'aspect VOULU,
`./verifie.sh --references`, regarder les images, les commiter avec le
changement.

## Chantiers parallèles

Dix-huit chantiers tournent en parallèle, chacun dans son worktree, pour faire
de Pulse le tableau de bord ultime. **Toute session qui travaille dans un
worktree lit `docs/chantiers/README.md` avant de commencer** : la carte des
chantiers, les fichiers que chacun possède, la fusion en avance rapide dans
`main`, les vérifications et les interdits.

## Fait

- Socle live : mémoire et pression, swap, CPU par cluster P/E, GPU, volumes
  avec prévision de saturation sur 72 h. La pente est estimée intervalle par
  intervalle, les opérations en masse écartées : une régression globale
  inversait le signe sur un disque qu'on venait de vider (piège documenté).
- CPU et mémoire **par application**, processus auxiliaires agrégés (`libproc`).
- Temps par application et sessions de montage, persistés 90 jours.
- **Détection d'export** sur la charge de Media Encoder, seuil à 60 % d'un cœur
  posé entre deux bornes mesurées (repos ≤ 31 %, export 102-231 %). Le CPU de
  Premiere est inutilisable : son maximum au repos dépasse son maximum en
  export. Affichée dans le popover et dans `--probe`. Non persistée.
- Incidents : plantages Adobe via la base Crashpad + processus tués par macOS
  faute de mémoire. Les rapports « disk writes » et « cpu usage » sont écartés :
  ils décrivent un montage ordinaire (12 « CPU saturé », zéro panne).
- Interface conforme aux métriques macOS, palette validée par mesure de
  contraste dans les deux apparences, accessibilité VoiceOver.
- Mouvement : un ressort critique unique (`UI/Motion.swift`), réponse 0,4 s,
  qui suit « Réduire les animations » de macOS.
- **Refonte du popover** (`docs/refonte-ui.md`) : un **verdict** en tête — douze
  règles à l'ordre figé, hystérésis 3 s / 10 s, réfutable par sa ligne de preuve
  et par `--probe` —, puis une seule grammaire de ligne (`UI/Rows.swift`), quatre
  abscisses fixes, sparklines de la dernière heure, **une seule barre** dans tout
  le panneau. 1380 pt de haut avant, ~450 après.
- **Dépliants graphiques** : chaque ligne s'ouvre sur un graphique
  (`UI/DetailPanels.swift`), dont l'historique processeur et GPU et les 30 jours
  d'espace libre, collectés depuis toujours sans être affichés. Les explications
  vérifiées passent en infobulle.
- **Raccourci global ⌃⌥M**, qui ouvre le popover même par-dessus Premiere en plein
  écran. Touche résolue depuis la disposition active (AZERTY).
- **Lancement à l'ouverture de session** (`SMAppService`), enregistré une seule
  fois pour qu'un retrait dans Réglages Système tienne.
- **Journal des verdicts** (`verdicts.jsonl`) et son bilan dans `--probe`, pour
  calibrer les seuils sur des données.
- Accessibilité relue à l'API : verdict, lignes et boutons nommés.
- **Internet** : débit en direct dans la barre de menus (↑ envoyé, ↓ reçu,
  empilés, largeur figée) et consommation du jour par réseau dans le panneau —
  partage iPhone et Starlink reconnus sans autorisation de localisation.
  `reseau.json`, ce Mac seulement. Compteurs 32 bits imposés par macOS : écarts
  modulo 2³² (piège documenté).
- **Raccourci fiabilisé** : la bascule regarde ce qui est visible, pas
  `isShown` ; chaque ouverture est journalisée (`raccourci.log`, bilan dans
  `--probe`).
- **Pulse léger** (09/10) : panneau fermé, 8,2 % d'un cœur et 238 Mo avant,
  0,84 % et 66 Mo après une ouverture réelle. Le contenu du popover n'existe
  que pendant l'ouverture ; disques toutes les 2 min panneau fermé ; processus
  identifiés une fois ; libellé redessiné seulement s'il change. Cible tenue :
  moins de 1 %. Toute nouveauté doit la garder — mesurer avant de committer.
- **Verdict fiable** (09/10) : un nouveau verdict ne remplace l'affiché que
  s'il gagne depuis 5 min, sauf aggravation (35,7 → 7,3 changements par jour,
  rejoué sur le journal) ; chiffres d'une règle tenue datés dans la preuve.
  Prévision : le plus lent des rythmes 72 h / 24 h (« Ssd 2 plein dans ~8
  jours » sur un disque immobile). Volumes en lecture seule écartés (images
  d'installation). Neuf scénarios dans `swift test`, chacun vu échouer sans
  sa correction.
- **Façon iStat Menus, livraison 1** (11/10) : panneau à deux colonnes de
  cartes (Processeur, Réseau | Mémoire, Disques, Montage), anneaux, historique
  en barres, graphique miroir du débit, apps avec icône, barre de raccourcis ;
  barre de menus combinée « MÉM / disque / débit ». Nouvelles mesures :
  pression en %, charge, temps allumé. Mémoire en « Go » (base 1024 inchangée).
  Fond sombre #1E1E1E et contrastes remesurés. Relevé d'iStat : vidéo d'Aim
  Apple et bjango.com. **À faire** : activité disque (lecture/écriture, par
  app), températures.
- **Capteurs, jalon 1** (11/10, chantier 04) : températures, ventilateurs,
  puissance, fréquences et pression thermique, **sans sudo** — SMC en lecture
  seule (la commande d'écriture n'existe pas dans le type), HID, IOReport,
  `notify`. Section CAPTEURS de `--probe`, chaque valeur recoupée quand une
  seconde source existe (puce : HID et SMC à 0,1 °C). Une lecture : ~4 ms de
  CPU. Seize tests de décodage (`SensorDecodingTests`).
- **Socle, jalon 1** (11/10, chantier 01) : registre de modules
  (`Sources/Pulse/Modules/`, un module = une ligne dans `ModuleRegistry.all`,
  une ligne réservée par chantier), une carte par fichier (`UI/Cards/`),
  disposition calculée sans vue (`Layout`), réglages tolérants
  (`Settings/`, `reglages.json`). Rendu identique, vérifié pixel à pixel dans
  le même processus. `--snapshot x.png --carte <id>`, section MODULES de
  `--probe`.
- **Socle, jalons 2 et 3** (11/10, chantier 01) : tout se règle dans la
  **fenêtre Réglages** (clic droit sur l'icône, bouton ⚙ du panneau, ⌘,) :
  cartes affichées, ordre (glisser dans la barre latérale), 1 à 3 colonnes
  (glisser d'une colonne à l'autre), cartes compactes, nombre d'apps,
  couleur de chaque série (refusée sous 3:1, ratio affiché), cadence
  (jamais sous 5 s panneau fermé), débit en octets ou en bits, export et
  import. Aperçu en direct de chaque carte. Réglages par défaut : rendu
  identique au pixel près.
- **Énergie** (11/10, chantier 06) : carte `energie` dans le panneau —
  charge et santé en anneaux (81 %, le chiffre des Réglages, lu par
  `system_profiler`), état, consommation (SMC `PSTR`, le chiffre de la carte
  Capteurs), chargeur, mode d'énergie, température, cycles, AirPods et
  accessoires ; historique (séries `energie.charge` et
  `energie.consommation` du 02) dépliable depuis le titre. Rien ne passe par
  le Bluetooth : les accessoires viennent de powerd
  (`IOPSCopyPowerSourcesByType`), aucune autorisation demandée. Température
  de la jauge en dixièmes de kelvin (piège documenté). « Sur secteur, la
  batterie aide » au-delà de 5 W. Section ÉNERGIE de `--probe`, 18 tests
  (`PowerTests`). Coût mesuré : 0,0004 % d'un cœur panneau fermé, rien carte masquée ;
  banc complet 0,88 %. **Pas vérifié sur batterie** ni avec un casque tiers
  (JBL, soundcore) : voir `docs/chantiers/06-batterie.md`.
- **Historique longue durée** (11/10, chantier 02) : `historique.sqlite`
  (`Sources/Pulse/History/`, libsqlite3 du système) — points de 10 s gardés
  24 h, minutes 7 j, tranches de 10 min 90 j (moyenne, min, max). Processeur
  (total, utilisateur, système, P, E), carte graphique, mémoire (utilisée,
  apps, système, compressée), pression, swap, débit ↑↓, espace libre par
  volume. Un module ajoute sa série en deux lignes (`History.declare`,
  `History.record`) ; `HistoryChart(keys:)` la trace avec plages 1 h → 90 j
  et survol. history.json repris une fois, prouvé sur une copie (3 939
  valeurs, 0 perdue), jamais réécrit ; une base illisible est renommée,
  jamais effacée. 21,9 Mo à 90 jours, 0,0012 % d'un cœur, 2,9 Mo écrits par
  heure (schéma 2 : clé (temps, série), journal de retour arrière, lots de
  5 min, purge horaire ; 19,3 Mo pour la première version). Les lecteurs
  (`--probe`, `--snapshot`, `--banc`) n'y écrivent pas un octet. Section
  HISTORIQUE de `--probe`, `--snapshot x.png --historique`, 22 tests
  (`HistoryTests`, plus trois outils qui travaillent sur des copies). Les
  séries des modules gardent leur unité dans la base : `--probe` les écrit
  comme la carte.
  **À brancher** : le graphique dans les dépliants des cartes (registre du
  socle) ; il n'est montré nulle part dans le panneau pour l'instant.
- **Réseau avancé** (11/10, chantier 07) : `ReseauModule` remplace la carte
  réseau du socle, même identifiant. Connexion (passerelle par ping ICMP local
  SUR RÉGLAGE — macOS 15 peut demander l'accès au réseau local —, Internet
  PASSIF sur le RTT des connexions TCP en cours : rien n'est envoyé),
  signal Wi-Fi sans autorisation de localisation, IP locales et DNS, débit par
  app (NetworkStatistics, privé), forfait iPhone : jauge au vrai dénominateur
  une fois réglé, consommation par jour du cycle, rythme, « épuisé vers le… »,
  seuils 80 % / 100 % (`NiveauForfait`, `Sampler.forfait`) pour le chantier
  11. IP publique et ping Internet désactivés par défaut. Sections FORFAIT
  IPHONE, CONNEXION, WI-FI, APPS, COÛT de `--probe` ; 18 tests dont le
  rebouclage des compteurs 32 bits et le plantage du 11/10 à 04:41
  (`SuiviSocketsTests`). Coût : 0 panneau fermé (vérifié par `sample` sur le
  Pulse installé), 0,26 % d'un cœur panneau ouvert (banc de 60 s).
- **Carte Capteurs** (11/10, chantier 04) : `SensorsModule`, colonne de
  droite. Trois anneaux à dénominateur RÉEL — fréquence des cœurs
  performance et de la carte graphique sur le haut de leur table DVFS,
  ventilateurs sur le maximum d'Apple (`F0Mx`) ; pas d'anneau de
  température, aucune limite thermique n'étant publiée (règle n° 7).
  Pression thermique, températures par organe, puissance (processeur, carte
  graphique, moteur neuronal, mémoire, machine entière). Lecture 1,5 s
  panneau ouvert (SMC + IOReport, 4,4 ms : 0,29 % d'un cœur), 30 s fermé
  (SMC seul, 0,6 ms : 0,002 %), rien si la carte est masquée ; abonnement
  IOReport créé à la première ouverture. Option « CPU 62° » pour la barre de
  menus (éteinte). Quatre séries dans l'historique (`capteurs.*`), le titre
  de la carte ouvre celle des températures.
  `--snapshot x.png --capteurs`, 17 tests (`SensorDecodingTests`).
- **Médias, livraison 1** (11/10, chantier 08, `Metrics/Media/`) : carte
  Médias au registre (`MediaModule`, colonne de gauche, 227 pt,
  `--snapshot x.png --carte medias`) : exports de la semaine relus dans le
  journal d'AME (3 212 depuis le 25/03, 23 ms) et persistés dans
  `exports.json`, anneau GPU, mémoire tenue par le GPU, encodeur vidéo
  matériel (IOReport, sans root), application qui occupe le GPU (temps GPU
  des `AGXDeviceUserClient`), cache média (emplacement lu dans
  `com.Adobe.Common`, 109 Go dont 90 dormants, bouton Finder, jamais de
  suppression). Fréquence et puissance du GPU dans `--probe` seulement : la
  carte Capteurs les affiche. Section MÉDIAS de `--probe`. Panneau fermé :
  un `stat` de 69 µs par relevé. `--probe --suivi-export [s]` : l'instrument
  de l'export direct depuis Premiere, prêt, en attente d'un export réel.
- **Conseil du verdict** (11/10, chantier 12, `Metrics/Advice/`) : une ligne
  chiffrée à droite de la phrase, un bouton sous elle (Finder, Moniteur
  d'activité, réglages de stockage ; jamais quitter une app), sans ligne de
  plus dans le bandeau. Mémoire : la plus lourde des apps qu'on peut fermer
  (1 Go au moins, montage exclu). Disques : la copie en cours qui le remplit
  (détection du chantier 05), sinon un disque externe qui a la place, en
  jours au rythme du premier. Plantage : la mémoire à l'heure du plantage.
  Processeur : les cœurs rendus au montage. Calculé panneau ouvert sur les
  relevés publiés, rien panneau fermé. Section CONSEIL de `--probe`,
  `--snapshot x.png --conseils`, 13 tests (`AdviceTests`), chacun vu échouer
  sous mutation.
- **Le panneau tient dans l'écran** (11/10, chantier 01) : trop haut pour
  l'écran de l'icône, il prend une colonne de plus (les dernières cartes des
  colonnes trop hautes passent à droite, dans leur ordre), jamais des cartes
  compactes, qui cacheraient leurs listes. Relevé figé : 1 296 pt (sept
  cartes, forfait réglé) et 1 487 pt (+ Médias) deviennent 932 × 1 238 pt,
  pour 1 274 pt utiles ; panneau détaché (13) compris, sa fenêtre à
  1 268 pt. Rendu identique quand tout tient. `--ajuste` dans
  `./verifie.sh`, 10 tests (`PanelFitTests`).
  sous mutation. Règle 9 calibrée à 14 jours (au-delà, 72 % des échéances
  disparaissaient en 24 h) ; bilan du journal sans les relances ; preuve
  écrite dans `verdicts.jsonl` ; `outils/rejoue-seuils.py`
  (`CalibrationTests`).
- **Barre de menus façon iStat** (11/10, chantier 09) : `Sources/Pulse/MenuBar/`.
  Un élément combiné ou un par segment, au choix dans la page « Barre de
  menus » des Réglages ; segments mémoire, disque le plus serré, débit,
  processeur, batterie (06), température (04), dans l'ordre réglé, chacun en
  texte, mini-graphe, jauge ou anneau (jauge et anneau seulement sur un total
  réel). Symbole du verdict à place réservée — triangle plein pour une alerte,
  en contour pour un avertissement s'il est demandé —, largeur figée sur la
  composition, jamais sur les valeurs. Dessin AppKit en image template, 10 pt.
  Icône cachée (barre pleine, derrière l'encoche) détectée sur les fenêtres de
  Control Center : dite dans le panneau et dans `--probe` (section BARRE DE
  MENUS, avec la place à droite de l'encoche). Débit filtré (30 %, 3 ko/s), barre
  refaite au plus toutes les 5 s : 33 → 17 affichages au banc. 17 tests
  (`MenuBarTests`), `--snapshot x.png --barre`.
- **Fenêtres** (11/10, chantier 13, `Window/`) : panneau détachable en
  `NSPanel` non activant (Premiere garde le clavier), épingle « au-dessus de
  tout » plein écran compris ; tableau de bord pour un second écran (verdict,
  six grands `HistoryChart`, toutes les cartes en colonnes « maçonnerie »).
  Boutons au pied du panneau, entrées au menu de l'icône. Contenu créé à
  l'ouverture, vidé fermé ou caché : au banc, fermées 0,2-0,26 %, ouvertes
  7,7 % (détaché) et 6,2 % (tableau). `--snapshot x.png --fenetre|--tableau`,
  `--banc 60 --fenetre|--tableau`.
- **Animations, verre et thèmes** (11/10, chantier 10) : cascade
  d'ouverture en 300 ms (opacité, 5 pt de chute, anneaux qui se remplissent,
  chiffres posés d'emblée), horloge à 60 images/s puis en pause ; survol et
  appui sur tout ce qui se clique (voile mesuré à 3:1) ; survol des
  graphiques en barres (heure et valeur) ; cadre en Liquid Glass natif sous
  macOS 26, données sur fond opaque ; six thèmes (Système, Sombre, Clair,
  Violet, Indigo, Accent du système) dans Réglages › Général, chacun mesuré.
  Réduire les animations et Réduire la transparence respectés. Les titres
  des six cartes ouvrent leur historique ; un dépliant ouvert compacte les
  autres cartes de sa colonne (le panneau sortait de l'écran). Voir
  `docs/chantiers/10-animations.md`.
- **Règles et notifications** (11/10, chantier 11) : `Sources/Pulse/Rules/`,
  page « Règles et alertes » de la fenêtre Réglages, sept préréglages TOUS
  éteints (disque de rushes sous 100 Go, export terminé, Premiere a planté,
  forfait iPhone 80 % puis épuisé, swap qui monte, connexion perdue), et
  des règles libres sur 13 mesures que les modules publient déjà. Moteur
  pur : durée minimale, hystérésis (marge et délai de sortie), plages
  horaires, une notification par épisode, rafales, au plus une
  notification toutes les 5 min (le reste regroupé), rien de non urgent
  tant qu'une app de montage est au premier plan, trou de veille, reprise
  du journal au redémarrage. Notifications ordinaires : Ne pas déranger et
  les concentrations de macOS les retiennent. Cloche dans la barre, place
  réservée seulement si une règle allumée la demande. Coût nul sans règle
  allumée (aucun abonnement) ; allumées, mesurées au banc
  (`PULSE_BANC_REGLES`). Section RÈGLES de `--probe`, journal
  `regles.jsonl`. 23 tests, chacun vu échouer sans sa correction
  (`outils/mutations-regles.py`, 28 mutations). **L'autorisation de
  notifier n'a jamais été demandée** : elle part le jour où Isma allume
  une règle qui notifie — à vérifier à ce moment-là.
- **Audit de performance** (11/10, chantier 15) : le Pulse installé passe
  de 0,82 % à 0,46 % d'un cœur panneau fermé (fenêtres de 14 à 18 min, loin
  d'une relance), réveils de 3,2 à 1,4 par seconde — relevé des processus en
  un appel au noyau par processus, GPU lu par sa seule clé, avec la barre
  du chantier 09. L'écart banc/app venait des cœurs : l'app tourne sur les
  cœurs E, le banc lancé d'un shell sur les cœurs P (deux fois moins de
  temps CPU pour le même travail) ; le banc mesure désormais panneau fermé
  sur les cœurs E et compte les tâches de 1, 2 et 10 min une à une. Le pic
  des 2 min (espace « important », 105–117 ms) n'est plus relu que toutes
  les 10 min fermé. Défaut corrigé : après une veille, un compteur réseau
  remis à zéro devenait 1,8 Go fantômes dans le forfait iPhone. Voir
  `docs/chantiers/15-audit-perf.md`.
- **Extras** (chantier 18, 11/10) : horloges nommées par personne avec lever
  et coucher du soleil (calcul NOAA sur le Mac, aucune localisation),
  calendrier (EventKit, accès demandé à l'activation seulement), météo
  Open-Meteo heure par heure et sur 7 jours (sort sur Internet, et la carte
  le dit). Trois modules **désactivés par défaut** ; rien ne demande ni
  n'envoie hors de l'app installée (`Extras.appReelle`). `--exemple` pour
  les rendre. Journal : `docs/chantiers/18-extras.md`. **Ni EventKit ni
  Open-Meteo n'ont jamais été appelés pour de vrai** : à vérifier le jour où
  Isma active ces cartes — et si macOS oublie l'accès au calendrier à chaque
  reconstruction (signature ad hoc), la carte propose un bouton au lieu de
  redemander seule.

- **Ventilateurs, prêts jusqu'à l'installation** (11/10, chantier 14,
  `Sources/PulseHelper/`, `Sources/Pulse/Fans/`) : helper root `PulseHelper`
  embarqué et signé par `build.sh`, JAMAIS installé sans Isma ; page
  Ventilateurs des Réglages (installation sur accord avec mot de passe,
  désinstallation en un clic, modes automatique / fixe / courbe, éditeur de
  courbe, journal) ; pilote qui ne fait RIEN en automatique (le défaut). Démon
  classique dans `/Library/PrivilegedHelperTools`, pas `SMAppService` (ad hoc
  + recompilations = « Launch Constraint Violation »). Sécurités dans le
  helper : bornes d'Apple relues à chaque consigne, automatique si Pulse
  quitte, battement manqué 15 s, veille, pression thermique forte, SMC muet,
  60 écritures par démarrage. Section VENTILATEURS de `--probe`,
  `--snapshot x.png --reglages ventilateurs`, 40 tests (`FanControlTests`,
  `FanPilotTests`), revue de sécurité dans `docs/chantiers/14-ventilateurs.md`.

- **Audit UX, Apple et accessibilité** (11/10, chantier 16) : rapport classé
  et cité HIG dans `docs/chantiers/16-audit-ux.md`. VoiceOver dit le
  chiffre de tête de chaque carte (il était muet), le niveau du verdict, les
  graphiques (graphique sonore pour la dernière heure) ; plus aucun
  AXUnknown hors 09 et 14 ; la couleur ne porte plus rien seule (pression
  et santé écrites dans l'anneau, forfait iPhone en violet : l'orange veut
  dire « attention ») ; chevrons à 3:1 ; un historique ouvert ne compacte
  que ce qu'il faut (`PanelFit.shrink`) ; verdict jamais coupé ; « débit en
  bits » enfin appliqué. `swift outils/relecture-ax.swift --attendre 90` :
  relecture à l'API du panneau réellement ouvert, à lancer avec Isma.
  `--equilibre` rend la variante de rangement soumise à Isma.

- **Audit du code** (11/10, chantier 17, `docs/chantiers/17-audit-code.md`) :
  helper des ventilateurs relu avant l'installation (retour en automatique
  retenté tant que le SMC le refuse, copie installée vérifiée, exigence XPC
  testée pour de vrai) ; history.json, reseau.json et exports.json lus
  élément par élément, mis de côté plutôt qu'écrasés ; une base SQLite saine
  n'est plus jamais renommée ; `--probe` en lecture seule de bout en bout ;
  IP publique et sonde 1.1.1.1 dans l'app installée seulement ; 30 tests de
  non-régression, dont un par piège du README qui se teste ; inventaire des
  API privées ; 1 300 lignes de code mort retirées ;
  `swift-tools-version 6.0`, concurrence vérifiée en entier à la
  compilation, mode de langage 5 gardé (piège du README).
- **Suites techniques** (11/10, chantier 19, `docs/chantiers/19-suivis.md`) :
  la fenêtre Réglages cachée (derrière Premiere, réduite, autre espace)
  repasse à la cadence fermée et vide son contenu : au banc, cachée
  = fermée (0,24 %), contre 10 fois plus avant (6,00 % contre 0,64 % sur
  une passe Mac sur batterie, `--banc 620 --reglages memoire`) ; panneau détaché et
  tableau de bord réduits, même règle (`Surfaces.isSeen`). Binaire installé
  8,1 Mo au lieu de 9,2 (dSYM à côté du bundle, carte de débogage retirée,
  table des symboles gardée) ; `./verifie.sh` plafonne le code et les
  données, 6 Mo pour 4,0. Carte Médias figée, comparée aux références.
  Débits disque (lecture, écriture) dans l'historique longue durée, toutes
  les séries au pire sous 50 Mo à 90 jours. Règles « Copie de rushes
  terminée » (8e préréglage, éteint) et « Export terminé » qui nomme le
  fichier et son issue ; coût nul règles éteintes.
- **Partage public** (26/10, `docs/chantiers/20-partage.md`) : Pulse est sur
  github.com/Apocale/Pulse, code sans l'historique de main, page d'accueil
  pour qui ne code pas (`.github/README.md`), une ligne d'installation
  (`installer.sh`, curl sans quarantaine). `outils/distribue.sh` fabrique le
  zip à part, sans le helper des ventilateurs ; `outils/publie.sh <version>`
  publie, par la branche `public` seulement — **ne jamais pousser main**,
  son historique porte les noms de clients retirés de l'arbre. Trois audits
  avant l'envoi (installation neuve, M1 Pro, plantages) : catalogue de
  capteurs par puce, grappes éteintes à 5 °C écartées, plus aucune demande
  d'autorisation au premier lancement (Documents, Téléchargements, réseau
  local), disques locaux seulement, Time Machine écarté, second écran,
  panneau rangé au plus serré sur un petit écran, bulles d'aide calculées
  sur le Mac, panneau ouvert une fois au tout premier lancement, réglage du
  lancement à l'ouverture de session. Tous les pièges sont au README.

## Pas fait

- **Export lancé sans Media Encoder.** Non détecté : l'export direct depuis
  Premiere ne démarre pas Media Encoder, et la charge des `VTEncoderXPCService`
  ne se rattache à rien (`ppid 1`). **Piste en cours** : les fichiers média que
  Premiere tient ouverts en écriture (`Metrics/OpenFiles.swift`, affichés par
  `--probe`). Au repos il n'en tient aucun. À valider pendant un export réel
  lancé depuis Premiere avant d'en faire une détection.
- **Seuils du verdict à calibrer.** Le délai de tenue (5 min) est calibré
  sur 16 jours de journal, la règle 9 sur 13 jours de prévisions (14 j, le
  11/10) ; les seuils des règles 7 (1 Gio/h) et 10 (90 % / 200 %) restent
  posés, pas mesurés : 2 h de série seulement le 11/10. Vers le 17/10,
  `python3 outils/rejoue-seuils.py` (une semaine de swap, de processeur et
  de `processeur.hors-montage`, la charge de l'app la plus occupée, relevée
  depuis le 11/10) et le bilan du journal dans `--probe`, qui ne compte
  plus les relances : 9,9 changements par jour depuis le délai de tenue,
  cible ~7. `outils/rejoue-verdicts.py` rejoue n'importe quel délai.
- **VoiceOver jamais écouté.** L'arbre d'accessibilité est juste à l'API, mais
  personne n'a fait le parcours à l'oreille.
- **Persistance des exports.** Fait le 11/10 (chantier 08) : `exports.json`,
  nourri par le journal d'AME et par la détection en direct.
- **Seuil d'export à confirmer.** Un seul export de 30 s, un seul format, et le
  plancher au repos jamais observé pendant un appel vidéo.
  `outils/mesure-export.py` produit un relevé de plus à chaque exécution.
- Encodeurs ProRes et moteurs médias : chantier 08. (Ce qui était écrit ici —
  « températures et ventilateurs exigent `sudo` » — était faux : corrigé le
  11/10, voir « Capteurs » dans Fait.)
- Une revue adversariale des dimensions persistance / incidents / interface a
  été lancée puis interrompue. À relancer si besoin.
- **Forfait iPhone à régler.** Quota et jour de renouvellement demandés à
  Isma ; en attendant, pas de jauge (pas de dénominateur inventé). Se règle
  dans la carte (« Régler le forfait iPhone ») ou dans la fenêtre Réglages.
- **Consommation du forfait par app.** Le débit par app n'est mesuré que
  panneau ouvert : « qui a mangé le forfait aujourd'hui » demanderait un
  suivi panneau fermé, sur le partage iPhone seulement, à mesurer au banc
  avant d'exister.
- **Barre de menus jamais vue par Isma.** Vérifiée hors écran et à l'API
  (`--snapshot --barre`, `--probe`) ; le rendu dans SA barre — thème, encoche,
  voisines — demande un regard. Coût de l'icône à remesurer sur le Pulse
  installé (le banc ne peut pas l'afficher : `Banc.icone` reste à 0,45).
- **Actions Raccourcis et widgets** (chantier 13). Écrits, testés, rendus
  (`--snapshot x.png --widget tous`), métadonnées App Intents produites sans
  Xcode (`outils/appintents-metadata.sh`), extension de widgets construite à
  part (`Widgets/`, bac à sable + lecture seule du dossier de Pulse, prouvé
  en ad hoc). Mais `linkd` refuse une app sans Team ID, chronod purge un
  widget ad hoc, et l'empreinte ad hoc change à chaque compilation. Il faut
  un certificat « Apple Development » (Apple ID gratuit dans Xcode) et
  `PULSE_IDENTITE` dans `build.sh`, qui embarque alors les deux : décision
  d'Isma, en attente.
- **Règles : l'autorisation de notifier jamais vue.** Le moteur est testé
  avec un notificateur injecté ; la demande de macOS ne part qu'à
  l'allumage d'une règle qui notifie, par Isma. Le jour où il le fait :
  vérifier qu'une notification arrive (journal `regles.jsonl`, section
  RÈGLES de `--probe`). La copie de rushes terminée (chantier 05) n'est pas
  une règle : les épisodes clos ne sont pas publiés panneau fermé.

- **Contrôle des ventilateurs jamais essayé pour de vrai.** En attente de
  l'accord d'Isma (son mot de passe) et d'un essai de 10 min avec lui : la
  procédure est dans `docs/chantiers/14-ventilateurs.md`. Personne n'a encore
  écrit dans le SMC de ce M2 Max ; ne JAMAIS installer le helper ni écrire
  dans le SMC sans lui. (Relevé le 26/10 : le helper EST installé sur ce Mac
  depuis le 11/10 à 11 h 29, journal à 0 écriture ; la version partagée ne
  l'embarque pas.)
- **Jamais vu sur un autre Mac.** La version partagée n'a tourné que sur ce
  M2 Max : clés des capteurs M1 tirées de Stats, macOS 14 à 27 jamais
  essayés. Le premier `--probe` d'un autre Mac (section CAPTEURS) le dira.

## Règles dures

1. **Ne jamais activer App Sandbox.** `build.sh` signe sans entitlements, et
   c'est ce qui autorise la lecture des rapports de diagnostic et du dossier
   Caches d'Adobe. Le sandbox couperait toute la section Incidents.
2. **Tout nouveau champ persisté doit être lu en `decodeIfPresent`.** Le
   décodeur `Codable` synthétisé de Swift lève `keyNotFound` sur une clé
   absente malgré une valeur par défaut : un champ ajouté naïvement efface tout
   l'historique de l'utilisateur au premier lancement.
3. **Deux conventions d'unités, pas une.** `Fmt.memory` en base 1024 pour la
   mémoire et le swap, `Fmt.bytes` en base 1000 pour le stockage. Apple fait
   exactement ça. Un basculement global casse la moitié de l'affichage.
4. **Aucune couleur ne code une donnée sans ratio mesuré.** Voir
   `UI/Palette.swift`. `.accentColor` est réservée à l'interactif : elle suit le
   réglage de l'utilisateur et tombe à 1,37:1 en accent jaune.
5. **Pas de taille de police littérale** sous 10 pt : c'est le plancher macOS.
   Utiliser les styles système.
6. **Une teinte de `Palette` ne colore jamais du texte.** Ses ratios sont mesurés
   à 3:1, le seuil des objets graphiques ; le texte en exige 4,5. Elle colore un
   symbole, un filet, un remplissage, un trait — le texte reste `.primary` ou
   `.secondary`.
7. **Aucune barre sans dénominateur réel.** Pas de barre sur une durée, un
   compte, le swap ou le CPU d'une application : leur « total » serait inventé.
   La seule barre du panneau est l'occupation d'un volume.

## Contexte utilisateur

Monteur vidéo. Travaille sur Premiere Pro 2026, exporte parfois dans CapCut.
Disque de rushes externe qui se remplit vite et se remonte sous des noms
variables — d'où l'indexation de l'historique par UUID de volume.
