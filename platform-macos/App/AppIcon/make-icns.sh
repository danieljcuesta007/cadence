#!/bin/zsh
# AppIcon-1024.png (from render-icon.swift) → AppIcon.icns for the bundle.
set -euo pipefail
cd "$(dirname "$0")"
[[ -f AppIcon-1024.png ]] || swift render-icon.swift AppIcon-1024.png

rm -rf AppIcon.iconset
mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
    sips -z $s $s AppIcon-1024.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    d=$((s * 2))
    sips -z $d $d AppIcon-1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
echo "wrote $(pwd)/AppIcon.icns"
