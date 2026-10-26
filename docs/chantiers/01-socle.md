# 01-socle — modules, mise en page, fenêtre Réglages

Départ : dimanche 11/10/2026, 06 h 22 (heure de Paris), 04:22 UTC.
Branche `chantier/01-socle`, worktree `.claude/worktrees/agent-ac9f0d387d65b1f6c`.

## Plan en jalons

**J1 — Registre de modules et cartes découpées** (à fusionner en premier : les
chantiers 09 à 13 l'attendent, 04 à 08 s'y branchent).
- `Sources/Pulse/Modules/` : le protocole `PulseModule` (identifiant, nom,
  symbole, carte, segment de barre optionnel, réglages propres, coût) et le
  registre `ModuleRegistry.all`, une ligne par module.
- `Sources/Pulse/UI/Cards/` : une carte par fichier (Processeur, Réseau,
  Mémoire, Disques, Montage), `PopoverView` réduit au verdict, aux colonnes
  et au pied.
- `--snapshot x.png --carte <id>` : une carte seule.
- Rendu identique : l'ancien et le nouveau panneau rendus dans le MÊME
  processus, sur le même relevé, comparés pixel à pixel, sombre et clair.
- Tests du registre.

**J2 — Réglages persistés et mise en page pilotée**
- `Sources/Pulse/Settings/` : `reglages.json` tolérant (`decodeIfPresent`
  partout, fichier illisible mis de côté), export et import.
- Quelles cartes, dans quel ordre, sur 1, 2 ou 3 colonnes, compactes ou
  complètes ; nombre d'apps listées ; fréquence de mise à jour ; unités.
- Section RÉGLAGES dans `--probe`, rendus `--colonnes`, tests de persistance.

**J3 — Fenêtre Réglages façon iStat**
- Ouverte depuis le menu de l'app (clic droit sur l'icône) et un bouton de la
  barre de raccourcis.
- Barre latérale par module, aperçu en direct de la carte, interrupteurs,
  ordre par glisser-déposer, fréquence, unités, nombre d'apps, couleurs par
  série avec contraste mesuré (refusées sous 3:1).
- Rendue hors écran pour la vérification ; jamais ouverte sur l'écran d'Isma.

## Journal

### J1 — registre et cartes découpées (04 h 22 → 04 h 50 UTC)

Fait :
- `Sources/Pulse/Modules/` : `Module.swift` (protocole `PulseModule`,
  `ModuleCost`, `ModuleOption`, `ModuleSeries`, `MenuBarSegment`,
  `ProbeSection`, `ModuleState`), `ModuleRegistry.swift` (une ligne par
  module, une ligne réservée par chantier), `CardContext.swift`,
  `Layout.swift` (disposition pure, testée).
- `Sources/Pulse/UI/Cards/` : `ProcessorCard`, `NetworkCard`, `MemoryCard`,
  `DisksCard`, `WorkCard`, `CardKit` (historique dépliable partagé).
  `PopoverView` : verdict, colonnes tirées de `Layout`, pied.
- `Sources/Pulse/Settings/` : modèle tolérant, `reglages.json`, export et
  import, teintes mesurées (`TintChoice`, `Contrast`).
- `--snapshot x.png --carte <id> [--ouvert <clé>]` ; section MODULES de
  `--probe`.

Mesures :
- Rendu identique : ancien et nouveau panneau rendus dans le même processus,
  sur le même relevé, comparés pixel à pixel. Sombre et clair, replié puis
  chacun des cinq historiques déplié : 0 pixel différent sur 1,8 à
  2,3 millions (12 comparaisons). Témoin : une différence se voit.
- `swift test` : 19 tests de plus (registre, disposition, réglages,
  teintes) ; les tests de tolérance vus échouer avec le décodeur naïf.
- Contraste inchangé : la plus basse à 3,16:1 (violet, sombre).
- Budget : aucune minuterie ajoutée ; panneau fermé, les modules du socle ne
  font rien de plus. Mesure après fusion sur le Pulse relancé.

## Mode d'emploi pour les chantiers 04 à 08 (et 18)

1. Écrire le module dans VOTRE dossier :

   ```swift
   struct SensorsModule: PulseModule {
       let id = "capteurs"                 // stable : clé de reglages.json
       let name = "Capteurs"
       let symbol = "thermometer.medium"
       var defaultColumn: Int { 0 }        // 0 gauche, 1 droite (2 colonnes)
       func card(_ context: CardContext) -> AnyView {
           AnyView(SensorsCard(model: SensorMonitor.shared, compact: context.compact))
       }
       func stateDidChange(_ state: ModuleState) {
           // panneau ouvert ou fermé, carte affichée ou masquée : la cadence
       }
       func probeSection() -> ProbeSection? { nil } // ou votre section
   }
   ```

2. Remplacer SA ligne commentée dans `ModuleRegistry.all`
   (`// 04-capteurs` → `SensorsModule(),`), sans toucher aux voisines : les
   lignes vides évitent les conflits de fusion.
3. Rendre : `./.build/release/Pulse --snapshot x.png --carte capteurs`.
4. Pour enrichir une carte du socle (Disques, Réseau, Montage) plutôt que
   d'en ajouter une : une ligne dans le fichier de la carte
   (`UI/Cards/DisksCard.swift`…), qui appelle votre vue.

Les pièces de dessin communes restent dans `UI/Cartes.swift` (`Card`,
`CardTitle`, `Ring`, `HistoryBars`, `MirrorBars`, `InfoRow`, `AppRow`).
Pour un historique dépliable : `HistoryToggle` et `HistoryPanel`
(`UI/Cards/CardKit.swift`). `context.compact`, `context.appCount`,
`context.tint(série)` et `context.option(id)` suivent les réglages d'Isma,
que la fenêtre Réglages (jalon 3) règle.

### J2 — les cartes suivent les réglages (04 h 50 → 05 h 00 UTC), fusionné

- Colonnes, ordre, cartes masquées, compactes, nombre d'apps, teinte de
  chaque série, débit en bits, cadence du relevé : appliqués à chaud
  (`AppDelegate.apply`, `Sampler.setIntervals`, plancher 5 s fermé).
- `--snapshot` : `--colonnes`, `--compact`, `--apps`, `--bits`, `--masque`,
  sans rien écrire. `--probe` : cadence, unité, teintes et leurs ratios.
- Défaut trouvé par les tests parallèles : le formateur partagé de `Fmt`
  n'avait pas de verrou (« 0,0 o/s » au lieu de « 0 o/s ») ; la file
  d'échantillonnage et le main thread s'en servent en même temps.
  Verrouillé, test vu échouer avant.
- Réglages par défaut : revérifié pixel à pixel contre l'ancien panneau
  (sombre, clair, chacun des cinq historiques déplié) : 0 pixel différent.

### J3 — fenêtre Réglages (05 h 00 → 05 h 15 UTC)

- `Settings/SettingsView.swift` : barre latérale (Général + une ligne par
  carte, ordre au glisser-déposer), page Général (colonnes 1/2/3 et plan du
  panneau où l'on glisse les cartes d'une colonne à l'autre, cadence,
  unités, export, import, réglages d'origine), page par module
  (interrupteur, colonne, compacte, apps listées, réglages déclarés par le
  module, couleurs par série avec ratio sombre/clair, refusées sous 3:1 et
  barrées, coût) et aperçu en direct de la carte.
- Ouverture : clic droit (ou ⌃-clic) sur l'icône → « Réglages de
  Pulse… », bouton ⚙ en pied du panneau, ⌘,. Contenu créé à l'ouverture,
  libéré à la fermeture (budget). Fenêtre `.moveToActiveSpace` +
  `.fullScreenAuxiliary` pour venir par-dessus Premiere en plein écran.
- Vérifiée hors écran seulement : `--snapshot x.png --reglages <page>`
  (fenêtre jamais posée à l'écran, `cacheDisplay`). L'arbre
  d'accessibilité d'une fenêtre jamais affichée reste vide (SwiftUI ne le
  construit que pour un client) : à relire à l'API par le chantier 16.
- Page Général : la hauteur du panneau, mesurée sur la vraie vue, face à
  celle de l'écran. Une colonne de cartes complètes : 2 419 pt pour 1 290
  utiles — la page le dit et propose compactes, masquées ou une colonne de
  plus.
- Fenêtre ouverte, le relevé passe à la cadence ouverte : l'aperçu est en
  direct (capteurs compris) ; fermée, retour à la cadence fermée.

### Bilan à 05 h 30 UTC — mission faite, fusionnée (fd9309d puis la suite)

Mesures :
- Budget panneau fermé, `./verifie.sh` (banc 60 s) : 0,80 et 0,82 % d'un
  cœur estimés (0,36-0,37 % au banc + l'icône), plafond 1 %. Pulse installé
  (version de `main`, tous chantiers compris) aux mêmes secondes : 1,15 et
  1,35 % ; suivi du Pulse installé sur 3 min stables : 0,82 %.
- 117 tests, contraste au plus bas 3,16:1 (inchangé), panneau 626 × 1 214
  à 1 233 pt avec toutes les cartes des chantiers (sous les 1 290 utiles).
- Cinq modules d'autres chantiers branchés par le registre sans toucher au
  socle : Énergie (06), Capteurs (04), Réseau enrichi (07), Disques
  enrichi (05).

Hors de mon périmètre, signalé :
- `./verifie.sh` échoue sur « Données intactes » depuis l'arrivée de
  l'historique SQLite (02) : `historique.sqlite-shm` est modifié par
  `--probe`, `--snapshot` et `--snapshot --carte`, dans une copie des
  données. Ouvrir une base WAL, même en `SQLITE_OPEN_READONLY`, réécrit
  l'index `-shm`. Piste : `?immutable=1` ou `SQLITE_OPEN_READONLY` sur une
  copie quand `Persistence.enabled` est faux.
- Le Pulse installé (`main`) mesure 1,15 à 1,35 % d'un cœur pendant les
  bancs, au-dessus du plafond de 1 % : à suivre par le chantier 15.

### J4 — le panneau tient dans l'écran (relance, 06 h 20 → 06 h 45 UTC)

Demande : le banc mesurait 1 297 pt pour sept cartes avec le forfait réglé,
1 449 avec Médias, pour 1 290 utiles.

- Choix : **une colonne de plus**, pas des cartes compactes. Une colonne ne
  retire rien à lire ; une carte compacte cache ses listes (apps, journées,
  températures) sans le dire. L'écran d'Isma a de la place en largeur
  (2 056 pt, six colonnes) et pas en hauteur. Les dernières cartes des
  colonnes trop hautes passent dans la colonne ajoutée, dans leur ordre ;
  les autres ne bougent pas, et les réglages ne sont jamais réécrits.
- `Modules/PanelFit.swift` : `PanelLayout`, une mise en page SwiftUI qui
  reproduit la pile d'origine (verdict, colonnes de 296 pt, pied) et ajoute
  la règle ; `PanelFit.arrange`, pure, testée (10 tests, vus échouer sans
  le débordement) ; `PanelLimits` : la zone visible de l'écran de l'icône
  moins la flèche du popover (13 pt) et 3 pt, soit 1 274 pt ici. La règle
  joue à chaque mise en page : une carte qui grandit panneau ouvert, une
  carte de plus activée.
- `--ajuste` (dans `./verifie.sh`) : relevé figé, sombre et clair.
  Sept cartes + forfait : 626 × 1 296 → 932 × 1 238 pt. Plus Médias :
  626 × 1 487 → 932 × 1 238 pt. Largeur 932 pt pour 2 040 disponibles.
- Rendu identique quand tout tient : rendus figés de `--rendus` (cartes et
  panneau) inchangés, 0 pixel ; ancien et nouveau panneau comparés dans le
  même processus sur le relevé figé sans Énergie (1 238 pt, tient) : 0 pixel
  en sombre et en clair.
- Page Général des Réglages : dit quand le panneau s'ajuste, en chiffres.
- Après synchronisation (09 barre, 10 animations, cartes compactes autour
  d'un historique ouvert) : la cascade d'ouverture, l'avis d'icône cachée et
  la compaction suivent dans `PanelLayout`. Comparé au panneau de `main`
  sur le relevé figé : identique au pixel près replié et avec l'historique
  des volumes ouvert ; avec l'historique Réseau ouvert, les initiales des
  jours (L M M J V S D) se placent un sous-pixel plus loin (613 pixels sur
  3,1 millions, lettres seulement, moins d'un demi-point) : résidu
  d'arrondi, non élucidé, hors des comparaisons de `./verifie.sh`.
- Précision de la coordination : le panneau détaché (13) suit la même
  règle. `FloatingContent` passe à `PopoverView` la place de l'écran
  principal moins sa barre de titre (28 pt). `--ajuste` le rend aussi :
  fenêtre de 626 × 1 328 pt (sept cartes) et 626 × 1 519 pt (+ Médias)
  sans ajustement, 932 × 1 268 pt ajustée, pour 2 056 × 1 290. La vraie
  fenêtre, `--snapshot x.png --fenetre` : 626 × 1 281 pt avec les mesures
  du moment (tient, rien ne bouge) ; avec `--ecran 2056x1000`,
  932 × 946 pt. Jamais posée à l'écran (« à l'écran : 0 »).
