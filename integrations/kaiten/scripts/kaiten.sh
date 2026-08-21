#!/bin/bash
# Kaiten API CLI - универсальный скрипт для вызова Kaiten API
# Usage: ./kaiten.sh <method> <endpoint> [json_body]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
hub_load_env "$SCRIPT_DIR"

# Check required env vars
if [[ -z "$KAITEN_TOKEN" ]]; then
    echo "Error: KAITEN_TOKEN environment variable must be set" >&2
    exit 1
fi

# Use KAITEN_API if set, otherwise build from KAITEN_DOMAIN
if [[ -z "$KAITEN_API" ]]; then
    if [[ -z "$KAITEN_DOMAIN" ]]; then
        echo "Error: KAITEN_API or KAITEN_DOMAIN must be set" >&2
        exit 1
    fi
    KAITEN_API="https://${KAITEN_DOMAIN}/api/latest"
fi

METHOD="${1:-GET}"
ENDPOINT="${2:-/users/current}"
BODY="$3"

# Эндпоинт склеивается с базой как есть (${KAITEN_API}${ENDPOINT}), поэтому без ведущего
# слэша получается ".../api/latestspaces" — Kaiten отвечает 401, и выглядит это как
# «не хватает прав», хотя токен в порядке. Нормализуем, чтобы обе формы работали.
[[ "$ENDPOINT" == /* ]] || ENDPOINT="/$ENDPOINT"

# Access control levels (cumulative):
#   1 | read                — GET/HEAD only
#   2 | read_write          — + POST/PUT/PATCH (no archive)
#   3 | read_write_archive  — + card archiving (default)
#   4 | full                — + DELETE
KAITEN_ACCESS_LEVEL="${KAITEN_ACCESS_LEVEL:-read_write_archive}"

METHOD_UPPER=$(echo "$METHOD" | tr '[:lower:]' '[:upper:]')

access_level_num() {
    case "$KAITEN_ACCESS_LEVEL" in
        1|read|READ|read_only|READ_ONLY) echo 1 ;;
        2|read_write|READ_WRITE) echo 2 ;;
        3|read_write_archive|READ_WRITE_ARCHIVE) echo 3 ;;
        4|full|FULL|read_write_archive_delete|READ_WRITE_ARCHIVE_DELETE) echo 4 ;;
        *) echo 0 ;;
    esac
}

is_card_archive_operation() {
    if [[ "$ENDPOINT" == *"/archive"* ]]; then
        return 0
    fi
    if [[ "$ENDPOINT" =~ ^/cards/[0-9]+$ ]]; then
        if [[ "$METHOD_UPPER" == "PATCH" || "$METHOD_UPPER" == "PUT" ]]; then
            if echo "$BODY" | grep -Eq '"archived"[[:space:]]*:[[:space:]]*(true|1)'; then
                return 0
            fi
        fi
    fi
    return 1
}

# Safe DELETE operations allowed at read_write_archive level:
# - Tag removal from cards: /cards/{id}/tags/{tag_id}
# - Checklist item removal: /cards/{id}/checklists/{id}/items/{id}
# - Card blocker removal: /cards/{id}/blockers/{id}
# - Member removal from cards: /cards/{id}/members/{member_id}
# - Planned relation removal: /cards/{id}/planned-relation/{target_card_id}
#   (снимает planned-зависимость между карточками — обратимо через re-relate, не удаляет карточки)
# - External link removal: /cards/{id}/external-links/{link_id}
#   (снимает ссылку с карточки — сам адрес остаётся в истории карточки, вешается заново одним POST)
is_safe_delete_operation() {
    if [[ "$ENDPOINT" =~ ^/cards/[0-9]+/tags/[0-9]+$ ]]; then
        return 0
    fi
    if [[ "$ENDPOINT" =~ ^/cards/[0-9]+/checklists/[0-9]+/items/[0-9]+$ ]]; then
        return 0
    fi
    if [[ "$ENDPOINT" =~ ^/cards/[0-9]+/blockers/[0-9]+$ ]]; then
        return 0
    fi
    if [[ "$ENDPOINT" =~ ^/cards/[0-9]+/members/[0-9]+$ ]]; then
        return 0
    fi
    if [[ "$ENDPOINT" =~ ^/cards/[0-9]+/planned-relation/[0-9]+$ ]]; then
        return 0
    fi
    if [[ "$ENDPOINT" =~ ^/cards/[0-9]+/external-links/[0-9]+$ ]]; then
        return 0
    fi
    return 1
}

LEVEL=$(access_level_num)

if [[ "$LEVEL" -eq 0 ]]; then
    echo "Error: Unknown KAITEN_ACCESS_LEVEL='$KAITEN_ACCESS_LEVEL'. Valid: read, read_write, read_write_archive (default), full" >&2
    exit 1
fi

case "$METHOD_UPPER" in
    GET|HEAD)
        ;; # level >= 1, always allowed
    POST|PUT|PATCH)
        if [[ "$LEVEL" -lt 2 ]]; then
            echo "Error: Write access denied (KAITEN_ACCESS_LEVEL=$KAITEN_ACCESS_LEVEL). Set to read_write or higher." >&2
            exit 1
        fi
        if is_card_archive_operation && [[ "$LEVEL" -lt 3 ]]; then
            echo "Error: Archive access denied (KAITEN_ACCESS_LEVEL=$KAITEN_ACCESS_LEVEL). Set to read_write_archive or higher." >&2
            exit 1
        fi
        ;;
    DELETE)
        if [[ "$LEVEL" -ge 3 ]] && is_safe_delete_operation; then
            : # Safe deletes allowed at read_write_archive level
        elif [[ "$LEVEL" -lt 4 ]]; then
            echo "Error: Delete access denied (KAITEN_ACCESS_LEVEL=$KAITEN_ACCESS_LEVEL). Set to full to allow DELETE." >&2
            exit 1
        fi
        ;;
    *)
        echo "Error: Unsupported HTTP method: $METHOD" >&2
        exit 1
        ;;
esac

# Build curl command
# --connect-timeout / --max-time: без них зависший запрос висит бесконечно
# (наблюдалось при bulk-прогонах). Ограничиваем время соединения и всего запроса.
CURL_ARGS=(
    -s
    --connect-timeout 10
    --max-time 30
    -X "$METHOD_UPPER"
    -H "Authorization: Bearer $KAITEN_TOKEN"
    -H "Content-Type: application/json"
)

if [[ -n "$BODY" ]]; then
    CURL_ARGS+=(-d "$BODY")
fi

# Клиентский троттлинг (opt-in через env KAITEN_RATE): пауза ПЕРЕД запросом. Дефолт — без
# паузы (интерактивные вызыватели пейсятся сами). max=0.6с ≈100 req/мин — безопасно для
# bulk (соответствует лимиту Kaiten); min=0.2с ≈300 req/мин — ТОЛЬКО для коротких серий
# (несколько вызовов), не для sustained-нагрузки.
case "${KAITEN_RATE:-}" in
    min) sleep 0.2 ;;
    max) sleep 0.6 ;;
esac

# Execute request. `|| curl_rc=$?`: под `set -e` присваивание с упавшим $(...) прервало бы
# скрипт на этой строке (тогда curl_rc=$? — мёртвый код) → ловим код, не роняя errexit.
curl_rc=0
response=$(curl "${CURL_ARGS[@]}" -w "\n%{http_code}" "${KAITEN_API}${ENDPOINT}") || curl_rc=$?

# Таймаут/сетевая ошибка curl (напр. 28) → чёткая ошибка, а не пустой ответ с exit 0
if [[ $curl_rc -ne 0 ]]; then
    echo "Error: curl не смог выполнить ${METHOD_UPPER} ${ENDPOINT} (exit $curl_rc — таймаут/сеть)" >&2
    exit 1
fi

# Extract HTTP code (last line)
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

# Check for errors
if [[ "$http_code" -ge 400 ]]; then
    echo "Error: HTTP $http_code" >&2
    echo "$body" >&2
    exit 1
fi

# Pretty print JSON if jq is available
if command -v jq &> /dev/null; then
    echo "$body" | jq . 2>/dev/null || echo "$body"
else
    echo "$body"
fi
