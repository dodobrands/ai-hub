#!/usr/bin/env python3
"""buildin-verify-md.py: сверка видит всю страницу и считает те же заголовки.

Зачем: обход страницы шёл только по верхнему уровню subNodes, а group_collapses
складывает всё содержимое свёрнутой секции внутрь блока type-38. Поэтому любой
документ с <!-- collapse --> давал ложные «missing headings» и «table rows: page
0». Второе расхождение — уровни: исходник считался по H2–H4, страница по всем
заголовкам сразу, так что опубликованный H1 или H5 превращался в «extra».

Сети нет: urlopen застаблен фикстурой страницы.
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import urllib.request

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(TESTS_DIR, os.pardir, "scripts", "buildin-verify-md.py")
PAGE_ID = "11111111-2222-3333-4444-555555555555"

FAILS = []


def check(cond, name, detail=""):
    if cond:
        print("ok:   " + name)
    else:
        print("FAIL: " + name + (" — " + detail if detail else ""))
        FAILS.append(name)


def load_module():
    spec = importlib.util.spec_from_file_location("verify_md", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.load_token = lambda: "test-token"
    return mod


class Resp:
    def __init__(self, payload):
        self._payload = json.dumps(payload).encode()

    def read(self):
        return self._payload


def heading(text):
    return {"type": 7, "data": {"segments": [{"text": text}]}}


def collapse(text, sub):
    return {"type": 38, "data": {"segments": [{"text": text}]}, "subNodes": sub}


def table(rows):
    """rows — список списков ячеек, включая шапку."""
    cols = ["col-a", "col-b"]
    fmt = {"tableBlockColumnOrder": cols,
           "tableBlockColumnFormat": {c: {"width": 300} for c in cols}}
    ids = []
    blocks = {}
    for n, cells in enumerate(rows):
        rid = "row-%d" % n
        ids.append(rid)
        blocks[rid] = {"type": 28, "data": {"collectionProperties":
                       {c: [{"text": v}] for c, v in zip(cols, cells)}}}
    blocks["tbl"] = {"type": 27, "data": {"format": fmt}, "subNodes": ids}
    return blocks


def make_page(sub_ids, blocks):
    page = {"subNodes": sub_ids,
            "data": {"pageFixedWidth": False, "directoryMenu": True}}
    doc = {PAGE_ID: page}
    doc.update(blocks)
    return doc


def run(mod, doc, md_text, extra_args=(), page_ref=PAGE_ID, paths=None):
    def fake(req, timeout=None):
        if paths is not None:
            paths.append(req.full_url.split("buildin.ai", 1)[-1])
        return Resp({"data": {"blocks": doc}})
    original = urllib.request.urlopen
    urllib.request.urlopen = fake
    argv = sys.argv
    tmp = tempfile.mkdtemp()
    md = os.path.join(tmp, "doc.md")
    with io.open(md, "w", encoding="utf-8") as fh:
        fh.write(md_text)
    out = io.StringIO()
    try:
        sys.argv = ["buildin-verify-md.py", page_ref, md] + list(extra_args)
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = mod.main()
    finally:
        urllib.request.urlopen = original
        sys.argv = argv
    return rc, out.getvalue()


def main():
    # 1. Содержимое свёрнутой секции — часть страницы, а не невидимка.
    blocks = {"h-top": heading("Обычный раздел")}
    blocks.update(table([["A", "B"], ["1", "2"]]))
    blocks["c-1"] = collapse("Свёрнутый раздел", ["h-in", "tbl"])
    blocks["h-in"] = heading("Вложенный заголовок")
    doc = make_page(["h-top", "c-1"], blocks)
    rc, out = run(load_module(), doc, """## Обычный раздел

<!-- collapse -->
### Свёрнутый раздел

#### Вложенный заголовок

| A | B |
|---|---|
| 1 | 2 |
""")
    check(rc == 0, "collapse-секция не даёт ложных расхождений", out.strip())

    # 2. Уровни заголовков считаются одинаково с обеих сторон.
    blocks = {"h-1": heading("Раздел"), "h-2": heading("Глубокий подраздел")}
    doc = make_page(["h-1", "h-2"], blocks)
    rc, out = run(load_module(), doc, """## Раздел

##### Глубокий подраздел
""")
    check(rc == 0, "H5 в исходнике не считается лишним на странице", out.strip())

    # 3. Опубликованный ведущий H1 (append/--keep-h1) сверяется, если так сказано.
    blocks = {"h-0": heading("Имя страницы"), "h-1": heading("Раздел")}
    doc = make_page(["h-0", "h-1"], blocks)
    rc, out = run(load_module(), doc, """# Имя страницы

## Раздел
""", extra_args=["--keep-h1"])
    check(rc == 0, "--keep-h1 сверяет ведущий H1 со страницей", out.strip())

    # 4. По умолчанию ведущий H1 не публикуется — и сверка этого не ждёт.
    blocks = {"h-1": heading("Раздел")}
    doc = make_page(["h-1"], blocks)
    rc, out = run(load_module(), doc, """# Имя страницы

## Раздел
""")
    check(rc == 0, "по умолчанию ведущий H1 исходника не ищется на странице", out.strip())

    # 5. Лишнее на странице по-прежнему расхождение, но с внятной причиной.
    blocks = {"h-1": heading("Раздел"), "h-x": heading("Чужой раздел")}
    doc = make_page(["h-1", "h-x"], blocks)
    rc, out = run(load_module(), doc, "## Раздел\n")
    check(rc == 1, "лишний блок на странице — расхождение", out.strip())
    check("--replace" in out,
          "сообщение объясняет, что сверка рассчитана на --replace", out.strip())

    # 6. URL страницы принимается наравне с UUID — как во всех соседних
    #    инструментах, иначе вставленная ссылка даёт невнятный HTTP 404.
    blocks = {"h-1": heading("Раздел")}
    doc = make_page(["h-1"], blocks)
    paths = []
    rc, out = run(load_module(), doc, "## Раздел\n",
                  page_ref="https://buildin.ai/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/" + PAGE_ID,
                  paths=paths)
    check(paths == ["/api/docs/" + PAGE_ID],
          "URL страницы приводится к page_id", "запрошено: %s" % paths)
    check(rc == 0, "сверка по URL проходит", out.strip())

    print("---")
    if FAILS:
        print("%d check(s) failed" % len(FAILS))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
