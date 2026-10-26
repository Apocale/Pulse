# 10-animations — animations, Liquid Glass, thèmes

Départ : dimanche 11/10/2026, 07 h 37 (heure de Paris), 05:37 UTC.
Branche `chantier/10-animations`, worktree `.claude/worktrees/agent-af2fb22e80ff659ba`.
Fin au plus tard : 07:37 UTC.

Skills chargés avant de dessiner : animate, emil-design-eng, liquid-glass,
apple-design. Leur barre : une animation doit dire pourquoi elle existe, sinon
elle n'existe pas ; jamais sur un chiffre ; ressort ou courbe forte, jamais
`ease-in` ; Réduire les animations et Réduire la transparence livrés avec.

## Ce que la machine impose, mesuré avant de commencer

- **Une animation SwiftUI dans une fenêtre jamais affichée tourne sans
  frein.** Fenêtre hors écran (comme celle de `--banc`), une animation
  linéaire de 4 s : 77 840 images évaluées en 5 s, 2,68 s de processeur
  (`.build/exp/tick.swift`). À l'écran, la synchronisation verticale la borne
  à 120 images/s. Conséquence : le banc ne peut pas mesurer une animation
  telle que la vit Isma ; son coût se mesure en coût PAR IMAGE, multiplié par
  le nombre d'images réelles.
- **Le cadre de NSPopover est déjà du verre sous macOS 26.** Introspection du
  runtime, sans rien afficher : `NSPopoverFrame` (un `NSVisualEffectView`)
  porte `_glassVariant` et `_updateGlassVariant`, ses données privées un
  `glassView`. Le fond opaque #1E1E1E du panneau le recouvre aujourd'hui.
- Banc de départ (40 s, machine occupée à 91 %) : fermé 0,45 %, ouvert
  13,24 % (création 182 ms et rendu complet 82 ms compris), budget estimé
  0,87 %. Panneau 626 × 1 210 pt.

## Plan en jalons

**J1 — Ouverture** (`UI/Motion/`)
- Cascade des cartes en 300 ms au plus : verdict, puis les cartes en
  diagonale (rang = ligne + colonne), opacité et 5 pt de chute vers leur
  place — le panneau vient de la barre de menus, au-dessus.
- Anneaux, jauges et barres qui se remplissent jusqu'à leur valeur dans la
  même fenêtre ; les chiffres, eux, sont posés d'emblée.
- Courbe ease-out forte (0,23 ; 1 ; 0,32 ; 1), évaluée à la main.
- Réduire les animations : tout est en place d'emblée.
- Vérifié sur une planche d'images (`--snapshot x.png --ouverture`).

**J2 — Survols et défilement**
- États de survol et d'appui sur tout ce qui se clique (lignes dépliables,
  raccourcis, Réglages, Quitter).
- Survol des graphes du panneau : valeur et heure sous le curseur.
- Le graphique miroir du débit défile en continu entre deux relevés, à une
  cadence bornée et mesurée.

**J3 — Liquid Glass**
- Le cadre du panneau en verre natif de macOS 26 ; cartes et verdict sur des
  fonds opaques : aucune donnée sur du verre, prouvé sur deux rendus à
  arrière-plans différents.
- Réduire la transparence : le fond opaque d'aujourd'hui.

**J4 — Thèmes**
- Système, Sombre, Clair, Violet, Indigo, Accent du système ; choix dans la
  fenêtre Réglages ; chaque thème mesuré par `outils/contraste.swift`.

## Journal

### J1 — ouverture, et les six historiques alignés (05:37 → 06:12 UTC)

Fait :
- `UI/Motion/Opening.swift` : une horloge d'ouverture (`\.opening`, 1 par
  défaut partout), la cascade `entrance(rank:)` — verdict au rang 0, cartes
  en diagonale (1 + ligne + colonne), barre de raccourcis au rang 4 —,
  opacité et 5 pt de chute, courbe (0,23 ; 1 ; 0,32 ; 1) résolue à la main.
  Les anneaux (`Ring`, `SegmentedRing`) se remplissent jusqu'à leur valeur
  dans la même fenêtre ; les chiffres sont posés d'emblée.
- `OpeningDriver` : `TimelineView` à 60 images/s au plus, mise en pause à
  300 ms. Réduire les animations : tout est posé dès la première image. Le
  vrai popover seulement (`AppDelegate.makeContent`) : rendus, aperçus et
  banc dessinent le panneau posé.
- `--snapshot x.png --ouverture` (et `--carte <id> --ouverture`) : la
  planche, une image tous les 40 ms ; mesure du coût en prime.
- Demande de la coordination : les titres de Processeur, Mémoire et Réseau
  ouvrent l'historique longue durée (`HistoryChart`, cpu.total,
  memoire.utilisee, reseau.reception + envoi), en bas de carte comme
  Disques, Capteurs et Énergie.
- Panneau trop haut dès qu'un dépliant s'ouvre — défaut ANTÉRIEUR, mesuré
  avec `--snapshot x.png --ouvert <clé>` (nouveau pour le panneau entier) :
  volumes 1 381, capteurs 1 393, énergie 1 344, 7 derniers jours 1 445,
  connexion 1 398, session 1 359 pt, pour 1 290 utiles. Désormais, pendant
  qu'un dépliant est ouvert, les autres cartes de SA colonne passent en
  compactes (`PopoverView.historyOwners`) : 1 214 à 1 220 pt pour les
  douze dépliants, fermé 1 220 pt.

Mesures :
- Planche regardée : rien à 0 ms, verdict et premières cartes à 40 ms,
  anneaux aux trois quarts à 80 ms, tout posé à 300 ms.
- Coût d'une image de cascade : 5 à 14 ms selon la charge de la machine ;
  le remplissage des 24 anneaux en était la moitié, les barres sur `Canvas`
  l'essentiel du reste — retirées du remplissage, comme les douze petits
  anneaux des cœurs. Horloge essayée hors écran : 18 images en 285 ms
  (60/s), dernière valeur 1,000, puis plus rien. Soit ~90 ms de processeur
  par ouverture (19 × 4,9 ms ajoutées, témoin immobile retranché).
- Panneau fermé : aucune vue, donc rien de plus.

### J2 — survols et appuis (06:12 → 06:24 UTC)

Fait :
- `UI/Motion/Pressable.swift` : `.pulseRow` et `.pulseIcon`, sur TOUT ce
  qui se clique dans le panneau — lignes dépliables (`Explainable`, donc
  les six titres et chaque ligne à chevron), raccourcis, Réglages, Quitter,
  « Régler le forfait iPhone » (07), sélecteur de plage de `HistoryChart`
  (02). Voile au survol en 120 ms ease-out ; à l'appui la ligne se resserre
  à 0,98, l'icône à 0,92, en 80 ms, retour en 160 ms. Réduire les
  animations : voile sans transition, aucun resserrement.
- Quitter n'est plus un bouton de verre : dans un cadre tout en verre (J3)
  il ne se distinguait plus, et `--snapshot` ne savait pas le dessiner —
  il manquait aux rendus. Il a le dessin des raccourcis, en mot.
- `UI/Motion/GraphHover.swift` : survol des graphiques en barres du
  panneau — processeur (l'heure de la minute, la charge), débit réseau et
  activité des disques (l'heure du relevé, les deux débits) : un filet et
  la bulle de `HistoryChart`, sans animation (un filet en retard sur le
  pointeur se lit comme de la lenteur). `--snapshot x.png --survol` dessine
  tout survolé.

Mesures :
- Voile mesuré (`MotionTests`) : blanc 5 % en sombre, noir 3 % en clair ;
  chaque teinte de `Palette` y garde 3:1. À 6 % de noir en clair, le bleu
  tombait à 2,97:1 : d'où 3 %.
- Rendus figés (`--rendus`) : six références refaites et regardées — les
  titres Processeur et Mémoire portent leur chevron (+2 pt), Quitter
  apparaît en pied.

### J3 — Liquid Glass (06:24 → 06:30 UTC)

Fait :
- `UI/Themes/Glass.swift` : sous macOS 26, le cadre de NSPopover est déjà
  du verre ; le panneau le laisse voir hors des données (`\.glassFrame`).
  Pas de second verre SwiftUI par-dessus : du verre sur du verre. Le verre
  natif apporte sa forme (flèche comprise) et suit seul Augmenter le
  contraste.
- Cartes OPAQUES (`Palette.card`), aux valeurs exactes que rendait l'ancien
  voile : 0,171 en sombre, #FAFAFA en clair. Le verdict prend la même
  surface opaque quand il y a du verre autour (+14 pt).
- Réduire la transparence : le fond opaque d'avant, relu à chaque
  ouverture. Rendus, aperçus et banc : opaques, comme avant.
- `--snapshot x.png --verre` : le panneau posé sur des bandes criardes à
  la place du verre. Regardé : les bandes n'apparaissent que dans les
  marges, les interstices et la barre de raccourcis ; aucune carte, aucun
  chiffre, aucune teinte n'est posé dessus.
- Boutons des chantiers 12 (conseil) et 08 (dossier du cache) : même style
  de survol et d'appui.

Mesures :
- Rendus figés refaits : écart d'un niveau sur 255 au plus (arrondi du
  voile devenu opaque), 16 pixels en sombre, 14 143 en clair.
- Contraste : inchangé (mêmes fonds), voir `./verifie.sh`.
- Non vérifiable sans ouvrir le panneau : le rendu du verre lui-même —
  à regarder par Isma (voir le rapport).

### J4 — thèmes (06:30 → 06:40 UTC)

Fait :
- `UI/Themes/Theme.swift` : Système (le panneau d'avant), Sombre et Clair
  (apparence imposée au popover), Violet, Indigo, Accent du système
  (sombres). Un thème ne change que les fonds — panneau, cartes, teinte
  posée sur le verre du cadre — ; les teintes de données restent celles de
  `Palette` et des réglages par série, qui ne cassent pas : une teinte
  acceptée sur Système l'est sur tous (luminance des cartes bornée).
- Réglages › Général › Apparence : le choix du thème ; `reglages.json`,
  `display.theme`, lu en tolérant (absent ou inconnu : Système).
- `--snapshot x.png --theme <id>` ; `outils/contraste.swift` accepte « - »
  pour un thème d'une seule apparence.
- README (options, quatre pièges) et CLAUDE.md complétés en fin de section.

Mesures (`outils/contraste.swift` sur les rendus, seuil 3:1) :

| Thème | Carte lue | Plus basse |
|---|---|---|
| Système, sombre | #393939 | 3,18 (violet) |
| Système, clair | #FAFAFA | 3,37 (bleu) |
| Sombre | #393939 | 3,18 |
| Clair | #FAFAFA | 3,37 |
| Violet | #3A314F | 3,34 |
| Indigo | #2D3752 | 3,25 |
| Accent (bleu, celui de la machine) | #233951 | 3,26 |

- `ThemeTests` : chaque teinte, voile de survol compris, sur la carte et le
  panneau de chaque thème, et Accent avec les huit accents de macOS ; la
  borne de luminance ; Système identique à avant ; réglage tolérant.

### J5 — graphes qui défilent, chiffres nets (06:54 → 07:15 UTC)

Fait :
- `UI/Motion/Scroll.swift` : le miroir du débit (carte Réseau) glisse
  d'une barre sur la durée d'un relevé ; la nouvelle barre entre par la
  droite à son arrivée. `TimelineView` périodique à 3 images/s, un pixel
  par image ; barres dessinées une fois par relevé, seul leur décalage
  change (`visualEffect`). Le survol suit le glissement. Réduire les
  animations : saut d'une barre par relevé, comme avant. Rendus immobiles.
- `--snapshot x.png --defilement` : planche à 0, ¼, ½, ¾ et 1 relevé.
  Décalage mesuré image à image contre le repère : 0 · 1 · 3 · 4 px, puis
  la grille retombe en place à 1 — la boucle est sans couture.
- Chiffres nets : les neuf `.contentTransition(.numericText())` des
  dépliants (`DetailPanels.swift`) et leurs animations de valeur retirés
  (mission, point 5 : aucune animation sur un chiffre qui change à chaque
  relevé ; le README l'avait déjà relevé pour le verdict).
- Barres remplies d'un seul tracé par côté (`MirrorBars`, `HistoryBars`).

Mesures :
- Défilement à 12 images/s : 3,2 à 3,8 % d'un cœur, que les barres soient
  redessinées ou seulement décalées — le prix est la mise à jour SwiftUI
  (2,6 ms par image), pas le dessin. Abandonné pour 3 images/s : écart non
  mesurable au-dessus du bruit sur 5 s (≤ 0,8 % calculé, 2,6 ms × 3).
- Panneau fermé : aucune vue, aucune horloge.

### Bilan à 07:25 UTC

Fusionnés dans `main` : J1 + J2 (2bb52c1), J3 (27b46d1), J4 (e878d67),
chaque fois après `./verifie.sh` complet (TOUT PASSE, budget panneau fermé
0,41 à 0,91 % d'un cœur, rendus figés refaits et regardés).

J5 (défilement du miroir, chiffres nets des dépliants) : commité sur la
branche, `./verifie.sh` complet passé à 07:15 ; la fusion de 07:18 est
refusée par `fusionne.sh` sur `swift test` — `CalendrierTests` (chantier 18,
`ExtrasTests.swift:40, 58, 128-129`) échoue à chaque essai, alors que
l'arbre ne diffère de `main` que par les fichiers de ce chantier (aucun dans
`Modules/Extras/`). Passé à 07:15, échoue depuis la synchronisation qui a
amené le chantier 14 (07:16). À relancer dès que `main` repasse ses tests :
`git merge main`, `./verifie.sh`, `outils/fusionne.sh chantier/10-animations`.

Reste à voir par Isma, faute de pouvoir ouvrir le panneau : le verre du
cadre, la cascade et le glissement du débit en vrai, un thème.

Ensuite, si on continue : le défilement des autres graphiques en barres
(activité des disques), une transition de thème, le chantier 16 (VoiceOver
à l'oreille sur les nouveaux contrôles).
