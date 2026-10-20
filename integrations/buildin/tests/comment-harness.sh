# shellcheck shell=bash
# Общая часть харнессов bash-слоя команд комментариев: подключается через
# source из comment.sh и comment-threads.sh. Здесь застабленный buildin.sh,
# фикстуры состояния и хелперы — у двух копий стаба разъехались бы ручки.
#
# buildin.sh застаблен и ПРИМЕНЯЕТ операции к состоянию: иначе проверку после
# записи («подсветка закрепилась?») нельзя ни подтвердить, ни опровергнуть.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$TESTS_DIR/../scripts"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Свой TMPDIR: команды кладут туда дефолтный файл отката, и без подмены каждый
# прогон оставлял их в настоящем временном каталоге — набрались тысячи.
export TMPDIR="$TMP/tmpdir"
mkdir -p "$TMPDIR"
FAILS=0

fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
ok()   { echo "ok:   $1"; }

PAGE=11111111-1111-4111-8111-111111111111
BLOCK=22222222-2222-4222-8222-222222222222
SPACE=33333333-3333-4333-8333-333333333333
OTHER=44444444-4444-4444-4444-444444444444
# Страница, которую упоминают в комментарии: её название отдаёт /api/blocks.
MENTIONED=55555555-5555-4555-8555-555555555555
# Участник без ника: в выводе вместо него короткий id, его почта не печатается.
NONICK=77777777-0000-4000-8000-0000000000aa

mkdir -p "$TMP/scripts" "$TMP/log"
cp "$SRC_DIR/buildin-pages.sh" "$SRC_DIR/buildin-lib.sh" "$SRC_DIR/buildin-comments.sh" \
   "$SRC_DIR/buildin-comment.py" "$SRC_DIR/buildin_segments.py" "$TMP/scripts/"

# Состояние страницы: один блок с тремя сегментами — обычный, code, хвост.
# «лимит» встречается дважды (в «безлимитный» и отдельно) — материал для
# проверки неоднозначности.
write_fixture() {
    cat > "$TMP/state.json" <<DOC
{"code":200,"data":{"blocks":{"$BLOCK":{
  "uuid":"$BLOCK","spaceId":"$SPACE","type":1,"discussions":[],
  "data":{"pageFixedWidth":true,"format":{"commentAlignment":"top"},
    "segments":[
      {"text":"безлимитный тариф: лимит ","type":0,"enhancer":{}},
      {"text":"100 запросов","type":0,"enhancer":{"code":true}},
      {"text":" в минуту","type":0,"enhancer":{}}]}}}}}
DOC
}
write_fixture

# Применение операций к состоянию + режимы имитации чужого писателя.
cat > "$TMP/scripts/apply-ops.py" <<'APPLY'
import copy, json, os, sys

state_path, body_path, block_id = sys.argv[1:4]
state = json.load(open(state_path))
block = state["data"]["blocks"][block_id]


def foreign_split(segments, uuid_):
    """Сегменты так, как их записал бы ЧУЖОЙ comment из того же снапшота:
    свой кусок подсвечен, остальная подсветка снапшота сохранена."""
    segments = copy.deepcopy(segments)
    first = segments[0]
    text = first["text"]
    head = dict(first, text=text[:11], discussions=[uuid_])
    tail = dict(first, text=text[11:])
    tail.pop("discussions", None)
    return [head, tail] + segments[1:]


ops = json.load(open(body_path))["transactions"][0]["operations"]
before_segments = copy.deepcopy(block["data"].get("segments", []))

# Чужая запись ДО нашей: её подсветку наши сегменты затрут, а в списке она
# останется (listAfter аддитивен) — так теряют подсветку параллельные треды.
before_uuid = os.environ.get("STUB_FOREIGN_BEFORE_POST")
if before_uuid:
    block["data"]["segments"] = foreign_split(before_segments, before_uuid)
    block.setdefault("discussions", []).append(before_uuid)

if not os.environ.get("STUB_IGNORE_WRITES"):
    # Треды и сообщения применяются тоже: без них проверку после записи у
    # команд резолва и ответа нечем ни подтвердить, ни опровергнуть.
    threads = state["data"].setdefault("discussions", {})
    messages = state["data"].setdefault("comments", {})
    for op in ops:
        table, command, path = op.get("table"), op["command"], op.get("path")
        if table == "block" and op["id"] == block_id:
            if command == "update" and path == ["data"]:
                block["data"].update(op["args"])
            elif command == "listAfter" and path == ["discussions"]:
                block.setdefault("discussions", []).append(op["args"]["uuid"])
            elif command == "listRemove" and path == ["discussions"]:
                block["discussions"] = [d for d in block.get("discussions", []) if d != op["args"]["uuid"]]
        elif table == "discussion":
            if command == "set":
                threads[op["id"]] = dict(op["args"])
            elif command == "update" and path == []:
                threads.setdefault(op["id"], {}).update(op["args"])
            elif command == "listAfter" and path == ["comments"]:
                threads.setdefault(op["id"], {}).setdefault("comments", []).append(op["args"]["uuid"])
            elif command == "listRemove" and path == ["comments"]:
                thread = threads.setdefault(op["id"], {})
                thread["comments"] = [c for c in thread.get("comments", []) if c != op["args"]["uuid"]]
        elif table == "comment":
            if command == "set":
                messages[op["id"]] = dict(op["args"])
            elif command == "update" and path == []:
                messages.setdefault(op["id"], {}).update(op["args"])

# Ответ коллеги в окне перед откатом: появляется в треде вместе с записью,
# которая этот тред закрывает (resolved: true).
reply_uuid = os.environ.get("STUB_REPLY_ON_RESOLVE")
if reply_uuid and not os.environ.get("STUB_IGNORE_WRITES"):
    for op in ops:
        if op.get("table") == "discussion" and op.get("args", {}).get("resolved") is True:
            thread = state["data"].setdefault("discussions", {}).setdefault(op["id"], {})
            thread.setdefault("comments", []).append(reply_uuid)
            state["data"].setdefault("comments", {})[reply_uuid] = {
                "uuid": reply_uuid, "parentId": op["id"], "status": 1, "createdBy": "someone-else"}

# Чужая запись ПОСЛЕ нашей, построенная из ДОнашего снапшота: затирает нашу
# подсветку — так проигрывают гонку.
after_uuid = os.environ.get("STUB_FOREIGN_AFTER_POST")
if after_uuid and any(o["command"] == "update" and o.get("path") == ["data"] for o in ops):
    block["data"]["segments"] = foreign_split(before_segments, after_uuid)
    if after_uuid not in block.get("discussions", []):
        block.setdefault("discussions", []).append(after_uuid)

json.dump(state, open(state_path, "w"), ensure_ascii=False)
APPLY

# Стаб отвечает только на СВОЮ страницу и умеет ломаться: без этого ветки
# отказов недостижимы, а регресс comments проходил бы, даже если разбор
# идентификаторов начнёт брать UUID пространства вместо страницы.
# Ручки (все через окружение):
#   STUB_FAIL_GET_AFTER_WRITE  — чтение после записи падает
#   STUB_FAIL_POST             — падает сам POST
#   STUB_INBAND_ERROR          — чтение после записи отдаёт конверт ошибки (HTTP 200, code 500)
#   STUB_AFTER_WRITE_BODY      — чтение после записи отдаёт это тело как есть
#   STUB_FAIL_SECOND_POST      — первый POST проходит, второй (самоочистка) падает
#   STUB_MUTATE_ON_GET=N       — начиная с N-го чтения сегменты блока другие
#   STUB_IGNORE_WRITES         — POST принимается, но состояние не меняется
#   STUB_FAIL_MEMBERS          — список участников пространства не отдаётся
#   STUB_MEMBERS_ENVELOPE      — вместо списка участников конверт ошибки (HTTP 200, code 403)
#   STUB_FAIL_DOCS             — страница не читается вовсе
#   STUB_NO_USER               — /api/users/me отдаёт пустой uuid
#   STUB_REPLY_ON_RESOLVE=uuid — закрытие треда приносит в него чужой ответ (окно перед откатом)
#   STUB_FAIL_USER             — /api/users/me отдаёт конверт ошибки и код 1
restore_stateful_stub() {
    cat > "$TMP/scripts/buildin.sh" <<STUB
#!/usr/bin/env bash
METHOD="\$1"; ENDPOINT="\$2"; BODY="\${3:-}"
LOG_DIR="$TMP/log"
printf '%s %s\n' "\$METHOD" "\$ENDPOINT" >> "\$LOG_DIR/calls.txt"
case "\$ENDPOINT" in
    /api/users/me)
        if [ -n "\${STUB_NO_USER:-}" ]; then echo '{"code":200,"data":{"uuid":""}}'; exit 0; fi
        if [ -n "\${STUB_FAIL_USER:-}" ]; then echo '{"code":401,"msg":"stub: unauthorized"}'; exit 1; fi
        echo '{"code":200,"data":{"uuid":"user-1"}}' ;;
    /api/blocks/$MENTIONED)
        echo '{"code":200,"data":{"uuid":"$MENTIONED","spaceId":"$SPACE","title":"Страница B"}}' ;;
    /api/spaces/$SPACE/members)
        if [ -n "\${STUB_FAIL_MEMBERS:-}" ]; then echo "Error: HTTP 403" >&2; exit 1; fi
        if [ -n "\${STUB_MEMBERS_ENVELOPE:-}" ]; then echo '{"code":403,"msg":"stub: forbidden"}'; exit 0; fi
        echo '{"code":200,"data":[{"user":{"uuid":"$OTHER","nickname":"j.doe","email":"j.doe@example.com"}},{"user":{"uuid":"user-1","nickname":"agent"}},{"user":{"uuid":"$NONICK","email":"nonick@example.com"}}]}' ;;
    /api/docs/$PAGE)
        if [ -n "\${STUB_FAIL_DOCS:-}" ]; then echo "Error: HTTP 503" >&2; exit 1; fi
        N=\$(cat "\$LOG_DIR/getn" 2>/dev/null || echo 0); N=\$((N + 1)); echo "\$N" > "\$LOG_DIR/getn"
        if [ -n "\${STUB_FAIL_GET_AFTER_WRITE:-}" ] && [ -s "\$LOG_DIR/tx-body.json" ]; then
            echo "Error: HTTP 503" >&2; exit 1
        fi
        if [ -n "\${STUB_INBAND_ERROR:-}" ] && [ -s "\$LOG_DIR/tx-body.json" ]; then
            echo '{"code":500,"msg":"stub: in-band error"}'; exit 0
        fi
        if [ -n "\${STUB_AFTER_WRITE_BODY:-}" ] && [ -s "\$LOG_DIR/tx-body.json" ]; then
            printf '%s' "\$STUB_AFTER_WRITE_BODY"; exit 0
        fi
        if [ -n "\${STUB_MUTATE_ON_GET:-}" ] && [ "\$N" -ge "\$STUB_MUTATE_ON_GET" ]; then
            cat "$TMP/state-changed.json"; exit 0
        fi
        cat "$TMP/state.json" ;;
    /api/records/transactions)
        P=\$(cat "\$LOG_DIR/postn" 2>/dev/null || echo 0); P=\$((P + 1)); echo "\$P" > "\$LOG_DIR/postn"
        if [ -n "\${STUB_FAIL_POST:-}" ]; then echo "Error: HTTP 502" >&2; exit 1; fi
        if [ -n "\${STUB_FAIL_SECOND_POST:-}" ] && [ "\$P" -ge 2 ]; then
            echo "Error: HTTP 502" >&2; exit 1
        fi
        printf '%s' "\$BODY" >> "\$LOG_DIR/tx-all.json"
        printf '%s' "\$BODY" > "\$LOG_DIR/tx-body.json"
        python3 "$TMP/scripts/apply-ops.py" \\
            "$TMP/state.json" "\$LOG_DIR/tx-body.json" "$BLOCK"
        echo '{"code":200,"data":true}' ;;
    *)
        echo '{"code":404,"msg":"stub: unexpected endpoint"}' >&2; exit 1 ;;
esac
STUB
    chmod +x "$TMP/scripts/buildin.sh"
}
restore_stateful_stub

# Блок с другим текстом — для ручки STUB_MUTATE_ON_GET.
cat > "$TMP/state-changed.json" <<DOC
{"code":200,"data":{"blocks":{"$BLOCK":{
  "uuid":"$BLOCK","spaceId":"$SPACE","type":1,"discussions":[],
  "data":{"pageFixedWidth":true,
    "segments":[{"text":"кто-то переписал блок, но фраза в минуту цела","type":0,"enhancer":{}}]}}}}}
DOC

# Прогон команды под /bin/bash. Печатает rc; stdout/stderr — в log/.
run_comment() {
    rm -f "$TMP/log/tx-body.json" "$TMP/log/tx-all.json" \
          "$TMP/log/getn" "$TMP/log/postn" "$TMP/log/calls.txt"
    [ -n "${SKIP_RESET:-}" ] || write_fixture
    /bin/bash "$TMP/scripts/buildin-pages.sh" comment "$@" \
        > "$TMP/log/stdout.txt" 2> "$TMP/log/stderr.txt"
    echo $?
}
run_cmd() { # произвольная подкоманда — для регресса comments
    /bin/bash "$TMP/scripts/buildin-pages.sh" "$@" > "$TMP/log/stdout.txt" 2> "$TMP/log/stderr.txt"
    echo $?
}
sent()   { [ -s "$TMP/log/tx-body.json" ]; }
stderr() { cat "$TMP/log/stderr.txt"; }
stdout() { cat "$TMP/log/stdout.txt"; }
block_state() { python3 -c "
import json, sys
b = json.load(open('$TMP/state.json'))['data']['blocks']['$BLOCK']
segs = b['data']['segments']
lit = {t for s in segs for t in (s.get('discussions') or [])}
print(json.dumps({'listed': b.get('discussions', []), 'lit': sorted(lit),
                  'text': ''.join(s['text'] for s in segs), 'n': len(segs)}, ensure_ascii=False))
"; }

# Пустое значение — для проверок, что флаг без значения не съедает следующий.
EMPTY=""
: > "$TMP/empty.txt"

# ---- треды: фикстура и хелперы -----------------------------------------------
THREAD=66666666-6666-4666-8666-666666666666
FIRST=77777777-7777-4777-8777-777777777777

# Состояние с тредом на блоке: $1 — resolved (true|false).
write_thread_fixture() {
    cat > "$TMP/state.json" <<DOC
{"code":200,"data":{"blocks":{"$BLOCK":{
  "uuid":"$BLOCK","spaceId":"$SPACE","type":1,"discussions":["$THREAD"],
  "data":{"pageFixedWidth":true,
    "segments":[
      {"text":"безлимитный тариф","type":0,"enhancer":{},"discussions":["$THREAD"]},
      {"text":": лимит 100 запросов в минуту","type":0,"enhancer":{}}]}}},
  "discussions":{"$THREAD":{"uuid":"$THREAD","spaceId":"$SPACE","parentId":"$BLOCK",
    "status":1,"resolved":${1:-false},"comments":["$FIRST"]}},
  "comments":{"$FIRST":{"uuid":"$FIRST","spaceId":"$SPACE","parentId":"$THREAD",
    "status":1,"text":[{"text":"первое","type":0,"enhancer":{}}]}}}}
DOC
}

run_sub() { # подкоманда с чистыми журналами стаба; состояние готовит вызывающий
    rm -f "$TMP/log/tx-body.json" "$TMP/log/tx-all.json" \
          "$TMP/log/getn" "$TMP/log/postn" "$TMP/log/calls.txt"
    /bin/bash "$TMP/scripts/buildin-pages.sh" "$@" > "$TMP/log/stdout.txt" 2> "$TMP/log/stderr.txt"
    echo $?
}
thread_field() { python3 -c "
import json
print(json.dumps(json.load(open('$TMP/state.json'))['data']['discussions']['$THREAD']['$1']))"; }
posts() { cat "$TMP/log/postn" 2>/dev/null || echo 0; }

thread_comments() { python3 -c "
import json
print(' '.join(json.load(open('$TMP/state.json'))['data']['discussions']['$THREAD']['comments']))"; }
message_field() { python3 -c "
import json
print(json.dumps(json.load(open('$TMP/state.json'))['data']['comments']['$1']['$2'], ensure_ascii=False))" 2>/dev/null; }

# Сегменты текста сообщения из отправленной транзакции: uuid упоминаний и текст.
sent_text() { python3 -c "
import json
ops = json.load(open('$TMP/log/tx-body.json'))['transactions'][0]['operations']
rec = [o for o in ops if o['table'] == 'comment'][0]
print(' | '.join(s.get('uuid') or s['text'] for s in rec['args']['text']))" 2>/dev/null; }

finish() {
    echo "---"
    if [ "$FAILS" -gt 0 ]; then
        echo "$FAILS check(s) failed"
        exit 1
    fi
    echo "all checks passed"
}
