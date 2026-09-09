#!/bin/bash
# Buildin Navigation — навигация по дереву страниц, поиск (UI API)
# Usage: ./buildin-nav.sh <command> [args...]
#
# Принимает page_id как UUID или URL buildin.ai
#
# Commands:
#   tree <page_id> [max_depth]           — дерево дочерних страниц (default depth=2)
#   search <query> [space_id]            — поиск по названию (UI search API, качество низкое)
#   title <page_id>                      — получить заголовок страницы
#   children <page_id>                   — список прямых дочерних страниц (id + title)
#   parent <page_id>                     — родительская страница

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_SPACE_ID="${BUILDIN_SPACE_ID:-your-space-id-here}"

buildin() {
    "$SCRIPT_DIR/buildin.sh" "$@"
}

parse_id() {
    local input="$1"
    local uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    local uuid
    uuid=$(echo "$input" | grep -oE "$uuid_re" | tail -1 || true)
    echo "${uuid:-$input}"
}

# Получить заголовок страницы через /api/blocks/{id}
get_title() {
    local page_id="$1"
    buildin GET "/api/blocks/$page_id" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin).get('data', {})
    print(data.get('title', '') or '(untitled)')
except:
    print('(error)')
" 2>/dev/null
}

# Получить дочерние page-блоки (type=0) из /api/docs/{id}
get_child_pages() {
    local page_id="$1"
    buildin GET "/api/docs/$page_id" 2>/dev/null | python3 -c "
import json, sys
page_id = sys.argv[1]
data = json.load(sys.stdin).get('data', {})
blocks = data.get('blocks', {})
page = blocks.get(page_id, {})
for sid in page.get('subNodes', []):
    child = blocks.get(sid)
    if child and child.get('type') == 0:
        title = child.get('title', '(untitled)')
        print(f'{sid}\t{title}')
" "$page_id" 2>/dev/null
}

# Рекурсивный вывод дерева
print_tree() {
    local page_id="$1"
    local depth="${2:-0}"
    local max_depth="${3:-2}"
    local prefix=""
    for ((i=0; i<depth; i++)); do prefix="  $prefix"; done

    local title
    title=$(get_title "$page_id")
    echo "${prefix}${title}  [${page_id}]"

    if [[ "$depth" -ge "$max_depth" ]]; then
        return
    fi

    local children
    children=$(get_child_pages "$page_id")
    while IFS=$'\t' read -r child_id child_title; do
        [[ -z "$child_id" ]] && continue
        print_tree "$child_id" $((depth + 1)) "$max_depth"
    done <<< "$children"
}

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
    title)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: title <page_id|url>" >&2; exit 1; }
        get_title "$PAGE_ID"
        ;;

    children)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: children <page_id|url>" >&2; exit 1; }
        children=$(get_child_pages "$PAGE_ID")
        while IFS=$'\t' read -r cid ctitle; do
            [[ -z "$cid" ]] && continue
            echo "${ctitle}  [${cid}]"
        done <<< "$children"
        ;;

    tree)
        PAGE_ID=$(parse_id "$1")
        MAX_DEPTH="${2:-2}"
        [[ -z "$PAGE_ID" ]] && { echo "Usage: tree <page_id|url> [max_depth]" >&2; exit 1; }
        print_tree "$PAGE_ID" 0 "$MAX_DEPTH"
        ;;

    parent)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: parent <page_id|url>" >&2; exit 1; }
        buildin GET "/api/blocks/$PAGE_ID" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin).get('data', {})
parent_id = data.get('parentId', '')
space_id = data.get('spaceId', '')
if parent_id == space_id:
    print(f'Root page (space: {space_id})')
else:
    print(parent_id)
" 2>/dev/null
        ;;

    search)
        QUERY="$1"
        SPACE_ID="${2:-$DEFAULT_SPACE_ID}"
        [[ -z "$QUERY" ]] && { echo "Usage: search <query> [space_id]" >&2; exit 1; }

        # UI Search API is a LAST RESORT: quality is poor (irrelevant/duplicated results) and
        # it is scoped to one space. Prefer shadow-index + tree traversal (buildin-shadow.sh
        # search / buildin-nav.sh children), or ask the user for the page URL/page_id.
        echo "warning: UI search quality is low and space-scoped — prefer shadow-index/tree traversal or ask for the page URL." >&2

        # UI Search API (quality is poor — results are often irrelevant or duplicated)
        BODY=$(python3 -c "
import json, sys
print(json.dumps({
    'page': 1,
    'perPage': 20,
    'query': sys.argv[1],
    'source': 'quickFind',
    'sort': 'relevance',
    'filters': {'createdBy': [], 'ancestors': []}
}))
" "$QUERY")

        buildin POST "/api/search/$SPACE_ID/docs" "$BODY" | python3 -c "
import json, sys
data = json.load(sys.stdin).get('data', {})
results = data.get('results', [])
blocks = data.get('recordMap', {}).get('blocks', {})
total = data.get('total', 0)

if not results:
    print('No results found.')
    sys.exit(0)

print(f'Found {total} results (showing {len(results)}):')
print()
for r in results:
    page_id = r.get('pageId', r.get('uuid', ''))
    hit = r.get('hitText', '')
    block = blocks.get(page_id, {})
    title = block.get('title', '') or hit
    space_id = block.get('spaceId', r.get('spaceId', ''))
    parent_id = block.get('parentId', '')
    print(f'  {title}')
    print(f'    ID: {page_id}')
    print(f'    URL: https://buildin.ai/{space_id}/{page_id}')
    if hit and hit != title:
        print(f'    Hit: {hit[:100]}')
    print()
" 2>/dev/null
        ;;

    help|*)
        echo "Buildin Navigation — навигация по дереву страниц (UI API)"
        echo "Принимает page_id как UUID или URL buildin.ai"
        echo ""
        echo "Commands:"
        echo "  title <id|url>                       — заголовок страницы"
        echo "  parent <id|url>                      — родительская страница"
        echo "  children <id|url>                    — прямые дочерние page-блоки"
        echo "  tree <id|url> [max_depth]            — дерево страниц (default depth=2)"
        echo "  search <query> [space_id]            — поиск по названию (UI Search API, качество низкое)"
        echo ""
        echo "Default space: $DEFAULT_SPACE_ID"
        ;;
esac
