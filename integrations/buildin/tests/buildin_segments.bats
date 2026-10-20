#!/usr/bin/env bats
# Юнит-тесты buildin_segments.py — инлайн-сегменты текстом для read и comments.
# Сеть подменена скриптом-клиентом: он отвечает по адресу и пишет журнал
# запросов, чтобы проверять не только вывод, но и сколько раз ходили в API.

setup() {
    SCRIPTS="$BATS_TEST_DIRNAME/../scripts"
    LOG="$BATS_TEST_TMPDIR/calls.txt"
    : > "$LOG"
    CLIENT="$BATS_TEST_TMPDIR/buildin.sh"
    cat > "$CLIENT" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$1" "\$2" >> "$LOG"
case "\$2" in
    /api/spaces/s1/members)
        [ -n "\${FAIL_MEMBERS:-}" ] && { echo '{"code":403,"msg":"forbidden"}'; exit 1; }
        echo '{"code":200,"data":[{"user":{"uuid":"44444444-4444-4444-4444-444444444444","nickname":"j.doe"}},{"user":{"uuid":"77777777-0000-4000-8000-0000000000aa","email":"nonick@example.com"}}]}' ;;
    /api/blocks/55555555-5555-4555-8555-555555555555)
        echo '{"code":200,"data":{"spaceId":"s2","title":"Страница B"}}' ;;
    *)
        echo '{"code":3005,"msg":"Document not found"}'; exit 1 ;;
esac
STUB
    chmod +x "$CLIENT"
}

# Текст сегментов через модуль: $1 — JSON сегментов, $2 — JSON блоков ответа
# /api/docs (по умолчанию пусто), $3 — markup (1 — markdown, как у read).
render() {
    python3 - "$SCRIPTS" "$CLIENT" "$1" "${2:-}" "${3:-}" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from buildin_segments import Inline
inline = Inline(json.loads(sys.argv[4] or "{}"), "s1", sys.argv[2])
print(inline.text(json.loads(sys.argv[3]), markup=bool(sys.argv[5])))
PY
}

calls() { grep -c "$1" "$LOG" || true; }

@test "date: day, day with time, range, and a date without fields" {
    [ "$(render '[{"text":"‣","type":1,"startDate":"2026/10/16","startTime":"","endDate":"","dateFormat":"relative"}]')" = "2026-10-16" ]
    [ "$(render '[{"text":"‣","type":1,"startDate":"2026/10/16","startTime":"14:30","endDate":"","dateFormat":"relative"}]')" = "2026-10-16 14:30" ]
    [ "$(render '[{"text":"‣","type":1,"startDate":"2026/10/16","startTime":"14:30","endDate":"2026/10/18","endTime":"09:00"}]')" = "2026-10-16 14:30 → 2026-10-18 09:00" ]
    [ "$(render '[{"text":"‣","type":1}]')" = "(дата)" ]
}

@test "person: nickname, and a short id instead of the email when there is no nickname" {
    [ "$(render '[{"text":"","type":7,"uuid":"44444444-4444-4444-4444-444444444444"},{"text":"посмотри","type":0}]')" = "@j.doe посмотри" ]
    result=$(render '[{"text":"","type":7,"uuid":"77777777-0000-4000-8000-0000000000aa"},{"text":" ответ","type":0}]')
    [ "$result" = "@77777777 ответ" ]
}

@test "person: members are asked once and only when someone is mentioned" {
    render '[{"text":"просто текст","type":0}]' > /dev/null
    [ "$(calls members)" -eq 0 ]
    render '[{"text":"","type":7,"uuid":"44444444-4444-4444-4444-444444444444"},{"text":" и ","type":0},{"text":"","type":7,"uuid":"77777777-0000-4000-8000-0000000000aa"}]' > /dev/null
    [ "$(calls members)" -eq 1 ]
}

@test "person: without the members list the mention is a short id" {
    export FAIL_MEMBERS=1
    [ "$(render '[{"text":"","type":7,"uuid":"44444444-4444-4444-4444-444444444444"}]')" = "@44444444" ]
}

# Без списка участников короткий id не отличить от участника без ника:
# модуль помнит, что список не получен, и читатели об этом пишут.
members_flag() {
    python3 - "$SCRIPTS" "$CLIENT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from buildin_segments import Inline
inline = Inline({}, "s1", sys.argv[2])
before = inline.members_unavailable
inline.name("44444444-4444-4444-4444-444444444444")
print(before, inline.members_unavailable)
PY
}

@test "person: the module remembers that the members list was not received" {
    [ "$(members_flag)" = "False False" ]
    export FAIL_MEMBERS=1
    [ "$(members_flag)" = "False True" ]
}

@test "page: title from the response, from the API, a link without access, and no request for a non-uuid" {
    blocks='{"66666666-0000-4000-8000-000000000001":{"title":"Родитель","spaceId":"s1"}}'
    segs='[{"text":"","type":4,"uuid":"66666666-0000-4000-8000-000000000001"},{"text":"|","type":0},{"text":"","type":4,"uuid":"55555555-5555-4555-8555-555555555555"},{"text":"|","type":0},{"text":"","type":4,"uuid":"66666666-0000-4000-8000-000000000002"},{"text":"|","type":0},{"text":"","type":4,"uuid":"55555555-5555-4555-8555-555555555555"},{"text":"|","type":0},{"text":"","type":4,"uuid":"../spaces/x"}]'
    result=$(render "$segs" "$blocks")
    [ "$result" = "[Родитель](https://buildin.ai/s1/66666666-0000-4000-8000-000000000001)|[Страница B](https://buildin.ai/s2/55555555-5555-4555-8555-555555555555)|https://buildin.ai/s1/66666666-0000-4000-8000-000000000002|[Страница B](https://buildin.ai/s2/55555555-5555-4555-8555-555555555555)|(упоминание страницы)" ]
    [ "$(calls /api/blocks/)" -eq 2 ]
    [ "$(calls 'spaces/x')" -eq 0 ]
}

@test "markup: code, bold, italic and links as markdown only when asked" {
    segs='[{"text":"код","type":0,"enhancer":{"code":true}},{"text":" ","type":0},{"text":"жирный","type":0,"enhancer":{"bold":true}},{"text":" ","type":0},{"text":"курсив","type":0,"enhancer":{"italic":true}},{"text":" ","type":0},{"text":"ссылка","type":3,"url":"https://example.com"}]'
    [ "$(render "$segs" '' 1)" = '`код` **жирный** *курсив* [ссылка](https://example.com)' ]
    [ "$(render "$segs")" = "код жирный курсив ссылка" ]
}
