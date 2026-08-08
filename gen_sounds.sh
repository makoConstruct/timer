#!/usr/bin/env bash
set -euo pipefail

# Regenerates the sound assets that aren't committed (assets/sounds/ is
# gitignored), so collaborators can produce the files platform_audio.dart and
# pubspec.yaml expect.

cd "$(dirname "$0")"

SOUNDS=assets/sounds
ANNOUNCEMENT_SRC=$SOUNDS/june_russel_mako_timer_e-piano_1.wav
ANNOUNCEMENT_DST=$SOUNDS/june_russel_mako_timer_e-piano_1.ogg
SILENT_WAV=$SOUNDS/silent.wav
SILENT_OGG=$SOUNDS/silent.ogg

command -v ffmpeg >/dev/null 2>&1 || { echo "Error: ffmpeg not found. Install it (e.g. pacman -S ffmpeg)."; exit 1; }
[[ -f "$ANNOUNCEMENT_SRC" ]] || { echo "Error: source file missing: $ANNOUNCEMENT_SRC"; exit 1; }

# "JR - Announcement". -q:a 5 is what the shipped version was encoded at:
# vorbis, 44100 Hz stereo, ~115 kb/s actual.
ffmpeg -hide_banner -loglevel error -y -i "$ANNOUNCEMENT_SRC" -c:a libvorbis -q:a 5 "$ANNOUNCEMENT_DST"
echo "wrote $ANNOUNCEMENT_DST"

# "Silent". 1.3s of nothing, 48 kHz mono; the ogg is opus at its lowest useful
# bitrate, which lands at well under a kilobyte.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=48000:cl=mono -t 1.3 -c:a pcm_s16le "$SILENT_WAV"
echo "wrote $SILENT_WAV"

ffmpeg -hide_banner -loglevel error -y -i "$SILENT_WAV" -c:a libopus -b:a 6k "$SILENT_OGG"
echo "wrote $SILENT_OGG"
