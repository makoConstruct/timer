#!/usr/bin/env bash
# Regenerate the website's favicon set from the app icon.
# Requires: rsvg-convert (librsvg) and magick (ImageMagick).
#
#   ./website/gen_favicons.sh
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/../app icon.svg"
out="$here/out"           # deploy dir

mkdir -p "$out"
cd "$out"

# Crisp PNGs rendered straight from the SVG at each target size.
for s in 16 32 48 180 192; do
  rsvg-convert -w "$s" -h "$s" "$src" -o "favicon-$s.png"
done

cp "$src" favicon.svg                 # scalable favicon for modern browsers
mv favicon-180.png apple-touch-icon.png   # iOS home screen
mv favicon-192.png icon-192.png           # Android home screen / hi-res

# Multi-resolution .ico for legacy browsers.
magick favicon-16.png favicon-32.png favicon-48.png favicon.ico

rm -f favicon-48.png                  # only needed inside the .ico

echo "Generated: favicon.ico favicon.svg favicon-16.png favicon-32.png apple-touch-icon.png icon-192.png"
