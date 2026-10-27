#!/bin/bash
# TestOps (Allure TestOps) API CLI — универсальный скрипт для вызова TestOps API
# Usage: ./testops.sh <method> <endpoint> [json_body]
#
# Обёртка над REST API: ${TESTOPS_URL}/api/<endpoint>
# Авторизация: Api-token ${TESTOPS_TOKEN}

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Резолвим .env: реальный корень git-репо (работает и в standalone, и когда
# ai-hub подключён как subtree в overlay-репо), с fallback на subtree-корень
# (../../..). Переопределяется через HUB_ENV_FILE.
SUBTREE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENV_FILE="${HUB_ENV_FILE:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SUBTREE_ROOT")/.env}"

# Load .env
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

# Check required env vars
if [[ -z "$TESTOPS_TOKEN" ]]; then
    echo "Error: TESTOPS_TOKEN environment variable must be set" >&2
    echo "Get it from: Allure TestOps -> Profile -> API Tokens" >&2
    exit 1
fi

if [[ -z "$TESTOPS_URL" ]]; then
    echo "Error: TESTOPS_URL environment variable must be set (e.g. https://your-instance.qatools.cloud)" >&2
    exit 1
fi

# Remove trailing slash from URL
TESTOPS_URL="${TESTOPS_URL%/}"

METHOD="${1:-GET}"
ENDPOINT="${2:-/project}"
BODY="$3"

METHOD_UPPER=$(echo "$METHOD" | tr '[:lower:]' '[:upper:]')

# Потолки — числа секунд. Опечатку вроде `2m` curl отверг бы кодом 2, и ниже она выглядела бы как
# недоступный TestOps.
for _v in TESTOPS_CONNECT_TIMEOUT TESTOPS_MAX_TIME; do
    if [[ -n "${!_v}" && ! "${!_v}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "Error: $_v must be a number of seconds, got '${!_v}'" >&2
        exit 1
    fi
done
unset _v

# Build curl command
# Без потолков вызов висит бесконечно: без VPN TCP-соединение устанавливается, а TLS-рукопожатие
# не завершается. --connect-timeout быстро даёт вердикт «недоступен», --max-time обрывает
# зависший ответ с запасом на тяжёлые выборки. -S оставляет в stderr причину от curl.
CURL_ARGS=(
    -sS
    --connect-timeout "${TESTOPS_CONNECT_TIMEOUT:-15}"
    --max-time "${TESTOPS_MAX_TIME:-120}"
    -X "$METHOD_UPPER"
    -H "Authorization: Api-token $TESTOPS_TOKEN"
    -H "Content-Type: application/json"
)

if [[ -n "$BODY" ]]; then
    CURL_ARGS+=(-d "$BODY")
fi

# Execute request. `|| curl_rc=$?`: под `set -e` упавший $(...) завершил бы скрипт молча, с кодом
# curl, и вызывающий не отличил бы недоступный TestOps от любой другой ошибки.
curl_rc=0
response=$(curl "${CURL_ARGS[@]}" -w "\n%{http_code}" "${TESTOPS_URL}/api${ENDPOINT}") || curl_rc=$?

if [[ $curl_rc -ne 0 ]]; then
    echo "Error: no response from TestOps for ${METHOD_UPPER} ${ENDPOINT} (curl exit $curl_rc: timeout or network)" >&2
    # Запрос мог упереться в --max-time, когда TestOps уже принял его: запись тогда прошла, и слепой
    # повтор создаст дубль тест-кейса или запуска.
    if [[ "$METHOD_UPPER" != GET && "$METHOD_UPPER" != HEAD ]]; then
        echo "Error: a write may have been applied — check before retrying" >&2
    fi
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
