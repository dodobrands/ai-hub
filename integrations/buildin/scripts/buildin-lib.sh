# shellcheck shell=bash
# Общие хелперы buildin-pages.sh и buildin-comments.sh — подключается через source.
# Одна копия на оба скрипта: UUID_RE и конверт транзакции у них обязаны
# совпадать, а две копии разошлись бы молча.
#
# Ждёт SCRIPT_DIR от подключившего скрипта: buildin() зовёт соседний buildin.sh.

buildin() {
    "$SCRIPT_DIR/buildin.sh" "$@"
}

# Формат UUID — одной константой на файл: три копии пришлось бы держать в
# синхроне руками, ровно от этого уходили при выносе parse_page_and_block_id.
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

# Извлечь UUID из URL или вернуть как есть
parse_id() {
    local input="$1"
    local uuid
    uuid=$(echo "$input" | grep -oE "$UUID_RE" | tail -1 || true)
    echo "${uuid:-$input}"
}

# Получить spaceId для страницы
get_space_id() {
    local PAGE_ID="$1"
    local space_id
    space_id=$(buildin GET "/api/blocks/$PAGE_ID" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('data', {}).get('spaceId', ''))
" 2>/dev/null)
    [[ -z "$space_id" ]] && { echo "Error: cannot resolve spaceId for $PAGE_ID" >&2; exit 1; }
    echo "$space_id"
}

# Получить uuid текущего пользователя — его проставляют в createdBy/updatedBy.
# Пустой uuid молча испортил бы авторство у всего, что создаёт транзакция.
get_user_id() {
    local user_id
    user_id=$(buildin GET "/api/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('uuid',''))")
    [[ -z "$user_id" ]] && { echo "Error: cannot resolve current user id from /api/users/me" >&2; exit 1; }
    echo "$user_id"
}

# Сгенерировать UUID v4
gen_uuid() {
    python3 -c "import uuid; print(str(uuid.uuid4()))"
}

# Тело запроса к /api/records/transactions. Отдельно от отправки: тот же конверт
# нужен файлу отката, а две его копии разошлись бы молча и вскрылись бы ровно
# в тот момент, когда откат понадобится.
tx_body() {
    local SPACE_ID="$1"
    local OPERATIONS="$2"
    python3 -c "
import json, sys
ops = json.loads(sys.argv[1])
print(json.dumps({
    'requestId': sys.argv[2],
    'transactions': [{
        'id': sys.argv[3],
        'spaceId': sys.argv[4],
        'operations': ops
    }]
}))
" "$OPERATIONS" "$(gen_uuid)" "$(gen_uuid)" "$SPACE_ID"
}

# Выполнить транзакцию
transaction() {
    local SPACE_ID="$1"
    local OPERATIONS="$2"
    # Тело собираем отдельным присваиванием, а не подстановкой прямо в аргументе:
    # при подстановке сбой сборки прячется от set -e и POST уходит с пустым телом.
    # «|| return» обязателен, а не избыточен: в условии if/&&/|| bash отключает
    # set -e во всём теле вызванной функции, и без него сбой сборки тела не
    # прервал бы её — POST ушёл бы с пустым телом.
    local body
    body=$(tx_body "$SPACE_ID" "$OPERATIONS") || return
    buildin POST "/api/records/transactions" "$body"
}
