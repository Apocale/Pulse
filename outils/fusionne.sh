#!/bin/bash
# Fusionne une branche de chantier dans main, en avance rapide seulement, puis
# réinstalle Pulse. Un verrou fait passer les chantiers un par un : deux
# ./build.sh dans le même dossier se marcheraient dessus, et un Pulse.app à
# moitié copié ne se lancerait pas.
#
# La vérification se fait SOUS le verrou, dans le worktree de la branche :
# main ne peut plus bouger entre la vérification et la fusion. Avant, avec une
# dizaine de chantiers, main avançait pendant les 3 min de ./verifie.sh et un
# chantier a fini par fusionner sans revérifier (chantier 12). La version
# complète de ./verifie.sh reste à lancer avant, hors verrou.
#
# La relance du Pulse installé est espacée d'au moins 15 min : il redémarrait
# sans cesse, l'icône clignotait chez Isma, et chaque mesure du budget tombait
# dans les premières minutes après un lancement (chantier 03). Le bundle, lui,
# est toujours à jour.
#
# Usage : /Users/isma/Documents/Dashbaord/outils/fusionne.sh chantier/01-socle
set -euo pipefail
branche="${1:?usage : outils/fusionne.sh <branche>}"
depot=/Users/isma/Documents/Dashbaord

# Le corps tourne sous lockf (attente jusqu'à 30 min si une autre fusion est en
# cours). Pas d'apostrophe dans ce bloc : il est entre guillemets simples.
exec /usr/bin/lockf -k -t 1800 /tmp/pulse-fusion.lock /bin/bash -c '
set -euo pipefail
cd "$1"
if [ "$(git branch --show-current)" != main ]; then
  echo "Fusion refusée : le dépôt principal est hors de main." >&2; exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "Fusion refusée : modifications non commitées dans le dépôt principal." >&2; exit 1
fi
if ! git merge-base --is-ancestor main "$2"; then
  echo "Fusion refusée : $2 ne contient pas le dernier main. Lance git merge main, revérifie, recommence." >&2; exit 1
fi
arbre=""
courant=""
while IFS= read -r ligne; do
  case "$ligne" in
    "worktree "*) courant="${ligne#worktree }" ;;
    "branch refs/heads/$2") arbre="$courant" ;;
  esac
done < <(git worktree list --porcelain)
if [ -z "$arbre" ]; then
  echo "Fusion refusée : aucun worktree ne porte $2." >&2; exit 1
fi
if [ -n "$(git -C "$arbre" status --porcelain --untracked-files=no)" ]; then
  echo "Fusion refusée : modifications non commitées dans $arbre." >&2; exit 1
fi
echo "Vérification de $2 sous verrou : ./verifie.sh --rapide dans $arbre"
if ! (cd "$arbre" && ./verifie.sh --rapide); then
  echo "Fusion refusée : ./verifie.sh --rapide échoue sur $2." >&2; exit 1
fi
git merge --ff-only "$2"
./build.sh
derniere=/tmp/pulse-derniere-relance
if [ -f "$derniere" ] && [ $(( $(date +%s) - $(stat -f %m "$derniere") )) -lt 900 ]; then
  echo "→ $2 vérifiée et fusionnée dans main ($(git rev-parse --short HEAD)) ; Pulse.app reconstruit, relance différée (une au plus toutes les 15 min)."
  exit 0
fi
osascript -e "tell application id \"com.isma.pulse\" to quit" >/dev/null 2>&1 || true
sleep 2
open Pulse.app
touch "$derniere"
echo "→ $2 vérifiée et fusionnée dans main ($(git rev-parse --short HEAD)), Pulse réinstallé et relancé."
' fusion "$depot" "$branche"
