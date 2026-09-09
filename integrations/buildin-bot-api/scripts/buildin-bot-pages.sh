#!/bin/bash
# Buildin Bot API — Page operations (Official Bot API, api.buildin.ai/v1/)
#
# Usage: ./buildin-bot-pages.sh <command> [args...]
#
# Accepts page_id as UUID or URL:
#   ./buildin-bot-pages.sh read 2a904afe-42e9-4ebd-a94e-f6fe0cbacf58
#   ./buildin-bot-pages.sh read https://buildin.ai/241db73f.../2a904afe...
#
# Commands:
#   get <page_id>                          — get page metadata (JSON)
#   read <page_id>                         — read page as markdown (fetches blocks recursively)
#   create <parent_page_id> <title>        — create child page
#   update <page_id> <title>               — update page title
#   archive <page_id>                      — archive page (set archived: true)
#   search <query> [page_size]             — search pages (Bot API /v1/search)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bot() {
    "$SCRIPT_DIR/buildin-bot.sh" "$@"
}

parse_id() {
    local input="$1"
    local uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    local uuid
    uuid=$(echo "$input" | grep -oE "$uuid_re" | tail -1 || true)
    echo "${uuid:-$input}"
}

# Fetch all children blocks with pagination
fetch_all_children() {
    local block_id="$1"
    local cursor=""
    local all_blocks="[]"

    while true; do
        local url="/v1/blocks/${block_id}/children?page_size=100"
        if [[ -n "$cursor" ]]; then
            url="${url}&start_cursor=${cursor}"
        fi

        local resp
        resp=$(bot GET "$url")

        local blocks
        blocks=$(echo "$resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(json.dumps(data.get('results', [])))
" 2>/dev/null)

        all_blocks=$(python3 -c "
import sys, json
a = json.loads(sys.argv[1])
b = json.loads(sys.argv[2])
print(json.dumps(a + b))
" "$all_blocks" "$blocks")

        local has_more
        has_more=$(echo "$resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('true' if data.get('has_more') else 'false')
" 2>/dev/null)

        if [[ "$has_more" != "true" ]]; then
            break
        fi

        cursor=$(echo "$resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('next_cursor', ''))
" 2>/dev/null)
    done

    echo "$all_blocks"
}

# Render blocks to markdown recursively
render_blocks_md() {
    local blocks_json="$1"
    local indent="${2:-0}"

    python3 -c "
import sys, json

blocks = json.loads(sys.argv[1])
indent = int(sys.argv[2])
pfx = '  ' * indent

def rt(rich_text):
    parts = []
    for item in (rich_text or []):
        text = item.get('plain_text', '')
        if not text:
            t = item.get('text', {})
            text = t.get('content', '')
        ann = item.get('annotations', {})
        href = item.get('href') or (item.get('text', {}) or {}).get('link', {}) or {}
        if isinstance(href, dict):
            href = href.get('url', '')
        if ann.get('code'): text = f'\`{text}\`'
        elif ann.get('bold'): text = f'**{text}**'
        elif ann.get('italic'): text = f'*{text}*'
        elif ann.get('strikethrough'): text = f'~~{text}~~'
        if href:
            text = f'[{text}]({href})'
        parts.append(text)
    return ''.join(parts)

for b in blocks:
    btype = b.get('type', 'paragraph')
    data = b.get(btype, b.get('data', {}))
    rich = data.get('rich_text', [])
    text = rt(rich)
    has_children = b.get('has_children', False)

    if btype == 'paragraph':
        if text:
            print(f'{pfx}{text}')
        print()
    elif btype in ('heading_1', 'heading_2', 'heading_3'):
        level = int(btype[-1])
        h = '#' * level
        print(f'{pfx}{h} {text}')
        print()
    elif btype == 'bulleted_list_item':
        print(f'{pfx}- {text}')
    elif btype == 'numbered_list_item':
        print(f'{pfx}1. {text}')
    elif btype == 'to_do':
        checked = data.get('checked', False)
        mark = 'x' if checked else ' '
        print(f'{pfx}- [{mark}] {text}')
    elif btype == 'quote':
        print(f'{pfx}> {text}')
        print()
    elif btype == 'callout':
        icon = ''
        icon_data = data.get('icon', {})
        if icon_data:
            icon = icon_data.get('emoji', '') + ' '
        print(f'{pfx}> {icon}{text}')
        print()
    elif btype == 'code':
        lang = data.get('language', '')
        print(f'{pfx}\`\`\`{lang}')
        print(f'{pfx}{text}')
        print(f'{pfx}\`\`\`')
        print()
    elif btype == 'divider':
        print(f'{pfx}---')
        print()
    elif btype == 'image':
        img = data.get('file', data.get('external', {}))
        url = img.get('url', '')
        caption = rt(data.get('caption', []))
        print(f'{pfx}![{caption}]({url})')
        print()
    elif btype == 'bookmark':
        url = data.get('url', '')
        caption = rt(data.get('caption', []))
        print(f'{pfx}[{caption or url}]({url})')
        print()
    elif btype == 'toggle':
        print(f'{pfx}<details>')
        print(f'{pfx}<summary>{text}</summary>')
        print()
    elif btype == 'child_page':
        title = data.get('title', text)
        print(f'{pfx}> [{title}]')
        print()
    elif btype == 'child_database':
        title = data.get('title', text)
        print(f'{pfx}> [Database: {title}]')
        print()
    elif text:
        print(f'{pfx}{text}')
        print()
" "$blocks_json" "$indent"
}

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
    get)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: get <page_id|url>" >&2; exit 1; }
        bot GET "/v1/pages/$PAGE_ID"
        ;;

    read)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: read <page_id|url>" >&2; exit 1; }

        # Get page metadata for title
        page_json=$(bot GET "/v1/pages/$PAGE_ID")
        title=$(echo "$page_json" | python3 -c "
import sys, json
page = json.load(sys.stdin)
props = page.get('properties', {})
title_prop = props.get('title', {})
title_items = title_prop.get('title', [])
parts = []
for item in title_items:
    parts.append(item.get('plain_text', item.get('text', {}).get('content', '')))
print(''.join(parts) or '(untitled)')
" 2>/dev/null)

        echo "# $title"
        echo ""

        # Fetch and render blocks
        blocks_json=$(fetch_all_children "$PAGE_ID")
        render_blocks_md "$blocks_json" 0

        # Recursively render children of blocks that have children
        echo "$blocks_json" | python3 -c "
import sys, json
blocks = json.load(sys.stdin)
for b in blocks:
    if b.get('has_children'):
        print(b.get('id', ''))
" 2>/dev/null | while read -r child_id; do
            [[ -z "$child_id" ]] && continue
            sub_blocks=$(fetch_all_children "$child_id")
            render_blocks_md "$sub_blocks" 1
        done
        ;;

    create)
        PARENT_ID=$(parse_id "$1")
        TITLE="$2"
        [[ -z "$PARENT_ID" || -z "$TITLE" ]] && { echo "Usage: create <parent_page_id|url> <title>" >&2; exit 1; }

        BODY=$(python3 -c "
import json, sys
parent_id = sys.argv[1]
title = sys.argv[2]
print(json.dumps({
    'parent': {'type': 'page_id', 'page_id': parent_id},
    'properties': {
        'title': {'type': 'title', 'title': [{'type': 'text', 'text': {'content': title}}]}
    }
}))
" "$PARENT_ID" "$TITLE")

        result=$(bot POST "/v1/pages" "$BODY")
        page_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
        page_url=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('url',''))" 2>/dev/null)
        echo "Created page: $page_id"
        echo "URL: $page_url"
        ;;

    update)
        PAGE_ID=$(parse_id "$1")
        TITLE="$2"
        [[ -z "$PAGE_ID" || -z "$TITLE" ]] && { echo "Usage: update <page_id|url> <title>" >&2; exit 1; }

        BODY=$(python3 -c "
import json, sys
title = sys.argv[1]
print(json.dumps({
    'properties': {
        'title': {'type': 'title', 'title': [{'type': 'text', 'text': {'content': title}}]}
    }
}))
" "$TITLE")

        bot PATCH "/v1/pages/$PAGE_ID" "$BODY"
        ;;

    archive)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: archive <page_id|url>" >&2; exit 1; }

        bot PATCH "/v1/pages/$PAGE_ID" '{"archived": true}'
        ;;

    search)
        # Bot API POST /v1/search is broken server-side — it consistently returns HTTP 500.
        # Guarded on purpose so callers don't waste turns on a dead endpoint. Read by
        # page_id/URL (`read`/`get`), ask the user for the URL, or use the UI-API `buildin`
        # integration (shadow-index + `buildin-nav children`) to locate a page_id.
        echo "search: Bot API /v1/search is broken (HTTP 500) and disabled. Read by page_id/URL, ask the user for the URL, or use the UI-API buildin integration (shadow-index / buildin-nav children)." >&2
        exit 2
        QUERY="$1"
        PAGE_SIZE="${2:-20}"
        [[ -z "$QUERY" ]] && { echo "Usage: search <query> [page_size]" >&2; exit 1; }

        BODY=$(python3 -c "
import json, sys
print(json.dumps({
    'query': sys.argv[1],
    'page_size': int(sys.argv[2])
}))
" "$QUERY" "$PAGE_SIZE")

        bot POST "/v1/search" "$BODY" | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('results', [])
has_more = data.get('has_more', False)
cursor = data.get('next_cursor')

if not results:
    print('No results found.')
    sys.exit(0)

print(f'Found {len(results)} results (has_more={has_more}):')
print()
for r in results:
    rid = r.get('id', '')
    url = r.get('url', '')
    archived = r.get('archived', False)
    props = r.get('properties', {})
    title_prop = props.get('title', {})
    title_items = title_prop.get('title', [])
    title = ''.join(item.get('plain_text', '') for item in title_items) or '(untitled)'
    parent = r.get('parent', {})
    parent_type = parent.get('type', '')
    parent_id = parent.get(parent_type, '')

    status = ' [archived]' if archived else ''
    print(f'  {title}{status}')
    print(f'    ID: {rid}')
    if url:
        print(f'    URL: {url}')
    print(f'    Parent: {parent_type}={parent_id}')
    print()

if cursor:
    print(f'Next cursor: {cursor}')
" 2>/dev/null
        ;;

    help|*)
        echo "Buildin Bot API — Page operations (Official API, api.buildin.ai/v1/)"
        echo "Accepts page_id as UUID or URL buildin.ai"
        echo ""
        echo "Commands:"
        echo "  get <id|url>                             — page metadata (JSON)"
        echo "  read <id|url>                            — read as markdown"
        echo "  create <parent_id|url> <title>           — create child page"
        echo "  update <id|url> <title>                  — update title"
        echo "  archive <id|url>                         — archive page"
        echo "  search <query> [page_size]               — search pages (/v1/search)"
        echo ""
        echo "Auth: BUILDIN_BOT_TOKEN (bot integration token)"
        echo "Note: Bot can only access pages shared with it"
        ;;
esac
