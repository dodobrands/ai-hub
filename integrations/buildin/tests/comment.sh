#!/usr/bin/env bash
# bash-слой команды `comment` под /bin/bash: разбор аргументов, формы ввода,
# --dry-run, откат, поведение при параллельной записи.
#
# Зачем отдельно от bats-юнитов: те бьют по чистому питоновскому билдеру, а
# ошибки разбора аргументов и склейки живут в shell. Опечатка «--dryrun», молча
# ставшая позиционным аргументом, делала боевую запись вместо превью — ровно
# такой класс багов сюда и ловится. Плюс на macOS /bin/bash = 3.2, целевой шелл
# скриптов хаба, и он проверяется тем же прогоном.
#
# buildin.sh застаблен и ПРИМЕНЯЕТ операции к состоянию: иначе проверку после
# записи («подсветка закрепилась?») нельзя ни подтвердить, ни опровергнуть.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$TESTS_DIR/../scripts"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0

fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
ok()   { echo "ok:   $1"; }

PAGE=11111111-1111-4111-8111-111111111111
BLOCK=22222222-2222-4222-8222-222222222222
SPACE=33333333-3333-4333-8333-333333333333
OTHER=44444444-4444-4444-4444-444444444444

mkdir -p "$TMP/scripts" "$TMP/log"
cp "$SRC_DIR/buildin-pages.sh" "$SRC_DIR/buildin-comment.py" "$TMP/scripts/"

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
    for op in ops:
        if op.get("table") != "block" or op["id"] != block_id:
            continue
        if op["command"] == "update" and op.get("path") == ["data"]:
            block["data"].update(op["args"])
        elif op["command"] == "listAfter" and op.get("path") == ["discussions"]:
            block.setdefault("discussions", []).append(op["args"]["uuid"])
        elif op["command"] == "listRemove" and op.get("path") == ["discussions"]:
            block["discussions"] = [d for d in block.get("discussions", []) if d != op["args"]["uuid"]]

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
#   STUB_FAIL_SECOND_POST      — первый POST проходит, второй (самоочистка) падает
#   STUB_MUTATE_ON_GET=N       — начиная с N-го чтения сегменты блока другие
#   STUB_IGNORE_WRITES         — POST принимается, но состояние не меняется
restore_stateful_stub() {
    cat > "$TMP/scripts/buildin.sh" <<STUB
#!/usr/bin/env bash
METHOD="\$1"; ENDPOINT="\$2"; BODY="\${3:-}"
LOG_DIR="$TMP/log"
printf '%s %s\n' "\$METHOD" "\$ENDPOINT" >> "\$LOG_DIR/calls.txt"
case "\$ENDPOINT" in
    /api/users/me)
        echo '{"code":200,"data":{"uuid":"user-1"}}' ;;
    /api/docs/$PAGE)
        N=\$(cat "\$LOG_DIR/getn" 2>/dev/null || echo 0); N=\$((N + 1)); echo "\$N" > "\$LOG_DIR/getn"
        if [ -n "\${STUB_FAIL_GET_AFTER_WRITE:-}" ] && [ -s "\$LOG_DIR/tx-body.json" ]; then
            echo "Error: HTTP 503" >&2; exit 1
        fi
        if [ -n "\${STUB_INBAND_ERROR:-}" ] && [ -s "\$LOG_DIR/tx-body.json" ]; then
            echo '{"code":500,"msg":"stub: in-band error"}'; exit 0
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

# ---- P1 #1 (раунд 1): неизвестные флаги не становятся позиционными ----------
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' --dryrun)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'неизвестный флаг'; then
    ok "опечатка --dryrun отвергнута, боевой записи нет"
else
    fail "опечатка --dryrun не отвергнута (rc=$RC)"
fi

RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' --rollback-out "$TMP/mine.json")
if [ "$RC" -eq 0 ] && [ -s "$TMP/mine.json" ]; then
    ok "пробельная форма --rollback-out <path> принята"
else
    fail "пробельная форма --rollback-out не сработала (rc=$RC): $(stderr)"
fi

# Пустая переменная не должна съедать следующий флаг: так --dry-run становился
# путём, и превью превращалось в боевую запись.
EMPTY=""
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' --rollback-out $EMPTY --dry-run)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'rollback-out без значения'; then
    ok "--rollback-out с пустым значением не съедает следующий флаг"
else
    fail "--rollback-out съел --dry-run (rc=$RC, записал=$(sent && echo да || echo нет))"
fi
RC=$(run_comment "$PAGE" "$BLOCK" 'лимит' 'текст' --occurrence $EMPTY --dry-run)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'occurrence без значения'; then
    ok "--occurrence с пустым значением не съедает следующий флаг"
else
    fail "--occurrence съел --dry-run (rc=$RC)"
fi

RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' 'лишний')
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'ровно <anchor> и <text>'; then
    ok "лишний позиционный аргумент отвергнут"
else
    fail "лишний позиционный аргумент не отвергнут (rc=$RC)"
fi

RC=$(run_comment "$PAGE" 'в минуту' 'текст')
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'не указан block_id'; then
    ok "отсутствие block_id названо своим именем"
else
    fail "отсутствие block_id не отвергнуто внятно (rc=$RC): $(stderr | head -1)"
fi

RC=$(run_comment "https://buildin.ai/$SPACE/$PAGE#$BLOCK" 'в минуту' 'текст')
if [ "$RC" -eq 0 ] && sent; then
    ok "форма <url>#<block_uuid> принята"
else
    fail "форма <url>#<block_uuid> не сработала (rc=$RC): $(stderr | head -2)"
fi

# ---- #6 (раунд 1): --dry-run не отправляет и не пишет файл отката -----------
RB="$TMP/dry-rollback.json"
printf 'прежний откат' > "$RB"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' --dry-run "--rollback-out=$RB")
if [ "$RC" -eq 0 ] && ! sent; then
    ok "--dry-run ничего не отправил"
else
    fail "--dry-run отправил транзакцию (rc=$RC)"
fi
if [ "$(cat "$RB")" = "прежний откат" ]; then
    ok "--dry-run не переписал файл отката"
else
    fail "--dry-run переписал файл отката"
fi
if stdout | python3 -c "
import json, sys
ops = json.load(sys.stdin)
assert [o['command'] for o in ops] == ['set','set','update','listAfter','update'], ops
" 2>/dev/null; then
    ok "--dry-run напечатал операции транзакции"
else
    fail "--dry-run напечатал не то: $(stdout | head -3)"
fi

# ---- #11 (раунд 1): пустые значения после разворачивания ---------------------
: > "$TMP/empty.txt"
RC=$(printf '' | run_comment "$PAGE" "$BLOCK" 'в минуту' -)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'текст комментария пустой'; then
    ok "пустой stdin как текст отвергнут"
else
    fail "пустой stdin как текст не отвергнут (rc=$RC)"
fi
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' "@$TMP/empty.txt")
if [ "$RC" -ne 0 ] && ! sent; then
    ok "пустой файл как текст отвергнут"
else
    fail "пустой файл как текст не отвергнут (rc=$RC)"
fi

# ---- #5 (раунд 1) + #9 (раунд 2): однозначность якоря ------------------------
RC=$(run_comment "$PAGE" "$BLOCK" 'лимит' 'текст')
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'раз(а) — непонятно'; then
    ok "неоднозначный якорь отвергнут"
else
    fail "неоднозначный якорь не отвергнут (rc=$RC): $(stderr | head -2)"
fi
RC=$(run_comment "$PAGE" "$BLOCK" 'лимит' 'текст' --occurrence=2)
if [ "$RC" -eq 0 ] && sent; then
    ok "--occurrence=2 разрешает неоднозначность"
else
    fail "--occurrence=2 не сработал (rc=$RC): $(stderr | head -2)"
fi
RC=$(run_comment "$PAGE" "$BLOCK" 'лимит' 'текст' --occurrence 2)
if [ "$RC" -eq 0 ] && sent; then
    ok "пробельная форма --occurrence N принята"
else
    fail "пробельная форма --occurrence N не сработала (rc=$RC): $(stderr | head -2)"
fi
RC=$(run_comment "$PAGE" "$BLOCK" 'лимит' 'текст' --occurrence=0)
if [ "$RC" -ne 0 ] && ! sent; then
    ok "--occurrence=0 отвергнут"
else
    fail "--occurrence=0 не отвергнут (rc=$RC)"
fi

# ---- #8 (раунд 1) + #3 (раунд 2): сигилы и ведущие дефисы --------------------
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' '@@j.doe глянь сюда')
if [ "$RC" -eq 0 ] && sent && python3 -c "
import json
ops = json.load(open('$TMP/log/tx-body.json'))['transactions'][0]['operations']
assert ops[1]['args']['text'][0]['text'] == '@j.doe глянь сюда'
" 2>/dev/null; then
    ok "@@ даёт литеральный @ в тексте комментария"
else
    fail "@@ не дал литеральный @ (rc=$RC)"
fi
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' '@нет-такого-файла')
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'удвойте сигил'; then
    ok "ошибка про @ объясняет обходной путь"
else
    fail "ошибка про @ не объясняет обходной путь"
fi
RC=$(run_comment "$PAGE" "$BLOCK" -- 'в минуту' '-- не согласен')
if [ "$RC" -eq 0 ] && sent && python3 -c "
import json
ops = json.load(open('$TMP/log/tx-body.json'))['transactions'][0]['operations']
assert ops[1]['args']['text'][0]['text'] == '-- не согласен', ops[1]['args']['text']
" 2>/dev/null; then
    ok "текст с ведущими дефисами доходит через разделитель --"
else
    fail "текст с ведущими дефисами не дошёл (rc=$RC): $(stderr | head -2)"
fi
printf -- '-- не согласен' > "$TMP/dashes.txt"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' "@$TMP/dashes.txt")
if [ "$RC" -eq 0 ] && sent && python3 -c "
import json
ops = json.load(open('$TMP/log/tx-body.json'))['transactions'][0]['operations']
assert ops[1]['args']['text'][0]['text'] == '-- не согласен', ops[1]['args']['text']
" 2>/dev/null; then
    ok "текст с ведущими дефисами доходит через @file"
else
    fail "текст с ведущими дефисами не дошёл через @file (rc=$RC): $(stderr | head -2)"
fi

# ---- #7 (раунд 2): файл отката разбирается и проигрывается -------------------
RB2="$TMP/rb-real.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB2")
BEFORE=$(python3 -c "print('безлимитный тариф: лимит 100 запросов в минуту')")
if [ "$RC" -eq 0 ] && python3 -c "
import json, sys
b = json.load(open('$RB2'))
tx = b['transactions'][0]
assert tx['spaceId'] == '$SPACE', tx['spaceId']
assert isinstance(b['requestId'], str) and b['requestId']
got = [(o['command'], o['table'], '.'.join(o['path'])) for o in tx['operations']]
want = [('update','block','data'), ('listRemove','block','discussions'),
        ('update','comment',''), ('update','discussion',''), ('update','block','')]
assert got == want, got
" 2>/dev/null; then
    ok "файл отката — валидный конверт с ожидаемыми операциями"
else
    fail "файл отката не разобрался: $(head -c 200 "$RB2" 2>/dev/null)"
fi
# проигрываем откат через стаб и смотрим, что блок вернулся
/bin/bash "$TMP/scripts/buildin.sh" POST /api/records/transactions "$(cat "$RB2")" > /dev/null 2>&1
ST=$(block_state)
if echo "$ST" | python3 -c "
import json, sys
st = json.load(sys.stdin)
assert st['listed'] == [], st['listed']
assert st['lit'] == [], st['lit']
assert st['text'] == '$BEFORE', st['text']
assert st['n'] == 3, st['n']
" 2>/dev/null; then
    ok "проигранный откат вернул блок к снапшоту и убрал тред"
else
    fail "откат не вернул блок: $ST"
fi

# ---- #6 (раунд 2): сбой GET после успешной записи ---------------------------
write_fixture
export STUB_FAIL_GET_AFTER_WRITE=1
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
unset STUB_FAIL_GET_AFTER_WRITE
if [ "$RC" -eq 2 ] && sent && stderr | grep -q 'discussion:' && stderr | grep -q 'Не повторяйте команду вслепую'; then
    ok "сбой GET после записи называет созданный тред и запрещает слепой повтор"
else
    fail "сбой GET после записи обработан молча (rc=$RC): $(stderr | tail -3)"
fi

# ---- #2 (раунд 2): чужой тред, созданный ПАРАЛЛЕЛЬНО, теряет подсветку -------
# Чужая запись ложится до нашей из того же снапшота: в снапшоте команды её нет,
# и прежняя база сравнения (подсветка снапшота) этот случай пропускала.
write_fixture
export STUB_FOREIGN_BEFORE_POST="$OTHER"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
unset STUB_FOREIGN_BEFORE_POST
if [ "$RC" -eq 0 ] && sent && stderr | grep -q "лишила подсветки чужие треды: $OTHER"; then
    ok "тред, созданный параллельно и потерявший подсветку, назван в предупреждении"
else
    fail "параллельно созданный тред не замечен (rc=$RC): $(stderr | tail -3)"
fi

# ---- #1 (раунд 2): проигрыш гонки чинится узким откатом ----------------------
# Чужая запись ложится ПОСЛЕ нашей и затирает нашу подсветку. Полный откат тут
# применять нельзя: он вернул бы наш снапшот и стёр подсветку победителя.
write_fixture
export STUB_FOREIGN_AFTER_POST="$OTHER"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
unset STUB_FOREIGN_AFTER_POST
if [ "$RC" -ne 0 ] && stderr | grep -q 'подсветка не закрепилась'; then
    ok "проигрыш гонки — громкая ошибка"
else
    fail "проигрыш гонки не обнаружен (rc=$RC): $(stderr | tail -3)"
fi
if stderr | grep -q 'применять НЕ надо'; then
    ok "команда предупреждает не применять полный откат"
else
    fail "команда не предупредила про полный откат: $(stderr | tail -3)"
fi
if python3 -c "
import json
bodies = open('$TMP/log/tx-all.json').read()
# второй конверт в логе — узкий откат, отправленный самой командой
import re
objs, depth, start = [], 0, None
for i, ch in enumerate(bodies):
    if ch == '{':
        if depth == 0: start = i
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0: objs.append(bodies[start:i+1])
assert len(objs) == 2, len(objs)
ops = json.loads(objs[1])['transactions'][0]['operations']
assert not any(o.get('path') == ['data'] for o in ops), ops
assert [o['command'] for o in ops] == ['listRemove','update','update','update'], ops
" 2>/dev/null; then
    ok "в ветке гонки отправлен узкий откат без операции по segments"
else
    fail "узкий откат не отправлен или содержит запись сегментов"
fi
ST=$(block_state)
if echo "$ST" | python3 -c "
import json, sys
st = json.load(sys.stdin)
assert st['lit'] == ['$OTHER'], st['lit']          # подсветка победителя цела
assert st['listed'] == ['$OTHER'], st['listed']    # наш тред снят со списка
" 2>/dev/null; then
    ok "после самоочистки подсветка победителя цела, наш тред снят"
else
    fail "самоочистка повредила состояние: $ST"
fi

# ---- #4 (раунд 3): отмена ДО записи — теперь достижима ручкой стаба ---------
# Раньше эта ветка не проверялась ничем: стаб отдавал один и тот же документ на
# оба чтения, и проверку можно было удалить, не уронив ни одного теста.
write_fixture
export STUB_MUTATE_ON_GET=2
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
unset STUB_MUTATE_ON_GET
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'блок изменился'; then
    ok "правка блока между чтениями отменяет запись до POST"
else
    fail "отмена до записи не сработала (rc=$RC): $(stderr | head -2)"
fi

# ---- #1 (раунд 3): сбой самого POST ----------------------------------------
write_fixture
export STUB_FAIL_POST=1
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
unset STUB_FAIL_POST
if [ "$RC" -eq 2 ] && stderr | grep -q 'discussion:' && stderr | grep -q 'исход записи неизвестен'; then
    ok "сбой POST называет тред и запрещает слепой повтор"
else
    fail "сбой POST обработан молча (rc=$RC): $(stderr | tail -3)"
fi

# ---- #2 (раунд 3): отказ API не выдаётся за гонку ---------------------------
# Проверочное чтение отдаёт конверт ошибки: об исходе записи ничего не известно,
# поэтому гасить свой (возможно успешный) тред нельзя.
write_fixture
export STUB_INBAND_ERROR=1
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
unset STUB_INBAND_ERROR
POSTS=$(cat "$TMP/log/postn" 2>/dev/null || echo 0)
if [ "$RC" -eq 2 ] && stderr | grep -q 'не вернуло блок' && [ "$POSTS" -eq 1 ]; then
    ok "конверт ошибки на проверке — код 2 и никакой самоочистки"
else
    fail "конверт ошибки принят за гонку (rc=$RC, POST-ов=$POSTS): $(stderr | tail -3)"
fi

# Транзакция принята, но не применилась: нашего треда нет даже в списке блока.
write_fixture
export STUB_IGNORE_WRITES=1
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
unset STUB_IGNORE_WRITES
POSTS=$(cat "$TMP/log/postn" 2>/dev/null || echo 0)
if [ "$RC" -eq 1 ] && stderr | grep -q 'не применилась' && stderr | grep -q 'повтор безопасен' && [ "$POSTS" -eq 1 ]; then
    ok "неприменившаяся транзакция названа своим именем, тред не гасится"
else
    fail "неприменившаяся транзакция принята за гонку (rc=$RC, POST-ов=$POSTS): $(stderr | tail -3)"
fi

# ---- #3 (раунд 3): сбой самоочистки не глушит запрет полного отката ---------
write_fixture
export STUB_FOREIGN_AFTER_POST="$OTHER" STUB_FAIL_SECOND_POST=1
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
unset STUB_FOREIGN_AFTER_POST STUB_FAIL_SECOND_POST
if [ "$RC" -eq 2 ] && stderr | grep -q 'применять НЕ надо' && stderr | grep -q 'Снять тред не удалось'; then
    ok "сбой самоочистки сохраняет запрет применять полный откат"
else
    fail "сбой самоочистки проглотил запрет (rc=$RC): $(stderr | tail -4)"
fi

# ---- #5 (раунд 3): transaction() не шлёт пустое тело ни в каком контексте ----
# Регрессия из fcb0107: сбор тела подстановкой в аргументе прятал сбой от set -e.
# Вторая половина — вызов в условии if, где bash глушит set -e во всей функции.
python3 - "$SRC_DIR/buildin-pages.sh" "$TMP/tx-probe.sh" <<'EXTRACT'
import sys
src_path, out_path = sys.argv[1:3]
src = open(src_path, encoding="utf-8").read()
tail = '" "$OPERATIONS" "$(gen_uuid)" "$(gen_uuid)" "$SPACE_ID"\n}'
tx_body = src[src.index("tx_body() {"):src.index(tail) + len(tail)]
start = src.index("transaction() {")
transaction = src[start:src.index("\n}\n", start) + 2]
open(out_path, "w", encoding="utf-8").write(
    "#!/bin/bash\nset -e\n"
    "gen_uuid() { echo u; }\n"
    'buildin() { echo "POST-SENT" >> "$PROBE_LOG"; }\n'
    + tx_body + "\n" + transaction + "\n"
    'case "$1" in\n'
    '  plain) transaction sp "не-json" ;;\n'
    '  guard) if ! transaction sp "не-json"; then echo "if-ветка" >/dev/null; fi ;;\n'
    'esac\n')
EXTRACT
for mode in plain guard; do
    : > "$TMP/log/probe-$mode.txt"
    PROBE_LOG="$TMP/log/probe-$mode.txt" /bin/bash "$TMP/tx-probe.sh" "$mode" >/dev/null 2>&1 || true
    if [ -s "$TMP/log/probe-$mode.txt" ]; then
        fail "transaction ($mode): POST ушёл с пустым телом"
    else
        ok "transaction ($mode): сбой сборки тела не даёт отправить POST"
    fi
done

# ---- #6 (раунд 3): временные файлы команды не остаются на диске -------------
# Голый mktemp на macOS игнорирует TMPDIR и кладёт файлы в /var/folders/...,
# поэтому «посчитать файлы в TMPDIR» утечку не видит. Подменяем сам mktemp:
# он загоняет безымянные вызовы в известный каталог и ведёт журнал созданного.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/mktemp" <<SHIM
#!/bin/bash
D="\$MKTEMP_PROBE_DIR"; LOG="\$MKTEMP_PROBE_LOG"
if [ "\${1:-}" = "-d" ]; then
    out=\$(/usr/bin/mktemp -d "\$D/probe-XXXXXX")
else
    case "\${1:-}" in
        */*) out=\$(/usr/bin/mktemp "\$@") ;;   # шаблон с путём — отдаём как есть
        *)   out=\$(/usr/bin/mktemp "\$D/probe-XXXXXX") ;;
    esac
fi
printf '%s\n' "\$out" >> "\$LOG"
printf '%s\n' "\$out"
SHIM
chmod +x "$TMP/bin/mktemp"

PROBE="$TMP/mktemp-probe"; rm -rf "$PROBE"; mkdir -p "$PROBE"
PROBE_LOG="$TMP/log/mktemp-created.txt"; : > "$PROBE_LOG"
write_fixture
RC=$(PATH="$TMP/bin:$PATH" MKTEMP_PROBE_DIR="$PROBE" MKTEMP_PROBE_LOG="$PROBE_LOG" \
     run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
CREATED=$(wc -l < "$PROBE_LOG" | tr -d ' ')
STRAY=0
while IFS= read -r f; do
    case "$f" in *buildin-rollback-*) continue ;; esac   # файл отката остаётся намеренно
    [ -e "$f" ] && { STRAY=$((STRAY + 1)); echo "      остался: $f"; }
done < "$PROBE_LOG"
if [ "$RC" -eq 0 ] && [ "$CREATED" -ge 3 ] && [ "$STRAY" -eq 0 ]; then
    ok "все временные файлы команды удалены, кроме файла отката ($CREATED создано)"
else
    fail "утечка временных файлов (rc=$RC, создано=$CREATED, осталось=$STRAY)"
fi

CLEANDIR="$TMP/tmpdir-probe"; rm -rf "$CLEANDIR"; mkdir -p "$CLEANDIR"

# ---- #23 (раунд 3): результат успешного запуска лежит в stdout --------------
write_fixture
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
OUT_ID=$(stdout | sed -n 's/^discussion: //p')
ERR_ID=$(stderr | sed -n 's/^discussion: //p' | head -1)
if [ "$RC" -eq 0 ] && [ -n "$OUT_ID" ] && [ "$OUT_ID" = "$ERR_ID" ] && [ "$(stdout | wc -l | tr -d ' ')" -eq 1 ]; then
    ok "успешный запуск печатает id треда в stdout и ничего лишнего"
else
    fail "id треда не в stdout (rc=$RC): $(stdout | head -3)"
fi

# ---- #18 (раунд 3): дефолтные пути отката не сталкиваются, права 0600 -------
# В раунде 1 эта проверка была заявлена в ответе, но в харнесс не попала.
write_fixture
RC=$(TMPDIR="$CLEANDIR" run_comment "$PAGE" "$BLOCK" 'в минуту' 'первый')
RB1=$(stderr | grep -o "$CLEANDIR/buildin-rollback-[A-Za-z0-9]*" | head -1)
RC=$(SKIP_RESET=1 TMPDIR="$CLEANDIR" run_comment "$PAGE" "$BLOCK" 'безлимитный' 'второй')
RB2=$(stderr | grep -o "$CLEANDIR/buildin-rollback-[A-Za-z0-9]*" | head -1)
if [ -n "$RB1" ] && [ -n "$RB2" ] && [ "$RB1" != "$RB2" ] && [ -s "$RB1" ] && [ -s "$RB2" ]; then
    ok "два комментария подряд получают разные файлы отката"
else
    fail "пути отката совпали или пусты: [$RB1] [$RB2]"
fi
if python3 -c "
import os, stat, sys
for p in ('$RB1', '$RB2'):
    m = stat.S_IMODE(os.stat(p).st_mode)
    assert m == 0o600, (p, oct(m))
" 2>/dev/null; then
    ok "дефолтные файлы отката создаются с правами 0600"
else
    fail "права дефолтного файла отката не 0600"
fi
EXPLICIT="$CLEANDIR/explicit-rollback.json"
write_fixture
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$EXPLICIT")
if [ "$RC" -eq 0 ] && python3 -c "
import os, stat
m = stat.S_IMODE(os.stat('$EXPLICIT').st_mode)
assert m == 0o600, oct(m)
" 2>/dev/null; then
    ok "файл по --rollback-out тоже получает права 0600"
else
    fail "файл по --rollback-out создан с правами по umask"
fi

# ---- регресс: comments после выноса parse_page_and_block_id ------------------
write_fixture
# Проверяем ВЫВОД, а не только rc: если разбор начнёт брать UUID пространства
# вместо страницы или блока, код выхода останется нулевым.
RC=$(run_cmd comments "$PAGE" "$BLOCK")
if [ "$RC" -eq 0 ] && stdout | grep -q "$BLOCK" && ! stdout | grep -q "$SPACE"; then
    ok "comments принимает <page> <block> и работает с тем самым блоком"
else
    fail "comments сломан на <page> <block> (rc=$RC): $(stdout | head -2)"
fi
RC=$(run_cmd comments "https://buildin.ai/$SPACE/$PAGE#$BLOCK")
if [ "$RC" -eq 0 ] && stdout | grep -q "$BLOCK" && ! stdout | grep -q "$SPACE"; then
    ok "comments принимает <url>#<block_uuid> и не путает space с page"
else
    fail "comments сломан на якоре в URL (rc=$RC): $(stdout | head -2)"
fi

echo "---"
if [ "$FAILS" -gt 0 ]; then
    echo "$FAILS check(s) failed"
    exit 1
fi
echo "all checks passed"
