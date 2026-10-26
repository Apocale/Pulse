# 16-audit-ux — audit Apple, HIG, accessibilité

Départ : dimanche 11/10/2026, 09 h 21 (heure de Paris), 07:21 UTC.
Branche `chantier/16-audit-ux`. Fin au plus tard : 09:21 UTC.

Skills chargés : apple-design (HIG, 122 pages, juin 2026) et
perception-first-design:evaluate.

Tout se regarde hors écran : `--snapshot` et ses variantes, lus avec l'outil
de lecture d'images. Rien ne s'ouvre sur l'écran d'Isma.

## Plan en jalons

**J1 — Matière et rapport d'audit**
- Rendus de tout : panneau sombre et clair, chaque thème, chaque carte,
  chaque dépliant (`--ouvert`), `--verre`, `--ouverture`, `--fenetre`,
  `--tableau`, `--conseils`, `--historique`, `--barre`, `--exemple`,
  `--ajuste`, chaque page des Réglages.
- Lecture du code des vues : libellés d'accessibilité, tailles de police,
  couleurs du texte, états vides et d'erreur, focus clavier.
- Rapport classé du critique au mineur, chaque point cité (fichier HIG et
  titre), dans ce journal.

**J2 — Accessibilité (critique et haut)**
- Libellés et valeurs VoiceOver de chaque carte, Capteurs (04) et bandeau
  du verdict (12) compris ; ordre de lecture ; éléments décoratifs cachés.
- Navigation clavier ; tailles de texte ; Réduire les animations et la
  transparence revérifiés.

**J3 — Écriture, cohérence, états vides et d'erreur**
- Mots simples en français, sans jargon ; même mot pour la même chose ;
  états vides qui disent quoi faire.

**J4 — Relecture à l'API et choix d'Isma**
- `outils/relecture-ax.swift` : l'arbre d'accessibilité du panneau
  réellement ouvert, lu par `AXUIElementCopyAttributeValue`, prêt à lancer
  par la coordination avec Isma.
- Choix de goût rendus en variantes comparées (rangement des colonnes quand
  le panneau s'ajuste, cartes compactes autour d'un historique ouvert), une
  décision à la fois, ma recommandation en premier.

Chaque jalon : rendus avant/après regardés, `./verifie.sh`, commit,
`git merge main`, fusion par `outils/fusionne.sh`.

## Rapport d'audit, du critique au mineur

Matière : 60 rendus hors écran (panneau sombre et clair, chaque thème,
chaque carte, chaque dépliant, verre, cascade, fenêtre détachée, tableau
de bord, conseils, historique, barre, extras d'exemple, ajustement, pages
des Réglages), le code des vues, deux relectures du code en parallèle
(accessibilité, écriture) et une évaluation perception-first des rendus
(note globale 57/100 : verdict solide et réfutable, mais trop de chiffres
au même poids). Citations : skill apple-design, `references/hig/<fichier>
› <titre>`. « Corrigé » renvoie au jalon du journal ci-dessous.

### Critique
1. **VoiceOver taisait le chiffre de tête de chaque carte** (« 40 % »,
   « 18,9 Go sur 32 Go », « Processeur 75 °C ») et les valeurs de Montage
   (session, temps d'écran, export, incidents) : le libellé posé sur un
   bouton remplace son contenu. `voiceover.md › Descriptions` : « Provide
   alternative labels for all key interface elements ». Corrigé (J2a).
2. **Seize conteneurs sortaient en AXUnknown** (`.ignore`), dont tous les
   résumés parlés des dépliants. Même citation ; piège du README. Corrigé
   (J2b) ; restent `MenuBarSettingsPage.swift:127` (09) et
   `FanSettingsPage.swift:339` (14), chantiers encore ouverts.
3. **Le niveau du verdict n'était dit que par la couleur et le symbole.**
   `accessibility.md › Vision` : « Convey information with more than
   color alone ». Corrigé (J2a), tableau de bord compris (J2b).

### Haut
4. **Graphiques muets** : dernière heure du processeur, débit, exports,
   forfait, 7 derniers jours. `charting-data.md › Best practices` :
   « Make every chart in your app accessible » ; `charts.md › Enhancing
   the accessibility of a chart`. Corrigé (J2a, J2b, J5, J6), graphique
   sonore compris pour le processeur ; chaque jour dit en entier.
5. **Pression mémoire et santé de la batterie : la couleur seule.**
   `color.md › Inclusive color`. Corrigé (J2b), écrit dans l'anneau.
6. **L'orange voulait dire « attention » ET « iPhone ».** `color.md › Best
   practices` : « Avoid using the same color to mean different things ».
   Corrigé (J2b), iPhone en violet mesuré.
7. **Un historique ouvert cachait des cartes entières sans nécessité.**
   `layout.md › Best practices` : « Make essential information easy to
   find by giving it sufficient space ». Corrigé (J2a).
8. **Légende fausse sous la dernière heure du processeur.** `charts.md ›
   Color`. Corrigé (J2b).
9. **Chevrons des lignes dépliables sous 3:1.** `accessibility.md ›
   Vision`, tableau des contrastes. Corrigé (J2b).
10. **Le réglage « Débit : en bits » ne changeait rien** : seule l'ancienne
    carte Réseau, remplacée par celle du chantier 07, le lisait.
    `settings.md › Best practices`. Corrigé (J3).
11. **Le verdict tronqué** quand le panneau est réglé sur une colonne :
    la phrase même (« La mémoire commence à man… »), et le bandeau reste à
    une colonne quand le panneau en prend deux pour tenir.
    `typography.md › Supporting Dynamic Type` : « Keep text truncation to
    a minimum » ; `writing.md › Best practices`. Corrigé (J4) : phrase,
    preuve et conseil passent sur deux lignes au lieu d'être coupés ;
    « et aussi » ne se perd plus. Reste : sur une colonne réglée que le
    panneau élargit à deux pour tenir, le bandeau garde la largeur d'une
    colonne (mise en page du 01).

### Moyen
12. **Glisser-déposer sans alternative** pour ranger les cartes.
    `accessibility.md › Mobility` : « Offer alternatives to gestures ».
    Corrigé (J2b, actions VoiceOver et clavier).
13. **Lecture « valeur, nom », capitales épelées, intitulés hors du rotor.**
    `voiceover.md › Navigation` : « Use titles and headings ». Corrigé (J2b).
14. **Texte sous 10 pt** (`minimumScaleFactor` sur `.caption2`).
    `typography.md › Ensuring legibility`, minimum macOS 10 pt. Corrigé
    (J2b) ; restent les widgets (13), non embarqués sans certificat.
15. **Jargon** : « pt », « Charge 1 · 5 · 15 min », « relevé »,
    « tendance : premier relevé », « Latence », « dBm », « séries », noms
    d'API dans la page Règles (`host_processor_info`, `vm.swapusage`…).
    `writing.md › Getting started` : « Write for everyone… avoiding
    jargon ». Corrigé dans les Réglages (J2b) ; les libellés du panneau
    sont des choix de mots : décision 2 ci-dessous.
16. **Deux chiffres pour une seule grandeur** : « Consommation 71 W »
    (Énergie) et « Machine entière 75 W » (Capteurs), « Température
    32,7 °C » et « Batterie 32 °C » : deux lectures du même capteur à des
    instants différents. Le README le règle déjà pour la carte graphique
    (« une lecture, deux cartes »). Corrigé pour la consommation (J6) : la
    carte Énergie prend la lecture de la carte Capteurs quand celle-ci
    mesure (75 W et 75 W au rendu). Reste la température de la batterie,
    deux sondes différentes (jauge au dixième, SMC).
17. **Panneau détaché hors d'atteinte du clavier** (`NSPanel` non
    activant, voulu pour que Premiere garde le clavier). `keyboards.md ›
    Best practices` : « Support Full Keyboard Access ». Corrigé (J6) : il
    peut devenir actif quand l'Accès complet au clavier est allumé,
    seulement alors.
18. **Une alerte qui arrive panneau fermé n'est pas annoncée** (icône de
    barre). `voiceover.md › Navigation` : « Inform VoiceOver when visible
    content or layout changes occur ». Pour 09 (fichier ouvert) :
    `NSAccessibility.post(…, .announcementRequested)` au passage à l'alerte.
19. **Boutons de plage de l'historique à 18 pt de haut** (1 h, 24 h…).
    `accessibility.md › Mobility` : minimum macOS 20 × 20 pt. Corrigé (J5).

### Bas
20. Pied : l'icône « disque interne » ouvre l'Utilitaire de disque, l'icône
    « disque externe » les réglages de stockage (du disque interne) : les
    vraies icônes d'app se liraient mieux. Jugement.
21. « AirP… » tronqué dans Énergie (la ligne des niveaux passe devant).
22. « …épuisé vers le 22 oct. à / ce rythme » : coupure de ligne. Corrigé
    (J5), comme « masquée » sous 4,5:1 dans la barre latérale des Réglages.
23. « Claude Code » : icône générique blanche (exécutable hors bundle).
24. Thème propre à l'app : `dark-mode.md › Best practices` déconseille un
    réglage d'apparence propre à l'app. Gardé exprès (demande d'Isma,
    façon iStat), « Système » par défaut.

### Ce qui est bien, à garder
Tout ce qui se clique est un `Button` (rien en `onTapGesture`), icônes
nommées, ⌘, et ⌘Q ; règle 6 tenue partout (aucune teinte sur du texte) ;
aucune taille de police littérale ; toutes les animations passent par
`Motion` ou suivent Réduire les animations ; le verre se coupe sous
Réduire la transparence ; l'historique long a ses graphiques sonores ; le
verdict reste réfutable par sa preuve et `--probe`.

## Décisions pour Isma, une à la fois

### Décision 1 — quand le panneau prend une 3e colonne pour tenir

Image : `scratchpad/16-audit-ux/decision-rangement/rangement-A-contre-B.png`
(relevé figé, carte Médias allumée ; rendu `--ajuste`, et `--ajuste
--equilibre` pour B).

- **Ma recommandation : B, équilibré.** 1 016 pt de haut au lieu de 1 240
  (−224 pt, le panneau ne descend plus jusqu'en bas de l'écran), trois
  colonnes de même hauteur, plus de grand trou sous Médias. Le prix :
  Capteurs passe aussi dans la 3e colonne, sous Énergie et Médias.
- A, aujourd'hui (chantier 01) : le moins de cartes déplacées possible —
  seules Énergie et Médias changent de colonne ; Capteurs reste sous
  Montage.

Question à poser : « Quand Pulse ajoute une colonne pour tenir dans
l'écran, tu préfères A (les cartes bougent le moins possible) ou B (trois
colonnes égales, plus court) ? » Si B : `PanelFit.equilibre` devient la
règle (une ligne), test déjà écrit (`laVarianteEquilibreeGarde…`).

### Décision 2 — les mots du panneau (après la 1)

Proposés par la relecture d'écriture, à valider en bloc ou un par un :
« Pression thermique » → « Chauffe » (« pression » reste à la mémoire) ;
« La machine suit » → « Tout va bien » ; « utilisateur · système » →
« Apps · Système » ; « 4 efficacité · 8 performance » → « 4 économes · 8
rapides » ; « Latence Internet » → « Temps de réponse » ; « tendance :
premier relevé » → « rythme : pas encore mesuré » ; « Charge 1 · 5 · 15
min » → « Tâches en cours (1 · 5 · 15 min) » ; « ↑ 3,8k » → « ↑ 3,8 ko » ;
« Temps d'écran Claude 1 h 20 · 3 h 09 » → « Temps d'écran 3 h 09, dont
Claude 1 h 20 ». Ma recommandation : oui pour tous, sauf « CPU » dans la
barre de menus, que tout le monde connaît.

### Décision 3 — coup d'œil ou tableau complet (plus tard)

L'évaluation perception-first : ~100 chiffres et 23 anneaux pour un coup
d'œil de 3 s ; les grands anneaux (Énergie, Capteurs) pèsent plus que le
verdict et que l'anneau du disque qui menace. Proposition : les lignes qui
ne décident rien (Charge, Allumé depuis, Moteur neuronal 0,0 W, puissance
détaillée) passent dans le dépliant de leur carte. À rendre en variantes
avant de lui poser la question.

## Journal

### J2a — ce que VoiceOver taisait, compacter le moins possible (07:21 → 07:45 UTC)

Fait :
- **Le chiffre de tête de chaque carte n'était jamais dit.** `HistoryToggle`
  posait un libellé (« historique du processeur ») sans valeur : le libellé
  d'un bouton remplace son contenu, donc « 40 % », « 18,9 Go sur 32 Go »,
  « Processeur 75 °C », la session (« depuis 2 h 48, 6,6 Go »), le temps
  d'écran, l'export et les incidents étaient muets. `HistoryToggle(value:)`
  les rend ; les titres de carte deviennent des titres (rotor « Titres »).
- Disques : « 86, Ssd 2, … » → « Ssd 2, disque externe : occupé à 86 %,
  279 Go libres, plein vers jeudi ». Capteurs : fréquence ET plafond dits,
  paires de températures dites en entier (« 75 point 73 » avant).
- Verdict : le niveau (« Alerte », « Attention ») n'était porté que par la
  couleur et le symbole ; il est dit, et un verdict qui change panneau
  ouvert s'annonce.
- Graphiques : la dernière heure du processeur a un libellé et un
  graphique sonore (Audio Graphs, les valeurs mêmes des barres) ; le débit
  dit ses pics, déjà écrits sous le graphique.
- **Historique ouvert : on ne compacte que ce qu'il faut, de bas en haut**
  (`PanelFit.shrink`, `ViewThatFits` par carte). Avant, toutes les autres
  cartes de la colonne passaient en compactes : historique des volumes
  ouvert, Mémoire perdait sa légende et ses apps et Montage son temps
  d'écran, quand compacter Capteurs seule suffisait ; historique du
  processeur ouvert, Réseau perdait sa journée, sa connexion, son forfait
  et ses apps, quand Énergie seule suffisait. Rendus `--ouvert volumes` et
  `--ouvert processeur` avant/après regardés : 1 220 → 1 240 pt et
  1 253 pt, sous les 1 274 utiles. Trois tests (`PanelFitTests`).
- `outils/relecture-ax.swift` : prêt, essayé panneau fermé (il lit l'icône
  de la barre : « Pulse — alerte : Ssd 2 plein vers jeudi · mémoire 63 % ·
  … »), n'ouvre rien, ne demande rien.

Mesures : `./verifie.sh --rapide` TOUT PASSE, 324 tests, 16 rendus
identiques à leur référence (ces corrections ne changent pas un pixel
replié). Fusionné (f26fa81), `./verifie.sh` complet : budget fermé 0,39 %.

### J2b — couleur jamais seule, VoiceOver dans tous les recoins (07:45 → 07:55 UTC)

D'après deux relectures du code (accessibilité, écriture) et une évaluation
« perception-first » des rendus, faites en parallèle :
- **Seize conteneurs en `.ignore` sortaient en AXUnknown** (le piège du
  README) : résumés parlés des dépliants, historique, forfait, exports,
  accessoires, extras → `.combine`, libellés gardés. Restent deux, dans des
  fichiers de chantiers encore ouverts : `MenuBarSettingsPage.swift:127`
  (09) et `FanSettingsPage.swift:339` (14).
- **Couleur seule** : la pression mémoire et la santé de la batterie ne
  disaient leur état que par l'orange de l'anneau ; l'anneau l'écrit
  (« PRESSION ÉLEVÉE », « SANTÉ À RÉVISER ») et VoiceOver le dit
  (`RingCenter(note:)`). HIG Color, « Inclusive color ».
- **L'orange des barres du forfait iPhone** se lisait comme une alerte à
  chaque coup d'œil : l'iPhone passe en violet (`Palette.tertiary`, mesuré),
  ici et dans le dépliant des 7 jours ; l'orange ne veut plus dire
  qu'« attention ». HIG Color, « Avoid using the same color to mean
  different things ».
- **Légende trompeuse** du processeur : des pastilles bleue et grise
  « utilisateur · système » sous des barres toutes bleues qui montrent le
  TOTAL. Pastilles retirées (et les deux couleurs, qui ne coloraient
  qu'elles, des Réglages).
- **Chevron des lignes dépliables** en `.tertiary` : ~1,9:1 en clair, seul
  signe qu'une ligne s'ouvre → `.secondary` (3:1 et plus). HIG
  Accessibility, « Strive to meet color contrast minimum standards ».
- Ordre de lecture « valeur, nom » → « nom, valeur » (anneaux, débits) ;
  capitales en `.textCase` (« APPS » s'épelait) ; intitulés de section en
  titres ; « 1 · 5 · 15 », « ~38 ms » dits en mots ; jours des exports dits ;
  niveau du verdict dit aussi dans le tableau de bord, et annoncé quand
  seul le niveau change.
- Texte sous 10 pt : `minimumScaleFactor(0.8)` sur du `.caption2` (météo,
  8 pt) retiré ; 0,84 dans les anneaux Capteurs (10,1 pt). Règle dure n° 5.
- Réglages : le glisser-déposer des cartes a ses actions (« Monter »,
  « Descendre », « Colonne de gauche / de droite ») pour le clavier et
  VoiceOver. HIG Accessibility, « Offer alternatives to gestures ».
- Écriture objective : « chacun garde leur contraste » (accord), « 1254 pt »
  → « 1 254 points », « Hors de de 9 h » (doublon) dans les Règles.

Rendus avant/après regardés (scratchpad `16-audit-ux/avant`, `apres2`,
`ajuste-apres`). **Références refaites, changement voulu** : les 16 images
de `Tests/References` (chevrons plus lisibles partout ; processeur sans
pastilles ; forfait violet ; « PRESSION ÉLEVÉE » et « SANTÉ À RÉVISER » sur
le relevé figé, qui a une pression élevée et une batterie à réviser).
`./verifie.sh` complet : TOUT PASSE, contraste au plus bas 3,18:1, budget
fermé 0,39 % d'un cœur, panneau ouvert 5,45 %.

### J3 — le réglage des bits, la variante du rangement (07:55 → 08:02 UTC)

- **« Débit : en bits » ne changeait rien à l'écran** (relevé par la
  relecture d'écriture) : la carte Réseau du chantier 07 écrivait ses débits
  en octets quoi qu'il arrive. Elle suit désormais le réglage
  (`Fmt.rate`) ; en octets, rendu identique au pixel près.
- Variante B du rangement, pour la décision 1 : `PanelFit.arrangeBalanced`,
  rendue seulement avec `--equilibre` (inactive dans l'app), un test.
  Relevé figé : sept cartes 932 × 1 240 → 932 × 997 pt ; avec Médias
  932 × 1 240 → 932 × 1 016 pt.
- `./verifie.sh` complet : TOUT PASSE, 329 tests, 16 rendus identiques.

## Relecture VoiceOver à l'API, avec Isma

Hors écran, l'arbre d'accessibilité reste vide : il faut le panneau
réellement ouvert. Le script est prêt et essayé panneau fermé (il lit
l'icône de la barre).

Quand : au prochain retour d'Isma devant le Mac, avec les autres regards
sur le panneau (ligne « Animations et thèmes » de `a-faire-isma.md`), une
minute, Premiere peut rester ouvert.
1. La coordination lance, dans le dépôt principal :
   `swift outils/relecture-ax.swift --attendre 90 --fichier /tmp/relecture-ax.txt`
2. Isma ouvre le panneau (⌃⌥M ou clic sur l'icône) dans les 90 s et ne
   touche plus à rien 2 s. Le script lit, n'ouvre rien, ne clique sur rien.
3. Facultatif : ouvrir les Réglages (⌘, panneau ouvert) et relancer le
   script sans `--attendre` : il lit aussi la fenêtre Réglages.
Ce qu'on y lit : chaque élément dans l'ordre de VoiceOver, les défauts
graves (AXUnknown, contrôle sans nom, contrôle hors clavier), le nombre de
titres. À vérifier en particulier : les titres de carte (boutons marqués
titres) restent des boutons, les graphiques sortent en images nommées, le
bandeau du verdict dit « Alerte » avant sa phrase.

### J4 — le verdict n'est plus coupé (08:02 → 08:08 UTC)

- Phrase, preuve et conseil du bandeau : deux lignes au plus au lieu
  d'une ligne coupée. Sur une colonne, « La mémoire commence à man… »,
  « pression élevée · sw… » et « Déplacer 41 Go vers Extreme Pro (719 Go
  l… » se lisent en entier ; sur deux colonnes, rien ne bouge (tout tenait
  déjà sur une ligne), sauf une preuve trop longue, qui passe à la ligne
  au lieu de perdre « et aussi ». Rendu `--conseils` avant/après regardé
  (scratchpad `16-audit-ux/avant/conseils.png`, `apres4/conseils.png`).

### J5 — derniers détails mesurables (08:08 → 08:16 UTC)

- Boutons de plage des historiques (1 h, 24 h, 7 j…) : 18 → 20 pt au
  moins dans les deux sens, le minimum des contrôles sur Mac
  (`accessibility.md › Mobility`).
- Réglages, barre latérale : le mot « masquée » n'est plus atténué à 60 %
  avec la ligne (il tombait sous les 4,5:1 du texte) ; seul le nom l'est.
- Forfait : « épuisé vers le 22 oct. à ce rythme » ne se coupe plus en
  « à / ce rythme » (espaces insécables) ; le graphique par jour dit à
  VoiceOver chaque jour où l'iPhone a servi, avec son total (la ligne
  « par jour » de `--probe`).
- Références refaites, changement voulu : `carte-reseau` et `panneau`,
  sombre et clair (la ligne du forfait passe à la ligne avant « épuisé »).

## Bilan à 08:20 UTC

Fusionnés dans `main`, chacun après `./verifie.sh` complet puis la
vérification sous verrou de `fusionne.sh` : J2a (f26fa81), J2b (4367b0c),
J3 (ea4356a), J4 (59bc9f2), J5 (8b184e6), puis J6 (c716565) et J7
(b9d9a20), écrits plus bas. 350 tests à J7, contraste au plus bas
3,18:1, budget fermé 0,38 à 0,53 % d'un cœur selon la charge de la
machine (plafond 1 %), panneau ouvert ~5,5 %. Le panneau tient : 1 253 pt
replié, 1 240 à 1 253 pt avec un historique ouvert, pour 1 274 utiles.

Bloqué, il faut Isma :
- La relecture VoiceOver à l'API du panneau réellement ouvert (1 min,
  procédure ci-dessus).
- Décision 1, rangement A ou B (image `rangement-A-contre-B.png`).

Ensuite, si on continue :
- Décisions 2 (les mots) et 3 (coup d'œil) ; les rendre en variantes.
- 09 : annoncer l'alerte de l'icône panneau fermé, le dernier `.ignore` ;
  14 : le sien. (La légende des historiques à plusieurs séries est faite,
  J7.)
- Le bouton du conseil ouvre une autre app mais porte le chevron des
  dépliants : `arrow.up.forward` pour tout ce qui sort du panneau.
- Le bandeau à la largeur réelle quand une colonne réglée devient deux.

### J6 — une seule lecture, le clavier, les 7 jours (08:20 → 08:30 UTC)

- **Consommation** : la carte Énergie montre la lecture du SMC de la carte
  Capteurs quand celle-ci mesure panneau ouvert — deux lectures à des
  instants différents affichaient 71 W et 75 W côte à côte. Rendu : 75 W
  et 75 W. Capteurs masquée : Énergie garde sa propre lecture (même
  capteur). Relevé figé inchangé (capteurs figés à l'arrêt).
- **Panneau détaché** : devient actif au clic quand l'Accès complet au
  clavier est allumé (relu à chaque ouverture) ; sinon, comme avant,
  Premiere garde le clavier.
- **7 derniers jours** : VoiceOver lisait « L, M, M, J, V, S, D » ; chaque
  jour est dit, réseau par réseau, reçu et envoyé (les chiffres de la
  section RÉSEAU de `--probe`).

### J7 — une légende pour les historiques à plusieurs séries (08:30 → 08:45 UTC)

- `HistoryChart` à deux séries ou plus (débit, températures) : une légende
  sous le graphique (côte à côte, ou l'une sous l'autre si elles ne
  tiennent pas), et la pastille de la série dont parlent « moy. · pointe ».
  Rien ne disait quelle couleur était quoi (`charts.md › Descriptive
  content`).
- Débit : l'envoi en bleu et la réception en gris, comme la carte Réseau
  juste au-dessus — l'historique les peignait à l'inverse. Même ordre dans
  le tableau de bord et la galerie `--historique`.
- Rendu `--historique` avant/après regardé (scratchpad `16-audit-ux/avant`,
  `apres7`).
