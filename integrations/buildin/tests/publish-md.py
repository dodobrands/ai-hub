#!/usr/bin/env python3
"""buildin-publish-md.py: публикация не разрушает страницу и не пишет вслепую.

Зачем: в --replace скрипт сначала удалял блоки страницы и только потом
конвертировал markdown и заливал результат. Любой сбой между этими шагами —
падение конвертера, 502 от шлюза на середине батчей — оставлял страницу пустой
без возможности отката. Сюда же 5xx: они приходят как HTTPError и не
повторялись вовсе, хотя именно они транзиентные. Третий инвариант — spaceId:
молчаливый фолбэк на зашитую константу писал блоки в чужое пространство и
печатал при этом «Done».

Сети нет: urlopen застаблен, порядок и содержимое транзакций пишутся в лог.
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(TESTS_DIR, os.pardir, "scripts", "buildin-publish-md.py")
PAGE_ID = "11111111-2222-3333-4444-555555555555"
TX_ENDPOINT = "/api/records/transactions"

FAILS = []


def check(cond, name, detail=""):
    if cond:
        print("ok:   " + name)
    else:
        print("FAIL: " + name + (" — " + detail if detail else ""))
        FAILS.append(name)


def load_module():
    """Свежий экземпляр на каждый тест: main() пишет глобальный SPACE_ID."""
    spec = importlib.util.spec_from_file_location("publish_md", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.load_token = lambda: "test-token"
    mod.API_BACKOFF = 0
    return mod


class Resp:
    def __init__(self, payload):
        self._payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return self._payload


def http_error(code):
    return urllib.error.HTTPError(
        "https://buildin.ai" + TX_ENDPOINT, code, "stub",
        {}, io.BytesIO(b'{"msg":"stub failure"}'))


def page_doc(space_id="space-1"):
    """b1/b2 — обычные блоки под удаление, b3 — ссылка на дочернюю страницу."""
    page = {"subNodes": ["b1", "b2", "b3"]}
    if space_id is not None:
        page["spaceId"] = space_id
    return {PAGE_ID: page, "b1": {"type": 1}, "b2": {"type": 1}, "b3": {"type": 0}}


def make_urlopen(doc, tx_log, on_tx=None, calls=None):
    def fake(req, timeout=None):
        endpoint = req.full_url.split("buildin.ai", 1)[-1]
        if calls is not None:
            calls.append(endpoint)
        if endpoint == "/api/users/me":
            return Resp({"code": 200, "data": {"uuid": "user-1"}})
        if endpoint.startswith("/api/docs/"):
            return Resp({"code": 200, "data": {"blocks": doc}})
        if endpoint == TX_ENDPOINT:
            ops = json.loads(req.data.decode())["transactions"][0]["operations"]
            kind = "delete" if any(o.get("command") == "listRemove" for o in ops) else "append"
            tx_log.append(kind)
            failure = on_tx(len(tx_log), kind) if on_tx else None
            if failure is not None:
                raise failure
            return Resp({"code": 200, "data": True})
        raise AssertionError("неожиданный endpoint: " + endpoint)
    return fake


def run(mod, args, fake):
    original = urllib.request.urlopen
    urllib.request.urlopen = fake
    argv = sys.argv
    out, error = io.StringIO(), None
    try:
        sys.argv = ["buildin-publish-md.py"] + args
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            mod.main()
    except BaseException as exc:
        error = exc
    finally:
        urllib.request.urlopen = original
        sys.argv = argv
    return out.getvalue(), error


def main():
    tmp = tempfile.mkdtemp()
    md = os.path.join(tmp, "doc.md")
    with open(md, "w", encoding="utf-8") as fh:
        fh.write("## Раздел\n\nПервый абзац.\n\nВторой абзац.\n")

    # 1. Деструктивный шаг — последний: удаление не начинается, пока новые
    #    блоки не легли на страницу.
    tx = []
    _, err = run(load_module(), [PAGE_ID, md, "--replace"], make_urlopen(page_doc(), tx))
    check(err is None, "replace проходит на исправном API", repr(err))
    check("append" in tx and "delete" in tx,
          "replace и заливает, и удаляет", "транзакции: %s" % tx)
    if "append" in tx and "delete" in tx:
        check(tx.index("delete") > len(tx) - 1 - tx[::-1].index("append"),
              "все append уходят раньше любого delete", "порядок: %s" % tx)

    # 2. Главный инвариант: сорванная заливка не трогает старое содержимое.
    tx = []
    fake = make_urlopen(page_doc(), tx,
                        on_tx=lambda n, kind: http_error(502) if kind == "append" else None)
    _, err = run(load_module(), [PAGE_ID, md, "--replace"], fake)
    check(err is not None, "сорванная заливка завершается ошибкой")
    check("delete" not in tx,
          "сорванная заливка не удаляет старые блоки", "транзакции: %s" % tx)

    # 3. 502 транзиентен — его надо повторять, а не падать с первой попытки.
    tx = []
    fake = make_urlopen(page_doc(), tx,
                        on_tx=lambda n, kind: http_error(502) if n <= 2 else None)
    _, err = run(load_module(), [PAGE_ID, md, "--replace"], fake)
    check(err is None, "502 повторяется и публикация доходит", repr(err))

    # 4. Обратная сторона: 4xx повторять бессмысленно.
    tx = []
    fake = make_urlopen(page_doc(), tx,
                        on_tx=lambda n, kind: http_error(400) if kind == "append" else None)
    _, err = run(load_module(), [PAGE_ID, md, "--replace"], fake)
    check(err is not None, "400 завершается ошибкой")
    check(tx.count("append") == 1,
          "400 не повторяется", "попыток append: %d" % tx.count("append"))

    # 5. Нераспознанный spaceId — отказ, а не запись вслепую в чужое пространство.
    tx = []
    _, err = run(load_module(), [PAGE_ID, md, "--replace"],
                 make_urlopen(page_doc(space_id=None), tx))
    check(err is not None, "без spaceId публикация завершается ошибкой")
    check(tx == [], "без spaceId не отправлено ни одной транзакции", "транзакции: %s" % tx)

    # 6. Лишний позиционный аргумент — опечатка во флаге или второй файл,
    #    который молча не публиковался.
    tx = []
    _, err = run(load_module(), [PAGE_ID, md, md, "--replace"],
                 make_urlopen(page_doc(), tx))
    check(err is not None, "лишний позиционный аргумент отвергается")
    check(tx == [], "при лишнем аргументе страница не трогается", "транзакции: %s" % tx)

    # 7. Документ страницы читается один раз: spaceId и список блоков брались
    #    двумя отдельными запросами к одному и тому же /api/docs.
    tx, calls = [], []
    _, err = run(load_module(), [PAGE_ID, md, "--replace"],
                 make_urlopen(page_doc(), tx, calls=calls))
    docs = [c for c in calls if c.startswith("/api/docs/")]
    check(err is None, "replace проходит", repr(err))
    check(len(docs) == 1, "документ страницы читается одним запросом",
          "запросов к /api/docs: %d" % len(docs))

    print("---")
    if FAILS:
        print("%d check(s) failed" % len(FAILS))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
