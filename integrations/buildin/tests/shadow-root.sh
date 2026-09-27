#!/usr/bin/env bash
# Корень shadow-индекса приходит снаружи, а не зашит в скрипт.
#
# Зачем: ai-hub — публичный мульти-командный репозиторий, и REVIEW_GUIDELINES
# требует, чтобы командная специфика жила в overlay потребителя, а не в
# generic-коде. У `tree` дефолтом стоял ID конкретной страницы конкретной
# команды: у всех остальных команда молча печатала пустое дерево вместо отказа.
#
# Сети не нужно — shadow-индекс целиком локальный. Тест plain bash, чтобы на
# маке его можно было гонять без bats прямо под /bin/bash 3.2 (целевой шелл).
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$TESTS_DIR/../scripts"
HUB_META_DIR="$TESTS_DIR/../../hub-meta/scripts"
BUILDIN_DIR="$TESTS_DIR/.."
BOT_API_DIR="$TESTS_DIR/../../buildin-bot-api"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0

fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
ok()   { echo "ok:   $1"; }

# ---- 1. выведенный из обращения ID не должен вернуться ----------------------
# Страница конкретной команды, стоявшая и в примерах, и дефолтом у `tree`.
# Склеиваем из двух половин: целиком написанный ID попал бы под собственную
# проверку и тест вечно падал бы на самом себе.
RETIRED_ID='2a904afe-42e9-4ebd'-'a94e-f6fe0cbacf58'
echo "--- ID конкретной страницы не просочился обратно ---"
HITS=$(grep -rl "$RETIRED_ID" "$BUILDIN_DIR" "$BOT_API_DIR" 2>/dev/null || true)
if [ -n "$HITS" ]; then
    fail "ID конкретной страницы снова в исходниках:"
    echo "$HITS" | sed 's/^/        /'
else
    ok "ID конкретной страницы нигде в buildin/buildin-bot-api"
fi

# ---- песочница: боевая раскладка + overlay с .env и team-config -------------
# buildin-shadow.sh ищет load-env.sh относительным путём, а корень overlay
# (HUB_OVERLAY_ROOT) — это каталог найденного .env.
OVERLAY="$TMP/overlay"
mkdir -p "$OVERLAY/integrations/buildin/scripts" "$OVERLAY/integrations/hub-meta/scripts"
cp "$SRC_DIR/buildin-shadow.sh" "$OVERLAY/integrations/buildin/scripts/"
cp "$HUB_META_DIR/load-env.sh" "$OVERLAY/integrations/hub-meta/scripts/"
printf 'BUILDIN_UI_TOKEN=test-token\n' > "$OVERLAY/.env"

SHADOW="$OVERLAY/integrations/buildin/scripts/buildin-shadow.sh"
INDEX="$OVERLAY/integrations/buildin/shadow-index.json"
CONFIGURED_ROOT='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
OTHER_ROOT='11111111-2222-3333-4444-555555555555'

# Индекс с двумя корнями — так видно, какой из них выбрал скрипт.
seed_index() {
    python3 -c '
import json, sys
json.dump({
    "meta": {"description": "Shadow index"},
    "pages": {
        sys.argv[2]: {"title": "ИЗ-КОНФИГА", "children": []},
        sys.argv[3]: {"title": "ИЗ-АРГУМЕНТА", "children": []},
    },
}, open(sys.argv[1], "w"), ensure_ascii=False)
' "$INDEX" "$CONFIGURED_ROOT" "$OTHER_ROOT"
}

set_config() {
    if [ -z "$1" ]; then
        rm -f "$OVERLAY/team-config.json"
    else
        python3 -c '
import json, sys
json.dump({"buildin": {"root_page_id": sys.argv[2]}}, open(sys.argv[1], "w"))
' "$OVERLAY/team-config.json" "$1"
    fi
}

run_tree() {
    /bin/bash "$SHADOW" tree ${1:+"$1"} > "$TMP/out.txt" 2> "$TMP/err.txt"
}

echo "--- tree: корень берётся снаружи ---"

# Ни аргумента, ни конфига — отказ, а не пустое дерево «успешно».
set_config ""; seed_index
run_tree ""; RC=$?
if [ "$RC" -eq 0 ]; then
    fail "без аргумента и без конфига tree завершился нулём (должен отказать)"
elif ! grep -qi 'usage\|root_page_id' "$TMP/err.txt"; then
    fail "без аргумента и без конфига в stderr нет подсказки (stderr: $(head -c 200 "$TMP/err.txt"))"
else
    ok "без аргумента и без конфига — отказ с подсказкой"
fi

# Конфиг задан — он и есть корень.
set_config "$CONFIGURED_ROOT"; seed_index
run_tree ""; RC=$?
if [ "$RC" -ne 0 ]; then
    fail "с корнем в team-config.json tree упал (rc=$RC), stderr: $(head -c 200 "$TMP/err.txt")"
elif ! grep -q 'ИЗ-КОНФИГА' "$TMP/out.txt"; then
    fail "корень из team-config.json не применился (stdout: $(head -c 200 "$TMP/out.txt"))"
else
    ok "корень берётся из team-config.json"
fi

# Явный аргумент важнее конфига.
set_config "$CONFIGURED_ROOT"; seed_index
run_tree "$OTHER_ROOT"; RC=$?
if [ "$RC" -ne 0 ]; then
    fail "tree с явным аргументом упал (rc=$RC), stderr: $(head -c 200 "$TMP/err.txt")"
elif ! grep -q 'ИЗ-АРГУМЕНТА' "$TMP/out.txt"; then
    fail "явный аргумент не перебил конфиг (stdout: $(head -c 200 "$TMP/out.txt"))"
else
    ok "явный аргумент важнее конфига"
fi

echo "--- индекс создаётся валидным, когда корень не задан ---"
set_config ""; rm -f "$INDEX"
/bin/bash "$SHADOW" stats > "$TMP/out.txt" 2> "$TMP/err.txt"; RC=$?
if [ "$RC" -ne 0 ]; then
    fail "stats на пустом месте упал (rc=$RC), stderr: $(head -c 200 "$TMP/err.txt")"
elif [ ! -s "$INDEX" ]; then
    fail "индекс не создан"
elif ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$INDEX" 2>/dev/null; then
    fail "созданный индекс — невалидный JSON: $(head -c 200 "$INDEX")"
elif grep -q "$RETIRED_ID" "$INDEX"; then
    fail "в созданный индекс попал ID конкретной страницы"
else
    ok "индекс создаётся валидным JSON без чужого ID"
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: все проверки пройдены"
else
    echo "FAILED: $FAILS"
fi
[ "$FAILS" -eq 0 ]
