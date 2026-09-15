#!/usr/bin/env python3
"""Публикация markdown в страницу Buildin: дописать в конец или заменить содержимое.

Движок команды `buildin-pages.sh publish-md`; вызывать напрямую тоже можно.
Разбор markdown делает md-to-blocks.py, сборку операций — buildin-blocks.py;
здесь остаётся то, чего нет в shell-пути: ретраи обрывов и транзиентных
ответов сервера, батчи, безопасный порядок замены (сначала залить, потом
удалить), сохранение дочерних страниц и поиск .env без hub-meta.

Usage: buildin-publish-md.py <page_id|url> <file.md> [--append|--replace] [--skip-h1|--keep-h1]
"""
import json, re, sys, uuid, time, os, subprocess, urllib.request, urllib.error

# ---- Config ----
BUILDIN_BASE = "https://buildin.ai"
# Пространство берётся у самой страницы (см. get_space_id в buildin-pages.sh);
# резервного значения нет намеренно — см. resolve_space_id.
SPACE_ID = None
BATCH_SIZE = 25  # blocks per append transaction
API_TRIES = 4          # сетевые обрывы к buildin.ai не редкость
API_TIMEOUT = 120
API_BACKOFF = 4
# Транзиентные статусы: их повтор имеет смысл, прочие 4xx — про сам запрос.
API_RETRY_STATUS = frozenset({429, 500, 502, 503, 504})

# Поиск .env вынесен в общий модуль: копия в каждом скрипте расходилась.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from buildin_env import read_token


def load_token():
    return read_token()


def _retry_delay(err, attempt):
    """Retry-After сервера важнее нашего backoff — при 429 он и есть ответ
    на вопрос «сколько ждать». Потолок в минуту: дольше ждать бессмысленно."""
    raw = (getattr(err, "headers", None) or {}).get("Retry-After")
    try:
        return max(0, min(float(raw), 60))
    except (TypeError, ValueError):
        return API_BACKOFF * (attempt + 1)

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
    # Повторяем и сетевые обрывы, и транзиентные ответы шлюза: 429/5xx приходят
    # как HTTPError, но говорят о перегрузке, а не о самом запросе.
    #
    # Повтор безопасен, пока уходит ТО ЖЕ САМОЕ тело: операции несут фиксированные
    # uuid блоков, а `set` на тот же uuid перезаписывает блок и `listAfter` того же
    # uuid не задваивает subNodes. Проверено на живой странице: одни и те же
    # операции с разными requestId дали один блок, разные операции с одним
    # requestId — два. То есть requestId сервер НЕ дедуплицирует, и полагаться
    # на него нельзя. Отсюда инвариант: тело строится один раз до цикла попыток;
    # пересобирать операции внутри ретрая — значит получить дубли.
    for attempt in range(API_TRIES):
        try:
            with urllib.request.urlopen(req, timeout=API_TIMEOUT) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            body_txt = e.read().decode()
            if e.code not in API_RETRY_STATUS or attempt == API_TRIES - 1:
                raise RuntimeError(f"HTTP {e.code}: {body_txt[:300]}")
            time.sleep(_retry_delay(e, attempt))
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

def fetch_doc(page_id, token):
    """Документ страницы одним запросом: spaceId и список блоков берутся из
    одного ответа, а не двумя отдельными GET за одним и тем же адресом."""
    data = api("GET", f"/api/docs/{page_id}", token=token)
    return (data.get("data") or {}).get("blocks", {}) or {}


def resolve_space_id(page_id, token):
    """spaceId целевой страницы. Фолбэка нет намеренно: блоки с чужим spaceId
    уходят не в то пространство и на странице не появляются — причём молча, с
    успешным ответом API. Явный отказ заметнее потерянной публикации."""
    return space_id_of(fetch_doc(page_id, token), page_id)


def space_id_of(all_blocks, page_id):
    space_id = (all_blocks.get(page_id) or {}).get("spaceId")
    if not space_id:
        raise RuntimeError(
            "не удалось определить spaceId страницы %s — проверьте, что id верный "
            "и токен даёт доступ к странице" % page_id)
    return space_id


def get_blocks_info(all_blocks, page_id):
    """Returns (all_block_ids, child_page_block_ids).
    type=0 blocks are child page references — must NOT be deleted."""
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

def _helper(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    if not os.path.exists(path):
        raise RuntimeError("%s рядом не найден: %s" % (name, path))
    return path


def build_ops(page_id, blocks, user_id, now):
    """Операции транзакции собирает buildin-blocks.py, а не этот скрипт.

    Раньше здесь жила своя рекурсия по children — третья копия одной и той же
    логики (первая в buildin-blocks.py, вторая была в выброшенном конвертере).
    Копии расходятся: именно поэтому строки таблиц какое-то время терялись.
    Хелпер уже умеет вложенность, listBefore и цвета блоков, и его зовёт
    buildin-pages.sh, то есть он проверяется на каждой ручной вставке.
    """
    r = subprocess.run(
        [sys.executable, _helper("buildin-blocks.py"), page_id, SPACE_ID,
         str(now), user_id, json.dumps(blocks, ensure_ascii=False)],
        capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise RuntimeError("buildin-blocks.py упал: " + (r.stderr or "")[:300])
    return json.loads(r.stdout)


def append_blocks_batch(page_id, blocks, user_id, token):
    """Блоки батча цепляются друг за другом, а сам батч встаёт в конец страницы:
    listAfter без after — это добавление в хвост, поэтому порядок между батчами
    сохраняется без передачи хвостового uuid."""
    now = int(time.time() * 1000)
    transaction(build_ops(page_id, blocks, user_id, now), token)


def convert_markdown(md_file, skip_h1=True):
    """Разбор markdown внешним md-to-blocks.py.

    Здесь жил второй, упрощённый конвертер: он не отдавал children у таблиц,
    поэтому таблицы публиковались пустой рамкой, и не знал про ширины колонок,
    языки блоков кода и вложенность списков. Два конвертера — это два набора
    багов; внешний поддерживается и покрыт тестами.
    """
    cmd = [sys.executable, _helper("md-to-blocks.py"), md_file]
    if skip_h1:
        # H1 — заголовок самой страницы; блоком на странице он лишний.
        # Раньше сюда передавался --shift-headings, но это другая операция:
        # она сдвигает уровни, а H1 всё равно оставался блоком.
        cmd.append("--skip-h1")
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise RuntimeError("md-to-blocks.py упал: " + (r.stderr or "")[:300])
    return json.loads(r.stdout)


USAGE = """Usage: buildin-publish-md.py <page_id|url> <file.md> [--append|--replace] [--skip-h1|--keep-h1]

  --append    дописать блоки в конец страницы, ничего не удаляя
  --replace   заменить содержимое: удалить блоки страницы и залить заново
              (ссылки на дочерние страницы, type 0, сохраняются)

Режим по умолчанию — --replace, как и раньше у этого скрипта. Точка входа для
новой работы — buildin-pages.sh publish-md, там по умолчанию --append.

  --skip-h1   не публиковать первый H1 (он же заголовок страницы); по умолчанию
              включён в --replace и выключен в --append: дописываемый фрагмент
              начинается с настоящего заголовка раздела, а не с имени страницы.
"""

UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def parse_id(value):
    """URL страницы принимается наравне с UUID — как в buildin-pages.sh."""
    found = UUID_RE.findall(value or "")
    return found[-1] if found else value


def parse_args(argv):
    mode, skip_h1, positional = None, None, []
    for a in argv:
        if a in ("--append", "--replace"):
            mode = a[2:]
        elif a == "--skip-h1":
            skip_h1 = True
        elif a == "--keep-h1":
            skip_h1 = False
        elif a.lower() in ("true", "false") and len(positional) == 2:
            # Обратная совместимость: третьим позиционным был skip_h1.
            skip_h1 = a.lower() != "false"
        elif a.startswith("-"):
            raise SystemExit("неизвестный флаг: " + a + "\n\n" + USAGE)
        else:
            positional.append(a)
    if len(positional) != 2:
        # Молчаливо съеденный третий аргумент — это либо второй файл, который
        # так и не опубликовался, либо флаг, написанный без дефисов.
        if len(positional) > 2:
            raise SystemExit("лишние аргументы: %s\n\n%s"
                             % (" ".join(positional[2:]), USAGE))
        raise SystemExit(USAGE)
    if mode is None:
        mode = "replace"
        print("режим не указан — replace, как раньше. Явный флаг надёжнее: "
              "--append дописывает, --replace заменяет", file=sys.stderr)
    if skip_h1 is None:
        skip_h1 = (mode == "replace")
    return parse_id(positional[0]), positional[1], mode, skip_h1


def main():
    page_id, md_file, mode, skip_h1 = parse_args(sys.argv[1:])

    print("Loading token...")
    token = load_token()
    user_id = get_user_id(token)
    print(f"User ID: {user_id[:8]}...")

    doc = fetch_doc(page_id, token)
    global SPACE_ID
    SPACE_ID = space_id_of(doc, page_id)
    print(f"Space: {SPACE_ID}")

    # Удаление идёт последним, когда новые блоки уже на странице. Обратный
    # порядок оставлял страницу пустой при любом сбое между удалением и
    # заливкой — сорванной конвертации или 5xx на середине батчей, — и откатить
    # это было нечем. Ценой короткого окна с дублем содержимого страница теперь
    # ни в один момент не пуста.
    delete_ids = []
    if mode == "replace":
        print("\nStep 1: Get existing blocks...")
        delete_ids, child_ids = get_blocks_info(doc, page_id)
        print(f"  Found {len(delete_ids)} blocks to replace, {len(child_ids)} child page(s) to preserve")
    else:
        print("\nMode: append — существующие блоки не трогаем")

    print(f"\nStep 2: Parse markdown {md_file}...")
    blocks = convert_markdown(md_file, skip_h1=skip_h1)
    rows = sum(len(b.get("children") or []) for b in blocks)
    print(f"  Converted to {len(blocks)} blocks ({rows} nested), skip_h1={skip_h1}")

    print(f"\nStep 3: Append {len(blocks)} blocks in batches of {BATCH_SIZE}...")
    for i in range(0, len(blocks), BATCH_SIZE):
        batch = blocks[i:i+BATCH_SIZE]
        append_blocks_batch(page_id, batch, user_id, token)
        print(f"  Batch {i//BATCH_SIZE + 1}: {len(batch)} blocks appended")

    if delete_ids:
        print(f"\nStep 4: Delete {len(delete_ids)} replaced blocks...")
        delete_all_blocks(page_id, delete_ids, user_id, token)
        print("  Done!")

    print(f"\n✅ Done! Page updated: https://buildin.ai/{SPACE_ID}/{page_id}")


if __name__ == "__main__":
    main()
