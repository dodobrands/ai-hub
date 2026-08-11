#!/bin/bash
# Kusto (Azure Data Explorer) CLI — read-only queries
# Usage: ./kusto.sh "<KQL query>" [--format table|json|raw]
#
# Requirements: Azure CLI (az), curl, python3
#   az login
#
# Configuration via .env in overlay root:
#   KUSTO_CLUSTER=https://your-cluster.region.kusto.windows.net
#   KUSTO_DATABASE=your-database

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

for cmd in az curl python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is required but not found." >&2
        exit 1
    fi
done

if [[ -z "$KUSTO_CLUSTER" ]]; then
    echo "Error: KUSTO_CLUSTER must be set in .env" >&2
    echo "Example: KUSTO_CLUSTER=https://mycluster.westeurope.kusto.windows.net" >&2
    exit 1
fi

if [[ -z "$KUSTO_DATABASE" ]]; then
    echo "Error: KUSTO_DATABASE must be set in .env" >&2
    exit 1
fi

KUSTO_CLUSTER="${KUSTO_CLUSTER%/}"

usage() {
    echo "Usage: $0 \"<KQL query>\" [--format table|json|raw]" >&2
    echo "" >&2
    echo "Config required in .env.local:" >&2
    echo "  KUSTO_CLUSTER=https://your-cluster.region.kusto.windows.net" >&2
    echo "  KUSTO_DATABASE=your-database" >&2
}

QUERY=""
FORMAT="table"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --format)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --format requires a value (table|json|raw)." >&2
                usage
                exit 1
            fi
            FORMAT="$2"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        --*)
            echo "Error: Unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            if [[ -z "$QUERY" ]]; then
                QUERY="$1"
            else
                QUERY+=" $1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$QUERY" ]]; then
    usage
    exit 1
fi

case "$FORMAT" in
    table|json|raw) ;;
    *)
        echo "Error: Unsupported format: '$FORMAT'. Expected: table, json, raw." >&2
        exit 1
        ;;
esac

TOKEN=$(az account get-access-token \
    --resource "$KUSTO_CLUSTER" \
    --query accessToken -o tsv 2>/dev/null)

if [[ -z "$TOKEN" ]]; then
    echo "Error: Failed to get Azure token." >&2
    echo "Run: az login" >&2
    exit 1
fi

BODY=$(python3 -c "
import json, sys
print(json.dumps({'db': sys.argv[1], 'csl': sys.argv[2]}))
" "$KUSTO_DATABASE" "$QUERY")

HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${KUSTO_CLUSTER}/v1/rest/query" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$BODY")

HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
RESPONSE=$(echo "$HTTP_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ge 400 ]] 2>/dev/null; then
    echo "Kusto HTTP error $HTTP_CODE" >&2
    echo "$RESPONSE" | head -5 >&2
    exit 1
fi

if ! echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'Tables' in d else 1)" 2>/dev/null; then
    ERROR=$(echo "$RESPONSE" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    err=d.get('error',{})
    print(err.get('@message', err.get('message', json.dumps(d)[:400])))
except:
    print(sys.stdin.read()[:400])
" 2>/dev/null || echo "$RESPONSE" | head -3)
    echo "Kusto error: $ERROR" >&2
    exit 1
fi

if [[ "$FORMAT" == "raw" ]]; then
    echo "$RESPONSE"
    exit 0
fi

echo "$RESPONSE" | OUTPUT_FORMAT="$FORMAT" python3 -c "
import json, sys, os

FORMAT = os.environ.get('OUTPUT_FORMAT', 'table')
d = json.load(sys.stdin)
tables = d.get('Tables', [])
primary = next((t for t in tables if t.get('TableKind') == 'PrimaryResult'), tables[0] if tables else None)

if not primary:
    print('No results')
    sys.exit(0)

cols = [c['ColumnName'] for c in primary['Columns']]
rows = primary['Rows']

if not rows:
    print('No results')
    sys.exit(0)

if FORMAT == 'json':
    result = [dict(zip(cols, r)) for r in rows]
    print(json.dumps(result, indent=2, default=str, ensure_ascii=False))
else:
    str_rows = [[str(v) if v is not None else '' for v in r] for r in rows]
    widths = [max(len(c), max((len(r[i]) for r in str_rows), default=0)) for i, c in enumerate(cols)]
    widths = [min(w, 120) for w in widths]
    sep = '+' + '+'.join('-' * (w + 2) for w in widths) + '+'
    def fmt_row(r):
        return '|' + '|'.join(' ' + str(v)[:w].ljust(w) + ' ' for v, w in zip(r, widths)) + '|'
    print(sep)
    print(fmt_row(cols))
    print(sep)
    for r in str_rows:
        print(fmt_row(r))
    print(sep)
    print(f'{len(rows)} row(s)')
"
