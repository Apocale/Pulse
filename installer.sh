#!/bin/bash
# Installe Pulse sur ce Mac, ou le met à jour. Dans le Terminal :
#
#   curl -fsSL https://raw.githubusercontent.com/Apocale/Pulse/main/installer.sh | bash
#
# Ce qu'il fait, rien de plus :
#   1. vérifie que ce Mac a une puce Apple (M1 ou plus récente) et macOS 14
#      ou plus récent ;
#   2. télécharge la dernière version de Pulse publiée sur GitHub (2,4 Mo)
#      et vérifie son empreinte et sa signature ;
#   3. la pose dans /Applications (ou ~/Applications si /Applications est
#      fermé à ce compte), à la place d'une version précédente ;
#   4. ouvre Pulse : son icône apparaît en haut à droite, dans la barre de
#      menus.
# Rien d'autre n'est installé, et rien n'est envoyé nulle part.
#
# Pourquoi le Terminal : Pulse n'est pas notarisé par Apple (il faudrait un
# compte développeur payant). Un zip téléchargé par Safari ou Chrome est
# marqué « téléchargé », et macOS refuse alors de l'ouvrir sans un détour par
# Réglages Système › Confidentialité et sécurité › Ouvrir quand même. curl ne
# pose pas cette marque.
#
# Essai sans rien toucher (pour qui maintient Pulse) : PULSE_ESSAI=<dossier>
# installe dans ce dossier, sans fermer ni ouvrir Pulse ; PULSE_SOURCE=<url>
# remplace l'adresse de téléchargement (file:///… pour un zip local).
set -euo pipefail

# Tout tient dans une fonction appelée à la dernière ligne : lu par
# `curl | bash`, le script ne s'exécute qu'une fois reçu en entier.
installe() {
  local depot="${PULSE_DEPOT:-Apocale/Pulse}"
  local base="${PULSE_SOURCE:-https://github.com/$depot/releases/latest/download}"
  local essai="${PULSE_ESSAI:-}"

  [ "$(uname -s)" = Darwin ] || arret "ce n'est pas un Mac."
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] \
    || arret "Pulse demande une puce Apple (M1 ou plus récente) ; ce Mac a un processeur Intel."
  local version
  version=$(sw_vers -productVersion)
  [ "${version%%.*}" -ge 14 ] || arret "Pulse demande macOS 14 Sonoma ou plus récent (ce Mac : macOS $version)."

  local dossier=/Applications
  if [ -n "$essai" ]; then
    dossier="$essai"
  elif [ ! -w "$dossier" ]; then
    dossier="$HOME/Applications"
  fi
  mkdir -p "$dossier"

  temp=$(mktemp -d)
  trap 'rm -rf "$temp"' EXIT

  dit "Téléchargement de Pulse…"
  curl -fsSL "$base/Pulse.zip" -o "$temp/Pulse.zip" \
    || arret "téléchargement impossible. Vérifie la connexion, puis relance la même ligne."
  curl -fsSL "$base/Pulse.zip.sha256" -o "$temp/Pulse.zip.sha256" \
    || arret "empreinte introuvable. Relance la même ligne dans une minute."
  local attendu obtenu
  attendu=$(cut -d' ' -f1 < "$temp/Pulse.zip.sha256")
  obtenu=$(shasum -a 256 "$temp/Pulse.zip" | cut -d' ' -f1)
  [ "$attendu" = "$obtenu" ] || arret "le fichier reçu est abîmé (empreinte différente). Relance la même ligne."

  ditto -x -k "$temp/Pulse.zip" "$temp/app"
  [ -d "$temp/app/Pulse.app" ] || arret "le zip ne contient pas Pulse.app."
  codesign --verify --deep --strict "$temp/app/Pulse.app" 2>/dev/null \
    || arret "la signature de Pulse.app est abîmée."

  # Une version déjà ouverte est fermée avant d'être remplacée. pkill plutôt
  # qu'AppleScript : piloter une app depuis le Terminal ferait demander une
  # autorisation à macOS.
  if [ -z "$essai" ] && pgrep -xq Pulse; then
    dit "Fermeture de la version ouverte…"
    pkill -x Pulse || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Pulse || break; sleep 0.5; done
  fi
  rm -rf "$dossier/Pulse.app"
  ditto "$temp/app/Pulse.app" "$dossier/Pulse.app"

  if [ -n "$essai" ]; then
    dit "Essai : Pulse.app posé dans $dossier, rien n'a été ouvert ni fermé."
    return
  fi
  open "$dossier/Pulse.app"
  dit ""
  dit "Pulse est installé ($dossier/Pulse.app) et ouvert."
  dit "Son icône est en haut à droite de l'écran, dans la barre de menus : clique dessus."
  dit "Raccourci pour l'ouvrir de partout : contrôle + option + M."
}

dit() { printf '%s\n' "$*"; }
arret() { printf '\nPulse n'"'"'est pas installé : %s\n' "$*" >&2; exit 1; }

installe
