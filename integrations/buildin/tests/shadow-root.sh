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

# BUILDIN_ROOT_PAGE_ID нет в HUB_KNOWN_SECRETS, поэтому hub_load_env его не
# сбрасывает, а скрипт ставит его выше team-config.json. Экспортированная
# переменная (direnv, профиль) ломала бы кейсы «нет корня» и «корень из
# конфига» на верном коде.
unset BUILDIN_ROOT_PAGE_ID HUB_OVERLAY_ROOT HUB_ENV_FILE

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
# Только отслеживаемые файлы: рядом лежит gitignored shadow-index.json, и у
# всех, кто запускал shadow до этой правки, в нём остался старый root_page_id.
# Скан по каталогу падал бы на личном кеше, а CI с чистым чекаутом молчал бы.
if git -C "$TESTS_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    HITS=$(git -C "$TESTS_DIR" grep -l "$RETIRED_ID" -- "$BUILDIN_DIR" "$BOT_API_DIR" 2>/dev/null || true)
else
    HITS=$(grep -rl --exclude=shadow-index.json "$RETIRED_ID" "$BUILDIN_DIR" "$BOT_API_DIR" 2>/dev/null || true)
fi
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

echo "--- настоящий team-config.example.json не даёт тихое пустое дерево ---"
# setup.sh копирует пример как есть (`cp team-config.example.json
# team-config.json`) и про root_page_id не спрашивает. Если в примере лежит
# непустой плейсхолдер, guard его пропустит и `tree` у каждой новой команды
# снова молча напечатает пустое дерево — ровно то, что эта правка убирает.
rm -f "$OVERLAY/team-config.json"
cp "$TESTS_DIR/../../../team-config.example.json" "$OVERLAY/team-config.json"
seed_index
run_tree ""; RC=$?
if [ "$RC" -eq 0 ]; then
    fail "с нетронутым team-config.example.json tree завершился нулём (тихое пустое дерево)"
elif ! grep -qi 'usage\|root_page_id' "$TMP/err.txt"; then
    fail "с нетронутым примером нет подсказки (stderr: $(head -c 200 "$TMP/err.txt"))"
else
    ok "нетронутый пример даёт отказ с подсказкой, а не пустое дерево"
fi

# Корень задан, но в индексе его нет — опечатка или неотсканированная страница.
# Тихий нулевой выход здесь неотличим от «дерево пустое».
set_config '99999999-9999-9999-9999-999999999999'; seed_index
run_tree ""; RC=$?
if [ "$RC" -eq 0 ]; then
    fail "корень, которого нет в индексе, дал код 0 и пустой вывод"
else
    ok "корень, которого нет в индексе, — отказ"
fi

echo "--- shadow работает без .env и без load-env.sh ---"
# Описание обещает, что локальные команды не требуют ни токена, ни .env.
# Обе ветки мягкого бутстрапа до сих пор в CI не исполнялись: каждый кейс
# выше кладёт в песочницу и load-env.sh, и .env.
EMPTY_HOME="$TMP/empty-home"
mkdir -p "$EMPTY_HOME"

BARE="$TMP/bare"
mkdir -p "$BARE/integrations/buildin/scripts" "$BARE/integrations/hub-meta/scripts"
cp "$SRC_DIR/buildin-shadow.sh" "$BARE/integrations/buildin/scripts/"
cp "$HUB_META_DIR/load-env.sh" "$BARE/integrations/hub-meta/scripts/"
BARE_SHADOW="$BARE/integrations/buildin/scripts/buildin-shadow.sh"

HOME="$EMPTY_HOME" XDG_CONFIG_HOME="$EMPTY_HOME" \
    /bin/bash "$BARE_SHADOW" stats > "$TMP/out.txt" 2> "$TMP/err.txt"
if [ $? -ne 0 ]; then
    fail "stats без .env упал: $(head -c 200 "$TMP/err.txt")"
else
    ok "stats работает без .env"
fi

rm -f "$BARE/integrations/hub-meta/scripts/load-env.sh" "$BARE/integrations/buildin/shadow-index.json"
HOME="$EMPTY_HOME" XDG_CONFIG_HOME="$EMPTY_HOME" \
    /bin/bash "$BARE_SHADOW" stats > "$TMP/out.txt" 2> "$TMP/err.txt"
if [ $? -ne 0 ]; then
    fail "stats без load-env.sh упал: $(head -c 200 "$TMP/err.txt")"
else
    ok "stats работает даже без load-env.sh"
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: все проверки пройдены"
else
    echo "FAILED: $FAILS"
fi
[ "$FAILS" -eq 0 ]
