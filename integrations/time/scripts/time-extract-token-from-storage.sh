#!/bin/bash
# Извлекает MMAUTHTOKEN из Playwright storage-state JSON файла,
# валидирует и сохраняет в .env.
# Токен НЕ выводится в stdout — LLM видит только статус.
#
# Usage: ./time-extract-token-from-storage.sh <storage-state.json>
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBTREE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# Source hub-meta/scripts/load-env.sh from either marketplace layout
# (<root>/integrations/<plugin>/scripts/) or Claude Code plugin cache
# (<cache>/<marketplace>/<plugin>/<version>/scripts/, resolved by globbing the
# sibling hub-meta versions and taking the highest, with $CLAUDE_PLUGIN_ROOT
# as a last resort).
_hub_load_env_sh="$SCRIPT_DIR/../../hub-meta/scripts/load-env.sh"
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "$SCRIPT_DIR"/../../../hub-meta/*/scripts/load-env.sh 2>/dev/null | sort -V | tail -1)
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "${CLAUDE_PLUGIN_ROOT:-/dev/null}"/../../hub-meta/*/scripts/load-env.sh 2>/dev/null | sort -V | tail -1)
[[ -f "$_hub_load_env_sh" ]] || { echo "Error: hub-meta/scripts/load-env.sh not found (marketplace and plugin-cache layouts checked)" >&2; exit 1; }
# shellcheck source=../../hub-meta/scripts/load-env.sh
source "$_hub_load_env_sh"
unset _hub_load_env_sh
hub_load_env "$SCRIPT_DIR" || true

ENV_FILE="${HUB_ENV_FILE:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SUBTREE_ROOT")/.env}"
TIME_BASE_URL="${TIME_BASE_URL:-https://your-company.time-messenger.ru}"

STORAGE_FILE="${1}"

if [[ -z "$STORAGE_FILE" ]]; then
    echo "error:no_storage_file" >&2
    exit 1
fi

if [[ ! -f "$STORAGE_FILE" ]]; then
    echo "error:file_not_found $STORAGE_FILE" >&2
    exit 1
fi

TOKEN=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for cookie in data.get('cookies', []):
    if cookie.get('name') == 'MMAUTHTOKEN':
        print(cookie['value'])
        sys.exit(0)
sys.exit(1)
" "$STORAGE_FILE" 2>/dev/null)

if [[ -z "$TOKEN" ]]; then
    echo "error:no_mmauthtoken"
    exit 1
fi

# Validate token
VERIFY=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    "${TIME_BASE_URL}/api/v4/users/me")

HTTP_CODE=$(echo "$VERIFY" | tail -1)
USER_INFO=$(echo "$VERIFY" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "error:validation_failed (HTTP $HTTP_CODE)"
    exit 1
fi

USERNAME=$(echo "$USER_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("username",""))' 2>/dev/null)
EMAIL=$(echo "$USER_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("email",""))' 2>/dev/null)

# Save to .env
touch "$ENV_FILE"

if grep -q '^TIME_TOKEN=' "$ENV_FILE" 2>/dev/null; then
    sed -i '' "s|^TIME_TOKEN=.*|TIME_TOKEN=${TOKEN}|" "$ENV_FILE"
else
    echo "" >> "$ENV_FILE"
    echo "# Time (Mattermost) personal session token" >> "$ENV_FILE"
    echo "TIME_TOKEN=${TOKEN}" >> "$ENV_FILE"
fi

# Clean up storage state file (contains sensitive cookies)
rm -f "$STORAGE_FILE"

echo "ok @${USERNAME} (${EMAIL})"
