#!/bin/sh
# Cadence installer: https://cadence-dictation.pages.dev/install.sh
#   curl -fsSL https://cadence-dictation.pages.dev/install.sh | sh
#
# Read this before you run it. It is short on purpose. It:
#   1. checks this is an Apple silicon Mac on macOS 14 or later,
#   2. downloads one release disk image from GitHub,
#   3. checks it against the SHA-256 printed below and stops if they differ,
#   4. copies Cadence.app into Applications (updating an existing Cadence in place),
#   5. clears macOS's "downloaded from the internet" flag on that one app, and opens it.
# No sudo, no admin rights. It never touches ~/.cadence, where your history and
# settings live, and it only ever replaces an app that is Cadence itself.
# Remove it: quit Cadence and drag it from Applications to the Trash.
set -eu

VERSION="0.1.3"
SHA256="63e315ea93b98916ac648cd7b1d70ad8cfe885bdf94ba031f3dea38cf57c31c1"
URL="${CADENCE_URL:-https://github.com/danieljcuesta007/cadence/releases/download/v$VERSION/Cadence.dmg}"  # override only for testing; the checksum still applies
BUNDLE_ID="dev.cadence.app"

say() { printf 'cadence: %s\n' "$*"; }
die() { printf 'cadence: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Cadence is a Mac app."
# hw.optional.arm64 is 1 on Apple silicon even when Terminal runs under Rosetta.
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ] || die "Cadence needs an Apple silicon Mac (M1 or newer). Nothing was installed."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "Cadence needs macOS 14 Sonoma or later (this Mac has $(sw_vers -productVersion)). Nothing was installed."
for tool in curl shasum hdiutil ditto xattr; do
  command -v "$tool" >/dev/null 2>&1 || die "needs $tool, which every Mac has; is your PATH unusual?"
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/cadence-install.XXXXXX")
mnt="$tmp/mnt"
mounted=0
cleanup() {
  [ "$mounted" = 1 ] && hdiutil detach -quiet -force "$mnt" >/dev/null 2>&1
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

say "downloading Cadence $VERSION (about 450 MB, the speech model comes with it)"
curl -fL --progress-bar "$URL" -o "$tmp/Cadence.dmg" || die "download failed: $URL"

actual=$(shasum -a 256 "$tmp/Cadence.dmg" | cut -d' ' -f1)
[ "$actual" = "$SHA256" ] || die "checksum mismatch (expected $SHA256, got $actual). Nothing was installed."
say "checksum verified"

mkdir "$mnt"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$tmp/Cadence.dmg" || die "could not open the disk image"
mounted=1
src="$mnt/Cadence.app"
[ -d "$src" ] || die "the disk image has no Cadence.app"

bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true; }
[ "$(bundle_id "$src")" = "$BUNDLE_ID" ] || die "the disk image's app is not Cadence ($BUNDLE_ID). Nothing was installed."

# Where to put it: an existing Cadence first (so updates stay where you keep it),
# then /Applications if you can write there, else ~/Applications.
if [ -n "${CADENCE_APPS:-}" ]; then apps="$CADENCE_APPS"
elif [ -d /Applications/Cadence.app ]; then apps=/Applications
elif [ -d "$HOME/Applications/Cadence.app" ]; then apps="$HOME/Applications"
elif [ -w /Applications ]; then apps=/Applications
else apps="$HOME/Applications"
fi
mkdir -p "$apps"
dest="$apps/Cadence.app"

if [ -e "$dest" ]; then
  [ "$(bundle_id "$dest")" = "$BUNDLE_ID" ] || die "$dest is a different app, not Cadence. Move it, then run this again. Nothing was installed."
  if pgrep -f "$dest/Contents/MacOS/" >/dev/null 2>&1; then
    say "quitting the running Cadence to update it"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    i=0
    while pgrep -f "$dest/Contents/MacOS/" >/dev/null 2>&1 && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
    pgrep -f "$dest/Contents/MacOS/" >/dev/null 2>&1 && die "Cadence is still running. Quit it from its menu-bar icon, then run this again. Nothing was changed."
  fi
fi

# Copy beside it first, then swap, so a failed copy never leaves you without Cadence.
rm -rf "$apps/.Cadence.app.new"
ditto "$src" "$apps/.Cadence.app.new" || die "could not copy Cadence into $apps"
xattr -dr com.apple.quarantine "$apps/.Cadence.app.new" 2>/dev/null || true
rm -rf "$dest"
mv "$apps/.Cadence.app.new" "$dest"
say "installed $dest"

if [ "${CADENCE_NO_OPEN:-}" = "1" ]; then
  say "done."
else
  open "$dest"
  say "done. Cadence is in your menu bar; it will ask for Microphone and Accessibility the first time."
fi
