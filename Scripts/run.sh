#!/bin/bash
# Compile Capri en mode release, l'emballe dans un petit Capri.app, puis le lance.
#
# Pourquoi un .app et pas juste le binaire ? Plus tard (étape 3), macOS demandera des
# permissions (Rappels…) et on voudra « Ouvrir au démarrage » : tout ça exige une vraie app
# avec un identifiant (bundle id) et une signature.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Compilation (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Capri.app"
echo "▸ Assemblage de $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Capri" "$APP/Contents/MacOS/Capri"
# Le bundle de ressources (les sprites) créé par SwiftPM, rangé dans Contents/Resources.
cp -R "$BIN_DIR/Capri_Capri.bundle" "$APP/Contents/Resources/"
# Copie de secours de sa personnalité (l'app lit en priorité Persona/capri.md du projet).
cp Persona/capri.md "$APP/Contents/Resources/capri.md"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>         <string>Capri</string>
    <key>CFBundleIdentifier</key>         <string>com.dan13615.capri</string>
    <key>CFBundleName</key>               <string>Capri</string>
    <key>CFBundleDisplayName</key>        <string>Capri</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <!-- Capri parle français : macOS lui donne aussi les noms d'apps en français (« Calculette »). -->
    <key>CFBundleDevelopmentRegion</key>  <string>fr</string>
    <key>CFBundleLocalizations</key>      <array><string>fr</string></array>
    <key>NSHighResolutionCapable</key>    <true/>
    <!-- Pas d'icône dans le Dock : Capri vit sur le bureau et dans la barre des menus. -->
    <key>LSUIElement</key>                <true/>
    <!-- Les textes des fenêtres d'autorisation de macOS (affichés la première fois). -->
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Capri lit ton agenda pour te prévenir de tes rendez-vous, et y crée les rappels que tu lui demandes.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Capri peut chercher et lire les fichiers de ton Bureau quand tu le lui demandes (sans jamais les modifier).</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Capri peut chercher et lire tes Documents quand tu le lui demandes (sans jamais les modifier).</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Capri peut chercher et lire tes Téléchargements quand tu le lui demandes (sans jamais les modifier).</string>
    <!-- Où est le projet : l'app y relit Persona/capri.md à chaque message. -->
    <key>CapriProjectPath</key>           <string>$(pwd)</string>
</dict>
</plist>
PLIST

# Signature : l'identité stable « Capri Dev » si elle existe (voir Scripts/create-signing-identity.sh),
# sinon « ad hoc » (-). Avec « ad hoc », macOS peut redemander les autorisations après chaque compilation.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Capri Dev"'; then
    echo "▸ Signature avec « Capri Dev »"
    codesign --force --sign "Capri Dev" "$APP"
else
    echo "▸ Signature ad hoc (lance Scripts/create-signing-identity.sh pour garder les autorisations)"
    codesign --force --sign - "$APP"
fi

# Si une ancienne Capri tourne encore, on la ferme avant de relancer.
pkill -x Capri 2>/dev/null && sleep 0.5 || true

echo "▸ Lancement"
open "$APP"
