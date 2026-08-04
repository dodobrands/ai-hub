#!/bin/bash
# Export non-archived cards from a Kaiten board to Markdown
# Usage: ./kaiten-export-board.sh <board_id> [output_file.md]
#
# Example:
#   ./kaiten-export-board.sh 123456 tasks.md
#
# Optional env vars:
#   PROPERTY_ID — custom property ID for "Affected Services" (if set, exports service tags)

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
hub_load_env "$SCRIPT_DIR" || true

# Auto-read PROPERTY_ID from team-config.json (lives at the overlay root,
# next to .env). Falls back silently if no team config is present.
TEAM_CONFIG="${HUB_OVERLAY_ROOT:-}/team-config.json"
if [[ -z "${PROPERTY_ID:-}" && -f "$TEAM_CONFIG" ]]; then
    PROPERTY_ID=$(jq -r '.kaiten.property_id_affected_services // empty' "$TEAM_CONFIG" 2>/dev/null || true)
fi
PROPERTY_ID="${PROPERTY_ID:-}"

if [[ -z "$1" ]]; then
    echo "Usage: ./kaiten-export-board.sh <board_id> [output_file.md]" >&2
    echo "" >&2
    echo "Set PROPERTY_ID env var to include Affected Services in export." >&2
    exit 1
fi

BOARD_ID="$1"
if [[ -n "${2:-}" ]]; then
    OUTPUT_FILE="$2"
else
    TEMP_DIR="${HUB_OVERLAY_ROOT:-.}/Temp"
    mkdir -p "$TEMP_DIR"
    OUTPUT_FILE="${TEMP_DIR}/board_${BOARD_ID}.md"
fi

echo "Fetching board info..." >&2

# Get board name
BOARD_NAME=$("$SCRIPT_DIR/kaiten.sh" GET "/boards/$BOARD_ID" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('title', 'Unknown Board'))
")

# Get columns mapping
COLUMNS=$("$SCRIPT_DIR/kaiten.sh" GET "/boards/$BOARD_ID/columns" 2>/dev/null)

# Get affected services mapping (optional)
if [[ -n "$PROPERTY_ID" ]]; then
    SERVICES_MAP=$("$SCRIPT_DIR/kaiten.sh" GET "/company/custom-properties/${PROPERTY_ID}/select-values" 2>/dev/null)
else
    SERVICES_MAP="[]"
fi

# Get all cards and filter non-archived, then fetch full details
echo "Fetching cards..." >&2

"$SCRIPT_DIR/kaiten-cards.sh" list "$BOARD_ID" 2>/dev/null | python3 -c "
import subprocess
import json
import sys

# Read inputs
cards_list = json.load(sys.stdin)
columns_json = '''$COLUMNS'''
services_json = '''$SERVICES_MAP'''
board_name = '''$BOARD_NAME'''
output_file = '''$OUTPUT_FILE'''
script_dir = '''$SCRIPT_DIR'''
property_id = '''$PROPERTY_ID'''

columns = {c['id']: c['title'] for c in json.loads(columns_json)}
services = {s['id']: s['value'] for s in json.loads(services_json)}

# Filter non-archived
active_cards = [c for c in cards_list if not c.get('archived', False)]
print(f'Found {len(active_cards)} active cards (excluded {len(cards_list) - len(active_cards)} archived)', file=sys.stderr)

# Fetch full card details
results = []
for i, card in enumerate(active_cards, 1):
    cid = card['id']
    try:
        raw = subprocess.check_output(
            [f'{script_dir}/kaiten.sh', 'GET', f'/cards/{cid}'],
            stderr=subprocess.DEVNULL
        )
        data = json.loads(raw)

        svc_ids = data.get('properties', {}).get(f'id_{property_id}', [])
        svc_names = [services.get(sid, f'unknown:{sid}') for sid in svc_ids]

        results.append({
            'id': data['id'],
            'title': data['title'],
            'column': columns.get(data['column_id'], str(data['column_id'])),
            'affected_services': svc_names,
            'description': data.get('description') or ''
        })
        print(f'  {i}/{len(active_cards)}: {data[\"title\"][:50]}...', file=sys.stderr)
    except Exception as e:
        print(f'  ERROR card {cid}: {e}', file=sys.stderr)

# Group by column
by_column = {}
for card in results:
    col = card['column']
    if col not in by_column:
        by_column[col] = []
    by_column[col].append(card)

# Write markdown
with open(output_file, 'w') as f:
    f.write(f'# {board_name}\n\n')
    f.write(f'> Exported: {len(results)} active cards\n\n')

    for col_name, cards in by_column.items():
        f.write(f'## {col_name} ({len(cards)})\n\n')

        for card in cards:
            f.write(f'### [{card[\"id\"]}] {card[\"title\"]}\n\n')

            if card['affected_services']:
                f.write(f'**Affected Services:** {', '.join(card['affected_services'])}\n\n')

            if card['description']:
                f.write(card['description'].strip() + '\n\n')
            else:
                f.write('*(no description)*\n\n')

            f.write('---\n\n')

print(f'Saved to {output_file}')
"
