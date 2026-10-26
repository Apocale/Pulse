# 09-barre — barre de menus façon iStat

Départ : dimanche 11/10/2026, 05 h 37 UTC (07 h 37 à Paris).
Branche `chantier/09-barre`, worktree `.claude/worktrees/agent-a7056b55d37c81387`.

## Plan en jalons

**J1 — Le dessin des segments, mode combiné réglable**
- `Sources/Pulse/MenuBar/` : réglages de la barre (`reglages.json`, champ
  `menuBar`, lu en `decodeIfPresent`), catalogue des segments (mémoire,
  disque, débit, processeur, batterie du chantier 06, température du 04),
  dessin AppKit en image template — texte (étiquette au-dessus de la
  valeur), mini-graphe, jauge, anneau ; débit empilé ↑/↓.
- Largeur figée sur le pire cas de la configuration, pas des valeurs.
- Segment processeur (« CPU / 44 % ») fourni par `ProcessorModule`.
- `--snapshot x.png --barre` : la barre réglée, plus une galerie de tous
  les styles, sur barre sombre et claire. Tests de composition et de
  largeur. Section BARRE DE MENUS de `--probe`. Banc remesuré.

**J2 — Un élément ou un par module, alerte, page de Réglages**
- Mode « un élément par module » : un `NSStatusItem` par segment, chacun à
  largeur figée.
- L'alerte du verdict : un symbole à place réservée (largeur constante),
  jamais une couleur seule ; réglable (alertes, avertissements, jamais).
- Page « Barre de menus » dans la fenêtre Réglages : mode, segments
  (affichés, ordre, style), alerte, aperçu, place occupée.

**J3 — La place à droite de l'encoche**
- 918 pt à droite de l'encoche. Détecter qu'un élément de Pulse est caché
  (derrière l'encoche, hors écran) et le dire dans le panneau et dans
  `--probe` (fenêtres de barre de menus lues par `CGWindowListCopyWindowInfo`,
  sans autorisation).

## Journal

### J1 et J2 — dessin, styles, un ou plusieurs éléments, alerte, Réglages (05 h 37 → 06 h 15 UTC)

Fait :
- `Sources/Pulse/MenuBar/` : `MenuBarSettings` (clé `menuBar` de
  `reglages.json`, tolérante), `MenuBarCatalog` (six segments : mémoire,
  disque le plus serré, débit, processeur, batterie du 06, température du
  04 ; styles permis, place par défaut), `MenuBarContent` (composition pure,
  rejouée par les tests), `MenuBarDrawing` (AppKit, image template, 10 pt),
  `MenuBarController` (un élément ou un par segment, largeur figée, clic,
  ancrage du panneau), `MenuBarRoom` (ce qui se voit), `MenuBarProbe`,
  `MenuBarSnapshot`, `MenuBarSettingsPage`, `MenuBarNotice`.
- Styles : texte (étiquette au-dessus de la valeur), mini-graphe (douze
  relevés), jauge, anneau ; débit empilé ↑/↓ ou en miroir. Jauge et anneau
  refusés sans total réel (règle n°7) : ni débit ni température.
- Alerte du verdict : triangle plein (alerte), en contour (avertissement, si
  demandé), place réservée — la largeur ne bouge pas quand elle arrive.
  Isma est en alerte ~34 % du temps (règles 3 et 4, journal des 7 jours) :
  le symbole sera souvent là.
- Segment processeur (`ProcessorModule.menuBarSegment`). Batterie « BAT »
  dessinée comme les autres, éteinte par défaut (macOS l'affiche déjà) ;
  allumée, le module Énergie continue de lire carte masquée
  (`ModuleState.menuBar`).
- Icône cachée : sur macOS 26 les icônes sont des fenêtres de Control
  Center (relevé `CGWindowListCopyWindowInfo`) ; un élément se voit si une
  fenêtre affichée contient son cadre. Dit dans le panneau (ligne sous le
  verdict) et dans `--probe`. Au raccourci ⌃⌥M, le panneau ne s'accroche
  plus à une icône cachée.
- Budget, demandé par la coordination : débit affiché filtré à 30 %, barre
  refaite au plus toutes les 3,5 s, comparaison sur ce qui est dessiné.

Mesures :
- Les deux binaires au banc aux mêmes secondes (06 h 10) : libellé redessiné
  33 fois (main) → 17 (09-barre) ; banc panneau fermé 0,28/0,35 % →
  0,23/0,27 % d'un cœur ; réveils 1,7-1,9 → 0,8 par seconde.
- Largeur de l'élément réglé par défaut : image de 141 pt (dont 18 pour la
  place de l'alerte) ; à droite de l'encoche, 918 pt, 828 pris par 13
  icônes, 92 libres (`--probe`). Pulse installé : x 1347–1472, visible.
- `swift test` : 17 tests `MenuBarTests`, les trois clés (largeur figée, rien à redessiner, débit filtré) vues échouer sous mutation ; `./verifie.sh` : tout passe (201 puis 204 tests), fusionné en 87cc893.

### J3 — la place, vérifiée sur la vraie barre (06 h 15 → 06 h 45 UTC)

Fait :
- Visibilité de l'icône vérifiée AVANT de créer le panneau (sa hauteur tient
  compte de la ligne « icône cachée », sans saut) ; ligne précisée : barre
  pleine, ou Pulse décoché dans Réglages Système › Barre de menus.
- Polices et attributs du dessin mis en cache ; chaque style de chaque
  segment vérifié dessiné (`chaqueStyleDessine`) ; l'horloge du chantier 18,
  arrivée dans le catalogue entre-temps, couverte par les tests.
- Trois synchronisations avec main (11, 03, 12, 10, 15, 18), conflits
  résolus en gardant les deux côtés (Réglages, `--probe`, panneau).

Mesures sur le Pulse installé, relancé par la fusion (2e4aabc, 06 h 41) :
- `--probe` (API d'accessibilité + fenêtres de Control Center) : élément
  x 1337–1480, 143 pt, visible ; 125 pt avant — les 18 pt de la place de
  l'alerte, le reste à l'identique. À droite de l'encoche : 918 pt, 838
  pris par 13 icônes, 82 libres.
- Description d'accessibilité de l'élément : « Pulse — alerte : Ssd 2 plein
  vers vendredi · mémoire 70 % · Ssd 2 occupé à 85 % · reçu 8,7 ko/s ·
  envoyé 43,0 ko/s ».
- Coût, Pulse installé, 5 à 10 min après chaque lancement (`ps -o time=`,
  5 min) : 0,857 % puis 0,820 % d'un cœur avant (main sans la barre 09) ;
  0,409 % après (2e4aabc). L'écart mêle la barre et « Relevé fermé : un
  appel au noyau par processus » (chantier 15, fusionné au même moment) :
  pas attribuable à la barre seule. Au banc aux mêmes secondes : banc sans
  icône 0,32 %, Pulse installé 0,63 % (machine à 90-96 %).
- Images de la barre sur le Pulse installé (description d'accessibilité
  relue toutes les 0,5 s pendant 2 min) : 15 par minute, contre une
  trentaine avant (README, chantier 03). La moitié restante : les « 1,0k »,
  « 2,6k », « 3,6k » du repos, et la mémoire qui bougeait d'un point à
  chaque relevé (compilations des chantiers). D'où un plancher de 3 ko/s sous
  10 ko/s pour la bande du débit, et une image au plus toutes les 5 s.
- `Banc.icone` est passé à 0,13 % (chantier 03, profil de l'ancienne barre :
  dessin du bouton, `fixLengthOnce` à chaque image, infobulle et libellé
  VoiceOver). Désormais la largeur ne se remesure qu'à un changement de
  composition, l'infobulle et le libellé seulement s'ils changent : à
  re-profiler par le 03 ou le 15 (je n'ai pas lancé `sample`).
- Second relevé du Pulse installé (barre J3, relancé à 06 h 58, 5 à 10 min
  après) : 0,437 % d'un cœur. Le plancher de 3 ko/s et l'image au plus
  toutes les 5 s (7f71f28) s'installent à la relance suivante.

### Bilan à 07 h 25 UTC

- Fusionné dans main : 87cc893 (J1, J2), 2e4aabc (J3), 7f71f28 (plancher de
  3 ko/s, une image au plus toutes les 5 s). Installé par la relance de
  07 h 16.
- Images de la barre sur le Pulse installé, description d'accessibilité
  relue 2 min : ~30 par minute avant (chantier 03), 15 avec la bande de
  30 %, **9,5** avec le plancher et les 5 s. Le reste : la mémoire qui
  bouge d'un point (60, 61, 62 %) et les vraies variations du débit.
- Dernière fusion refusée par `outils/fusionne.sh` : `CalendrierTests`
  (chantier 18, `ExtrasTests.swift`) échoue depuis ~07 h 15, sans rapport
  avec la barre — le test compare un événement « dans 25 min » à une heure
  figée. Ce journal reste sur la branche jusqu'à la prochaine fusion.
- CPU du Pulse installé, 5 min (`ps -o time=`) : 0,857 et 0,820 % d'un cœur
  avant la barre 09 ; 0,409 et 0,437 % avec la barre J3 ; **0,353 %** avec la
  barre finale (07 h 23 → 07 h 28). Gain mêlé au « Relevé fermé » du
  chantier 15, fusionné dans le même intervalle.
