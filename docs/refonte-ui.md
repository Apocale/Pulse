# SPÉCIFICATION FINALE — refonte du popover de Pulse

Base : proposition TACHE (« un verdict, puis ses preuves »). Y sont greffés, en tranchant : le barème figé et testable d'EDITION, sa ligne de relevé à sparklines et son swap sur axe propre, la règle « aucune jauge sans dénominateur » et la traçabilité `--probe` d'APPLE, la ligne de preuve qui n'énonce qu'un fait mesuré de PRO. Sont rejetés : la bande d'incidents de 14 cellules, l'affordance au survol, l'inspecteur unique en pied, le sélecteur segmenté.

---

## 1. LE PRINCIPE

Le panneau cesse d'être un tableau de bord et devient une **phrase, puis la liste des mesures qui la produisent**. Une seule chose est grosse à l'écran — le verdict —, tout le reste est une liste de lignes strictement identiques : un nom à gauche, une marque au milieu, une valeur à droite, à la même abscisse du haut en bas du panneau.

La hiérarchie ne se fait plus par des boîtes, des séparateurs ni du verre, mais par l'échelle typographique et par le blanc : le panneau passe de neuf blocs de poids égal à six blocs dont un seul accroche l'œil.

Le verdict est un jugement rendu par l'application, donc il est **réfutable par construction** : la deuxième ligne affiche toujours le chiffre brut qui l'a produit, la règle retenue s'imprime dans `--probe`, et l'absence de mesure ne se lit jamais comme un feu vert.

---

## 2. LA STRUCTURE

### Constantes de mise en page

- Largeur du panneau **360 pt**, marge **14 pt**, largeur de contenu **332 pt**.
- Fond **opaque**, `PopoverBackground` (`windowBackgroundColor`) inchangé.
- Espacement **entre blocs : 14 pt**. Dans un bloc : 3 à 4 pt.
- **Aucun séparateur, aucun en-tête de section.** Le blanc groupe.
- Quatre abscisses, valables pour **toutes** les lignes de donnée du panneau :

| colonne | x (dans les 332 pt) | largeur | contenu |
|---|---|---|---|
| A — triangle | 0 | 12 | triangle de divulgation, ou vide |
| B — nom | 14 | 88 | libellé, `lineLimit(1)`, `.tail` |
| C — marque | 110 | 118 | sparkline **ou** qualificatif, jamais les deux |
| D — valeur | 236 | 96 | cadrée à droite, chiffres à chasse fixe |

12 + 2 + 88 + 8 + 118 + 8 + 96 = 332. Une ligne de donnée fait **18 pt** de haut (`.body` a 16 pt d'interligne sur macOS, la sparkline en fait 16), 4 pt entre lignes.

**Deux formes de ligne, une seule grammaire.**
- *Forme mesure* — nom en `.body` **secondaire** (c'est une grandeur, pas un objet), colonne C = sparkline, colonne D = valeur.
- *Forme objet* — nom en `.body` **primaire** (c'est une chose : une application, un volume, une période), colonne C = qualificatif en `.caption` secondaire ou vide, colonne D = valeur.

Quand la colonne B ne suffit pas, le nom déborde sur la colonne C (B+C = 214 pt) et la colonne C reste vide. La colonne D ne bouge jamais.

---

### BLOC 0 — LE VERDICT · ~39 pt (56 pt au pire)

Pas de carte, **pas de verre**, pas de fond. Posé directement sur le fond opaque.

```
▌  ⬢   La mémoire est saturée
        pression critique · swap 5,9 Gio · Premiere 21,4 Gio
        et aussi · 3 plantages en 24 h · disque à 92 %
```

- **Filet vertical** de 3 pt de large, sur toute la hauteur du bloc, à x = 0, coins arrondis 1,5 pt. Tracé **uniquement** quand le verdict est de niveau avertissement ou alerte. Absent au repos : l'état sain est le plus silencieux de l'écran.
- **Symbole SF** à x = 11, taille `.title2`, teinte du verdict, aligné sur la première ligne de texte.
- **Ligne 1 — la phrase.** `.title2.weight(.semibold)`, `.primary`, x = 41, largeur disponible 291 pt. **30 caractères maximum**, une seule ligne, jamais tronquée à l'affichage : le catalogue ci-dessous le garantit, et tout nom variable est coupé avant insertion (volume à 14 caractères, application à 12). macOS emploie Bold comme graisse emphatique de Title 2 ; on prend semibold, un cran en dessous, la phrase étant déjà le seul grand élément.
- **Ligne 2 — la preuve.** `.callout` `.secondary`, chiffres à chasse fixe, **une seule ligne**, faits séparés par ` · `. Elle n'énonce que des grandeurs mesurées, jamais une déduction. C'est ce qui rend le verdict contestable.
- **Ligne 3 — « et aussi ».** `.callout` `.secondary`, présente seulement si au moins une autre règle est active. Forme : `et aussi · <libellé court> · <libellé court>`, **deux au maximum**, dans l'ordre du barème. C'est la réponse au défaut nommé par six juges sur douze : un panneau qui ne montrerait qu'un problème sur deux serait pire qu'un tableau de bord.

Interlignes 2 pt. Hauteur : 22 + 2 + 15 = **39 pt** ; 56 pt avec la ligne 3.

Le bloc n'est **pas dépliable**. C'est une conclusion, pas un dossier.

#### Le barème — ordre figé, première règle active gagne

Toutes les conditions se construisent sur des valeurs déjà publiées par `Sampler`. **Aucun champ persisté n'est ajouté** : la règle dure n°2 n'est jamais mise en jeu.

| # | condition | niveau | symbole | phrase (≤30 car.) | preuve | libellé court |
|---|---|---|---|---|---|---|
| 1 | `memory.pressureLevel == 4` | alert | `memorychip.fill` | La mémoire est saturée | pression critique · swap 5,9 Gio · Premiere 21,4 Gio | mémoire saturée |
| 2 | un incident `.jetsam` < 24 h | alert | `exclamationmark.triangle.fill` | macOS a tué un processus | faute de mémoire · il y a 40 min | processus tué |
| 3 | un volume ≥ 95 % (`usedFraction`) | alert | `externaldrive.fill.badge.exclamationmark` | Rushes est plein à 96 % | 38 Go libres · plein dans ~4 jours *(ou : tendance en cours de calcul)* | disque à 96 % |
| 4 | `daysUntilFull < 7` | alert | `externaldrive.fill.badge.exclamationmark` | Rushes plein dans ~5 jours | 418 Go libres · 84 Go par jour sur 72 h | disque presque plein |
| 5 | un incident `.crash` < 24 h | alert | `exclamationmark.triangle.fill` | Premiere a planté 3 fois | dernier il y a 11 h · 3 en 24 h | 3 plantages en 24 h |
| 6 | `pressureLevel == 2` | warning | `memorychip` | La mémoire commence à manquer *(29 car.)* | pression élevée · swap 5,9 Gio | pression élevée |
| 7 | `swapUsed > 0` et hausse ≥ 1 Gio sur l'heure | warning | `memorychip` | Le swap monte | 5,9 Gio sur disque · +1,4 Gio en une heure | swap en hausse |
| 8 | un volume ≥ 90 % | warning | `externaldrive` | Rushes est plein à 92 % | 79 Go libres · plein dans ~21 jours | disque à 92 % |
| 9 | `daysUntilFull < 30` | warning | `externaldrive` | Rushes plein dans ~21 jours | 418 Go libres · 20 Go par jour sur 72 h | disque bientôt plein |
| 10 | pas d'export **et** `cpu.total > 0,90` **et** le plus gros groupe attribué est `AppKind.other` au-dessus de 200 % | warning | `cpu` | Vivaldi occupe le processeur | 412 % d'un cœur · processeur à 94 % | processeur occupé |
| 11 | `sampler.export != nil` | data | `film` | Export en cours | Media Encoder · depuis 4 min · processeur à 94 % | — |
| 12 | sinon | muted | `checkmark.circle` | La machine suit | 20,9 Gio sur 32 · aucun swap · Rushes 418 Go libres | — |

**Trois arbitrages, contre les propositions d'origine.**

1. **L'export qualifie, il ne concourt pas.** Quand `sampler.export != nil` : la règle 10 est **supprimée** (le processeur au plafond pendant un export est l'état normal et souhaité), et la clause ` · export en cours` est **ajoutée à la ligne de preuve** de n'importe quel verdict. L'export n'apparaît donc jamais dans « et aussi » : il est déjà partout. Un export est un mode de la journée, pas un rang de gravité.
2. **L'occupation entre au barème, pas seulement la prévision** (règles 3 et 8). `HistoryStore.forecast` rend `nil` sous 6 h d'observation calme, au-delà de `maxStaleness`, et dès que le volume se vide : c'est le cas courant après un redémarrage ou un remontage du SSD externe. Sans les règles 3 et 8, un disque à 96 % afficherait « La machine suit ». C'était le trou le plus coûteux de toutes les propositions.
3. **La fenêtre des plantages est 24 h glissantes, pas la journée civile.** Le README prend pour exemple « planté trois fois hier soir ». À 9 h du matin, une frontière de minuit efface exactement ce qui explique la matinée. Corollaire technique : `IncidentLog.recent` est rescanné **de force à l'ouverture du popover** (`setPopoverOpen(true)`, comme `refreshApps`), sinon le verdict arrive jusqu'à 120 s en retard sur le plantage.

**Seuils explicitement provisoires**, à signaler comme tels dans `--probe` : règle 7 (1 Gio/h), règle 9 (30 jours), règle 10 (90 % machine et 200 % d'un cœur). Aucun ne repose sur une mesure comparable aux 68 relevés du détecteur d'export.

**Formulations d'absence.** Quand `forecast` est `nil`, la preuve écrit `tendance en cours de calcul`, `tendance : relevés trop anciens` (`lastSampleAge > maxStaleness`) ou `tendance : premier relevé` (`lastSampleAge == nil`). La règle 12 n'écrit **jamais** « disques dégagés » : elle nomme l'espace libre du volume le plus contraint et, si sa tendance manque, elle le dit. Une absence de mesure ne doit pas se lire comme un feu vert.

**Durées.** Toujours `Fmt.days` tel quel : « moins d'un jour », « ~N jours » (< 60), « ~N mois ». Ne jamais écrire « ~3 semaines », que `Fmt.days` ne sait pas produire.

#### Hystérésis — à écrire avant tout le reste

Sans elle, la phrase change à la cadence de 1,5 s dès qu'une valeur oscille autour d'un seuil, et le panneau devient illisible.

- **Où.** Un type `VerdictEngine`, possédé par `Sampler`, muté **uniquement depuis la file d'échantillonnage**, à l'intérieur de `tick()`, exactement comme `exportDetector.observe(...)`. Interdiction formelle de le toucher depuis le main thread. Il publie un `Verdict` immuable dans `@Published private(set) var verdict: Verdict`.
- **Pourquoi pas dans la vue.** La cadence retombe à 5 s popover fermé, et l'état « la condition tient depuis N secondes » doit survivre à la fermeture.
- **Entrée.** Une règle devient active quand sa condition tient **sans interruption depuis ≥ 3 s**. En secondes et non en nombre de relevés : la cadence varie de 1,5 s à 5 s.
- **Sortie.** Une règle active est relâchée quand sa condition est fausse **sans interruption depuis ≥ 10 s**.
- **Exception.** La règle 11 hérite de l'hystérésis d'`ExportDetector` (deux relevés au-dessus du seuil, 30 s de grâce) et n'est pas ré-hystérisée.
- **État.** Deux `Date?` par règle, en mémoire vive. Rien de persisté.

#### `--probe`

Nouvelle section `VERDICT`, imprimée après `EXPORT` :

```
VERDICT
  règle retenue   5 — plantage Adobe dans les 24 h
  phrase          Premiere a planté 3 fois
  preuve          dernier il y a 11 h · 3 en 24 h
  aussi actives   8 (volume à 92 %)
  sans hystérésis : état instantané, l'interface exige 3 s de maintien
  règle 11 (export) indécidable sur un relevé unique — Media Encoder à 4,2 %, seuil 60 %
  seuils provisoires : 7 (1 Gio/h), 9 (30 j), 10 (90 % / 200 %)
```

`Probe.run()` instancie déjà un `HistoryStore` : les règles 3, 4, 8, 9 et 12 y sont donc décidables. Seule la 11 ne l'est pas, et elle le dit. Sans cette section, le seul élément qui compte serait le seul indébogable — ce qui contredirait la règle de débogage du dépôt.

---

### BLOC 1 — LE RELEVÉ · ~100 pt

Quatre lignes en *forme mesure*, une seule grammaire, la même que tout le reste du panneau.

```
▸ mémoire      ╱‾╲__╱‾‾            20,9 Gio
▸ swap         __╱‾‾‾‾‾             5,9 Gio
▸ processeur   ‾╲_╱╲_╱‾               30 %
▸ gpu          _╱‾╲__╱                 27 %
   60 dernières minutes
```

- **Sparkline** : 118 × 16 pt, `LineSeries`, trait 1,25 pt, `lineJoin: .round`, **sans remplissage, sans axe, sans grille, sans cadre**, posée sur un filet de base de 1 pt en `separatorColor` qui matérialise le zéro. Ce filet est ce qui distingue une série plate d'une absence de données.
- **Échelles.** Fixe 0–1 pour mémoire, processeur et gpu : le plein a un sens dans les trois cas, et c'est ce qui les rend comparables (`charts.md` : plage fixe quand les bornes sont signifiantes). Le **swap n'a pas de plafond** — `xsu_total` est la taille des fichiers alloués, que macOS agrandit à la demande — donc il a **son axe propre**, normalisé sur `max(maximum de la fenêtre, 2 Gio)`. Le plancher de 2 Gio évite qu'un filet de 40 Mio se dessine comme une montagne. Le bricolage actuel `swap / memory.total` disparaît.
- **Séries vides.** Si `series.count <= 1`, le bloc entier affiche **un seul** texte `.caption` `.secondary` « collecte en cours » à la place des quatre marques — pas quatre courbes vides.
- **GPU nul.** Quand `sampler.gpu == nil`, la valeur est `—` et **aucune sparkline n'est tracée** ; la colonne C porte « non disponible » en `.caption` `.secondary`. `SeriesPoint` stocke `gpu ?? 0` : une courbe plate à zéro, côte à côte avec trois courbes valides, serait un mensonge crédible.
- **Légende** : une seule pour les quatre courbes, `.caption` `.secondary`, alignée à gauche sur x = 110 (bord d'attaque de la colonne C), 3 pt sous la dernière ligne. Texte : « 60 dernières minutes ».
- **Valeurs** : `Fmt.memory` (base 1024) pour mémoire et swap, `Fmt.percent` pour processeur et gpu. Quand `swapUsed == 0`, la valeur est « aucun » et aucune courbe n'est tracée.

Hauteur : 4 × 18 + 3 × 4 + 3 + 13 = **100 pt**.

**Dépliants** : `memoire` → `MemoirePanel` · `graphe` → `SwapPanel` · `coeurs` → `CoeursPanel` · `gpu` → `GpuPanel`.

**Disparaît d'ici** : les trois tuiles de verre et leurs jauges, l'en-tête « mémoire et swap · 60 dernières minutes », la légende ram/swap, la courbe de 62 pt, les deux notes de pied, l'en-tête « cœurs · 8 P · 4 E » et les douze barres verticales.

---

### BLOC 2 — LE TRAVAIL · ~18 pt (40 pt avec export)

Deux lignes au maximum, *forme objet*, affichées **par exception**.

```
▸ Premiere Pro   depuis 3 h 36              21,4 Gio
▸ Media Encoder  export                        4 min
```

- Ligne session, présente si `sampler.session != nil`. Nom en `.body` `.primary`. Qualificatif : `depuis <Fmt.duration(session.duration)>`. Valeur : **`sessionProcess.footprint`**, jamais `session.peakMemoryBytes` — ce dernier est la mémoire de la **machine** au pic, pas celle de Premiere ; une implémentation naïve afficherait un chiffre faux sous le nom de l'application.
- **Pas de CPU d'application sur cette ligne.** Le README l'établit par la mesure : le maximum de Premiere au repos (286 %) dépasse son maximum pendant un export (282 %). Un chiffre qui ne sépare rien n'a pas sa place dans la vue par défaut. Il reste dans `SessionPanel` et dans `--probe`.
- Ligne export, présente si `sampler.export != nil`. Qualificatif « export », valeur `Fmt.duration(export.duration)`.
- **Plus de pastille verte.** La présence de la ligne *est* la session. La pastille était un `systemGreen` brut, hors Palette, sans ratio mesuré.

**Dépliants** : `session` → `SessionPanel` · `export` → `ExportPanel`. Cette ligne est cliquable : `ExportPanel` est la pièce la mieux justifiée du dépôt (seuil à 60 % entre 31 % et 102-231 %), elle ne doit pas devenir orpheline.

**Disparaît d'ici** : la carte de verre de session et ses quatre colonnes durée / mémoire / processeur / plantages ; la carte de verre d'export. Le compteur de plantages du jour n'a plus à s'afficher en permanence à zéro : il est la règle 5 du verdict.

---

### BLOC 3 — LES DISQUES · ~65 pt (deux volumes)

```
▸ Rushes ⏏                             418 Go libres
   ████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░
   581 Go utilisés · plein dans ~21 jours · dont 42 Go récupérables
  Macintosh HD                          214 Go libres
```

**Tri**, indépendant du point de montage (qui n'est pas stable : le SSD externe remonte tantôt en `Ssd`, tantôt en `Ssd 2`) :

```
sévérité(v) = 0 si usedFraction ≥ 0,95 ou (days != nil et days < 7)
              1 si usedFraction ≥ 0,90 ou (days != nil et days < 30)
              2 sinon
tri par (sévérité croissante, days ?? +∞ croissant, usedFraction décroissant)
```

Ce tri place un volume à 96 % **sans prévision** en tête, ce qu'un tri sur `daysUntilFull` seul ne fait pas.

- **Le premier volume seul** reçoit le traitement complet : ligne + barre + légende.
  - Ligne, *forme objet* : nom `.body` `.primary`, suivi de `externaldrive` en `.caption` `.secondary` si `!isInternal` ; valeur « 418 Go libres » en `.body` chasse fixe `.primary`, **jamais colorée**.
  - Barre : x = 14 → 332 (318 pt), 6 pt de haut. 3 pt au-dessus et au-dessous.
  - Légende `.caption` `.secondary` : `« <N> Go utilisés · <prévision> »`, plus `« · dont <N> Go récupérables »` si `purgeable > 10 Go`. **« utilisés » est conservé** : `used` se mesure sur `availableStrict` et « libres » sur `available` ; sans lui, « dont N récupérables » ne se rattache plus à rien et la ligne ne s'additionne pas sous les yeux (944 utilisés, 73 libres, disque de 995 — c'est exactement ce que corrige le commit a8ac1fd).
- **Les autres volumes** : une ligne nue, sans barre, sans légende. Pas de barre, donc pas de problème de réconciliation.
- Unités : `Fmt.bytes`, base 1000. Règle dure n°3.

Hauteur : 18 + 3 + 6 + 3 + 13 = 43 pt pour le premier, + 4 + 18 par volume suivant.

**Dépliant** : `volumes` → `VolumesPanel`, sur la ligne du premier volume.

**Disparaît d'ici** : la barre pleine largeur de chaque volume (il n'en reste qu'une), et la légende sur deux lignes des volumes secondaires.

---

### BLOC 4 — LA RÉTROSPECTIVE · ~18 pt (40 pt avec incidents)

```
▸ aujourd'hui      Premiere 3 h 36               6 h 12
▸ incidents · 14 jours                                3
```

- Ligne « aujourd'hui », toujours présente. Qualificatif : l'application de tête et sa durée. Valeur : `Fmt.duration(focusTotal)`.
- Ligne « incidents · 14 jours », **affichée seulement si `!sampler.incidents.isEmpty`**. Le nom déborde sur la colonne C ; valeur = le compte. Affichage par exception : voir la ligne, c'est déjà savoir que ça a cassé.

**Dépliants** : `apps` → `AppsPanel` · `incidents` → `IncidentsPanel`.

**Ce qui est tranché ici.** La bande de 14 cellules proposée par EDITION est **rejetée** : elle constituerait une troisième grammaire graphique, elle ne distingue pas un plantage de deux à 10 pt de haut, et elle donne le jour, pas l'heure. Or « planté trois fois hier soir » est exactement ce que le README revendique. La question « quand » est donc traitée à l'endroit où elle décide quelque chose — la ligne de preuve du verdict, règle 5, « dernier il y a 11 h » — et le détail daté reste dans `IncidentsPanel`, qui le dessine déjà sur 14 jours groupés par jour.

**Disparaît d'ici** : l'en-tête « temps par application · aujourd'hui » et ses cinq lignes à barres ; l'en-tête « incidents · 14 derniers jours » et ses lignes par nature à barres.

---

### BLOC 5 — LE PIED · ~20 pt

Rien à gauche. À droite, le bouton **Quitter**, `.buttonStyle(.glass)` + `.tint(.clear)` sous macOS 26, `Button` nu en repli, `controlSize(.small)`, `⌘Q`. **C'est le seul verre du panneau.**

« mise à jour toutes les 1,5 s » disparaît. La preuve de vie est désormais visible : les sparklines avancent et les chiffres transitionnent en `.numericText()` à chaque relevé. Une constante qui ne change jamais ne fonde aucune décision.

---

### La divulgation

- **Triangle visible**, `.caption2.weight(.semibold)` `.tertiary`, `chevron.right`, pivoté de 90° à l'ouverture avec `Motion.value`. Pointant vers l'intérieur fermé, vers le bas ouvert — la formulation exacte du HIG, celle du Finder, qui en aligne des dizaines dans une même vue.
- **Au bord d'attaque, colonne A**, sur toutes les lignes dépliables. Les lignes non dépliables (volumes secondaires) laissent la colonne A vide : les noms restent alignés.
- **Rejet explicite de l'affordance au survol** : invisible sur une capture, invisible au clavier avant que le focus soit posé, invisible pour qui n'effleure pas la ligne au trackpad.
- **Cible de clic** : la ligne entière, 332 × 18 pt, via `.contentShape(Rectangle())`. Le paramètre `row:` d'`Explainable`, qui ajoutait 5 pt de padding vertical pour rattraper des en-têtes de 13 pt, n'a plus d'objet et disparaît.
- **Un seul dépliant ouvert à la fois**, `@State private var open: String?` inchangé. Le panneau s'insère juste sous la ligne qui l'a révélé, sur 332 pt, `DetailPanel` gardant ses 10 pt de marge intérieure — donc **312 pt utiles**, la largeur sur laquelle tous les panneaux sont dessinés. Rien à redessiner.
- **Plafond : 200 pt par dépliant.** Vérifié au `--show` bloc par bloc.

**Neuf lignes, neuf clés existantes, neuf panneaux, aucun orphelin, aucune entrée à ajouter dans `Legendes.all` ni `Explanations.all` :**

| ligne | clé | panneau |
|---|---|---|
| mémoire | `memoire` | `MemoirePanel` |
| swap | `graphe` | `SwapPanel` |
| processeur | `coeurs` | `CoeursPanel` |
| gpu | `gpu` | `GpuPanel` |
| Premiere Pro | `session` | `SessionPanel` |
| Media Encoder | `export` | `ExportPanel` |
| premier volume | `volumes` | `VolumesPanel` |
| aujourd'hui | `apps` | `AppsPanel` |
| incidents | `incidents` | `IncidentsPanel` |

La ligne « processeur » porte la clé `coeurs` et non `processeur` : sa légende (« Les quatre premières barres sont les cœurs E… ») est celle de ce qui s'ouvre. `ProcesseurPanel` et la clé `processeur` sortent du routage — la courbe processeur des 60 minutes qu'ils dessinaient est désormais dans la vue par défaut, sur la ligne elle-même.

---

## 3. L'ÉCHELLE TYPOGRAPHIQUE

Cinq styles, tous système, aucune taille littérale, plancher 10 pt tenu par construction.

| style | macOS | graisse | couleur | rôle | occurrences |
|---|---|---|---|---|---|
| `.title2` | 17 pt / 22 | **semibold** | `.primary` | la phrase du verdict | **1, jamais plus** |
| `.body` | 13 pt / 16 | regular | `.primary` | nom d'un **objet** : Premiere Pro, Media Encoder, Rushes, Macintosh HD, aujourd'hui, incidents | 4 à 7 |
| `.body` | 13 pt / 16 | regular | `.secondary` | nom d'une **mesure** : mémoire, swap, processeur, gpu | 4 |
| `.body` chasse fixe | 13 pt / 16 | regular | `.primary` | **toutes** les valeurs de la colonne D, sans exception | 8 à 11 |
| `.callout` | 12 pt / 15 | regular | `.secondary` | ligne de preuve, ligne « et aussi » | 1 à 2 |
| `.caption` | 10 pt / 13 | regular | `.secondary` | qualificatifs de colonne C, légende « 60 dernières minutes », légende de volume, « collecte en cours » | 4 à 6 |
| `.caption2` | 10 pt / 13 | semibold | `.tertiary` | le triangle de divulgation, et rien d'autre | 7 à 9 |

- **Une seule graisse non régulière dans tout le panneau**, sur le verdict. C'est ce qui fait que l'œil atterrit toujours au même endroit.
- **`.tertiary` (1,87:1) ne porte jamais de donnée.** C'est une affordance, pas une mesure.
- **Le renversement par rapport à l'existant** : aujourd'hui la chose la plus grosse est « 20,9 Gio » en `.title3`, et son libellé « mémoire » en `.caption2` gris quasi invisible — le chiffre crie sans dire ce qu'il mesure. Après refonte, plus aucun chiffre n'est plus gros qu'un autre ; la hiérarchie des mesures se fait par la position en colonne, et le seul grand texte est une conclusion.
- `.title3`, `.subheadline` et `.footnote` disparaissent du popover.
- **Tous les chiffres** : `.monospacedDigit()` + `.contentTransition(.numericText())` + `Motion.value`. Une valeur qui change ne déplace jamais celles d'à côté, et la colonne D reste comparable verticalement.
- Le verdict change au plus une fois toutes les 10 s (hystérésis) : la phrase et le symbole se croisent en **opacité seule**, avec `Motion.value`. Pas de décalage : un seul ressort dans l'application, et il suit « Réduire les animations ».
- Les sparklines ne sont pas animées : elles sont redessinées. Animer une courbe qui défile de 10 s en 10 s produirait une reptation.

---

## 4. LA GRAMMAIRE DES BARRES

**Deux grammaires graphiques, une seule barre.**

| forme | ce qu'elle dit | où |
|---|---|---|
| **la ligne** (sparkline) | une évolution dans le temps | colonne C des 4 lignes de mesure |
| **la barre** (proportion) | une part d'un total | **une seule fois** : le premier volume |

### La barre, au point près

- Composant : `Meter`, tel qu'il existe, avec `height: 6`.
- Géométrie : x = 14 → 332, soit **318 × 6 pt**. `Capsule`, alignée à gauche.
- Piste : `quaternaryLabelColor`. Remplissage : `min(1, max(0, usedFraction))`, largeur minimale visible 2 pt.
- Animation : `Motion.value` sur `fraction`. `accessibilityHidden(true)` : la valeur est déjà énoncée par la ligne.
- Dénominateur : `usedFraction = (total − availableStrict) / total`, purgeable **exclu** — c'est l'occupation réelle.

### La règle dure qui vient avec

**Aucune barre sans dénominateur.** Une barre dont le total est inventé est une barre qui ment. Conséquences, toutes appliquées :

- **Pas de barre sur une durée.** Les cinq lignes du classement d'applications avaient une barre normalisée sur le maximum du jour : un dénominateur fabriqué, qui change de sens d'un jour à l'autre. Supprimée.
- **Pas de barre sur un compte.** Les lignes d'incidents étaient normalisées sur la nature la plus fréquente : « 3 plantages » se lisait relativement à « 12 CPU saturé », un rapport dont on ne fait rien. Supprimée.
- **Pas de barre sur le swap.** `swapTotal` n'est pas un plafond, le README le documente. Le swap a une **ligne**, pas une barre, et sur son axe propre.
- **Pas de barre sur le CPU d'une application.** `ProcessGroup.cpu` est un pourcentage d'**un** cœur, jusqu'à 1200 % sur cette machine : toute normalisation serait arbitraire.
- **Pas de jauge de tuile.** Une jauge de 4 pt sous un nombre écrit en toutes lettres réencode la même chose, moins précisément. La sparkline la remplace et apporte ce que le chiffre ne dit pas : la dernière heure.

Les graphiques **à l'intérieur des dépliants** ne sont pas concernés : chacun énonce son échelle dans sa légende, et c'est déjà le cas.

---

## 5. LES COULEURS

**Rappel de la règle dure n°4 et de ce qu'elle mesure.** Les teintes de `Palette` sont mesurées à **≥ 3:1** sur les deux fonds du matériau `.popover` — c'est le seuil WCAG des **objets graphiques**. Le seuil du **texte** est 4,5:1, et `Palette.alert` (3,23:1 en clair) comme `Palette.warning` (4,18:1 en clair) ne l'atteignent pas à 12 ou 13 pt.

> **Règle** : une teinte de `Palette` ne colore **jamais du texte**. Elle ne colore qu'un objet graphique : un symbole SF, un filet, un remplissage de barre, un trait de courbe. Tout texte est `.primary` ou `.secondary`.
>
> Cela corrige deux violations existantes : `VolumeRow` peint « 73 Go libres » en `Palette.alert` sur du `.callout`, et `stat("plantages", …)` peint son chiffre en `Palette.alert` sur du `.callout`. Les deux disparaissent avec les vues qui les portent.

**Le fond du panneau reste opaque** (`PopoverBackground`), c'est la condition pour que ces ratios restent vrais. **Le verre est retiré du bandeau de verdict** : il y porterait un symbole coloré issu de `Palette`, dont les ratios sont mesurés contre le fond opaque et devraient être remesurés sur verre. Le verre ne subsiste que sur le bouton Quitter, où il est un contrôle. `GlassEffectContainer` disparaît avec les tuiles qu'il existait pour rendre cohérentes.

### Les quatre emplacements colorés, et pas un de plus

| emplacement | teinte | règle qui décide |
|---|---|---|
| **symbole du verdict** | teinte du verdict | le niveau de la règle active : `alert` (1–5), `warning` (6–10), `data` (11), `muted` (12) |
| **filet de 3 pt du verdict** | teinte du verdict | tracé **seulement** si `alert` ou `warning` |
| **trait des sparklines** | `Palette.data` par défaut ; **la teinte du verdict** sur la seule série que le verdict nomme | mémoire et swap prennent la teinte pour les règles 1, 2, 6, 7 ; processeur pour la règle 10 |
| **remplissage de la barre de volume** | `muted` < 90 % · `warning` 90–95 % · `alert` ≥ 95 % | **les mêmes seuils que les règles 3 et 8** |

Ce dernier point est la garantie de cohérence : le panneau ne peut pas afficher un verdict serein au-dessus d'une barre en alerte, parce que les deux sortent du même seuil.

**Au plus un signal coloré à l'écran à la fois**, et il vient toujours du verdict. Au repos (règle 12), la seule couleur du panneau est le gris de `muted` sur le symbole et le bleu de `data` sur les sparklines.

**La couleur ne porte jamais seule le sens** : le symbole SF dit la nature, la phrase dit la chose, le filet n'est qu'un redoublement périphérique.

**`.accentColor` n'apparaît nulle part dans les données**, et nulle part tout court : il n'y a plus de sélecteur segmenté, et le bouton Quitter porte `.tint(.clear)` précisément pour ne pas se teinter en action principale. Elle suit le réglage de l'utilisateur et tombe à 1,37:1 en accent jaune.

---

## 6. CE QUI DISPARAÎT DE L'AFFICHAGE PAR DÉFAUT

| ce qui part | où ça va |
|---|---|
| Les trois tuiles de verre (`Tile`) | **supprimé** — le composant `Tile` est supprimé de `Components.swift` |
| Les trois jauges de tuile | **supprimé** — remplacées par les sparklines, qui disent ce que le chiffre ne dit pas |
| La légende « modérée » / « normale » | **verdict** (règles 1 et 6) quand elle signifie quelque chose ; le README rappelle que « modérée » veut seulement dire qu'il reste un octet dans le swap |
| La légende « P 20 % · E 50 % » | **déplié** `coeurs` (`CoeursPanel`, qui les dessine mieux) |
| La légende « lecture ou rendu » du gpu | **déplié** `gpu` (`GpuPanel`) |
| `GlassEffectContainer` et `glassSurface` | **supprimé** — le commentaire de `GlassSurface` sur le fond opaque est reporté sur `PopoverBackground`, qui porte désormais seul la règle |
| La carte de session et ses 4 colonnes | **supprimé** — une ligne les remplace |
| La colonne « plantages » à zéro | **verdict** (règle 5), en 24 h glissantes |
| Le CPU de Premiere sur la ligne de session | **déplié** `session` + `--probe` — inutilisable comme signal, mesuré |
| La pastille verte de session | **supprimé** — `systemGreen` brut, hors Palette ; la présence de la ligne est la session |
| La carte de verre d'export | **supprimé** — une ligne la remplace, toujours cliquable vers `ExportPanel` |
| L'en-tête « mémoire et swap · 60 dernières minutes » | **supprimé** — une légende pour quatre courbes suffit |
| La légende à pastilles ram / swap | **supprimé** — chaque série a sa propre ligne et son libellé |
| La courbe de 62 pt | **ligne « mémoire »** (16 pt) + **déplié** `memoire` |
| Le hack `swapSeries` (swap ÷ RAM totale) | **supprimé** — le swap a son axe propre, normalisé sur son maximum de fenêtre, plancher 2 Gio |
| « swap N Gio écrits sur disque » | **valeur de la ligne swap** + **verdict** (règle 7) |
| « cache fichier 9,8 Gio » | **déplié** `memoire` (`MemoirePanel` le dessine déjà) |
| L'en-tête « cœurs » et « 8 P · 4 E » | **déplié** `coeurs` |
| Les douze barres verticales | **déplié** `coeurs` — on ne se pose la question qu'après avoir vu le processeur au plafond |
| `ProcesseurPanel` | **supprimé** du routage — sa courbe est désormais dans la vue par défaut, sur la ligne « processeur » |
| L'en-tête « temps par application · aujourd'hui » et son total | **ligne « aujourd'hui »** + **déplié** `apps` |
| Les cinq lignes du classement et leurs barres | **déplié** `apps` (`AppsPanel`) — barres supprimées, dénominateur inventé |
| L'en-tête « incidents · 14 derniers jours » | **ligne « incidents · 14 jours »** |
| Les lignes d'incidents par nature et leurs barres | **déplié** `incidents` (`IncidentsPanel`) |
| La barre pleine largeur des volumes secondaires | **supprimé** — une seule barre subsiste, sur le volume qui compte |
| La légende des volumes secondaires | **déplié** `volumes` (`VolumesPanel`) |
| Les quatre `Divider()` | **supprimé** — le blanc groupe |
| Les cinq `SectionLabel` du popover | **supprimé** — la colonne B tient le rôle d'en-tête (`SectionLabel` reste dans `Components.swift`, les dépliants s'en servent) |
| « mise à jour toutes les 1,5 s » | **supprimé** — la preuve de vie est le mouvement des chiffres et des courbes |
| `AppRow` (défini dans `PopoverView.swift`) | **supprimé** |

Conservés sans modification parce que les dépliants s'en servent : `Meter`, `LineSeries`, `SectionLabel`, `LegendDot`, `DisclosureChevron`, `Explainable`, `DetailPanel`, `PopoverBackground`, `Motion`, `Palette`, `Fmt`.

---

## 7. HAUTEUR TOTALE

Cas nominal : session Premiere ouverte, pas d'export, deux volumes, verdict sain sans ligne « et aussi ».

| | pt |
|---|---|
| marge haute | 14 |
| **bloc 0 — verdict** (22 + 2 + 15) | **39** |
| espacement | 14 |
| **bloc 1 — relevé** (4 × 18 + 3 × 4 + 3 + 13) | **100** |
| espacement | 14 |
| **bloc 2 — travail** (1 ligne) | **18** |
| espacement | 14 |
| **bloc 3 — disques** (43 + 4 + 18) | **65** |
| espacement | 14 |
| **bloc 4 — rétrospective** (1 ligne) | **18** |
| espacement | 14 |
| **bloc 5 — pied** (bouton `.small`) | **20** |
| marge basse | 14 |
| **total** | **358 pt** |

Variantes :

| situation | delta | total |
|---|---|---|
| aucune session de montage ouverte | −32 | **326** |
| ligne « et aussi » présente | +17 | 375 |
| export en cours | +22 | 380 |
| troisième volume monté | +22 | 380 |
| ligne incidents présente | +22 | 380 |
| **pire cas cumulé** | +83 | **441** |
| **+ le plus grand dépliant ouvert** (8 + 200) | +208 | **649** |

À comparer aux 1380 pt actuels sur un écran de 1329 pt. Le panneau fermé tient dans le champ utile d'un regard ; ouvert au pire, il occupe la moitié de l'écran.

Vérification à chaque étape : `./Pulse.app/Contents/MacOS/Pulse --show` imprime la géométrie de la fenêtre sur stderr.

---

## 8. ORDRE D'IMPLÉMENTATION

Chaque étape est testable seule et laisse l'application utilisable. La hauteur ne remonte à aucune étape.

**Étape 1 — le verdict, sans interface.**
`Sources/Pulse/Metrics/Verdict.swift` : le type `Verdict` (niveau, symbole, phrase, preuve, libellés « et aussi », identifiant de règle), `VerdictEngine` avec les douze règles, l'hystérésis 3 s / 10 s, l'export en qualificatif. Évalué dans `Sampler.tick()`, **sur la file d'échantillonnage uniquement**, publié dans `@Published private(set) var verdict`. Rescan forcé de `IncidentLog.recent` dans `setPopoverOpen(true)`. Section `VERDICT` dans `Probe.run()`.
*Testable* : `./.build/release/Pulse --probe` seul. Aucun pixel ne change. C'est le prérequis de tout le reste : sans hystérésis, la phrase clignoterait à 1,5 s et le défaut serait pire que tous ceux qu'on corrige.

**Étape 2 — le bloc verdict remplace les trois tuiles.**
La vue du verdict (filet, symbole, trois lignes) prend la place de `tileRow`. `Tile` et `GlassEffectContainer` sortent.
*Testable* : le panneau perd ~60 pt et gagne 39 ; le verdict se lit, se contredit avec `--probe`, et l'application reste entièrement fonctionnelle. À cette seule étape, le gain principal est acquis.

**Étape 3 — `MetricRow` et le relevé.**
Le composant de ligne (quatre colonnes, deux formes) et les quatre lignes mémoire / swap / processeur / gpu. Ils remplacent `memoryChart` en entier (en-tête, légende, courbe 62 pt, deux notes) et `cores` en entier. `swapSeries` est supprimé au profit de la normalisation sur maximum de fenêtre.
*Testable* : le panneau passe sous les 1329 pt et devient lisible en entier. Comparer chaque valeur de ligne à la section correspondante de `--probe`.

**Étape 4 — les lignes objet.**
Travail (session, export), disques (`VolumeRow` réécrite, tri par sévérité, une seule barre), rétrospective (aujourd'hui, incidents). `AppRow`, `sessionCard`, `exportCard`, `applications`, `incidentsSection` sortent.
*Testable* : le panneau tombe autour de 400 pt. Vérifier le cas du volume à plus de 90 % sans prévision, et le cas du volume qui se vide.

**Étape 5 — le chrome.**
Les quatre `Divider`, les `SectionLabel` du popover, les `LegendDot` du popover, le texte du pied, `glassSurface`. Passe de relecture : plus aucune teinte de `Palette` sur du texte.
*Testable* : 358 pt au `--show`. Capture en clair et en sombre par `screencapture -R` sur la géométrie imprimée.

**Étape 6 — le routage des dépliants.**
Neuf lignes, neuf clés existantes, `ProcesseurPanel` retiré du `switch`, `Explainable.row` supprimé, cible de clic sur la ligne entière. Mesurer chaque dépliant ouvert au `--show` et vérifier le plafond de 200 pt ; le plus haut est `VolumesPanel` à trois volumes.
*Testable* : ouvrir les neuf dépliants un par un, relever neuf hauteurs.

**Étape 7 — hors popover, facultative.**
`MenuBarLabel` : quand le verdict est de niveau `alert`, un point plein de 3 pt apparaît au bout de la courbe, en `.primary` à pleine opacité, la courbe restant à 0,75. **Un changement de forme, pas de couleur** : la luminance du fond de la barre de menus est inconnue (c'est le fond d'écran), donc aucun ratio de `Palette` n'y est valide. C'est la seule lecture qui ne demande pas d'ouvrir le panneau.

---

**Fichiers concernés** : `/Users/isma/Documents/Dashbaord/Sources/Pulse/UI/PopoverView.swift` (réécrit), `/Users/isma/Documents/Dashbaord/Sources/Pulse/UI/Components.swift` (`Tile` et `GlassSurface` retirés), `/Users/isma/Documents/Dashbaord/Sources/Pulse/Metrics/Verdict.swift` (créé), `/Users/isma/Documents/Dashbaord/Sources/Pulse/Metrics/Sampler.swift` (publication du verdict, rescan des incidents à l'ouverture), `/Users/isma/Documents/Dashbaord/Sources/Pulse/Metrics/Probe.swift` (section VERDICT), `/Users/isma/Documents/Dashbaord/Sources/Pulse/UI/MenuBarLabel.swift` (étape 7). `DetailPanels.swift`, `Explanations.swift`, `Palette.swift`, `Motion.swift` et `Format.swift` ne sont pas modifiés.