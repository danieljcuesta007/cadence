#!/bin/bash
# Turn dist/Cadence.app into a release disk image and point the installers at it.
#   qa/package-app.sh && qa/make-dmg.sh 0.1.0
# Writes dist/Cadence.dmg, records its SHA-256 in Casks/cadence.rb and on the site's
# download section, and prints the publish steps. It never publishes anything itself.
set -euo pipefail
VERSION="${1:?usage: qa/make-dmg.sh <version, e.g. 0.1.0>}"
cd "$(dirname "$0")/.."
APP=dist/Cadence.app
DMG=dist/Cadence.dmg

[[ -d "$APP" ]] || { echo "make-dmg: $APP missing; run qa/package-app.sh first" >&2; exit 1; }

# Never ship the wrong model again: an English-only build went out for six days once.
PIN=$(grep -A2 'fetch ggml-small.bin' models/fetch-models.sh | grep -oE '[0-9a-f]{64}')
MODEL="$APP/Contents/Resources/models/ggml-small.bin"
[[ -f "$MODEL" ]] || { echo "make-dmg: bundled model is not ggml-small.bin (multilingual); refusing" >&2; exit 1; }
[[ "$(shasum -a 256 "$MODEL" | cut -d' ' -f1)" == "$PIN" ]] || { echo "make-dmg: bundled model does not match the pinned hash; refusing" >&2; exit 1; }
for f in LICENSE THIRD_PARTY_NOTICES.md; do
  [[ -f "$APP/Contents/Resources/$f" ]] || { echo "make-dmg: $f missing from the app; repackage" >&2; exit 1; }
done
codesign --verify --deep --strict "$APP" || { echo "make-dmg: app signature does not verify" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp LICENSE THIRD_PARTY_NOTICES.md "$STAGE/"
cat > "$STAGE/Read me first.txt" <<'TXT'
Cadence: dictation that never leaves your Mac.

1. Drag Cadence onto Applications.
2. Open it. macOS will say it can't verify the app: click Done.
   (Cadence isn't notarized: that costs $99 a year, and Cadence is free.)
3. System Settings > Privacy & Security > Security: next to "Cadence was
   blocked", click Open Anyway, then confirm.
4. Allow Microphone and Accessibility when asked.

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
