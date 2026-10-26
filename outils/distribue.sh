#!/bin/bash
# Fabrique la version de Pulse à envoyer à quelqu'un d'autre.
#
#   outils/distribue.sh      → .build/distribution/Pulse.zip et son empreinte
#
# - Compilée À PART (PULSE_APP) : le ./Pulse.app du dépôt, celui qui tourne
#   chez Isma, n'est pas touché.
# - Sans le helper des ventilateurs (PULSE_SANS_HELPER) : leur réglage n'a
#   jamais été essayé sur un vrai Mac, il ne part pas sur celui d'un autre.
# - Zippée par ditto, qui garde la signature : un zip fait autrement (zip -r)
#   peut perdre des attributs, et macOS dirait alors l'app « endommagée ».
# - Revérifiée après un aller-retour : le zip est extrait ailleurs, sa
#   signature relue, puis marqué « téléchargé » (quarantaine) comme le ferait
#   Safari, pour lire ce que Gatekeeper en pense.
#
# Le zip ne contient que Pulse.app : aucune donnée, aucun réglage. Chez
# l'autre, Pulse part de zéro (~/Library/Application Support/Pulse est créé
# au premier lancement).
set -euo pipefail
cd "$(dirname "$0")/.."

sortie=.build/distribution
rm -rf "$sortie"
mkdir -p "$sortie"

PULSE_APP="$sortie/Pulse.app" PULSE_SANS_HELPER=1 ./build.sh >/dev/null
app="$sortie/Pulse.app"

if [ -e "$app/Contents/MacOS/PulseHelper" ]; then
  echo "distribue.sh : le helper des ventilateurs est dans le bundle, rien n'est zippé." >&2
  exit 1
fi
codesign --verify --deep --strict "$app"

# Le dSYM reste à côté, hors du zip : il ne sert qu'à lire un rapport de
# plantage, ici.
ditto -c -k --sequesterRsrc --keepParent "$app" "$sortie/Pulse.zip"

essai=$(mktemp -d)
trap 'rm -rf "$essai"' EXIT
ditto -x -k "$sortie/Pulse.zip" "$essai"
codesign --verify --deep --strict "$essai/Pulse.app"
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$essai/Pulse.app"
gatekeeper=$(spctl --assess --type execute "$essai/Pulse.app" 2>&1 | sed 's|^.*Pulse\.app: ||' || true)

empreinte=$(shasum -a 256 "$sortie/Pulse.zip" | cut -d' ' -f1)
echo "$empreinte  Pulse.zip" > "$sortie/Pulse.zip.sha256"
taille=$(stat -f %z "$sortie/Pulse.zip")

echo "→ $(pwd)/$sortie/Pulse.zip ($(awk -v o="$taille" 'BEGIN { printf "%.1f", o / 1e6 }' | tr . ,) Mo)"
echo "  SHA-256 $empreinte"
echo "  signature ad hoc intacte après dézippage ; sans le helper des ventilateurs"
echo "  Gatekeeper, téléchargé par un navigateur : ${gatekeeper:-accepté}"
echo "  (attendu : refusé — app non notarisée. D'où l'installation par le Terminal,"
echo "   dont curl ne pose pas la quarantaine, ou « Ouvrir quand même ».)"
