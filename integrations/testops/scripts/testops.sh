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

# Build curl command
CURL_ARGS=(
    -s
    -X "$METHOD_UPPER"
    -H "Authorization: Api-token $TESTOPS_TOKEN"
    -H "Content-Type: application/json"
)

if [[ -n "$BODY" ]]; then
    CURL_ARGS+=(-d "$BODY")
fi

# Execute request
response=$(curl "${CURL_ARGS[@]}" -w "\n%{http_code}" "${TESTOPS_URL}/api${ENDPOINT}")

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
