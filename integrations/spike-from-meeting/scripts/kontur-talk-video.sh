#!/usr/bin/env bash
# kontur-talk-video.sh — скачивает MP4 записи Контур.Толк через API.
# Usage: kontur-talk-video.sh <recording_url> <output.mp4> [quality]
#   quality: highest (default), 900p, 240p и т.д.
#
# Авторизация — каскадом через ktalk-auth.sh: ключ API ($KTALK_TOKEN), при отказе —
# cookie-сессия ($KTALK_SESSION_TOKEN). См. kontur-talk-transcript.sh.
# Эндпоинт: GET /recording-blob/{id}/{quality}
# Верифицирован 2026-05-12 на реальном ktalk-tenant'е (по ключу API — 2026-07-28);
# работает на любом *.ktalk.ru.

set -euo pipefail

INPUT="${1:?Kontur.Talk recording URL required}"
OUTPUT="${2:?output mp4 path required}"
QUALITY="${3:-highest}"

if [[ "$INPUT" =~ ^https?://([^/]+\.ktalk\.ru)/recordings/([A-Za-z0-9_-]+) ]]; then
  TENANT_HOST="${BASH_REMATCH[1]}"
  RECORDING_ID="${BASH_REMATCH[2]}"
else
  echo "Error: could not parse URL: $INPUT" >&2
  exit 1
fi

# shellcheck source=ktalk-auth.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ktalk-auth.sh"
ktalk_init_auth
ktalk_have_auth || { ktalk_auth_help "$TENANT_HOST"; exit 2; }

# Если quality=highest — разрешить через метаданные
if [[ "$QUALITY" == "highest" ]]; then
  META=$(mktemp -t ktalk-meta-XXXXXX)
  trap 'rm -f "$META"' EXIT
  ktalk_fetch "https://${TENANT_HOST}/api/recordings/${RECORDING_ID}" "$META" >/dev/null
  QUALITY=$(jq -r '.qualities[-1].name // "900p"' "$META")
fi

URL="https://${TENANT_HOST}/recording-blob/${RECORDING_ID}/${QUALITY}"

echo "Downloading $URL → $OUTPUT" >&2
read -r STATUS AUTH_MODE <<<"$(ktalk_fetch "$URL" "$OUTPUT" -L)"
if [[ "$STATUS" != "200" && "$STATUS" != "206" ]]; then
  echo "Error: HTTP $STATUS при скачивании (auth: ${AUTH_MODE})" >&2
  exit 1
fi

if [[ ! -s "$OUTPUT" ]]; then
  echo "Error: downloaded file is empty" >&2
  exit 1
fi

SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "Saved $SIZE → $OUTPUT" >&2
