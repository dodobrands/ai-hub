#!/usr/bin/env python3
"""
Buildin page updater: delete all blocks and replace with markdown content.
Usage: python3 buildin_publish.py <page_id> <markdown_file> [skip_h1]
"""
import json, re, sys, uuid, time, os, subprocess, urllib.request, urllib.error

# ---- Config ----
BUILDIN_BASE = "https://buildin.ai"
SPACE_ID = "241db73f-2322-47e8-bbb5-11481aca3c40"
BATCH_SIZE = 25  # blocks per append transaction
API_TRIES = 4          # сетевые обрывы к buildin.ai не редкость
API_TIMEOUT = 120
API_BACKOFF = 4

def load_token():
    env_path = os.path.expanduser("~/dodo/ai-hub/.env")
    with open(env_path) as f:
        for line in f:
            if line.startswith("BUILDIN_UI_TOKEN="):
                return line.strip().split("=", 1)[1]
    raise RuntimeError("BUILDIN_UI_TOKEN not found in .env")

def api(method, endpoint, body=None, token=None):
    url = BUILDIN_BASE + endpoint
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    req.add_header("x-platform", "web-cookie")
    req.add_header("x-app-origin", "web")
    req.add_header("x-product", "buildin")
    req.add_header("app_version_name", "1.146.0")
    # Повторяем сетевые обрывы: публикация сначала удаляет блоки страницы, и
    # если append упадёт на таймауте, страница останется разрушенной. HTTP-ошибку
    # повторять нельзя — она про сам запрос, а не про сеть.
    for attempt in range(API_TRIES):
        try:
            with urllib.request.urlopen(req, timeout=API_TIMEOUT) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            body_txt = e.read().decode()
            raise RuntimeError(f"HTTP {e.code}: {body_txt[:300]}")
        except Exception as e:
            if attempt == API_TRIES - 1:
                raise RuntimeError("сеть недоступна после %d попыток: %s: %s"
                                   % (API_TRIES, type(e).__name__, e))
            time.sleep(API_BACKOFF * (attempt + 1))

def transaction(ops, token):
    body = {
        "requestId": str(uuid.uuid4()),
        "transactions": [{
            "id": str(uuid.uuid4()),
            "spaceId": SPACE_ID,
            "operations": ops
        }]
    }
    return api("POST", "/api/records/transactions", body, token)

def get_user_id(token):
    me = api("GET", "/api/users/me", token=token)
    return me["data"]["uuid"]

def get_blocks_info(page_id, token):
    """Returns (all_block_ids, child_page_block_ids).
    type=0 blocks are child page references — must NOT be deleted."""
    data = api("GET", f"/api/docs/{page_id}", token=token)
    all_blocks = data.get("data", {}).get("blocks", {})
    page = all_blocks.get(page_id, {})
    sub_nodes = page.get("subNodes", [])
    child_ids = [bid for bid in sub_nodes if all_blocks.get(bid, {}).get("type") == 0]
    delete_ids = [bid for bid in sub_nodes if bid not in child_ids]
    if child_ids:
        print(f"  ⚠️  Preserving {len(child_ids)} child page block(s): {child_ids}")
    return delete_ids, child_ids

def delete_all_blocks(page_id, block_ids, user_id, token):
    now = int(time.time() * 1000)
    ops = []
    for bid in block_ids:
        ops.append({"id": bid, "command": "update", "table": "block", "path": [],
                    "args": {"status": -1, "updatedBy": user_id, "updatedAt": now}})
        ops.append({"id": page_id, "command": "listRemove", "table": "block",
                    "path": ["subNodes"], "args": {"uuid": bid}})
    ops.append({"id": page_id, "command": "update", "table": "block", "path": [],
                "args": {"updatedBy": user_id, "updatedAt": now}})
    # Batch into chunks of 60 ops (30 blocks)
    chunk_size = 60
    for i in range(0, len(ops), chunk_size):
        chunk = ops[i:i+chunk_size]
        transaction(chunk, token)
        print(f"  Deleted batch {i//chunk_size + 1} ({len([o for o in chunk if o['command']=='update' and 'status' in o.get('args',{})])//1} ops)")

# ---- Markdown → Buildin blocks ----

def parse_inline(text):
    segs = []
    pos = 0
    pattern = re.compile(r'\*\*(.*?)\*\*|`(.*?)`|\[(.*?)\]\((.*?)\)')
    for m in pattern.finditer(text):
        if m.start() > pos:
            plain = text[pos:m.start()]
            if plain:
                segs.append({"type": 0, "text": plain, "enhancer": {}})
        full = m.group(0)
        if full.startswith("**"):
            segs.append({"type": 0, "text": m.group(1), "enhancer": {"bold": True}})
        elif full.startswith("`"):
            segs.append({"type": 0, "text": m.group(2), "enhancer": {"code": True}})
        else:
            segs.append({"type": 3, "text": m.group(3), "url": m.group(4), "enhancer": {}})
        pos = m.end()
    if pos < len(text):
        rest = text[pos:]
        if rest:
            segs.append({"type": 0, "text": rest, "enhancer": {}})
    if not segs:
        segs.append({"type": 0, "text": text, "enhancer": {}})
    return segs

def table_to_text(table_lines):
    rows = []
    for line in table_lines:
        if re.match(r'^\|[-\s|:]+\|$', line.strip()):
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        rows.append(' | '.join(cells))
    return '\n'.join(rows)

def md_to_blocks(content, skip_h1=True):
    blocks = []
    lines = content.split('\n')
    i = 0
    first_h1_skipped = False

    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()

        # Empty
        if not line.strip():
            i += 1
            continue

        # Divider
        if re.match(r'^[-*_]{3,}\s*$', line):
            blocks.append({"type": 9, "data": {}})
            i += 1
            continue

        # Heading
        m = re.match(r'^(#{1,6})\s+(.*)', line)
        if m:
            level = min(len(m.group(1)), 3)
            text = m.group(2).strip()
            if skip_h1 and level == 1 and not first_h1_skipped:
                first_h1_skipped = True
                i += 1
                continue
            blocks.append({"type": 7, "data": {"level": level, "segments": parse_inline(text)}})
            i += 1
            continue

        # Code block
        if line.startswith('```'):
            lang = line[3:].strip()
            code_lines = []
            i += 1
            while i < len(lines) and not lines[i].rstrip().startswith('```'):
                code_lines.append(lines[i].rstrip())
                i += 1
            i += 1
            blocks.append({"type": 25, "data": {
                "language": lang or "text",
                "segments": [{"type": 0, "text": '\n'.join(code_lines), "enhancer": {}}]
            }})
            continue

        # Bullet list
        m = re.match(r'^[-*+]\s+(.*)', line)
        if m:
            blocks.append({"type": 4, "data": {"segments": parse_inline(m.group(1).strip())}})
            i += 1
            continue

        # Blockquote → callout
        m = re.match(r'^>\s*(.*)', line)
        if m:
            blocks.append({"type": 13, "data": {"segments": parse_inline(m.group(1).strip())}})
            i += 1
            continue

        # Table
        if line.startswith('|'):
            table_lines = []
            while i < len(lines) and lines[i].rstrip().startswith('|'):
                table_lines.append(lines[i].rstrip())
                i += 1
            blocks.append({"type": 25, "data": {
                "language": "text",
                "segments": [{"type": 0, "text": table_to_text(table_lines), "enhancer": {}}]
            }})
            continue

        # Paragraph (accumulate)
        para = [line]
        i += 1
        while i < len(lines):
            nxt = lines[i].rstrip()
            if not nxt.strip():
                break
            if (nxt.startswith('#') or nxt.startswith('```') or nxt.startswith('|') or
                    nxt.startswith('>') or re.match(r'^[-*_]{3,}\s*$', nxt) or
                    re.match(r'^[-*+]\s+', nxt)):
                break
            para.append(nxt)
            i += 1
        blocks.append({"type": 1, "data": {"segments": parse_inline(' '.join(para))}})

    return blocks

def _block_ops(block, parent_id, user_id, now, after=None):
    """Операции на один блок и, рекурсивно, на его children.

    Вложенные блоки обязательны для таблиц: md-to-blocks отдаёт таблицу (27) с
    children-строками (28), и без их публикации на странице остаётся пустая
    рамка. Порядок строк держится через after — без него строки перемешиваются.
    """
    bid = str(uuid.uuid4())
    ops = [{
        "id": bid,
        "command": "set",
        "table": "block",
        "path": [],
        "args": {
            "uuid": bid,
            "spaceId": SPACE_ID,
            "parentId": parent_id,
            "type": block["type"],
            "textColor": "",
            "backgroundColor": "",
            "status": 1,
            "permissions": [],
            "createdAt": now,
            "createdBy": user_id,
            "updatedBy": user_id,
            "updatedAt": now,
            "data": {**{"pageFixedWidth": True, "format": {"commentAlignment": "top"}},
                     **block["data"]}
        }
    }]
    attach = {"uuid": bid}
    if after:
        attach["after"] = after
    ops.append({"id": parent_id, "command": "listAfter", "table": "block",
                "path": ["subNodes"], "args": attach})
    prev = None
    for child in block.get("children") or []:
        child_ops, prev = _block_ops(child, bid, user_id, now, after=prev)
        ops.extend(child_ops)
    return ops, bid


def append_blocks_batch(page_id, blocks, user_id, token):
    now = int(time.time() * 1000)
    ops = []
    for block in blocks:
        block_ops, _ = _block_ops(block, page_id, user_id, now)
        ops.extend(block_ops)
    ops.append({"id": page_id, "command": "update", "table": "block", "path": [],
                "args": {"updatedBy": user_id, "updatedAt": now}})
    transaction(ops, token)

def convert_markdown(md_file, skip_h1=True):
    """Разбор markdown внешним md-to-blocks.py, а не встроенным конвертером.

    Встроенный md_to_blocks ниже — упрощённая копия: он не отдаёт children у
    таблиц, поэтому таблицы публиковались пустой рамкой, и не знает про ширины
    колонок, языки блоков кода и вложенность списков. Держать два конвертера
    means держать два набора багов; внешний поддерживается и покрыт тестами.
    """
    conv = os.path.join(os.path.dirname(os.path.abspath(__file__)), "md-to-blocks.py")
    if not os.path.exists(conv):
        raise RuntimeError("md-to-blocks.py рядом не найден: " + conv)
    cmd = [sys.executable, conv, md_file]
    if not skip_h1:
        cmd.append("--shift-headings")
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise RuntimeError("md-to-blocks.py упал: " + (r.stderr or "")[:300])
    return json.loads(r.stdout)


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 buildin_publish.py <page_id> <markdown_file> [skip_h1=true]")
        sys.exit(1)

    page_id = sys.argv[1]
    md_file = sys.argv[2]
    skip_h1 = sys.argv[3].lower() != 'false' if len(sys.argv) > 3 else True

    print(f"Loading token...")
    token = load_token()
    user_id = get_user_id(token)
    print(f"User ID: {user_id[:8]}...")

    print(f"\nStep 1: Get existing blocks...")
    delete_ids, child_ids = get_blocks_info(page_id, token)
    print(f"  Found {len(delete_ids)} blocks to delete, {len(child_ids)} child page(s) to preserve")

    if delete_ids:
        print(f"\nStep 2: Delete {len(delete_ids)} existing blocks...")
        delete_all_blocks(page_id, delete_ids, user_id, token)
        print(f"  Done!")

    print(f"\nStep 3: Parse markdown {md_file}...")
    blocks = convert_markdown(md_file, skip_h1=skip_h1)
    rows = sum(len(b.get("children") or []) for b in blocks)
    print(f"  Converted to {len(blocks)} blocks ({rows} nested)")

    print(f"\nStep 4: Append {len(blocks)} blocks in batches of {BATCH_SIZE}...")
    for i in range(0, len(blocks), BATCH_SIZE):
        batch = blocks[i:i+BATCH_SIZE]
        append_blocks_batch(page_id, batch, user_id, token)
        print(f"  Batch {i//BATCH_SIZE + 1}: {len(batch)} blocks appended")

    print(f"\n✅ Done! Page updated: https://buildin.ai/{SPACE_ID}/{page_id}")

if __name__ == "__main__":
    main()
