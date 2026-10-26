#!/bin/bash
# Produit <Resources>/Metadata.appintents pour un exécutable construit par
# `swift build -c release` (moteur Swift Build, défaut de SwiftPM 6.x), sans projet
# Xcode. Sans ce dossier, Raccourcis ne voit aucune action App Intents.
#
# Usage : appintents-metadata.sh <dossier .build/release> <module> <Contents/Resources> [cible de déploiement]
#   ex. : appintents-metadata.sh .build/release Pulse Pulse.app/Contents/Resources 14.0
#
# Ce que fait Xcode, refait à la main : swiftc a déjà émis les valeurs constantes
# du module (-emit-const-values -const-gather-protocols-list …, ajoutés d'office
# par Swift Build) ; il reste à lancer appintentsmetadataprocessor dessus, ce que
# SwiftPM ne fait pas pour un exécutable. À appeler AVANT codesign : le dossier
# fait partie des ressources scellées.
set -euo pipefail

RELEASE_DIR="${1:?dossier .build/release}"
MODULE="${2:?nom du module}"
RESOURCES="${3:?dossier Contents/Resources}"
DEPLOY="${4:-14.0}"

DEV="$(xcode-select -p)"
TC="$DEV/Toolchains/XcodeDefault.xctoolchain"
PROC="$TC/usr/bin/appintentsmetadataprocessor"
if [ ! -x "$PROC" ]; then
    # Outils en ligne de commande seuls : l'outil n'existe que dans Xcode.
    echo "avertissement : $PROC absent (Xcode requis), pas d'actions Raccourcis" >&2
    exit 0
fi
# Numéro de build d'Xcode (27A266a) : 5 ms dans version.plist, 0,3 s par xcodebuild.
XCODE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$DEV/../version.plist" 2>/dev/null \
    || xcodebuild -version | awk '/Build version/ {print $3}')"

# .build/release -> out/Products/Release ; les intermédiaires sont sous out/Intermediates.noindex,
# ex. Pulse.build/Release/Pulse-p.build/Objects-normal/arm64/. Le plus récent gagne.
ARCH="$(uname -m)"                                   # SwiftPM construit pour l'hôte
OUT="$(cd -P "$RELEASE_DIR" && pwd)/../.."
LIST="$(ls -t "$OUT"/Intermediates.noindex/*/Release/*/Objects-normal/"$ARCH"/"$MODULE".SwiftFileList 2>/dev/null | head -n 1 || true)"
if [ -z "$LIST" ]; then
    echo "erreur : intermédiaires de $MODULE introuvables sous $OUT/Intermediates.noindex" >&2
    echo "        (build system natif ? il faut le moteur swiftbuild, défaut de SwiftPM 6.x)" >&2
    exit 1
fi
OBJ="$(dirname "$LIST")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/appintents.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Release (WMO) : un seul fichier par module, <Module>-primary.swiftconstvalues.
find "$OBJ" -maxdepth 1 -name '*.swiftconstvalues' > "$WORK/constvalues.txt"
if [ ! -s "$WORK/constvalues.txt" ]; then
    echo "erreur : aucun .swiftconstvalues dans $OBJ" >&2
    exit 1
fi
# Liste des sources : obligatoire et non vide (sinon « Missing value for '--source-files' »).
cp "$LIST" "$WORK/sources.txt"
: > "$WORK/deps.txt"
: > "$WORK/static-deps.txt"

mkdir -p "$RESOURCES"
rm -rf "$RESOURCES/Metadata.appintents"
if ! "$PROC" \
    --toolchain-dir "$TC" \
    --module-name "$MODULE" \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$XCODE_BUILD" \
    --platform-family macOS \
    --deployment-target "$DEPLOY" \
    --target-triple "$ARCH-apple-macos$DEPLOY" \
    --output "$RESOURCES" \
    --source-file-list "$WORK/sources.txt" \
    --swift-const-vals-list "$WORK/constvalues.txt" \
    --metadata-file-list "$WORK/deps.txt" \
    --static-metadata-file-list "$WORK/static-deps.txt" \
    --stringsdata-file "$WORK/ExtractedAppShortcutsMetadata.stringsdata" \
    --deployment-aware-processing \
    --no-app-shortcuts-localization \
    > "$WORK/log.txt" 2>&1; then
    cat "$WORK/log.txt" >&2
    echo "erreur : appintentsmetadataprocessor a échoué" >&2
    exit 1
fi
# Le processeur bavarde même quand tout va bien : ne montrer que le reste (avertissements).
grep -v -E 'Starting appintentsmetadataprocessor export|Writing Metadata.appintents|Metadata root:|skipping writing output' \
    "$WORK/log.txt" >&2 || true

# Module sans aucun App Intent : code 0, rien d'écrit. Ce n'est pas une erreur.
if grep -q 'skipping writing output' "$WORK/log.txt"; then
    echo "→ aucun App Intent dans $MODULE : pas de Metadata.appintents"
    exit 0
fi
if [ ! -f "$RESOURCES/Metadata.appintents/extract.actionsdata" ]; then
    echo "erreur : Metadata.appintents non produit" >&2
    exit 1
fi
echo "→ $RESOURCES/Metadata.appintents"
