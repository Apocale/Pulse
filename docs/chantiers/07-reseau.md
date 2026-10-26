# 07-reseau — réseau avancé et forfait iPhone

Départ : dim. 11/10/2026, 04:23 (heure de la machine). Butée : 06:23.
Branche `chantier/07-reseau`, fichiers à moi : `Sources/Pulse/Metrics/NetworkPlus/`.

## Relevés préalables (11/10, sur la machine, binaires compilés et signés ad hoc comme l'app)

Pas par l'interpréteur `swift` : il voit les compteurs 64 bits que l'app ne
voit pas (piège du README). Chaque essai est un binaire compilé.

| Question | Résultat |
|---|---|
| NetworkStatistics (privé) sans root ? | oui : `dlopen` + `NStatManagerCreate`, 108 sockets, 0,29 s, ~0 ms de CPU |
| Octets par socket ? | dans le bloc des comptes (`rxBytes`, `txBytes`), pas dans la description |
| Qui ? | dans la description : `processName`, `processID`, `epid` (app pour qui un démon travaille) |
| RTT TCP ? | `rttAverage` en **secondes** dans les comptes (0,0895 = 89,5 ms, nettop dit 89,50 ms) |
| Wi-Fi sans autorisation de localisation ? | RSSI −68 dBm, bruit −86 dBm, débit 216 Mbit/s, canal 52, 5 GHz, 80 MHz, 802.11ax : **oui**. Nom du réseau et BSSID : **non** (`nil`) |
| Ping sans root ? | oui, socket `SOCK_DGRAM` / `IPPROTO_ICMP` : passerelle 192.168.1.2 en 3,5 à 7 ms |

## Plan en jalons

1. **Forfait iPhone** : réglages (quota, jour de renouvellement) en JSON
   tolérant, consommation du cycle tirée de `reseau.json`, jauge au vrai
   dénominateur, consommation par jour, rythme, seuils 80 % / 100 % exposés
   pour le chantier 11. Tests : cycles (31 du mois, février, jour 1), seuils,
   rebouclage des compteurs 32 bits.
2. **Connexion** : latence de la passerelle (ping local), latence Internet
   PASSIVE (RTT des connexions TCP déjà ouvertes : aucun octet envoyé),
   indicateur, adresses IP locales, signal Wi-Fi (CoreWLAN).
3. **Débit par application** : NetworkStatistics, panneau ouvert seulement,
   top 5 ↑ et ↓ avec icônes.
4. **Carte Réseau enrichie** dans mon dossier, rendue par
   `--snapshot x.png --carte reseau` ; section dans `--probe`.
5. **IP publique et sonde Internet active** : désactivées par défaut, sur
   réglage seulement ; aucune requête pendant les essais.
6. **Branchement** sur le registre du 01 dès qu'il est dans `main`.

## Journal

### 04:47 — jalons 1 à 4 (forfait, connexion, apps, carte)

**Fait**
- Forfait iPhone (`Forfait.swift`, `ReglagesReseau.swift`) : cycle au jour de
  renouvellement (31 → dernier jour des mois courts), consommation du partage
  iPhone tirée de `reseau.json`, rythme sur les jours OBSERVÉS (cumul commencé
  le 07/10 : 1,4 Go par jour, et non 566 Mo en divisant par tout le cycle),
  échéance « épuisé vers le 21 oct. » si elle tombe dans le cycle, seuils
  80 % / 100 % (`NiveauForfait`) pour le chantier 11, `Sampler.forfait`.
  Pas de jauge tant que le forfait n'est pas réglé : pas de dénominateur
  inventé. Réglages dans `reseau-reglages.json`, relus champ par champ.
- Compteurs 32 bits : l'écart sort de `NetworkTracker` dans
  `CompteursReseau.ecart`, que l'app appelle et que les tests exercent
  (rebouclage, compteur remis à zéro, durée nulle).
- Connexion : passerelle par 2 échos ICMP (le plus court : la radio Wi-Fi qui
  se réveille a donné 70 ms au lieu de 3,4), Internet PASSIF = le plus court
  des RTT des connexions TCP actives (~23 ms sur 14 connexions, médiane
  55 ms), indicateur à seuils posés (2 pertes sur 10, 150 ms), IP locale,
  IPv6 routable, DNS.
- Wi-Fi par CoreWLAN : −67 dBm, bruit −87, rapport 20 dB, 216 Mbit/s,
  canal 52, 5 GHz, 80 MHz, Wi-Fi 6. Le nom du réseau exige la localisation :
  non demandé, et `--probe` le dit.
- Débit par app : NetworkStatistics (161 sockets), apps regroupées par
  bundle comme le classement processeur, `epid` pour les démons qui
  travaillent pour une app.
- Carte `CarteReseau` (mon dossier), rendue par
  `--snapshot x.png --carte reseau [--forfait 20] [--light]`.
- `--probe` : sections FORFAIT IPHONE, CONNEXION, WI-FI, APPS, COÛT.

**Mesures**
- `swift test` : 20 tests, dont 10 à moi ; le compteur remis à zéro et le
  31 février vus échouer sans leur correction.
- Contraste : panneau entier et carte seule, toutes les teintes entre 3,16 et
  5,16:1. La couleur de lien du système, essayée pour « Régler le
  forfait », tombe à 4,08:1 sur la carte sombre (texte : 4,5) : remplacée
  par une ligne à chevron en `.secondary`.
- Coût, mesuré par `--probe` (temps processeur du processus) : relevé des
  sockets 5,0 ms toutes les 3 s, Wi-Fi 2,0 ms + adresses 0,3 ms + ping
  0,8 ms toutes les 10 s : ≈ 0,2 % d'un cœur panneau ouvert. Panneau
  fermé : rien ne tourne (le moniteur vit avec la carte).

### 05:04 — jalon 6 : branché sur le registre du socle

**Fait**
- Le registre du 01 est arrivé dans `main` pendant le jalon 4 :
  `ReseauModule` (mon dossier) remplace `NetworkModule` dans
  `ModuleRegistry.all`, même identifiant « reseau » — la place et les choix
  d'Isma sont gardés. `UI/Cards/NetworkCard.swift` (du socle) n'est plus
  inscrit : à retirer par le 01 ou le 17.
- Réglages du forfait déplacés dans `reglages.json` du socle
  (`modules.reseau.options`) : la fenêtre Réglages les dessine depuis
  `ReseauModule.options`, la carte les modifie au même endroit. Mon fichier
  `reseau-reglages.json` n'a jamais été écrit chez Isma : retiré du code.
- Le moniteur suit `stateDidChange` (carte affichée ET panneau ouvert), et la
  carte, par sûreté, à son apparition et sa disparition.
- Détail de la connexion dépliable, un seul historique ouvert à la fois
  (`context.open`), carte compacte (`context.compact`), nombre d'apps
  (`context.appCount`). Carte ramenée de ~575 à ~490 pt.
- Sockets : chaque socket décrit à son arrivée, descriptions complètes une
  fois sur cinq.

**Mesures**
- Banc (`PULSE_BANC_RESEAU=60 swift test --filter BancReseau`) : 0,398 % d'un
  cœur panneau ouvert avec les descriptions à chaque relevé, **0,259 %**
  après (159 ms de processeur en 61 s, 30 relevés de 147 sockets). Panneau
  fermé : 0, rien ne tourne.
- `./verifie.sh` : TOUT PASSE — 76 tests, panneau 626 × 1214 pt (plafond
  1290), contraste au plus bas 3,16:1.
- Le panneau à 1214 pt : la colonne de gauche porte Processeur, Réseau et
  Énergie, celle de droite ~600 pt. Une carte de plus à gauche le ferait
  déborder : la colonne par défaut d'Énergie (0) est à revoir par le socle.
  (Réglé depuis par le 04 : Capteurs à droite, deux colonnes de ~1214 pt.)

### 05:12 — fusionné dans `main` (d50a7be), puis mesures et tests de plus

- **Fusionné** par `outils/fusionne.sh`, Pulse réinstallé et relancé.
- `./verifie.sh` complet avant fusion : TOUT PASSE (banc : fermé 0,37 %,
  refermé 0,35 % — le moniteur s'arrête bien —, ouvert 5,24 %). Après la
  synchro suivante (historique du 02), un seul échec, qui n'est pas le mien :
  `historique.sqlite-shm` modifié par `--probe`/`--snapshot` (lecture seule
  d'une base WAL : SQLite met à jour son index partagé). Ma branche ne touche
  ni `Sources/Pulse/History/` ni `verifie.sh` (`git diff main` vide). Signalé
  dans le rapport.
- Pulse installé, panneau fermé, après fusion : 1,49 s de processeur en
  180 s = **0,83 %** d'un cœur, 53 Mo (`ps -o time=`), dans la plage d'avant
  (0,76 à 0,93 %, banc du 03).
- `nettop` n'est pas un repli : 0,65 s de processeur pour un relevé d'une
  seconde (`/usr/bin/time`), cent fois l'appel direct. Écrit dans le README.
- Découverte pour la suite : sans aucune requête, NetworkStatistics livre de
  lui-même la description et les DERNIERS comptes de chaque socket qui se
  ferme (30 s : 286 fermés, 286 avec leurs comptes, 4,3 Mo). Une comptabilité
  exacte par app est donc possible sans scruter — mais le gestionnaire seul,
  à l'écoute, coûte 0,10 % d'un cœur sur cette machine (31 ms en 30 s, 424
  sockets vus) : à réserver au partage iPhone, et à passer au banc.
- 17 tests réseau (adresses privées et CGNAT, sockaddr brut, IP publique
  contre un portail captif, réponse d'écho ICMP et somme de contrôle,
  indicateur de connexion, débits minuscules) ; CGNAT vu échouer sans sa
  règle.

### 05:28 — fusionné (717ca95), puis l'indicateur ne crie plus au loup

- Fusionné une deuxième fois : forfait en MENU dans la fenêtre Réglages du
  socle (arrivée entre-temps) — le socle dessine un nombre en compteur, 50 Go
  coûtaient cinquante clics ; tailles d'opérateur de 1 à 500 Go, relues en
  texte comme en nombre. Rendu vérifié : `--snapshot x.png --reglages reseau`.
  Mon option de rendu `--reglages` (éditeur de la carte) entrait en collision
  avec celle du socle : renommée `--edition-forfait`.
- Apps : cinq par défaut, comme iStat ; le nombre réglé par Isma l'emporte.
- Indicateur : une passerelle qui n'a JAMAIS répondu au ping filtre l'ICMP
  (certaines box) — « passerelle muette au ping », calme, au lieu d'une
  alerte rouge permanente ; seule une passerelle qui répondait et se tait
  alerte. Les pertes repartent de zéro au changement de passerelle (l'ancien
  réseau ne juge plus le nouveau). Règle vue échouer sans sa correction.
- Non vérifié faute d'y être : que l'iPhone (172.20.10.1) réponde au ping
  sur le partage. S'il ne répond pas, la règle ci-dessus évite la fausse
  alerte ; `--probe` sur le partage le dira (ligne « passerelle »).

### 05:41 — consignes de la coordination : rien qui fasse surgir une fenêtre, budget

- **Ping de la passerelle désormais SUR RÉGLAGE** (désactivé par défaut),
  dans la carte, `--probe` et la fenêtre Réglages (« Ping de la
  passerelle »). Depuis macOS 15, un accès au réseau local par une app peut
  faire afficher par macOS la demande « Réseau local » ; le ping de la
  passerelle en est un. Par défaut, la carte n'envoie donc plus rien du tout :
  latence Internet passive, Wi-Fi par CoreWLAN, adresses lues sur place.
  Entre les fusions de 05:12 et de ce jalon, le Pulse installé pinguait la
  passerelle à chaque ouverture du panneau.
- Aucune autre demande possible : CoreWLAN n'est lu que pour le signal (le
  nom du réseau, qui exige la localisation, n'est jamais demandé),
  NetworkStatistics est une lecture du noyau, l'IP publique et le ping
  Internet sont désactivés par défaut. Aucun fichier ouvert dans une app,
  aucun osascript : les rendus sont lus par l'outil de lecture d'images.
- **Coût panneau fermé du module : 0.** `sample` du Pulse installé pendant
  10 s, panneau fermé : aucune pile dans `MoniteurReseau`, `SuiviSockets`,
  `LecteurWiFi`, `LecteurAdresses`, `Ping` ni `CarteReseau` ; les files
  `com.isma.pulse.reseau-plus` et `com.isma.pulse.sockets` n'apparaissent même
  pas (CoreWLAN n'y figure que dans la liste des images chargées). Ce qui
  tourne fermé : la file du sampler (74 échantillons sur 10 s), celle des
  capteurs (12), le rendu de l'icône (RenderBox, Metal : 4).
- **Plantage de 04:41 signalé par le 06** (`Pulse-2026-10-11-044150.ips`,
  et `time-…-044148.ips` de la commande qui l'enveloppait) : c'est mon tout
  premier `--snapshot --carte reseau`, lancé depuis mon worktree (chemin
  `.build/release/Pulse`, coalition de l'agent), EXC_BREAKPOINT dans
  `closure #1 in SuiviSockets.demarrer()` — blocs non échappants retenus par
  NetworkStatistics. Corrigé à 04:42 (`@escaping`), AVANT tout commit : la
  première version commitée (daacef6) et toutes les suivantes portent la
  correction, la première fusion date de 05:12. Le Pulse installé n'a jamais
  pu la rencontrer. Test de non-régression `SuiviSocketsTests` : vrai cadre,
  démarrage, deux relevés, arrêt ; sans `@escaping`, il tue le processus de
  test avec le même message (signal 5), vu le 11/10 à 05:44.
- Fusionné (7600597). `./verifie.sh` complet : TOUT PASSE — 134 tests,
  10 rendus identiques à leur référence, contraste 3,16:1 au plus bas, banc
  fermé 0,32 % / refermé 0,35 % / ouvert 5,55 % (machine à 44 %), aucune
  écriture. `sample` du Pulse installé (7600597), panneau fermé, 30 s :
  aucune pile du module.
- Carte masquée ou panneau fermé : `stateDidChange` éteint le moniteur
  (`enabled && panelOpen`), la fenêtre Réglages compte comme une ouverture
  (aperçu en direct) et le libère à sa fermeture ; la carte, à sa
  disparition, l'éteint aussi. Banc : fermé 0,34 %, refermé 0,39 % — pas
  d'écart après une ouverture.

## Bilan au 11/10, 05:52

**Fait** — les cinq points de la mission, dans `main` : débit par app
(NetworkStatistics, cinq apps, icônes), connexion (latence Internet passive,
indicateur, IP locales, DNS ; IP publique, ping Internet et ping de la
passerelle sur réglage), signal Wi-Fi sans localisation, forfait iPhone
(réglable dans la carte et la fenêtre Réglages, jauge au vrai dénominateur,
consommation par jour, rythme, échéance, seuils 80/100 % pour le 11), carte
branchée sur le registre, sections de `--probe`, 18 tests réseau et un banc à la demande.

**Bloqué** — il faut à Isma : la taille de son forfait iPhone (en Go) et le
jour du mois où il repart de zéro.

**Ensuite** — « qui a mangé le forfait » : consommation par app sur le
partage iPhone, panneau fermé. Faisable sans scruter (NetworkStatistics livre
les derniers comptes de chaque socket fermé) mais le seul fait d'écouter
coûte 0,10 % d'un cœur : à décider avec le budget. Ping de la passerelle à
valider sur le partage iPhone, une fois coché.
