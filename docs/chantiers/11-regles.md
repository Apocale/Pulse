# 11-regles — règles et notifications

Départ : dimanche 11/10/2026, 05 h 37 UTC (07 h 37 à Paris), `date` de la
machine. Butée : 07 h 37 UTC. Branche `chantier/11-regles`, worktree
`.claude/worktrees/agent-ad6ef8310243a752a`, parti de `main` en 7bff9d8.

## Ce qui ne se négocie pas ici

- La demande d'autorisation de notifications s'afficherait sur l'écran
  d'Isma : elle ne part que le jour où il active lui-même une règle. Aucun
  essai ne touche `UNUserNotificationCenter` : le moteur se teste avec un
  notificateur injecté, et le notificateur système n'est jamais créé hors du
  bundle, ni sous `--probe`, `--snapshot`, `--banc` ou `swift test`.
- Coût nul quand aucune règle n'est active : pas d'abonnement, pas de
  minuterie. Active, une règle s'évalue sur les relevés existants du
  `Sampler`, sans relevé de plus.
- Toutes les règles sont désactivées par défaut. Jamais de fenêtre qui
  s'ouvre ; Ne pas déranger et les modes de concentration sont ceux de macOS,
  qui retient toute notification ordinaire (jamais « urgente » au sens du
  système).

## Plan en jalons

**J1 — Le moteur, pur et testé** (`Sources/Pulse/Rules/`)
- Modèle `Regle` persistable, décodé champ par champ (règle dure n° 2).
- Catalogue des mesures que les modules exposent (mémoire, disques, réseau,
  forfait iPhone, montage) et le relevé qui les lit sur le `Sampler`.
- Moteur : durée minimale, hystérésis (marge de retour et délai de sortie),
  plages horaires (y compris à cheval sur minuit), un épisode = une seule
  notification, événements (export terminé, plantage) regroupés en rafale,
  au plus une notification toutes les 5 min (le reste regroupé dans la
  suivante), retenue tant qu'une app de montage est au premier plan.
- Préréglages, tous éteints : disque de rushes sous X Go, export terminé,
  Premiere a planté, forfait iPhone à 80 % puis 100 %, swap qui monte,
  connexion perdue.
- Tests, chacun vu échouer sans sa correction.

**J2 — Branché dans l'app, coût nul au repos**
- `regles.json` (tolérant, mis de côté s'il est illisible), journal
  `regles.jsonl` (30 jours).
- Le surveillant s'abonne au relevé seulement si une règle est active.
- Notificateur système : `UNUserNotificationCenter`, créé à la demande dans
  le bundle seulement ; autorisation demandée à l'activation d'une règle.
- Section RÈGLES de `--probe` : chaque règle, sa mesure du moment, si sa
  condition tient, le journal des 7 derniers jours.
- Budget mesuré au banc.

**J3 — L'éditeur dans la fenêtre Réglages**
- Page « Règles » (un cas de `SettingsPage`, une ligne de barre latérale) :
  interrupteur, seuil, durée, plage horaire, actions, regroupement, journal.
- Rendu hors écran `--snapshot x.png --reglages regles`, sombre et clair.

**J4 — Le signal dans la barre**
- Un symbole, jamais une couleur seule, tant qu'un épisode d'une règle qui
  le demande est en cours ; la largeur de l'icône ne danse pas.
- Les données exposées au chantier 09 (segment de barre).

**J5 — Rapport**
- README, CLAUDE.md, la demande exacte à Isma.

## Journal

### J1 — le moteur (05 h 37 → 05 h 58 UTC), commit 391c79d

Fait :
- `Sources/Pulse/Rules/` : `Regle.swift` (règle, plage horaire, réglages
  communs, fichier, sept préréglages éteints), `Mesures.swift` (catalogue :
  13 mesures de 5 modules), `LectureRegles.swift` (valeurs tirées des
  relevés existants, détecteur d'événements), `Moteur.swift` (pur),
  `JournalRegles.swift`, `ReglesStore.swift`, `Notificateur.swift`,
  `SurveillantRegles.swift`.
- Épisode : commence quand la condition a tenu sa durée sans interruption,
  finit quand la mesure a repassé le seuil de la marge ET y est restée le
  délai de sortie. Une notification par épisode. Un événement (export fini,
  plantage) ouvre une rafale : les suivants dans le délai s'y comptent
  (« a planté 3 fois depuis 14 h 00 »).
- La boîte : au plus une notification par intervalle (5 min), ce qui arrive
  entre-temps part regroupé (« Pulse · 2 alertes ») ; rien de non urgent
  tant qu'une app de montage est au premier plan ; une alerte d'état
  retombée avant d'être dite ne part jamais.
- Deux pièges évités avant d'exister :
  - **la veille** : deux relevés séparés de plus de 60 s ne se suivent pas,
    les compteurs repartent de zéro — sinon « hors ligne depuis 30 s » au
    réveil, le Wi-Fi étant coupé pendant la veille ;
  - **le redémarrage** : un épisode laissé ouvert au journal est repris
    déjà dit — sinon chaque relance de Pulse (`fusionne.sh` en fait
    plusieurs par heure aujourd'hui) redirait « disque presque plein ».
- Absence de mesure (disque débranché, forfait non réglé) : ni vraie ni
  fausse, l'épisode est gelé — un disque presque plein qu'on rebranche n'a
  pas été vidé.

### J2 et J3 — branché, `--probe`, page Réglages (05 h 58 → 06 h 05 UTC), commit 8fbcf80

- `SurveillantRegles.demarrer` (une ligne dans `PulseApp.swift`) : abonné à
  `regles.json` seulement ; à la publication de la mémoire du `Sampler`
  (une fois par relevé) seulement si une règle est active.
- `--probe` : section RÈGLES (chaque règle, sa condition en clair, la
  valeur du moment et si la condition tient, l'autorisation), puis
  JOURNAL DES RÈGLES sur 7 jours.
- Fenêtre Réglages : `SettingsPage.regles`, ligne « Règles et alertes » sous
  « Général ». Rendue hors écran, sombre et clair, `--ouvert <id>` pour un
  réglage déplié. Le statut des notifications y vaut « indisponibles hors de
  Pulse.app » : le rendu ne touche pas au centre de notifications.

Mesures :
- 20 tests (`ReglesTests`, `SurveillantReglesTests`). **Chacun vu échouer
  sans sa correction** : 23 mutations, une par correction, appliquées une à
  une à une copie de la branche (`mutations.py`, dossier de travail de la
  session) — toutes font échouer leur test. Deux ne le faisaient pas au
  premier passage (règle éteinte, retenue en montage) : les tests ont été
  renforcés, puis revus échouer.

### Fusion 1 (06 h 11 UTC) : J1 à J3 dans `main` (39aa04f)

`./verifie.sh` : tout passe en 196 s — 172 tests, `--probe` 389 lignes,
rendus 626 × 1 216 pt, 10 rendus figés identiques, contraste au plus bas
3,18:1, **données de Pulse intactes** (ni `regles.json` ni `regles.jsonl`
écrits par les essais), budget panneau fermé **0,79 % d'un cœur estimés**
(0,34 % au banc + l'icône), Pulse installé aux mêmes secondes 0,73 %.

### J4 — la cloche dans la barre (06 h 11 → 06 h 25 UTC)

- `MenuBarLabel.alerte` : `nil`, rien de réservé (l'icône d'Isma ne change
  pas d'un pixel tant qu'aucune règle allumée ne demande la cloche) ;
  `false`, la place d'une cloche, vide ; `true`, la cloche (`bell.fill`,
  un symbole, jamais une couleur). La largeur figée de l'icône compte la
  place dès qu'une règle allumée la demande : rien ne danse quand un
  épisode commence ou finit. Infobulle et VoiceOver : « alerte : Disque de
  rushes presque plein et 1 autre ».
- `SurveillantRegles.segmentBarre` : le segment pour le chantier 09 (un
  élément par module), valeurs seulement.
- `--snapshot x.png --barre --alerte` : la barre avec sa cloche, regardée.
- Le disque suivi d'office à l'allumage : le disque de rushes, c'est-à-dire
  l'externe qui sera plein le plus tôt, sinon le moins libre — pas le plus
  grand : Ssd 2 et Extreme Pro font tous deux 2 To.
- Une alerte qui attend suit les réglages du moment : décocher la
  notification pendant qu'elle est retenue l'annule.

Mesures :
- Coût des règles ALLUMÉES (`PULSE_BANC_REGLES=20000 swift test --filter
  BancRegles`) : les sept préréglages actifs, 20 000 relevés à 5 s
  d'intervalle simulé, forfait relu chaque minute, app au premier plan lue
  à chaque fois : **156 µs par relevé en compilation de débogage, soit
  0,0031 % d'un cœur** panneau fermé — borne haute, le binaire de l'app
  est optimisé. Sans règle allumée : zéro, aucun abonnement.

Vérification avant la fusion 2 (06 h 25 UTC) : `./verifie.sh` tout passe en
183 s — 189 tests, 16 rendus figés identiques, contraste au plus bas
3,18:1, données intactes, budget panneau fermé 0,92 % d'un cœur estimés
(0,47 % au banc + l'icône ; Pulse installé aux mêmes secondes 0,81 %, la
machine sert à une dizaine de chantiers). `main` a bougé entre-temps
(10-animations) : resynchronisé, revérifié.

### J5 — la notification d'essai (06 h 25 → 06 h 30 UTC)

- Bouton « Envoyer une notification d'essai » dans la page : Isma voit à
  quoi ressemble une alerte sans attendre un vrai problème. C'est à ce clic
  — le sien — que macOS pose la question d'autorisation, s'il ne l'a jamais
  posée. Le résultat s'affiche sous le bouton et s'écrit au journal.
- L'erreur de macOS est gardée telle quelle (domaine et code) : si la
  signature ad hoc de Pulse.app empêchait les notifications, le journal et
  `--probe` le diraient, au lieu d'un « refusée » qu'on prendrait pour un
  refus d'Isma.

### La cloche dans la barre du chantier 09 (06 h 30 → 06 h 40 UTC)

Le 09 a refait la barre pendant ce temps (`Sources/Pulse/MenuBar/`) et
retiré `MenuBarLabel` : ma première cloche est partie avec lui. Elle passe
désormais par la place d'alerte du 09, qui existait déjà pour le verdict :
`MenuBarComposer.Reading.regles` (`nil` : aucune règle allumée ne la
demande ; `false` : place réservée ; `true` : cloche). La place est comptée
dès qu'une règle allumée la demande, même si Isma a réglé le symbole du
verdict sur « jamais » ; la cloche passe devant le triangle du verdict
(Isma a demandé à être prévenu de CELA ; le verdict reste dans le panneau),
l'infobulle dit les deux. La place d'alerte compte la largeur de
`bell.fill`. Rendu `--snapshot x.png --barre --alerte` regardé : cloche à
gauche, 141 pt avec ou sans elle. Test réécrit sur le compositeur.

### Fusion 2 (06 h 51 UTC) : J4 et J5 dans `main` (61e1f03)

Six synchronisations en vingt minutes : 10-animations, 15-audit-perf,
18-extras, 09-barre, 12-verdict, 13-fenetre ont fusionné pendant mes
vérifications. `./verifie.sh` complet, banc compris, est passé quatre fois
sur la branche (budget panneau fermé estimé 0,57 à 0,92 % d'un cœur selon
la charge de la machine, Pulse installé 0,70 à 0,81 % aux mêmes secondes) ;
les trois dernières tentatives, en `--rapide` pour tenir entre deux
fusions des autres : tout passe (240 tests, données intactes, contraste
3,18:1 au plus bas, 16 rendus figés identiques).

## Bilan — mission faite

- Moteur, préréglages, page Réglages, section RÈGLES, journal, cloche dans
  la barre, notification d'essai : dans `main`.
- Rien n'a été envoyé, rien n'a été demandé à macOS pendant le chantier :
  le centre de notifications n'est touché qu'au clic d'Isma.
- Ce qu'il faut d'Isma (2 min) : Réglages de Pulse → « Règles et alertes »
  → « Envoyer une notification d'essai » → « Autoriser » quand macOS le
  demande ; dire si la bannière « Pulse · essai » est apparue. Sinon, la
  ligne sous le bouton (et `--probe`, section RÈGLES) dit pourquoi — une
  signature ad hoc refusée par macOS s'y lirait telle quelle.
- Tests : 23 (`ReglesTests`, `SurveillantReglesTests`, `BarreEtDisqueTests`)
  plus le banc `BancReglesTests` hors suite. `outils/mutations-regles.py` :
  28 mutations, une par correction — moteur, lecture, surveillant, barre,
  page — toutes vues faire échouer leur test (dernière passe 06 h 54 UTC).
- Ensuite, hors de mon périmètre : la copie de rushes terminée (le 05 ne
  publie pas ses épisodes clos panneau fermé) ; le nom du fichier exporté
  et son issue dans « Export terminé » (historique du 08) ; batterie et
  températures au catalogue des mesures si Isma le veut.
