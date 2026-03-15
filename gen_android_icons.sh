#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

command -v rsvg-convert >/dev/null 2>&1 || { echo "Error: rsvg-convert not found. Install librsvg (e.g. pacman -S librsvg)."; exit 1; }

for f in "app icon.svg" "app icon without border.svg" "app icon monochrome.svg" "app icon background.svg"; do
  [[ -f "$f" ]] || { echo "Error: source file missing: $f"; exit 1; }
done

RES=android/app/src/main/res

# density -> (launcher_size, adaptive_size)
declare -A LAUNCHER_SIZE=( [mdpi]=48 [hdpi]=72 [xhdpi]=96 [xxhdpi]=144 [xxxhdpi]=192 )
declare -A ADAPTIVE_SIZE=( [mdpi]=108 [hdpi]=162 [xhdpi]=216 [xxhdpi]=324 [xxxhdpi]=432 )

svg_to_png() {
  local src="$1" size="$2" dst="$3"
  rsvg-convert -w "$size" -h "$size" "$src" -o "$dst"
  echo "  -> $dst ($size x $size)"
}

for density in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  dir="$RES/mipmap-$density"
  ls_size=${LAUNCHER_SIZE[$density]}
  ad_size=${ADAPTIVE_SIZE[$density]}

  echo "$density:"
  svg_to_png "app icon.svg"              "$ls_size" "$dir/ic_launcher.png"
  svg_to_png "app icon background.svg"   "$ad_size" "$dir/ic_launcher_background.png"
  svg_to_png "app icon without border.svg" "$ad_size" "$dir/ic_launcher_foreground.png"
  svg_to_png "app icon monochrome.svg"   "$ad_size" "$dir/ic_launcher_monochrome.png"
done

echo "Done."
