#!/bin/bash
# Turn dist/Cadence.app into a release disk image and point the installers at it.
#   qa/package-app.sh && qa/make-dmg.sh 0.1.0
# Writes dist/Cadence.dmg, records its SHA-256 in Casks/cadence.rb and on the site's
# download section, and prints the publish steps. It never publishes anything itself.
set -euo pipefail
VERSION="${1:?usage: qa/make-dmg.sh <version, e.g. 0.1.0>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "make-dmg: version must look like 0.1.0 (no leading v)" >&2; exit 1; }
cd "$(dirname "$0")/.."
APP=dist/Cadence.app
DMG=dist/Cadence.dmg

[[ -d "$APP" ]] || { echo "make-dmg: $APP missing; run qa/package-app.sh first" >&2; exit 1; }

# Never ship the wrong model again: an English-only build went out for six days once.
PIN=$(grep -A2 'fetch ggml-small.bin' models/fetch-models.sh | grep -oE '[0-9a-f]{64}' || true)
[[ -n "$PIN" ]] || { echo "make-dmg: no pinned hash for ggml-small.bin found in models/fetch-models.sh" >&2; exit 1; }
MODEL="$APP/Contents/Resources/models/ggml-small.bin"
[[ -f "$MODEL" ]] || { echo "make-dmg: bundled model is not ggml-small.bin (multilingual); refusing" >&2; exit 1; }
[[ "$(shasum -a 256 "$MODEL" | cut -d' ' -f1)" == "$PIN" ]] || { echo "make-dmg: bundled model does not match the pinned hash; refusing" >&2; exit 1; }
for f in LICENSE THIRD_PARTY_NOTICES.md; do
  [[ -f "$APP/Contents/Resources/$f" ]] || { echo "make-dmg: $f missing from the app; repackage" >&2; exit 1; }
done
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ "$APP_VERSION" == "$VERSION" ]] || { echo "make-dmg: the app says version '$APP_VERSION' but you asked for $VERSION; set it in qa/package-app.sh and repackage" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "make-dmg: app signature does not verify" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/LICENSE" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" "$STAGE/"  # the same copies the app ships
cat > "$STAGE/Read me first.txt" <<'TXT'
Cadence: dictation that never leaves your Mac.

1. Drag Cadence onto Applications, eject this disk, and open Cadence from
   Applications (not from this window).
2. macOS will say it can't check or verify the app: click Done (or OK).
   (Cadence isn't notarized: that costs $99 a year, and Cadence is free.)
3. System Settings > Privacy & Security > Security: next to "Cadence was
   blocked", click Open Anyway, then confirm.
   On macOS 14 Sonoma you can instead Control-click Cadence in
   Applications, choose Open, then Open again.
   No Open Anyway button? Paste this into Terminal, then open Cadence:
   xattr -dr com.apple.quarantine /Applications/Cadence.app
4. Allow Microphone and Accessibility when asked.

Optional desktop widget: open Cadence's menu in the menu bar and choose
Show Desktop Widget. Drag it to place it; hide it from that menu or its close
button. Click its logo to open Cadence. It shows today's and this week's
words, streak, pace, time saved and all-time words while Cadence is running.

Hold Right Option, speak, release. More: https://cadence-dictation.pages.dev
TXT

rm -f "$DMG"
hdiutil create -quiet -volname "Cadence" -srcfolder "$STAGE" -format UDZO -fs HFS+ -ov "$DMG"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

sed -i '' -e "s|^  version \".*\"|  version \"$VERSION\"|" -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" Casks/cadence.rb
sed -i '' -E "s|<code data-sha>[^<]*</code>|<code data-sha>$SHA</code>|" site/index.html

cat <<MSG
Built $DMG ($(du -h "$DMG" | cut -f1))
SHA-256 $SHA
Updated Casks/cadence.rb and site/index.html.

To publish (each step is outward-facing; do it on purpose):
  1. git tag v$VERSION && git push origin v$VERSION
  2. gh release create v$VERSION $DMG --title "Cadence $VERSION" --notes-file <notes>
     (keep the asset name Cadence.dmg: the site links to releases/latest/download/Cadence.dmg)
  3. PR the Cask + site checksum change to dev, then dev to main.
  4. Deploy the site: cd site && npm run build && npx wrangler pages deploy dist --project-name cadence-dictation
MSG
