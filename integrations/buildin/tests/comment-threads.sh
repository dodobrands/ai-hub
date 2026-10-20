#!/usr/bin/env bash
# bash-слой команд тредов под /bin/bash: comment-reply, comment-resolve и
# comment-unresolve — запись, отказы до неё и исходы проверки после;
# comment-rollback — проверка файла, сверка свежести и защита от повтора;
# --mention у comment и comment-reply. Общий стаб и хелперы — в
# comment-harness.sh.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/comment-harness.sh"

# ---- comment-resolve / comment-unresolve -------------------------------------

write_thread_fixture false
RC=$(run_sub comment-resolve "$PAGE" "$THREAD")
if [ "$RC" -eq 0 ] && [ "$(thread_field resolved)" = "true" ] && [ "$(posts)" -eq 1 ] \
   && [ "$(stdout)" = "discussion: $THREAD
status: changed" ]; then
    ok "comment-resolve закрывает тред, в stdout — id и status: changed"
else
    fail "comment-resolve не закрыл тред (rc=$RC, resolved=$(thread_field resolved)): $(stderr | head -2)"
fi

write_thread_fixture true
RC=$(run_sub comment-unresolve "https://buildin.ai/$SPACE/$PAGE" "$THREAD")
if [ "$RC" -eq 0 ] && [ "$(thread_field resolved)" = "false" ]; then
    ok "comment-unresolve открывает тред, страница — и формой URL"
else
    fail "comment-unresolve не открыл тред (rc=$RC): $(stderr | head -2)"
fi

write_thread_fixture true
RC=$(run_sub comment-resolve "$PAGE" "$THREAD")
if [ "$RC" -eq 0 ] && ! sent && stderr | grep -q 'уже закрыт' && [ "$(stdout)" = "discussion: $THREAD
status: noop" ]; then
    ok "уже закрытый тред — без записи, выход 0, status: noop"
else
    fail "повторный резолв что-то записал или упал (rc=$RC, POST-ов=$(posts))"
fi

write_thread_fixture false
RC=$(run_sub comment-resolve "$PAGE" "$THREAD" --dry-run)
if [ "$RC" -eq 0 ] && ! sent && stdout | grep -q '"resolved": true'; then
    ok "резолв с --dry-run печатает операцию и ничего не отправляет"
else
    fail "резолв с --dry-run (rc=$RC, отправил=$(sent && echo да || echo нет)): $(stdout | head -3)"
fi

write_thread_fixture false
RC=$(run_sub comment-resolve "$PAGE" "$THREAD" "--rollback-out=$TMP/rb-resolve.json")
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'неизвестный флаг: --rollback-out'; then
    ok "флаг, которого у резолва нет, отвергнут, а не принят молча"
else
    fail "резолв принял --rollback-out (rc=$RC)"
fi

# Разрешённый флаг в чужой форме не должен стать позиционным аргументом.
write_thread_fixture false
RC=$(run_sub comment-resolve "$PAGE" "$THREAD" --dry-run=yes)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'неизвестный флаг: --dry-run=yes'; then
    ok "--dry-run=yes отвергнут, а не принят за позиционный аргумент"
else
    fail "--dry-run=yes не отвергнут как флаг (rc=$RC): $(stderr | head -1)"
fi

RC=$(run_sub comment-resolve "$PAGE" "не-uuid")
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'не UUID'; then
    ok "id треда не в форме UUID отвергнут"
else
    fail "кривой id треда не отвергнут (rc=$RC)"
fi

write_thread_fixture false
RC=$(run_sub comment-resolve "$PAGE" "$THREAD" лишний)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'ожидался ровно <discussion_id>'; then
    ok "лишний позиционный аргумент резолва отвергнут"
else
    fail "лишний аргумент резолва не отвергнут (rc=$RC)"
fi

RC=$(run_sub comment-resolve)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'Usage: comment-resolve'; then
    ok "comment-resolve без аргументов печатает справку"
else
    fail "comment-resolve без аргументов (rc=$RC): $(stderr | head -1)"
fi

write_fixture
RC=$(run_sub comment-resolve "$PAGE" "$THREAD")
if [ "$RC" -eq 1 ] && ! sent && stderr | grep -q 'на странице нет'; then
    ok "тред не с этой страницы — отказ без записи"
else
    fail "отсутствующий тред не отвергнут (rc=$RC): $(stderr | head -2)"
fi

write_thread_fixture false
export STUB_FAIL_POST=1
RC=$(run_sub comment-resolve "$PAGE" "$THREAD")
unset STUB_FAIL_POST
if [ "$RC" -eq 2 ] && stderr | grep -q 'исход записи неизвестен' && stderr | grep -q 'Повтор безопасен'; then
    ok "сбой POST при резолве — код 2 и честное «повтор безопасен»"
else
    fail "сбой POST при резолве обработан не так (rc=$RC): $(stderr | tail -2)"
fi

write_thread_fixture false
export STUB_FAIL_GET_AFTER_WRITE=1
RC=$(run_sub comment-resolve "$PAGE" "$THREAD")
unset STUB_FAIL_GET_AFTER_WRITE
if [ "$RC" -eq 2 ] && stderr | grep -q 'проверить результат не удалось'; then
    ok "сбой проверочного чтения при резолве — код 2"
else
    fail "сбой проверочного чтения при резолве (rc=$RC): $(stderr | tail -2)"
fi

write_thread_fixture false
export STUB_INBAND_ERROR=1
RC=$(run_sub comment-resolve "$PAGE" "$THREAD")
unset STUB_INBAND_ERROR
if [ "$RC" -eq 2 ] && stderr | grep -q 'не подтвердило запись'; then
    ok "конверт ошибки на проверке резолва — код 2"
else
    fail "конверт ошибки на проверке резолва (rc=$RC): $(stderr | tail -2)"
fi

write_thread_fixture false
export STUB_IGNORE_WRITES=1
RC=$(run_sub comment-resolve "$PAGE" "$THREAD")
unset STUB_IGNORE_WRITES
if [ "$RC" -eq 1 ] && stderr | grep -q 'не применилась'; then
    ok "неприменившийся резолв — код 1 и «повтор безопасен»"
else
    fail "неприменившийся резолв принят за успех (rc=$RC): $(stderr | tail -2)"
fi

# ---- comment-reply ------------------------------------------------------------

write_thread_fixture false
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ в тред')
NEW=$(stdout | sed -n 's/^comment: //p')
ERR_ID=$(stderr | sed -n 's/^comment: //p' | head -1)
RB_ERR=$(stderr | sed -n 's/^Откат: //p')
if [ "$RC" -eq 0 ] && [ -n "$NEW" ] && [ "$NEW" = "$ERR_ID" ] && [ "$(stdout | wc -l | tr -d ' ')" -eq 2 ] \
   && [ -n "$RB_ERR" ] && [ "$(stdout | sed -n 2p)" = "rollback: $RB_ERR" ] \
   && [ "$(thread_comments)" = "$FIRST $NEW" ] && [ "$(posts)" -eq 1 ]; then
    ok "comment-reply дописывает ответ в конец треда, id и путь к откату — в stdout, id заранее в stderr"
else
    fail "comment-reply (rc=$RC, тред=$(thread_comments)): $(stderr | tail -2)"
fi
if [ "$(message_field "$NEW" text)" = '[{"text": "ответ в тред", "type": 0, "enhancer": {}}]' ]; then
    ok "текст ответа лёг одним сегментом"
else
    fail "текст ответа: $(message_field "$NEW" text)"
fi

printf -- '-- не согласен' > "$TMP/reply.txt"
write_thread_fixture false
RC=$(run_sub comment-reply "$PAGE" "$THREAD" "@$TMP/reply.txt")
NEW=$(stdout | sed -n 's/^comment: //p')
if [ "$RC" -eq 0 ] && [ "$(message_field "$NEW" text)" = '[{"text": "-- не согласен", "type": 0, "enhancer": {}}]' ]; then
    ok "текст ответа из @файла доходит, в том числе с ведущими дефисами"
else
    fail "ответ из @файла (rc=$RC): $(stderr | tail -2)"
fi

RB="$TMP/reply-dry-rollback.json"
printf 'прежний откат' > "$RB"
write_thread_fixture false
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ' --dry-run "--rollback-out=$RB")
if [ "$RC" -eq 0 ] && ! sent && [ "$(cat "$RB")" = "прежний откат" ] && stdout | grep -q '"listAfter"'; then
    ok "ответ с --dry-run печатает операции, ничего не отправляет и не трогает файл отката"
else
    fail "ответ с --dry-run (rc=$RC, отправил=$(sent && echo да || echo нет))"
fi

RB="$TMP/reply-rollback.json"
write_thread_fixture false
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ' "--rollback-out=$RB")
NEW=$(stdout | sed -n 's/^comment: //p')
/bin/bash "$TMP/scripts/buildin.sh" POST /api/records/transactions "$(cat "$RB")" > /dev/null 2>&1
if [ "$RC" -eq 0 ] && [ "$(thread_comments)" = "$FIRST" ] && [ "$(message_field "$NEW" status)" = "-1" ]; then
    ok "проигранный откат ответа убирает его из треда и гасит"
else
    fail "откат ответа (rc=$RC, тред=$(thread_comments), status=$(message_field "$NEW" status))"
fi

write_thread_fixture true
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ')
if [ "$RC" -eq 1 ] && ! sent && stderr | grep -q 'comment-unresolve'; then
    ok "ответ в закрытый тред отвергнут с подсказкой открыть его"
else
    fail "ответ в закрытый тред не отвергнут (rc=$RC): $(stderr | head -2)"
fi

write_fixture
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ')
if [ "$RC" -eq 1 ] && ! sent && stderr | grep -q 'на странице нет'; then
    ok "ответ в тред не с этой страницы — отказ без записи"
else
    fail "ответ в отсутствующий тред не отвергнут (rc=$RC)"
fi

write_thread_fixture false
RC=$(run_sub comment-reply "$PAGE" "$THREAD" "@$TMP/empty.txt")
if [ "$RC" -eq 1 ] && ! sent && stderr | grep -q 'текст ответа пустой'; then
    ok "пустой файл как текст ответа отвергнут"
else
    fail "пустой текст ответа не отвергнут (rc=$RC)"
fi

RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ' --occurrence=2)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'неизвестный флаг: --occurrence=2'; then
    ok "флаг, которого у ответа нет, отвергнут"
else
    fail "ответ принял --occurrence (rc=$RC)"
fi

RC=$(run_sub comment-reply "$PAGE" "не-uuid" 'ответ')
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'не UUID'; then
    ok "кривой id треда в ответе отвергнут"
else
    fail "кривой id треда в ответе не отвергнут (rc=$RC)"
fi

RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ' 'лишний')
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'ожидались ровно <discussion_id> и <text>'; then
    ok "лишний позиционный аргумент ответа отвергнут"
else
    fail "лишний аргумент ответа не отвергнут (rc=$RC)"
fi

RC=$(run_sub comment-reply)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'Usage: comment-reply'; then
    ok "comment-reply без аргументов печатает справку"
else
    fail "comment-reply без аргументов (rc=$RC): $(stderr | head -1)"
fi

write_thread_fixture false
export STUB_FAIL_POST=1
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ')
unset STUB_FAIL_POST
if [ "$RC" -eq 2 ] && stderr | grep -q 'исход записи неизвестен (comment: ' && stderr | grep -q 'вслепую'; then
    ok "сбой POST при ответе называет id ответа и запрещает слепой повтор"
else
    fail "сбой POST при ответе (rc=$RC): $(stderr | tail -2)"
fi

write_thread_fixture false
export STUB_FAIL_GET_AFTER_WRITE=1
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ')
unset STUB_FAIL_GET_AFTER_WRITE
if [ "$RC" -eq 2 ] && stderr | grep -q 'проверить результат не удалось'; then
    ok "сбой проверочного чтения при ответе — код 2"
else
    fail "сбой проверочного чтения при ответе (rc=$RC): $(stderr | tail -2)"
fi

write_thread_fixture false
export STUB_INBAND_ERROR=1
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ')
unset STUB_INBAND_ERROR
if [ "$RC" -eq 2 ] && stderr | grep -q 'не подтвердило запись'; then
    ok "конверт ошибки на проверке ответа — код 2"
else
    fail "конверт ошибки на проверке ответа (rc=$RC): $(stderr | tail -2)"
fi

write_thread_fixture false
export STUB_IGNORE_WRITES=1
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ')
unset STUB_IGNORE_WRITES
if [ "$RC" -eq 1 ] && stderr | grep -q 'не применилась' && stderr | grep -q 'повтор безопасен'; then
    ok "неприменившийся ответ — код 1 и «повтор безопасен»"
else
    fail "неприменившийся ответ принят за успех (rc=$RC): $(stderr | tail -2)"
fi

# ---- comment-rollback ---------------------------------------------------------
RB="$TMP/rb-apply.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
RC2=$(run_sub comment-rollback "$RB")
ST=$(block_state)
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ ! -e "$RB" ] && [ -s "$RB.applied" ] \
   && [ "$(stdout)" = "status: applied
rollback: $RB.applied" ] \
   && echo "$ST" | python3 -c "
import json, sys
st = json.load(sys.stdin)
assert st['listed'] == [] and st['lit'] == [] and st['n'] == 3, st
" 2>/dev/null; then
    ok "comment-rollback вернул блок к снапшоту и переименовал файл в .applied"
else
    fail "comment-rollback (rc=$RC2, файлы: $(ls "$RB"* 2>/dev/null | tr '\n' ' ')): $(stderr | tail -2) $ST"
fi

RC=$(run_sub comment-rollback "$RB")
if [ "$RC" -eq 1 ] && ! sent && stderr | grep -q 'Он уже применён'; then
    ok "повтор отката по прежнему пути отвергнут с указанием на .applied"
else
    fail "повтор отката не отвергнут (rc=$RC): $(stderr | head -2)"
fi

RC=$(run_sub comment-rollback "$RB.applied")
if [ "$RC" -eq 1 ] && ! sent && stderr | grep -q 'суффикс .applied'; then
    ok "файл .applied второй раз не применяется"
else
    fail "файл .applied применён повторно (rc=$RC)"
fi

printf '%s' '{"requestId":"r","transactions":[{"id":"t","spaceId":"'"$SPACE"'","operations":[{"id":"'"$BLOCK"'","command":"set","table":"block","path":[],"args":{}}]}]}' > "$TMP/rb-foreign.json"
RC=$(run_sub comment-rollback "$TMP/rb-foreign.json")
if [ "$RC" -eq 1 ] && ! sent && [ -e "$TMP/rb-foreign.json" ] && stderr | grep -q 'файл отката отвергнут'; then
    ok "чужая транзакция в файле отката отвергнута, файл не тронут"
else
    fail "чужая транзакция в файле отката не отвергнута (rc=$RC): $(stderr | head -2)"
fi

printf 'не json' > "$TMP/rb-garbage.json"
RC=$(run_sub comment-rollback "$TMP/rb-garbage.json")
if [ "$RC" -eq 1 ] && ! sent && stderr | grep -q 'файл отката отвергнут'; then
    ok "не-JSON вместо файла отката отвергнут"
else
    fail "не-JSON вместо файла отката не отвергнут (rc=$RC)"
fi

RC=$(run_sub comment-rollback "$TMP/rb-garbage.json" лишний)
if [ "$RC" -eq 1 ] && ! sent && stderr | grep -q 'Usage: comment-rollback'; then
    ok "comment-rollback с лишним аргументом — справка без записи"
else
    fail "comment-rollback принял лишний аргумент (rc=$RC)"
fi

RB="$TMP/rb-fail.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
export STUB_FAIL_POST=1
RC2=$(run_sub comment-rollback "$RB")
unset STUB_FAIL_POST
if [ "$RC2" -eq 2 ] && [ -e "$RB" ] && [ ! -e "$RB.applied" ] && stderr | grep -q 'не переименован'; then
    ok "сбой POST при откате — код 2, файл остаётся на месте"
else
    fail "сбой POST при откате (rc=$RC2, файлы: $(ls "$RB"* 2>/dev/null | tr '\n' ' '))"
fi

# В сеть уходит тело, собранное заново: из файла берутся только проверенные
# операции и spaceId, а свои ключи, id транзакции и check файла остаются за бортом.
RB="$TMP/rb-rebuilt.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
python3 -c "
import json
b = json.load(open('$RB'))
b['requestId'] = 'file-request'; b['extra'] = 1
b['transactions'][0].update(id='file-tx', extra=1)
json.dump(b, open('$RB', 'w'))"
RC2=$(run_sub comment-rollback "$RB")
if [ "$RC2" -eq 0 ] && python3 -c "
import json
b = json.load(open('$TMP/log/tx-body.json'))
assert set(b) == {'requestId', 'transactions'} and b['requestId'] != 'file-request', b
tx = b['transactions'][0]
assert set(tx) == {'id', 'spaceId', 'operations'} and tx['id'] != 'file-tx', tx
" 2>/dev/null; then
    ok "откат шлёт тело, собранное заново: без check и чужих ключей файла"
else
    fail "тело отката взято из файла (rc=$RC2): $(head -c 300 "$TMP/log/tx-body.json")"
fi

# Два комментария в один блок откатываются в обратном порядке, оба полным
# откатом: откат второго возвращает блок ровно к тому, что записал первый.
RB_A="$TMP/rb-order-a.json"; RB_B="$TMP/rb-order-b.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'первый' "--rollback-out=$RB_A")
RC2=$(SKIP_RESET=1 run_comment "$PAGE" "$BLOCK" 'безлимитный' 'второй' "--rollback-out=$RB_B")
RC3=$(run_sub comment-rollback "$RB_B")
RC4=$(run_sub comment-rollback "$RB_A")
ST=$(block_state)
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$RC3" -eq 0 ] && [ "$RC4" -eq 0 ] \
   && [ -e "$RB_A.applied" ] && [ -e "$RB_B.applied" ] && echo "$ST" | python3 -c "
import json, sys
st = json.load(sys.stdin)
assert st['listed'] == [] and st['lit'] == [] and st['n'] == 3, st
assert st['text'] == 'безлимитный тариф: лимит 100 запросов в минуту', st
" 2>/dev/null; then
    ok "B, затем A — оба полным откатом, блок вернулся к исходному"
else
    fail "откат в обратном порядке (rc=$RC3/$RC4): $ST $(stderr | head -2)"
fi

# Проверка после записи упала — запись уже ушла, поэтому код 2, а не 1:
# код 1 («не легло, повтор безопасен») при повторе задвоил бы ответ и тред.
# Два тела: не объект ([]) и объект, на котором разбор страницы падает.
for BODY in '[]' '{"code":200,"data":["x"]}'; do
    write_thread_fixture false
    RC=$(STUB_AFTER_WRITE_BODY="$BODY" run_sub comment-reply "$PAGE" "$THREAD" 'ответ')
    RC2=$(STUB_AFTER_WRITE_BODY="$BODY" run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
    RB="$TMP/rb-verdict-crash.json"
    RC3=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
    RC4=$(STUB_AFTER_WRITE_BODY="$BODY" run_sub comment-rollback "$RB")
    if [ "$RC" -eq 2 ] && [ "$RC2" -eq 2 ] && [ "$RC4" -eq 2 ] && [ -e "$RB" ] && ! stderr | grep -q Traceback; then
        ok "проверка после записи упала ($BODY) — код 2 у ответа, комментария и отката"
    else
        fail "сбой проверки после записи ($BODY): ответ rc=$RC, комментарий rc=$RC2, откат rc=$RC4"
    fi
done

# Упал сам вердикт, а не разбор страницы: запись уже ушла, поэтому тоже код 2.
# Модуль подменён обёрткой, которая роняет только режимы вердикта.
mv "$TMP/scripts/buildin-comment.py" "$TMP/scripts/buildin-comment-real.py"
cat > "$TMP/scripts/buildin-comment.py" <<CRASH
import os, sys
if any(a in ("--verdict", "--reply-verdict", "--rollback-verdict") or a.startswith("--resolve-verdict")
       for a in sys.argv[1:]):
    sys.exit(1)
os.execv(sys.executable, [sys.executable, "$TMP/scripts/buildin-comment-real.py"] + sys.argv[1:])
CRASH
write_thread_fixture false
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ')
write_thread_fixture false
RC2=$(run_sub comment-resolve "$PAGE" "$THREAD")
RC3=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
mv "$TMP/scripts/buildin-comment-real.py" "$TMP/scripts/buildin-comment.py"
if [ "$RC" -eq 2 ] && [ "$RC2" -eq 2 ] && [ "$RC3" -eq 2 ]; then
    ok "вердикт упал после записи — код 2 у ответа, резолва и комментария"
else
    fail "упавший вердикт после записи: ответ rc=$RC, резолв rc=$RC2, комментарий rc=$RC3"
fi

# Откат треда — в два шага: сначала тред закрывается (закрытый /api/docs ещё
# отдаёт, погашенный — уже нет), страница перечитывается, и только потом
# тред гасится. Ответ коллеги, пришедший в окне перед откатом, так виден:
# тред открывается обратно, откат отказывает, ничего не потеряно.
RB="$TMP/rb-window.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
D=$(stdout | sed -n 's/^discussion: //p')
RC2=$(STUB_REPLY_ON_RESOLVE=99999999-0000-4000-8000-0000000000ee run_sub comment-rollback "$RB")
ST=$(block_state)
if [ "$RC2" -eq 1 ] && [ -e "$RB" ] && [ ! -e "$RB.applied" ] && [ "$(posts)" -eq 2 ] \
   && stderr | grep -q 'чужие сообщения' && stderr | grep -q 'снова открыт' \
   && python3 -c "
import json, sys
s = json.load(open('$TMP/state.json'))['data']
t = s['discussions']['$D']
assert t.get('resolved') is False and t.get('status') != -1, t
st = json.loads(sys.argv[1])
assert '$D' in st['listed'] and '$D' in st['lit'], st
" "$ST" 2>/dev/null; then
    ok "ответ коллеги в окне перед откатом — тред открыт обратно, откат не применён"
else
    fail "ответ в окне перед откатом (rc=$RC2, POST=$(posts)): $(stderr | tail -3) $ST"
fi

RB="$TMP/rb-two-steps.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
RC2=$(run_sub comment-rollback "$RB")
FIRST_TX=$(python3 -c "
import json, sys
dec = json.JSONDecoder(); raw = open('$TMP/log/tx-all.json').read(); i = 0; out = []
while i < len(raw):
    obj, i = dec.raw_decode(raw, i)
    out.append([(o['table'], o['command'], sorted(o['args'])) for o in obj['transactions'][0]['operations']])
print(json.dumps(out[0]))")
if [ "$RC2" -eq 0 ] && [ "$(posts)" -eq 2 ] && [ "$FIRST_TX" = '[["discussion", "update", ["resolved"]]]' ]; then
    ok "откат треда: сначала закрытие треда, потом сам откат — две записи"
else
    fail "два шага отката треда (rc=$RC2, POST=$(posts)): первая запись $FIRST_TX"
fi

write_thread_fixture false
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ' "--rollback-out=$TMP/rb-reply-one-step.json")
RC2=$(run_sub comment-rollback "$TMP/rb-reply-one-step.json")
if [ "$RC2" -eq 0 ] && [ "$(posts)" -eq 1 ]; then
    ok "откат ответа — одна запись: тред он не гасит, закрывать нечего"
else
    fail "откат ответа (rc=$RC2, POST=$(posts))"
fi

# Проверка после отката: в .applied файл уходит только тогда, когда откат
# виден на странице. Иначе неприменившийся откат было бы уже не повторить.
RB="$TMP/rb-ignored.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
export STUB_IGNORE_WRITES=1
RC2=$(run_sub comment-rollback "$RB")
unset STUB_IGNORE_WRITES
if [ "$RC2" -eq 1 ] && sent && [ -e "$RB" ] && [ ! -e "$RB.applied" ] \
   && stderr | grep -q 'не применилась' && stderr | grep -q 'повтор безопасен' && ! stdout | grep -q 'applied'; then
    ok "откат не лёг — код 1, файл на месте, повтор безопасен"
else
    fail "неприменившийся откат (rc=$RC2, файлы: $(ls "$RB"* 2>/dev/null | tr '\n' ' ')): $(stderr | tail -2)"
fi

for KNOB in STUB_FAIL_GET_AFTER_WRITE STUB_INBAND_ERROR; do
    RB="$TMP/rb-unread-$KNOB.json"
    RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
    export "$KNOB=1"
    RC2=$(run_sub comment-rollback "$RB")
    unset "$KNOB"
    if [ "$RC2" -eq 2 ] && sent && [ -e "$RB" ] && [ ! -e "$RB.applied" ] && stderr | grep -q 'не переименован'; then
        ok "откат отправлен, а проверить нельзя ($KNOB) — код 2, файл на месте"
    else
        fail "непроверенный откат ($KNOB, rc=$RC2, файлы: $(ls "$RB"* 2>/dev/null | tr '\n' ' ')): $(stderr | tail -2)"
    fi
done

# Каталог только на чтение: файл не переименовать, но откат уже ушёл — команда
# обязана предупредить, а не упасть молча. Под root права каталога не мешают
# переименованию, поэтому там проверка не имеет смысла.
if [ "$(id -u)" -ne 0 ]; then
    mkdir -p "$TMP/ro"
    RB="$TMP/ro/rb.json"
    RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
    chmod 555 "$TMP/ro"
    RC2=$(run_sub comment-rollback "$RB")
    chmod 755 "$TMP/ro"
    if [ "$RC2" -eq 0 ] && sent && stderr | grep -q 'переименовать' && stderr | grep -q 'Повторно его не применяйте' \
       && [ "$(stdout)" = "status: applied
rollback: $RB" ]; then
        ok "откат ушёл, а файл не переименовался — громкое предупреждение"
    else
        fail "неудачное переименование файла отката (rc=$RC2): $(stderr | tail -2)"
    fi
fi

# ---- свежесть файла отката и --narrow ----------------------------------------
RB="$TMP/rb-check.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
if [ "$RC" -eq 0 ] && python3 -c "
import json
b = json.load(open('$RB'))
segs = json.load(open('$TMP/state.json'))['data']['blocks']['$BLOCK']['data']['segments']
assert b['check']['page'] == '$PAGE' and b['check']['block'] == '$BLOCK', b['check']
assert b['check']['segments'] == segs, (b['check']['segments'], segs)
" 2>/dev/null; then
    ok "файл отката comment несёт сверку: страница, блок и сегменты после записи"
else
    fail "в файле отката нет сверки или она не та (rc=$RC)"
fi

RB="$TMP/rb-stale.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'первый' "--rollback-out=$RB")
FIRST_D=$(stdout | sed -n 's/^discussion: //p')
RC2=$(SKIP_RESET=1 run_comment "$PAGE" "$BLOCK" 'безлимитный' 'второй')
SECOND_D=$(stdout | sed -n 's/^discussion: //p')
RC3=$(run_sub comment-rollback "$RB")
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$RC3" -eq 1 ] && ! sent && [ -e "$RB" ] && [ ! -e "$RB.applied" ] \
   && stderr | grep -q 'блок изменился после комментария' && stderr | grep -q -- '--narrow'; then
    ok "блок меняли после комментария — полный откат отвергнут, предложен --narrow"
else
    fail "устаревший файл отката (rc=$RC3): $(stderr | head -3)"
fi

RC=$(run_sub comment-rollback "$RB" --narrow)
ST=$(block_state)
if [ "$RC" -eq 0 ] && [ -e "$RB.applied" ] && echo "$ST" | python3 -c "
import json, sys
st = json.load(sys.stdin)
assert '$FIRST_D' not in st['listed'], st
assert '$SECOND_D' in st['listed'] and '$SECOND_D' in st['lit'], st
assert st['text'] == 'безлимитный тариф: лимит 100 запросов в минуту', st
" 2>/dev/null && python3 -c "
import json
ops = json.load(open('$TMP/log/tx-body.json'))['transactions'][0]['operations']
assert ops and not any(o.get('path') == ['data'] for o in ops), ops
" 2>/dev/null; then
    ok "--narrow снимает только свой тред: сегменты не трогает, чужая подсветка цела"
else
    fail "--narrow (rc=$RC): $ST $(stderr | head -2)"
fi

# --dry-run: те же сверки, вывод — операции, без записи и без .applied.
# Превью читаемое и при не-UTF-8 выводе: кириллица текстом, а не \uXXXX.
# Не-UTF-8 вывод — через PYTHONIOENCODING: под LC_ALL=C Python 3.7+ сам
# переключается на UTF-8, и поломка печати не воспроизвелась бы.
RB="$TMP/rb-dry.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
for MODE in full --narrow; do
    RC2=$(PYTHONIOENCODING=ascii run_sub comment-rollback "$RB" --dry-run ${MODE#full})
    if [ "$MODE" = full ] && ! stdout | grep -q 'безлимитный'; then
        fail "comment-rollback --dry-run печатает кириллицу нечитаемо: $(stdout | grep -m1 text)"
    fi
    if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && ! sent && [ -e "$RB" ] && [ ! -e "$RB.applied" ] && stdout | python3 -c "
import json, sys
ops = json.load(sys.stdin)
data = [o for o in ops if o.get('path') == ['data']]
assert ops and len(data) == (0 if '$MODE' == '--narrow' else 1), ops
" 2>/dev/null; then
        ok "comment-rollback --dry-run ($MODE) показывает операции и ничего не пишет"
    else
        fail "comment-rollback --dry-run ($MODE, rc=$RC2): $(stdout | head -3) $(stderr | head -2)"
    fi
done

RB="$TMP/rb-dry-stale.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'первый' "--rollback-out=$RB")
RC2=$(SKIP_RESET=1 run_comment "$PAGE" "$BLOCK" 'безлимитный' 'второй')
RC3=$(run_sub comment-rollback "$RB" --dry-run)
if [ "$RC3" -eq 1 ] && ! sent && [ -e "$RB" ] && [ -z "$(stdout)" ] && stderr | grep -q 'блок изменился'; then
    ok "comment-rollback --dry-run отказывает так же, как боевой прогон"
else
    fail "--dry-run пропустил устаревший файл (rc=$RC3): $(stdout | head -2)"
fi

RB="$TMP/rb-docs-fail.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
export STUB_FAIL_DOCS=1
RC2=$(run_sub comment-rollback "$RB")
unset STUB_FAIL_DOCS
if [ "$RC2" -eq 1 ] && ! sent && [ -e "$RB" ] && stderr | grep -q 'не удалось прочитать страницу'; then
    ok "страница не читается — сверить нельзя, полный откат не применён"
else
    fail "сбой чтения страницы при откате (rc=$RC2): $(stderr | head -2)"
fi

RB="$TMP/rb-unverified.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
# Блок удалили со страницы, а тред остался: сверять полный откат не с чем.
python3 -c "
import json
s = json.load(open('$TMP/state.json'))
del s['data']['blocks']['$BLOCK']
json.dump(s, open('$TMP/state.json', 'w'))"
RC2=$(run_sub comment-rollback "$RB")
if [ "$RC2" -eq 1 ] && ! sent && stderr | grep -q 'нет на странице'; then
    ok "блока из файла нет на странице — полный откат не применён"
else
    fail "блок из файла не найден, а откат применён (rc=$RC2): $(stderr | head -2)"
fi

RB="$TMP/rb-nocheck.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
python3 -c "
import json
b = json.load(open('$RB')); b.pop('check'); json.dump(b, open('$RB', 'w'))"
RC2=$(run_sub comment-rollback "$RB")
if [ "$RC2" -eq 1 ] && ! sent && [ -e "$RB" ] && stderr | grep -q 'без сверки'; then
    ok "файл без сверки сегменты не возвращает: проверить в нём нечего"
else
    fail "файл без сверки применён (rc=$RC2): $(stderr | head -2)"
fi

# В тред, который откатываем, успел ответить другой человек: откат погасил
# бы и его ответ. Отказ с подсказкой закрыть тред — и для полного, и для --narrow.
RB="$TMP/rb-foreign-reply.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
D=$(stdout | sed -n 's/^discussion: //p')
python3 -c "
import json
s = json.load(open('$TMP/state.json'))
s['data']['discussions']['$D']['comments'].append('$OTHER')
s['data']['comments']['$OTHER'] = {'uuid': '$OTHER', 'createdBy': '$OTHER', 'status': 1}
json.dump(s, open('$TMP/state.json', 'w'))"
for MODE in full --narrow; do
    RC2=$(run_sub comment-rollback "$RB" ${MODE#full})
    if [ "$RC" -eq 0 ] && [ "$RC2" -eq 1 ] && ! sent && [ -e "$RB" ] \
       && stderr | grep -q 'чужие сообщения' && stderr | grep -q "comment-resolve $PAGE $D"; then
        ok "в треде чужой ответ — откат ($MODE) не применён, предложен comment-resolve"
    else
        fail "откат треда с чужим ответом ($MODE, rc=$RC2): $(stderr | head -3)"
    fi
done

# Свой ответ в свой тред — сценарий с живой страницы: отказ ведёт к откату
# ответа его файлом, а после него тред откатывается целиком.
RB="$TMP/rb-own-thread.json"; RB_R="$TMP/rb-own-reply.json"
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
D=$(stdout | sed -n 's/^discussion: //p')
RC2=$(run_sub comment-reply "$PAGE" "$D" 'свой ответ' "--rollback-out=$RB_R")
RC3=$(run_sub comment-rollback "$RB")
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$RC3" -eq 1 ] && ! sent && [ -e "$RB" ] \
   && stderr | grep -q 'ваши ответы' && stderr | grep -q 'rollback:'; then
    ok "в треде свой ответ — отказ с подсказкой откатить сначала ответ"
else
    fail "откат треда со своим ответом (rc=$RC3): $(stderr | head -3)"
fi
RC4=$(run_sub comment-rollback "$RB_R")
RC5=$(run_sub comment-rollback "$RB")
ST=$(block_state)
if [ "$RC4" -eq 0 ] && [ "$RC5" -eq 0 ] && echo "$ST" | python3 -c "
import json, sys
st = json.load(sys.stdin)
assert st['listed'] == [] and st['lit'] == [] and st['n'] == 3, st
" 2>/dev/null; then
    ok "ответ откатан своим файлом — после него тред откатывается целиком"
else
    fail "откат ответа, потом треда (rc=$RC4/$RC5): $ST $(stderr | head -2)"
fi

RB="$TMP/rb-reply-apply.json"
write_thread_fixture false
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ' "--rollback-out=$RB")
NEW=$(stdout | sed -n 's/^comment: //p')
RC2=$(run_sub comment-rollback "$RB")
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$(thread_comments)" = "$FIRST" ] && [ "$(message_field "$NEW" status)" = "-1" ]; then
    ok "comment-rollback откатывает и ответ в тред"
else
    fail "откат ответа через comment-rollback (rc=$RC2, тред=$(thread_comments))"
fi

# ---- @-упоминания -------------------------------------------------------------

RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--mention=$OTHER")
if [ "$RC" -eq 0 ] && [ "$(sent_text)" = "$OTHER |  текст" ]; then
    ok "--mention ставит упоминание в начало комментария"
else
    fail "--mention в comment (rc=$RC, текст=$(sent_text)): $(stderr | tail -2)"
fi

RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' --mention "$OTHER")
if [ "$RC" -eq 0 ] && [ "$(sent_text)" = "$OTHER |  текст" ]; then
    ok "пробельная форма --mention <uuid> принята"
else
    fail "пробельная форма --mention (rc=$RC): $(stderr | tail -2)"
fi

RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' --mention $EMPTY --dry-run)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'mention без значения'; then
    ok "--mention с пустым значением не съедает следующий флаг"
else
    fail "--mention съел --dry-run (rc=$RC)"
fi

RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' --mention=)
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'mention без значения'; then
    ok "--mention= без uuid отвергнут"
else
    fail "--mention= без uuid не отвергнут (rc=$RC)"
fi

RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' --mention=88888888-8888-4888-8888-888888888888)
if [ "$RC" -eq 1 ] && ! sent && stderr | grep -q 'среди участников пространства нет'; then
    ok "упоминание не участника пространства отвергнуто без записи"
else
    fail "упоминание не участника не отвергнуто (rc=$RC): $(stderr | tail -2)"
fi

export STUB_FAIL_MEMBERS=1
RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--mention=$OTHER")
unset STUB_FAIL_MEMBERS
if [ "$RC" -eq 1 ] && ! sent && stderr | grep -q 'не удалось получить участников'; then
    ok "без списка участников упоминание не проверить — запись отменена"
else
    fail "сбой списка участников проглочен (rc=$RC): $(stderr | tail -2)"
fi

RC=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст')
if [ "$RC" -eq 0 ] && ! grep -q '/members' "$TMP/log/calls.txt"; then
    ok "без --mention участников не спрашиваем"
else
    fail "участники запрошены без --mention (rc=$RC)"
fi

RC=$(run_comment "$PAGE" "$OTHER" 'в минуту' 'текст' "--mention=$OTHER")
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'не найден на странице' && ! stderr | grep -q 'участник'; then
    ok "блока нет на странице — отказ про блок, а не про участников"
else
    fail "отказ при отсутствующем блоке с --mention (rc=$RC): $(stderr | tail -2)"
fi

write_thread_fixture false
RC=$(run_sub comment-reply "$PAGE" "$THREAD" 'ответ' "--mention=$OTHER")
if [ "$RC" -eq 0 ] && [ "$(sent_text)" = "$OTHER |  ответ" ]; then
    ok "--mention работает и в ответе"
else
    fail "--mention в comment-reply (rc=$RC, текст=$(sent_text)): $(stderr | tail -2)"
fi

# Читатель comments ставит пробел после упоминания сам. Текст нашего ответа уже
# начинается с пробела, и раньше выходило «@j.doe  ответ» с двойным пробелом.
RC=$(run_cmd comments "$PAGE")
if [ "$RC" -eq 0 ] && stdout | grep -q '@j.doe ответ' && ! stdout | grep -q '@j.doe  '; then
    ok "comments печатает упоминание без двойного пробела"
else
    fail "comments и упоминание (rc=$RC): $(stdout | grep '@' | head -2)"
fi

# Все формы упоминания в одном треде — с точным выводом: проверка «нет двойного
# пробела» пропустила бы и склейку «@j.doeпосмотри», и лишний пробел в конце.
python3 - "$TMP/state.json" "$BLOCK" "$THREAD" "$SPACE" "$OTHER" <<'FIX'
import json, sys
path, block, thread, space, other = sys.argv[1:6]
mention = lambda uid: {"text": "", "type": 7, "uuid": uid, "enhancer": {}}
text = lambda t: {"text": t, "type": 0, "enhancer": {}}
bodies = [[mention(other), text("посмотри")], [mention(other), text(" ответ")], [mention(other)],
          [mention(other), text(" "), mention("user-1"), text(" текст")]]
ids = ["99999999-0000-4000-8000-00000000000%d" % i for i in range(len(bodies))]
state = {"code": 200, "data": {
    "blocks": {block: {"uuid": block, "spaceId": space, "type": 1, "discussions": [thread],
                       "data": {"segments": [text("абзац")]}}},
    "discussions": {thread: {"uuid": thread, "spaceId": space, "parentId": block, "status": 1,
                             "resolved": False, "comments": ids}},
    "comments": {cid: {"uuid": cid, "spaceId": space, "parentId": thread, "status": 1,
                       "createdBy": "user-1", "text": body} for cid, body in zip(ids, bodies)}}}
json.dump(state, open(path, "w"), ensure_ascii=False)
FIX
RC=$(run_cmd comments "$PAGE")
GOT=$(stdout | sed -n 's/^- agent (?): //p')
if [ "$RC" -eq 0 ] && [ "$GOT" = "@j.doe посмотри
@j.doe ответ
@j.doe
@j.doe @agent текст" ]; then
    ok "comments: все формы упоминания — с точным выводом"
else
    fail "comments и формы упоминания (rc=$RC): $GOT"
fi

# Упоминание страницы — сегмент type 4 с одним uuid. Название берётся из
# /api/docs, если страница там есть (так приходят родители), иначе одним
# запросом /api/blocks на страницу. Нет страницы — ссылка. Не-UUID из чужого
# текста в запрос не уходит.
PARENT=66666666-0000-4000-8000-000000000001
MISSING=66666666-0000-4000-8000-000000000002
python3 - "$TMP/state.json" "$BLOCK" "$THREAD" "$SPACE" "$MENTIONED" "$PARENT" "$MISSING" <<'FIX'
import json, sys
path, block, thread, space, mentioned, parent, missing = sys.argv[1:8]
page = lambda uid: {"text": "", "type": 4, "uuid": uid, "enhancer": {}}
text = lambda t: {"text": t, "type": 0, "enhancer": {}}
body = [text("см. "), page(mentioned), text(", "), page(parent), text(", "), page(missing),
        text(", снова "), page(mentioned), text(" и "), page("../spaces/x")]
cid = "99999999-0000-4000-8000-000000000009"
state = {"code": 200, "data": {
    "blocks": {block: {"uuid": block, "spaceId": space, "type": 1, "discussions": [thread],
                       "data": {"segments": [text("абзац")]}},
               parent: {"uuid": parent, "spaceId": space, "type": 0, "title": "Родитель"}},
    "discussions": {thread: {"uuid": thread, "spaceId": space, "parentId": block, "status": 1,
                             "resolved": False, "comments": [cid]}},
    "comments": {cid: {"uuid": cid, "spaceId": space, "parentId": thread, "status": 1,
                       "createdBy": "user-1", "text": body}}}}
json.dump(state, open(path, "w"), ensure_ascii=False)
FIX
RC=$(run_sub comments "$PAGE")
GOT=$(stdout | sed -n 's/^- agent (?): //p')
WANT="см. [Страница B](https://buildin.ai/$SPACE/$MENTIONED), [Родитель](https://buildin.ai/$SPACE/$PARENT), https://buildin.ai/$SPACE/$MISSING, снова [Страница B](https://buildin.ai/$SPACE/$MENTIONED) и (упоминание страницы)"
BLOCK_GETS=$(grep -c "^GET /api/blocks/" "$TMP/log/calls.txt" || true)
if [ "$RC" -eq 0 ] && [ "$GOT" = "$WANT" ] && [ "$BLOCK_GETS" -eq 2 ] \
   && grep -q "^GET /api/blocks/$MENTIONED$" "$TMP/log/calls.txt" && grep -q "^GET /api/blocks/$MISSING$" "$TMP/log/calls.txt"; then
    ok "comments: упоминание страницы — название, при сбое ссылка, по запросу на страницу"
else
    fail "comments и упоминание страницы (rc=$RC, запросов /api/blocks=$BLOCK_GETS): $GOT"
fi

# read и comments печатают инлайн-сегменты одним модулем: дату — датой, а не
# заглушкой «‣», упоминания — @ником и ссылкой. Участник без ника — коротким
# id: почта в контекст агента не попадает.
python3 - "$TMP/state.json" "$PAGE" "$BLOCK" "$THREAD" "$SPACE" "$OTHER" "$NONICK" "$MENTIONED" <<'FIX'
import json, sys
path, page, block, thread, space, other, nonick, mentioned = sys.argv[1:9]
text = lambda t: {"text": t, "type": 0, "enhancer": {}}
person = lambda uid: {"text": "", "type": 7, "uuid": uid, "enhancer": {}}
segs = [text("Дата: "),
        {"text": "‣", "type": 1, "startDate": "2026/10/16", "startTime": "14:30", "endDate": "", "dateFormat": "relative"},
        text(", кто: "), person(other), text(", без ника: "), person(nonick),
        text(", страница: "), {"text": "", "type": 4, "uuid": mentioned, "enhancer": {}},
        text(", "), {"text": "жирно", "type": 0, "enhancer": {"bold": True}}]
cid = "99999999-0000-4000-8000-00000000000a"
state = {"code": 200, "data": {
    "blocks": {page: {"uuid": page, "spaceId": space, "type": 0, "title": "Страница", "subNodes": [block]},
               block: {"uuid": block, "spaceId": space, "type": 1, "discussions": [thread], "data": {"segments": segs}}},
    "discussions": {thread: {"uuid": thread, "spaceId": space, "parentId": block, "status": 1,
                             "resolved": False, "comments": [cid]}},
    "comments": {cid: {"uuid": cid, "spaceId": space, "parentId": thread, "status": 1,
                       "createdBy": nonick, "text": [person(nonick), text("посмотри")]}}}}
json.dump(state, open(path, "w"), ensure_ascii=False)
FIX
LINE="Дата: 2026-10-16 14:30, кто: @j.doe, без ника: @77777777, страница: [Страница B](https://buildin.ai/$SPACE/$MENTIONED)"
RC=$(run_sub read "$PAGE")
if [ "$RC" -eq 0 ] && stdout | grep -qxF "$LINE, **жирно**" && ! stdout | grep -q 'example.com'; then
    ok "read: дата, упоминания человека и страницы, без ника — короткий id"
else
    fail "read и инлайн-сегменты (rc=$RC): $(stdout | sed -n 3p) $(stderr | tail -2)"
fi
RC=$(run_sub comments "$PAGE")
if [ "$RC" -eq 0 ] && stdout | grep -qxF "Текст блока: $LINE, жирно" && stdout | grep -qxF -- "- 77777777 (?): @77777777 посмотри" \
   && ! stdout | grep -q 'example.com'; then
    ok "comments: те же сегменты тем же модулем, автор без ника — короткий id"
else
    fail "comments и инлайн-сегменты (rc=$RC): $(stdout | head -6) $(stderr | tail -2)"
fi

write_thread_fixture false
RC=$(run_sub comment-resolve "$PAGE" "$THREAD" "--mention=$OTHER")
if [ "$RC" -ne 0 ] && ! sent && stderr | grep -q 'неизвестный флаг: --mention'; then
    ok "у резолва --mention нет — флаг отвергнут"
else
    fail "резолв принял --mention (rc=$RC)"
fi


# ---- members -----------------------------------------------------------------
write_fixture
for FORM in "$PAGE" "https://buildin.ai/$SPACE/$PAGE"; do
    RC=$(run_sub members "$FORM")
    if [ "$RC" -eq 0 ] && ! sent && [ "$(stdout)" = "$NONICK
user-1  agent
$OTHER  j.doe" ] && ! stdout | grep -q '@'; then
        ok "members ($FORM): uuid и ник участников, без почт"
    else
        fail "members ($FORM, rc=$RC): $(stdout | head -3) $(stderr | head -2)"
    fi
done

for KNOB in STUB_FAIL_MEMBERS STUB_MEMBERS_ENVELOPE; do
    export "$KNOB=1"
    RC=$(run_sub members "$PAGE")
    unset "$KNOB"
    if [ "$RC" -ne 0 ] && [ -z "$(stdout)" ] && { [ "$KNOB" = STUB_FAIL_MEMBERS ] || stderr | grep -q 'не получен'; }; then
        ok "members: список участников не получен ($KNOB) — ошибка, а не пустой список"
    else
        fail "members при недоступном списке ($KNOB, rc=$RC): $(stdout | head -2) $(stderr | tail -2)"
    fi
done

printf '%s' '{"code":200,"data":{"blocks":{}}}' > "$TMP/state.json"
RC=$(run_sub members "$PAGE")
if [ "$RC" -eq 1 ] && stderr | grep -q 'пространство не определить'; then
    ok "members: в ответе на страницу нет блоков — понятная ошибка"
else
    fail "members без блоков на странице (rc=$RC): $(stderr | tail -2)"
fi

RC=$(run_sub members "$PAGE" лишний)
if [ "$RC" -eq 1 ] && stderr | grep -q 'Usage: members'; then
    ok "members с лишним аргументом — справка"
else
    fail "members принял лишний аргумент (rc=$RC)"
fi


# ---- справка -----------------------------------------------------------------
# Справка обязана называть каждую команду скрипта: новые команды в неё уже
# забывали добавить, и агент о них не узнавал.
RC=$(run_cmd help)
MISSING=""
for C in $(sed -n 's/^    \([a-z|-]*\))$/\1/p' "$SRC_DIR/buildin-comments.sh" | tr '|' ' '); do
    case "$C" in commands|help) continue ;; esac
    stdout | grep -q "^  $C " || MISSING="$MISSING $C"
done
if [ "$RC" -eq 0 ] && [ -z "$MISSING" ] && stdout | grep -q '^  members '; then
    ok "справка buildin-pages.sh называет все команды комментариев"
else
    fail "в справке нет команд:$MISSING (rc=$RC)"
fi


# ---- подсказки агенту --------------------------------------------------------
# «@имя» в тексте — естественная попытка позвать человека. Она разбирается как
# путь к файлу, и подсказка обязана вести к --mention, а не только к «@@»:
# «@@имя» даст обычный текст без уведомления.
write_thread_fixture false
RC=$(run_sub comment-reply "$PAGE" "$THREAD" '@j.doe посмотри')
if [ "$RC" -eq 1 ] && ! sent && stderr | grep -q -- '--mention' && stderr | grep -q 'members'; then
    ok "«@имя» в тексте — отказ с подсказкой про --mention и members"
else
    fail "подсказка на «@имя» (rc=$RC): $(stderr | tail -3)"
fi

# Опечатка в команде — ошибка с кодом 1, а не справка с кодом 0: по коду её не
# отличить от успеха. help остаётся с кодом 0.
RC=$(run_cmd comment-resolv "$PAGE" "$THREAD")
RC2=$(run_cmd no-such-command)
RC3=$(run_cmd help)
if [ "$RC" -eq 1 ] && [ "$RC2" -eq 1 ] && [ "$RC3" -eq 0 ]; then
    ok "неизвестная команда — код 1 и в buildin-comments.sh, и в buildin-pages.sh; help — 0"
else
    fail "неизвестная команда: comment-resolv rc=$RC, no-such-command rc=$RC2, help rc=$RC3"
fi
RC=$(run_cmd comment-resolv "$PAGE" "$THREAD")
if [ -z "$(stdout)" ] && stderr | grep -q 'неизвестная команда: comment-resolv'; then
    ok "неизвестная команда называется в stderr, stdout пуст"
else
    fail "вывод при неизвестной команде: stdout=$(stdout | head -1) stderr=$(stderr | head -1)"
fi


# ---- пользователь не определён -----------------------------------------------
# На uuid пользователя держится авторство: ответ пишется от его имени, откат
# сверяет по нему чьи записи. Нет uuid — отказ с кодом 1 и никакого POST.
for KNOB in STUB_NO_USER STUB_FAIL_USER; do
    write_thread_fixture false
    RC=$(export "$KNOB=1"; run_sub comment-reply "$PAGE" "$THREAD" 'ответ')
    P1=$(posts)
    RB="$TMP/rb-no-user-$KNOB.json"
    RC2=$(run_comment "$PAGE" "$BLOCK" 'в минуту' 'текст' "--rollback-out=$RB")
    export "$KNOB=1"
    RC3=$(run_sub comment-rollback "$RB")
    unset "$KNOB"
    if [ "$RC" -eq 1 ] && [ "$P1" -eq 0 ] && [ "$RC3" -eq 1 ] && ! sent && [ -e "$RB" ]; then
        ok "пользователь не определён ($KNOB) — ответ и откат отказывают, POST не ушёл"
    else
        fail "пользователь не определён ($KNOB): ответ rc=$RC POST=$P1, откат rc=$RC3 POST=$(posts)"
    fi
done


# ---- участники недоступны ----------------------------------------------------
# Короткий id вместо ника бывает и у участника без ника, и когда список
# участников не получен. Второй случай читатели называют прямо.
NOTE='Участники пространства недоступны: вместо ников — первые 8 символов uuid.'
write_thread_fixture false
RC=$(STUB_FAIL_MEMBERS=1 run_sub comments "$PAGE")
RC2=$(run_sub comments "$PAGE")
NOTE_OK=$(stdout | grep -cF "$NOTE" || true)
RC3=$(STUB_FAIL_MEMBERS=1 run_sub comments "$PAGE")
if [ "$RC" -eq 0 ] && [ "$RC3" -eq 0 ] && stdout | grep -qF "$NOTE" && [ "$NOTE_OK" -eq 0 ]; then
    ok "comments: список участников не получен — пометка в выводе, а с ним — без неё"
else
    fail "пометка о недоступных участниках в comments (rc=$RC/$RC3, без сбоя пометок: $NOTE_OK)"
fi
python3 - "$TMP/state.json" "$PAGE" "$BLOCK" "$SPACE" "$OTHER" <<'FIX'
import json, sys
path, page, block, space, other = sys.argv[1:6]
seg = [{"text": "кто: ", "type": 0, "enhancer": {}}, {"text": "", "type": 7, "uuid": other, "enhancer": {}}]
json.dump({"code": 200, "data": {"blocks": {
    page: {"uuid": page, "spaceId": space, "type": 0, "title": "Страница", "subNodes": [block]},
    block: {"uuid": block, "spaceId": space, "type": 1, "data": {"segments": seg}}}}}, open(path, "w"), ensure_ascii=False)
FIX
RC=$(STUB_FAIL_MEMBERS=1 run_sub read "$PAGE")
if [ "$RC" -eq 0 ] && stdout | grep -qF "$NOTE"; then
    ok "read: список участников не получен — пометка в выводе"
else
    fail "пометка о недоступных участниках в read (rc=$RC): $(stdout | tail -2)"
fi

finish
