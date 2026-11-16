#!/usr/bin/env bash
# Régénère les icônes OpenAguja depuis assets/brand/openaguja-icon.svg :
#   - ios/OpenAguja/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024², sans alpha)
#   - assets/brand/favicon-64.png
#   - assets/brand/icon-512.png
# Prérequis : rsvg-convert (brew install librsvg) et ImageMagick (brew install imagemagick).
set -euo pipefail
cd "$(dirname "$0")/.."

SVG=assets/brand/openaguja-icon.svg
ICONSET=ios/OpenAguja/Assets.xcassets/AppIcon.appiconset/AppIcon.png
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

command -v rsvg-convert >/dev/null || { echo "rsvg-convert absent (brew install librsvg)" >&2; exit 1; }
command -v magick >/dev/null || { echo "magick absent (brew install imagemagick)" >&2; exit 1; }

render() { # $1 = taille, $2 = destination
    rsvg-convert -w "$1" -h "$1" "$SVG" -o "$TMP/in.png"
    magick "$TMP/in.png" -background '#1A1E23' -alpha remove -alpha off "$2"
}

render 1024 "$ICONSET"
render 64 assets/brand/favicon-64.png
render 512 assets/brand/icon-512.png

echo "icônes régénérées :"
file "$ICONSET" assets/brand/favicon-64.png assets/brand/icon-512.png
