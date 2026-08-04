#!/bin/bash
# Читает токен из буфера обмена, проверяет и сохраняет в .env
# Вызывается после того, как JS в браузере скопировал MMAUTHTOKEN в clipboard
#
# Usage: ./time-save-token-from-clipboard.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBTREE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# Source hub-meta/scripts/load-env.sh from either marketplace layout
# (<root>/integrations/<plugin>/scripts/) or Claude Code plugin cache
# (<cache>/<marketplace>/<plugin>/<version>/scripts/, resolved by globbing the
# sibling hub-meta version, with $CLAUDE_PLUGIN_ROOT as a last resort).
_hub_load_env_sh="$SCRIPT_DIR/../../hub-meta/scripts/load-env.sh"
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "$SCRIPT_DIR"/../../../hub-meta/*/scripts/load-env.sh 2>/dev/null | head -1)
[[ -f "$_hub_load_env_sh" ]] || _hub_load_env_sh=$(ls "${CLAUDE_PLUGIN_ROOT:-/dev/null}"/../../hub-meta/*/scripts/load-env.sh 2>/dev/null | head -1)
[[ -f "$_hub_load_env_sh" ]] || { echo "Error: hub-meta/scripts/load-env.sh not found (marketplace and plugin-cache layouts checked)" >&2; exit 1; }
# shellcheck source=../../hub-meta/scripts/load-env.sh
source "$_hub_load_env_sh"
unset _hub_load_env_sh
hub_load_env "$SCRIPT_DIR" || true

ENV_FILE="${HUB_ENV_FILE:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SUBTREE_ROOT")/.env}"
TIME_BASE_URL="${TIME_BASE_URL:-https://your-company.time-messenger.ru}"

# Read token from clipboard
TOKEN=$(pbpaste 2>/dev/null | tr -d '[:space:]')

if [[ -z "$TOKEN" ]]; then
    echo "Error: буфер обмена пуст" >&2
    exit 1
fi

# Basic sanity check (Mattermost tokens are 26-char alphanumeric)
if [[ ${#TOKEN} -lt 20 ]]; then
    echo "Error: значение из буфера не похоже на токен (слишком короткое: ${#TOKEN} символов)" >&2
    exit 1
fi

# Verify token against API
VERIFY=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    "${TIME_BASE_URL}/api/v4/users/me")

HTTP_CODE=$(echo "$VERIFY" | tail -1)
USER_INFO=$(echo "$VERIFY" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Error: токен невалидный (HTTP $HTTP_CODE)" >&2
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

# Clear clipboard
echo -n "" | pbcopy

echo "ok @${USERNAME} (${EMAIL})"
