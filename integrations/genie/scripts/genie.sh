#!/bin/bash
# Databricks Genie CLI - Query data using natural language
#
# Usage:
#   ./genie.sh "how many orders were there yesterday?"
#   ./genie.sh "top-10 locations by revenue this week"
#   ./genie.sh --raw "query"  # Return raw JSON response
#   ./genie.sh --no-sql "query"  # Hide SQL details

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
RAW_OUTPUT=false
SHOW_SQL=true
QUERY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --raw|-r)
            RAW_OUTPUT=true
            shift
            ;;
        --no-sql)
            SHOW_SQL=false
            shift
            ;;
        --help|-h)
            echo "Databricks Genie CLI - Query data using natural language"
            echo ""
            echo "Usage:"
            echo "  ./genie.sh \"ваш вопрос на естественном языке\""
            echo "  ./genie.sh --raw \"вопрос\"     # вернуть полный JSON ответ"
            echo "  ./genie.sh --no-sql \"вопрос\"  # скрыть SQL детали"
            echo ""
            echo "Auth: databricks auth login --host <workspace-url> --profile <profile>"
            echo "Config (.env): GENIE_SPACE_ID, GENIE_PROFILE or GENIE_HOST"
            echo "Exit codes: 0 ok, 1 error, 2 login required (the user runs it, it opens a browser)"
            echo ""
            echo "Examples:"
            echo "  ./genie.sh \"how many orders were there yesterday?\""
            echo "  ./genie.sh \"top-10 locations by revenue this week\""
            echo "  ./genie.sh \"compare revenue across regions for January\""
            exit 0
            ;;
        *)
            QUERY="$1"
            shift
            ;;
    esac
done

if [ -z "$QUERY" ]; then
    echo "Error: Query is required"
    echo "Usage: ./genie.sh \"ваш вопрос\""
    exit 1
fi

# Конфиг — после разбора аргументов, чтобы --help работал без CLI и .env.
source "$SCRIPT_DIR/genie-config.sh"

# stderr CLI нужен целиком, чтобы понять причину отказа: подсказка про логин при таймауте
# или 403 отправила бы агента перелогиниваться, а логин делает только человек в браузере.
CLI_ERR=$(mktemp)
GENIE_LOCK=""
trap 'rm -f "$CLI_ERR"; [[ -z "$GENIE_LOCK" ]] || rmdir "$GENIE_LOCK" 2>/dev/null' EXIT

# Параллельные вызовы (волна агентов discovery) обновляли бы истёкший access token одновременно.
# Если в аккаунте Databricks включены single-use refresh tokens, выигрывает один, остальные
# получают «refresh token is invalid» и требуют перелогина через браузер. Поэтому токен
# прогреваем под блокировкой: обновится он один раз, остальные возьмут свежий (живёт час,
# вопрос — минуты). Ошибка прогрева не фатальна: для профилей не на U2M `auth token` не
# работает, а настоящий отказ авторизации покажет сам запрос.
genie_warm_token() {
    local key lock waited=0
    key=$(printf '%s' "${GENIE_PROFILE:-${GENIE_HOST:-default}}" | tr -c 'A-Za-z0-9._-' '_')
    lock="${TMPDIR:-/tmp}/genie-auth-$key.lock"
    until mkdir "$lock" 2>/dev/null; do
        # Прогрев держит блокировку не дольше своего таймаута (20 с); дольше её держит только
        # убитый процесс. GENIE_LOCK_WAIT_SECONDS укорачивает ожидание в тестах.
        if (( waited >= ${GENIE_LOCK_WAIT_SECONDS:-30} )); then
            rmdir "$lock" 2>/dev/null || true
            waited=0
            continue
        fi
        sleep 1
        waited=$((waited + 1))
    done
    GENIE_LOCK="$lock"
    databricks auth token "${GENIE_CLI_ARGS[@]}" --timeout 20s >/dev/null 2>&1 || true
    rmdir "$lock" 2>/dev/null || true
    GENIE_LOCK=""
}
genie_warm_token

# CLI сам опрашивает сообщение до COMPLETED и падает на FAILED/CANCELLED. Его таймаут по
# умолчанию — 20 минут; агенту столько висеть незачем.
# `--` — чтобы вопрос, начинающийся с дефиса, не разобрался как флаг CLI.
if ! RESPONSE=$(databricks genie start-conversation "${GENIE_CLI_ARGS[@]}" --timeout 5m -- "$GENIE_SPACE_ID" "$QUERY" 2>"$CLI_ERR"); then
    cat "$CLI_ERR" >&2
    # Тексты отказов авторизации CLI v1.13.0: нет кредов, протух refresh token, нет профиля.
    if grep -qiE 'cannot configure default credentials|refresh token is invalid|invalid_grant|invalid access token|databricks auth login|has no .* profile configured' "$CLI_ERR"; then
        genie_login_hint
        exit 2
    fi
    if grep -qE 'unknown (command|flag)' "$CLI_ERR"; then
        echo "Error: this databricks CLI has no 'genie start-conversation --timeout'. Update databricks CLI (tested on v1.13.0): https://docs.databricks.com/aws/en/dev-tools/cli/install" >&2
        exit 1
    fi
    echo "Error: Genie request failed, see the databricks CLI error above" >&2
    exit 1
fi
cat "$CLI_ERR" >&2

# Raw output mode
if [ "$RAW_OUTPUT" = true ]; then
    echo "$RESPONSE" | python3 -c "import sys,json; d=json.loads(sys.stdin.read(), strict=False); print(json.dumps(d, indent=2, ensure_ascii=False))"
    exit 0
fi

# Parse and display response
# Pass SHOW_SQL as environment variable to avoid shell injection
echo "$RESPONSE" | SHOW_SQL_VAR="$SHOW_SQL" python3 -c "
import sys
import json
import re
import os

response_json = sys.stdin.read()
d = json.loads(response_json, strict=False)
show_sql = os.environ.get('SHOW_SQL_VAR', 'true') == 'true'

# Extract components from attachments
sql_query = None
description = None
tables_used = []
text_response = None
suggested_questions = []

for att in d.get('attachments', []):
    if 'query' in att:
        sql_query = att['query'].get('query', '')
        description = att['query'].get('description', '')
        # Extract tables from SQL
        tables = re.findall(r'\x60([^\x60]+)\x60\.\x60([^\x60]+)\x60\.\x60([^\x60]+)\x60', sql_query)
        tables_used = [f'{t[0]}.{t[1]}.{t[2]}' for t in tables]
    if 'text' in att:
        text_response = att['text'].get('content', '')
    if 'suggested_questions' in att:
        suggested_questions = att['suggested_questions'].get('questions', [])

# Print text response
if text_response:
    print(text_response)

# Print SQL details if enabled
if show_sql and sql_query:
    print()
    print('─' * 50)
    print('📊 SQL Query:')
    print(sql_query)
    if tables_used:
        print()
        print(f'📁 Tables: {\", \".join(tables_used)}')

# Print suggested questions
if suggested_questions:
    print()
    print('💡 Suggested questions:')
    for q in suggested_questions[:3]:
        print(f'   • {q}')
"
