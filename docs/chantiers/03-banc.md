# 03-banc — journal

Départ : dim. 11/10/2026, 04:22 (horloge de la machine, `date`).
Branche `chantier/03-banc`. Mission : section « 03-banc » de `missions.md`.

## Plan en jalons

1. **`./verifie.sh`, première version — à fusionner tout de suite.** Build,
   `swift test`, `--probe` sans erreur, rendus sombre et clair (`--snapshot`),
   contraste (`outils/contraste.swift`), taille du binaire. Sortie lisible, code
   d'erreur si un seuil casse, moins de 3 minutes. Les sept autres chantiers
   l'attendent pour fusionner.
2. **`Pulse --banc <secondes>`** (`Sources/Pulse/Bench/`) : le vrai `Sampler`
   sans interface, écriture coupée. Phases : panneau fermé, ouvert (contenu créé
   hors écran, jamais montré), refermé. Imprime le temps CPU (temps cumulé du
   processus), la mémoire, les réveils par seconde, le temps de création du
   panneau. Recoupé avec le Pulse installé (`ps -o time=` sur plusieurs
   minutes). Branché dans `./verifie.sh` : 60 s, seuil de 1 % d'un cœur
   panneau fermé.
3. **Sampler simulé et tests de rendu.** Données fixes et déterministes ; rendu
   du panneau entier (puis de chaque carte quand le registre du 01 est dans
   `main`), sombre et clair, comparé à `Tests/References` avec une tolérance
   mesurée ; un mode pour régénérer les références volontairement.
4. **Mesures de base** ici et dans la section Diagnostic du README.
5. **Enrichir** : contraste qui retrouve le fond des cartes quelle que soit la
   mise en page, alerte sur une teinte de `Palette` non mesurée, seuils pour le
   15-audit-perf.

## Avancement

### Jalon 1 — `./verifie.sh` v1 (fait, fusionné à 04:36)

Compilation, taille du binaire, `swift test`, `--probe` (sections présentes,
verdict rendu), rendus sombre et clair hors écran avec contrôle de taille (le
panneau doit tenir dans 2056 × 1290 pt), contraste. Relevé et rendus tournent
en parallèle. Les journaux et les images vont dans `.build/verifie/`.

Mesures : 11 s sur une compilation déjà faite, 26 s après une modification
(14 s de compilation release, une dizaine de tests). Échecs vérifiés à la
main : une erreur de compilation volontaire (le message du compilateur est
cité, couleurs ANSI retirées), un test volontairement faux (les lignes ✘ sont
citées), code de sortie 1 dans les deux cas.

État de départ relevé : binaire 1,9 Mo ; rendu 626 × 713 pt ; contraste le plus
bas 3,16:1 (violet, sombre) ; 12 avertissements préexistants du compilateur
(`as? Double` inutiles dans les décodeurs manuels, pour le 17-audit-code).

### Jalon 2 — `--banc` et `./verifie.sh` v2 (fait, 04:57)

`Sources/Pulse/Bench/Banc.swift`. Le vrai `Sampler`, écriture coupée, sans
barre ni popover ; le libellé de barre refait comme `AppDelegate.renderLabel`
(même `labelImage`, rendue interne pour ça). Trois phases : fermé (20 s),
ouvert (12 s, contenu créé comme `makeContent` et gardé dans une fenêtre jamais
affichée), refermé (20 s). Chaque fenêtre démarre entre deux relevés et en
couvre un nombre entier. Temps CPU par `getrusage` ; réveils, énergie et
mémoire par `proc_pid_rusage` v6. Le Pulse installé est lu pendant les mêmes
secondes (unités mach converties : vérifié, 0,535873 s contre 0,53589 s par
`getrusage` sur une seconde de calcul).

Constats mesurés :
- `ri_pkg_idle_wkups` reste à 0 sur Apple Silicon ; `ri_interrupt_wkups`
  compte juste (200 sommeils de 20 ms → 200).
- Hors fenêtre, la vue SwiftUI du panneau ne bouge plus (2 réveils/s) ; dans
  une fenêtre jamais affichée, elle suit le sampler (9 à 13,5 réveils/s).
  Fenêtres de Pulse à l'écran pendant le banc : 0, vérifié par
  `CGWindowListCopyWindowInfo`.
- Banc fermé 0,27 à 0,47 % d'un cœur, Pulse installé 0,76 à 0,93 % sur les
  mêmes secondes. L'écart (0,41 à 0,53 point) revient à l'icône de barre, que
  le banc ne peut pas afficher : `Banc.icone` = 0,45 point ajouté au budget
  estimé. **Le Pulse installé est déjà à ~0,8 % : il reste ~0,2 point de
  budget pour tous les chantiers.**
- Le bruit vient de la machine, occupée à 60–100 % par les chantiers : d'où
  la seconde mesure en cas de dépassement, la meilleure retenue.

`./verifie.sh` v2 : banc de 60 s (budget estimé < 1 %, mémoire refermé
< 150 Mo, création à chaud < 400 ms, 0 fenêtre à l'écran, alerte si refermé
coûte plus que fermé) et **contrôle d'écriture** : tests, relevé, rendus et
banc tournent dans un dossier personnel de rechange (`CFFIXED_USER_HOME`)
garni d'une copie des données de Pulse, comparée par MD5 avant et après.
Vérifié en coupant volontairement `Persistence.enabled = false` dans
`Snapshot.swift` : « modifié : history.json, verdicts.jsonl », code 1. Durée :
95 s, dont 68 de banc.

### Jalon 3 — relevé figé et rendus de référence (fait, 05:20)

- `Bench/Releve.swift` : tout ce que publie le `Sampler`, en valeurs fixes —
  une journée de montage chargée (Premiere et Media Encoder, swap qui monte,
  Ssd 2 plein dans 12 jours, partage iPhone, un plantage). Aucune valeur ne
  dépend de l'heure : échéances au-delà de la semaine (« plein vers lundi »
  changerait), session close, démarrage fixé (`SystemClock.bootDate` devient
  une variable), cumul internet figé (`Sampler.networkHistory`).
- `Sampler(figé:)` : sans minuterie ni capteur, construit par
  `Releve.sampler()`, qui coupe d'abord la persistance.
- `Pulse --rendus` : quatre cartes du socle et le panneau (échelle 1, il
  vérifie l'assemblage), sombre et clair, comparés à `Tests/References`
  (820 Ko). `--rendus --references` régénère ; `./verifie.sh --references`
  aussi, et liste ce qui a changé.
- Tolérance mesurée : deux rendus du même relevé, mêmes octets. Comparé tel
  quel à sa référence relue, un rendu inchangé s'en écartait d'un niveau sur
  62 à 295 pixels (arrondi du PNG) : il passe désormais par le même PNG,
  identique à l'octet sur une dizaine d'exécutions — sauf une fois, un niveau
  sur 243 pixels. Seuil : 2 niveaux, 0 pixel. Sensibilité : « 68 % » devenu
  « 69 % » → 180 pixels à 191 niveaux, vu échouer dans `--rendus` et dans
  `unChiffreQuiChangeSeVoit`.
- Trouvé en route : le processus de `swift test` résout les couleurs système
  autrement que l'app (fond clair #FFFEFF au lieu de #EFEFEF). Les références
  se font donc dans le binaire ; les tests (`RenduTests`, 7) vérifient la
  stabilité, la comparaison elle-même et que les cartes vivantes se rendent.
- Cartes vivantes (énergie ; capteurs quand il sera inscrit) : rendues dans
  `.build/rendus/vivante-*.png`, jamais comparées, tant que leur module ne sait
  pas se nourrir d'un relevé figé.
- Après synchronisation (05 et 07 fusionnés) : la carte Disques a gagné sa
  ligne d'activité (référence régénérée, déterministe : « — » sans relevé),
  la carte Réseau du 07 dessine le forfait du mois jusqu'à « aujourd'hui »,
  l'heure du rendu : sortie des cartes figées, rendue sans comparaison. Elle
  y reviendra quand `Forfait.etat` pourra recevoir une date fixe.

### Jalon 4 — l'écart de budget avec le Pulse installé (05:55)

Demande de la coordination : le Pulse installé mesure 1,15 à 1,35 % d'un cœur
sur 60 s, le budget estimé du banc 0,80 à 0,83 %. Ce que le banc ne
reproduisait pas, et ce qui est fait :

- **Persistance** : coupée au banc jusqu'ici. `--banc … --ecrit` la garde
  active, refusé hors d'un dossier personnel de rechange (`CFFIXED_USER_HOME`,
  liens résolus, la Bibliothèque d'Isma interdite) ; `./verifie.sh` le lance
  ainsi, après son contrôle d'écriture. Effet mesuré : faible — fermé 0,33 %
  et refermé 0,39 % sur 60 s ; 0,51 % et 0,45 % sur 300 s (fenêtres de 110 s).
- **Cadence** : le banc applique maintenant les réglages comme
  `AppDelegate.apply` (`setIntervals`), et cale ses fenêtres sur la période
  fermée réglée.
- **Icône de barre** : toujours impossible à afficher sans rien montrer.
  Mesuré côte à côte, mêmes secondes (`outils/trace-cpu.swift`, toutes les
  2 s) : Pulse installé 15 ms par tranche de 2 s en moyenne (0,75 %), le banc
  6 ms (0,30 %) ; l'écart revient à chaque tranche, 8 à 9 ms de plus même hors
  relevé, quand seul le libellé change. `Banc.icone` (0,45 point) tient.
- **Tâches longues** : le banc de 60 s ne voit pas celles de période ≥ 60 s
  (disques, incidents : toutes les 2 min, tombées pendant la chauffe). Sur
  300 s, +0 à +0,1 point. Une pointe de 156 ms vue une fois au banc vers 30 s,
  non identifiée (à suivre par le 15).
- **Le Pulse installé est relancé à chaque fusion** (`fusionne.sh`) : à
  plusieurs fusions par quart d'heure, il est presque toujours dans ses
  premières minutes. Une trace de 90 s après relance : 0,85 % ; une autre,
  1,5 % sur ses 30 premières secondes. Les 1,15 à 1,35 % peuvent tenir en
  partie à ce démarrage permanent : à mesurer sur 10 min sans fusion.

Outil remis au 15-audit-perf : `swift outils/trace-cpu.swift [durée] [pas]
[pid]`, lecture seule, sans `sample` ni profileur (le mode développeur est
désactivé : ils déclencheraient une demande de mot de passe à l'écran).

### Point au bout de la session (06:03)

**Fait, fusionné dans `main`** : `./verifie.sh` (compilation, taille, tests,
`--probe`, rendus sombre et clair, rendus figés contre `Tests/References`,
contraste, contrôle d'écriture sur une maison de rechange, banc de 60 s avec
persistance active) ; `Pulse --banc [s] [--ecrit]` ; `Pulse --rendus
[--references]` ; `Releve` et `Sampler(figé:)` ; `outils/trace-cpu.swift` ;
`outils/contraste.swift` qui trouve seul le fond des cartes ; le faux échec
des `-shm` réglé. Durées : `./verifie.sh` 90 à 160 s, `--rapide` 25 à 80 s
selon ce qui est à recompiler.

**En cours** : rien d'entamé hors de `main`.

**Bloqué** : rien. Deux demandes à faire passer :
- au 07-reseau : laisser fixer « aujourd'hui » dans `Forfait.etat` pour un
  rendu, sans quoi la carte Réseau reste hors des comparaisons d'images ;
- aux modules qui mesurent eux-mêmes (énergie, capteurs) : un relevé figé
  injectable, pour entrer dans `Rendu.cartesFigees`.

**Ensuite** : mesurer le Pulse installé 10 min sans fusion (le 15, avec
`outils/trace-cpu.swift`) ; identifier la pointe de 156 ms vue au banc ;
signaler dans `verifie.sh` une teinte de `Palette` absente de
`outils/contraste.swift` ; rendre les dépliants figés (`--ouvert`) quand leurs
historiques auront un relevé figé.

### Jalon 5 — énergie, capteurs et réseau figés ; teintes de Palette contrôlées

Relance de la coordination (04, 06 et 07 terminés).

- **Modules figés, changements courts dans leurs fichiers** :
  `PowerSampler(figé:)` et `EnergyModule.installer` (06) ; `SensorStore.figer`
  (04) ; `MoniteurReseau.figer` (07) — chacun publie un relevé fixe, et plus
  rien ne le relance (`update`, `setCadence`, `regler` sans effet ; une
  publication en vol est ignorée). « Aujourd'hui » du forfait :
  `Sampler.maintenantFige`, posé par `Sampler(figé:)`, lu par
  `Sampler.forfait(_:)`. La carte Réseau lit ses réglages dans son contexte,
  comme les autres cartes, et non plus dans `SettingsStore.shared` : un rendu
  figé donne les siens (forfait de 20 Go renouvelé le 1er).
- `Releve.typique` : batterie sur secteur ne chargeant plus (74 %, santé
  81 %, chargeur 140 W, AirPods Pro), puce chaude sous export (cœurs 70 et
  58 °C, ventilateurs 2 675 tr/min, 64 W), partage iPhone (−58 dBm, ~39 ms,
  Dropbox qui envoie), forfait à 10 Go sur 20, onze jours de cycle.
- `Rendu.cartesFigees` : les sept cartes du registre d'alors ; 16 rendus
  identiques d'une exécution à l'autre, références régénérées et regardées.
  Reste vivante : « medias » (08), arrivée entre-temps.
- **Teintes de Palette** : `./verifie.sh` échoue sur une teinte que
  `outils/contraste.swift` ne mesure pas (hors fonds, décor, accent et
  `adaptiveWarning`, déclarés) et sur une définition système différente des
  deux côtés. Vu échouer sur deux copies cassées de `Palette.swift` : une
  teinte « chaleur » ajoutée, `data` passée en `.systemTeal`.
- Vu en route : le panneau figé, toutes cartes affichées et le forfait réglé,
  fait 1 297 pt de haut, plus que les 1 290 utiles de l'écran (pour le 01).
