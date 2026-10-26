# Chantiers parallèles — le tableau de bord ultime

But commun : faire de Pulse le meilleur moniteur système pour un monteur vidéo,
au niveau d'iStat Menus 7 (Bjango) et au-delà. Point de départ dans `main` :
« Façon iStat Menus, livraison 1 » (panneau en cartes sur deux colonnes, barre
de menus combinée), commit 51e469d.

Chaque chantier tourne dans sa propre session, son propre worktree, sa propre
branche. Ce fichier est le contrat entre eux : le lire en entier avant de
commencer.

## La carte

| Id | Chantier | Vague | Attend | Possède (fichiers nouveaux) |
|---|---|---|---|---|
| 01-socle | Modules, mise en page, fenêtre Réglages (« tout modifier ») | 1, prioritaire | — | `Sources/Pulse/Modules/`, `Sources/Pulse/Settings/`, `Sources/Pulse/UI/Cards/` |
| 02-historique | Historique longue durée (SQLite), plages 1 h → 90 j, survol | 1 | — | `Sources/Pulse/History/` |
| 03-banc | Banc d'essai : `--banc`, tests de rendu, `./verifie.sh` | 1 | — | `Sources/Pulse/Bench/`, `Tests/`, `verifie.sh` |
| 04-capteurs | Températures, ventilateurs (lecture), puissance, fréquences | 1 | — | `Sources/Pulse/Metrics/Sensors/` |
| 05-disques | Activité disque par disque et par app, santé, ce qui remplit | 1 | — | `Sources/Pulse/Metrics/DiskActivity/` |
| 06-batterie | Batterie, alimentation, appareils Bluetooth | 1 | — | `Sources/Pulse/Metrics/Power/` |
| 07-reseau | Débit par app, latence, IP, Wi-Fi, quota iPhone | 1 | — | `Sources/Pulse/Metrics/NetworkPlus/` |
| 08-medias | GPU détaillé, moteurs médias, export depuis Premiere, cache média | 1 | — | `Sources/Pulse/Metrics/Media/` |
| 09-barre | Barre de menus façon iStat : styles, un ou plusieurs éléments | 2 | 01 | `Sources/Pulse/MenuBar/` |
| 10-animations | Animations, Liquid Glass, thèmes, survols | 2 | 01 | `Sources/Pulse/UI/Motion/`, `Sources/Pulse/UI/Themes/` |
| 11-regles | Règles et notifications, silencieuses par défaut | 2 | 01 | `Sources/Pulse/Rules/` |
| 12-verdict | Verdict 2.0 : conseil chiffré, boutons, seuils calibrés | 2 | 01 | `Sources/Pulse/Metrics/Advice/` |
| 13-fenetre | Panneau détachable, fenêtre tableau de bord, widgets, Raccourcis | 2 | 01 | `Sources/Pulse/Window/`, `Widgets/` |
| 14-ventilateurs | Contrôle des ventilateurs (helper privilégié, sur accord) | 3 | 04 | `Sources/PulseHelper/` |
| 15-audit-perf | Endurance, veille, débranchements, fuites | 3 | 03 | rapports, seuils de `verifie.sh` |
| 16-audit-ux | Audit Apple / HIG / accessibilité, corrections | 3 | 01, 10 | rapports |
| 17-audit-code | Revue, code mort, Swift 6 strict, sécurité | 3 | la plupart | rapports |
| 18-extras | Horloges, calendrier, météo (désactivés par défaut) | 3, optionnel | 01 | `Sources/Pulse/Modules/Extras/` |

Vague 1 : démarre tout de suite. Vague 2 : quand `Sources/Pulse/Modules/`
existe dans `main` (fusion du socle). Vague 3 : quand ce qu'elle attend est
fusionné. Un chantier de vague 2 lancé trop tôt commence par la partie qui ne
dépend de rien, et se resynchronise.

## Le protocole

1. **Tes fichiers.** Tu crées les tiens, dans les dossiers de la colonne
   « Possède ». Les fichiers partagés — `Sampler.swift`, `PopoverView.swift` et
   les cartes, `PulseApp.swift`, `Palette.swift`, `Format.swift`, `Probe.swift`,
   `Snapshot.swift`, `CLAUDE.md`, `README.md` — ne reçoivent que des
   modifications courtes et localisées. Dans `CLAUDE.md` et `README.md`,
   ajoute en FIN de section, ne réécris pas.
2. **Ta carte avant le socle.** Tant que le registre de modules n'est pas dans
   `main`, construis ta carte dans ton propre fichier, autonome, et rends-la
   avec `--snapshot` (un cas d'une ligne dans `Snapshot.swift` si l'option
   `--carte` n'existe pas encore). Le branchement final tient en une ligne.
3. **Ton journal.** `docs/chantiers/<id>.md` : le plan en jalons, puis à
   chaque jalon fait / en cours / bloqué / ensuite, avec les mesures.
4. **Avant de fusionner**, synchronise ta branche avec `main` (outil
   `sync_with_base_branch` si ta session l'a, sinon `git merge main` dans ton
   worktree : pas de remote, la branche `main` locale fait foi), puis vérifie
   tout :
   - `./build.sh` et `swift test` ;
   - `./.build/release/Pulse --snapshot x.png` en sombre et `--light`, regardés ;
   - `swift outils/contraste.swift sombre.png clair.png` (≥ 3:1) ;
   - le budget : moins de 1 % d'un cœur panneau fermé (`--banc` dès que le
     chantier 03 l'a livré, sinon mesure isolée de ta partie) ;
   - `./.build/release/Pulse --probe` cohérent avec l'écran ;
   - `./verifie.sh` dès qu'il existe : c'est lui qui fait foi.
5. **Fusion, en avance rapide seulement, par le script** :
   `/Users/isma/Documents/Dashbaord/outils/fusionne.sh <ta-branche>`. Il prend
   un verrou (une fusion à la fois), avance `main`, recompile et relance le
   Pulse installé. Refusée parce que `main` a bougé : resynchronise, revérifie,
   recommence. Jamais de `--force`, jamais de réécriture de `main`.
6. **Ta branche** s'appelle `chantier/<id>`, ta mission est la section `<id>`
   de `missions.md`.
7. **Commits** : petits, en français, un par jalon, terminés par la ligne
   d'attribution que ta session t'indique.

## Interdits

- Ouvrir le panneau sur l'écran d'Isma : ni `--show`, ni ⌃⌥M, ni clic
  simulé. Il monte, souvent en plein écran. Les rendus se font hors écran.
- Ouvrir un fichier dans une app (`open x.png`, Aperçu, Finder), piloter une
  app par `osascript`, ou déclencher une demande d'autorisation macOS
  (notifications, calendrier, Bluetooth, localisation, contrôle d'une app) :
  tout s'affiche sur son écran. Regarde tes rendus avec l'outil de lecture
  d'images. Seule exception : `outils/fusionne.sh`, qui relance Pulse.
- Lancer `.build/release/Pulse` sans `--probe`, `--snapshot` ou `--banc` :
  une seconde instance écrirait dans son historique.
- Sans son accord explicite : installer quoi que ce soit qui demande le mot de
  passe administrateur, envoyer quoi que ce soit sur Internet, toucher à ses
  réglages système, supprimer un fichier à lui.
- Afficher un chiffre qui ne se retrouve pas dans `--probe`, une couleur qui
  n'a pas son ratio mesuré.

## Chantiers lancés en agents

Isma suit tout depuis une seule conversation, souvent sur son téléphone : la
session de coordination, dans le dépôt principal, lance chaque chantier comme
agent dans son propre worktree, et lui rend compte.

- Un agent ne peut pas parler à Isma. Ce qu'il lui faut (un export réel, un
  accord, un regard sur sa barre) : il avance sur tout le reste, puis écrit la
  demande exacte dans son rapport ; la coordination la transmet.
- Il s'arrête quand sa mission est finie, quand il est bloqué, ou au plus tard
  après 2 h de travail : travail en cours commité sur sa branche, puis
  rapport. La coordination vérifie le quota d'Isma et le relance.
- Le rapport, son dernier message : Fait (mesures, commits fusionnés) · En
  cours · Bloqué (ce qu'il faut d'Isma, précisément) · Ensuite.
- Quota, règle d'Isma (compte partagé avec un ami, ce n'est pas une consigne
  d'économie) : sous 70 % de la fenêtre de 5 h, on avance vite ; entre 70 et
  85 %, la coordination prévient ; à 85 %, les agents s'arrêtent proprement,
  travail commité, jusqu'à la remise à zéro. Mêmes seuils pour la limite
  hebdomadaire.

## Parler à Isma

Monteur vidéo, TDAH, ne code pas. En français, le résultat d'abord, phrases
courtes, une action de moins de 2 minutes à la fin quand il y en a une. Ne
l'interroger que si tu es bloqué ou avant une action irréversible : il veut
des sessions autonomes qui avancent seules pendant des heures.
