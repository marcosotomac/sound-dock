#!/bin/bash
# Builds a release Mezcla.app into ./build.
#
#   scripts/build-app.sh            # sign with Apple Development / Developer ID, the local signing certificate, or ad hoc
#   CODESIGN_IDENTITY="…" scripts/build-app.sh
#   scripts/build-app.sh --install  # also replace /Applications/Mezcla.app and relaunch it
#
# Ad-hoc signatures change on every build, so macOS asks for the audio permission again after each one;
# a certificate (even the local self-signed one) keeps the permission.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Mezcla.app"
APPEX="$APP/Contents/PlugIns/MezclaSafari.appex"
FLAGS=(--configuration release --arch arm64)

for product in Mezcla MezclaBridge MezclaSafariExtension; do
    swift build "${FLAGS[@]}" --product "$product"
done
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"

# App and its Chromium bridge
cp "$BIN/Mezcla" "$APP/Contents/MacOS/Mezcla"
cp "$BIN/MezclaBridge" "$APP/Contents/Helpers/mezcla-bridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
rsync -a --delete --exclude '.DS_Store' BrowserExtension/ "$APP/Contents/Resources/BrowserExtension/"

# Safari web extension: shared page scripts and icons, Safari's own manifest and background page
cp "$BIN/MezclaSafariExtension" "$APPEX/Contents/MacOS/MezclaSafariExtension"
cp Resources/SafariExtension-Info.plist "$APPEX/Contents/Info.plist"
rsync -a --exclude '.DS_Store' SafariExtension/ "$APPEX/Contents/Resources/"
cp BrowserExtension/page-volume.js BrowserExtension/page-bridge.js "$APPEX/Contents/Resources/"
rsync -a BrowserExtension/icons/ "$APPEX/Contents/Resources/icons/"

strip -x "$APP/Contents/MacOS/Mezcla" "$APP/Contents/Helpers/mezcla-bridge" "$APPEX/Contents/MacOS/MezclaSafariExtension"

# Prefer an Apple-issued identity; otherwise the local "Mezcla Local Signing" certificate, whose stable
# designated requirement lets macOS keep the audio permission across builds; otherwise ad hoc.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning | grep -q '"Mezcla Local Signing"'; then
    IDENTITY="Mezcla Local Signing"
fi
SIGN=(codesign --force --sign "${IDENTITY:--}" --timestamp=none)
# Inside out: helpers and plug-ins first, then the app that seals them.
"${SIGN[@]}" --identifier dev.mezcla.bridge "$APP/Contents/Helpers/mezcla-bridge"
"${SIGN[@]}" --entitlements Resources/SafariExtension.entitlements "$APPEX"
"${SIGN[@]}" "$APP"
codesign --verify --strict --deep "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1), signed with ${IDENTITY:-ad hoc identity})"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Mezcla 2>/dev/null || true
    sleep 0.5
    rsync -a --delete "$APP/" /Applications/Mezcla.app/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Mezcla.app
    pluginkit -a /Applications/Mezcla.app/Contents/PlugIns/MezclaSafari.appex
    open /Applications/Mezcla.app
    echo "Installed /Applications/Mezcla.app"
fi
