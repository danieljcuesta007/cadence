#!/bin/zsh
# Assemble Cadence.app from the release build: a real menu-bar app the user can keep in
# ~/Applications, launch by double-click, and grant mic/Accessibility to under the name
# "Cadence" (instead of the terminal). Ad-hoc signed so TCC grants survive rebuilds of
# unchanged code paths; a Developer ID comes later (§ distribution).
#
# Usage: qa/package-app.sh [--install]   (--install copies to ~/Applications and opens it)
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=platform-macos/.build/release/cadence
MODEL=models/artifacts/ggml-base.en.bin
APP=dist/Cadence.app

[[ -x "$BIN" ]] || { echo "build first: qa/build-shell.sh" >&2; exit 1; }
[[ -f "$MODEL" ]] || { echo "model missing: run models/fetch-models.sh" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/models"

cp "$BIN" "$APP/Contents/MacOS/Cadence"
cp "$MODEL" "$APP/Contents/Resources/models/"
cp platform-macos/App/AppIcon/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>        <string>Cadence</string>
    <key>CFBundleIdentifier</key>        <string>dev.cadence.app</string>
    <key>CFBundleName</key>              <string>Cadence</string>
    <key>CFBundleDisplayName</key>       <string>Cadence</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- Menu-bar agent: no Dock icon, no app switcher entry (§12: invisible until used). -->
    <key>LSUIElement</key>               <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Cadence listens only while you hold the dictation key, and transcribes entirely on this Mac.</string>
    <key>NSHumanReadableCopyright</key>  <string>© 2026 Daniel Cuesta</string>
</dict>
</plist>
PLIST

# Prefer the stable self-signed identity (qa/setup-signing.sh): its designated
# requirement pins the certificate, so TCC grants survive rebuilds. Ad-hoc fallback
# resets grants on every build — dev convenience only.
IDENTITY="Cadence Dev Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier dev.cadence.app "$APP"
    SIGNED="$IDENTITY"
else
    echo "note: stable identity missing (run qa/setup-signing.sh) — ad-hoc signing," >&2
    echo "      TCC grants will reset on every rebuild" >&2
    codesign --force --sign - --identifier dev.cadence.app "$APP"
    SIGNED="ad-hoc"
fi

echo "packaged: $APP"
codesign --verify --deep --strict "$APP" && echo "signature: OK ($SIGNED)"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/Cadence.app
    cp -R "$APP" ~/Applications/
    echo "installed: ~/Applications/Cadence.app"
    open ~/Applications/Cadence.app
fi
