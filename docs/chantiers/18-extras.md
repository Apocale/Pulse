# 18-extras — horloges, calendrier, météo

Départ : dimanche 11/10/2026, 06 h 03 UTC (`date` : Sun Oct 11 06:03:55 +00
2026). Branche `chantier/18-extras`, worktree
`.claude/worktrees/agent-ab26cb77e143390d6`. Fin au plus tard 08 h 03 UTC.

Fuseau du Mac relevé dans `/etc/localtime` (+00 ce jour).

## Principe

Trois modules dans `Sources/Pulse/Modules/Extras/`, inscrits au registre,
**désactivés par défaut** (`enabledByDefault = false`) : tant qu'Isma ne les
active pas, rien ne change dans le panneau, rien ne tourne, rien ne coûte.

- Rien ne demande d'autorisation et rien ne sort sur Internet ailleurs que
  dans l'app installée (`Extras.appReelle` : le bundle `.app`, persistance
  active, aucune option de diagnostic). `--snapshot`, `--probe`, `--banc`,
  `--rendus` et `swift test` ne touchent ni EventKit ni le réseau, même si
  Isma a activé les modules.
- `--exemple` (sous `--snapshot` / `--banc` seulement) : calendrier simulé,
  réponse Open-Meteo d'exemple écrite d'après la documentation, personnes
  d'exemple. C'est ainsi que les cartes se rendent et se mesurent.

## Plan en jalons

**J1 — Horloges** (`horloges`)
- Personnes nommées (nom + ville → fuseau), heure, écart avec ici, jour ou
  nuit ; lever et coucher du soleil calculés sur place (algorithme NOAA, rien
  ne sort), pour ici et pour chaque personne.
- Table de villes (fuseau, coordonnées), ville d'ici déduite du fuseau du
  Mac, réglable.
- Éditeur des personnes dans la fenêtre Réglages (crochet court dans le
  socle : une section propre au module).
- Section HORLOGES de `--probe`, segment de barre, tests (soleil contre des
  valeurs publiées, réglages tolérants).

**J2 — Calendrier** (`calendrier`)
- Source d'événements derrière un protocole : EventKit dans l'app, un
  magasin simulé pour les tests et `--exemple`.
- Autorisation demandée seulement quand Isma active la carte, dans l'app
  installée ; clé `NSCalendarsFullAccessUsageDescription` dans `build.sh`.
- Prochains événements (aujourd'hui, demain), « dans 25 min », journées
  entières ; section CALENDRIER, segment, tests.

**J3 — Météo** (`meteo`)
- Client Open-Meteo sans clé, décodage tolérant, codes WMO en français et en
  symboles. Heure par heure (12 h) et 7 jours.
- Requête seulement carte activée, panneau ouvert, au plus toutes les 30 min,
  dans l'app installée ; la carte dit qu'elle sort sur Internet et ce
  qu'elle envoie. Dernière réponse gardée dans `meteo.json` (relue de façon
  tolérante) pour `--probe` et le lancement suivant.
- Section MÉTÉO, segment, tests de décodage sur des réponses écrites d'après
  la documentation.

**J4 — Mesures et documentation**
- Rendus sombre et clair de chaque carte, contraste, panneau avec les trois
  cartes activées (hauteur), banc avec les modules activés en `--exemple`.
- README (options, stockage, pièges), CLAUDE.md (Fait).

## Journal

### J1 — horloges (06 h 03 → 06 h 35 UTC)

Fait :
- `Modules/Extras/` : `Extras.swift` (garde « app installée », `--exemple`,
  heure fr_FR), `Villes.swift` (86 villes, Maroc et France d'abord ; repli
  `zone.tab` pour un fuseau hors table), `Soleil.swift` (NOAA),
  `Horloges.swift` (réglages tolérants, calcul, module, section HORLOGES),
  `CarteHorloges.swift` (carte, éditeur des personnes).
- Socle, deux crochets courts : `PulseModule.settingsSection` (une section
  propre dans la page du module de la fenêtre Réglages ; nil par défaut) et
  son affichage dans `ModuleSettingsPage`. Une ligne au registre.
- Personnes rangées dans `modules.horloges.options.personnes`, une par
  ligne « Nom = ville » : lisible et réparable à la main, relu ligne par
  ligne (une ville inconnue saute seule).

Mesures :
- Soleil contre les éphémérides publiées, à 2 min près : Paris aux deux
  solstices, Tokyo (lever la veille en UTC), Tromsø (nuit et jour polaires).
  Rendu du 11/10 : Paris 08:05 → 19:09, Montréal 07:05 → 18:16, Tokyo
  05:44 → 17:12, Casablanca 06:32 → 18:02.
- Huit horloges, soleil compris : 0,067 ms par minute de carte ouverte ;
  panneau fermé, rien (pas de minuterie, `TimelineView` dans le contenu du
  panneau qui n'existe qu'ouvert).
- `swift test --filter HorlogesTests` : 12 tests.

J1 fusionné dans `main` (52fbb91), après `./verifie.sh` : tout passe,
budget panneau fermé 0,74 à 0,83 % estimés (trois bancs), panneau inchangé
(horloges désactivées). Trois resynchronisations : `main` bougeait pendant
chaque vérification.

### J2 et J3 — calendrier et météo (06 h 35 → 07 h 00 UTC)

Fait :
- `Calendrier.swift` : `SourceEvenements` (protocole), `SourceEventKit`
  (créée dans l'app installée seulement), `SourceSimulee` (tests,
  `--exemple`), `Agenda` (lecture toutes les 5 min et à chaque changement du
  calendrier, carte affichée), `CalendrierModule`, section CALENDRIER.
  `CarteCalendrier.swift` : par jour, compte à rebours du prochain, journées
  entières ; aucune couleur de calendrier (pas de ratio mesuré).
- Demande d'accès : **seulement au passage de masquée à affichée**, l'app
  tournant — jamais au lancement. Pulse est signé ad hoc : macOS peut
  oublier l'accès à chaque reconstruction (l'identité de signature change),
  et la demande surgirait après chaque fusion, en plein montage. Dans ce cas
  la carte propose « Autoriser l'accès aux calendriers », et c'est Isma qui
  demande. Hypothèse à vérifier le jour où il active la carte : je n'ai rien
  demandé à macOS.
- `build.sh` : `NSCalendarsFullAccessUsageDescription` (sans elle, la
  demande échoue).
- `Meteo.swift` : `OpenMeteo` (URL, décodage tolérant — `unixtime` comme
  ISO 8601 local, `null` et types inattendus deviennent des trous, erreur
  déclarée refusée), `CodeMeteo` (codes OMM en français et en symboles),
  `CacheMeteo` (`meteo.json`), `Meteo` (requête au plus toutes les 30 min
  panneau ouvert, toutes les heures fermé, dans l'app installée seulement),
  `MeteoModule`, section MÉTÉO. `CarteMeteo.swift` : le moment, 12 heures
  (probabilité de pluie en barres sur 100 %, `Palette.data`), 7 jours, et
  en pied ce qui sort sur Internet. `ExemplesMeteo.swift` : réponses écrites
  d'après la documentation (open-meteo.com/en/docs), jamais demandées.
- Segments de barre : « CLIENT 02:47 », « AGENDA 25 min », « MÉTÉO 18° »,
  au catalogue du chantier 09, éteints par défaut.
- `--probe` règle chaque modèle comme l'app au lancement avant d'écrire sa
  section : hors de l'app, rien n'est lu ni demandé.

Mesures :
- Aucune requête, aucune demande d'accès pendant tout le chantier : réponses
  d'exemple et magasin simulé seulement ; carte masquée, `--probe` le dit.
- Tests : 12 horloges, 9 calendrier, 11 météo. Vus échouer sans leur
  correction : la demande au lancement (garde d'activation retirée), le nom
  rogné pendant la frappe.
- Contraste sur les rendus de la carte Météo : bleu des barres de pluie à
  3,57:1 en sombre, 3,40:1 en clair (seule teinte des trois cartes).
- Banc de 60 s, les trois cartes activées et leurs segments allumés, sur
  `--exemple`, dans une maison de rechange : panneau fermé 0,37 % au banc,
  0,57 % estimés avec l'icône (plafond 1 %) ; ouvert 10,9 %, contre 9,3 à
  9,8 % sans elles ; panneau de 1 894 pt.
- Hauteurs : horloges 225 pt (4 personnes), calendrier 179 pt, météo 365 pt.
  Les trois activées sur deux colonnes : panneau de 2 051 pt pour 1 290
  utiles ; sur trois colonnes, 1 558 pt. La page Général des Réglages le dit
  déjà ; il faudra des cartes compactes ou en masquer d'autres.

J2 et J3 fusionnés dans `main` (1f39a6f) : `./verifie.sh` complet, banc
compris, tout passe (budget panneau fermé 0,54 à 0,59 % estimés, cartes
extras masquées comme par défaut), puis la vérification sous verrou du
nouveau `fusionne.sh`. Quatre resynchronisations ; deux conflits de
documentation (CLAUDE.md, README.md, ajouts en fin de section des chantiers
10, 11 et 13), résolus en gardant les deux. Le test `chaqueStyleDessine` du
chantier 09 parcourt tout le catalogue de la barre : il lui fallait une
valeur d'essai pour le calendrier et la météo (deux lignes, à côté de celle
des horloges qu'il avait déjà prévue).

Vu aussi : la page Horloges de la fenêtre Réglages, rendue hors écran avec
trois personnes (maison de rechange) — nom, ville, retrait, « 3 sur 8 ».

## Bilan à 07 h 15 UTC — mission faite

Les trois modules sont dans `main`, désactivés : rien ne change dans le
panneau d'Isma tant qu'il ne les active pas.

Ce qu'il faut d'Isma (dans le rapport) :
1. Les personnes de ses horloges et leur ville — ou il les tape lui-même :
   Réglages de Pulse › Horloges › « Ajouter une personne ».
2. La ville du soleil et de la météo : celle du fuseau du Mac par défaut.
   La bonne ? Sinon, Réglages › Horloges et Météo › « Ville ».
3. Activer ou non Calendrier (macOS demandera l'accès, une fois) et Météo
   (sort sur Internet : la position de la ville vers api.open-meteo.com).
4. Les trois activées ajoutent ~800 pt : panneau de 2 051 pt pour 1 290
   utiles. Cartes compactes, ou en masquer d'autres.

À vérifier le jour où il active le calendrier : macOS garde-t-il l'accès
d'une mise à jour de Pulse à l'autre ? Signé ad hoc, probablement non ; la
signature « Apple Development » que propose le chantier 13 le réglerait.

Ensuite, si Isma le veut : une règle « pluie dans l'heure » (moteur du
chantier 11, mesure à publier par la météo) ; d'autres villes à la table.

## Correctif du 11/10, 07 h 25 UTC — `CalendrierTests` dépendait de l'heure

Signalé par la coordination : `CalendrierTests` cassait `main` et bloquait
toutes les fusions depuis ~07:15. Cause : les événements d'essai étaient
posés à 06:45–07:15 UTC (fixe), mais l'`Agenda` lisait avec la VRAIE
horloge ; passé 07:15, l'événement était fini et sortait de la liste.
Le test passait donc le matin et échouait une heure plus tard.

- `Agenda(source:horloge:)` : l'heure de lecture est injectable (la vraie
  horloge par défaut, l'app ne change pas).
- Les tests du calendrier se rejouent sur six instants figés : 06:20,
  23:50, minuit pile, les nuits des changements d'heure de Paris
  (29/03, 25/10), la Saint-Sylvestre. Nouveau test : un événement fini
  quitte la liste quand l'horloge (injectée) avance ; et la fenêtre
  « jusqu'à demain soir » suit le calendrier les nuits de 23 h et de 25 h.
- Vérifié sous `TZ=Europe/Paris`, `America/Los_Angeles`, `Pacific/Auckland`
  et le fuseau du Mac ; vu échouer avec la vraie horloge (29 écarts).
