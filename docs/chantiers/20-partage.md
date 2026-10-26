# 20-partage — envoyer Pulse à un ami

26/10/2026. Demande d'Isma : vérifier Pulse, corriger ce qui casse, et
l'envoyer simplement à un ami qui a un MacBook Pro M1 Pro. Dépôt public
choisi par Isma (« Tout public »), sans l'historique de main.

## Fait

- **Vérification de départ** : `./verifie.sh` passait (363 tests, 18 rendus,
  contraste, 0,54 % d'un cœur fermé).
- **Trois audits en parallèle**, sur une copie figée de Pulse.app, maison de
  rechange vide (`CFFIXED_USER_HOME`), rien d'ouvert à l'écran :
  installation neuve, autre Mac (M1 Pro, autres écrans, macOS 14 à 27),
  plantages possibles. Aucun plantage atteignable par les valeurs d'un autre
  Mac ; ce qui suit a été corrigé, chaque correction couverte par un test vu
  échouer sans elle :
  - capteurs : catalogue par génération de puce (M1 à M4), grappes éteintes
    à 5 °C écartées (`SensorDecodingTests`) ;
  - demandes d'autorisation au premier lancement : journal d'AME (dossier
    Documents) cherché seulement carte Médias affichée, aucune Info.plist ni
    icône lue dans un dossier protégé, sonde Starlink muette quand
    192.168.100.1 est sur le réseau même du Mac (`MediaTests`,
    `PiegesMachineTests`, `CompteursReseauTests`) ;
  - disques : locaux seulement, Time Machine écarté (`PiegesMachineTests`) ;
  - barre de menus : icônes d'un second écran au-dessus ou à gauche
    (`PiegesTests`) ;
  - panneau : sur un petit écran, cartes rangées au plus serré au lieu de
    s'empiler dans la dernière colonne (`PanelFitTests`) ;
  - textes : bulles d'aide calculées sur le Mac (« 10 cœurs », plus
    « douze »), vouvoiement partout, notes de mesure sorties des Réglages,
    chiffres à la française quelle que soit la région ;
  - premier lancement : le panneau s'ouvre une fois tout seul (jamais chez
    qui a déjà lancé Pulse) ; interrupteur « Ouvrir Pulse à l'ouverture de
    session » dans Réglages › Général ;
  - blindage contre des fichiers abîmés à la main (`reglages.json`,
    `reseau.json`, `meteo.json`), un SMC aberrant, aucun écran.
- **Confidentialité** : noms de clients et de proches retirés du code, des
  tests et des notes (le relevé figé dit « Interview 6.mp4 ») ; la ville
  d'Isma retirée des journaux ; commits publics signés de l'adresse
  « noreply » de GitHub.
- **Version à partager** : `outils/distribue.sh` → `.build/distribution/`,
  2,4 Mo, sans le helper des ventilateurs (jamais essayé en vrai : la page
  Ventilateurs ne le propose pas), signature revérifiée après dézippage.
- **Installation** : `installer.sh` à la racine, une ligne dans le Terminal.
  Essayé ici en mode essai (`PULSE_ESSAI`, depuis un zip local puis depuis
  GitHub), refuse un zip à l'empreinte fausse.

## Publier une nouvelle version

1. Corriger, `./verifie.sh`, commiter sur main.
2. `outils/publie.sh 1.1` : vérifie qu'aucun mot de `.git/info/mots-prives`
   n'est dans l'arbre, que les images de `.github/images` sont les rendus de
   référence, relance `./verifie.sh --rapide`, fabrique le zip, ajoute un
   commit à la branche `public` (l'arbre de main), le pousse en `main` sur
   GitHub et crée la version. Sur le Mac de l'ami, la même ligne
   d'installation met à jour.

Mis en place une fois, à refaire sur un autre clone : le dépôt distant
(`git remote add github https://github.com/Apocale/Pulse.git`), le crochet
`.git/hooks/pre-push` (n'accepte que `refs/heads/public` → `main`) et
`.git/info/mots-prives`. Aucun des trois n'est versionné.

**Ne jamais pousser main sur GitHub** : son historique porte les noms
retirés de l'arbre. Le crochet le refuse ; ne pas le contourner.

## Pièges

- **Un zip téléchargé par un navigateur est en quarantaine.** Pulse n'est pas
  notarisé (compte développeur payant) : Gatekeeper le refuse
  (`spctl --assess` : rejected) et il faut « Ouvrir quand même ». curl ne
  pose pas la quarantaine : d'où `installer.sh`.
- **`--probe` ne voit pas les demandes d'autorisation.** Lancé du Terminal,
  il hérite des accès du Terminal (TN3179 d'Apple pour le réseau local, et
  de même pour les dossiers) : seule une lecture du code les trouve.
- **Le helper des ventilateurs est installé sur le Mac d'Isma** depuis le
  11/10 à 11 h 29 (`/Library/PrivilegedHelperTools`), 0 écriture au
  journal. `--probe` le réveille par XPC sans rien écrire.

## Pas vérifié

- Pulse n'a jamais tourné sur un M1, ni sous macOS 14, 15 ou 27 : les clés
  M1 viennent de Stats, la compatibilité de la compilation (cible macOS 14,
  symboles faibles). Le premier `--probe` de l'ami, section CAPTEURS, dira si
  les températures sont justes.
- Un disque Time Machine réel : le rôle « Backup » est lu dans l'IORegistry
  comme les rôles des volumes système, jamais vu sur un vrai disque de
  sauvegarde.
- Le panneau sur l'écran de l'ami : vérifié hors écran avec `--ecran`.
