# Pulse

Application de barre de menus macOS qui surveille une **journée de montage**,
pas une machine. Écrite pour Adobe Premiere Pro.

La différence tient en une phrase : « 28 Go utilisés » ne veut rien dire, mais
« Premiere a planté trois fois hier soir, tu swappes 7 Gio et ton disque de
rushes sera plein dans neuf jours » se traduit en décision.

## Construire et lancer

```
./build.sh          # compile et signe Pulse.app
open Pulse.app
```

Aucun Xcode requis : SwiftPM compile avec les Command Line Tools, le bundle est
assemblé à la main et signé ad hoc.

Installation durable : `cp -R Pulse.app /Applications/`, puis Réglages Système →
Général → Ouverture pour un lancement automatique.

Pour quelqu'un d'autre (26/10) : `outils/distribue.sh` fabrique
`.build/distribution/Pulse.zip` — compilé à part, sans le helper des
ventilateurs, signature revérifiée après dézippage — et `outils/publie.sh
<version>` publie code et zip sur github.com/Apocale/Pulse. Sur l'autre Mac,
une ligne : `curl -fsSL https://raw.githubusercontent.com/Apocale/Pulse/main/installer.sh | bash`
(`installer.sh` : télécharge par curl, qui ne pose pas la quarantaine de
Gatekeeper ; `PULSE_ESSAI=<dossier>` l'essaie sans rien ouvrir ni fermer).
Procédure et pièges : `docs/chantiers/20-partage.md`.

## Diagnostic

```
./.build/release/Pulse --probe
```

Relevé texte de tous les capteurs. Si un chiffre est faux dans l'interface, il
l'est ici aussi — c'est le point d'entrée du débogage.

| Option | Effet |
|---|---|
| `--probe` | relevé complet sur la sortie standard |
| `--probe --audit` | idem, écrit dans `~/Library/Application Support/Pulse/probe.txt` (pour un lancement par `open`, où stdout n'aboutit nulle part) |
| `--show` | ouvre le popover 1 s après le lancement et imprime sa géométrie sur stderr |
| `--light` | force l'apparence claire, sans toucher au réglage du système |
| `--snapshot fichier.png` | rend le panneau entier hors écran avec les mesures du moment, puis sort. **Rien ne s'ouvre** : à préférer à `--show` pendant que l'utilisateur monte. Un vrai `Sampler` tourne 6 s, écriture sur disque coupée (`Persistence`) : ni l'historique, ni le journal, ni le cumul réseau de l'app ne sont touchés. Ajouter `--light` pour le clair |
| `--snapshot fichier.png --barre` | la barre de menus (chantier 09) : la barre réglée, puis chaque style (texte, mini-graphe, jauge, anneau) sur tous les segments qui le permettent, l'alerte et l'avertissement, un élément par segment — les images mêmes que l'app pose, recolorées sur barre sombre et claire, agrandies deux fois, largeur de chacune en points |
| `--snapshot fichier.png --reglages barre` | la page « Barre de menus » de la fenêtre Réglages, hors écran |
| `--snapshot fichier.png --barre-cachee` | le panneau avec la ligne « L'icône de Pulse est cachée dans la barre de menus », pour la regarder sans cacher l'icône d'Isma |
| `--snapshot fichier.png --reseau` | le seul dépliant internet, avec une zone vide au-dessus pour qu'un débordement s'y voie |
| `swift outils/contraste.swift sombre.png clair.png` | contraste de chaque teinte de `Palette` sur le fond des cartes, lu sur deux rendus ; échoue sous 3:1 |
| `./Pulse.app/Contents/MacOS/Pulse --probe` | idem `--probe`, mais depuis le bundle : seul moyen de lire l'état du lancement à l'ouverture de session (voir les pièges) |
| `--snapshot fichier.png --capteurs` | la carte Capteurs seule, dans le cadre du panneau, avec les vraies mesures (attend la seconde lecture IOReport, 10 s au plus) ; `--light` pour le clair, `--barre` pour le segment « CPU 62° » |
| `--snapshot fichier.png --historique` | l'exemple du graphique d'historique (`HistoryChart`) : barres sur un total réel, courbe sur une pointe, deux séries, survol figé sur la tranche la plus haute — lu dans la vraie base, en lecture seule |
| `PULSE_HISTORIQUE=/chemin/base.sqlite` | remplace la base d'historique pour `--snapshot` et `--probe` : regarder une copie ou une base de démonstration (`PULSE_DEMO_BASE=… swift test --filter baseDeDemo`) sans toucher à la vraie |
| `--probe --remplissage` | section DISQUES : refait ici la requête Spotlight « ce qui remplit » de chaque volume externe (20 s au plus), en plus du dernier bilan de l'app |
| `--snapshot fichier.png --carte disques --ouvert activite-disques` | la carte Disques avec son dépliant : miroir des 3 min, ce qui remplit, apps qui écrivent, santé SMART |
| `PULSE_DIRECT=300 swift test --filter DirectDisquesTests` | le détecteur d'écritures massives sur la vraie machine pendant 300 s, au rythme de l'app ; imprime les épisodes, n'écrit rien |

`--probe` imprime aussi la règle de verdict retenue, le bilan du journal des
verdicts sur 7 jours, et — section EXPORT — les fichiers média que Premiere tient
ouverts en écriture. Section CAPTEURS : chaque température, ventilateur,
puissance et fréquence de la carte, sa clé d'origine, la seconde source qui la
recoupe quand il y en a une, et le coût d'une lecture.

`--snapshot fichier.png --carte <id>` rend une carte seule, à la largeur d'une
colonne, avec les réglages d'Isma : `processeur`, `reseau`, `memoire`,
`disques`, `montage`, puis celles des chantiers (la section MODULES de
`--probe` les liste). `--ouvert <clé>` la rend avec un historique déplié
(`volumes`, `reseau`, `session`, `apps`, `incidents`). Le fichier se met juste
après `--snapshot`.

Pour essayer une disposition sans toucher aux réglages d'Isma (rien n'est
écrit) : `--colonnes 1|2|3`, `--compact` (toutes les cartes), `--apps <n>`,
`--bits` (débit en bits), `--masque <id>`. `--snapshot x.png --reglages
[general|<id>]` rend la fenêtre Réglages hors écran — une fenêtre jamais
posée à l'écran, dessinée par `cacheDisplay` : `ImageRenderer` ne sait pas
dessiner les interrupteurs et les menus d'AppKit.

**`./verifie.sh`** enchaîne tout cela avant une fusion — compilation, taille du
binaire, `swift test`, `--probe`, rendus sombre et clair, contraste, banc de
60 s — et sort en erreur si un seuil casse. Tests, relevé, rendus et banc y
tournent dans un dossier personnel de rechange (`CFFIXED_USER_HOME`, qui
redirige Application Support et Préférences) garni d'une copie des données de
Pulse, comparée avant et après : une écriture qui échapperait à `Persistence`
se voit, et ne touche jamais les vraies données. `--rapide` saute le banc.

**`--banc <secondes>`** (60 par défaut) mesure Pulse sur lui-même, sans rien
ouvrir ni écrire : le vrai `Sampler` panneau fermé, puis ouvert — contenu créé
comme à l'ouverture, gardé dans une fenêtre jamais affichée —, puis refermé.
Temps CPU cumulé du processus (`getrusage`), réveils (`ri_interrupt_wkups`),
énergie (`ri_energy_nj`), mémoire, création du panneau, et le Pulse installé
lu pendant les mêmes secondes. Mesures du 11/10, machine occupée de 60 à 100 %
par les chantiers :

| Panneau | CPU, 1 cœur | Réveils/s | Puissance | Mémoire |
|---|---|---|---|---|
| fermé, au banc | 0,27 à 0,47 % | 1,7 | 6 mW | 17 Mo |
| ouvert, hors écran | 4 à 5 % | 8 à 13 | 90 mW | 35 à 42 Mo |
| fermé, Pulse installé | 0,76 à 0,93 % | — | — | — |

Panneau de 626 × 764 pt, créé en 90 à 180 ms la première fois, 35 à 80 ms
ensuite, dessiné en entier en 40 ms. Le banc refait le libellé de barre de
menus à l'identique, mais ne peut pas l'afficher sans rien montrer : l'écart
avec le Pulse installé, 0,41 à 0,53 point sur les mêmes secondes, revient à
l'icône — une trentaine d'affichages par minute, le débit changeant sans cesse
(hypothèse à confirmer au profileur). Le budget estimé lui ajoute donc
0,45 point (`Banc.icone`), à remesurer si la barre change.

`--banc … --ecrit` garde la persistance active, comme l'app — historique,
base SQLite, journaux —, et n'est accepté que dans un dossier personnel de
rechange : `./verifie.sh` le lance ainsi. Effet mesuré le 11/10 : faible
(0,36 % fermé sur 60 s, 0,48 % sur 300 s, contre 0,33 à 0,45 % sans). Le banc
de 60 s ne voit pas les tâches de période ≥ 60 s (disques et incidents toutes
les 2 min) : `--banc 300 --ecrit` les compte. `swift outils/trace-cpu.swift`
suit le Pulse installé toutes les 2 s, en lecture seule : côte à côte avec un
banc, mêmes secondes, l'app dépense 8 à 9 ms de plus toutes les 2 s (0,75 %
contre 0,30 %), l'écart de l'icône. Le Pulse installé est relancé à chaque
fusion : mesuré dans ses premières minutes, il paie encore son démarrage.

Correction du 11/10 (15-audit-perf) : cet écart n'était qu'en petite partie
l'icône. Lancé d'un terminal, le banc tournait sur les cœurs de performance ;
l'app, panneau fermé, tourne sur les cœurs d'efficacité, où le même travail
coûte deux fois plus de temps CPU (piège ci-dessous). Depuis, les phases
fermées du banc tournent en arrière-plan Darwin, sur les cœurs E, et les
tâches de 1 et 2 min y sont mesurées une à une puis réparties sur leur
période (`Sampler.rendDues`) : le banc de 60 s les compte, 0,10 point.
L'icône ne pèse plus que 0,13 point (`Banc.icone`, mesuré au profileur).
Mesures, mêmes secondes : banc sur les cœurs E 0,64 %, Pulse installé 0,71 %.

**`--rendus`** rend les cartes du socle et le panneau sur un relevé figé
(`Bench/Releve.swift` : une journée de montage chargée, aucune valeur qui
dépende de l'heure), en sombre et en clair, et les compare pixel à pixel à
`Tests/References` ; `--rendus --references` les régénère. Rendu deux fois, le
même relevé donne les mêmes octets ; la tolérance de 2 niveaux sur 255 couvre
un arrondi d'un niveau observé une fois, quand un seul chiffre changé en
déplace 180 pixels de 190 niveaux. Les écarts restent dans `.build/rendus/`,
en rouge. Les modules qui mesurent eux-mêmes sont figés du même geste
(`PowerSampler(figé:)`, `SensorStore.figer`, `MoniteurReseau.figer`), et
« aujourd'hui » est fixé pour le forfait du mois : les sept cartes se
comparent. Un module nouveau est rendu mais pas comparé tant que `Releve` ne
sait pas le figer (`Rendu.cartesFigees`). `./verifie.sh` signale aussi toute
teinte de `Palette` que `outils/contraste.swift` ne mesure pas, ou mesure sous
une autre définition.

Carte Réseau (chantier 07) : `--snapshot x.png --carte reseau` la rend avec la
connexion, le Wi-Fi, le forfait et le débit par app mesurés pour de vrai ;
`--ouvert connexion` déplie le détail (adresses, DNS, canal, norme) ;
`--forfait 20` pose un forfait d'essai de 20 Go EN MÉMOIRE, pour voir la
jauge sans toucher aux réglages d'Isma ; `--edition-forfait` ouvre l'éditeur du
forfait. `--probe` ajoute les sections FORFAIT IPHONE, CONNEXION, WI-FI, APPS
et COÛT. Le coût du moniteur en régime établi se mesure au banc :
`PULSE_BANC_RESEAU=60 swift test --filter BancReseau` (une minute de relevés à
la cadence de la carte, temps processeur du processus).

Conseil du verdict (chantier 12, `Metrics/Advice/`) : à droite de la phrase,
une ligne chiffrée — « Fermer Vivaldi libère 6,0 Go », « Extreme Pro a
719 Go libres, ~8 jours à ce rythme », « Copie de carte en cours (ffmpeg,
1,3 Go) » —, et sous elle un bouton qui n'ouvre qu'une fenêtre : le disque
dans le Finder, le Moniteur d'activité ou les réglages de stockage. Jamais
quitter une app. Le bandeau garde ses deux lignes : le panneau n'a pas de
hauteur à céder (une troisième seulement sur une colonne). `--probe`,
section CONSEIL : la ligne de chaque règle vraie, son calcul, ce que ferait
son bouton, sans jamais l'exécuter. `--snapshot x.png --conseils` rend le
bandeau pour chaque sorte de conseil, sur les relevés fabriqués des tests.

`--ajuste [dossier]` vérifie que le panneau tient dans l'écran d'Isma (zone
visible 2 056 × 1 290 pt) sur le relevé figé du banc : sept cartes avec le
forfait iPhone réglé, puis avec la carte Médias, sombre et clair, en popover
et en panneau détaché (chantier 13, barre de titre de 28 pt comprise), tailles
imprimées et rendus dans `.build/ajuste` ; échoue si le panneau ajusté
dépasse en hauteur ou en largeur. `./verifie.sh` le lance. `--snapshot x.png
--ecran 1920x1055` rend le panneau tel qu'il serait sur un autre écran (zone
visible, en points) ; sans `--ecran`, l'écran principal.
Fenêtres, widgets et Raccourcis (chantier 13, `Sources/Pulse/Window/`) :
`--snapshot x.png --fenetre` rend le panneau détaché, cadre et barre de titre
compris (la vraie fenêtre, jamais posée à l'écran) ; `--tableau [--largeur L
--hauteur H]` le tableau de bord ; `--widget disque|memoire|forfait|tous
[--taille petit|moyen]` les widgets, sur l'état que l'app écrirait à la
seconde. `--banc 60 --fenetre` (ou `--tableau`) mesure la surface fermée,
ouverte hors écran, puis refermée. `--probe`, section WIDGETS ET
RACCOURCIS : ce que diraient les widgets et les actions Raccourcis, et l'âge
de `etat-partage.json`.

Mouvement, verre et thèmes (chantier 10) — rien ne s'ouvre :
`--snapshot x.png --ouverture` rend la cascade d'ouverture image par image
sur une planche (0 à 300 ms) et mesure son coût ; `--carte <id> --ouverture`
pour une carte seule ; `--survol` dessine tous les contrôles survolés et une
bulle de graphique ; `--verre` pose le panneau sur des bandes criardes à la
place du verre de son cadre (rien de ce qui porte une donnée ne doit les
laisser voir) ; `--theme <id>` essaie un thème (`systeme`, `sombre`,
`clair`, `violet`, `indigo`, `accent`) sans l'écrire, mesuré ensuite par
`swift outils/contraste.swift sombre.png -` (« - » : thème d'une seule
apparence) ; `--ouvert <clé>` déplie un historique du panneau entier, pour
en mesurer la hauteur ; `--defilement` rend le miroir du débit à cinq
instants de son glissement entre deux relevés et mesure ce qu'il coûte.

Accessibilité (chantier 16) : `swift outils/relecture-ax.swift` lit à
l'API (`AXUIElementCopyAttributeValue`, pas System Events) ce que
VoiceOver et le clavier trouvent dans les fenêtres de Pulse ouvertes —
ordre de lecture, titres, éléments AXUnknown, contrôles sans nom ou hors
clavier ; `--attendre 90` attend qu'Isma ouvre le panneau, `--fichier x.txt`
garde le relevé. Il n'ouvre rien et ne demande aucune autorisation : sans
celle de l'app qui le lance, il le dit et s'arrête. Panneau fermé, il ne
lit que l'icône de la barre. `--ajuste --equilibre` (ou `--snapshot x.png
--equilibre`) rend la variante « colonnes équilibrées » du rangement,
inactive dans l'app (décision d'Isma, `docs/chantiers/16-audit-ux.md`).

Fenêtre Réglages cachée (19-suivis) : derrière Premiere en plein écran,
réduite ou sur un autre espace, elle gardait la cadence du panneau ouvert
tant qu'elle n'était pas fermée. Elle relit sa visibilité à chaque
changement d'occlusion et quand elle est réduite (`Surfaces.isSeen` : à
l'écran, pas réduite, pas entièrement recouverte) ; hors de vue, son
contenu est vidé, sa page gardée, et le relevé repasse à la cadence fermée.
Le panneau détaché et le tableau de bord, qui s'arrêtaient sur une fenêtre
réduite ou masquée (`isVisible` faux), suivent la même règle. `--banc 620
--reglages [page]` mesure la vraie fenêtre, jamais posée à l'écran, en cinq
phases de 120 s — fermée, visible, cachée comme avant (cadence ouverte,
contenu vivant), cachée, refermée — ; page « Mémoire », le 11/10 : fermée
0,24 %, visible 1,10 %, cachée 0,24 %, refermée 0,23 % d'un cœur. Cachée
comme avant, sur une seconde passe faite Mac sur batterie à 3 % (tout y
coûte 2 à 6 fois plus) : 6,00 % contre 0,64 % une fois cachée, 0,59 %
fermée.

Symboles et taille du binaire (19-suivis) : le binaire de SwiftPM pesait
9,2 Mo, dont 3,6 Mo de code (`__TEXT`), 0,3 Mo de données et 5,4 Mo de
`__LINKEDIT` — la table des symboles (noms Swift, ~30 000) et une carte de
débogage de 65 000 entrées qui renvoie aux `.o` de `.build/`, réécrits à
chaque compilation. `build.sh` en tire `Pulse.app.dSYM` à côté du bundle
(`dsymutil`, 1 s, ~21 Mo, non versionné), puis retire la carte du binaire
installé (`strip -S`) : 8,1 Mo. La table des symboles reste — un rapport de
plantage nomme chaque fonction quelle que soit la compilation d'où il
vient ; `strip -x` l'ôterait (4,2 Mo) et rendrait illisibles ceux d'une
compilation dont le dSYM a été remplacé depuis. Fichier et ligne d'une
adresse de la compilation en cours : `atos -o
Pulse.app.dSYM/Contents/Resources/DWARF/Pulse -arch arm64 -l <base de
l'image> <adresse>`. `./verifie.sh` plafonne le CODE ET LES DONNÉES du
binaire installé (`__TEXT`, `__DATA_CONST`, `__DATA`) à 6 Mo — 4,0 Mo le
11/10 —, ce qu'une ressource ou une bibliothèque embarquée par erreur fait
bondir, et imprime les symboles sans plafond : ils suivent le code.

Carte Médias figée (19-suivis) : `Releve.typique` porte aussi son état — GPU
au chiffre de la carte Processeur, encodeur au travail, cache de 109 Go,
l'export en cours et le fichier qu'il écrit — et une semaine d'exports
servie par `ExportHistory(figé:)`, sans journal d'AME ni exports.json ;
« aujourd'hui » y est l'heure du relevé (`Sampler.maintenantFige`). Elle
entre dans `Rendu.cartesFigees` : huit cartes comparées, 18 rendus.

## Règles et notifications (chantier 11)

Une règle surveille une mesure qu'un module publie déjà — espace libre
d'un disque, swap, forfait iPhone, réseau, export, plantage… — et prévient
quand sa condition tient : notification macOS (avec ou sans son), cloche
dans la barre de menus. **Toutes éteintes à l'origine** ; elles se règlent
dans la fenêtre Réglages, page « Règles et alertes ». Sept préréglages :
disque de rushes sous 100 Go, export terminé, Premiere a planté, forfait
iPhone à 80 % puis épuisé, swap qui monte, connexion perdue.

- **Un épisode, une notification.** Il commence quand la condition a tenu
  sa durée sans interruption ; il finit quand la mesure a repassé le seuil
  de sa marge (« sous 100 Go » finit au-delà de 110 Go) et y est restée le
  délai de sortie. Une valeur qui oscille autour du seuil ne produit pas
  dix notifications. Trois plantages en dix minutes en font une seule, qui
  dit « 3 fois ».
- **Pulse se tait en montage.** Au plus une notification toutes les 5 min,
  le reste regroupé dans la suivante ; tant que Premiere (ou une autre app
  de montage) est au premier plan, rien ne part, sauf règle cochée « même
  en plein montage » ; la cloche, silencieuse, s'allume tout de suite.
  Chaque notification est ordinaire, jamais « urgente » au sens de macOS :
  Ne pas déranger et les modes de concentration la retiennent. Hors de sa
  plage horaire, un état se dit à l'ouverture de la plage s'il dure encore,
  un événement se tait. Jamais de fenêtre qui s'ouvre.
- **Coût nul sans règle allumée** : ni abonnement au relevé, ni minuterie.
  Allumée, une règle s'évalue à chaque relevé du `Sampler` (5 s panneau
  fermé), sur des valeurs déjà mesurées ; le forfait une fois par minute.
- **L'autorisation de notifier** n'est demandée qu'au moment où Isma allume
  lui-même une règle qui notifie, et seulement si macOS ne l'a jamais posée.
  Jamais au lancement, jamais par `--probe`, `--snapshot`, `--banc` ou
  `swift test` : le moteur se teste avec un notificateur injecté.

`--probe`, section RÈGLES : chaque règle, sa condition en clair, la valeur
du moment de sa mesure et si la condition tient, l'état de l'autorisation,
puis le journal des 7 jours. `--snapshot x.png --reglages regles` rend la
page (`--ouvert <id>` déplie une règle) ; `--snapshot x.png --barre
--alerte` la barre avec sa cloche. `python3 outils/mutations-regles.py`
retire une à une les 28 corrections du moteur et vérifie que chaque test
échoue sans la sienne.

Horloges, calendrier, météo (chantier 18) — trois modules **désactivés par
défaut** : tant qu'Isma ne les active pas, rien ne tourne et rien n'est
demandé. `--snapshot x.png --carte horloges|calendrier|meteo --exemple` les
rend avec des personnes d'exemple, un agenda simulé et une réponse
Open-Meteo écrite d'après la documentation (`ExemplesMeteo`) ; sans
`--exemple`, chaque carte montre son état réel. `--probe` ajoute les
sections HORLOGES, CALENDRIER et MÉTÉO ; carte masquée, aucune n'appelle
EventKit ni le réseau. `--banc 60 --exemple`, dans une maison de rechange où
les trois sont activés, mesure leur coût. Ni la demande d'accès au
calendrier ni une requête météo ne partent ailleurs que dans l'app installée
(`Extras.appReelle` : bundle `.app`, persistance active, aucune option de
diagnostic) : `--snapshot`, `--probe`, `--banc`, `--rendus` et `swift test`
lisent les VRAIS réglages d'Isma, et un rendu lancé par un chantier ferait
sinon surgir la demande de macOS sur son écran — depuis un binaire nu, que
macOS ne connaît pas —, ou enverrait sa position à chaque `./verifie.sh`.

Ventilateurs (chantier 14) : `Pulse.app/Contents/MacOS/Pulse --snapshot
x.png --reglages ventilateurs` rend la page Ventilateurs des Réglages (depuis
le bundle : l'état du helper ne se lit que là) ; `--ventilateurs fixed|curve`
la montre dans un autre mode, EN MÉMOIRE. `--probe`, section VENTILATEURS :
le helper (absent, installé, sa réponse), le mode, chaque ventilateur, ce que
la vitesse fixe et la courbe enverraient, le journal du helper.
`.build/release/PulseHelper --simule` fait tourner les sécurités du helper
sur un SMC simulé, sans root : une consigne bornée, puis le retour en
automatique faute de battement, sur la sortie d'erreur.

Suites du 19 : un huitième préréglage, éteint, « Copie de rushes
terminée » — la fin d'une copie de carte ou entre disques vers un disque
externe, 1 Go au moins, constatée 60 s après la dernière écriture, panneau
fermé compris : « Copie de carte vers Ssd 2 · 128 Go en 14 min ».
Téléchargements et exports n'en sont pas. Le chantier 05 ne publie ses
épisodes clos vers le fil principal que si une règle allumée les écoute
(`DiskActivity.ecouteCopies`) : rien sinon. « Export terminé » nomme le
fichier et son issue, lus dans le journal d'AME relu sur la file du relevé,
un relevé après la fin : « Interview 6.mp4 · réussi · 4,2 Go », « 3 fichiers ·
1 échec : B.mp4 ». Sans ligne au journal, ou sans réponse en 20 s, la
notification dit l'app et la durée, comme avant.

## Ce qui est mesuré

| Métrique | Source | Privilèges |
|---|---|---|
| Mémoire (app, wired, compressée, cache) | `host_statistics64` | aucun |
| Pression mémoire | `kern.memorystatus_vm_pressure_level` | aucun |
| Swap | `vm.swapusage` | aucun |
| Processeur par cœur, clusters P et E | `host_processor_info` | aucun |
| GPU | IORegistry, `PerformanceStatistics` | aucun |
| CPU et mémoire par application | `libproc` | aucun (même uid) |
| Volumes, espace libre, prévision | `mountedVolumeURLs` | aucun |
| Temps par application | `NSWorkspace` | aucun |
| Sessions de montage | `NSWorkspace` | aucun |
| Export en cours | charge d'Adobe Media Encoder | aucun |
| Plantages Adobe | base Crashpad | aucun |
| Saturations de ressources | `/Library/Logs/DiagnosticReports` | compte **administrateur** |
| Températures (cœurs, carte graphique, SSD, batterie, air) | SMC en lecture seule ; HID `IOHIDEventSystemClient` en recoupement | aucun |
| Ventilateurs : vitesse, minimum, maximum, consigne | SMC (`F0Ac`, `F0Mn`, `F0Mx`, `F0Tg`) | aucun |
| Puissance et fréquences : processeur, carte graphique, moteur neuronal, mémoire | IOReport (`Energy Model`, `CPU Stats`, `GPU Stats`) et tables DVFS du `pmgr` | aucun |
| Pression thermique | `notify`, `com.apple.system.thermalpressurelevel` | aucun |
| Batterie : niveau, santé, cycles, température | `AppleSmartBattery` (IORegistry), `IOPowerSources` | aucun |
| Consommation de la machine (carte Énergie) | SMC `PSTR`, comme la carte Capteurs ; la jauge (`PowerTelemetryData`) en recoupement et pour les moyennes de l'historique | aucun |
| Santé telle que l'affiche macOS | `system_profiler SPPowerDataType`, toutes les 6 h au plus | aucun |
| Chargeur, mode d'énergie | `IOPSCopyExternalPowerAdapterDetails`, `IOPMCopyActivePMPreferences` | aucun |
| AirPods, souris, claviers à batterie | `IOPSCopyPowerSourcesByType` (powerd), IORegistry HID | aucun — **pas** d'autorisation Bluetooth |
| Lecture et écriture par disque physique | IORegistry, `Statistics` des `IOBlockStorageDriver` | aucun |
| Lecture et écriture par application | `proc_pid_rusage`, `ri_diskio_*` | aucun (même uid) |
| Disque qu'une application écrit | fichiers ouverts en écriture, `PROC_PIDFDVNODEINFO` | aucun (même uid) |
| Santé des SSD : état, usure, température, écrits à vie | journal SMART NVMe, plug-in `NVMeSMARTLib` | aucun |
| Ce qui remplit un volume : octets arrivés par dossier, 24 h et 7 j | index Spotlight (`MDQuery`, `kMDItemDateAdded`) | aucun |

Températures, ventilateurs, puissance et fréquences se lisent SANS `sudo`
(vérifié le 11/10 depuis le binaire compilé, signé ad hoc) : seul
`powermetrics` l'exige, et Pulse ne s'en sert pas. Les encodeurs ProRes et
moteurs médias relèvent du chantier 08.

Réseau, chantier 07 — tout panneau ouvert seulement, rien panneau fermé :

| Métrique | Source | Privilèges |
|---|---|---|
| Débit par application, RTT des connexions TCP | cadre privé `NetworkStatistics` (celui de `nettop`) | aucun |
| Latence de la passerelle, **sur réglage** | 2 échos ICMP, socket `SOCK_DGRAM` / `IPPROTO_ICMP` | aucun, mais macOS 15 peut demander l'accès au « réseau local » : désactivé par défaut |
| Latence vers Internet | le plus court des RTT des connexions TCP actives : **passif**, aucun octet envoyé | aucun |
| Signal Wi-Fi : RSSI, bruit, débit de liaison, canal, norme | CoreWLAN | aucun — **pas** d'autorisation de localisation |
| IP locales, passerelle, DNS | `getifaddrs`, SystemConfiguration | aucun |
| Forfait iPhone du mois | cumul du partage iPhone dans `reseau.json` | aucun |
| IP publique, ping Internet | `api.ipify.org`, `1.1.1.1` — **désactivés par défaut**, sortent sur Internet | aucun |

Extras, chantier 18 — désactivés par défaut, rien ne tourne carte masquée :

| Métrique | Source | Privilèges |
|---|---|---|
| Heure par personne, lever et coucher du soleil | `TimeZone` ; soleil calculé sur le Mac (NOAA), coordonnées d'une table de 86 villes, sinon `/usr/share/zoneinfo/zone.tab` | aucun — **pas** de localisation |
| Prochains événements | EventKit, dans l'app installée seulement | autorisation Calendriers, demandée à l'activation de la carte |
| Météo heure par heure et sur 7 jours | Open-Meteo (`api.open-meteo.com`, sans clé), une requête au plus toutes les 30 min panneau ouvert, toutes les heures fermé | aucun, mais **sort sur Internet** : la position de la ville choisie, au centième de degré |

Ventilateurs, chantier 14 — le seul endroit où Pulse ÉCRIT au matériel, et
seulement sur accord : un helper root (`PulseHelper`) installé par Isma avec
son mot de passe, qui écrit `F<n>Md` (mode imposé) et `F<n>Tg` (consigne,
bornée par `F<n>Mn` et `F<n>Mx` relus à chaque fois). L'app, elle, reste en
lecture seule. Voie, sécurités et revue : `docs/chantiers/14-ventilateurs.md`.

## Pièges vérifiés, à ne pas réintroduire

Chacun de ces points a été mesuré sur la machine. Ce ne sont pas des précautions
théoriques : chacun correspond à un bug qui a réellement existé dans ce code.

**Adobe ne produit aucun `.ips`.** `crashpad_handler` installe son propre
gestionnaire d'exception et empêche `ReportCrash` d'Apple d'écrire quoi que ce
soit. Vérifié : trois plantages Premiere le 24 août, zéro rapport système. Les
vrais plantages sont dans
`~/Library/Caches/Adobe/<App>/<Version>/SentryIO-db/{completed,pending}/*.dmp`,
datés par l'attribut étendu `org.chromium.crashpad.database.creation_time`. Une
détection de plantage fondée sur les seuls rapports système serait
**silencieusement inopérante**.

**`pti_total_user` n'est pas en nanosecondes.** Ce sont des unités de temps
mach. La timebase vaut 125/3 sur ce M2 Max, soit 41,67 ns par unité : les lire
comme des nanosecondes divise le CPU par 41,67. Sur Intel la timebase est 1/1,
ce qui masque complètement l'erreur — d'où son abondance dans les exemples en
ligne.

**`pti_resident_size` n'est pas ce qu'affiche macOS.** Il ignore les pages
compressées et les allocations IOSurface/GPU, décisives en mémoire unifiée.
Écart mesuré jusqu'à 41× sur un service de décodage vidéo. La bonne valeur est
`ri_phys_footprint` de `proc_pid_rusage` avec `RUSAGE_INFO_V6`. (Cette structure
n'a **pas** de champ `ri_shared_footprint` : on ne peut pas dédupliquer la
mémoire partagée par cette voie.)

**Apple mélange les conventions d'unités.** Décimal pour le stockage (Finder,
Utilitaire de disque), binaire pour la mémoire (`system_profiler`, `top`,
`sysctl`). D'où deux fonctions distinctes : `Fmt.bytes` en base 1000 pour les
volumes, `Fmt.memory` en base 1024 pour la mémoire et le swap. Un basculement
global vers l'une ou l'autre casse la moitié de l'affichage.

**`xsu_total` n'est pas un plafond de swap** mais la taille des fichiers
actuellement alloués, que macOS agrandit à la demande — observé passer de 2 à
9,7 Gio en une soirée. L'afficher en dénominateur donnait un ratio collé autour
de 90 % quel que soit l'état réel.

**Le décodeur `Codable` synthétisé de Swift lève `keyNotFound`** sur une clé
absente, même quand la propriété a une valeur par défaut. Combiné à un `try?`,
cela effaçait tout l'historique dès qu'un champ était ajouté au schéma. D'où le
`init(from:)` écrit à la main dans `HistoryStore.File` et `EditingSession`, en
`decodeIfPresent` sur chaque champ. **Tout nouveau champ persisté doit suivre la
même règle.**

**Les points de montage ne sont pas stables.** Le SSD externe de la machine est
remonté tantôt en `/Volumes/Ssd`, tantôt en `/Volumes/Ssd 2`. L'historique est
donc indexé par UUID de volume, jamais par chemin.

**Une régression linéaire ne résiste pas à une marche d'escalier.** La pente
de remplissage d'un volume était estimée aux moindres carrés sur tous les points
de la fenêtre. Vérifié le 25 août : 207 Go supprimés du disque de rushes en
17 minutes, puis 14 h de remplissage lent. La régression annonçait « se vide de
172,0 Go par jour » quand le volume se remplissait de 3,2 Go par jour. Le signe
étant inversé, `daysUntilFull` restait `nil` : le disque à 90 % ne pouvait
déclencher aucune alerte, soit exactement la situation que la prévision existe
pour signaler. Réduire la fenêtre de 30 jours à 72 h n'y change rien et aggrave
même le cas récent — plus la fenêtre est courte, plus une opération unique y
pèse. Chaque intervalle est donc jugé séparément, et ceux qui portent une
opération en masse sont écartés (`HistoryStore.forecast`).

Le seuil de débit sépare une **copie** d'un **travail**, et se règle par le bas,
pas par le haut : à 400 Go par jour il rejetait 3,3 Go écrits en 10 minutes,
donc tous les intervalles d'un export ProRes — soit précisément les moments où
le disque se remplit. Il est à 5 To par jour, entre les 30 Mo/s d'un export et
les 200 à 400 Mo/s d'une ingestion de carte.

**Le CPU de Premiere ne dit pas s'il exporte.** C'était la piste évidente, et
elle est fausse. Relevé le 25 août sur un export réel passé par Media Encoder,
68 mesures à 3 s conservées dans `outils/reference-export-2026-08-25.csv` :

| Signal | Au repos | Pendant l'export | Sépare ? |
|---|---|---|---|
| CPU d'Adobe Media Encoder | 0,0 à 31,3 % | 102 à 231 % | **oui** — marge ×3 |
| CPU des `VTEncoderXPCService` | **0,0 %** sur 56 relevés | 2,3 à 4,7 % | oui, mais quelques % d'un cœur |
| CPU des `VTDecoderXPCService` | 0,0 à 9,0 % | 5,3 à 34,3 % | non — plages confondues |
| CPU de Premiere | 0,0 à 286 % | 161 à 282 % | non — le maximum est **hors** export |

Le maximum de Premiere au repos dépasse son maximum pendant l'export : aucun
seuil ne peut exister là. La détection porte donc sur Media Encoder, seuil à
60 % d'un cœur, posé entre les deux bornes mesurées (`ExportDetector`).

La présence des processus ne vaut rien non plus : 13 `VTEncoderXPCService`
vivants pendant une simple lecture, et leur nombre ne bouge pas davantage
pendant un export. VideoToolbox garde ses services au chaud.

**Les diagnostics « disk writes » sont du bruit.** Le seuil est de 2 Gio écrits
sur 24 h, franchi par n'importe quel export. Ils représentaient 39 des 70
rapports. Ils sont volontairement écartés (`bug_type` 45).

**Les diagnostics « cpu usage » aussi.** Seuil : 50 % d'UN cœur tenus 3 min.
Relevé le 09/10 : les 12 « CPU saturé » des 14 derniers jours étaient tous
Premiere, à 63 % d'un cœur — quand une simple séance de montage le fait tourner
à 187 %. macOS écrit lui-même « Action taken: none ». Le panneau affichait « 11
incidents » pour zéro panne. Écartés (`bug_type` 22) : seuls comptent les
plantages Adobe et les processus tués par macOS faute de mémoire.

**Un verdict qui change 36 fois par jour ne se lit plus.** Seize jours de
journal (24/09 → 09/10) : 35,7 changements par jour. 249 bascules allaient et
venaient entre « La mémoire commence à manquer » et « Le swap monte », le même
problème sous deux phrases — la pression mémoire élevée tenait 30 s en médiane.
L'hystérésis par règle (3 s / 10 s) ne pouvait rien contre deux règles VRAIES
qui se passent la tête. Désormais un nouveau verdict ne remplace l'affiché que
s'il gagne depuis 5 min, sauf aggravation, qui passe tout de suite. Rejoué sur
le journal (`outils/rejoue-verdicts.py`) : 7,3 changements par jour. Le
comportement est vérifié sur le moteur réel par `swift test`, et chaque test a
été vu échouer sans la correction.

**Une rafale finie n'est pas un rythme.** Nuit du 08/10 : 650 Go écrits sur
Ssd 2 en 7 h, à 7 Go les 10 min — trop lent pour passer pour une opération en
masse —, puis 596 Go effacés d'un coup, écartés eux. La pente des 72 h ne
voyait que le remplissage : « plein dans ~8 jours » sur un disque immobile
depuis 30 h. La prévision retient désormais le plus lent des deux rythmes,
72 h ou 24 h : elle ne crie jamais plus fort qu'avant, et tait une rafale
terminée.

**Une image disque se lit pleine à 100 %.** Un installateur monté
(« FilmCraft 0.4.0 », 136 Mio, lecture seule) affichait en rouge « FilmCraft 0…
est plein à 100 % ». Les volumes en lecture seule ne se remplissent jamais :
écartés, sauf la racine — que la clé ne marque d'ailleurs pas comme telle.

**Ne jamais activer App Sandbox.** `codesign --force --sign -` sans entitlements
est ce qui rend possible la lecture de `/Library/Logs/DiagnosticReports` et du
dossier Caches d'Adobe. Le sandbox couperait toute la section Incidents, quels
que soient les droits POSIX.

**Les couleurs sont choisies sur mesure de contraste.** `systemOrange` est à
2,00:1 sur fond clair — invisible. `tertiaryLabel` est à 1,87:1. `.accentColor`
suit le réglage de l'utilisateur et tombe à 1,37:1 en accent jaune : elle ne
code donc jamais une donnée. Voir `UI/Palette.swift`, où chaque teinte porte son
ratio mesuré dans les deux apparences.

**Un `NSStatusItem` sans titre ne dessine rien.** Sur macOS 26, un bouton qui
porte une image et aucun titre réserve sa largeur dans la barre de menus et reste
transparent — image pourtant valide, 496 pixels opaques, vérifiée en la vidant
sur disque. Le pourcentage est donc le titre du bouton, et seul le débit empilé
est une image. La largeur de l'icône est figée sur le pire cas : en largeur
variable, le débit qui change toutes les 2 s ferait danser les icônes voisines.

**La position d'une icône ne prouve pas qu'elle se voit.** Quand la barre déborde,
macOS cache les icônes les plus à gauche sans changer leur position
d'accessibilité. Relevé le 07/10 : une pastille de caméra apparue pendant un
appel a effacé Lightshot et Pulse, toujours annoncés à x = 1170, dans la zone
visible. Seule une capture de la barre tranche. Et sur macOS 26, la préférence
« NSStatusItem Preferred Position » n'a plus d'effet : l'ordre se règle au
glisser avec ⌘.

**`RegisterEventHotKey` attend une position de touche, pas un caractère.**
`kVK_ANSI_M` est la place du M sur un QWERTY ; sur l'AZERTY de cette machine elle
produit une virgule. Le raccourci était enregistré sur une touche que personne ne
presse, et le test automatique passait quand même : il envoyait le code 46,
précisément celui qu'on attendait. La touche se résout depuis la disposition
active (`UCKeyTranslate`) et se réenregistre quand elle change.

**`NSPopover.show` échoue en silence sans fenêtre d'ancrage visible.** En plein
écran la barre de menus est masquée, le bouton de l'item n'a plus de fenêtre, et
le popover ne s'ouvre pas — le raccourci semblait mort alors qu'il arrivait bien.
Un ancrage de secours `fullScreenAuxiliary` prend le relais. Et un popover
`.transient` ouvert au clavier se refermait dans la seconde, Premiere reprenant le
focus : ouvert au raccourci, il reste jusqu'au suivant.

**La fenêtre du popover ne s'anime pas quand son contenu grandit.**
`sizingOptions = [.preferredContentSize]` remonte la taille IDÉALE du contenu, pas
sa taille animée : mesuré, la hauteur passe de 1129 à 1069 en une frame. Animer le
contenu par-dessus produisait un décalage, pas une transition.
`NSPopover.animates` ne gouverne que l'apparition et la fermeture.

**SwiftUI ne teste le clic que sur les pixels dessinés.** Sans
`.contentShape(Rectangle())`, l'espace d'un `Spacer` entre un titre et sa valeur
ne répond pas. Avec des en-têtes de 13 pt de haut, c'était « je dois cliquer
trois fois ».

**`volumeAvailableCapacityForImportantUsage` rend parfois 0.** Relevé sur SSD 1,
un APFS externe : « 0 o libres » à l'écran, 240 Go selon `df` et `diskutil`, une
heure après avoir rendu la bonne valeur. Cette clé contient par définition tout le
libre strict ; celui-ci lui sert de plancher. Sans quoi un 0 fantôme donnerait à
la prévision « plein dans moins d'un jour ».

**Une prévision sans échéance ne veut pas dire que le volume se vide.** L'échéance
est tue au-delà de 400 jours : un disque qui se remplit lentement n'en a pas non
plus. La formule d'origine écrivait « se vide de -3,0 Go par jour ».

**L'hystérésis ne s'applique pas au premier relevé.** Le délai d'entrée de 3 s
empêche un relevé fugace de changer un verdict établi ; appliqué au lancement, il
laissait la liste vide, donc « La machine suit » — constaté par le journal : feu
vert à t+0, « Macintosh HD est plein à 96 % » à t+5.

**Pour vérifier l'accessibilité, ne pas passer par System Events.** Sur macOS 26,
SwiftUI range le nom d'un élément dans `AXAttributedDescription`, une chaîne
enrichie que System Events ne sait pas lire : un bouton parfaitement nommé y
paraît anonyme. Lire l'arbre avec `AXUIElementCopyAttributeValue`. Et un
conteneur en `.accessibilityElement(children: .ignore)` sort avec le rôle
`AXUnknown` ; `.combine` en fait un `AXStaticText` qui se lit.

**`SMAppService.mainApp` ne sait rien hors bundle.** Lancé en binaire nu depuis
`.build/`, il rend `.notFound` même quand l'élément d'ouverture est bien
enregistré. D'où l'appel depuis `Pulse.app` pour lire cet état.

**L'écran fait 2056 × 1329 points, pas 1728.** Il est en résolution mise à
l'échelle. Des captures `screencapture -R` calées sur 1728 ont visé les mauvais
pixels et conduit à un faux diagnostic — une icône « invisible » qui s'affichait
très bien. La géométrie imprimée par `--show` fait foi.

**macOS ne livre que 32 bits des compteurs réseau à une app tierce.** Relevé le
07/10 : `netstat` et un script lancé par l'outil `swift` lisent 12,7 Go reçus
depuis le démarrage ; le même code compilé — optimisé ou non — lit 4,15 Go,
les 32 bits de poids faible arrondis au kilo-octet. Le compteur repasse à zéro
tous les 4,29 Go, soit quelques minutes d'envoi de rushes. Toute lecture
absolue est fausse ; seuls les écarts entre deux relevés rapprochés, calculés
modulo 2³², ont un sens. Piège dans le piège : un test lancé par `swift
fichier.swift` voit les vrais 64 bits et passe, alors que l'app échoue.

**Un popover refermé continue de se dessiner.** Relevé le 09/10 : panneau
fermé, Pulse dépensait 8,2 % d'un cœur dès qu'il avait été ouvert une fois, et
occupait 238 Mo. Sa vue SwiftUI, créée au lancement, restait abonnée au
sampler : chaque relevé la recalculait et rejouait l'animation des chiffres,
image par image, dans une fenêtre retirée de l'écran. Le contenu est désormais
créé à l'ouverture et vidé à la fermeture (`AppDelegate.makeContent`). Avec
trois économies de plus — disques relus toutes les 2 min panneau fermé,
processus identifiés une seule fois, libellé redessiné seulement s'il change —,
Pulse fermé tombe à 0,67 % d'un cœur (5 min de mesure), 0,84 % et 66 Mo après
une ouverture réelle. Mesurer avec le temps CPU cumulé, `ps -o time=`, sur
plusieurs minutes : le même processus a donné 5,6 % sur 30 s et 8,2 % sur 2 min.

**Le fond d'un popover n'est plus celui qu'on croit.** Sous macOS 26,
`windowBackgroundColor` rend #414141 dans le popover — lu sur une capture
réelle du panneau (09/10) et sur le rendu hors écran, identiques. Les ratios de
`Palette` avaient été mesurés sur #2F2F2F, et les couleurs système ont changé
avec macOS 26 (bleu sombre #0091FF au lieu de #0A84FF). Sur les cartes du
panneau façon iStat (#4F4F4F), le bleu, le rouge et le violet tombaient à
2,2–2,5:1. Le fond sombre est désormais fixé à #1E1E1E (`Palette.panel`), et
chaque teinte se remesure sur le rendu avec `outils/contraste.swift` : toutes
entre 3,16 et 5,14:1 le 11/10.

**Un `ForEach` aux identités en double répète un élément.** Le 08/10, le Mac
est passé par quatre Wi-Fi ; tous s'appellent « Wi-Fi », et le dépliant
internet les identifiait par leur nom. SwiftUI a dessiné quatre fois le plus
gros segment : la colonne de jeudi montait de 150 pt au-dessus du panneau et
recouvrait les volumes. `NetworkTracker.history` fusionne désormais par sorte
de réseau, et le dépliant s'identifie par sorte — unique par construction.
Reproduit puis vérifié avec `--snapshot`, sans ouvrir le popover.

**Le mouvement est un ressort, jamais une durée fixe.** Le sampler publie
toutes les 1,5 s quand le popover est ouvert : chaque animation est interrompue
par la suivante avant d'avoir fini. Un ressort repart de la valeur affichée et
absorbe l'interruption ; une courbe à durée fixe repart de la cible et saute à
chaque relevé. Amortissement critique, aucun rebond — un dépassement suggérerait
l'inertie d'un objet lancé à la main, alors que ce sont des mesures qui
arrivent. Le tout suit « Réduire les animations » de macOS, où les valeurs
redeviennent instantanées sans rien perdre en exactitude (`UI/Motion.swift`).

**`.map(Double.init)` sur un entier non signé lit des bits, pas un nombre.**
Sur un `UInt64`, Swift choisit `Double(bitPattern:)` : le nombre de
ventilateurs lu au SMC (`FNum`, 2) devenait 1e-323, celui des clés (`#KEY`,
2 410) 1e-320, et la carte n'affichait aucun ventilateur sans la moindre
erreur. Écrire `{ Double($0) }`. Vu le 11/10, couvert par
`SensorDecodingTests`, vu échouer sans la correction.

**Températures et ventilateurs ne demandent pas `sudo`.** Le SMC s'ouvre et se
LIT sans privilège ; seule l'écriture (piloter un ventilateur) exige root, et
Pulse n'en a pas la commande (`SMCCommand`). Sur ce M2 Max, le détail par
cœur n'existe qu'au SMC : HID ne publie que la puce vue par ses contrôleurs
d'alimentation (« PMU tdie »), le SSD et la batterie. Les deux voies se
recoupent sur la puce à 0,1 °C (`--probe`, section CAPTEURS).

**Chaque `IOReportCopyChannelsInGroup` parcourt tous les pilotes.** 130 ms de
CPU par groupe, quel qu'il soit : 390 ms pour s'abonner à l'énergie, aux
états des cœurs et à ceux de la carte graphique. Une seule copie de tous les
canaux (`IOReportCopyAllChannels`, 10 092 sur ce M2 Max), filtrée ensuite,
coûte 145 ms (`IOReportSampler`, mesuré le 11/10). Et la carte graphique
déclare quinze états de performance pour huit fréquences dans sa table
DVFS : les sept de trop restent vides, on le vérifie à chaque lecture.

**La température de la batterie n'est pas en centièmes de degré.** C'est la
lecture qu'on trouve partout pour la clé `Temperature` de l'`AppleSmartBattery` ;
sur ce M2 Max elle est en dixièmes de kelvin. Relevé le 11/10 au même instant :
3 071, soit 34,0 °C, quand les trois sondes SMC de la batterie (TB0T, TB1T,
TB2T) lisaient 33,8 · 32,6 · 33,8 °C et les capteurs HID « gas gauge battery »
33,0 à 34,2 °C ; lue en centièmes, elle donnerait 30,7 °C, sous toutes les
sondes. `VirtualTemperature`, elle, est bien en centièmes, et suit la première
à 0,1 °C près : c'est le recoupement que `--probe` imprime à chaque lecture.

**`system_profiler` annonce « Low Power Mode: Yes » sur secteur, à tort.** Le
réglage « Mode d'énergie » vit sous la clé historique `LowPowerMode`, qui vaut
désormais 0 (automatique), 1 (économie) ou 2 (haute performance) ;
`system_profiler` la lit en booléen. Sur ce Mac elle vaut 2 sur secteur
(`pmset -g` : `powermode 2`), et l'économie d'énergie est inactive selon
`ProcessInfo` comme selon `IOPowerSources` (« LPM Active » = 0). Pulse lit la
valeur entière.

**La santé de la batterie a deux chiffres, et macOS n'en donne qu'un.** Les
Réglages affichent 81 % ; capacité nominale sur capacité d'origine donne 82 %
(7 150 sur 8 694 mAh), la pleine charge du moment 79 % (6 906 mAh). powerd
lisse la sienne dans le temps et ne la livre directement qu'aux binaires
d'Apple : `IOPSCopyPowerSourcesByTypePrecise` rend `kIOReturnNotPrivileged`
(0xe00002c1) à un binaire signé ad hoc. Pulse lit donc le chiffre des
Réglages par `system_profiler -json SPPowerDataType` — 0,09 s de processeur,
une fois au plus toutes les 6 h —, et retombe sur le calcul s'il échoue.

**Les batteries Bluetooth se lisent sans le Bluetooth.** `IOBluetooth` et
`CoreBluetooth` déclenchent la demande d'autorisation Bluetooth de macOS, à
l'écran, au premier appel. Les niveaux des AirPods (gauche, droite, boîtier)
et des accessoires sont publiés par powerd pour le widget Batteries :
`IOPSCopyPowerSourcesByType(4)` les rend sans rien demander, y compris pour
des AirPods à portée mais reliés à l'iPhone. Les Magic Mouse, Keyboard et
Trackpad publient en plus `BatteryPercent` dans l'IORegistry. Pulse ne touche
jamais au Bluetooth lui-même.

**Une vue SwiftUI hors de toute fenêtre ne se met plus à jour.** Pour mesurer
le panneau ouvert sans l'afficher, `--banc` crée son contenu comme l'app. Hors
fenêtre, la vue restait figée : 2 réveils par seconde, ceux du seul relevé —
le banc aurait mesuré un panneau mort. Posée dans une fenêtre jamais mise à
l'écran, elle suit le sampler comme dans le popover : 9 à 13,5 réveils par
seconde. Le mécanisme du défaut du 09/10, vu de l'autre côté : une fenêtre
absente de l'écran n'arrête rien.

**`swift test` ne voit pas les couleurs système comme l'app.** Rendu dans le
processus des tests, le fond clair du panneau (`windowBackgroundColor`) sort
en #FFFEFF ; dans le binaire de Pulse, en #EFEFEF — celui d'une capture
réelle. Des références produites par les tests montraient des cartes blanches
sur fond blanc, et les auraient défendues. Les rendus de référence se font
donc dans le binaire (`--rendus`) ; les tests ne vérifient que ce qui ne
dépend pas de l'apparence : un rendu stable, une comparaison qui voit un
chiffre changer.

**Un seuil de 10 s pile donne un point toutes les 15 s.** La série d'une heure
de history.json devait tomber toutes les 10 s ; relevé le 11/10 sur le vrai
fichier, 196 points : 14,85 s en médiane. Le Sampler relève toutes les 5 s
panneau fermé, à la gigue de la minuterie près, et `now - dernier > 10`
manque le relevé de 10,0 s une fois sur deux. L'historique longue durée ferme
donc sa fenêtre à 9,5 s : un point toutes les 10 s, mesuré par
`HistoryTests`.

**Une base remplie série par série pèse 70 % de trop.** Pour estimer la taille
à 90 jours, remplir chaque série d'un bloc donnait 33,4 Mo pour 17 séries :
des pages B-tree pleines à 55 %. L'app écrit dans l'ordre du temps, toutes
séries mêlées ; rempli dans cet ordre, puis purgé comme le fait l'app, le même
contenu tient en 21,4 Mo, pages pleines à 88–91 % (`dbstat`), rotation de 30
jours comprise. Une mesure de taille ne vaut que dans l'ordre d'écriture réel.

**Lire une base SQLite en WAL, c'est écrire.** Un lecteur d'un autre processus
— `--probe`, `--snapshot`, `--banc` — inscrit ses marques de lecture dans le
fichier `-shm` : `verifie.sh` l'a relevé le 11/10, « écriture dans les données
de Pulse malgré la persistance coupée ». L'historique est donc en journal de
retour arrière, où un lecteur ne pose que des verrous ; une base restée en WAL
se lit « immuable » (`immutable=1` : ni verrou ni `-shm`) jusqu'à sa
conversion par l'app.

**Une clé (série, temps) écrit dix fois trop.** Chaque série a ses pages : un
lot de 5 min salissait au moins une page par série et par étage, et le
journal de retour arrière les écrit deux fois — 16,1 Mo par heure mesurés. En
(temps, série), un lot s'ajoute à la fin sur quelques pages, la purge retire
des pages entières au début : 2,9 Mo par heure. Lire une seule série parcourt
alors les lignes de toutes : mesuré sur une base pleine, 14 ms pour 90 jours,
2 ms pour 24 h, sur la file de l'historique.

**Un bloc passé à une fonction C trouvée par `dlsym` doit être `@escaping`.**
Dans un type `@convention(c)`, un paramètre bloc est non échappant par défaut :
Swift vérifie qu'il n'a pas été retenu, et NetworkStatistics le retient
toujours. Résultat le 11/10 : « closure argument passed as @noescape to
Objective-C has escaped », arrêt net au premier socket. Chaque bloc de
`SuiviSockets.API` est donc déclaré `@escaping`, et `SuiviSocketsTests`
démarre le vrai suivi à chaque `swift test` : sans `@escaping`, le processus
de test meurt avec le même message.

**NetworkStatistics livre deux dictionnaires, et il faut les deux.** La
DESCRIPTION d'un socket dit qui (`processName`, `processID`, `epid`), où
(interface, adresse distante) et l'état TCP, mais ses compteurs y sont à zéro ;
les COMPTES portent `rxBytes`, `txBytes` et `rttAverage`, mais leur identité
est vide. Et `rttAverage` est en SECONDES : 0,0895 pour les 89,50 ms que
`nettop` affiche sur la même connexion. Décrire tous les sockets à chaque
relevé coûtait 8,3 ms de processeur ; chaque socket est désormais décrit à son
arrivée, et le tout une fois sur cinq : 0,40 % d'un cœur panneau ouvert,
0,26 % désormais (banc de 60 s).

**Le premier ping réveille la radio Wi-Fi.** La même passerelle a répondu en
3,4 ms puis en 70 ms d'un relevé à l'autre : la carte Wi-Fi sortait de son
économie d'énergie. Deux échos à 100 ms d'écart, le plus court retenu
(`Ping.meilleur`), mesurent la liaison et pas le réveil.

**La couleur de lien du système n'est pas lisible sur la carte sombre.**
`NSColor.linkColor` y tombe à 4,08:1 (#419CFF sur #393939), sous les 4,5:1
du texte. « Régler le forfait » est donc une ligne à chevron en
`.secondary`, comme « 7 derniers jours ».

**Le rythme du forfait se divise par les jours comptés, pas par le cycle.**
Le cumul de `reseau.json` a commencé le 07/10, le cycle d'Isma le 01/10 :
divisé par tout le cycle, le partage iPhone donnait 566 Mo par jour au lieu de
1,4 Go, et l'échéance « épuisé vers le … » arrivait deux fois trop tard.

**Le débit disque d'une application ne dit pas sur quel disque elle écrit.**
`ri_diskio_byteswritten` compte des octets, pas une destination. Relevé le
11/10 : Ssd 2 écrivait 5,8 Mo/s de proxies ffmpeg ; Xcode écrivait 3,1 Mo/s
— sur le disque interne — et ffmpeg 2,5 Mo/s. Rapprocher les débits
désignait Xcode. L'écrivain d'un disque est désormais l'application qui y
tient un fichier ouvert EN ÉCRITURE (`WrittenDevices`, périphérique lu par
`PROC_PIDFDVNODEINFO`, sans chemin) ; aucune : « écrivain non identifié »,
jamais deviné. Couvert par `IngestionTests`, vu échouer avec l'ancienne règle.

**Le journal SMART se lit sans root, mais pas à travers tous les boîtiers.**
Le plug-in `NVMeSMARTLib` d'IOKit rend la page SMART de tout contrôleur qui
publie « NVMe SMART Capable » : le SSD interne et, malgré sa liaison USB, le
SanDisk Extreme Pro (relevé le 11/10 : 47 °C, usure 0 %). Le boîtier ASMedia
ASM246X de Ssd 2 et le Lexar E300 ne relaient rien : Pulse écrit « non
publiée » plutôt qu'un état inventé. Lecture en 1 à 4 ms, toutes les 10 min.

**Le client SMART est exclusif, et `Release` ne le rend pas.** Deux pièges
relevés le 11/10 en lançant trois lecteurs à la fois (ce que fait
`./verifie.sh`) : un seul lit, les autres voient la création du plug-in
échouer en `kIOReturnNoResources` (0xe00002be) — pas en
`kIOReturnExclusiveAccess`, qu'on attendait et qu'on testait. Et après un
simple `Release` du plug-in, le client reste tenu jusqu'à la fin du
processus : Pulse, qui ne finit jamais, en aurait privé DriveDx, smartctl et
ses propres relectures. `IODestroyPlugInInterface` le rend aussitôt ; un
client pris se retente quatre fois en 0,5 s, et l'app garde la valeur connue.

**Le disque interne écrit sans application visible.** 15,7 Mo/s relevés le
11/10 sans un seul processus de l'utilisateur au-dessus de 1 Mo/s : le swap
et les services du système, d'un autre compte, illisibles sans root. La
détection d'ingestion ne porte donc que sur les disques externes — sur
l'interne chaque épisode serait anonyme, et le swap ne remplit pas le disque.

**L'historique FSEvents d'un disque externe repart de zéro.** Relevé le
11/10 : environ 3 jours d'historique sur le disque interne, moins de 6 h sur
Ssd 2. On ne peut pas, avec lui seul, dire quels dossiers ont grossi en
7 jours ; la date d'ajout de chaque fichier (`kMDItemDateAdded`) le peut.

**« Ce qui remplit » se demande à Spotlight, pas au disque.** Parcourir
Ssd 2 (58 000 fichiers) à priorité d'arrière-plan, pendant qu'un ffmpeg y
lisait des rushes, n'avait pas fini en 7 min 45 : le noyau bride à juste titre
une lecture de fond. L'index que macOS tient déjà répond à la même question —
943 fichiers arrivés en 7 jours, 810 Go, dont 385 dans Client A › 01 Rushes —
pour 0,27 s de processeur côté Pulse. La réponse a mis 89 s à venir, machine
chargée : c'est `mds` qui travaille. D'où une requête toutes les 30 min, sur
sa propre file, jamais celle du relevé, et un `--probe` qui montre le dernier
bilan de l'app sans refaire la requête (`--probe --remplissage` la refait,
bornée à 20 s) : refaite d'office, elle portait le relevé de 13 à 53 s.

**Un transcodage n'est pas une copie.** Pendant que Ssd 2 recevait 3,1 Mo/s
de proxies, le disque interne lisait 109 Mo/s pour d'autres processus, et la
première règle (« un autre disque lit au moins la moitié de ce que la cible
écrit ») annonçait « Copie depuis Macintosh HD ». Une copie lit autant qu'elle
écrit : la source doit lire entre la moitié et le triple de l'écriture, et le
disque interne n'est désigné que si l'écrivain lui-même lit ce qu'il écrit —
ffmpeg lisait dix fois plus. Couvert par `IngestionTests`.

**IOReport ne publie ni le décodeur vidéo ni ProRes.** Relevé le 11/10 sur ce
M2 Max, sans root : l'encodeur vidéo (`AVE0`, mJ), le scaler (`MSR0`), le
moteur neuronal et le GPU (`GPU Energy`, en nJ — pas en mJ comme les autres)
ont un canal d'énergie ; le décodeur (`AppleAVD`) et les deux moteurs ProRes
(`AppleProResHW`) n'en ont aucun, ni d'énergie ni d'état. La carte Médias les
dit « non mesurables » plutôt que de les afficher à 0. La résidence de la
grappe `AVEMSR` ne prouve pas un encodage : elle est allumée 21 % du temps au
repos, pour le scaler de l'affichage.

**Le journal d'AME est en UTF-16, et le découper en lignes coûte cher.**
`AMEEncodingLog.txt` (3,4 Mo, 48 000 lignes, marque FF FE) : découpé en
`String` puis rogné ligne à ligne, il prenait 209 ms au repos et 1,3 s sous
charge. Lu en octets UTF-8, seules les trois lignes utiles d'un bloc devenant
du texte, et les dates converties à la main plutôt que par `DateFormatter` :
23 ms. Il n'est relu que quand sa date ou sa taille change — un `stat` de
69 µs par relevé, panneau fermé.

**Un bouton AppKit ne se dessine pas hors écran.** `ImageRenderer` remplace un
`Button` au style système par un pavé jaune barré (relevé le 11/10 sur la
carte Médias, en `--snapshot`). Un bouton de carte prend `.buttonStyle(.plain)`,
comme ceux de la barre de raccourcis.

**Le compteur d'occupation du GPU ne se relit pas.** « Device Utilization % »
a donné 0 % à la carte Médias et 92 % à la carte Processeur sur le même rendu
(11/10), lus à quelques millisecondes d'écart dans le même relevé. Deux
cartes qui montrent le même chiffre le prennent à UNE lecture : la carte
Médias reçoit celle du socle (`MediaTracker.tick(gpu:)`).

**Premiere traîne soixante processus qui n'exportent rien.** Les moteurs web
de ses panneaux d'extension (`CEPHtmlEngine`, relevé le 11/10 : 60 processus,
427 fichiers ouverts en écriture — journaux et caches). Lister les fichiers
de chacun à chaque relevé coûtait 5,9 ms ; ils sont écartés, et la liste des
processus d'une app se garde 30 s : 0,6 ms par relevé, 6,6 ms toutes les 30 s.

**Un panneau plus haut que l'écran est rogné par macOS.** Relevé le 11/10 sur
le relevé figé du banc : sept cartes avec le forfait iPhone réglé, 1 296 pt ;
avec la carte Médias, 1 487 pt — pour 1 290 pt visibles sous la barre de
menus, moins la flèche du popover (13 pt) et 3 pt de marge, soit 1 274. Le bas
du panneau, et la barre de raccourcis avec Quitter, disparaissaient. Le
panneau prend désormais une colonne de plus quand il ne tient pas : les
dernières cartes des colonnes trop hautes passent à droite, dans leur ordre,
autant de colonnes que la largeur de l'écran le permet (six sur ce Mac) —
932 × 1 238 pt dans les deux cas. Une colonne de plus plutôt que des cartes
compactes : elle ne retire rien à lire, alors qu'une carte compacte cache
ses listes sans le dire ; et l'écran d'Isma a de la place en largeur, pas en
hauteur. Quand tout tient, rien ne bouge, au pixel près (rendus figés de
`./verifie.sh`). Les réglages ne sont jamais réécrits : c'est l'affichage qui
s'adapte, à chaque mise en page (`PanelLayout`, `PanelFit`). La règle vaut
aussi pour le panneau détaché : sa fenêtre entière, barre de titre comprise,
tient dans l'écran (1 268 pt dans les deux cas ; `--snapshot x.png --fenetre
--ecran 2056x1000` le montre sur un écran plus bas).
**Une échéance à trente jours est du bruit.** La règle 9 (« plein dans moins
de N jours », avertissement) était posée à 30 jours et tenait 38 % du journal
des verdicts, le premier de tous. Méthode (`outils/rejoue-seuils.py`, le
11/10) : la prévision de l'app, copiée à l'identique, recalculée à chaque
point des 30 jours de disques de history.json, puis deux questions par
tranche d'échéance — 24 h plus tard, l'échéance existe-t-elle encore ? 3 jours
plus tard, le disque est-il plus plein ? Disque interne, 13 jours observés :

| échéance annoncée | disparue 24 h après | plus plein 3 jours après |
|---|---|---|
| 0 à 7 jours | 28 sur 87 | 1 sur 88 (Isma a fait de la place) |
| 7 à 14 jours | 97 sur 294 (33 %) | 81 sur 226 (36 %) |
| 14 à 30 jours | 145 sur 201 (72 %) | 58 sur 200 (29 %) |

Au-delà de 14 jours, trois échéances sur quatre s'évanouissaient dans la
journée. Seuil 14 jours : la règle est vraie 27 % du temps au lieu de 43 %, et
garde une semaine d'avertissement avant l'alerte des 7 jours. Les règles 7
(swap) et 10 (processeur) restent provisoires : le 11/10, l'historique ne
couvrait que 2 h de leurs séries, un matin de compilations — à rejouer avec le
même outil quand il couvrira une semaine de montage. La charge par
application n'y était pas : la moitié « 200 % d'un cœur » de la règle 10 ne
se rejouait pas. Depuis le 11/10, la série `processeur.hors-montage` relève
la charge de l'app hors montage la plus occupée (`CalibrationSeries`, un
maximum sur le balayage que le relevé fait déjà), et l'outil croise les deux.

**Une relance de Pulse n'est pas un changement de verdict.** Chaque
lancement réécrit la règle du moment dans le journal, et le bilan de
`--probe` les comptait : « 38,8 changements par jour » le 11/10, quand depuis
le délai de tenue (09/10, 21 h 58 UTC) 42 lignes de règle ne faisaient que 13
changements — les fusions des chantiers relançaient Pulse toutes les quelques
minutes. Le bilan compte désormais les vrais changements et nomme les
relances à part (`VerdictJournal.changes`). Depuis le délai de tenue : 9,9
changements par jour, dont 8 sur 13 par la règle 7, qui va et vient autour de
son seuil.

**Un banc lancé d'un terminal ne tourne pas sur les mêmes cœurs que l'app.**
Relevé le 11/10 par `ri_user_ptime` et `ri_cycles` : panneau fermé, le Pulse
installé passe 97 % de son temps CPU sur les cœurs d'efficacité (2,4 GHz,
une instruction par cycle) ; `--banc`, lancé depuis le shell d'un chantier,
84 à 99 % sur les cœurs de performance (3,2 GHz, 1,4), parce qu'il partage
le groupe de fils de son parent, occupé. Pour le même travail — 6,9
milliards d'instructions par banc, au même compte près —, 1,1 s de CPU contre
2,2 s. Le banc donnait 0,35 % quand l'app en dépensait 0,8, et l'écart avait
été mis sur le compte de l'icône (0,45 point) ; elle n'en pèse que 0,13 au
profileur. `taskpolicy -a` ou `-c utility` n'y changent rien : seul
l'arrière-plan Darwin (`PRIO_DARWIN_BG`) l'envoie sur les cœurs E, à 2,4 GHz
comme l'app. Les phases fermées du banc s'y mesurent désormais.

**Un balayage des processus coûte dix fois plus que mesuré sur un cœur P.**
Le commentaire disait 1,3 ms ; au profileur du Pulse installé, 16 ms par
relevé, le tiers de son budget panneau fermé, presque tout dans le noyau
(`__proc_info`). Deux appels par processus pour ~650 processus lisibles :
`PROC_PIDTASKINFO` pour le seul temps CPU, puis `proc_pid_rusage` V6 pour le
reste. Le temps CPU est aussi dans `rusage` (écart maximal 0,07 % sur 670
processus, le temps entre les deux lectures) et la V2 suffit — la V6
additionne instructions et énergie fil par fil. Un seul appel V2 : 2,7 ms
→ 1,1 ms par balayage hors de l'app, −0,16 point sur les cœurs E au banc.
De même, `IORegistryEntryCreateCFProperties` copiait toutes les propriétés
du GPU pour en lire une : 2,35 ms contre 0,034 ms pour la seule clé.

**Sur macOS 26, les icônes de la barre de menus sont des fenêtres de Control
Center.** Relevé le 11/10 par `CGWindowListCopyWindowInfo` : les treize
fenêtres de niveau 25 (`kCGStatusWindowLevel`) appartiennent toutes à Control
Center, celle de Pulse comprise — aucune ne porte le pid de son app. Le cadre
qu'annoncent l'app et l'API d'accessibilité ne prouve donc rien (voir « La
position d'une icône ne prouve pas qu'elle se voit ») ; ce qui tranche, c'est
une fenêtre de Control Center À L'ÉCRAN qui contient ce cadre : Pulse à
x = 1347 sur 125 pt, dans la fenêtre x = 1340 sur 139 pt, 7 pt de marge de
chaque côté. `MenuBarRoom` fait ce rapprochement, sans autorisation (bornes
seulement, aucun nom de fenêtre lu) : le panneau dit qu'une icône de Pulse
est cachée, `--probe` dit où elle est. Ce jour-là : 918 pt à droite de
l'encoche, 828 pris par 13 icônes, 92 libres.

**L'icône est le premier poste du budget, et le débit la redessinait sans
cesse.** Chantier 03, 11/10, aux mêmes secondes : 0,75 % d'un cœur pour le
Pulse installé, 0,30 % au banc sans icône — environ 0,45 point pour une
trentaine d'affichages par minute, presque tous dus au débit, qui changeait
à chaque relevé de 2 s (« 6,0k », « 7,5k », « 6,8k »). Le débit affiché ne
bouge plus que d'au moins 30 % (et 3 ko/s sous 10 ko/s) ou d'une unité (`MenuBarRateFilter`), la barre
se refait au plus toutes les 5 s, et rien n'est redessiné tant que l'image
ne change pas — la part d'une jauge compte au pour cent près, celle d'un
texte pas du tout. Les deux binaires au banc, aux mêmes secondes : 33
affichages du libellé avant, 17 après ; 0,32 % puis 0,25 % d'un cœur
panneau fermé au banc, réveils de 1,9 à 0,8 par seconde. L'image est
dessinée en AppKit, sans `ImageRenderer`.
**Une fenêtre qui épouse son contenu par contraintes refait sa mise en page à
chaque relevé.** Mesuré le 11/10 sur le panneau détaché (chantier 13), au banc :
en `sizingOptions = [.minSize, .maxSize]`, 11,3 % d'un cœur fenêtre ouverte,
contre 8,0 % pour le popover au même moment. En suivant plutôt la taille
préférée (`preferredContentSize`) sous une barre de titre transparente, AppKit
lève une exception — « more Update Constraints in Window passes than there are
views in the window » — : la marge de la barre de titre change la taille, qui
change la marge. Le contenu mesure sa taille idéale (préférence SwiftUI) et la
fenêtre ne la suit que quand elle change : 7,7 %, et rien fermée.

**`linkd` refuse les actions Raccourcis d'une app signée ad hoc.** Relevé le
11/10 dans son journal, sur le Pulse installé : « Unable to get teamId from
com.isma.pulse … Rejecting invalid client due to requiresValidatedBundle ».
Les métadonnées App Intents se produisent bien sans Xcode
(`outils/appintents-metadata.sh`, identiques à celles d'Xcode), mais une app
sans Team ID ne peut pas recevoir l'appel : les actions apparaîtraient, puis
échoueraient. `build.sh` ne les embarque donc que si Pulse est signé avec un
certificat de développeur (`PULSE_IDENTITE`).

**Une animation SwiftUI dans une fenêtre jamais affichée tourne sans
frein.** Fenêtre hors écran (celle de `--banc`), une animation linéaire de
4 s : 77 840 images évaluées en 5 s et 2,68 s de processeur (11/10). À
l'écran, la synchronisation verticale la borne à 120 images par seconde.
Un banc qui laisserait jouer une animation mesurerait donc n'importe quoi :
le coût d'une animation se mesure image par image (`--snapshot
--ouverture`), et la cascade d'ouverture a sa propre horloge, plafonnée à
60 images par seconde puis mise en pause (`UI/Motion/Opening.swift`).

**Le cadre de NSPopover est déjà du verre sous macOS 26.** Relevé par
introspection du runtime, sans rien afficher : `NSPopoverFrame` (un
`NSVisualEffectView`) porte `_glassVariant` et `_updateGlassVariant`. Le
panneau n'a qu'à laisser voir ce verre hors de ses cartes ; en poser un
second en SwiftUI ferait du verre sur du verre. Les cartes deviennent
opaques, aux valeurs que rendait leur ancien voile translucide : les ratios
mesurés ne bougent pas (`UI/Themes/Glass.swift`).

**Un dépliant ouvert faisait sortir le panneau de l'écran.** Mesuré le
11/10 avec `--snapshot x.png --ouvert <clé>` : 1 344 à 1 445 pt pour les
historiques des disques, des capteurs, de l'énergie, des 7 derniers jours,
de la connexion et de la session, pour 1 290 utiles — macOS rognait le bas.
Pendant qu'un dépliant est ouvert, les autres cartes de sa colonne passent
en compactes (`PopoverView.historyOwners`) : 1 214 à 1 220 pt.

**Le ratio de contraste ne dépend que de la luminance.** Une carte violette
de même luminance qu'une carte grise donne les mêmes ratios, au centième.
Les thèmes changent donc la teinte des fonds, jamais leur luminance au-delà
de la carte grise mesurée (sombre) ou de #FAFAFA (clair) : toute teinte
acceptée sur le thème Système l'est sur tous (`ThemeTests`, huit accents
compris).

**Un widget signé ad hoc n'atteint pas la galerie, et changerait d'empreinte
à chaque compilation.** Relevé le 11/10 sur une extension d'essai : le bac à
sable et l'exception temporaire de lecture marchent sans compte (une sonde
lit le fichier permis, EPERM ailleurs), mais `pluginkit -a` est refusé hors
d'une app, `lsregister -f -R -trusted` l'enregistre, et chronod la purge
aussitôt (« we shouldn't cache it »). Et le conteneur d'une extension
sandboxée est lié à son empreinte : en ad hoc, chaque reconstruction pourrait
faire demander à Isma de confirmer. L'extension (`Widgets/`) n'est donc
embarquée qu'avec `PULSE_IDENTITE`.

**`SMAppService.daemon` ne survit pas à une signature ad hoc.** Au premier
enregistrement, launchd fige une contrainte de lancement sur l'empreinte
(`cdhash`) du helper ; Pulse.app est recompilé à chaque fusion, et chaque
nouvelle empreinte donnerait « Launch Constraint Violation » (Quinn, Apple
DTS, forums 799910 et 795022). Le helper des ventilateurs est donc un démon
classique, copié une fois, sur accord, dans `/Library/PrivilegedHelperTools`
(chantier 14) : les recompilations ne le touchent pas.

**Un serveur XPC qu'on ne retient pas répond nil, sans erreur.** Le
gestionnaire de l'écouteur tient son serveur en `weak` : rendu au tuple
`(_ , …)` d'un test, le serveur disparaissait, et le client recevait des
réponses vides — deux tests rouges sur quatre, sans un message. Le démon le
garde en variable globale ; un test le garde avec `withExtendedLifetime`.

**Le mode Swift 6 arrête le processus là où le mode 5 laissait courir.**
Relevé le 11/10 (17-audit-code) : passé en mode de langage 6, Pulse
compilait, ses 355 tests, ses rendus et son banc passaient — mais 784 de
ses fonctions et 5 du helper portaient une vérification d'isolation à
l'exécution (`swift_task_reportUnexpectedExecutor`, lue au désassemblage).
Une fermeture formée sur le fil principal et rappelée ailleurs par une API
C — un gestionnaire `notify_register_dispatch` de premier niveau, comme
celui de la pression thermique du helper, ou ses gestionnaires de SIGTERM —
finit en SIGTRAP (code 133), quand le mode 5 l'exécute (code 0). Le helper,
root, se serait arrêté net au lieu de rendre la main à macOS. La
concurrence est donc vérifiée en entier À LA COMPILATION
(`StrictConcurrency`, zéro avertissement), le mode reste 5
(`Package.swift`) ; aucun binaire n'importe le symbole, ce qui se vérifie
par `nm -u .build/release/Pulse | grep reportUnexpectedExecutor`.

**Sur batterie presque vide, le même travail coûte trois fois plus de
temps processeur.** Relevé le 11/10 (19-suivis), Pulse installé suivi minute
par minute : jusqu'à 9 h 50, 3,1 à 3,9 ms de CPU par seconde pour 9,5 à 15
millions d'instructions par seconde et 1 à 1,6 mW ; à partir de 9 h 51, Mac
sur batterie à 3 %, 8,4 à 10,6 ms pour les MÊMES 10 à 13,6 millions
d'instructions, et 0,44 à 0,58 mW — macOS bride les cœurs. La fenêtre de
10 min passait de 0,34 à 0,89 % d'un cœur sans que Pulse ait changé, et un
banc de la même heure donnait 0,59 % panneau fermé contre 0,24 %. Un budget
se mesure sur secteur, ou se lit en instructions (`ri_instructions`), qui
ne bougent pas.

**Une clé SMC ne dit pas ce qu'elle mesure d'une puce à l'autre.** Le
catalogue des températures ne connaissait que les clés du M2. Sur le M1 Pro
d'un ami (26/10), `Tp09` est un cœur EFFICACITÉ, pas performance, et la carte
graphique est en `Tg05`, `Tg0D`, `Tg0L`, `Tg0T`, où le M2 n'a rien : la carte
aurait rangé un cœur efficacité parmi les cœurs performance et montré une
carte graphique sans température. Le catalogue se choisit au nom de la puce
(`machdep.cpu.brand_string`) : M1 à M4, d'après Stats ; une puce non
répertoriée n'affiche pas de cœurs plutôt que des cœurs devinés
(`SensorCatalog.entries(for:)`). Jamais vérifié sur un vrai M1.

**Une grappe éteinte rend 5 °C.** Relevé le 26/10 : sur 841 lectures à
10 Hz, les huit clés des cœurs performance tombaient ENSEMBLE à 4,6–6,7 °C
dans 267 lectures — valeurs de repos d'une grappe éteinte, pas des
températures. Moyennées, « Processeur » tombait à 24 °C dans la carte, la
barre et l'historique. Une puce allumée n'est jamais plus froide que la
pièce : sous 15 °C, la lecture est écartée et la dernière bonne valeur de la
sonde tient 30 s (`DieTemperatureFilter`).

**Regarder dans un dossier protégé, c'est demander à l'écran.** Documents,
Téléchargements, le Bureau, iCloud Drive, un disque externe : y lire un
fichier — même pour savoir s'il existe — fait afficher « Pulse souhaite
accéder aux fichiers de votre dossier… ». Deux voies l'auraient fait sur le
Mac d'un ami (26/10) : le journal d'AME, cherché dans `~/Documents` à la
première ouverture du panneau, carte Médias masquée ; l'Info.plist de chaque
app ouverte, lu pour la nommer, dès qu'une app tourne depuis Téléchargements.
Le journal n'est cherché que carte Médias affichée, règle « Export terminé »
allumée, ou historique déjà nourri par lui (`ExportHistory.Journal`) ; sous
ces dossiers, aucune Info.plist ni icône n'est lue (`ProtectedFolders`). Un
`--probe` lancé du Terminal ne le révèle jamais : c'est le Terminal qui a
l'accès.

**Une connexion directe au réseau local se fait autoriser.** macOS 15 compte
comme accès au « réseau local » toute connexion à une adresse jointe SANS
routeur (TN3179 d'Apple), et le fait autoriser à l'écran. La sonde Starlink
(192.168.100.1:9200) passe par le routeur : elle ne demandait rien chez
Isma. Sur une box qui sert 192.168.100.0/24, elle serait directe : elle se
tait alors (`NetworkMonitor.onLink`).

**Un partage réseau n'est pas un disque.** `mountedVolumeURLs` liste aussi
les partages : plein, un NAS faisait dire « plein à 96 % » au verdict et
devenait le disque le plus plein de la barre ; muet, son `statfs` bloquait
toute la file du relevé. Les volumes viennent désormais de la table du noyau,
locaux seulement (`getmntinfo`, `MNT_NOWAIT`, `MNT_LOCAL`), et le disque
Time Machine (rôle APFS « Backup »), que macOS garde plein exprès, est écarté
(`DiskMonitor.localVolumes`, `isTimeMachine`).

**Un second écran a sa propre barre de menus.** Au-dessus du Mac, ses
fenêtres ont des Y négatifs ; à gauche, des X négatifs. `MenuBarRoom`
comptait leurs icônes dans la place à droite de l'encoche (« 918 points,
dont 1 715 pris ») et disait cachée une icône de l'écran de gauche : la
rangée (`sameRow`) et l'écran de l'encoche (`notchScreen`) tranchent
désormais.

**Sur un petit écran, le débordement s'empilait.** Plus de colonnes que la
largeur n'en permet : `arrange` versait tout le trop-plein dans la
dernière, 859 pt pour 655 sur un 14 pouces en « texte plus grand ». Les
cartes se rangent alors dans l'ordre de lecture en colonnes équilibrées, ou
à défaut au plus serré (`PanelFit.arrangeToFit`) ; quand `arrange` tient,
rien ne change.

## Stockage

`~/Library/Application Support/Pulse/history.json`

- 60 minutes de séries pour le graphe
- 30 jours de mesures de disque pour la tendance
- 90 jours de temps par application et de sessions

La tendance de remplissage s'estime sur les **72 dernières heures**, intervalle
par intervalle. Ceux qui portent une copie ou une suppression en masse — plus de
5 % du volume d'un coup, ou plus de 5 To par jour — sont écartés ; la pente est
la moyenne des autres, pondérée par leur durée. En dessous de 6 h d'observation calme, rien n'est publié. Voir le
piège correspondant plus haut : une régression sur tous les points inversait le
signe sur un volume qu'on venait de vider.

La pente se mesure sur l'espace libre **strict**, purgeable exclu : macOS reprend
ses instantanés sans que l'utilisateur ait rien écrit, ce qui simulait un volume
se vidant de 12 Go d'un coup. Le reste à courir se compte en revanche sur
l'espace disponible purgeable **compris**, puisque macOS le récupère avant de
saturer.

Un fichier illisible est déplacé en `history.illisible.json` plutôt qu'écrasé.

`~/Library/Application Support/Pulse/reseau.json` : la consommation internet de
ce Mac, par jour et par réseau (partage iPhone, Starlink, autres), 90 jours.
Fichier à part, relu de façon tolérante.

`~/Library/Application Support/Pulse/verdicts.jsonl` : une ligne à chaque
changement de verdict, 30 jours. Fichier à part, relu de façon tolérante — un
journal abîmé ne doit jamais pouvoir coûter l'historique. Il sert à calibrer les
seuils des règles 7, 9 et 10, posés et non mesurés.

`~/Library/Application Support/Pulse/reglages.json` : les réglages (cartes,
ordre, colonnes, teintes, cadence, unités). Fichier à part, lu en
`decodeIfPresent` champ par champ : un réglage illisible retombe seul sur sa
valeur par défaut, un fichier qui n'est pas du JSON est mis de côté en
`reglages.illisible.json`. Jamais écrit par `--snapshot`.

`~/Library/Application Support/Pulse/historique.sqlite` : l'historique
longue durée (`Sources/Pulse/History/`), SQLite du système, clé (temps,
série), journal de retour arrière (schéma 2).

| étage | pas | gardé | plages servies |
|---|---|---|---|
| `raw` | 10 s (moyenne de la fenêtre) | 24 h | 1 h, 24 h |
| `minute` | 1 min : moyenne, min, max, nombre | 7 j | 7 j |
| `tenmin` | 10 min : moyenne, min, max, nombre | 90 j | 30 j, 90 j |

Écrit par lots toutes les 5 min sur sa propre file, purgé une fois par heure ;
chaque lot recalcule les tranches qu'il touche (agrégation sans état). Écrit
sur le SSD, mesuré sur une heure (`ri_diskio_byteswritten`, `HistoryTests`) :
**2,9 Mo par heure**, contre 19,3 Mo pour la première version du 11/10 (lot
chaque minute, clé (série, temps), WAL) — et 18 Mo pour la réécriture de
history.json, 300 ko chaque minute. Les graphiques lisent aussi les points
pas encore écrits. Jamais écrit par `--snapshot`, `--probe` ni `--banc`, qui
l'ouvrent en lecture seule, ne la créent pas et n'y écrivent pas un octet.
21,9 Mo à 90 jours pour les séries de base et trois volumes ; une série de
module relevée toutes les 10 s coûte ~1,5 Mo de plus. Au premier lancement, la série
d'une heure et les 30 jours de disques de history.json y sont repris une fois
(bilan dans `--probe`) ; history.json n'est ni réécrit ni déplacé. Une base
qui échoue à `quick_check` est renommée `historique.illisible-<date>.sqlite`,
journal compris, jamais effacée ; celle d'un Pulse plus récent est lue, jamais
écrite. Une série déclarée par un module (`History.declare`) garde dans la
base son libellé, son unité et son dénominateur : `--probe`, qui ne charge
pas les modules, écrit « 74 % » et « 79 °C » comme la carte, pas « 1 » et
« 79 ».

Le forfait iPhone (quota en Go, jour de renouvellement) et les deux mesures
qui sortiraient sur Internet (IP publique, ping Internet) sont des options du
module réseau, dans `reglages.json` sous `modules.reseau.options` : la
fenêtre Réglages les dessine, la carte les modifie au même endroit. Un forfait
à 0, ou absent, veut dire « pas de jauge ».

`~/Library/Application Support/Pulse/disques.json` : les écritures massives
nommées (copie de carte, téléchargement…) des 30 derniers jours, et le dernier
bilan « ce qui remplit » de chaque volume externe. Écrit à la clôture d'un
épisode, chaque minute pendant qu'il dure pour que `--probe` le voie, et à
chaque bilan (30 min). Fichier à part, relu de façon tolérante, mis de côté
s'il est illisible.

`~/Library/Application Support/Pulse/exports.json` : les exports terminés,
90 jours — ceux du journal d'AME (recopiés, avec la taille du fichier produit
lue à l'ingestion tant que le disque est branché) et ceux que Pulse a vus
lui-même. Fichier à part, relu élément par élément : un enregistrement
illisible est sauté sans emporter les autres (règle dure n°2).

Depuis le 11/10, chaque ligne de `verdicts.jsonl` porte aussi la preuve du
verdict (`evidence` : « +1,1 Go en une heure », « plein dans ~13 jours ») :
le chiffre qui a fait basculer une règle, sans lequel un seuil ne se calibre
pas. Champ ajouté, relu de façon tolérante comme le reste.

`reglages.json`, clé `menuBar` (chantier 09) : la barre de menus — un élément
ou un par segment (`mode`), les segments dans l'ordre de la barre avec leur
style (`items`), le symbole d'alerte (`alert`). Lue champ par champ ; absente,
la barre garde son allure d'avant (mémoire, disque, débit). L'interrupteur de
la température du processeur reste celui du module Capteurs
(`modules.capteurs.options.barre`), dont dépend sa cadence de lecture.
`~/Library/Application Support/Pulse/etat-partage.json` : ce que les widgets
affichent (verdict, mémoire, disques, partage iPhone), déjà mis en mots par
l'app. Écrit au plus une fois par minute, seulement si une valeur a changé
(ou toutes les 10 min, pour dater les chiffres) ; relu en `decodeIfPresent`
champ par champ, un disque illisible n'emporte pas les autres. Jamais écrit
par `--snapshot`, `--probe` ni `--banc`.

`~/Library/Application Support/Pulse/regles.json` : les règles (chantier 11),
préréglages compris, et comment Pulse se tait (intervalle, retenue en
montage). Fichier à part, lu champ par champ : une règle illisible est
écartée seule, un préréglage manquant revient éteint, un fichier qui n'est
pas du JSON est mis de côté en `regles.illisible.json`. Absent : les
préréglages, tous éteints. Jamais écrit par `--snapshot`, `--probe` ni
`--banc`.

`~/Library/Application Support/Pulse/regles.jsonl` : le journal des règles,
une ligne par début, fin, notification, retenue, alerte hors plage ou
retombée, autorisation — de quoi dire pourquoi une notification est partie,
ou pas. 30 jours. Les épisodes qu'il laisse ouverts sont repris au
lancement, déjà dits : une relance de Pulse ne redit pas « disque presque
plein ».

`~/Library/Application Support/Pulse/meteo.json` : la dernière réponse
d'Open-Meteo, brute, avec la ville et l'heure de réception — écrite par
l'app installée seulement, carte Météo activée ; relue de façon tolérante
(illisible : ignorée, remplacée à la réponse suivante). Les personnes des
horloges vivent dans `reglages.json`, sous
`modules.horloges.options.personnes` : une ligne « Nom = ville » par
personne, réparable à la main ; une ville inconnue saute seule.

`~/Library/Application Support/Pulse/ventilateurs.json` (chantier 14) : le
mode des ventilateurs (automatique, vitesse fixe, courbe), le niveau fixe,
la courbe et la température suivie. Lu champ par champ ; absent ou abîmé,
le mode retombe sur AUTOMATIQUE. Jamais écrit par `--snapshot`, `--probe` ni
`--banc`. Le helper, s'il est installé, écrit en root son journal
(`/Library/Logs/PulseHelper.log`, une ligne par consigne nouvelle, retour en
automatique ou refus) et son compte d'écritures du démarrage
(`/private/var/db/com.isma.pulse.helper.ecritures`) ; sa désinstallation les
efface avec lui, journal excepté.

Débits disque (19-suivis) : `disques.lecture` et `disques.ecriture` dans
`historique.sqlite`, le débit total des disques physiques — celui du miroir
des 3 min de la carte Disques —, à chaque relevé, panneau fermé compris,
moyenné par 10 s comme les autres séries ; graphique « Débit des disques »
du tableau de bord. Deux séries pour tous les disques, pas deux par
disque : un disque branché une fois n'en ouvre pas deux de plus pour 90
jours. Mesuré (`HistoryTests.toutesLesSeriesTiennentSousCinquanteMo`) :
toutes les séries déclarées au pire — les neuf de modules relevées toutes
les 10 s, débits disque compris — et trois volumes, sous 50 Mo à 90 jours :
la taille exacte est imprimée par le test.

## Limites connues

**L'export lancé sans Media Encoder n'est pas vu.** La détection s'appuie sur
la charge de Media Encoder, ce qui règle l'attribution sans effort : c'est une
application Adobe, identifiée par son identifiant de bundle. Un export lancé
directement depuis Premiere, sans passer par la file d'attente, ne le démarre
pas et passe donc inaperçu.

Le seul signal qui resterait dans ce cas est le plancher nul des
`VTEncoderXPCService` — réel, mais large de quelques pour cent d'un cœur, et
surtout impossible à rattacher à Adobe : ces services sont partagés par toute la
machine et n'ont que `ppid 1` (launchd) pour parent, `launchctl procinfo` exigeant
root. Un appel visio dans Vivaldi ou WhatsApp ferait monter le même compteur. À
ne pas ajouter sans résoudre l'attribution d'abord.

**Piste en cours** : un fichier ouvert en écriture, lui, appartient à un processus
précis, lisible sans root pour les processus de l'utilisateur. Au repos, Premiere
ne tient aucun fichier média ouvert en écriture ; pendant un export, il devrait
tenir le fichier de sortie. `OpenFiles.swift` les liste, prévisualisations et
caches écartés, et `--probe` les affiche. À valider sur un export réel lancé
depuis Premiere avant d'en faire une détection.

Deux réserves sur le seuil actuel : il repose sur un seul export de 30 s dans un
seul format, et le plancher au repos n'a été observé qu'en l'absence d'appel
vidéo. `outils/mesure-export.py` produit un relevé supplémentaire à chaque
exécution — un CSV par lancement, toutes les 3 s. Il dérive le temps CPU cumulé
au lieu de lire la colonne `%CPU` de `ps`, qui est une moyenne sur toute la vie
du processus : sur un encodeur vivant depuis 40 minutes, un export de 3 minutes
y serait invisible.

**Environ un tiers du CPU machine est invisible.** `proc_pidinfo` et
`proc_pid_rusage` échouent en `EPERM` sur les processus d'un autre uid —
`WindowServer`, `kernel_task`, `mediaanalysisd`. C'est un contrôle du noyau,
aucune autorisation ne peut le lever. Le classement par application est donc
structurellement incomplet.

**La section Incidents exige un compte administrateur.** L'accès à
`/Library/Logs/DiagnosticReports` vient de l'appartenance au groupe
`_analyticsusers`, obtenue par imbrication du groupe `admin`. Sur un compte
standard, la lecture échoue et la section se masque.

**L'item peut se cacher derrière l'encoche.** Quand la barre de menus est
pleine, macOS place les nouveaux items au centre de l'écran intégré, c'est-à-dire
derrière l'encoche. Il reste visible sur un écran externe. Réordonner en
⌘-glissant, ou retirer un item, résout le problème.

**Le forfait ne compte que ce Mac.** L'iPhone lui-même et les autres appareils
branchés sur son partage n'y sont pas, ni le trafic passé pendant que Pulse
était fermé : le chiffre est un plancher de ce que l'opérateur décomptera. Seul
l'iPhone (Réglages › Données cellulaires) ou l'espace client connaît le total.

**Le débit par application passe par une API privée.** `NetworkStatistics` est
résolue symbole par symbole (`dlsym`) : si un macOS la retire ou la change, la
carte dit « débit par app indisponible » au lieu de planter. `nettop`, qui
lit la même source dans le noyau, n'est PAS un repli : un relevé d'une
seconde (`nettop -P -L 2 -d -s 1`) coûte 0,65 s de processeur (mesuré le
11/10), quand l'appel direct en coûte ~5 ms — à la cadence de la carte, il
mangerait un tiers de cœur.

**Le nom du Wi-Fi n'est pas lu.** macOS le réserve aux apps autorisées à
localiser l'utilisateur ; Pulse ne demande pas cette autorisation. Le signal,
le bruit, le débit de liaison, le canal et la norme, eux, se lisent sans.

**Les règles ne voient que ce que Pulse mesure déjà.** « Connexion perdue »
porte sur l'absence de réseau (Wi-Fi coupé, partage iPhone perdu) : une box
ou un Starlink connectés mais privés d'Internet ne se voient pas panneau
fermé, faute d'une mesure qui sortirait sur Internet. « Export terminé »
porte sur Media Encoder, comme la détection d'export. Un plantage se
constate jusqu'à 2 min après (relecture de la base Crashpad), un disque
jusqu'à 2 min après (relecture des volumes panneau fermé), un export 30 s
après sa fin (`ExportDetector`).

**Le pilotage des ventilateurs n'a jamais été essayé sur ce Mac.** Tout est
prêt et testé contre un SMC simulé, mais personne n'a encore écrit `F0Md` sur
ce M2 Max : `Ftst`, la clé qui déverrouille les M3 et M4, n'y existe pas
(lue par son nom), et l'écriture directe, qui suffit sur M1, n'est
qu'annoncée pour M2. Premier geste de l'essai réel, avec Isma. Et le helper
ne sait pas qui lui parle au-delà de l'identifiant de signature, qu'un
processus de la même session peut copier : il ne permet donc rien qui sorte
des bornes d'Apple (revue de sécurité du chantier 14).
