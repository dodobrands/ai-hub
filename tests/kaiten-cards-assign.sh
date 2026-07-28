#!/usr/bin/env bash
# Регресс-гейт семантики `assign` в kaiten-cards.sh: команда обязана делать пользователя
# ОТВЕТСТВЕННЫМ за карточку, а не просто участником.
#
# В Kaiten «ответственный» — участник с type 2 (type 1 — обычный участник; именно type 2
# попадает в фильтр responsible_ids). POST /cards/{id}/members создаёт членство и ИГНОРИРУЕТ
# переданный type — роль поднимает только PATCH /cards/{id}/members/{user_id}. Отсюда инварианты
# assign, которые проверяет гейт:
#   1. вызывает И POST (создать членство), И PATCH с type:2 — ИМЕННО в этом порядке
#      (PATCH по ещё не созданному членству вернёт 4xx), без лишних вызовов;
#   2. если PATCH падает — assign возвращает ≠0 (иначе тихий баг: пользователь остаётся участником,
#      а гейт зелёный — ровно та регрессия, ради которой PR существует);
#   3. если POST падает («уже участник») — PATCH всё равно отрабатывает, assign завершается 0;
#   4. если падают оба — stderr показывает POST-ошибку (корень точнее, чем 404 от PATCH);
#   5. аргументы валидируются: пустые ИЛИ нечисловые card_id/user_id → exit 1, ни одного API-вызова
#      (защита от JSON- и path-инъекции — id идут в тело и в endpoint).
#
# Стаб kaiten.sh логирует вызовы и умеет падать по env FAIL_POST / FAIL_PATCH (эмулируя 4xx).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARDS_SH="$SCRIPT_DIR/../integrations/kaiten/scripts/kaiten-cards.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/calls.log"
ERR="$TMP/err.log"
FAILS=0
RC=0

# Копия kaiten-cards.sh рядом со стаб-kaiten.sh: kaiten-cards.sh зовёт "$SCRIPT_DIR/kaiten.sh".
cp "$CARDS_SH" "$TMP/kaiten-cards.sh"
cat > "$TMP/kaiten.sh" <<'STUB'
#!/usr/bin/env bash
# Логируем "METHOD ENDPOINT [BODY]" одной строкой на вызов: тело схлопываем (jq может отдать
# pretty-JSON), чтобы подсчёт/порядок вызовов не зависели от форматирования тела.
# Падаем на POST/PATCH по env FAIL_POST/FAIL_PATCH.
echo "$*" | tr '\n' ' ' >> "$CALLS"; echo >> "$CALLS"
case "$1" in
  POST)  [ -n "${FAIL_POST:-}" ]  && { echo "STUB POST failed: HTTP 422 (bad user_id)" >&2; exit 1; } ;;
  PATCH) [ -n "${FAIL_PATCH:-}" ] && { echo "STUB PATCH failed: HTTP 404" >&2; exit 1; } ;;
esac
printf '{"id":1,"type":2}\n'
STUB
chmod +x "$TMP/kaiten.sh" "$TMP/kaiten-cards.sh"

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }

# run <FAIL_POST> <FAIL_PATCH> -- <assign-args...>: чистит лог, гоняет assign со стабом; код assign
# кладёт в глобальную $RC через `|| RC=$?` — так set -e не срабатывает на ожидаемых ненулевых кодах,
# при этом инфраструктурные сбои setup (mktemp/cp/chmod выше) под set -e валят гейт сразу.
run() {
  local fp="$1" fpa="$2"; shift 3   # два FAIL_* + литерал '--'
  : > "$LOG"; : > "$ERR"; RC=0
  CALLS="$LOG" FAIL_POST="$fp" FAIL_PATCH="$fpa" "$TMP/kaiten-cards.sh" "$@" >/dev/null 2>"$ERR" || RC=$?
}

# 1. happy-path: ровно POST → PATCH type 2, в правильном порядке, без лишних вызовов
run "" "" -- assign 111 222
[ "$RC" -eq 0 ] && ok "happy: exit 0" || fail "happy: exit=$RC (ожидали 0)"
n=$(grep -c . "$LOG" || true)
[ "$n" -eq 2 ] && ok "happy: ровно 2 вызова (нет лишних)" || { fail "happy: вызовов $n (ожидали 2)"; sed 's/^/       /' "$LOG"; }
head -1 "$LOG" | grep -Eq '^POST /cards/111/members' && ok "happy: 1-й вызов — POST" || fail "happy: 1-й вызов не POST"
sed -n '2p' "$LOG" | grep -Eq '^PATCH /cards/111/members/222 .*"type": *2' \
  && ok "happy: 2-й вызов — PATCH type 2 (порядок POST→PATCH)" || fail "happy: 2-й вызов не PATCH type 2"

# 2. PATCH падает → assign обязан вернуть ≠0 (защита от регрессии '|| true' на PATCH)
run "" "1" -- assign 111 222
[ "$RC" -ne 0 ] && ok "PATCH fail → assign exit≠0" || fail "PATCH fail → assign exit 0 (тихий баг вернулся!)"

# 3. POST падает (уже участник) → PATCH всё равно, assign exit 0 (идемпотентность)
run "1" "" -- assign 111 222
[ "$RC" -eq 0 ] && ok "POST fail → assign exit 0 (идемпотентно)" || fail "POST fail → assign exit=$RC (ожидали 0)"
grep -Eq '^PATCH /cards/111/members/222' "$LOG" && ok "POST fail → PATCH всё равно вызван" || fail "POST fail → PATCH не вызван"

# 4. POST и PATCH падают → exit≠0 И stderr показывает POST-ошибку (точная диагностика корня)
run "1" "1" -- assign 111 222
[ "$RC" -ne 0 ] && ok "POST+PATCH fail → assign exit≠0" || fail "POST+PATCH fail → assign exit 0"
grep -q 'STUB POST failed' "$ERR" && ok "POST+PATCH fail → stderr содержит POST-ошибку" \
  || { fail "POST+PATCH fail → POST-ошибка потеряна в stderr"; sed 's/^/       /' "$ERR"; }

# 5. валидация аргументов → exit 1, ни одного API-вызова
run "" "" -- assign
{ [ "$RC" -eq 1 ] && [ ! -s "$LOG" ]; } && ok "no-args → exit 1 без вызовов" || fail "no-args → RC=$RC / лог непуст"
run "" "" -- assign abc 222
{ [ "$RC" -eq 1 ] && [ ! -s "$LOG" ]; } && ok "нечисловой card_id → exit 1 без вызовов (нет инъекции)" || { fail "нечисловой card_id → RC=$RC / лог непуст"; sed 's/^/       /' "$LOG"; }
run "" "" -- assign 111 'x","admin":true'
{ [ "$RC" -eq 1 ] && [ ! -s "$LOG" ]; } && ok "нечисловой user_id → exit 1 без вызовов (нет JSON-инъекции)" || { fail "нечисловой user_id → RC=$RC / лог непуст"; sed 's/^/       /' "$LOG"; }

echo "-----"
if [ "$FAILS" -eq 0 ]; then echo "PASS"; else echo "$FAILS fail(s)"; exit 1; fi
