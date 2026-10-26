# Missions des chantiers

Une section par chantier : ce qu'il doit livrer. Le protocole commun (tes
fichiers, synchronisation, fusion, vérifications, interdits, rapports) est
dans `README.md`, avec la carte et les dépendances : le lire d'abord.

## 01-socle — modules, mise en page, fenêtre Réglages

Vague 1, prioritaire : les chantiers 09 à 13 attendent sa fusion. Le but :
qu'Isma puisse tout modifier, comme dans iStat Menus.

1. Un protocole de module (`Sources/Pulse/Modules/`) : identifiant, nom,
   symbole, carte du panneau, segment de barre de menus optionnel, réglages
   propres, coût d'échantillonnage. Un registre unique où chaque module
   s'inscrit en UNE ligne : c'est par là que les chantiers 04 à 08
   brancheront leurs cartes.
2. Découper `PopoverView.swift` : une carte par fichier
   (`Sources/Pulse/UI/Cards/`), branchée sur le registre, et une option
   `--snapshot x.png --carte <id>` pour rendre une carte seule. Le rendu doit
   rester identique : comparer les `--snapshot` avant/après, sombre et clair.
3. Mise en page pilotée par les réglages : quelles cartes, dans quel ordre,
   sur 1, 2 ou 3 colonnes, compactes ou complètes.
4. Fenêtre Réglages façon iStat (menu de l'app et bouton dans la barre de
   raccourcis) : barre latérale par module, aperçu en direct de la carte,
   interrupteurs, ordre par glisser-déposer, fréquence de mise à jour, unités,
   nombre d'apps listées, couleurs par série (contraste mesuré, refusées sous
   3:1).
5. Réglages persistés en JSON tolérant (règle dure n°2 : `decodeIfPresent`
   partout), export et import.

Fusionner tôt le registre et la découpe (points 1 et 2) pour débloquer les
autres, puis la mise en page et la fenêtre. Tests du registre et de la
persistance des réglages.

## 02-historique — historique longue durée

Vague 1. Comme les graphes d'iStat et leurs plages de temps. Aujourd'hui
Pulse ne garde qu'une heure de série (`HistoryStore`, `history.json`) et
30 jours d'espace disque.

1. Base de séries temporelles en SQLite (libsqlite3 du système, aucune
   dépendance) dans Application Support/Pulse, code dans
   `Sources/Pulse/History/` : points bruts toutes les 10 s sur 24 h, agrégés
   à la minute sur 7 jours et aux 10 minutes sur 90 jours (moyenne, min,
   max). Écriture groupée, hors du main thread, coupée quand
   `Persistence.enabled` est faux.
2. Séries : processeur (total, utilisateur, système, par cluster), carte
   graphique, mémoire (apps, système, compressée), pression, swap, débit
   réseau ↑↓, et toute série qu'un module déclare (API prévue pour les
   chantiers 04 à 08).
3. Migration de la série actuelle de `history.json` sans rien perdre (règle
   dure n°2) ; une base illisible est mise de côté, jamais effacée.
4. API de lecture par plage (1 h, 24 h, 7 j, 30 j, 90 j) et un composant
   graphique réutilisable : sélecteur de plage, survol qui montre la valeur et
   l'heure, barres ou courbe, échelle à dénominateur réel (règle dure n°7).
5. Taille disque bornée et mesurée (moins de 50 Mo à 90 jours), coût CPU
   mesuré (moins de 0,05 % d'un cœur), section HISTORIQUE dans `--probe`.

Ne pas brancher le composant dans toutes les cartes : exposer l'API et un
exemple ; le branchement passera par le registre du 01. Tests : agrégation,
migration, purge, base corrompue, plages.

## 03-banc — banc d'essai et vérification automatique

Vague 1. Ce qui permet à 18 chantiers de ne rien casser.

1. `Pulse --banc <secondes>` : le vrai `Sampler` sans interface, écriture
   coupée (`Persistence.enabled = false`, comme `UI/Snapshot.swift`), panneau
   fermé puis ouvert ; imprime le temps CPU consommé (temps cumulé du
   processus, pas `top` : voir le README), la mémoire, les réveils par
   seconde, le temps de création du panneau. Repère du 11/10 : panneau fermé,
   0,72 % d'un cœur, 47 Mo.
2. Un `Sampler` simulé à données fixes et déterministes ; des tests de rendu
   de chaque carte et du panneau entier, sombre et clair, comparés à des
   images de référence (`Tests/References`) avec une tolérance mesurée ; un
   mode pour régénérer les références volontairement.
3. `./verifie.sh` à la racine : build, `swift test`, rendus, contraste
   (`outils/contraste.swift`), banc de 60 s avec seuil de budget, taille du
   binaire, `--probe` sans erreur. Sortie lisible, code d'erreur si un seuil
   casse. En fusionner une première version vite : tous les chantiers la
   lanceront avant de fusionner.
4. Mesures de base dans `docs/chantiers/03-banc.md` et dans la section
   Diagnostic du README.

## 04-capteurs — températures, ventilateurs (lecture), puissance

Vague 1. Sans sudo. `CLAUDE.md` affirme qu'il faut `powermetrics` donc
`sudo` : c'est probablement faux ; le vérifier et corriger la doc.

1. Températures Apple Silicon via `IOHIDEventSystemClient`, ventilateurs via
   le SMC (AppleSMC : vitesse actuelle, minimum, maximum, les deux
   ventilateurs du 16"), puissance et fréquences du processeur, de la carte
   graphique et du moteur neuronal via IOReport, comme macmon ou asitop sans
   root. Étudier Stats (exelban/stats, licence MIT) pour les API ; respecter
   sa licence en cas d'inspiration proche.
2. Noms lisibles en français, regroupés (Processeur, Carte graphique,
   Mémoire, SSD, Batterie, Air) ; chaque valeur recoupée avec une source
   indépendante quand il en existe une.
3. Une carte « Capteurs » façon iStat (`Sources/Pulse/Metrics/Sensors/` et une
   vue à toi) : trois anneaux (processeur, carte graphique, ventilateurs),
   puis Températures et Puissance en listes. Prête pour le registre du 01 ;
   en attendant, rendue avec `--snapshot`. Segment de barre de menus
   optionnel « CPU 62° ».
4. Section CAPTEURS dans `--probe` ; tests de décodage SMC et IOReport.
5. Coût mesuré : lecture panneau ouvert, ou toutes les 30 s panneau fermé ;
   le budget de moins de 1 % tient.

Rien n'écrit dans le SMC : le contrôle des ventilateurs est le chantier 14,
qui réutilisera ce lecteur.

## 05-disques — activité, santé, ce qui remplit

Vague 1. Le menu disque d'iStat, et ce qu'il ne fait pas. Contexte : « Ssd 2 »
(2 To, externe) prend environ 210 Go par jour ces temps-ci et se remonte sous
des noms variables (historique indexé par UUID de volume).

1. Lecture et écriture par disque physique (IOKit, statistiques de
   `IOBlockStorageDriver`), en direct et en graphique miroir (`MirrorBars`
   existe) ; par application, avec `ri_diskio_bytesread` / `written` de
   `proc_pid_rusage` (ProcessMonitor appelle déjà rusage v6 : ajouter les
   écarts sans coût de plus). Liste « Apps qui écrivent ».
2. Santé : statut SMART ou NVMe lisible sans root, usure, température du SSD
   si disponible.
3. « Qu'est-ce qui remplit Ssd 2 ? » : les dossiers qui ont le plus grossi
   sur 24 h et 7 jours, par balayage incrémental bon marché (FSEvents, ou
   tailles de premier niveau à intervalle long), jamais un parcours complet en
   boucle.
4. Détection d'une ingestion massive (copie de carte, téléchargement de
   rushes) pour la nommer au lieu de seulement crier « bientôt plein ».
5. Carte Disques enrichie (`Sources/Pulse/Metrics/DiskActivity/` et une vue à
   toi), prête pour le registre du 01 ; section dans `--probe` ; tests.

Ne jamais supprimer ni déplacer un fichier d'Isma.

## 06-batterie — batterie, alimentation, Bluetooth

Vague 1. Comme le menu batterie d'iStat.

1. Batterie, via `IOPowerSources` et `AppleSmartBattery` (IORegistry) :
   niveau, santé (capacité réelle sur capacité d'origine), cycles,
   température, état (en charge, sur secteur, sur batterie), temps restant,
   puissance du chargeur, consommation instantanée en watts.
2. Appareils Bluetooth à batterie (AirPods, souris, clavier, trackpad), lus
   sans autorisation intrusive.
3. Une carte « Énergie » (`Sources/Pulse/Metrics/Power/` et une vue à toi) :
   anneau du niveau, anneau de la santé, lignes de détail, appareils. Prête
   pour le registre du 01 ; en attendant, rendue avec `--snapshot`. Segment
   de barre de menus optionnel.
4. Historique de charge sur la journée si le 02 est dans `main`, sinon
   branchement prévu.
5. Section ÉNERGIE dans `--probe` ; tests de lecture IORegistry sur des
   dictionnaires d'exemple.

## 07-reseau — réseau avancé et forfait iPhone

Vague 1. Le menu réseau d'iStat au complet, plus le forfait iPhone. Existant :
carte Réseau (débit, miroir sur 3 min, cumul du jour et de la veille), cumul
par réseau dans `reseau.json` (partage iPhone et Starlink reconnus,
`Metrics/Network.swift`), compteurs 32 bits (piège du README).

1. Débit par application (cadre privé NetworkStatistics comme iStat ; à
   défaut `nettop` à faible fréquence, panneau ouvert seulement) : top 5 ↑ et
   ↓ avec icônes (`AppRow` existe).
2. Latence vers la passerelle et vers Internet, indicateur de connexion,
   adresses IP locales. L'IP publique uniquement si Isma l'active dans les
   réglages : elle sort sur Internet, désactivée par défaut.
3. Signal Wi-Fi (RSSI, bruit, débit de liaison) sans autorisation de
   localisation si c'est possible ; sinon le dire.
4. Forfait iPhone : quota mensuel et jour de renouvellement réglables, jauge
   du mois (dénominateur réel : le forfait, règle dure n°7), consommation par
   jour, seuils 80 % et 100 % exposés pour le chantier 11.
5. Carte Réseau enrichie (`Sources/Pulse/Metrics/NetworkPlus/` et une vue à
   toi), prête pour le registre du 01 ; section dans `--probe` ; tests (dont
   un rebouclage des compteurs 32 bits).

## 08-medias — médias, export Premiere, cache média

Vague 1. Ce qu'iStat ne sait pas faire pour un monteur. Existant : détection
d'export par la charge de Media Encoder (`Metrics/ExportDetector.swift`),
piste non validée pour l'export direct depuis Premiere
(`Metrics/OpenFiles.swift`, voir « Pas fait » dans `CLAUDE.md`).

1. Carte graphique détaillée (fréquence, mémoire, utilisation par application
   si l'IORegistry la donne) et moteurs médias Apple Silicon (encodeur,
   décodeur, ProRes) via IOReport, sans root.
2. Export lancé depuis Premiere sans Media Encoder : valider la piste
   OpenFiles (fichier média tenu ouvert en écriture) et l'activité de
   l'encodeur matériel. Il faut un vrai export : préparer la mesure (outil
   prêt à lancer), puis mettre dans le rapport la demande exacte à Isma (quoi
   exporter, combien de temps, quoi lancer avant). Ne faire une détection que
   sur des seuils mesurés, même méthode qu'ExportDetector (README).
3. Historique des exports persisté (règle dure n°2) : « 3 exports
   aujourd'hui, 1 h 20 », durée, fichier, taille, progression si la taille du
   fichier de sortie la rend estimable.
4. Cache média de Premiere : taille, emplacement réel (lu dans ses
   préférences), bouton pour l'ouvrir dans le Finder. Jamais de suppression
   automatique.
5. Carte Montage enrichie (`Sources/Pulse/Metrics/Media/` et une vue à toi),
   prête pour le registre du 01 ; sections dans `--probe` ; tests.

Ne jamais supprimer un fichier d'Isma, cache compris.

## 09-barre — barre de menus façon iStat

Vague 2, après le 01. Existant : barre combinée « MÉM / disque / débit »
(`UI/MenuBarLabel.swift`, image template rendue par `PulseApp.swift`, largeur
figée). Pièges du README : sans titre, un NSStatusItem ne dessine rien sous
macOS 26 ; la position AX d'une icône ne prouve pas qu'elle se voit.

1. Un seul élément combiné OU un élément par module, au choix dans les
   Réglages ; par module, style texte (petite étiquette au-dessus de la
   valeur, comme « CPU / 44% »), mini-graphe, jauge ou anneau ; ordre et
   contenu réglables.
2. L'alerte du verdict visible dans la barre (un symbole, jamais une couleur
   seule), sans devenir intrusive.
3. Largeurs figées (pas de danse des icônes voisines) et place limitée : à
   droite de l'encoche il n'y a que 918 points. Détecter qu'un élément est
   caché par manque de place et le dire dans le panneau et dans `--probe`.
4. Police au plancher de 10 points (règle dure n°5), rendu template qui suit
   le thème de la barre.
5. Tests de composition et de largeur (rendus `--snapshot x.png --barre`). À
   la fin, demander dans le rapport qu'Isma regarde sa barre une fois.

## 10-animations — animations, Liquid Glass, thèmes

Vague 2, après le 01. Rendre Pulse « mille fois mieux » à l'œil sans
l'alourdir. Charger les skills animate, emil-design-eng, liquid-glass et
apple-design. Existant : un ressort unique (`UI/Motion.swift`), une palette
mesurée (`UI/Palette.swift` ; fond sombre #1E1E1E, raison dans
`UI/Components.swift`).

1. Ouverture : cartes et anneaux en cascade (300 ms au plus), anneaux qui se
   remplissent jusqu'à leur valeur, graphes qui défilent en continu.
2. Survol d'un graphe : valeur et heure sous le curseur ; états de survol et
   d'appui sur tout ce qui se clique.
3. Liquid Glass macOS 26 pour le cadre du panneau, comme iStat 7.5, jamais de
   verre sous une donnée ; contraste remesuré après.
4. Thèmes façon iStat (Sombre, Clair, Violet, Indigo, Accent du système…),
   chacun mesuré par `outils/contraste.swift`.
5. Respect de Réduire les animations et Réduire la transparence ; aucune
   animation sur un chiffre qui change à chaque relevé.
6. Budget : panneau ouvert à 5 % d'un cœur au plus, fermé inchangé.

## 11-regles — règles et notifications

Vague 2 (le moteur n'attend rien ; l'éditeur attend le 01). Existant : un
verdict à douze règles, aucune notification.

1. Un moteur de règles (`Sources/Pulse/Rules/`) : condition sur n'importe
   quelle mesure exposée par un module, durée minimale, hystérésis, plages
   horaires ; actions : notification macOS, son, signal dans la barre.
2. Préréglages, TOUS désactivés par défaut : disque de rushes sous X Go,
   export terminé, Premiere a planté, forfait iPhone à 80 % puis 100 %, swap
   qui monte, connexion perdue.
3. Isma déteste être dérangé en montage : respecter Ne pas déranger et les
   modes de concentration, regrouper, une seule notification par épisode,
   jamais de fenêtre qui s'ouvre. Aucune notification réelle pendant les
   essais.
4. Éditeur de règles dans les Réglages du 01, journal des déclenchements,
   section RÈGLES dans `--probe`.
5. Tests du moteur (durée, hystérésis, plages horaires, regroupement), chacun
   vu échouer sans sa correction.

## 12-verdict — conseils chiffrés et boutons

Vague 2. Existant : `Metrics/Verdict.swift` (douze règles, hystérésis, délai
de tenue de 5 min), `Tests/PulseTests/VerdictTests.swift`, `verdicts.jsonl`,
`outils/rejoue-verdicts.py`.

1. Pour chaque règle, un conseil chiffré et vérifiable
   (`Sources/Pulse/Metrics/Advice/`) : « Vivaldi tient 10 Go : le fermer en
   libère autant », « Extreme Pro a 719 Go libres », « le swap a pris 2 Go en
   une heure ».
2. Un bouton qui agit sans danger : ouvrir le disque dans le Finder, le
   Moniteur d'activité, les réglages de stockage. Jamais quitter ou tuer une
   app sans confirmation explicite.
3. Calibrer les seuils provisoires des règles 7 (swap, 1 Go/h), 9 (30 jours)
   et 10 (90 % / 200 %) sur le journal (bilan dans `--probe`, rejeu avec
   `outils/rejoue-verdicts.py`) ; méthode et chiffres dans le README.
4. Tests : chaque conseil et chaque seuil vus échouer sans leur correction.

Le bandeau du verdict vit dans le panneau : si le 01 l'a déplacé, le suivre.

## 13-fenetre — fenêtre, widgets, Raccourcis

Vague 2, après le 01. Existant : le panneau est un NSPopover dont le contenu
est créé à l'ouverture et libéré à la fermeture (budget CPU).

1. Panneau détachable en fenêtre flottante, qui reste au-dessus de Premiere
   en plein écran si Isma le veut ; le budget tient fenêtre fermée.
2. Une fenêtre « tableau de bord » pour un second écran : toutes les cartes,
   grands graphes, mise en page du socle.
3. Widgets macOS (WidgetKit) : disque de rushes, mémoire, forfait iPhone.
   Une extension demande un bundle et une signature : trouver la voie la plus
   simple qui garde `./build.sh` comme point d'entrée, sans App Sandbox pour
   l'app principale (règle dure n°1) ; si c'est impossible sans compromis, le
   documenter et le mettre dans le rapport avant de trancher.
4. Actions Raccourcis (App Intents) : « Combien reste-t-il sur Ssd 2 ? »,
   « Pulse est-il calme ? », « Consommation iPhone du jour ».
5. Tests et rendus de chaque nouvelle surface. Aucune fenêtre ouverte sur
   l'écran d'Isma pendant les essais.

## 14-ventilateurs — contrôle des ventilateurs, sur accord

Vague 3, après le 04 (lecteur SMC). Optionnel, sûr, réversible.

1. Écrire dans le SMC demande root : un helper privilégié
   (`SMAppService.daemon`, `Sources/PulseHelper/`), installé seulement sur
   accord explicite d'Isma, désactivé par défaut, désinstallable en un clic.
   Rien qui demande son mot de passe sans son accord, donné après lui avoir
   expliqué en deux phrases ce qui sera installé et comment l'enlever. C'est
   lui qui tape son mot de passe.
2. Modes : automatique (macOS décide), vitesse fixe, courbe selon une
   température choisie, avec un éditeur de courbe.
3. Sécurités : jamais sous le minimum d'Apple ni au-dessus du maximum ;
   retour en automatique si Pulse quitte, plante, si le Mac se met en veille,
   si un capteur ne répond plus ou si le helper ne reçoit plus de battement
   de cœur ; chien de garde dans le helper.
4. Surface XPC minimale, vérification du signataire du client, journal des
   commandes ; revue de sécurité écrite.
5. Tests de la courbe et des replis ; essai réel seulement avec Isma présent.

## 15-audit-perf — endurance

Vague 3, après le 03 (`--banc`, `./verifie.sh`). Prouver que Pulse tient des
jours, avec tous les modules actifs. Repère du 11/10 : panneau fermé, 0,72 %
d'un cœur, 47 Mo.

1. Endurance de plusieurs heures au banc : temps CPU, mémoire (`leaks`,
   croissance du RSS), réveils par seconde, taille des fichiers de données,
   panneau fermé et ouvert, par module.
2. Situations dures : veille et réveil, disque externe débranché puis
   rebranché sous un autre nom, Wi-Fi ↔ partage iPhone, changement de fuseau,
   rebouclage des compteurs 32 bits, base d'historique corrompue. Ne rien
   débrancher soi-même : simuler dans le code de test, ou demander dans le
   rapport un moment où Isma peut le faire.
3. Rapport chiffré : ce qui coûte, fuit, casse ; corrections mesurées avant et
   après.
4. Seuils ajoutés à `./verifie.sh`.

## 16-audit-ux — audit Apple, HIG, accessibilité

Vague 3, après le 01 et le 10. Charger les skills apple-design et
perception-first-design:evaluate.

1. Chaque carte, la barre de menus, les Réglages, la fenêtre : hiérarchie,
   écriture (mots simples, français, sans jargon), cohérence, états vides et
   d'erreur, densité.
2. Accessibilité : parcours VoiceOver relu à l'API
   (`AXUIElementCopyAttributeValue`), libellés et valeurs, navigation clavier
   complète, tailles de texte, contraste dans chaque thème, Réduire les
   animations et la transparence.
3. Rapport classé du critique au mineur, chaque point cité (fichier HIG et
   titre), puis corrections avec rendus avant/après ; ce qui demande un choix
   d'Isma va dans le rapport, en images, une décision à la fois.

## 17-audit-code — revue, nettoyage, Swift 6

Vague 3, quand la plupart des chantiers sont fusionnés. Charger les skills
code-review et write-swift. Pas de grand déplacement de fichiers tant que
d'autres chantiers sont actifs.

1. Revue complète : bugs, concurrence, persistance (règle n°2), unités (n°3),
   cohérence `--probe` / interface.
2. Code mort retiré (anciennes lignes et dépliants remplacés par les cartes :
   `UI/Rows.swift`, parties de `UI/DetailPanels.swift`, chaque usage vérifié),
   fichiers trop longs découpés.
3. Passage en `swift-tools-version 6.0` et concurrence stricte, sans changer
   le comportement : rendus et tests identiques avant et après.
4. Sécurité et confidentialité : liste des API privées (IOReport,
   NetworkStatistics, HID…) avec le risque et le repli si macOS change ; rien
   ne sort sur Internet sans accord ; revue du helper du 14 s'il existe.
5. Un test de non-régression pour chaque bug du README qui n'en a pas.

## 18-extras — horloges, calendrier, météo

Vague 3, optionnel, après le 01. Chaque module dans
`Sources/Pulse/Modules/Extras/`, inscrit au registre et DÉSACTIVÉ par défaut.

1. Horloges du monde nommées par personne (le nom et son fuseau), lever et
   coucher du soleil.
2. Calendrier : prochains événements (EventKit ; autorisation demandée
   seulement quand Isma active le module).
3. Météo (Open-Meteo, sans clé), heure par heure et sur la semaine ; activée
   seulement par Isma, et le panneau dit qu'elle sort sur Internet. Aucune
   requête réelle tant qu'il ne l'a pas activée.
4. Cartes, segments de barre optionnels, sections dans `--probe`, tests de
   décodage sur des réponses enregistrées.
