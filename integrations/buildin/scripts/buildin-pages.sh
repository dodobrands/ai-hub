#!/bin/bash
# Buildin Pages — операции со страницами и блоками через UI API
# Usage: ./buildin-pages.sh <command> [args...]
#
# Принимает page_id как UUID или URL:
#   ./buildin-pages.sh read 2a904afe-42e9-4ebd-a94e-f6fe0cbacf58
#   ./buildin-pages.sh read https://buildin.ai/241db73f.../2a904afe...
#
# Commands:
#   get <page_id>                          — получить страницу (JSON, все блоки)
#   title <page_id>                        — получить заголовок страницы
#   read <page_id>                         — прочитать страницу как markdown
#   create <parent_page_id> <title>        — создать дочернюю страницу
#   update <page_id> <title>               — обновить заголовок страницы
#   archive <page_id>                      — архивировать страницу (status: -1)
#   get-blocks <page_id>                   — получить блоки страницы (JSON)
#   comments <page_id|url[#block_id]> [block_id] — комментарии страницы или конкретного блока
#                                                  (URL с якорем #block-uuid фильтрует по блоку)
#   append-blocks <page_id> <json_blocks>              — добавить блоки на страницу (transaction)
#                                                        блоки могут иметь "children" (таблицы/toggle/вложенные списки)
#   insert-blocks-after <page_id> <after_block_id> <json_blocks>   — вставить блоки после конкретного блока
#   insert-blocks-before <page_id> <before_block_id> <json_blocks> — вставить блоки перед конкретным блоком
#                                                        (block_id берётся из поля "uuid" в выводе get-blocks)
#   append-text <page_id> <text>                       — добавить текстовый параграф
#   append-image <page_id> <image_file> [caption]      — загрузить картинку в S3 Buildin и добавить image-блок
#                                                        (JPEG: размеры из SOF, EXIF Orientation не учитывается)
#   delete-block <block_id> <parent_id>                — удалить блок

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

buildin() {
    "$SCRIPT_DIR/buildin.sh" "$@"
}

# Извлечь UUID из URL или вернуть как есть
parse_id() {
    local input="$1"
    local uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    local uuid
    uuid=$(echo "$input" | grep -oE "$uuid_re" | tail -1 || true)
    echo "${uuid:-$input}"
}

# Получить spaceId для страницы
get_space_id() {
    local PAGE_ID="$1"
    buildin GET "/api/blocks/$PAGE_ID" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('data', {}).get('spaceId', ''))
" 2>/dev/null
}

# Сгенерировать UUID v4
gen_uuid() {
    python3 -c "import uuid; print(str(uuid.uuid4()))"
}

# Выполнить транзакцию
transaction() {
    local SPACE_ID="$1"
    local OPERATIONS="$2"
    local REQ_ID
    REQ_ID=$(gen_uuid)
    local TX_ID
    TX_ID=$(gen_uuid)

    local body
    body=$(python3 -c "
import json, sys
ops = json.loads(sys.argv[1])
print(json.dumps({
    'requestId': sys.argv[2],
    'transactions': [{
        'id': sys.argv[3],
        'spaceId': sys.argv[4],
        'operations': ops
    }]
}))
" "$OPERATIONS" "$REQ_ID" "$TX_ID" "$SPACE_ID")

    buildin POST "/api/records/transactions" "$body"
}

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
    get)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: get <page_id|url>" >&2; exit 1; }
        buildin GET "/api/docs/$PAGE_ID"
        ;;

    title)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: title <page_id|url>" >&2; exit 1; }
        buildin GET "/api/docs/$PAGE_ID" | python3 -c "
import json, sys
page_id = sys.argv[1]
data = json.load(sys.stdin).get('data', {})
blocks = data.get('blocks', {})
block = blocks.get(page_id, next(iter(blocks.values()), {})) if blocks else data
print(block.get('title', '(untitled)'))
" "$PAGE_ID"
        ;;

    create)
        PARENT_ID=$(parse_id "$1")
        TITLE="$2"
        [[ -z "$PARENT_ID" || -z "$TITLE" ]] && { echo "Usage: create <parent_page_id|url> <title>" >&2; exit 1; }

        SPACE_ID=$(get_space_id "$PARENT_ID")
        [[ -z "$SPACE_ID" ]] && { echo "Error: cannot determine spaceId for parent $PARENT_ID" >&2; exit 1; }

        PAGE_UUID=$(gen_uuid)
        BLOCK_UUID=$(gen_uuid)
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(buildin GET "/api/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uuid',''))")

        OPS=$(python3 -c "
import json, sys
page_id = sys.argv[1]
parent_id = sys.argv[2]
space_id = sys.argv[3]
block_id = sys.argv[4]
title = sys.argv[5]
now = int(sys.argv[6])
user_id = sys.argv[7]

ops = [
    # Create the page block
    {
        'id': page_id,
        'command': 'set',
        'table': 'block',
        'path': [],
        'args': {
            'uuid': page_id,
            'spaceId': space_id,
            'parentId': parent_id,
            'type': 0,
            'textColor': '',
            'backgroundColor': '',
            'status': 1,
            'permissions': [],
            'createdAt': now,
            'createdBy': user_id,
            'updatedBy': user_id,
            'updatedAt': now,
            'data': {
                'segments': [{'type': 0, 'text': title, 'enhancer': {}}],
                'pageFixedWidth': True,
                'format': {'commentAlignment': 'top'}
            }
        }
    },
    # Add page to parent's subNodes
    {
        'id': parent_id,
        'command': 'listAfter',
        'table': 'block',
        'path': ['subNodes'],
        'args': {'uuid': page_id}
    },
    # Create empty paragraph inside the page
    {
        'id': block_id,
        'command': 'set',
        'table': 'block',
        'path': [],
        'args': {
            'uuid': block_id,
            'spaceId': space_id,
            'parentId': page_id,
            'type': 1,
            'textColor': '',
            'backgroundColor': '',
            'status': 1,
            'permissions': [],
            'createdAt': now,
            'createdBy': user_id,
            'updatedBy': user_id,
            'updatedAt': now,
            'data': {
                'pageFixedWidth': True,
                'format': {'commentAlignment': 'top'}
            }
        }
    },
    # Add paragraph to page's subNodes
    {
        'id': page_id,
        'command': 'listAfter',
        'table': 'block',
        'path': ['subNodes'],
        'args': {'uuid': block_id}
    },
    # Update parent timestamps
    {
        'id': parent_id,
        'command': 'update',
        'table': 'block',
        'path': [],
        'args': {'updatedBy': user_id, 'updatedAt': now}
    }
]
print(json.dumps(ops))
" "$PAGE_UUID" "$PARENT_ID" "$SPACE_ID" "$BLOCK_UUID" "$TITLE" "$NOW" "$USER_ID")

        transaction "$SPACE_ID" "$OPS"
        echo ""
        echo "Created page: $PAGE_UUID"
        echo "URL: https://buildin.ai/$SPACE_ID/$PAGE_UUID"
        ;;

    update)
        PAGE_ID=$(parse_id "$1")
        TITLE="$2"
        [[ -z "$PAGE_ID" || -z "$TITLE" ]] && { echo "Usage: update <page_id|url> <title>" >&2; exit 1; }

        SPACE_ID=$(get_space_id "$PAGE_ID")
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(buildin GET "/api/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uuid',''))")

        OPS=$(python3 -c "
import json, sys
page_id, title, now, user_id = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
ops = [
    {
        'id': page_id,
        'command': 'update',
        'table': 'block',
        'path': ['data'],
        'args': {'segments': [{'type': 0, 'text': title, 'enhancer': {}}]}
    },
    {
        'id': page_id,
        'command': 'update',
        'table': 'block',
        'path': [],
        'args': {'updatedBy': user_id, 'updatedAt': now}
    }
]
print(json.dumps(ops))
" "$PAGE_ID" "$TITLE" "$NOW" "$USER_ID")

        transaction "$SPACE_ID" "$OPS"
        ;;

    archive)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: archive <page_id|url>" >&2; exit 1; }

        # Get parent and space info
        BLOCK_INFO=$(buildin GET "/api/blocks/$PAGE_ID")
        SPACE_ID=$(echo "$BLOCK_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('spaceId',''))")
        PARENT_ID=$(echo "$BLOCK_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('parentId',''))")
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(buildin GET "/api/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uuid',''))")

        OPS=$(python3 -c "
import json, sys
page_id, parent_id, now, user_id = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
ops = [
    {'id': page_id, 'command': 'update', 'table': 'block', 'path': [],
     'args': {'status': -1, 'updatedBy': user_id, 'updatedAt': now}},
    {'id': parent_id, 'command': 'listRemove', 'table': 'block', 'path': ['subNodes'],
     'args': {'uuid': page_id}},
    {'id': page_id, 'command': 'update', 'table': 'block', 'path': [],
     'args': {'updatedBy': user_id, 'updatedAt': now}}
]
print(json.dumps(ops))
" "$PAGE_ID" "$PARENT_ID" "$NOW" "$USER_ID")

        transaction "$SPACE_ID" "$OPS"
        ;;

    get-blocks)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: get-blocks <page_id|url>" >&2; exit 1; }
        buildin GET "/api/docs/$PAGE_ID" | python3 -c "
import json, sys
page_id = sys.argv[1]
data = json.load(sys.stdin).get('data', {})
blocks = data.get('blocks', {})
page = blocks.get(page_id, {})
sub_nodes = page.get('subNodes', [])
result = []
for sid in sub_nodes:
    if sid in blocks:
        result.append(blocks[sid])
print(json.dumps(result, indent=2, ensure_ascii=False))
" "$PAGE_ID"
        ;;

    comments)
        INPUT="$1"
        [[ -z "$INPUT" ]] && { echo "Usage: comments <page_id|url[#block_id]> [block_id]" >&2; exit 1; }
        # Полный URL — buildin.ai/<space>/<page>: страница — последний UUID до «#»
        # (как в parse_id), блок — из якоря после «#».
        UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        BASE="${INPUT%%#*}"
        PAGE_ID=$(echo "$BASE" | grep -oE "$UUID_RE" | tail -1 || true)
        [[ -z "$PAGE_ID" ]] && { echo "Error: no UUID found in '$INPUT'" >&2; exit 1; }
        BLOCK_ID="${2:-}"
        if [[ -z "$BLOCK_ID" && "$INPUT" == *"#"* ]]; then
            BLOCK_ID=$(echo "${INPUT#*#}" | grep -oE "$UUID_RE" | head -1 || true)
        fi

        DOC_FILE=$(mktemp)
        MEMBERS_FILE=$(mktemp)
        trap 'rm -f "$DOC_FILE" "$MEMBERS_FILE"' EXIT

        buildin GET "/api/docs/$PAGE_ID" > "$DOC_FILE"
        SPACE_ID=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1])).get('data', {})
blocks = data.get('blocks', {})
print(next(iter(blocks.values()), {}).get('spaceId', ''))
" "$DOC_FILE")
        # Участники нужны для имён авторов и @-упоминаний; без доступа — покажем UUID
        if [[ -n "$SPACE_ID" ]]; then
            buildin GET "/api/spaces/$SPACE_ID/members" > "$MEMBERS_FILE" 2>/dev/null || echo '{}' > "$MEMBERS_FILE"
        else
            echo '{}' > "$MEMBERS_FILE"
        fi

        python3 -c "
import json, sys
from datetime import datetime

doc_file, members_file, page_id, block_id = sys.argv[1:5]
data = json.load(open(doc_file)).get('data', {})
blocks = data.get('blocks', {})
discussions = data.get('discussions', {})
comments = data.get('comments', {})

try:
    members = json.load(open(members_file)).get('data', []) or []
except Exception:
    members = []
users = {m['user']['uuid']: m['user'].get('nickname') or m['user'].get('email', '') for m in members if m.get('user')}

def name(uuid):
    return users.get(uuid, uuid[:8] if uuid else '?')

def rt(segments):
    # type 7 — @-упоминание человека: text пустой, uuid = user uuid
    parts = []
    for s in (segments or []):
        if s.get('type') == 7:
            # пробел после упоминания: следующий сегмент часто начинается сразу с текста
            parts.append('@' + name(s.get('uuid', '')) + ' ')
        else:
            parts.append(s.get('text', ''))
    return ''.join(parts).strip()

def ts(ms):
    return datetime.fromtimestamp(ms / 1000).strftime('%Y-%m-%d %H:%M') if ms else '?'

found = 0
for did, disc in discussions.items():
    parent = disc.get('parentId', '')
    if block_id and parent != block_id:
        continue
    block = blocks.get(parent, {})
    block_title = block.get('title') or rt(block.get('data', {}).get('segments'))
    context = rt(disc.get('context'))
    status = 'resolved' if disc.get('resolved') else 'open'
    found += 1
    print(f'## Блок {parent}')
    if block_title:
        print(f'Текст блока: {block_title}')
    if context and context != block_title:
        print(f'Выделено: «{context}»')
    print(f'Тред {did} [{status}]:')
    for cid in disc.get('comments', []):
        c = comments.get(cid, {})
        body = rt(c.get('text')) or '(без текста)'
        print(f'- {name(c.get(\"createdBy\", \"\"))} ({ts(c.get(\"createdAt\"))}): {body}')
    print()

if not found:
    where = f'блока {block_id}' if block_id else f'страницы {page_id}'
    print(f'Комментариев у {where} нет.')
" "$DOC_FILE" "$MEMBERS_FILE" "$PAGE_ID" "$BLOCK_ID"
        ;;

    read)
        PAGE_ID=$(parse_id "$1")
        [[ -z "$PAGE_ID" ]] && { echo "Usage: read <page_id|url>" >&2; exit 1; }

        buildin GET "/api/docs/$PAGE_ID" | python3 -c "
import json, sys

page_id = sys.argv[1]
data = json.load(sys.stdin).get('data', {})
blocks = data.get('blocks', {})
page = blocks.get(page_id, {})
title = page.get('title', '(untitled)')
print(f'# {title}')
print()

# Block types: 0=page, 1=paragraph, 3=todo, 4=bulleted, 5=numbered, 6=toggle,
#              7=heading, 9=divider, 12=quote, 13=callout, 14=image,
#              21=bookmark, 23=equation, 25=code, 27=table (rows=28),
#              38=toggle-heading
def rt(segments):
    parts = []
    for s in (segments or []):
        text = s.get('text', '')
        enh = s.get('enhancer', {})
        url = s.get('url', '')
        if enh.get('code'): text = f'\`{text}\`'
        elif enh.get('bold'): text = f'**{text}**'
        elif enh.get('italic'): text = f'*{text}*'
        if url:
            text = f'[{text}]({url})'
        parts.append(text)
    return ''.join(parts)

def render(node_ids, indent=0):
    pfx = '  ' * indent
    for nid in node_ids:
        b = blocks.get(nid)
        if not b: continue
        t = b.get('type', 1)
        d = b.get('data', {})
        segs = d.get('segments', [])
        text = rt(segs)
        sub = b.get('subNodes', [])
        level = d.get('level', 1)

        if t == 0:
            # Sub-page
            print(f'{pfx}> [{b.get(\"title\", text)}](https://buildin.ai/{b.get(\"spaceId\", \"\")}/{nid})')
            print()
        elif t == 16:
            # Reference/link to another page. Previously unhandled → the link was
            # silently dropped from markdown (a real referenced page looked absent).
            # The /api/docs response includes the referenced block, so resolve its
            # title/space; fall back to the ref uuid when it is not embedded.
            ref = (d.get('ref') or {}).get('uuid', '')
            rb = blocks.get(ref, {})
            rtitle = rb.get('title') or text or '(referenced page)'
            rspace = rb.get('spaceId', '') or b.get('spaceId', '')
            print(f'{pfx}> [{rtitle}](https://buildin.ai/{rspace}/{ref})')
            print()
        elif t == 1:
            # Empty paragraph / text without segments
            if text:
                print(f'{pfx}{text}')
                print()
            else:
                print()
        elif t == 3:
            checked = '[x]' if d.get('checked') else '[ ]'
            print(f'{pfx}- {checked} {text}')
        elif t == 5:
            print(f'{pfx}1. {text}')
        elif t == 4:
            print(f'{pfx}- {text}')
        elif t == 6:
            print(f'{pfx}▶ {text}')
            print()
        elif t == 7:
            # level N → N решёток, чтобы round-trip с md-to-blocks.py был точным
            # (md-to-blocks по умолчанию: '#'→level1, '##'→level2, '###'→level3).
            h = '#' * min(level, 6)
            print(f'{pfx}{h} {text}')
            print()
        elif t == 38:
            # Сворачиваемый заголовок-секция — round-trip с маркером <!-- collapse -->
            h = '#' * min(level, 6)
            print(f'{pfx}<!-- collapse -->')
            print(f'{pfx}{h} {text}')
            print()
        elif t == 27:
            # Таблица: строки — дети типа 28, ячейки в collectionProperties
            fmt = d.get('format', {})
            cols = fmt.get('tableBlockColumnOrder', [])
            rows = []
            for rid in sub:
                rb = blocks.get(rid, {})
                cp = rb.get('data', {}).get('collectionProperties', {})
                rows.append([rt(cp.get(c, [])) for c in cols])
            for ri, row in enumerate(rows):
                print(f'{pfx}| ' + ' | '.join(row) + ' |')
                if ri == 0 and fmt.get('tableBlockRowHeader'):
                    print(f'{pfx}| ' + ' | '.join(['---'] * len(cols)) + ' |')
            print()
            continue
        elif t == 9:
            print(f'{pfx}---')
            print()
        elif t == 12:
            print(f'{pfx}> {text}')
            print()
        elif t == 13:
            icon = d.get('icon', {}).get('value', '')
            print(f'{pfx}> {icon} {text}')
            print()
        elif t == 14:
            oss = d.get('ossName', '')
            ext = d.get('extName', '')
            print(f'{pfx}![{text}]({oss})')
            print()
        elif t == 21:
            link = d.get('link', '')
            print(f'{pfx}[{text or link}]({link})')
            print()
        elif t == 23:
            print(f'{pfx}$$ {text} $$')
            print()
        elif t == 25:
            # Buildin хранит язык в format.language (data.language = null)
            lang = (d.get('language') or d.get('format', {}).get('language', '') or '').lower()
            print(f'{pfx}\`\`\`{lang}')
            print(f'{pfx}{text}')
            print(f'{pfx}\`\`\`')
            print()
        elif text:
            print(f'{pfx}{text}')
            print()

        if sub and t != 0:
            render(sub, indent + 1)

render(page.get('subNodes', []))
" "$PAGE_ID"
        ;;

    append-blocks)
        PAGE_ID=$(parse_id "$1")
        BLOCKS_JSON="$2"
        [[ -z "$PAGE_ID" || -z "$BLOCKS_JSON" ]] && { echo "Usage: append-blocks <page_id|url> <json_blocks>" >&2; exit 1; }

        SPACE_ID=$(get_space_id "$PAGE_ID")
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(buildin GET "/api/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uuid',''))")

        OPS=$(python3 "$SCRIPT_DIR/buildin-blocks.py" "$PAGE_ID" "$SPACE_ID" "$NOW" "$USER_ID" "$BLOCKS_JSON")

        transaction "$SPACE_ID" "$OPS"
        ;;

    insert-blocks-after)
        PAGE_ID=$(parse_id "$1")
        AFTER_BLOCK_ID=$(parse_id "$2")
        BLOCKS_JSON="$3"
        [[ -z "$PAGE_ID" || -z "$AFTER_BLOCK_ID" || -z "$BLOCKS_JSON" ]] && { echo "Usage: insert-blocks-after <page_id|url> <after_block_id> <json_blocks>" >&2; exit 1; }

        SPACE_ID=$(get_space_id "$PAGE_ID")
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(buildin GET "/api/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uuid',''))")

        OPS=$(python3 "$SCRIPT_DIR/buildin-blocks.py" "$PAGE_ID" "$SPACE_ID" "$NOW" "$USER_ID" "$BLOCKS_JSON" "$AFTER_BLOCK_ID")

        transaction "$SPACE_ID" "$OPS"
        ;;

    insert-blocks-before)
        PAGE_ID=$(parse_id "$1")
        BEFORE_BLOCK_ID=$(parse_id "$2")
        BLOCKS_JSON="$3"
        [[ -z "$PAGE_ID" || -z "$BEFORE_BLOCK_ID" || -z "$BLOCKS_JSON" ]] && { echo "Usage: insert-blocks-before <page_id|url> <before_block_id> <json_blocks>" >&2; exit 1; }

        # Найти предыдущего соседа целевого блока среди верхнеуровневых блоков
        # страницы. Если он есть — это обычный insert-after (проверенный путь);
        # если целевой блок первый — вставляем в начало через listBefore.
        PREV=$(buildin GET "/api/docs/$PAGE_ID" | python3 -c "
import json, sys
page_id, before = sys.argv[1], sys.argv[2]
blocks = json.load(sys.stdin).get('data', {}).get('blocks', {})
sub = blocks.get(page_id, {}).get('subNodes', [])
if before not in sub:
    sys.stderr.write('not_found')
    sys.exit(3)
i = sub.index(before)
print(sub[i - 1] if i > 0 else '')
" "$PAGE_ID" "$BEFORE_BLOCK_ID") || { echo "Error: блок $BEFORE_BLOCK_ID не найден среди верхнеуровневых блоков страницы (вложенные блоки не поддерживаются)" >&2; exit 1; }

        if [[ -n "$PREV" ]]; then
            bash "$SCRIPT_DIR/buildin-pages.sh" insert-blocks-after "$PAGE_ID" "$PREV" "$BLOCKS_JSON"
        else
            SPACE_ID=$(get_space_id "$PAGE_ID")
            NOW=$(python3 -c "import time; print(int(time.time()*1000))")
            USER_ID=$(buildin GET "/api/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uuid',''))")
            OPS=$(python3 "$SCRIPT_DIR/buildin-blocks.py" "$PAGE_ID" "$SPACE_ID" "$NOW" "$USER_ID" "$BLOCKS_JSON" "" "$BEFORE_BLOCK_ID")
            transaction "$SPACE_ID" "$OPS"
        fi
        ;;

    append-text)
        PAGE_ID=$(parse_id "$1")
        TEXT="$2"
        [[ -z "$PAGE_ID" || -z "$TEXT" ]] && { echo "Usage: append-text <page_id|url> <text>" >&2; exit 1; }

        BLOCKS=$(python3 -c "
import json, sys
text = sys.argv[1]
blocks = [{'type': 1, 'data': {'segments': [{'type': 0, 'text': text, 'enhancer': {}}]}}]
print(json.dumps(blocks))
" "$TEXT")

        bash "$SCRIPT_DIR/buildin-pages.sh" append-blocks "$PAGE_ID" "$BLOCKS"
        ;;

    append-image)
        PAGE_ID=$(parse_id "$1")
        FILE="$2"
        CAPTION="${3:-}"
        [[ -z "$PAGE_ID" || -z "$FILE" ]] && { echo "Usage: append-image <page_id|url> <image_file> [caption]" >&2; exit 1; }
        [[ ! -f "$FILE" ]] && { echo "Error: file not found: $FILE" >&2; exit 1; }

        # Метаданные файла считаем заранее: size+sha256 нужны getS3FileUploadInfo,
        # width/height — image-блоку (без них Buildin не может посчитать layout).
        META=$(python3 -c "
import hashlib, json, os, struct, sys

data = open(sys.argv[1], 'rb').read()

def dimensions(b):
    if b[:8] == b'\x89PNG\r\n\x1a\n':
        w, h = struct.unpack('>II', b[16:24])
        return w, h, 'png', 'image/png'
    if b[:6] in (b'GIF87a', b'GIF89a'):
        w, h = struct.unpack('<HH', b[6:10])
        return w, h, 'gif', 'image/gif'
    # JPEG: размеры из SOF-маркера как есть; EXIF Orientation не учитывается —
    # портретное фото с повёрнутой матрицей получит перепутанные width/height.
    if b[:2] == b'\xff\xd8':
        i = 2
        while i < len(b) - 9:
            if b[i] != 0xFF:
                i += 1
                continue
            marker = b[i + 1]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack('>HH', b[i + 5:i + 9])
                return w, h, 'jpg', 'image/jpeg'
            i += 2 + struct.unpack('>H', b[i + 2:i + 4])[0]
        raise SystemExit('jpeg: SOF marker not found')
    if b[:4] == b'RIFF' and b[8:12] == b'WEBP':
        if b[12:16] == b'VP8X':
            return (int.from_bytes(b[24:27], 'little') + 1,
                    int.from_bytes(b[27:30], 'little') + 1, 'webp', 'image/webp')
        if b[12:16] == b'VP8 ':
            w, h = struct.unpack('<HH', b[26:30])
            return w & 0x3FFF, h & 0x3FFF, 'webp', 'image/webp'
        if b[12:16] == b'VP8L':
            bits = int.from_bytes(b[21:25], 'little')
            return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1, 'webp', 'image/webp'
        raise SystemExit('webp: unsupported variant')
    raise SystemExit('unsupported image format (png/jpg/gif/webp)')

w, h, ext, mime = dimensions(data)
print(json.dumps({
    'fileName': os.path.basename(sys.argv[1]),
    'size': len(data),
    'sha256': hashlib.sha256(data).hexdigest(),
    'width': w, 'height': h, 'extName': ext, 'mimeType': mime,
}))
" "$FILE") || exit 1

        SPACE_ID=$(get_space_id "$PAGE_ID")
        [[ -z "$SPACE_ID" ]] && { echo "Error: cannot resolve spaceId for $PAGE_ID" >&2; exit 1; }

        # Дедуп как в родном клиенте: перед аплоадом ищем файл по sha256+size и
        # переиспользуем существующий ossName. Проверка оппортунистическая — в наших
        # пробах ответ был пуст даже для заведомых дублей; пусто -> грузим как обычно.
        S3_KEY=$(buildin POST "/api/search/resource" "$(python3 -c "
import json, sys
meta = json.loads(sys.argv[1])
print(json.dumps({'spaceId': sys.argv[2], 'sha256': meta['sha256'], 'size': meta['size']}))
" "$META" "$SPACE_ID")" | python3 -c "import sys, json; print((json.load(sys.stdin).get('data') or {}).get('ossName') or '')" 2>/dev/null) || S3_KEY=""

        if [[ -z "$S3_KEY" ]]; then
            UPLOAD_BODY=$(python3 -c "
import json, sys
meta = json.loads(sys.argv[1])
print(json.dumps({'spaceId': sys.argv[2], 'type': 'file',
                  'mimeType': meta['mimeType'], 'fileName': meta['fileName'],
                  'size': meta['size'], 'sha256': meta['sha256']}))
" "$META" "$SPACE_ID")
            UPLOAD_INFO=$(buildin POST "/api/upload/getS3FileUploadInfo" "$UPLOAD_BODY")
            S3_KEY=$(echo "$UPLOAD_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('s3Key',''))")
            UPLOAD_URL=$(echo "$UPLOAD_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uploadUrl',''))")
            # В stderr не печатаем весь ответ: в нём presigned URL (живёт 2 часа) — нечего
            # ему делать в логах/контексте LLM. Только code/msg.
            [[ -z "$S3_KEY" || -z "$UPLOAD_URL" ]] && { echo "Error: getS3FileUploadInfo failed: $(echo "$UPLOAD_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('code'), d.get('msg') or '')" 2>/dev/null)" >&2; exit 1; }

            # Content-Type подписан в presigned URL (SignedHeaders=content-type;host) —
            # без этого заголовка S3 отвечает 403 SignatureDoesNotMatch.
            MIME=$(echo "$META" | python3 -c "import sys,json; print(json.load(sys.stdin)['mimeType'])")
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: $MIME" --data-binary @"$FILE" "$UPLOAD_URL")
            [[ "$HTTP_CODE" != "200" ]] && { echo "Error: S3 upload failed (HTTP $HTTP_CODE)" >&2; exit 1; }
        fi

        BLOCKS=$(python3 -c "
import json, sys
meta = json.loads(sys.argv[1])
# Схема родного клиента: в segments — имя файла, подпись — отдельным data.caption
# (текст из segments UI у image-блока не отображает).
data = {
    'segments': [{'type': 0, 'text': meta['fileName'], 'enhancer': {}}],
    'display': 'image', 'ossName': sys.argv[2],
    'width': meta['width'], 'height': meta['height'],
    'size': meta['size'], 'extName': meta['extName'],
}
if len(sys.argv) > 3 and sys.argv[3]:
    data['caption'] = [{'type': 0, 'text': sys.argv[3], 'enhancer': {}}]
print(json.dumps([{'type': 14, 'data': data}]))
" "$META" "$S3_KEY" "$CAPTION")

        bash "$SCRIPT_DIR/buildin-pages.sh" append-blocks "$PAGE_ID" "$BLOCKS"
        echo "ossName: $S3_KEY"
        ;;

    delete-block)
        BLOCK_ID=$(parse_id "$1")
        [[ -z "$BLOCK_ID" ]] && { echo "Usage: delete-block <block_id>" >&2; exit 1; }

        # Resolve the block's real parent and use it as source of truth. A wrong block_id
        # (e.g. a page_id) otherwise returns a misleading code 200; for a page that means
        # status=-1 on the page block — silently deleting the whole page.
        DETECTED_PARENT=$(buildin GET "/api/blocks/$BLOCK_ID" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('parentId',''))")
        [[ -z "$DETECTED_PARENT" ]] && { echo "Error: $BLOCK_ID not found or is a page (no parent block); refusing to delete" >&2; exit 1; }
        PARENT_ID="$DETECTED_PARENT"

        SPACE_ID=$(get_space_id "$BLOCK_ID")
        NOW=$(python3 -c "import time; print(int(time.time()*1000))")
        USER_ID=$(buildin GET "/api/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uuid',''))")

        OPS=$(python3 -c "
import json, sys
block_id, parent_id, now, user_id = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
ops = [
    {'id': block_id, 'command': 'update', 'table': 'block', 'path': [],
     'args': {'status': -1, 'updatedBy': user_id, 'updatedAt': now}},
    {'id': parent_id, 'command': 'listRemove', 'table': 'block', 'path': ['subNodes'],
     'args': {'uuid': block_id}}
]
print(json.dumps(ops))
" "$BLOCK_ID" "$PARENT_ID" "$NOW" "$USER_ID")

        transaction "$SPACE_ID" "$OPS"
        ;;

    help|*)
        echo "Buildin Pages — операции со страницами и блоками (UI API)"
        echo "Принимает page_id как UUID или URL buildin.ai"
        echo ""
        echo "Commands:"
        echo "  get <id|url>                             — получить страницу (JSON, все блоки)"
        echo "  title <id|url>                           — заголовок страницы"
        echo "  read <id|url>                            — прочитать как markdown"
        echo "  create <parent_id|url> <title>           — создать дочернюю страницу"
        echo "  update <id|url> <title>                  — обновить заголовок"
        echo "  archive <id|url>                         — архивировать (status: -1)"
        echo "  get-blocks <id|url>                      — блоки страницы (JSON; id блока в поле uuid)"
        echo "  comments <id|url[#block_id]> [block_id]  — комментарии страницы или блока (якорь #block-uuid фильтрует)"
        echo "  append-blocks <id|url> <json_blocks>     — добавить блоки в конец страницы"
        echo "  insert-blocks-after <id|url> <after_block_id> <json_blocks>   — вставить блоки после блока"
        echo "  insert-blocks-before <id|url> <before_block_id> <json_blocks> — вставить блоки перед блоком"
        echo "  append-text <id|url> <text>              — добавить текстовый параграф"
        echo "  append-image <id|url> <image_file> [caption] — загрузить картинку (png/jpg/gif/webp) и добавить image-блок"
        echo "  delete-block <block_id> [parent_id]      — удалить блок"
        ;;
esac
