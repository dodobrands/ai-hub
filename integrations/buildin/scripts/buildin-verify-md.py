#!/usr/bin/env python3
"""Сверка опубликованной страницы Buildin с исходным markdown.

Проверяет то, на чём публикация ломается молча: пропавшие блоки, съеденные
строки таблиц, сырую markdown-разметку внутри ячеек, слетевшие опции страницы
и ширины таблиц за бюджетом. Пустой список расхождений — единственный
приемлемый результат.

    buildin-verify-md.py <page_id> <markdown_file> [--json]

Код возврата: 0 — расхождений нет, 1 — есть, 2 — страницу или файл не прочитать.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

BUDGET = 1240
API = "https://buildin.ai"


def load_token():
    for path in (os.path.join(os.path.dirname(__file__), "..", "..", "..", ".env"),
                 os.path.expanduser("~/dodo/ai-hub/.env")):
        path = os.path.abspath(path)
        if not os.path.exists(path):
            continue
        for line in open(path, encoding="utf-8"):
            if line.startswith("BUILDIN_UI_TOKEN="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise RuntimeError("BUILDIN_UI_TOKEN not found in .env")


def api_get(path, token):
    req = urllib.request.Request(API + path, headers={
        "Authorization": "Bearer " + token, "x-platform": "web-cookie",
        "x-app-origin": "web", "x-product": "buildin",
        "app_version_name": "1.146.0", "Accept": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read().decode())


def page_facts(page_id, token):
    """Заголовки, строки таблиц, ширины и опции страницы — как их видит Buildin."""
    blocks = api_get("/api/docs/" + page_id, token)["data"]["blocks"]
    page = blocks[page_id]
    sub = page.get("subNodes") or []

    def text(b):
        return "".join(s.get("text", "") for s in ((b.get("data") or {}).get("segments") or []))

    heads, tables, raw_cells, raw_inline, empty, links = [], [], 0, 0, 0, 0
    over_budget, width_sums = [], []
    for bid in sub:
        b = blocks.get(bid)
        if not b:
            continue
        t = b.get("type")
        if t == 7 or t == 38:            # 38 — сворачиваемый заголовок
            heads.append(text(b))
        elif t == 27:
            fmt = ((b.get("data") or {}).get("format") or {})
            cols = fmt.get("tableBlockColumnOrder") or []
            cw = fmt.get("tableBlockColumnFormat") or {}
            total = sum((cw.get(c) or {}).get("width") or 0 for c in cols)
            width_sums.append(total)
            if total > BUDGET:
                over_budget.append(total)
            rows = b.get("subNodes") or []
            for rid in rows:
                rb = blocks.get(rid)
                if not rb:
                    continue
                cp = (rb.get("data") or {}).get("collectionProperties") or {}
                for c in cols:
                    for s in (cp.get(c) or []):
                        if re.search(r"`|\*\*", s.get("text", "")):
                            raw_cells += 1
            tables.append(len(rows))
        elif t == 1:
            body = text(b)
            if not body.strip():
                empty += 1
            if re.search(r"`|\*\*", body):
                raw_inline += 1
        if t != 25:                       # в блоке кода бэктики законны
            for s in ((b.get("data") or {}).get("segments") or []):
                if s.get("type") == 3:
                    links += 1
    data = page.get("data") or {}
    return {"headings": heads, "tables": tables, "rows": sum(tables),
            "raw_in_cells": raw_cells, "raw_in_paragraphs": raw_inline,
            "empty_paragraphs": empty, "links": links,
            "width_sums": width_sums, "over_budget": over_budget,
            "pageFixedWidth": data.get("pageFixedWidth"),
            "directoryMenu": data.get("directoryMenu")}


def md_facts(path):
    """То же из исходника. Строки в блоках кода начинаются с | — их не считаем."""
    src = open(path, encoding="utf-8").read()
    heads, rows, in_fence = [], 0, False
    for line in src.split("\n"):
        if line.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if re.match(r"^#{2,4}\s", line):
            heads.append(re.sub(r"^#{2,4}\s+", "", line).strip())
        elif line.startswith("|") and not re.match(r"^\|[\s:\-|]+\|$", line):
            rows += 1
    return {"headings": heads, "rows": rows}


def strip_inline(s):
    s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)
    return s.replace("`", "").replace("**", "").strip()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_json = "--json" in sys.argv
    if len(args) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    page_id, md_path = args
    try:
        token = load_token()
        page = page_facts(page_id, token)
    except urllib.error.HTTPError as e:
        print("error:page_read_failed HTTP %d" % e.code, file=sys.stderr)
        return 2
    except Exception as e:
        print("error:%s %s" % (type(e).__name__, e), file=sys.stderr)
        return 2
    md = md_facts(md_path)

    problems = []
    ph = [strip_inline(h) for h in page["headings"]]
    mh = [strip_inline(h) for h in md["headings"]]
    if ph != mh:
        missing = [h for h in mh if h not in ph]
        extra = [h for h in ph if h not in mh]
        if missing or extra:
            problems.append("headings differ: missing %s, extra %s" % (missing, extra))
        else:
            problems.append("headings out of order")
    if page["rows"] != md["rows"]:
        problems.append("table rows: page %d, source %d" % (page["rows"], md["rows"]))
    if page["raw_in_cells"]:
        problems.append("raw markdown in %d table cells" % page["raw_in_cells"])
    if page["raw_in_paragraphs"]:
        problems.append("raw markdown in %d paragraphs" % page["raw_in_paragraphs"])
    if page["empty_paragraphs"]:
        problems.append("%d empty paragraphs" % page["empty_paragraphs"])
    if page["over_budget"]:
        problems.append("tables wider than %d px: %s" % (BUDGET, page["over_budget"]))
    if page["pageFixedWidth"] is not False:
        problems.append("pageFixedWidth is %r, expected False" % page["pageFixedWidth"])
    if page["directoryMenu"] is not True:
        problems.append("directoryMenu is %r, expected True" % page["directoryMenu"])

    if as_json:
        print(json.dumps({"problems": problems, "page": page, "source": md},
                         ensure_ascii=False, indent=1))
    else:
        print("headings %d/%d, tables %d, rows %d/%d, links %d, widths %s" % (
            len(page["headings"]), len(md["headings"]), len(page["tables"]),
            page["rows"], md["rows"], page["links"],
            "%d-%d" % (min(page["width_sums"]), max(page["width_sums"]))
            if page["width_sums"] else "n/a"))
        if problems:
            for p in problems:
                print("  problem: " + p)
        else:
            print("ok")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
