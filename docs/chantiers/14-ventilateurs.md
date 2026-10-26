# 14-ventilateurs — journal

Départ : dimanche 11/10/2026, 05 h 57 UTC. Limite : 07 h 57 UTC.
Branche `chantier/14-ventilateurs`. Fichiers : `Sources/PulseHelper/`
(bibliothèque `PulseFanKit` dans `Kit/`, exécutable `PulseHelper` dans
`Daemon/`), `Sources/Pulse/Fans/` (côté app), `Tests/PulseTests/FanControlTests.swift`
et `FanPilotTests.swift`. Lignes courtes dans `Package.swift`, `build.sh`,
`SettingsView.swift`, `SettingsSnapshot.swift`, `Probe.swift`, `PulseApp.swift`.

**Rien n'est installé, rien n'écrit dans le SMC tant qu'Isma n'a pas dit oui.**
Le helper est construit et signé dans `Pulse.app`, jamais installé ni
enregistré ; le mode par défaut est « Automatique », qui ne lance ni
minuterie, ni lecture, ni connexion.

## Plan en jalons

1. **Le cerveau, testé sans root.** Protocole XPC fait d'entiers, courbe,
   hystérésis, `FanController` qui porte toutes les sécurités, SMC simulé ;
   exécutable `PulseHelper` (écoute, contrôle du client, chien de garde,
   veille, pression thermique, signaux, journal).
2. **Le helper dans le bundle, inerte**, et la voie d'installation la plus
   simple et la plus sûre pour une app signée ad hoc, sources à l'appui.
3. **Côté Pulse, éteint par défaut** : page Ventilateurs des Réglages,
   pilote, section VENTILATEURS de `--probe`, rendus hors écran.
4. **Revue de sécurité** et étapes exactes de l'essai réel, Isma présent.

## Journal

### Jalon 1 — le cerveau (05 h 57 → 06 h 15)

Relevé du SMC de ce Mac, en LECTURE (commandes 5, 8 et 9 seulement) :
2 ventilateurs ; `F0Md` `ui8` inscriptible (0 = automatique) ; `F0Tg` `flt`
inscriptible (Float32 petit-boutiste) ; `F0Mn` 1 350 et `F0Mx` 5 349 tr/min,
`F1Mn` 1 522 et `F1Mx` 5 777, en lecture seule. Lues par leur nom : `Ftst`,
`F0md` et `FS! ` n'existent pas sur ce M2 Max sous macOS 26 (résultat SMC
0x84, clé inconnue).

- `Sources/PulseHelper/Kit/` : `FanProtocol` (service Mach
  `com.isma.pulse.helper`, quatre commandes : état, automatique, consigne,
  désinstallation ; entiers seulement), `FanController` (les sécurités),
  `FanCurve` (courbe, hystérésis de 3 °C, réglages tolérants : un réglage
  abîmé retombe en AUTOMATIQUE), `FanBytes`, `FanXPC` (serveur et client).
- `Sources/PulseHelper/Daemon/` : `main.swift`, `SMCFans.swift` — le seul
  endroit où la commande d'écriture (6) existe —, `HelperLog.swift`,
  `Installer.swift`.
- Refuse de tourner sans root (code 64) ; `--simule` fait tourner les mêmes
  sécurités sur un SMC simulé : consigne 4 000 / 9 999 → bornée à
  4 000 / 5 777, puis automatique 15 s plus tard faute de battement.
- Tests vus échouer sans la borne, sans le chien de garde, sans le retour
  quand Pulse quitte (6 tests rouges sous mutation).

### Jalons 2 et 3 — installation, page, pilote (06 h 15 → 06 h 45)

**La voie d'installation.** `SMAppService.daemon` était prévu ; il est
écarté, sources ci-dessous : avec une signature ad hoc, launchd fige au
premier enregistrement une contrainte de lancement sur l'empreinte du
helper, et chaque recompilation de `Pulse.app` — une par fusion, plusieurs
par heure en ce moment — donnerait « Launch Constraint Violation », voire une
nouvelle approbation. Retenu : un **démon launchd classique installé une
fois**. `PulseHelper --installe`, lancé en root par la demande de mot de
passe de macOS (bouton « Installer le helper… », c'est Isma qui tape),
copie le binaire dans `/Library/PrivilegedHelperTools/com.isma.pulse.helper`
et le plist dans `/Library/LaunchDaemons/com.isma.pulse.helper.plist`, deux
dossiers que seul root peut écrire, puis `launchctl bootstrap system`. Les
recompilations ne le touchent pas, et un processus d'Isma ne peut pas
remplacer le binaire qui tourne en root. Désinstallation en un clic : le
helper s'efface lui-même (commande `uninstall`, sans mot de passe — le sens
sûr) ; s'il ne répond pas, `--desinstalle` par la même demande de mot de
passe, ou dans le Terminal.

- `build.sh` embarque `Contents/MacOS/PulseHelper`, signé ad hoc, durci
  (`flags=0x10002(adhoc,runtime)`, identifiant `com.isma.pulse.helper`) ;
  `codesign --verify --strict Pulse.app` : valide. Aucun plist dans le
  bundle, rien d'enregistré (`launchctl print system/com.isma.pulse.helper` :
  introuvable).
- `Sources/Pulse/Fans/` : `FanHelperService` (état lu sur disque, installation
  et désinstallation sur geste d'Isma seulement, comparaison SHA-256 du helper
  installé et de celui du bundle → « Mettre à jour… »), `FanPilot` (rien en
  automatique ; sinon battement de 5 s ; température ou ventilateurs muets
  3 fois → automatique ; veille ; sortie de l'app), `FanSettingsPage` et
  `FanCurveEditor` (points glissés à la souris ou réglés au pas, point du
  moment tracé), `FanProbe`.
- Contre une limite d'écritures du SMC relevée sur M4 Max (voir plus bas) :
  60 écritures de consigne par démarrage au plus (compte tenu dans
  `/private/var/db`, remis à zéro à chaque démarrage), une baisse au plus
  par minute, courbe au pas de 5 %. Le retour en automatique n'est jamais
  compté ni refusé.
- `--probe` (depuis le bundle) : helper absent, binaire embarqué, mode
  automatique (défaut), ventilateurs 3 933 / 4 269 tr/min sur macOS, ce que
  la courbe enverrait, journal vide.
- Rendu : `Pulse.app/Contents/MacOS/Pulse --snapshot x.png --reglages
  ventilateurs [--ventilateurs curve] [--light]`, regardé en sombre et en
  clair.
- 40 tests (`FanControlTests`, `FanPilotTests`).

### Jalon 4 — installateur corrigé, revue, mesures (06 h 45 → 07 h 00)

- Défaut trouvé à la relecture, AVANT toute installation : vu depuis
  `Pulse.app/Contents/MacOS/PulseHelper`, `Bundle.main.executablePath`
  désigne l'exécutable PRINCIPAL du bundle — Pulse. `--installe` aurait
  copié Pulse dans `/Library/PrivilegedHelperTools` et launchd l'aurait
  lancé en root. Corrigé : chemin réel du processus (`_NSGetExecutablePath`,
  `realpath`) et identifiant de signature vérifié (`com.isma.pulse.helper`,
  `FanSigning`) avant toute copie. `PulseHelper --essai-installation` (sans
  root, sans écriture) le montre : source = le helper, signature reconnue.
  Sans root, `--installe` et `--desinstalle` sortent en 64 sans rien toucher.
- `./verifie.sh` complet, quatre fois sur ce code (main bougeant pendant
  chaque vérification, aucune n'a pu fusionner) : tout passe ; budget
  panneau fermé 0,83 · 0,82 · 0,55 · 0,59 % d'un cœur estimés ; en
  automatique, le pilote ne crée ni minuterie, ni lecteur, ni connexion.
- 41 tests (`FanControlTests`, `FanPilotTests`).

### Fusion (07 h 16, 8c458b0)

Main avançait pendant chaque vérification (sept essais, tous verts, aucun
n'a pu fusionner) ; le script de fusion revérifie désormais sous le verrou.
`./verifie.sh` complet avant l'appel : tout passe, budget panneau fermé
0,41 % d'un cœur estimés (0,33 % au banc). Fusionné par `fusionne.sh`
(revérification `--rapide` sous verrou), Pulse reconstruit et relancé.

Après la fusion, sur la machine : `launchctl print
system/com.isma.pulse.helper` → introuvable ; rien dans
`/Library/PrivilegedHelperTools` ni `/Library/LaunchDaemons` ; pas de
journal ; aucun processus `PulseHelper`. Le Pulse installé embarque le
helper (452 ko), inerte ; `--probe` depuis le bundle : « helper absent —
rien d'installé, rien d'enregistré », mode automatique (défaut). Pulse
installé, panneau fermé, temps CPU cumulé (`ps -o time=`) de 07 h 17 à
07 h 21 : 0,85 s en 240 s, **0,35 % d'un cœur**.

Après la fusion : `--installe`, `--desinstalle` et le démon regardent
l'utilisateur EFFECTIF (`geteuid`) — la demande de mot de passe de macOS
(`do shell script … with administrator privileges`) donne root en effectif,
et c'est lui qui compte pour écrire dans `/Library`. Sans root : code 64,
rien de touché (vérifié).

### Arrêt (07 h 25) — dernier commit non fusionné

Le commit `geteuid` + bilan est sur la branche, pas dans main : `./verifie.sh`
échoue depuis ~07 h 15 UTC sur `CalendrierTests` (chantier 18), pour tout le
monde — `ExtrasTests` fige « maintenant » au 11/10 06:20Z et place ses
événements à +25 min, quand l'agenda filtre sur l'horloge réelle : passé
07 h 15, plus aucun événement. Rien à voir avec les ventilateurs (échoue
pareil sur main pur). À fusionner dès que le 18 l'a corrigé, AVANT l'essai
réel.

## Signature : les deux cas, prévus (demande de la coordination, 07 h 07)

Le helper lit SA propre signature au démarrage et en déduit l'exigence
envers son client (`FanSigning.clientRequirement`, testée et compilée par
`SecRequirementCreateWithString`) — aucun réglage :

| | Ad hoc (aujourd'hui) | Identité « Apple Development » (si Isma la crée) |
|---|---|---|
| `build.sh` | `codesign -s -` | `PULSE_IDENTITE="Apple Development: …" ./build.sh` signe l'app ET le helper |
| Exigence envers Pulse | `identifier "com.isma.pulse"` — copiable par un processus de la même session | `identifier "com.isma.pulse" and anchor apple generic and certificate leaf[subject.OU] = "<son Team ID>"` — infalsifiable sans la clé privée d'Isma |
| Recompilations | sans effet sur le helper installé | sans effet non plus |
| Installation | démon classique, une fois, mot de passe | la même ; `SMAppService` deviendrait possible, mais jamais vu avec une équipe personnelle et lié au bundle reconstruit à chaque fusion : pas retenu |
| Passage de l'un à l'autre | — | « Mettre à jour… » dans la page (le helper du bundle diffère, SHA-256) : un mot de passe |

Si le helper installé porte une identité et que Pulse revient en ad hoc
(certificat expiré), le helper refuse Pulse : les ventilateurs restent en
automatique. Le sens sûr.

**Recommandation** : l'identité stable, si Isma la crée de toute façon pour
les widgets et Raccourcis du chantier 13 — reconstruire avec
`PULSE_IDENTITE`, PUIS installer le helper : la vérification du client est
alors forte dès le premier jour. Sans elle, l'ad hoc reste sûr grâce à la
surface bornée (revue ci-dessous) ; on ne l'attend pas pour l'essai.

## Recherche — ce que demande l'installation, ce que demande ce M2 Max

**`SMAppService.daemon` et la signature ad hoc** :
- Quinn (Apple DTS) : l'app et le helper doivent porter la même identité
  de signature délivrée par Apple ; en ad hoc, « Operation not permitted »
  (code 1). developer.apple.com/forums/thread/799910
- Au premier enregistrement réussi, launchd fige une contrainte de lancement
  (LWCR) sur l'empreinte de ce build ; les suivants échouent en « Launch
  Constraint Violation ». developer.apple.com/forums/thread/795022,
  github.com/johnlofty/portkeeper/pull/4, github.com/borism/ollama-cluster/pull/21
- L'en-tête `SMAppService.h` : un plist ou un exécutable changé « must be
  re-registered or it may not launch ». developer.apple.com/forums/thread/745412
- L'accord : un démon ne démarre qu'après l'approbation d'un administrateur
  dans Réglages Système › Ouverture et extensions. developer.apple.com/documentation/servicemanagement/smappservice/register()
- `AssociatedBundleIdentifiers` exige le même Team ID — que l'ad hoc n'a pas.
  developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos
- Une identité stable sans payer existe (« Personal Team » d'Xcode, compte
  Apple gratuit) mais n'a été vue nulle part avec un démon `SMAppService` ;
  un certificat auto-signé est refusé par AMFI. github.com/jwp23/throwntom/pull/182,
  github.com/agoodkind/macos-smc-fan

**Démon classique** : enregistré par le gestionnaire d'arrière-plan comme
« legacy daemon », activé par défaut, une notification « élément
d'arrière-plan ajouté », visible (et désactivable) dans Réglages Système ›
Général › Ouverture et extensions sous le nom de son exécutable.
dssw.co.uk/powermanager/guide/finding-and-fixing/macos-login-items/,
developer.apple.com/forums/thread/725982

**Le client XPC** : `identifier "…"` seul se falsifie (« the signer can set
the code signing identifier to whatever value they want », TN3127) ; en ad
hoc, toute contrainte de certificat est fausse. D'où la revue ci-dessous.
developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements

**Piloter les ventilateurs d'Apple Silicon** :
- Stats (exelban/stats, MIT) écrit `F<n>Md` = 1 directement, et ne passe par
  `Ftst` = 1 que si c'est refusé ; consigne `F<n>Tg` en Float32
  petit-boutiste ; retour : `Md` = 0. github.com/exelban/stats/blob/master/SMC/smc.swift
- M3 et M4 exigent `Ftst` ; M1 accepte l'écriture directe ; M2 « may behave
  the same; untested ». github.com/exelban/stats/pull/2924, /pull/3051
- Sur ce M2 Max, `Ftst` n'existe pas (lu par nom, 0x84) : l'écriture directe
  est la seule voie. **À vérifier à l'essai réel** : c'est le premier point
  de la procédure ci-dessous.
- Résultat SMC 0x82 = écriture refusée même si IOKit rend succès : le helper
  lit l'octet de résultat. github.com/s1mptom/GlassFan/pull/5
- Un relevé sur M4 Max, macOS 26.6 : environ 100 écritures de ventilateur
  par démarrage, puis 0x82 jusqu'au redémarrage.
  github.com/alfaiotadev/apple-silicon-smc-fan-write-limit — d'où le budget
  de 60.
- `Ftst` et le mode imposé se perdent en veille selon deux sources ; d'où le
  retour en automatique à la veille et la reprise après le réveil.
  github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md
- Le pilote Linux du SMC d'Apple : « The SMC does no sanity checks on
  requested fan speeds ». docs.kernel.org/hwmon/macsmc-hwmon.html — d'où les
  bornes relues à chaque consigne, et la pression thermique de macOS comme
  garde-fou.

## Revue de sécurité

Ce qui tourne en root : `PulseHelper` (433 ko), et rien d'autre. Lancé par
launchd au chargement puis à la demande (service Mach), il sort de lui-même
après 60 s sans client et en automatique. Il ne lance aucun processus — sauf
`/bin/launchctl bootout` pour se désinstaller —, ne lit ni n'écrit aucun
fichier pour le compte d'un client, n'ouvre aucun réseau. Ses seules
écritures : deux familles de clés du SMC (`F<n>Md`, `F<n>Tg`), son journal,
son compteur d'écritures, et ses propres fichiers à la désinstallation.

**1. Ce qu'un client peut demander.** Quatre commandes : l'état (rien
d'écrit), l'automatique, une consigne, la désinstallation (le sens sûr). Les
messages ne sont lus qu'en entiers 64 bits, clé connue par clé connue
(`FanRequest.decode`) : ni chaîne, ni tableau, ni données, ni objet. Tout
autre contenu → « mal formé », rien n'est touché (testé de bout en bout :
`FanXPCTests`). Les noms de clés SMC sont formés par le helper à partir d'un
indice vérifié contre `FNum` (8 au plus) : aucun client ne peut nommer une
clé, donc aucune autre clé du SMC (charge de la batterie, alimentation…)
n'est atteignable.

**2. Les bornes.** Chaque consigne est ramenée entre le minimum et le
maximum d'Apple RELUS au SMC à chaque fois ; des bornes absurdes (minimum
nul, maximum sous le minimum) → refus. La valeur du client n'est jamais
crue (testé : 100 et 99 999 tr/min deviennent 1 350 et 5 777).

**3. Les replis.** Retour en automatique — écrit ventilateur par
ventilateur, même si le SMC ne répond plus à la lecture — quand : Pulse
quitte ou plante (connexion fermée), le battement manque 15 s, le Mac
s'endort (puis 10 s de grâce au réveil), macOS publie une pression
thermique forte (puis 10 min sans consigne), la température ou les
ventilateurs ne se lisent plus (côté Pulse, 3 lectures), une lecture ou une
écriture du SMC échoue, le budget d'écritures est atteint, le helper démarre
(un ventilateur resté imposé par un helper tué est rendu), le helper
s'arrête (SIGTERM, SIGINT, SIGHUP). S'il plante, launchd le relance
(`KeepAlive` sur sortie en échec) et son démarrage rend la main. Chaque repli
est testé contre le SMC simulé.

**4. Qui peut parler au helper.** Un processus de la personne devant
l'écran (propriétaire de `/dev/console`, jamais root), signé
`identifier "com.isma.pulse"` (`xpc_connection_set_peer_code_signing_requirement`).
Limite assumée : Pulse est signé AD HOC ; son exigence désignée est son
empreinte, qui change à chaque compilation, et l'identifiant — la seule
exigence qui y survive — peut être copié par n'importe quel processus de la
même session (TN3127). Conséquence bornée par 1 à 3 : un tel processus peut
faire tourner les ventilateurs entre le minimum et le maximum d'Apple — du
bruit, de la batterie, un Mac plus chaud que macOS ne l'aurait laissé, que
la puce bride d'elle-même et que la pression forte rend à macOS — ou
désinstaller le helper. Rien de plus : pas d'élévation de privilèges, pas
de fichier lu ou écrit pour lui. Un tel processus a déjà les droits d'Isma.
Seule une identité signée par Apple (Developer ID, ou « Personal Team »
d'Xcode) fermerait ce point.

Côté Pulse, la connexion exige un service du domaine SYSTÈME
(`XPC_CONNECTION_MACH_SERVICE_PRIVILEGED`) : un processus de l'utilisateur
ne peut pas se faire passer pour le helper.

**5. Le binaire qui tourne en root** est la copie de
`/Library/PrivilegedHelperTools`, à root, dans un dossier à root : un
processus d'Isma ne peut pas le remplacer. L'installation, elle, exécute en
root le helper du bundle (inscriptible par Isma) — une fois, sur sa demande
et avec son mot de passe, comme tout installateur. Le binaire est durci
(`--options runtime`) et refuse de tourner hors root, sauf `--simule`, qui
n'ouvre pas le SMC.

**6. Les fichiers écrits en root** (`/Library/Logs/PulseHelper.log`,
`/private/var/db/com.isma.pulse.helper.ecritures`, le binaire et le plist
installés) : dossiers inscriptibles par root seul (relevé : root:wheel
755) ; ouverts quand même sans suivre de lien (`O_NOFOLLOW`, `O_EXCL` pour
les fichiers temporaires), renommés en place. Le journal n'est écrit que
s'il est un fichier ordinaire à root à un seul lien ; il ne contient que des
entiers et des phrases fixes, aucun texte venu d'un client.

## Ce qu'il faut d'Isma

Son accord pour installer le helper (son mot de passe administrateur), puis
un essai de 10 min avec lui devant le Mac. Tant qu'il n'a rien accepté :
rien n'est installé, le mode reste Automatique, et la page Ventilateurs ne
fait que lire.

En deux phrases, pour lui : Pulse installera un petit programme
administrateur, le « helper », qui ne sait faire qu'une chose — régler la
vitesse des deux ventilateurs entre le minimum et le maximum d'Apple — et
qui rend la main à macOS dès que Pulse quitte, que le Mac s'endort ou que
quelque chose cloche. Pour l'enlever : un clic sur « Désinstaller » dans
Réglages de Pulse › Ventilateurs (ou l'interrupteur
« com.isma.pulse.helper » dans Réglages Système › Général › Ouverture et
extensions).

## Essai réel, Isma présent (10 min)

Relevé à chaque étape par la coordination, sans rien ouvrir :
`/Users/isma/Documents/Dashbaord/Pulse.app/Contents/MacOS/Pulse --probe`,
section VENTILATEURS (mode, `F0Md`/`F1Md`, consignes, réponse du helper,
journal).

1. Isma : Réglages de Pulse (clic droit sur l'icône → Réglages de Pulse…,
   ou ⌘,) → « Ventilateurs » → « Installer le helper… » → lire l'alerte →
   « Installer » → taper son mot de passe. Une notification « élément
   d'arrière-plan ajouté » peut apparaître : c'est lui. Attendu : « Installé ».
2. **Le test qui décide** : « Vitesse fixe », curseur sur max. Dans les 5 s,
   les ventilateurs montent (on l'entend). Attendu au relevé : `F0Md = 1`,
   consignes 5 349 et 5 777, journal « consigne 0=5349 1=5777 ». Si le SMC
   refuse (journal « refus : le SMC n'a pas répondu », ventilateurs sur
   macOS) : ce M2 Max veut autre chose que l'écriture directe — arrêter là,
   désinstaller, rapporter le journal.
3. « Automatique » : retour à macOS en quelques secondes (`F0Md = 0`,
   journal « automatique : mode automatique choisi »).
4. Pulse quitte : « Vitesse fixe » au max, puis clic droit sur l'icône →
   Quitter. Attendu : retour immédiat à macOS (journal « Pulse a quitté »).
   Relancer Pulse (`open /Users/isma/Documents/Dashbaord/Pulse.app`) : le
   mode choisi reprend ; remettre « Automatique ».
5. « Courbe » (celle d'origine) : la vitesse suit la température ; le relevé
   montre la température suivie, le niveau et les consignes.
6. Fin : « Automatique », puis garder le helper ou « Désinstaller » (un
   clic). Après désinstallation, le relevé dit « absent » et
   `/Library/PrivilegedHelperTools/com.isma.pulse.helper` n'existe plus.

En secours, sans Pulse : `sudo /Library/PrivilegedHelperTools/com.isma.pulse.helper --desinstalle`
dans le Terminal rend la main et efface tout.
