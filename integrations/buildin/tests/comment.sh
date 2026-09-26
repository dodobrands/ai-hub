#!/usr/bin/env bash
# bash-слой команды `comment` под /bin/bash: разбор аргументов, формы ввода,
# --dry-run, откат, оптимистичная проверка.
#
# Зачем отдельно от bats-юнитов: те бьют по чистому питоновскому билдеру, а
# ошибки разбора аргументов живут в shell. Опечатка «--dryrun», молча ставшая
# позиционным аргументом, делала боевую запись вместо превью — ровно такой
# класс багов сюда и ловится. Плюс на macOS /bin/bash = 3.2, целевой шелл
# скриптов хаба, и он проверяется тем же прогоном.
#
# buildin.sh застаблен: отвечает канонными JSON, тела запросов пишет в log/.
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

# ---- песочница: копия скриптов + стаб buildin.sh ----------------------------
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

# Стаб buildin.sh: тела транзакций в log/, GET отдаёт состояние, POST его меняет.
# Состояние настоящее, а не застывшая фикстура: иначе проверку после записи
# («подсветка закрепилась?») нельзя ни подтвердить, ни опровергнуть.
cat > "$TMP/scripts/apply-ops.py" <<'APPLY'
import json, os, sys
state_path, body_path, block_id = sys.argv[1:4]
state = json.load(open(state_path))
block = state["data"]["blocks"][block_id]
for op in json.load(open(body_path))["transactions"][0]["operations"]:
    if op.get("table") != "block" or op["id"] != block_id:
        continue
    if op["command"] == "update" and op.get("path") == ["data"]:
        block["data"].update(op["args"])
    elif op["command"] == "listAfter" and op.get("path") == ["discussions"]:
        block.setdefault("discussions", []).append(op["args"]["uuid"])
    elif op["command"] == "listRemove" and op.get("path") == ["discussions"]:
        block["discussions"] = [d for d in block.get("discussions", []) if d != op["args"]["uuid"]]
drop = os.environ.get("STUB_DROP_HIGHLIGHT")
if drop:
    for seg in block["data"].get("segments", []):
        if drop in (seg.get("discussions") or []):
            seg["discussions"] = [d for d in seg["discussions"] if d != drop]
json.dump(state, open(state_path, "w"), ensure_ascii=False)
APPLY

restore_stateful_stub() {
    cat > "$TMP/scripts/buildin.sh" <<STUB
#!/usr/bin/env bash
METHOD="\$1"; ENDPOINT="\$2"; BODY="\${3:-}"
LOG_DIR="$TMP/log"
case "\$ENDPOINT" in
    /api/users/me)             echo '{"code":200,"data":{"uuid":"user-1"}}' ;;
    /api/docs/*)               cat "$TMP/state.json" ;;
    /api/records/transactions) printf '%s' "\$BODY" > "\$LOG_DIR/tx-body.json"
                               [ -z "\${STUB_IGNORE_WRITES:-}" ] && python3 "$TMP/scripts/apply-ops.py" \
                                   "$TMP/state.json" "\$LOG_DIR/tx-body.json" "$BLOCK"
                               echo '{"code":200,"data":true}' ;;
    *)                         echo '{"code":404}' ;;
esac
STUB
    chmod +x "$TMP/scripts/buildin.sh"
}
restore_stateful_stub

# Прогон команды под /bin/bash. Печатает rc; stdout/stderr — в log/.
run_comment() {
    rm -f "$TMP/log/tx-body.json"
    [ -n "${SKIP_RESET:-}" ] || write_fixture
    /bin/bash "$TMP/scripts/buildin-pages.sh" comment "$@" \
        > "$TMP/log/stdout.txt" 2> "$TMP/log/stderr.txt"
    echo $?
}
sent()   { [ -s "$TMP/log/tx-body.json" ]; }
stderr() { cat "$TMP/log/stderr.txt"; }
stdout() { cat "$TMP/log/stdout.txt"; }

# ---- P1 #1: неизвестные флаги не должны становиться позиционными ------------
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' --dryrun)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'неизвестный флаг'; then
    ok "опечатка --dryrun отвергнута, боевой записи нет"
else
    fail "опечатка --dryrun не отвергнута (rc=$RC, записал=$(sent && echo да || echo нет))"
fi

RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' --rollback-out "$TMP/mine.json")
if [ "$RC" -eq 0 ] && [ -s "$TMP/mine.json" ]; then
    ok "пробельная форма --rollback-out <path> принята"
else
    fail "пробельная форма --rollback-out не сработала (rc=$RC): $(stderr)"
fi

RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' 'лишний')
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'ровно <anchor> и <text>'; then
    ok "лишний позиционный аргумент отвергнут"
else
    fail "лишний позиционный аргумент не отвергнут (rc=$RC)"
fi

# ---- P2 #6: --dry-run не трогает ни сеть, ни диск ---------------------------
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

# ---- P3 #11: пустой текст/якорь после разворачивания -------------------------
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

# ---- P2 #5: неоднозначный якорь ---------------------------------------------
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
RC=$(run_comment "$PAGE" "$BLOCK" 'лимит' 'текст' --occurrence=0)
if [ "$RC" -ne 0 ] && ! sent; then
    ok "--occurrence=0 отвергнут"
else
    fail "--occurrence=0 не отвергнут (rc=$RC)"
fi

# ---- P3 #8: экранирование сигилов -------------------------------------------
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' '@@j.doe глянь сюда')
if [ "$RC" -eq 0 ] && sent && python3 -c "
import json, sys
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

# ---- #4: проверка ДО записи — блок изменился между GET и POST ---------------
# Стаб отдаёт исходный документ на первый GET и изменённый на последующие:
# имитация чужой правки, пришедшей пока готовился комментарий.
cat > "$TMP/state-changed.json" <<DOC
{"code":200,"data":{"blocks":{"$BLOCK":{
  "uuid":"$BLOCK","spaceId":"$SPACE","type":1,"discussions":[],
  "data":{"pageFixedWidth":true,
    "segments":[{"text":"кто-то переписал блок, но фраза в минуту цела","type":0,"enhancer":{}}]}}}}}
DOC
cat > "$TMP/scripts/buildin.sh" <<STUB2
#!/usr/bin/env bash
METHOD="\$1"; ENDPOINT="\$2"; BODY="\${3:-}"
LOG_DIR="$TMP/log"
case "\$ENDPOINT" in
    /api/users/me)             echo '{"code":200,"data":{"uuid":"user-1"}}' ;;
    /api/docs/*)               N=\$(cat "\$LOG_DIR/getn" 2>/dev/null || echo 0); N=\$((N + 1))
                               echo "\$N" > "\$LOG_DIR/getn"
                               if [ "\$N" -le 1 ]; then cat "$TMP/state.json"; else cat "$TMP/state-changed.json"; fi ;;
    /api/records/transactions) printf '%s' "\$BODY" > "\$LOG_DIR/tx-body.json"
                               echo '{"code":200,"data":true}' ;;
    *)                         echo '{"code":404}' ;;
esac
STUB2
chmod +x "$TMP/scripts/buildin.sh"
rm -f "$TMP/log/getn"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'блок изменился'; then
    ok "правка блока между GET и POST отменяет запись"
else
    fail "конкурентная правка не отменила запись (rc=$RC): $(stderr | head -2)"
fi

# ---- #4: проверка ПОСЛЕ записи ----------------------------------------------
# Проверка до записи сужает окно, но не закрывает: несколько процессов успевают
# сделать оба GET раньше первого POST (воспроизведено на живой странице —
# из трёх параллельных комментариев двое теряли подсветку). Поэтому результат
# сверяется по факту, и тихая потеря становится громкой.
restore_stateful_stub

# а) наша подсветка не закрепилась: стаб принимает запись, но состояние не меняет
export STUB_IGNORE_WRITES=1
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
unset STUB_IGNORE_WRITES
if [ "$RC" -ne 0 ] && sent && stderr | grep -q 'подсветка не закрепилась'; then
    ok "незакрепившаяся подсветка своего треда — громкая ошибка"
else
    fail "незакрепившаяся подсветка не обнаружена (rc=$RC): $(stderr | head -2)"
fi

# б) чужой тред был подсвечен, а после нашей записи подсветку потерял —
#    ровно то, что случилось на живой странице при трёх параллельных прогонах
write_fixture
python3 -c "
import json
p = '$TMP/state.json'
st = json.load(open(p))
b = st['data']['blocks']['$BLOCK']
b['discussions'] = ['$OTHER']
b['data']['segments'][1]['discussions'] = ['$OTHER']
json.dump(st, open(p, 'w'), ensure_ascii=False)
"
export STUB_DROP_HIGHLIGHT="$OTHER"
RC=$(SKIP_RESET=1 run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
unset STUB_DROP_HIGHLIGHT
if [ "$RC" -eq 0 ] && sent && stderr | grep -q "лишила подсветки чужие треды: $OTHER"; then
    ok "потерявший подсветку чужой тред назван в предупреждении"
else
    fail "чужой тред без подсветки не отмечен (rc=$RC): $(stderr | head -3)"
fi

# в) давно осиротевший чужой тред (в списке, но без подсветки ещё до нас) —
#    не наша вина и не повод для тревоги
write_fixture
python3 -c "
import json
p = '$TMP/state.json'
st = json.load(open(p))
st['data']['blocks']['$BLOCK']['discussions'] = ['$OTHER']
json.dump(st, open(p, 'w'), ensure_ascii=False)
"
RC=$(SKIP_RESET=1 run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
if [ "$RC" -eq 0 ] && ! stderr | grep -q 'ВНИМАНИЕ'; then
    ok "давно осиротевший тред не даёт ложной тревоги"
else
    fail "ложная тревога на давно осиротевшем треде (rc=$RC): $(stderr | head -3)"
fi

# г) happy path: наша подсветка на месте, предупреждений нет
write_fixture
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
if [ "$RC" -eq 0 ] && sent && ! stderr | grep -q 'ВНИМАНИЕ'; then
    ok "обычная запись проходит без предупреждений"
else
    fail "обычная запись дала предупреждение (rc=$RC): $(stderr | head -3)"
fi

echo "---"
if [ "$FAILS" -gt 0 ]; then
    echo "$FAILS check(s) failed"
    exit 1
fi
echo "all checks passed"
