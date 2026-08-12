#!/usr/bin/env bash
set -euo pipefail

# Regenerates the sound assets that aren't committed (they're gitignored), so
# collaborators can produce the files platform_audio.dart and pubspec.yaml
# expect.
#
# Everything ships as 16-bit PCM wav. iOS accepts nothing else as a notification
# sound, so one wav serves both in-app playback and the alarm notification,
# where an ogg could serve neither. The whole sound payload lands under a
# megabyte, against ~8.5MB of fonts. — Opus 5

cd "$(dirname "$0")"

SOUNDS=assets/sounds
SILENT_WAV=$SOUNDS/silent.wav

command -v ffmpeg >/dev/null 2>&1 || {
  echo "Error: ffmpeg not found. Install it (e.g. pacman -S ffmpeg, brew install ffmpeg)."
  exit 1
}

# "Silent". 1.3s of nothing, 48 kHz mono.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=48000:cl=mono \
  -t 1.3 -c:a pcm_s16le "$SILENT_WAV"
echo "wrote $SILENT_WAV"

# Kenney's jingles only reached us as vorbis, so their wavs are decoded from the
# committed oggs rather than being masters of their own. "JR - Announcement"
# needs no step here: its wav is the committed master. — Opus 5
for n in jingles_STEEL15 jingles_STEEL16; do
  [[ -f "$SOUNDS/$n.ogg" ]] || {
    echo "Error: source file missing: $SOUNDS/$n.ogg"
    exit 1
  }
  ffmpeg -hide_banner -loglevel error -y -i "$SOUNDS/$n.ogg" \
    -c:a pcm_s16le "$SOUNDS/$n.wav"
  echo "wrote $SOUNDS/$n.wav"
done
