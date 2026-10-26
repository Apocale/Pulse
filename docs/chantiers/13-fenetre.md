# 13-fenetre — fenêtre détachable, tableau de bord, widgets, Raccourcis

Départ : dimanche 11/10/2026, 07 h 38 (heure de Paris), 05:38 UTC.
Branche `chantier/13-fenetre`, worktree `.claude/worktrees/agent-a27922c80828ce0dc`.
Fin au plus tard : 09 h 38 (07:38 UTC).

Fichiers possédés : `Sources/Pulse/Window/` (fenêtres, état partagé, actions
Raccourcis), `Widgets/` (extension WidgetKit). Fichiers partagés touchés en
une ou deux lignes : `PulseApp.swift` (menu de l'icône, cadence quand une
fenêtre est visible), `PopoverView.swift` (deux boutons du pied),
`Snapshot.swift` (rendus `--fenetre`, `--tableau`, `--widget`), `Probe.swift`
(section WIDGETS ET RACCOURCIS), `Package.swift` et `build.sh` (extension).

## Règle commune aux quatre surfaces

Aucune ne coûte rien fermée : contenu créé à l'ouverture, vidé à la
fermeture, comme le panneau (README, « Un popover refermé continue de se
dessiner »). Une fenêtre cachée (autre espace, réduite, recouverte) vide
aussi son contenu et rend la cadence fermée. Les widgets et les Raccourcis
ne mesurent rien : ils lisent ce que Pulse relève déjà, par un petit fichier
d'état écrit au plus une fois par minute.

## Plan en jalons

**J1 — Panneau détachable en fenêtre flottante**
- Bouton « Détacher » au pied du panneau, entrée dans le menu de l'icône.
- `NSPanel` non activant : un clic dedans ne vole pas le clavier à Premiere.
- « Au-dessus de tout » (épingle) : niveau flottant, tous les espaces,
  plein écran compris ; décochée, fenêtre ordinaire. Mémorisé.
- Rendu hors écran `--snapshot x.png --fenetre`, coût mesuré fenêtre
  ouverte (hors écran) et fermée.

**J2 — Tableau de bord pour un second écran**
- Fenêtre redimensionnable, plein écran possible : verdict, grands graphes
  d'historique (processeur, mémoire, débit, disque de rushes, plages 1 h →
  90 j du chantier 02), puis toutes les cartes affichées, dans l'ordre des
  réglages, réparties en autant de colonnes que la largeur en loge.
- Rendu hors écran `--snapshot x.png --tableau [--largeur L --hauteur H]`.

**J3 — Actions Raccourcis (App Intents)**
- « Combien reste-t-il sur Ssd 2 ? » (disque choisi par UUID : le nom
  change), « Pulse est-il calme ? » (vrai/faux + la phrase du verdict),
  « Consommation iPhone du jour ».
- Métadonnées App Intents produites par `build.sh` sans projet Xcode.
- Logique testée par `swift test`, chiffres dans `--probe`.

**J4 — Widgets (WidgetKit)**
- Disque de rushes, mémoire, forfait iPhone : vues partagées avec l'app
  (rendues par `--snapshot x.png --widget <id>`).
- Extension sandboxée (obligatoire pour un widget), app principale SANS
  sandbox (règle dure n°1). Voie à établir en signature ad hoc : exception
  temporaire de lecture du dossier de Pulse, ou groupe d'apps (qui peut
  exiger un compte développeur ou déclencher une demande d'autorisation).
  Si aucune voie ne tient sans compromis : documenté, décision à Isma.

**J5 — Tests et rendus de chaque surface, bilan.**

## Journal

### J1 et J2 — panneau détaché, tableau de bord (05:38 → 06:20 UTC)

Fait :
- `Window/FloatingWindow.swift` : `NSPanel` non activant (un clic dedans ne
  prend pas le clavier à Premiere), `hidesOnDeactivate` faux, épingle « au-
  dessus de tout » (niveau flottant, tous les espaces, plein écran compris ;
  décochée, fenêtre ordinaire), position mémorisée, seul le bouton de
  fermeture. Ouverte par le bouton « Détacher » du pied du panneau (masqué
  dans la fenêtre elle-même), ou « Détacher le panneau » au menu de l'icône.
- `Window/DashboardWindow.swift` : fenêtre redimensionnable, plein écran
  possible, ouverte la première fois sur le second écran s'il y en a un.
  Verdict, six grands graphes `HistoryChart` du chantier 02 (processeur 1 h,
  mémoire 24 h, swap 24 h, carte graphique 1 h, débit 1 h, libre du disque de
  rushes 30 j, chacun avec son sélecteur 1 h → 90 j), puis toutes les cartes
  affichées dans l'ordre des réglages, en colonnes « maçonnerie » de 296 pt
  (autant que la largeur en loge, chaque carte dans la colonne la moins haute).
- `Window/Surfaces.swift` : une surface visible compte comme le panneau
  ouvert pour la cadence (`AppDelegate.measuringOpen`) ; cachée (réduite,
  recouverte, autre espace), son contenu est remplacé par un cadre vide de
  même taille et la cadence retombe ; fermée, tout est libéré.
- Rendus hors écran : `--snapshot x.png --fenetre`, `--tableau [--largeur
  --hauteur]` (cadre et barre de titre compris, `cacheDisplay`) ; bancs
  `--banc 60 --fenetre` et `--banc 60 --tableau`.

Mesures (banc de 65 s, machine occupée à 80-97 % par les chantiers) :

| Surface | fermée | ouverte, hors écran | refermée | à l'écran |
|---|---|---|---|---|
| panneau détaché | 0,26 % | 7,7 % | 0,26 % | 0 fenêtre |
| tableau de bord | 0,20 % | 6,2 % | 0,23 % | 0 fenêtre |
| popover, même heure (`--banc 60`) | 0,41 % | 8,0 % | 0,38 % | 0 fenêtre |

Refermée retombe au niveau de fermée : le contenu est bien libéré.
Défaut trouvé et corrigé en route : le panneau détaché en contraintes de
taille min/max coûtait 11,3 % ouvert (mise en page de la fenêtre à chaque
relevé) ; suivre la taille préférée à la volée bouclait avec la marge de la
barre de titre (exception AppKit, plantage au banc). Le contenu mesure
désormais sa taille idéale et la fenêtre ne la suit que si elle change.
Pièges ajoutés au README.

Invérifiable sans l'écran d'Isma (rien n'a été ouvert) : le clic dans un
panneau non activant, l'épingle au-dessus de Premiere en plein écran, le
tableau en plein écran sur le second écran.

### J3 — actions Raccourcis (06:00 → 06:25 UTC)

Fait :
- `Window/Raccourcis.swift` : « Pulse est-il calme ? » (vrai/faux + la phrase
  du verdict et sa preuve), « Espace libre sur un disque » (Go, base 1000 ;
  disque choisi par son nom, proposé dans une liste, sinon le disque de
  rushes — l'externe le plus rempli, repéré par UUID), « Consommation iPhone
  du jour » (Mo + cumul du cycle). Phrases App Shortcuts en français.
- Les réponses sont fabriquées par `Reponses`, pur et testé ; `--probe`
  (WIDGETS ET RACCOURCIS) imprime exactement ce qu'elles diraient.
- `outils/appintents-metadata.sh` : les métadonnées App Intents sans projet
  Xcode. SwiftPM 6.4 émet déjà les valeurs constantes ; le script lance
  `appintentsmetadataprocessor` dessus (0,6 s). Sur le vrai module : 3
  actions, 3 raccourcis, phrases comprises. Identique à Xcode sur une app
  d'essai.

Bloqué : `linkd` refuse une app signée ad hoc (« Unable to get teamId …
requiresValidatedBundle », relevé sur le Pulse installé). Les actions ne
peuvent s'exécuter qu'avec un Team ID, donc un certificat « Apple
Development » (gratuit : un Apple ID ajouté dans Xcode). `build.sh` accepte
`PULSE_IDENTITE` et n'embarque les métadonnées qu'alors : en ad hoc, aucune
action fantôme dans Raccourcis. Décision à Isma, voir le rapport.

Fusionné dans main à 06:50 UTC (ddfc044), après `./verifie.sh` complet
trois fois (budget panneau fermé 0,57 à 0,86 % estimés, plafond 1 %), puis
`--rapide` sur les dernières synchronisations : main avançait de plusieurs
fusions pendant chaque banc.

### J4 — widgets (06:00 → 07:00 UTC)

Fait :
- Vues partagées (`Window/WidgetViews.swift`) : disque de rushes (libre,
  occupation en barre, échéance), mémoire (utilisée sur installée, pression,
  swap), partage iPhone (aujourd'hui, cycle, jauge seulement si un forfait
  est réglé). Petit et moyen. Chaque widget dit l'âge de ses chiffres.
  Rendus : `--snapshot x.png --widget tous [--light]`.
- Fond posé par le widget (celui des cartes) : contraste mesuré sur les
  rendus (`outils/contraste-widgets.swift`) — au plus bas 3,40:1 (bleu,
  clair), 4,29:1 en sombre. Le fond système (#ECECEC) aurait mis le bleu
  sous 3:1.
- Extension (`Widgets/`, paquet SwiftPM à part : rien de plus à compiler
  pour les autres chantiers) : `WidgetBundle` de trois widgets, relecture de
  `etat-partage.json` toutes les 5 min, vues de l'app compilées une seconde
  fois par liens. Point d'entrée `_NSExtensionMain` et API d'extension,
  comme les widgets d'Apple. 12 s de compilation, appex de 392 Ko.
- Assemblée et signée dans une copie jetable de Pulse.app : extension AVEC
  bac à sable + lecture seule de `~/Library/Application Support/Pulse/`,
  app SANS entitlements ; `codesign --verify --strict --deep` valide.
  Jamais enregistrée auprès de LaunchServices, copie effacée.

Établi par un essai à part (app et extension d'essai, identifiants
`com.isma.essaiwidget.*`, désenregistrées ensuite) :
- Le bac à sable et l'exception temporaire de lecture marchent en
  signature ad hoc, sans compte : une sonde sandboxée lit le fichier permis
  et se voit refuser le reste (EPERM). Pas de groupe d'apps, pas de demande
  d'autorisation, Pulse hors sandbox.
- Enregistrement : `lsregister -f -R -trusted` (la commande d'Xcode) ;
  `pluginkit -a` seul est refusé (« plug-ins outside containing apps must
  be protected by SIP »).
- chronod reconnaît l'extension ad hoc, puis la purge (« we shouldn't cache
  it ») sans dire pourquoi : app hôte jamais lancée (piste principale), ou
  signature ad hoc. Non tranché sans ouvrir la galerie.
- Risque ad hoc documenté par Apple : le conteneur d'une extension
  sandboxée est lié à son empreinte ; chaque reconstruction (des dizaines
  par jour avec les chantiers) pourrait afficher chez Isma « … differs from
  previously opened versions ».

Décision prise : l'extension n'est embarquée qu'avec `PULSE_IDENTITE`,
comme les métadonnées des Raccourcis. En ad hoc, Pulse.app reste tel quel.
Décision à Isma (rapport) : un certificat « Apple Development » gratuit
débloque les deux d'un coup, sans sandbox pour l'app.

Fusionné dans main à 07:00 UTC (054bb83) : `./verifie.sh` complet sur la
branche synchronisée (240 tests, budget panneau fermé 0,60 % estimés), puis
`--rapide` après la dernière synchronisation, qui n'apportait que de la
documentation.

### Bilan à 07:05 UTC

Mesures :
- Budget panneau fermé, `./verifie.sh` avec ce chantier : 0,57 à 0,86 %
  d'un cœur estimés selon la charge de la machine (plafond 1 %).
- État des widgets : 0,25 ms de processeur et 2 Ko par écriture, une par
  minute au plus — 0,0004 % d'un cœur (`--banc 35 --fenetre`).
- Surfaces fermées : rien ne reste (refermée = fermée au banc, 0 fenêtre à
  l'écran pendant toutes les mesures et tous les rendus).
- 11 tests (`SurfacesTests`) : disque de rushes, chiffres identiques au
  panneau, « calme » jamais vrai avant le premier relevé, recherche d'un
  disque sans casse ni accents, fichier d'état tolérant (règle n°2),
  écriture coupée sous `--snapshot`, colonnes du tableau, âge du widget.

Ce qu'il faut d'Isma :
1. Un regard (2 min) : clic sur l'icône Pulse → bouton « Détacher » (deux
   fenêtres, à gauche de ⚙) ; vérifier que la fenêtre reste au-dessus de
   Premiere en plein écran, et qu'un clic sur l'épingle la libère. Puis
   bouton « Tableau de bord » (à côté) : la fenêtre s'ouvre sur le second
   écran s'il y en a un.
2. Une décision : signer Pulse avec un certificat « Apple Development »
   gratuit (Xcode › Réglages › Comptes › ajouter son Apple ID, puis « Manage
   Certificates » › « + » › Apple Development). Sans lui, ni les actions
   Raccourcis ni les widgets ne peuvent marcher (linkd et chronod refusent
   une app ad hoc). Avec lui : `PULSE_IDENTITE="Apple Development: …"` pour
   `build.sh` (dans `outils/fusionne.sh` pour l'app installée), un clic
   « Toujours autoriser » au trousseau la première fois, et à revérifier
   l'ouverture à la connexion (`SMAppService`), liée à la signature.

Ensuite : avec l'identité, enregistrer et tester widgets et Raccourcis pour
de vrai (devant Isma) ; option d'un panneau détaché plus petit (une colonne
compacte, cadence plus lente) si 7,7 % d'un cœur en continu au-dessus de
Premiere lui paraît cher ; un défilement si le panneau détaché dépasse un
jour la hauteur de l'écran (1 229 pt aujourd'hui pour 1 290 utiles).
