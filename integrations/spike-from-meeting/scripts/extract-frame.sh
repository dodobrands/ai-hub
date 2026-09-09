#!/usr/bin/env bash
# extract-frame.sh — извлекает один кадр из видео в указанный момент.
# Usage: extract-frame.sh <video_path> <HH:MM:SS> <output.png>
#
# Использует -ss ПЕРЕД -i для быстрого seek (input seeking).
# Качество -q:v 2 = high quality JPEG-like для PNG.

set -euo pipefail

VIDEO="${1:?video path required}"
TIMECODE="${2:?timecode HH:MM:SS required}"
OUTPUT="${3:?output png path required}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg not installed. Run: brew install ffmpeg" >&2
  exit 1
fi

if [[ ! -f "$VIDEO" ]]; then
  echo "Error: video not found: $VIDEO" >&2
  exit 1
fi

# -ss перед -i = быстрый input seek (точный, но без перекодирования с самого начала)
# -frames:v 1 = ровно один кадр
# -q:v 2 = высокое качество (для PNG влияет слабо, но не помешает)
# -update 1 = подавить warning о паттерне имени файла
ffmpeg -y -ss "$TIMECODE" -i "$VIDEO" -frames:v 1 -q:v 2 -update 1 "$OUTPUT" 2>/dev/null

if [[ ! -s "$OUTPUT" ]]; then
  echo "Error: ffmpeg produced empty file at $OUTPUT" >&2
  exit 1
fi

echo "$OUTPUT"
