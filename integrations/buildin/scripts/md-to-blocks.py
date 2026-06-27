#!/usr/bin/env python3
"""Конвертер Markdown → дерево блоков Buildin UI API (с вложенностью).

Печатает JSON-массив блоков, пригодный для `buildin-pages.sh append-blocks`.
Расширенные блоки (таблицы, сворачиваемые секции, вложенные списки) выражаются
полем "children" — их создаёт buildin-blocks.py с правильными parentId/subNodes.

Usage:
    md-to-blocks.py <markdown_file> [--shift-headings] > blocks.json
    cat doc.md | md-to-blocks.py - [--shift-headings] > blocks.json

Поддержка Markdown:
- # … ###### заголовки                 → heading (7), level 1–3
- <!-- collapse --> перед заголовком   → сворачиваемая секция (toggle-heading 38)
                                          со всем содержимым до след. заголовка
                                          того же/высшего уровня в children
- -, * списки (вложенность по отступу) → bulleted (4) + children
- 1. 2. нумерованные списки            → numbered (5)
- - [ ] / - [x]                        → todo (3)
- > выноска                            → callout (13); ведущий эмодзи → иконка
- ---                                  → divider (9)
- ``` код ```                          → code (25); ```mermaid → preview-диаграмма
- | таблица |                          → native table (27 + строки 28)
- абзацы                               → paragraph (1)

Inline:
- **bold**, *italic*, `code`, [text](url)

Опции:
- --shift-headings   сдвинуть уровни на 1 (## → level 1) — крупные секции

Не поддерживается: изображения (требуют upload в S3), цвета текста
(нет в синтаксисе Markdown), формулы.
"""
import json
import re
import sys
import uuid

COLLAPSE_MARKER = "<!-- collapse -->"

INLINE_PATTERN = re.compile(
    r"(?P<code>`[^`]+`)"
    r"|(?P<link>\[[^\]]+\]\([^)]+\))"
    r"|(?P<bold>\*\*[^*]+\*\*)"
    r"|(?P<italic>(?<![\*])\*[^*]+\*(?![\*]))"
)
LINK_PARTS = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")

# Известные языки кода → отображаемое имя в format.language (как делает Buildin).
CODE_LANG_DISPLAY = {
    "mermaid": "Mermaid", "json": "JSON", "swift": "Swift", "python": "Python",
    "bash": "Bash", "shell": "Shell", "sh": "Shell", "js": "JavaScript",
    "javascript": "JavaScript", "ts": "TypeScript", "typescript": "TypeScript",
    "kotlin": "Kotlin", "java": "Java", "go": "Go", "ruby": "Ruby", "rust": "Rust",
    "c": "C", "cpp": "C++", "objc": "Objective-C", "yaml": "YAML", "yml": "YAML",
    "sql": "SQL", "html": "HTML", "css": "CSS", "xml": "XML", "diff": "Diff",
    "markdown": "Markdown", "plain": "Plain Text",
}


def parse_inline(text):
    """Текст с inline-разметкой → список сегментов Buildin."""
    if not text:
        return [{"type": 0, "text": "", "enhancer": {}}]
    segments = []
    pos = 0
    for m in INLINE_PATTERN.finditer(text):
        if m.start() > pos:
            segments.append({"type": 0, "text": text[pos:m.start()], "enhancer": {}})
        if m.group("code"):
            segments.append({"type": 0, "text": m.group("code")[1:-1], "enhancer": {"code": True}})
        elif m.group("link"):
            lp = LINK_PARTS.match(m.group("link"))
            if lp:
                segments.append({"type": 3, "text": lp.group(1), "url": lp.group(2), "enhancer": {}})
        elif m.group("bold"):
            segments.append({"type": 0, "text": m.group("bold")[2:-2], "enhancer": {"bold": True}})
        elif m.group("italic"):
            segments.append({"type": 0, "text": m.group("italic")[1:-1], "enhancer": {"italic": True}})
        pos = m.end()
    if pos < len(text):
        segments.append({"type": 0, "text": text[pos:], "enhancer": {}})
    return segments or [{"type": 0, "text": "", "enhancer": {}}]


EMOJI_RE = re.compile(
    "^(?:[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F000-\U0001F0FF"
    "\U00002190-\U000021FF\U00002B00-\U00002BFF™ℹ❤]️?)"
)


def indent_width(line):
    """Ширина отступа в «уровнях» (таб или 2 пробела = 1 уровень)."""
    n = 0
    for ch in line:
        if ch == "\t":
            n += 1
        elif ch == " ":
            n += 1
        else:
            break
    return n // 2 if "\t" not in line[:n] else line[:n].count("\t")


LIST_RE = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)$")
TODO_RE = re.compile(r"^(\s*)[-*]\s+\[([ xX])\]\s+(.*)$")


def list_item_block(marker, content):
    """Создать блок пункта списка по маркеру."""
    todo = TODO_RE.match(marker + " " + content) if False else None  # handled by caller
    segs = parse_inline(content)
    if marker.endswith("."):
        return {"type": 5, "data": {"segments": segs}}
    return {"type": 4, "data": {"segments": segs}}


def parse_list(lines, start):
    """Разобрать группу подряд идущих list-строк начиная с lines[start].

    Возвращает (список блоков верхнего уровня с children, next_index).
    Вложенность строится по ширине отступа.
    """
    items = []  # (indent_level, block)
    i = start
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            # пустая строка не прерывает список, если дальше снова список
            nxt = i + 1
            if nxt < len(lines) and (LIST_RE.match(lines[nxt])):
                i += 1
                continue
            break
        mt = TODO_RE.match(line)
        ml = LIST_RE.match(line)
        if mt:
            indent = len(mt.group(1).replace("\t", "  ")) // 2
            checked = mt.group(2).lower() == "x"
            block = {"type": 3, "data": {"segments": parse_inline(mt.group(3)), "checked": checked}}
        elif ml:
            indent = len(ml.group(1).replace("\t", "  ")) // 2
            block = list_item_block(ml.group(2), ml.group(3))
        else:
            break
        items.append((indent, block))
        i += 1

    # Свернуть плоский (indent, block) в дерево по отступам
    roots = []
    stack = []  # (indent, block)
    for indent, block in items:
        while stack and stack[-1][0] >= indent:
            stack.pop()
        if stack:
            stack[-1][1].setdefault("children", []).append(block)
        else:
            roots.append(block)
        stack.append((indent, block))
    return roots, i


def code_data(lang, body):
    """data для блока кода (25). mermaid — с preview-рендером."""
    seg = [{"type": 0, "text": body, "enhancer": {}}]
    low = (lang or "").strip().lower()
    fmt = {"commentAlignment": "top"}
    if low == "mermaid":
        fmt["language"] = "Mermaid"
        fmt["codePreviewFormat"] = "preview"
    elif low:
        fmt["language"] = CODE_LANG_DISPLAY.get(low, lang.strip().capitalize())
    return {"language": None, "format": fmt, "segments": seg}


def parse_table(lines, start):
    """Markdown pipe-таблица → блок table (27) с children-строками (28)."""
    table_lines = []
    i = start
    while i < len(lines) and lines[i].lstrip().startswith("|"):
        table_lines.append(lines[i].strip())
        i += 1
    raw = [[c.strip() for c in tl.strip().strip("|").split("|")] for tl in table_lines]

    def is_sep(cells):
        ne = [c for c in cells if c != ""]
        return bool(ne) and all(re.fullmatch(r":?-{2,}:?", c) for c in ne)

    rows = [r for r in raw if not is_sep(r)]
    if not rows:
        return None, i
    ncols = max(len(r) for r in rows)
    col_ids = [str(uuid.uuid4()) for _ in range(ncols)]
    children = []
    for r in rows:
        r = r + [""] * (ncols - len(r))
        cp = {col_ids[ci]: parse_inline(cell) for ci, cell in enumerate(r)}
        children.append({"type": 28, "data": {"collectionProperties": cp}})
    table = {
        "type": 27,
        "data": {"segments": [], "format": {
            "commentAlignment": "top",
            "tableBlockRowHeader": True,
            "tableBlockColumnOrder": col_ids,
        }},
        "children": children,
    }
    return table, i


def heading_level(hashes, shift):
    n = len(hashes)
    if shift:
        n = max(1, n - 1)
    return n


def parse_md(md, shift=False):
    """Markdown → плоский список блоков (с пометкой collapse у заголовков)."""
    blocks = []
    lines = md.split("\n")
    i = 0
    pending_collapse = False
    while i < len(lines):
        line = lines[i]

        if line.strip() == COLLAPSE_MARKER:
            pending_collapse = True
            i += 1
            continue

        if not line.strip():
            i += 1
            continue

        # Код
        if line.lstrip().startswith("```"):
            lang = line.lstrip()[3:].strip()
            body = []
            i += 1
            while i < len(lines) and not lines[i].lstrip().startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1  # закрывающий ```
            blocks.append({"type": 25, "data": code_data(lang, "\n".join(body))})
            continue

        # Divider
        if line.strip() == "---":
            blocks.append({"type": 9, "data": {}})
            i += 1
            continue

        # Заголовок
        mh = re.match(r"^(#{1,6})\s+(.+)$", line)
        if mh:
            level = heading_level(mh.group(1), shift)
            blocks.append({
                "type": 7,
                "data": {"level": min(level, 3), "segments": parse_inline(mh.group(2))},
                "_collapse": pending_collapse,
                "_level": level,
            })
            pending_collapse = False
            i += 1
            continue

        # Callout (выноска из подряд идущих > строк)
        if line.lstrip().startswith(">"):
            quote, icon = [], "💡"
            first = True
            while i < len(lines) and lines[i].lstrip().startswith(">"):
                q = lines[i].lstrip()[1:].lstrip()
                if first:
                    em = EMOJI_RE.match(q)
                    if em:
                        icon = em.group(0)
                        q = q[len(em.group(0)):].lstrip()
                    first = False
                quote.append(q)
                i += 1
            blocks.append({"type": 13, "data": {
                "icon": {"type": "emoji", "value": icon},
                "segments": parse_inline("\n".join(quote).strip()),
            }})
            continue

        # Таблица
        if line.lstrip().startswith("|"):
            table, i = parse_table(lines, i)
            if table:
                blocks.append(table)
            continue

        # Списки (вкл. вложенные и todo)
        if LIST_RE.match(line):
            items, i = parse_list(lines, i)
            blocks.extend(items)
            continue

        # Абзац (склеиваем подряд идущие строки)
        para = [line]
        i += 1
        while i < len(lines) and lines[i].strip() and not _starts_block(lines[i]):
            para.append(lines[i])
            i += 1
        blocks.append({"type": 1, "data": {"segments": parse_inline(" ".join(p.strip() for p in para))}})

    return blocks


def _starts_block(line):
    s = line.lstrip()
    if not s:
        return True
    if s.startswith(("#", ">", "```", "|")):
        return True
    if line.strip() in ("---", COLLAPSE_MARKER):
        return True
    return bool(LIST_RE.match(line))


def group_collapses(blocks):
    """Свернуть помеченные <!-- collapse --> заголовки в toggle-heading (38)."""
    out = []
    i = 0
    while i < len(blocks):
        b = blocks[i]
        if b.get("type") == 7 and b.get("_collapse"):
            level = b.get("_level", 1)
            children = []
            j = i + 1
            while j < len(blocks):
                nb = blocks[j]
                if nb.get("type") == 7 and nb.get("_level", 99) <= level:
                    break
                children.append(_clean(nb))
                j += 1
            out.append({
                "type": 38,
                "data": {"level": min(level, 4), "segments": b["data"]["segments"]},
                "children": children,
            })
            i = j
        else:
            out.append(_clean(b))
            i += 1
    return out


def _clean(b):
    """Убрать служебные поля (_collapse/_level) перед выводом."""
    return {k: v for k, v in b.items() if not k.startswith("_")}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    shift = "--shift-headings" in sys.argv
    if not args:
        print("Usage: md-to-blocks.py <markdown_file|-> [--shift-headings]", file=sys.stderr)
        sys.exit(1)
    src = sys.stdin.read() if args[0] == "-" else open(args[0], encoding="utf-8").read()
    blocks = group_collapses(parse_md(src, shift=shift))
    print(json.dumps(blocks, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
