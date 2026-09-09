#!/usr/bin/env bash
# extract-gif.sh — извлекает короткий GIF из видео (для показа динамики).
# Usage: extract-gif.sh <video_path> <start_HH:MM:SS> <duration_sec> <output.gif>
#
# Двухпроходный palette-based GIF — заметно меньше размер при том же качестве.
# Целевые параметры: 1280×720, FPS=10, дизеринг bayer.

set -euo pipefail

VIDEO="${1:?video path required}"
START="${2:?start timecode HH:MM:SS required}"
DURATION="${3:?duration in seconds required (e.g. 4)}"
OUTPUT="${4:?output gif path required}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg not installed. Run: brew install ffmpeg" >&2
  exit 1
fi

if [[ ! -f "$VIDEO" ]]; then
  echo "Error: video not found: $VIDEO" >&2
  exit 1
fi

# Валидация длительности: 1..10 секунд (GIF длиннее становится тяжёлым)
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || (( DURATION < 1 )) || (( DURATION > 10 )); then
  echo "Error: duration must be integer 1..10 seconds, got: $DURATION" >&2
  exit 1
fi

PALETTE=$(mktemp -t gif-palette-XXXXXX.png)
trap 'rm -f "$PALETTE"' EXIT

# Pass 1: построить палитру по реальным цветам клипа
ffmpeg -y -ss "$START" -t "$DURATION" -i "$VIDEO" \
  -vf "fps=10,scale=1280:-1:flags=lanczos,palettegen=stats_mode=diff" \
  "$PALETTE" 2>/dev/null

# Pass 2: собрать GIF с применением палитры + дизеринг
ffmpeg -y -ss "$START" -t "$DURATION" -i "$VIDEO" -i "$PALETTE" \
  -lavfi "fps=10,scale=1280:-1:flags=lanczos [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  "$OUTPUT" 2>/dev/null

if [[ ! -s "$OUTPUT" ]]; then
  echo "Error: ffmpeg produced empty file at $OUTPUT" >&2
  exit 1
fi

SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "$OUTPUT ($SIZE)"
