#!/bin/bash
# Buildin Login — проверка/сохранение UI-токена
#
# Usage: ./buildin-login.sh check              — проверить существующий токен
#        ./buildin-login.sh save <token>       — проверить и сохранить токен (manual fallback)
#        ./buildin-login.sh cookie [browser]   — ПРИМАРНЫЙ ПУТЬ: прочитать cookie из профиля
#                                                 Chrome/Brave/Edge/Arc/Firefox (без MCP/сети)
#        ./buildin-login.sh clipboard          — legacy (pbpaste), не использовать в новых флоу
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

# Where to write the token: prefer the .env that was sourced (overlay root).
# If none was found (fresh setup), default to the overlay/subtree root we
# detect via git, falling back to subtree root.
ENV_FILE="${HUB_ENV_FILE:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SUBTREE_ROOT")/.env}"
BUILDIN_BASE_URL="https://buildin.ai"

verify_token() {
    local TOKEN="$1"
    VERIFY=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        -H "x-platform: web-cookie" \
        -H "x-app-origin: web" \
        -H "x-product: buildin" \
        "${BUILDIN_BASE_URL}/api/users/me")

    HTTP_CODE=$(echo "$VERIFY" | tail -1)
    USER_INFO=$(echo "$VERIFY" | sed '$d')

    if [[ "$HTTP_CODE" != "200" ]]; then
        return 1
    fi

    # Check API-level code
    API_CODE=$(echo "$USER_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("code",0))' 2>/dev/null)
    if [[ "$API_CODE" != "200" ]]; then
        return 1
    fi

    echo "$USER_INFO"
    return 0
}

extract_user_info() {
    local USER_INFO="$1"
    NICKNAME=$(echo "$USER_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("data",{}).get("nickname",""))' 2>/dev/null)
    EMAIL=$(echo "$USER_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("data",{}).get("email",""))' 2>/dev/null)
}

save_token_to_env() {
    local TOKEN="$1"
    touch "$ENV_FILE"

    if grep -q '^BUILDIN_UI_TOKEN=' "$ENV_FILE" 2>/dev/null; then
        sed -i '' "s|^BUILDIN_UI_TOKEN=.*|BUILDIN_UI_TOKEN=${TOKEN}|" "$ENV_FILE"
    else
        echo "" >> "$ENV_FILE"
        echo "# Buildin UI token (JWT from next_auth cookie, 30-day expiry)" >> "$ENV_FILE"
        echo "BUILDIN_UI_TOKEN=${TOKEN}" >> "$ENV_FILE"
    fi
}

# --- Cookie extraction path (zero-MCP, reads directly from local browser profile) ---
# Invokes buildin-cookie-extract.py which uses pycookiecheat to read the
# `next_auth` cookie from the user's Chrome/Brave/Arc/etc. profile, then
# validates and saves to .env. Token NEVER touches stdout visible to the agent:
# the python helper prints it on stdout, shell captures it into a local var,
# validates, writes to .env via save_token_to_env.

cmd_cookie() {
    local requested_browser="${1:-auto}"
    local extractor
    extractor=$(hub_resolve_plugin_path hub-meta scripts/browser-cookie-extract.py) \
        || extractor="$SUBTREE_ROOT/integrations/hub-meta/scripts/browser-cookie-extract.py"

    if [[ ! -f "$extractor" ]]; then
        echo "error:extractor_missing ($extractor)" >&2
        return 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "error:python3_not_found" >&2
        return 1
    fi

    # Auto-install pycookiecheat if missing. Silent, one-shot.
    if ! python3 -c "import pycookiecheat" >/dev/null 2>&1; then
        echo "info:pycookiecheat not installed — installing via pip --user..." >&2
        if ! python3 -m pip install --user --quiet pycookiecheat >&2; then
            echo "error:pycookiecheat_install_failed (try: python3 -m pip install --user pycookiecheat)" >&2
            return 1
        fi
    fi

    local stderr_buf
    stderr_buf=$(mktemp)

    # Capture token into a shell var. Stdout of the extractor = token value,
    # never echoed anywhere. Stderr carries `browser:<name>` marker + errors.
    local TOKEN
    TOKEN=$(python3 "$extractor" "https://buildin.ai" "next_auth" "$requested_browser" 2>"$stderr_buf")
    local rc=$?

    if [[ $rc -ne 0 || -z "$TOKEN" ]]; then
        # Surface diagnostic lines (but no token value)
        grep '^error:' "$stderr_buf" >&2 || echo "error:extract_failed" >&2
        grep -v '^browser:' "$stderr_buf" | grep -v '^error:' >&2 || true
        rm -f "$stderr_buf"
        return 1
    fi

    # Pick out which browser actually worked (non-sensitive)
    local detected
    detected=$(grep '^browser:' "$stderr_buf" | head -1 | cut -d: -f2)
    rm -f "$stderr_buf"

    if [[ ${#TOKEN} -lt 50 ]]; then
        echo "error:not_a_jwt (too short: ${#TOKEN} chars — probably not logged in)" >&2
        return 1
    fi

    local USER_INFO
    USER_INFO=$(verify_token "$TOKEN") || {
        echo "error:validation_failed (cookie present but server rejected it — token expired?)" >&2
        return 1
    }

    extract_user_info "$USER_INFO"
    save_token_to_env "$TOKEN"

    # Email deliberately NOT printed — agent sees only nickname + browser hint
    echo "ok ${NICKNAME} (via ${detected})"
}

# --- Main ---
MODE="${1:-}"

case "$MODE" in
    check)
        TOKEN="${BUILDIN_UI_TOKEN:-}"
        if [[ -z "$TOKEN" ]]; then
            echo "error:no_token"
            exit 1
        fi
        USER_INFO=$(verify_token "$TOKEN") || {
            echo "error:token_expired"
            exit 1
        }
        extract_user_info "$USER_INFO"
        echo "ok ${NICKNAME}"
        ;;

    save)
        TOKEN="${2:-}"
        if [[ -z "$TOKEN" ]]; then
            echo "error:no_token_argument" >&2
            exit 1
        fi
        TOKEN=$(echo "$TOKEN" | tr -d '[:space:]')

        USER_INFO=$(verify_token "$TOKEN") || {
            echo "error:validation_failed" >&2
            exit 1
        }
        extract_user_info "$USER_INFO"
        save_token_to_env "$TOKEN"
        echo "ok ${NICKNAME}"
        ;;

    clipboard)
        TOKEN=$(pbpaste 2>/dev/null | tr -d '[:space:]')
        if [[ -z "$TOKEN" ]]; then
            echo "error:clipboard_empty" >&2
            exit 1
        fi
        if [[ ${#TOKEN} -lt 50 ]]; then
            echo "error:not_a_jwt (too short: ${#TOKEN} chars)" >&2
            exit 1
        fi

        USER_INFO=$(verify_token "$TOKEN") || {
            echo "error:validation_failed" >&2
            exit 1
        }
        extract_user_info "$USER_INFO"
        save_token_to_env "$TOKEN"

        # Clear clipboard
        echo -n "" | pbcopy
        echo "ok ${NICKNAME}"
        ;;

    cookie)
        cmd_cookie "${2:-auto}"
        ;;

    *)
        echo "Usage: $0 [check|save <token>|cookie [browser]|clipboard]" >&2
        exit 1
        ;;
esac
