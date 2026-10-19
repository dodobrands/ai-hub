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
            echo "Config (.env): GENIE_SPACE_ID, GENIE_PROFILE, GENIE_HOST"
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

# CLI сам опрашивает сообщение до COMPLETED и падает на FAILED/CANCELLED. Его таймаут по
# умолчанию — 20 минут; агенту столько висеть незачем.
# `--` — чтобы вопрос, начинающийся с дефиса, не разобрался как флаг CLI.
if ! RESPONSE=$(databricks genie start-conversation "${GENIE_CLI_ARGS[@]}" --timeout 5m -- "$GENIE_SPACE_ID" "$QUERY"); then
    echo "Error: Genie request failed (see databricks CLI error above). If it is an auth error, log in again:" >&2
    genie_login_hint
    exit 1
fi

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
