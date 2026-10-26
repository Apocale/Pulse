#!/bin/bash
# Construit Pulse.app sans Xcode : SwiftPM compile le binaire, le bundle est
# assemblé à la main puis signé ad hoc (suffisant pour un usage local).
#
# PULSE_APP (facultatif) : où poser le bundle, au lieu de ./Pulse.app — celui
# qui tourne chez Isma. outils/distribue.sh s'en sert pour la version à
# partager, qui ne doit jamais remplacer la sienne.
# PULSE_SANS_HELPER=1 (facultatif) : ne pas embarquer le helper des
# ventilateurs. La page Ventilateurs le dit, et rien ne peut s'installer.
set -euo pipefail
cd "$(dirname "$0")"

APP="${PULSE_APP:-Pulse.app}"
swift build -c release

rm -rf "$APP" "$APP.dSYM"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pulse "$APP/Contents/MacOS/Pulse"
# Symboles (19-suivis). Le binaire de SwiftPM porte une carte de débogage
# (65 000 entrées « stabs », 1,1 Mo) qui renvoie aux fichiers .o de
# .build/ — réécrits à chaque compilation : dans l'app installée, elle ne
# pointe plus sur rien. Elle sert une fois, ici : dsymutil en tire
# Pulse.app.dSYM, à côté du bundle (1 s, ~20 Mo, fichiers et lignes pour
# `atos`), puis elle est retirée (`strip -S`). La table des symboles, elle,
# RESTE : un rapport de plantage nomme chaque fonction au moment du
# plantage, quelle que soit la compilation d'où il vient. `strip -x` la
# retirerait (4,2 Mo au lieu de 8,1) et rendrait illisibles les rapports
# d'une compilation dont le dSYM a été remplacé depuis.
dsymutil .build/release/Pulse -o "$APP.dSYM" || echo "build.sh : dSYM non produit, rien d'autre ne change" >&2
strip -S "$APP/Contents/MacOS/Pulse"
# Chantier 14 : le helper des ventilateurs, EMBARQUÉ et inerte. Il ne
# s'installe (hors du bundle, en root) que sur accord d'Isma, depuis
# Réglages › Ventilateurs ; une recompilation ne touche jamais celui qui
# serait installé.
sans_helper="${PULSE_SANS_HELPER:-0}"
[ "$sans_helper" = 1 ] || cp .build/release/PulseHelper "$APP/Contents/MacOS/PulseHelper"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Pulse</string>
    <key>CFBundleIdentifier</key><string>com.isma.pulse</string>
    <key>CFBundleName</key><string>Pulse</string>
    <key>CFBundleDisplayName</key><string>Pulse</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <!-- Les phrases des actions Raccourcis sont en français (chantier 13). -->
    <key>CFBundleDevelopmentRegion</key><string>fr</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Agent : pas d'icône dans le Dock, pas de basculement d'application. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Carte Calendrier (chantier 18) : macOS montre cette phrase quand Isma
         active la carte. Sans elle, la demande d'accès échoue. -->
    <key>NSCalendarsFullAccessUsageDescription</key><string>Pulse affiche vos prochains événements dans sa carte Calendrier. Rien ne quitte ce Mac.</string>
    <key>NSCalendarsUsageDescription</key><string>Pulse affiche vos prochains événements dans sa carte Calendrier. Rien ne quitte ce Mac.</string>
</dict>
</plist>
PLIST

# Signature ad hoc SANS entitlements, et ce n'est pas un raccourci.
# Activer App Sandbox (com.apple.security.app-sandbox) couperait la lecture de
# /Library/Logs/DiagnosticReports et de ~/Library/Caches/Adobe/…/SentryIO-db,
# donc toute la section Incidents, quels que soient les droits POSIX.
#
# PULSE_IDENTITE (facultatif, chantier 13) : signer avec un certificat de
# développeur — « Apple Development: … », équipe personnelle gratuite — au
# lieu de « - ». Toujours sans entitlements, donc toujours sans sandbox. Il
# donne un Team ID, sans lequel linkd refuse d'exécuter les actions
# Raccourcis (README) : leurs métadonnées ne sont embarquées qu'alors, pour
# qu'une app ad hoc n'affiche pas des actions vouées à échouer.
#
# Les widgets (paquet à part, Widgets/) suivent la même règle : en ad hoc,
# chaque reconstruction change l'empreinte de l'extension sandboxée, à qui
# macOS lie son conteneur — il demanderait à Isma de confirmer à chaque
# fois. Avec une identité stable, l'extension est construite, embarquée et
# signée AVEC ses entitlements (bac à sable, lecture seule du dossier de
# Pulse), puis l'app SANS (pas de --deep, qui les effacerait).
# --timestamp=none : codesign ne sort pas sur Internet.
identite="${PULSE_IDENTITE:--}"
if [ "$identite" != "-" ]; then
  outils/appintents-metadata.sh .build/release Pulse "$APP/Contents/Resources" 14.0
  swift build -c release --package-path Widgets
  appex="$APP/Contents/PlugIns/PulseWidgets.appex"
  mkdir -p "$appex/Contents/MacOS"
  cp Widgets/.build/release/PulseWidgets "$appex/Contents/MacOS/PulseWidgets"
  cp Widgets/Info.plist "$appex/Contents/Info.plist"
  codesign --force --sign "$identite" --timestamp=none --entitlements Widgets/widgets.entitlements "$appex"
fi
# Le helper des ventilateurs d'abord (chantier 14) : code imbriqué, scellé
# ensuite par la signature de l'app. Durci (`--options runtime`), identifiant
# fixe, même identité que l'app.
[ "$sans_helper" = 1 ] || codesign --force --sign "$identite" --timestamp=none --identifier com.isma.pulse.helper --options runtime "$APP/Contents/MacOS/PulseHelper"
codesign --force --sign "$identite" --timestamp=none "$APP"
echo "→ $(pwd)/$APP"
