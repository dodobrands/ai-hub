#!/usr/bin/env bash
# Ошибки Buildin UI API под /bin/bash: не-успешный `code` в теле останавливает работу.
#
# Зачем: UI API кладёт настоящий статус не в HTTP, а в поле `code` тела — на
# несуществующий документ он отвечает HTTP 200 и {"code":3005,"msg":"Document
# not found"}. Клиент, который смотрит только на HTTP-статус, отдаёт такой ответ
# вызывающему как успех, и тот идёт дальше с телом ошибки вместо данных.
#
# Второй рубеж — пустые USER_ID/SPACE_ID в buildin-pages.sh: если идентификатор
# не достали (тело оказалось ошибкой, форма ответа поменялась), транзакция не
# должна уходить с пустым полем — молча испорченная запись хуже отказа.
#
# curl и buildin.sh застаблены, сеть не нужна. Тест — plain bash, чтобы на маке
# его можно было гонять без bats прямо под /bin/bash 3.2 (целевой шелл хаба).
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$TESTS_DIR/../scripts"
HUB_META_DIR="$TESTS_DIR/../../hub-meta/scripts"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0

fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
ok()   { echo "ok:   $1"; }

# ---- песочница 1: buildin.sh с застабленным curl -----------------------------
# Раскладка повторяет боевую (<root>/integrations/<plugin>/scripts/): buildin.sh
# ищет load-env.sh относительным путём, а тот НЕ доверяет унаследованному
# окружению — токен подсовываем только через .env песочницы.
API_ROOT="$TMP/api"
mkdir -p "$API_ROOT/integrations/buildin/scripts" "$API_ROOT/integrations/hub-meta/scripts" "$TMP/bin"
cp "$SRC_DIR/buildin.sh" "$API_ROOT/integrations/buildin/scripts/"
cp "$HUB_META_DIR/load-env.sh" "$API_ROOT/integrations/hub-meta/scripts/"
printf 'BUILDIN_UI_TOKEN=test-token\n' > "$API_ROOT/.env"

cat > "$TMP/bin/curl" <<'STUB'
#!/bin/sh
# Стаб curl: тело и HTTP-код задаёт тест через STUB_BODY/STUB_HTTP.
# buildin.sh читает ответ как «тело \n http_code» (curl -w "\n%{http_code}").
printf '%s\n%s\n' "$STUB_BODY" "$STUB_HTTP"
STUB
chmod +x "$TMP/bin/curl"

run_api() {
    STUB_BODY="$1" STUB_HTTP="$2" PATH="$TMP/bin:$PATH" \
        /bin/bash "$API_ROOT/integrations/buildin/scripts/buildin.sh" GET /api/users/me \
        > "$TMP/out.txt" 2> "$TMP/err.txt"
}

# Ответ должен быть отвергнут, а причина — названа в stderr.
expect_fail() {
    local name="$1" body="$2" http="$3" needle="$4" rc
    run_api "$body" "$http"; rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "$name: ожидался ненулевой код возврата, получен 0 (stdout: $(head -c 160 "$TMP/out.txt"))"
    elif ! grep -q "$needle" "$TMP/err.txt"; then
        fail "$name: в stderr нет «$needle» (stderr: $(head -c 200 "$TMP/err.txt"))"
    else
        ok "$name"
    fi
}

# Ответ должен пройти насквозь — тело доезжает до вызывающего. Пустой needle —
# проверяем только код возврата (у пустого тела искать в stdout нечего).
expect_pass() {
    local name="$1" body="$2" http="$3" needle="$4" rc
    run_api "$body" "$http"; rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$name: ожидался код 0, получен $rc (stderr: $(head -c 200 "$TMP/err.txt"))"
    elif [ -n "$needle" ] && ! grep -q "$needle" "$TMP/out.txt"; then
        fail "$name: в stdout нет «$needle» (stdout: $(head -c 200 "$TMP/out.txt"))"
    else
        ok "$name"
    fi
}

echo "--- buildin.sh: статус из тела ответа ---"
expect_fail "code 3005 при HTTP 200 — отказ"        '{"code":3005,"msg":"Document not found"}'      200 '3005'
expect_fail "code 3005 — msg попадает в stderr"     '{"code":3005,"msg":"Document not found"}'      200 'Document not found'
expect_fail "code 500 при HTTP 200 — отказ"         '{"code":500,"msg":"Internal server error."}'   200 '500'
expect_fail "code 422 при HTTP 200 — отказ"         '{"code":422,"msg":"\"doc\" must be a GUID"}'   200 '422'

echo "--- buildin.sh: что не должно падать ---"
expect_pass "code 200 — успех"                      '{"code":200,"data":{"uuid":"u1"}}'             200 'u1'
expect_pass "нет поля code — успех"                 '{"data":{"uuid":"u1"}}'                        200 'u1'
expect_pass "не-JSON тело — успех, тело как есть"   'plain text, not json at all'                   200 'plain text'
expect_pass "JSON-массив — успех"                   '[{"uuid":"u1"}]'                               200 'u1'
expect_pass "пустое тело — успех"                   ''                                              200 ''
# Статус — только верхнеуровневый `code`. Страница, в тексте которой лежит свой
# «code», не должна выглядеть ошибкой: на этом ломается поиск статуса грепом.
expect_pass "вложенный code не считается статусом"  '{"code":200,"data":{"inner":{"code":500}}}'    200 'inner'

echo "--- buildin.sh: прежние ветки по HTTP-статусу целы ---"
expect_fail "HTTP 401 — прежнее сообщение"          '{"code":200}'                                  401 'buildin-login'
expect_fail "HTTP 500 — прежняя ветка"              '{"code":200}'                                  500 'HTTP 500'

# ---- песочница 2: buildin-pages.sh с застабленным buildin.sh -----------------
PAGES_DIR="$TMP/pages"
mkdir -p "$PAGES_DIR/scripts" "$PAGES_DIR/log"
cp "$SRC_DIR/buildin-pages.sh" "$SRC_DIR/buildin-blocks.py" "$PAGES_DIR/scripts/"

cat > "$PAGES_DIR/scripts/buildin.sh" <<STUB
#!/usr/bin/env bash
# Стаб buildin.sh: ответы на me/blocks задаёт тест через ME_JSON/BLOCK_JSON,
# тело транзакции пишет в log/ — по его наличию видно, ушла ли запись.
ENDPOINT="\$2"; BODY="\${3:-}"
case "\$ENDPOINT" in
    /api/users/me)             printf '%s' "\$ME_JSON" ;;
    /api/blocks/*)             printf '%s' "\$BLOCK_JSON" ;;
    /api/records/transactions) printf '%s' "\$BODY" > "$PAGES_DIR/log/tx-body.json"
                               echo '{"code":200,"data":true}' ;;
    *)                         echo '{"code":404,"msg":"stub: unknown endpoint '"\$ENDPOINT"'"}' ;;
esac
STUB
chmod +x "$PAGES_DIR/scripts/buildin.sh"

TX_FILE="$PAGES_DIR/log/tx-body.json"
BLOCKS_ARG='[{"type":1,"data":{"segments":[{"type":0,"text":"x","enhancer":{}}]}}]'

run_pages() {
    rm -f "$TX_FILE"
    ME_JSON="$1" BLOCK_JSON="$2" \
        /bin/bash "$PAGES_DIR/scripts/buildin-pages.sh" \
        append-blocks 11111111-2222-3333-4444-555555555555 "$BLOCKS_ARG" \
        > "$PAGES_DIR/log/stdout.txt" 2> "$PAGES_DIR/log/stderr.txt"
}

# Идентификатор не достали — команда обязана отказаться ДО отправки транзакции.
expect_no_tx() {
    local name="$1" me="$2" block="$3" rc
    run_pages "$me" "$block"; rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "$name: ожидался ненулевой код возврата, получен 0"
    elif [ -f "$TX_FILE" ]; then
        fail "$name: транзакция ушла, хотя идентификатор пуст: $(head -c 200 "$TX_FILE")"
    else
        ok "$name"
    fi
}

ME_OK='{"code":200,"data":{"uuid":"user-1"}}'
BLOCK_OK='{"code":200,"data":{"spaceId":"space-1","parentId":"parent-1"}}'

echo "--- buildin-pages.sh: пустой идентификатор не уезжает в транзакцию ---"
expect_no_tx "append-blocks: пустой USER_ID"   '{"code":200,"data":{}}'                "$BLOCK_OK"
expect_no_tx "append-blocks: нет data в me"    '{"code":200}'                          "$BLOCK_OK"
expect_no_tx "append-blocks: пустой SPACE_ID"  "$ME_OK"                                '{"code":200,"data":{}}'

echo "--- buildin-pages.sh: здоровый путь не сломан ---"
run_pages "$ME_OK" "$BLOCK_OK"; RC=$?
if [ "$RC" -ne 0 ]; then
    fail "append-blocks на здоровых ответах упал (rc=$RC), stderr: $(head -c 300 "$PAGES_DIR/log/stderr.txt")"
elif [ ! -s "$TX_FILE" ]; then
    fail "append-blocks на здоровых ответах не отправил транзакцию"
elif ! python3 -c "
import json, sys
ops = json.load(open(sys.argv[1]))['transactions'][0]
assert ops['spaceId'] == 'space-1', 'spaceId в транзакции: %r' % ops['spaceId']
users = [o['args']['createdBy'] for o in ops['operations'] if 'createdBy' in o.get('args', {})]
assert users and all(u == 'user-1' for u in users), 'createdBy в транзакции: %r' % users
" "$TX_FILE" 2>"$TMP/assert-err.txt"; then
    fail "append-blocks: транзакция собрана неверно: $(cat "$TMP/assert-err.txt")"
else
    ok "append-blocks на здоровых ответах доходит до транзакции"
fi

# ---- песочница 3: сквозной путь — потребитель поверх настоящего buildin.sh ----
# Здесь важен не код возврата (он и так верный), а вывод: потребители зовут
# клиента в конвейере `buildin ... | python3`, и остановить питон оттуда нельзя.
# На пустом stdin он валится JSONDecodeError и забивает трейсбеком то самое
# внятное сообщение, ради которого всё делалось.
cp "$SRC_DIR/buildin-pages.sh" "$SRC_DIR/buildin-nav.sh" "$SRC_DIR/buildin-blocks.py" \
   "$API_ROOT/integrations/buildin/scripts/"

PAGES="$API_ROOT/integrations/buildin/scripts/buildin-pages.sh"
NAV="$API_ROOT/integrations/buildin/scripts/buildin-nav.sh"
SOME_ID='11111111-2222-3333-4444-555555555555'

# Прогнать команду потребителя поверх заданного ответа API.
run_consumer() {
    STUB_BODY="$1" STUB_HTTP="$2" PATH="$TMP/bin:$PATH" \
        /bin/bash "$3" "$4" "$SOME_ID" > "$TMP/out.txt" 2> "$TMP/err.txt"
}

# При отказе API: причина видна, трейсбека нет, код возврата ненулевой.
expect_clean_failure() {
    local name="$1" body="$2" http="$3" script="$4" cmd="$5" needle="$6" rc
    run_consumer "$body" "$http" "$script" "$cmd"; rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "$name: ожидался ненулевой код возврата, получен 0"
    elif grep -q 'Traceback' "$TMP/err.txt"; then
        fail "$name: в stderr трейсбек питона — внятное сообщение в нём тонет"
    elif ! grep -q "$needle" "$TMP/err.txt"; then
        fail "$name: в stderr нет причины «$needle» (stderr: $(head -c 200 "$TMP/err.txt"))"
    else
        ok "$name"
    fi
}

echo "--- потребитель при отказе API: сообщение без трейсбека ---"
expect_clean_failure "title: code 3005 в теле"  '{"code":3005,"msg":"Document not found"}' 200 "$PAGES" title '3005'
expect_clean_failure "title: HTTP 500"          '{"error":"boom"}'                         500 "$PAGES" title 'HTTP 500'
expect_clean_failure "title: HTTP 401"          '{"code":401}'                             401 "$PAGES" title 'buildin-login'
expect_clean_failure "get-blocks: code 3005"    '{"code":3005,"msg":"Document not found"}' 200 "$PAGES" get-blocks '3005'

echo "--- stdout клиента при отказе — валидный JSON (иначе питон и падает) ---"
for probe in '200:{"code":3005,"msg":"Document not found"}' '500:{"error":"boom"}' '401:{"code":401}'; do
    http="${probe%%:*}"; body="${probe#*:}"
    run_api "$body" "$http"
    if python3 -c 'import json,sys; json.load(sys.stdin)' < "$TMP/out.txt" 2>/dev/null; then
        ok "HTTP $http: stdout разбирается как JSON"
    else
        fail "HTTP $http: stdout не JSON → [$(head -c 120 "$TMP/out.txt")]"
    fi
done

echo "--- buildin-nav.sh: обход дерева по-прежнему деградирует, а не падает ---"
# get_title зовётся на каждый узел дерева: один сбойный узел должен помечаться
# «(error)», а не ронять весь обход.
STUB_BODY='{"code":3005,"msg":"Document not found"}' STUB_HTTP=200 PATH="$TMP/bin:$PATH" \
    /bin/bash "$NAV" title "$SOME_ID" > "$TMP/out.txt" 2> "$TMP/err.txt"
if grep -q 'Traceback' "$TMP/err.txt"; then
    fail "nav title: в stderr трейсбек питона"
elif ! grep -q '(error)' "$TMP/out.txt"; then
    fail "nav title: сбойный узел должен помечаться «(error)», получено [$(head -c 80 "$TMP/out.txt")]"
else
    ok "nav title: сбойный узел помечен «(error)», обход не упал"
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: все проверки пройдены"
else
    echo "FAILED: $FAILS"
fi
[ "$FAILS" -eq 0 ]
