# Ce qu'il faut d'Isma

Tenu à jour par la session de coordination. Chaque ligne : quoi, combien de
temps, pour quel chantier. Une case cochée = fait et relevé.

## Au retour devant le Mac

- [ ] Si une fenêtre « … veut contrôler Aperçu » est ouverte : « Ne pas
      autoriser ». Un agent a ouvert un rendu dans Aperçu par erreur (01,
      11/10) ; c'est interdit depuis.
- [ ] Si une demande « Réseau local » pour Pulse est ouverte : refuser. Le
      ping de la passerelle partait par défaut entre 05:12 et 05:46 UTC le
      11/10 (07) ; il est désactivé depuis.
- [ ] Réglages de Pulse (clic droit sur l'icône, ou ⌘,) → Général : glisser
      une carte d'une colonne à l'autre, ouvrir le panneau, dire si la carte
      a changé de place. 2 min. (01)
- [ ] Débrancher le chargeur 5 min en travaillant normalement, et prévenir au
      moment du débranchement : la coordination relève `--probe` pendant ce
      temps. (06)
- [ ] Brancher le casque JBL ou les écouteurs soundcore 2 min, et prévenir :
      même relevé. (06)
- [ ] Un export depuis Premiere, sans Media Encoder : environ 10 min, dont
      2 d'attention. (08)
      1. Choisir une séquence déjà montée de 2 à 5 min.
      2. Onglet Exporter, préréglage habituel (H.264 « Match Source - Adaptive
         Low Bitrate »), bouton bleu Exporter. Pas « Envoyer à Media
         Encoder ».
      3. Prévenir juste avant : la coordination lance
         `./.build/release/Pulse --probe --suivi-export 600 --csv outils`
         (relevé toutes les 2 s pendant 10 min, rien ne s'ouvre).
      4. Attendre 1 min avant de cliquer, laisser tourner 1 min après la fin.
- [ ] Facultatif, 2 min : ouvrir le panneau et dire si les libellés de la
      carte Capteurs (colonne de droite) parlent. (04)
- [ ] Notifications, 2 min : Réglages de Pulse → « Règles et alertes » →
      « Envoyer une notification d'essai ». macOS demande « Pulse souhaite
      vous envoyer des notifications » : « Autoriser ». Dire si la bannière
      « Pulse · essai » est apparue ; sinon, recopier la ligne sous le
      bouton. Facultatif : allumer « Disque de rushes presque plein ». (11)
- [ ] Panneau détaché, 2 min : clic sur l'icône Pulse → « Détacher ». Passer
      Premiere en plein écran : la fenêtre doit rester visible par-dessus.
      Cliquer l'épingle : elle doit pouvoir passer derrière. Puis ouvrir
      « Tableau de bord ». (13)
- [ ] Décision, 5 min si oui : signer Pulse avec un certificat « Apple
      Development » gratuit (Xcode › Réglages › Comptes : ajouter ton Apple
      ID, puis Manage Certificates › + › Apple Development). Sans lui, macOS
      refuse les widgets et les actions Raccourcis de Pulse ; avec lui, le
      helper des ventilateurs (14) a aussi une signature stable. Pas de bac à
      sable, pas de compte payant. Ensuite : un clic « Toujours autoriser »
      dans le trousseau la première fois. (13, 14)
- [ ] 30 s, à la prochaine ouverture du panneau : cliquer « Ouvrir Ssd 2 › »
      sous le conseil du verdict, et confirmer qu'une fenêtre Finder s'ouvre
      sur Ssd 2, rien d'autre. (12)
- [ ] Animations et thèmes, 2 min, à une pause : ouvrir le panneau d'un clic
      sur l'icône ; regarder le cadre en verre autour des cartes et la
      cascade à l'ouverture ; survoler une barre du graphique Processeur ;
      puis Réglages de Pulse › Général › Apparence › Thème : essayer
      « Violet ». Dire ce qui plaît ou gêne. (10)
- [ ] Ventilateurs, 10 min, seulement si tu es d'accord. Pulse installe un
      petit programme administrateur (le « helper ») qui ne sait faire
      qu'une chose : régler la vitesse des deux ventilateurs, toujours entre
      le minimum et le maximum d'Apple, et rendre la main à macOS dès que
      Pulse quitte, que le Mac s'endort ou que quelque chose cloche. Pour
      l'enlever : « Désinstaller » dans Réglages de Pulse › Ventilateurs.
      Ton mot de passe est demandé une fois, c'est toi qui le tapes. La
      coordination suit l'essai pas à pas (6 étapes, dans
      docs/chantiers/14-ventilateurs.md). (14)
- [ ] Barre de menus, 30 s : regarder l'icône Pulse juste à droite de
      l'encoche (MÉM, SSD 2, ↑↓). Un petit triangle ⚠ doit être à gauche
      tant que le verdict est en alerte (« Ssd 2 plein vers jeudi »). Dire
      si le triangle est là, si le texte est net, et si aucune autre icône
      n'a disparu. (09)
- [ ] Rangement des colonnes quand Pulse en ajoute une : A (les cartes
      bougent le moins possible, 1 240 pt de haut) ou B (colonnes
      équilibrées, 1 016 pt) ? Recommandé : B. (16)
- [ ] Plus tard : les mots du panneau (« Pression thermique » → « Chauffe »,
      « La machine suit » → « Tout va bien »…), liste dans
      docs/chantiers/16-audit-ux.md ; le 16 recommande de presque tout
      accepter. (16)
- [ ] As-tu déjà vu une fenêtre « Pulse souhaite accéder aux fichiers de
      votre dossier Documents » ? Pulse y lit le journal de Media Encoder ;
      signé sans certificat, macOS peut reposer la question après chaque
      recompilation. Le certificat « Apple Development » réglerait ça aussi.
      (17)
- [ ] Facultatif, à effacer toi-même si tu veux (restes inutiles, sans
      danger) : ~/Library/Application Support/Pulse/historique.sqlite-shm,
      ~/Library/Containers/com.isma.essaiwidget.app.widgets,
      ~/Library/Containers/com.isma.essaiwidget.sonde. (02, 13, 17)

## Plus tard

- [ ] Vers le 17/10 : calibrer les seuils des règles 7 (swap) et 10
      (processeur) sur une semaine de journal, `outils/rejoue-seuils.py`.
      Rien à faire pour Isma : la coordination relance le chantier 12. (12)
- [ ] Relecture VoiceOver, 1 min, avec le regard « Animations et thèmes » :
      la coordination lance `swift outils/relecture-ax.swift --attendre 90
      --fichier /tmp/relecture-ax.txt` ; ouvrir le panneau (⌃⌥M) dans les
      90 s, puis ne toucher à rien 2 s. Le script ne clique sur rien. (16)

## Réponses

- [ ] Forfait iPhone : combien de Go par mois, et quel jour il repart à zéro.
      Ou le régler soi-même : carte Réseau → « Régler le forfait iPhone ».
      (07)
- [ ] D'accord pour que Pulse regarde toutes les 30 min, via Spotlight, ce
      qui arrive sur les disques externes ? macOS peut demander une fois
      l'accès aux volumes amovibles : « Autoriser ». En attendant,
      `--probe --remplissage` fait la requête depuis le terminal. (05)
- [ ] Facultatif, extras (tous éteints) : quelles personnes suivre dans les
      horloges, et leur ville ? (ou Réglages › Horloges › « Ajouter une
      personne »). Ta ville pour le soleil et la météo, déduite
      du fuseau du Mac, c'est juste ? Veux-tu le Calendrier (macOS demandera
      l'accès une fois) et la Météo (ta ville part vers api.open-meteo.com) ?
      Chaque carte s'allume dans Réglages › la carte. (18)
- [ ] Essai des ventilateurs : regarder le compteur « écriture(s) sur 60 »
      en mode Courbe. Chaque pas de 5 % coûte 2 écritures ; s'il s'épuise,
      les ventilateurs reviennent en automatique jusqu'au redémarrage. À
      revoir après l'essai. (14, 17)
- [ ] Mode de langage Swift 6 : une session dédiée, le jour venu ; en
      l'état, il ferait planter le helper au lieu de rendre la main à
      macOS. (17)
- [ ] Après le choix A/B du rangement : une ligne dans
      PopoverView.historyOwners pour que le dépliant Export ne fasse plus
      passer le panneau à trois colonnes. (17)
