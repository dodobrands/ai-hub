#!/bin/bash
# Логин в Time — получает токен и сохраняет в .env
#
# Usage: ./time-login.sh                — интерактивный выбор способа
#        ./time-login.sh check          — проверить существующий токен
#        ./time-login.sh cookie [browser] — ПРИМАРНЫЙ: читать MMAUTHTOKEN из профиля
#                                           Chrome/Brave/Edge/Arc (без MCP/сети)
#        ./time-login.sh password       — логин по email/паролю (interactive)
#        ./time-login.sh sso            — вставить токен из браузера вручную
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

save_token() {
    local TOKEN="$1"

    # Verify token works
    VERIFY=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "${TIME_BASE_URL}/api/v4/users/me")

    HTTP_CODE=$(echo "$VERIFY" | tail -1)
    USER_INFO=$(echo "$VERIFY" | sed '$d')

    if [[ "$HTTP_CODE" != "200" ]]; then
        echo "Error: Токен невалидный (HTTP $HTTP_CODE)" >&2
        return 1
    fi

    USERNAME=$(echo "$USER_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("username",""))' 2>/dev/null)
    EMAIL=$(echo "$USER_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("email",""))' 2>/dev/null)

    echo "Залогинен как @${USERNAME}"
    echo ""

    # Save to .env
    touch "$ENV_FILE"

    if grep -q '^TIME_TOKEN=' "$ENV_FILE" 2>/dev/null; then
        sed -i '' "s|^TIME_TOKEN=.*|TIME_TOKEN=${TOKEN}|" "$ENV_FILE"
        echo "TIME_TOKEN обновлён в $ENV_FILE"
    else
        echo "" >> "$ENV_FILE"
        echo "# Time (Mattermost) personal session token" >> "$ENV_FILE"
        echo "TIME_TOKEN=${TOKEN}" >> "$ENV_FILE"
        echo "TIME_TOKEN добавлен в $ENV_FILE"
    fi

    echo ""
    echo "Готово! Проверка:"
    echo "  integrations/time/scripts/time-channels.sh my-teams | jq '.[].display_name'"
}

login_password() {
    read -p "Email или username: " LOGIN_ID
    read -s -p "Пароль: " PASSWORD
    echo ""

    if [[ -z "$LOGIN_ID" || -z "$PASSWORD" ]]; then
        echo "Error: email и пароль обязательны" >&2
        exit 1
    fi

    LOGIN_BODY=$(python3 -c "import json,sys; print(json.dumps({'login_id': sys.argv[1], 'password': sys.argv[2]}))" "$LOGIN_ID" "$PASSWORD")

    echo "Логинюсь в ${TIME_BASE_URL}..."

    # Try v4 login
    RESPONSE=$(curl -s -D - \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$LOGIN_BODY" \
        "${TIME_BASE_URL}/api/v4/users/login" 2>&1)

    TOKEN=$(echo "$RESPONSE" | grep -i '^token:' | tr -d '[:space:]' | cut -d: -f2)

    # Fallback to v5
    if [[ -z "$TOKEN" ]]; then
        RESPONSE=$(curl -s -D - \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$LOGIN_BODY" \
            "${TIME_BASE_URL}/api/v5/auth/login" 2>&1)

        TOKEN=$(echo "$RESPONSE" | grep -i 'MMAUTHTOKEN' | sed 's/.*MMAUTHTOKEN=//I' | sed 's/;.*//' | tr -d '[:space:]')
        if [[ -z "$TOKEN" ]]; then
            TOKEN=$(echo "$RESPONSE" | grep -i '^token:' | tr -d '[:space:]' | cut -d: -f2)
        fi
    fi

    if [[ -z "$TOKEN" ]]; then
        echo "Error: Логин не удался. Проверь email и пароль." >&2
        HTTP_STATUS=$(echo "$RESPONSE" | grep -i '^HTTP/' | tail -1)
        echo "HTTP: $HTTP_STATUS" >&2
        exit 1
    fi

    save_token "$TOKEN"
}

login_sso() {
    echo "Как получить токен из браузера:"
    echo ""
    echo "  1. Открой ${TIME_BASE_URL} и залогинься через Google SSO"
    echo "  2. Открой DevTools (F12 или Cmd+Option+I)"
    echo "  3. Один из способов:"
    echo ""
    echo "     Способ A — Cookie (рекомендуется):"
    echo "       DevTools → Application → Cookies → ${TIME_BASE_URL}"
    echo "       Найди MMAUTHTOKEN → скопируй Value"
    echo ""
    echo "     Способ B — Network:"
    echo "       DevTools → Network → кликни любой запрос к api/"
    echo "       Headers → Authorization: Bearer <вот этот токен>"
    echo ""
    echo "     ⚠️ document.cookie не работает — MMAUTHTOKEN это httpOnly cookie"
    echo ""

    read -p "Вставь токен: " TOKEN
    TOKEN=$(echo "$TOKEN" | tr -d '[:space:]')

    if [[ -z "$TOKEN" ]]; then
        echo "Error: токен не может быть пустым" >&2
        exit 1
    fi

    save_token "$TOKEN"
}

# --- Cookie extraction path (zero-MCP, reads MMAUTHTOKEN directly from browser) ---
# Even though MMAUTHTOKEN is an httpOnly cookie, pycookiecheat reads the Chrome
# SQLite DB directly — httpOnly flag only blocks JS document.cookie access, not
# backing-store reads. Works for Chrome / Brave / Edge / Vivaldi / Opera / Arc /
# Firefox, iterates all profiles.

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

    # Auto-install pycookiecheat if missing
    if ! python3 -c "import pycookiecheat" >/dev/null 2>&1; then
        echo "info:pycookiecheat not installed — installing via pip --user..." >&2
        if ! python3 -m pip install --user --quiet pycookiecheat >&2; then
            echo "error:pycookiecheat_install_failed (try: python3 -m pip install --user pycookiecheat)" >&2
            return 1
        fi
    fi

    if [[ -z "$TIME_BASE_URL" || "$TIME_BASE_URL" == "https://your-company.time-messenger.ru" ]]; then
        echo "error:TIME_BASE_URL_not_set (set it first via env-manager.sh set TIME_BASE_URL <url>)" >&2
        return 1
    fi

    local stderr_buf
    stderr_buf=$(mktemp)

    # stdout = raw token → captured into shell var, never echoed
    # stderr = browser:<name>/<profile> marker + diagnostics
    local TOKEN
    TOKEN=$(python3 "$extractor" "$TIME_BASE_URL" "MMAUTHTOKEN" "$requested_browser" 2>"$stderr_buf")
    local rc=$?

    if [[ $rc -ne 0 || -z "$TOKEN" ]]; then
        grep '^error:' "$stderr_buf" >&2 || echo "error:extract_failed" >&2
        grep -v '^browser:' "$stderr_buf" | grep -v '^error:' >&2 || true
        rm -f "$stderr_buf"
        return 1
    fi

    local detected
    detected=$(grep '^browser:' "$stderr_buf" | head -1 | cut -d: -f2)
    rm -f "$stderr_buf"

    # Validate via Time API — save_token also prints "Залогинен как @...", which
    # we don't want in the cookie path (too chatty). Do a quieter validation.
    local VERIFY HTTP_CODE USER_INFO USERNAME
    VERIFY=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer $TOKEN" \
        "${TIME_BASE_URL}/api/v4/users/me")
    HTTP_CODE=$(echo "$VERIFY" | tail -1)
    USER_INFO=$(echo "$VERIFY" | sed '$d')

    if [[ "$HTTP_CODE" != "200" ]]; then
        echo "error:validation_failed (HTTP $HTTP_CODE — cookie present but Time rejected it; session expired?)" >&2
        return 1
    fi

    USERNAME=$(echo "$USER_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("username",""))' 2>/dev/null)

    # Save to .env (mirror save_token without the chatty output)
    touch "$ENV_FILE"
    if grep -q '^TIME_TOKEN=' "$ENV_FILE" 2>/dev/null; then
        sed -i '' "s|^TIME_TOKEN=.*|TIME_TOKEN=${TOKEN}|" "$ENV_FILE"
    else
        echo "" >> "$ENV_FILE"
        echo "# Time (Mattermost) personal session token" >> "$ENV_FILE"
        echo "TIME_TOKEN=${TOKEN}" >> "$ENV_FILE"
    fi

    # Email deliberately NOT printed
    echo "ok @${USERNAME} (via ${detected})"
}

# --- Main ---

MODE="${1:-}"

# Interactive banner only for interactive modes (password/sso with no args)
if [[ -z "$MODE" ]]; then
    echo "=== Time Login ==="
    echo ""
    echo "Выбери способ логина:"
    echo "  1) Google SSO — вставить токен из браузера вручную"
    echo "  2) Email + пароль"
    echo ""
    echo "  Или используй /ai-hub:time-login для автоматического"
    echo "  извлечения токена через Chrome DevTools (рекомендуется для SSO)"
    echo ""
    read -p "Выбор [1/2]: " CHOICE

    case "$CHOICE" in
        1) MODE="sso" ;;
        2) MODE="password" ;;
        *)
            echo "Error: выбери 1 или 2" >&2
            exit 1
            ;;
    esac
fi

case "$MODE" in
    check)
        TOKEN=""
        if [[ -f "$ENV_FILE" ]]; then
            TOKEN=$(grep '^TIME_TOKEN=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
        fi
        if [[ -z "$TOKEN" ]]; then
            echo "error:no_token"
            exit 1
        fi
        VERIFY=$(curl -s -w "\n%{http_code}" \
            -H "Authorization: Bearer $TOKEN" \
            "${TIME_BASE_URL}/api/v4/users/me")
        HTTP_CODE=$(echo "$VERIFY" | tail -1)
        USER_INFO=$(echo "$VERIFY" | sed '$d')
        if [[ "$HTTP_CODE" != "200" ]]; then
            echo "error:token_expired (HTTP $HTTP_CODE)"
            exit 1
        fi
        USERNAME=$(echo "$USER_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("username",""))' 2>/dev/null)
        EMAIL=$(echo "$USER_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("email",""))' 2>/dev/null)
        echo "ok @${USERNAME}"
        ;;
    cookie)   cmd_cookie "${2:-auto}" ;;
    sso)      login_sso ;;
    password) login_password ;;
    *)
        echo "Usage: $0 [check|cookie [browser]|sso|password]" >&2
        exit 1
        ;;
esac
