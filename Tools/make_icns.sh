#!/bin/bash
# Rebuilds Resources/AppIcon.icns from Resources/AppIcon.png.
set -euo pipefail
cd "$(dirname "$0")/.."
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" \
            "512 icon_512x512" "1024 icon_512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" Resources/AppIcon.png --out "$SET/$2.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
