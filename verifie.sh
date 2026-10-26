#!/bin/bash
# Vérifie tout avant une fusion. C'est lui qui fait foi (docs/chantiers/README.md).
#
#   ./verifie.sh               tout, environ 2 min
#   ./verifie.sh --rapide      sans le banc de 60 s
#   ./verifie.sh --references  régénère les images de référence des cartes
#                              (Tests/References), après un changement VOULU
#
# Rien ne s'ouvre à l'écran : relevé texte (--probe), rendus hors écran
# (--snapshot), banc sans interface (--banc). Rien n'est écrit chez Isma : tout
# tourne sur une copie de ses données, comparée avant et après.
# Sorties et images dans .build/verifie/ et .build/rendus/, à regarder.
#
# Code de sortie : 0 si tout passe, 1 si un seuil casse.
set -uo pipefail
cd "$(dirname "$0")"

rapide=0
references=0
for argument in "$@"; do
  case "$argument" in
    --rapide) rapide=1 ;;
    --references) references=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "option inconnue : $argument (voir ./verifie.sh --help)" >&2; exit 2 ;;
  esac
done

# Régénérer les références : les cartes figées sont rendues sur le relevé
# fixe (`Releve.typique`) et deviennent la nouvelle attente. À regarder avant
# de commiter : une référence fausse ferait passer le défaut qu'elle montre.
if [ $references -eq 1 ]; then
  swift build -c release 2>&1 | grep -E 'error:|Compiling|Build complete' | tail -3 | sed 's/^/  /'
  ./.build/release/Pulse --rendus --references | grep -v '^mesure' | sed 's/^/  /'
  printf '\nImages de Tests/References qui ont changé :\n'
  git status --short --untracked-files=all -- Tests/References | sed 's/^/  /'
  [ -z "$(git status --short --untracked-files=all -- Tests/References)" ] && echo "  aucune"
  printf '\nLes regarder, puis les commiter avec le changement qui les explique.\n'
  exit 0
fi

sortie=.build/verifie
mkdir -p "$sortie"
rm -f "$sortie"/*.png "$sortie"/*.txt "$sortie"/*.log
echecs=()
debut=$SECONDS

# ── Seuils ────────────────────────────────────────────────────────────────
# Taille du binaire : 1,9 Mo le 11/10 à l'aube, 9,2 Mo à 9 h. Le plafond
# attrape une ressource ou une bibliothèque embarquée par erreur, pas la
# croissance normale du code. Il porte donc sur le code et les données
# (__TEXT, __DATA_CONST, __DATA) du binaire de Pulse.app : 4,0 Mo le 11/10
# (19-suivis). La table des symboles, qui suit le code (~1 octet de nom par
# octet de code en Swift) et ne se charge jamais en mémoire, est imprimée
# sans plafond : la retirer rendrait les rapports de plantage illisibles
# (build.sh). Relever le plafond par palier, quand une croissance est voulue,
# en notant pourquoi.
binaire_max=$((6 * 1000 * 1000))
# Le panneau doit tenir dans l'écran d'Isma : 1329 pt de haut, moins la barre
# de menus (37 pt sur le 16 pouces). Au-delà, macOS le rogne.
hauteur_max=1290
largeur_max=2056

# ── Sortie ────────────────────────────────────────────────────────────────
etape() { printf '\n%s\n' "$1"; }
ok()    { printf '  ok      %s\n' "$1"; }
note()  { printf '          %s\n' "$1"; }
echec() { printf '  ÉCHEC   %s\n' "$1"; echecs+=("$1"); }
# Sans `timeout` sur macOS : perl pose une alarme puis s'efface devant la
# commande. Un relevé coincé sur un volume réseau muet ne bloque pas tout.
borne() { local secondes=$1; shift; perl -e 'alarm shift @ARGV; exec @ARGV' "$secondes" "$@"; }
chrono() { printf '%d s' $((SECONDS - $1)); }
# Une valeur de la ligne « mesure clé=valeur … » que rendent --banc et --rendus.
champ() { sed -n 's/.* '"$1"'=\([^ ]*\).*/\1/p' "$2" | tail -1; }
au_dessus() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
en_pct() { awk -v f="$1" 'BEGIN { printf "%.2f", f * 100 }' | tr . ,; }

pulse=./.build/release/Pulse

# ── 1. Compilation ───────────────────────────────────────────────────────
etape "Compilation (./build.sh)"
t=$SECONDS
# Les couleurs ANSI du compilateur retirées : le journal se lit et se cherche.
sans_couleurs() { sed $'s/\x1b\\[[0-9;]*m//g'; }
if ./build.sh 2>&1 | sans_couleurs > "$sortie/build.log"; then
  ok "Pulse.app compilé et signé ($(chrono $t))"
  avertissements=$(grep -cE '\.swift:[0-9]+:[0-9]+: warning:' "$sortie/build.log" || true)
  [ "$avertissements" -gt 0 ] && note "$avertissements avertissement(s) du compilateur : $sortie/build.log"
else
  echec "compilation"
  grep -E '\.swift:[0-9]+:[0-9]+: error:' "$sortie/build.log" | sort -u | head -10 | sed 's/^/          /'
  note "journal complet : $sortie/build.log"
  printf '\nRien d'"'"'autre ne peut se vérifier sans binaire.\n'
  exit 1
fi

# Le binaire installé : celui du bundle, carte de débogage retirée (build.sh).
installe=Pulse.app/Contents/MacOS/Pulse
taille=$(stat -f %z "$installe")
code=$(size -m "$installe" | awk '/^Segment __(TEXT|DATA_CONST|DATA):/ { s += $3 } END { print s + 0 }')
en_mo() { awk -v o="$1" 'BEGIN { printf "%.1f", o / 1e6 }' | tr . ,; }
detail="$(en_mo "$taille") Mo, dont code et données $(en_mo "$code") Mo, symboles et signature $(en_mo $((taille - code))) Mo"
if [ "$code" -gt 0 ] && [ "$code" -le "$binaire_max" ]; then
  ok "binaire : $detail (plafond $((binaire_max / 1000000)) Mo de code et données)"
else
  echec "binaire : $detail — au-dessus du plafond de $((binaire_max / 1000000)) Mo de code et données"
fi
[ -d Pulse.app.dSYM ] || note "Pulse.app.dSYM absent : les rapports de plantage n'auront pas les lignes (build.sh)"

# ── Une maison de rechange ───────────────────────────────────────────────
# Tests, relevé, rendus et banc tournent avec une COPIE des données de Pulse,
# dans un dossier personnel de rechange (CFFIXED_USER_HOME : Application
# Support et Préférences y sont redirigés). Les données d'Isma ne peuvent pas
# être touchées, et toute écriture se voit : la copie est comparée avant et
# après. Les caches d'Adobe restent les vrais, par un lien : la section
# Incidents les lit, rien n'y est jamais écrit.
maison="$PWD/$sortie/maison"
[ -L "$maison/Library/Caches/Adobe" ] && rm "$maison/Library/Caches/Adobe"
rm -rf "$maison"
mkdir -p "$maison/Library/Application Support" "$maison/Library/Preferences" "$maison/Library/Caches"
[ -d "$HOME/Library/Application Support/Pulse" ] \
  && cp -Rp "$HOME/Library/Application Support/Pulse" "$maison/Library/Application Support/"
[ -d "$HOME/Library/Caches/Adobe" ] && ln -s "$HOME/Library/Caches/Adobe" "$maison/Library/Caches/Adobe"
# Ce que Pulse pourrait écrire : ses données et ses préférences. SwiftPM range
# ses propres caches à côté (.swiftpm, Library/Caches) : ils ne comptent pas.
# Sauf les index `-shm` des bases SQLite : un lecteur d'une base en WAL y
# écrit ses marques de lecture, même ouvert en lecture seule — ce n'est pas
# une donnée, et la base se lit ainsi chez tout lecteur (relevé le 11/10 par
# le chantier 04 sur `historique.sqlite-shm`). Le `-wal`, lui, compte : un
# lecteur n'y écrit jamais.
inventaire() {
  (cd "$maison" && find "Library/Application Support" "Library/Preferences" -type f \
     ! -name '*-shm' -exec md5 -r {} + 2>/dev/null | sort -k2)
}
inventaire > "$sortie/maison-avant.txt"
# Chaque lancement de Pulse et des tests passe par là, jamais le reste.
pulse_ici=(env CFFIXED_USER_HOME="$maison" "$pulse")

# ── 2. Tests ─────────────────────────────────────────────────────────────
etape "Tests (swift test)"
t=$SECONDS
if env CFFIXED_USER_HOME="$maison" swift test 2>&1 | sans_couleurs > "$sortie/tests.log"; then
  bilan=$(grep -E 'Test run with [0-9]+ tests? .*passed' "$sortie/tests.log" | tail -1 \
          | sed -E 's/.*with ([0-9]+) tests? in ([0-9]+) suites?.*/\1 tests, \2 suites/')
  ok "${bilan:-tests passés} ($(chrono $t))"
else
  echec "swift test"
  grep -E '✘|↳|error:' "$sortie/tests.log" | grep -v 'Test run with\|Suite .* failed\|Testing Library\|Target Platform' | head -14 | sed 's/^/          /'
  note "journal complet : $sortie/tests.log"
fi

# ── 3. Relevé et rendus, en parallèle ────────────────────────────────────
# Trois processus indépendants : le relevé texte et les deux rendus. Chacun
# tourne quelques secondes de vrai Sampler, écriture coupée.
etape "Relevé (--probe) et rendus hors écran (--snapshot)"
t=$SECONDS
borne 90 "${pulse_ici[@]}" --probe > "$sortie/probe.txt" 2> "$sortie/probe.err" & p_probe=$!
borne 90 "${pulse_ici[@]}" --snapshot "$sortie/sombre.png" > /dev/null 2> "$sortie/sombre.err" & p_sombre=$!
borne 90 "${pulse_ici[@]}" --snapshot "$sortie/clair.png" --light > /dev/null 2> "$sortie/clair.err" & p_clair=$!
wait $p_probe;  r_probe=$?
wait $p_sombre; r_sombre=$?
wait $p_clair;  r_clair=$?

if [ $r_probe -ne 0 ]; then
  echec "--probe a échoué (code $r_probe)"
  head -5 "$sortie/probe.err" | sed 's/^/          /'
else
  manquantes=()
  for section in "MÉMOIRE" "PROCESSEUR" "GPU" "VERDICT" "RÉSEAU" "VOLUMES"; do
    grep -q "^$section" "$sortie/probe.txt" || manquantes+=("$section")
  done
  if [ ${#manquantes[@]} -gt 0 ]; then
    echec "--probe : section(s) absente(s) : ${manquantes[*]}"
  elif ! grep -q "règle retenue" "$sortie/probe.txt"; then
    echec "--probe : pas de verdict"
  else
    ok "--probe : $(grep -c '' "$sortie/probe.txt") lignes, $(grep -c '^[A-ZÉÈÀ]' "$sortie/probe.txt") sections"
    note "$(grep 'phrase' "$sortie/probe.txt" | head -1 | sed 's/^ *//')"
  fi
  [ -s "$sortie/probe.err" ] && note "sortie d'erreur non vide : $sortie/probe.err"
fi

for apparence in sombre clair; do
  code=$([ $apparence = sombre ] && echo $r_sombre || echo $r_clair)
  image="$sortie/$apparence.png"
  if [ "$code" -ne 0 ] || [ ! -s "$image" ]; then
    echec "rendu $apparence (code $code)"
    head -5 "$sortie/$apparence.err" | sed 's/^/          /'
    continue
  fi
  # Rendu à l'échelle 2 : deux pixels par point.
  l=$(( $(sips -g pixelWidth "$image" | awk '/pixelWidth/ { print $2 }') / 2 ))
  h=$(( $(sips -g pixelHeight "$image" | awk '/pixelHeight/ { print $2 }') / 2 ))
  if [ "$h" -gt "$hauteur_max" ] || [ "$l" -gt "$largeur_max" ]; then
    echec "rendu $apparence : $l × $h pt, plus grand que l'écran ($largeur_max × $hauteur_max pt utiles)"
  else
    ok "rendu $apparence : $l × $h pt → $image"
  fi
done
note "($(chrono $t)) Regarder les deux rendus avant de fusionner."

# ── Rendus figés ─────────────────────────────────────────────────────────
# Les cartes du socle sur un relevé fixe, sombre et clair, comparées pixel à
# pixel à Tests/References (tolérance mesurée : voir `Rendu`). Une carte qui
# mesure la machine elle-même est rendue, pas comparée.
etape "Rendus figés comparés aux références (--rendus)"
borne 90 "${pulse_ici[@]}" --rendus > "$sortie/rendus.txt" 2>&1
r_rendus=$?
compte=$(champ rendus "$sortie/rendus.txt" 2>/dev/null)
if [ $r_rendus -eq 0 ]; then
  ok "${compte:-?} rendus identiques à leur référence → .build/rendus/"
  grep '^rendues sans comparaison' "$sortie/rendus.txt" | sed 's/^/          /'
else
  echec "rendus figés : $(champ ecarts "$sortie/rendus.txt" 2>/dev/null || echo '?') écart(s)"
  grep '^ÉCHEC' "$sortie/rendus.txt" | sed 's/^ÉCHEC   /          /' | head -10
  note "voulu ? ./verifie.sh --references, regarder les images, les commiter"
fi

# ── Le panneau tient dans l'écran d'Isma ─────────────────────────────────
# Relevé figé, sept cartes + forfait, puis + Médias, sombre et clair : trop
# haut, le panneau prend une colonne de plus (`PanelFit`, chantier 01).
etape "Le panneau tient dans l'écran d'Isma (--ajuste)"
if borne 90 "${pulse_ici[@]}" --ajuste "$sortie/ajuste" > "$sortie/ajuste.txt" 2>&1; then
  grep -E '^ok' "$sortie/ajuste.txt" | sed -E 's/^ok +/  ok      /; s/ → \/.*$//'
else
  echec "panneau plus grand que l'écran d'Isma"
  grep -E '^ÉCHEC' "$sortie/ajuste.txt" | sed -E 's/^ÉCHEC +/          /; s/ → \/.*$//' | head -4
fi

# ── 4. Contraste ─────────────────────────────────────────────────────────
etape "Contraste des teintes de Palette (seuil 3:1)"
# Chaque couleur de `Palette` qui peut coder une donnée doit être mesurée par
# outils/contraste.swift, et sous la même définition (règle dure n°4). Hors
# mesure, par nature : les fonds (panel, card), le décor (track), l'accent
# réservé aux contrôles (interactive), et `adaptiveWarning`, la couleur
# AppKit derrière `warning`.
palette=Sources/Pulse/UI/Palette.swift
hors_mesure=" panel card track interactive adaptiveWarning "
declarees=$(sed -nE 's/^ *(static|nonisolated static) (let|var) ([A-Za-z]+) *=.*/\3/p' "$palette" | sort -u)
mesurees=$(grep -oE '\("[A-Za-z]+", ' outils/contraste.swift | tr -d '(", ' | sort -u)
non_mesurees=()
for nom in $declarees; do
  case "$hors_mesure" in *" $nom "*) continue ;; esac
  grep -qx "$nom" <<< "$mesurees" || non_mesurees+=("$nom")
done
# Même définition des deux côtés, quand elle est une couleur système
# (« .systemBlue ») : une teinte changée dans Palette et pas dans l'outil
# serait mesurée sur l'ancienne.
divergentes=()
while read -r nom valeur; do
  [ -n "$nom" ] || continue
  outil=$(grep -oE "\(\"$nom\", [^)]+\)" outils/contraste.swift | sed -E 's/.*", (.*)\)/\1/')
  if [ -n "$outil" ] && [ "${outil:0:1}" = "." ] && [ "$outil" != "$valeur" ]; then
    divergentes+=("$nom ($valeur dans Palette, $outil dans l'outil)")
  fi
done < <(sed -nE 's/^ *static let ([A-Za-z]+) = Color\(nsColor: (\.[A-Za-z]+)\).*/\1 \2/p' "$palette")
if [ ${#non_mesurees[@]} -gt 0 ]; then
  echec "teinte(s) de Palette que outils/contraste.swift ne mesure pas : ${non_mesurees[*]}"
  note "l'ajouter à la liste « tints » de l'outil, ou à « hors_mesure » ici si elle ne code aucune donnée"
fi
if [ ${#divergentes[@]} -gt 0 ]; then
  echec "définition différente dans Palette et dans l'outil : ${divergentes[*]}"
fi
[ ${#non_mesurees[@]} -eq 0 ] && [ ${#divergentes[@]} -eq 0 ] \
  && ok "les $(wc -w <<< "$mesurees" | tr -d ' ') teintes de données de Palette sont toutes mesurées, sous la même définition"
if [ -s "$sortie/sombre.png" ] && [ -s "$sortie/clair.png" ]; then
  if swift outils/contraste.swift "$sortie/sombre.png" "$sortie/clair.png" > "$sortie/contraste.txt" 2>&1; then
    plus_bas=$(grep -oE '[0-9]+\.[0-9]+:1' "$sortie/contraste.txt" | sort -t: -k1 -g | head -1 | tr . ,)
    ok "toutes les teintes à 3:1 ou plus, la plus basse à $plus_bas"
  else
    echec "contraste sous 3:1"
    grep -E 'SOUS|carte|error' "$sortie/contraste.txt" | sed 's/^/          /'
  fi
else
  echec "contraste : rendus absents"
fi

# ── 5. Rien d'écrit ──────────────────────────────────────────────────────
# Avant le banc : lui écrit, dans la maison de rechange, comme l'app.
etape "Données de Pulse intactes après tests, relevé et rendus"
inventaire > "$sortie/maison-apres.txt"
if diff -q "$sortie/maison-avant.txt" "$sortie/maison-apres.txt" > /dev/null; then
  ok "aucune écriture ($(grep -c '' "$sortie/maison-avant.txt") fichiers comparés, empreintes MD5)"
else
  echec "écriture dans les données de Pulse malgré la persistance coupée"
  # Ligne « empreinte chemin » ; le chemin gardé entier (« Application
  # Support » a une espace).
  awk 'NR == FNR { avant[substr($0, 34)] = $1; next }
       { chemin = substr($0, 34); apres[chemin] = $1 }
       END {
         for (c in apres) if (!(c in avant)) print "          créé :    " c
           else if (avant[c] != apres[c]) print "          modifié : " c
         for (c in avant) if (!(c in apres)) print "          effacé :  " c
       }' "$sortie/maison-avant.txt" "$sortie/maison-apres.txt" | sort | head -10
fi

# ── 6. Banc ──────────────────────────────────────────────────────────────
# Le vrai Sampler 60 s : fermé, ouvert hors écran, refermé. Persistance
# ACTIVE (--ecrit), comme dans l'app : l'historique s'écrit, dans la maison
# de rechange seulement — le banc refuse --ecrit ailleurs. Le budget estimé
# compte l'icône de barre, que le banc ne peut pas afficher (voir Banc.icone).
# Panneau fermé, le banc tourne sur les cœurs E comme l'app, et mesure une à
# une les tâches qui reviennent toutes les 1, 2 et 10 min (environ 100 s en tout).
# La machine sert à sept chantiers à la fois : un dépassement est remesuré une
# fois, et le meilleur des deux retenu — une interférence ne fait qu'ajouter.
etape "Banc de 60 s : budget panneau fermé (moins de 1 % d'un cœur)"
if [ $rapide -eq 1 ]; then
  note "sauté (--rapide)"
else
  t=$SECONDS
  banc_ok=1
  borne 150 "${pulse_ici[@]}" --banc 60 --ecrit > "$sortie/banc.txt" 2> "$sortie/banc.err" || banc_ok=0
  estime=$(champ estime "$sortie/banc.txt")
  if [ $banc_ok -eq 1 ] && [ -n "$estime" ] && au_dessus "$estime" 0.01; then
    note "$(en_pct "$estime") % au premier passage : remesuré"
    borne 150 "${pulse_ici[@]}" --banc 60 --ecrit > "$sortie/banc-2.txt" 2>> "$sortie/banc.err" || banc_ok=0
    second=$(champ estime "$sortie/banc-2.txt")
    if [ -n "$second" ] && au_dessus "$estime" "$second"; then
      estime=$second; mv "$sortie/banc-2.txt" "$sortie/banc.txt"
    fi
  fi
  if [ $banc_ok -eq 0 ] || [ -z "$estime" ]; then
    echec "le banc n'a pas abouti"
    head -5 "$sortie/banc.err" | sed 's/^/          /'
  else
    budget=$(champ budget "$sortie/banc.txt")
    installe=$(champ installe "$sortie/banc.txt")
    if au_dessus "$estime" 0.01; then
      echec "budget panneau fermé : $(en_pct "$estime") % d'un cœur estimés, plafond 1 %"
    else
      ok "budget panneau fermé : $(en_pct "$estime") % d'un cœur estimés ($(en_pct "$budget") % au banc, tâches lentes comprises, + l'icône), plafond 1 %"
    fi
    # Mesuré sur les cœurs E, comme l'app panneau fermé : sur les cœurs P, le
    # même travail coûte deux fois moins et le banc se croyait large
    # (15-audit-perf). Les tâches lentes (1, 2 et 10 min) mesurées une à une.
    note "dont tâches lentes réparties $(en_pct "$(champ lentes "$sortie/banc.txt")") % ; fermé à $(awk -v f="$(champ coeurs_p "$sortie/banc.txt")" 'BEGIN { printf "%d", f * 100 }') % sur les cœurs P"
    if [ "$installe" != "-" ]; then
      note "Pulse installé, mêmes secondes : $(en_pct "$installe") % (version de main)"
    elif [ "$(champ installe_age "$sortie/banc.txt")" != "-" ] \
         && [ "$(champ installe_age "$sortie/banc.txt")" -lt 120 ]; then
      note "Pulse installé non comparé : relancé il y a $(champ installe_age "$sortie/banc.txt") s, il démarre encore"
    else
      note "Pulse installé non comparé : absent, ou relancé pendant le banc"
    fi

    fenetres=$(champ fenetres "$sortie/banc.txt")
    [ "$fenetres" = "0" ] || echec "le banc a montré $fenetres fenêtre(s) à l'écran"

    memoire=$(champ memoire "$sortie/banc.txt")
    if [ "${memoire:-0}" -gt $((150 * 1024 * 1024)) ]; then
      echec "mémoire après fermeture : $((memoire / 1048576)) Mo, plafond 150 Mo"
    else
      ok "mémoire après fermeture : $((memoire / 1048576)) Mo · ouvert : $(en_pct "$(champ ouvert "$sortie/banc.txt")") % d'un cœur · $(champ reveils "$sortie/banc.txt" | tr . ,) réveils/s fermé"
    fi
    chaud=$(champ creation_chaud_ms "$sortie/banc.txt")
    if [ "${chaud:-0}" -gt 400 ]; then
      echec "panneau créé en $chaud ms à chaud, plafond 400 ms"
    else
      ok "panneau créé en $(champ creation_ms "$sortie/banc.txt") ms à froid, $chaud ms à chaud"
    fi
    # Un panneau refermé qui coûte plus qu'avant son ouverture : son contenu
    # n'a pas été libéré (le défaut du 09/10, 8,2 % au lieu de 2,1 %).
    if au_dessus "$(champ referme "$sortie/banc.txt")" "$(awk -v f="$(champ ferme "$sortie/banc.txt")" 'BEGIN { print f * 1.5 + 0.002 }')"; then
      note "refermé ($(en_pct "$(champ referme "$sortie/banc.txt")") %) au-dessus de fermé ($(en_pct "$(champ ferme "$sortie/banc.txt")") %) : contenu non libéré ? Voir $sortie/banc.txt"
    fi
  fi
  note "($(chrono $t)) détail : $sortie/banc.txt"
fi

# ── Bilan ────────────────────────────────────────────────────────────────
printf '\n'
if [ ${#echecs[@]} -eq 0 ]; then
  printf 'TOUT PASSE en %d s.\n' $((SECONDS - debut))
  exit 0
fi
printf '%d ÉCHEC(S) en %d s :\n' ${#echecs[@]} $((SECONDS - debut))
for e in "${echecs[@]}"; do printf '  - %s\n' "$e"; done
exit 1
