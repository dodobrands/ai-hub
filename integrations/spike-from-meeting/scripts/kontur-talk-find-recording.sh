#!/usr/bin/env bash
# kontur-talk-find-recording.sh — ищет ссылку на запись встречи Контур.Толк
# по названию / комнате / автору и дате, когда URL записи неизвестен.
#
# Usage: kontur-talk-find-recording.sh [опции] [<title_regex>]
#   <title_regex>     — регэксп по названию записи (case-insensitive), напр. 'Daily|Standup'
#   --date YYYY-MM-DD — день записи (по умолчанию сегодня; сравнение по UTC)
#   --room <roomName> — фильтр по постоянной комнате (надёжнее названия: id не меняется)
#   --email <email>   — только записи, созданные этим пользователем
#   --tenant <host>   — хост tenant'а, напр. your-company.ktalk.ru (обязателен, если не задан
#                       $KTALK_TENANT)
#
# Авторизация — каскадом (см. ktalk-auth.sh), но у режимов РАЗНЫЕ эндпоинты:
#   1. $KTALK_TOKEN (ключ API) → доменный листинг записей:
#      GET /api/domain/recordings?skip=&top=[&query=<подстрока названия>]
#      Записи всего домена, новые сверху: key, title, roomName, createdDate, duration,
#      participantsCount, createdBy.email, size.
#      NB: идентификатор записи — в поле `key` (поле `id` всегда null); он же идёт
#      в URL /recordings/<key> и в /api/recordings/<key>/…
#   2. $KTALK_SESSION_TOKEN (cookie) → личная история встреч (ключ API её НЕ принимает, 401):
#      GET /api/conferenceshistory?top=50&includeUnfinished=true
#      → GET /api/conferenceshistory/v2/{key} → artifacts.recordings[]
#   Если ключ есть, но доменный листинг ответил 401/403 — автоматически уходим в (2).
#
# ВАЖНО про названия: в режиме ключа `title` — это название ЗАПИСИ (обычно название
# комнаты), а в режиме cookie — тема КОНФЕРЕНЦИИ. Для одной и той же встречи они могут
# различаться (комнату переименовали, тему задали отдельно), поэтому для постоянных
# встреч надёжнее фильтровать по `--room <roomName>`, а не по названию.
#
# Вывод — по строке на найденную запись (новые сверху):
#   <createdDate/startTime><TAB><title><TAB>https://<tenant>/recordings/<key><TAB><duration>s
# Exit codes: 0 — найдено, 3 — записей по фильтру нет, 1/2 — ошибка / нет токена.
#
# Эндпоинты проверены 2026-07-28 на реальном ktalk-tenant'е.

set -euo pipefail

TENANT_HOST="${KTALK_TENANT:-}"
DAY="$(date -u +%F)"
TITLE_RE=""
ROOM=""
EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)   DAY="${2:?--date requires YYYY-MM-DD}"; shift 2 ;;
    --room)   ROOM="${2:?--room requires roomName}"; shift 2 ;;
    --email)  EMAIL="${2:?--email requires email}"; shift 2 ;;
    --tenant) TENANT_HOST="${2:?--tenant requires host}"; shift 2 ;;
    *)        TITLE_RE="$1"; shift ;;
  esac
done

usage() {
  echo "Usage: $(basename "$0") --tenant <host> [--date YYYY-MM-DD] [--room <roomName>] [--email <email>] [<title_regex>]" >&2
}

if [[ -z "$TENANT_HOST" ]]; then
  echo "Error: не задан tenant. Передай --tenant your-company.ktalk.ru или выставь \$KTALK_TENANT." >&2
  usage; exit 1
fi

if [[ -z "$TITLE_RE" && -z "$ROOM" && -z "$EMAIL" ]]; then
  echo "Error: нужен хотя бы один фильтр: <title_regex>, --room или --email." >&2
  usage; exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "Error: jq not installed. Install: brew install jq" >&2; exit 1; }

# shellcheck source=ktalk-auth.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ktalk-auth.sh"
ktalk_init_auth
ktalk_have_auth || { ktalk_auth_help "$TENANT_HOST"; exit 2; }

API_BASE="https://${TENANT_HOST}/api"

# --- Режим ключа API: доменный листинг записей, страницами, новые сверху ---
# Возвращает: 0 — найдено, 3 — нет по фильтру, 4 — ключ не принят (нужен фоллбек), 1 — ошибка
find_via_domain() {
  local page=500 skip=0 found=0 tmp status count matches oldest
  tmp=$(mktemp -t ktalk-domain-XXXXXX)

  while :; do
    status=$(curl -sS -o "$tmp" -w '%{http_code}' \
      -H "X-Auth-Token: ${KTALK_TOKEN}" -H 'Accept: application/json' \
      "${API_BASE}/domain/recordings?skip=${skip}&top=${page}" || echo "000")

    case "$status" in
      200) ;;
      401|403) rm -f "$tmp"; return 4 ;;
      *) echo "Error: HTTP $status от ${API_BASE}/domain/recordings" >&2
         echo "Body: $(head -c 300 "$tmp")" >&2
         rm -f "$tmp"; return 1 ;;
    esac

    count=$(jq -r '.recordings | length' "$tmp")
    [[ "$count" -eq 0 ]] && break

    matches=$(jq -r \
      --arg day "$DAY" --arg re "$TITLE_RE" --arg room "$ROOM" \
      --arg email "$EMAIL" --arg host "$TENANT_HOST" '
        .recordings[]
        | select((.createdDate // "")[0:10] == $day)
        | select($re    == "" or ((.title // "") | test($re; "i")))
        | select($room  == "" or (.roomName // "") == $room)
        | select($email == "" or ((.createdBy.email // "") == $email))
        | [ .createdDate, (.title // ""),
            ("https://" + $host + "/recordings/" + .key),
            (((.duration // 0) | tostring) + "s") ]
        | @tsv' "$tmp")

    if [[ -n "$matches" ]]; then
      printf '%s\n' "$matches"
      found=1
    fi

    # Листинг отсортирован по дате убыванию: как только страница ушла старше нужного дня,
    # дальше будут только более старые записи — останавливаемся.
    oldest=$(jq -r '.recordings[-1].createdDate // ""' "$tmp")
    [[ "${oldest:0:10}" < "$DAY" ]] && break

    skip=$((skip + page))
    [[ "$skip" -gt 20000 ]] && break   # предохранитель от бесконечной пагинации
  done

  rm -f "$tmp"
  [[ "$found" -eq 1 ]] && return 0
  return 3
}

# --- Фоллбек: личная история встреч по cookie-сессии ---
find_via_session() {
  local found=0 keys_titles

  [[ -n "$TITLE_RE" ]] || {
    echo "Error: режим cookie-сессии ищет только по <title_regex>: --room/--email умеет лишь ключ API." >&2
    echo "Передай регэксп по теме встречи либо задай KTALK_TOKEN." >&2
    return 1
  }

  # NB: HTTP-код проверяем явно. На `set -e` здесь полагаться нельзя — функция вызывается
  # через `|| rc=$?`, а внутри такого вызова errexit не действует: провал curl молча
  # превратился бы в «встреч не найдено» (exit 3) вместо ошибки авторизации.
  local sess_tmp sess_status rc
  sess_tmp=$(mktemp -t ktalk-session-XXXXXX)

  session_get() {
    sess_status=$(curl -sS -o "$sess_tmp" -w '%{http_code}' \
      -H "Authorization: Session ${KTALK_SESSION_TOKEN}" \
      -H "Cookie: sessionToken=${KTALK_SESSION_TOKEN}" \
      -H "x-platform: web" -H "Accept: application/json" "$1" || echo "000")
    case "$sess_status" in
      200) cat "$sess_tmp"; return 0 ;;
      401|403)
        echo "Error: cookie-сессия не принята (HTTP $sess_status) — sessionToken протух." >&2
        echo "Обнови cookie или задай KTALK_TOKEN (ключ API не истекает)." >&2
        return 2 ;;
      *)
        echo "Error: HTTP $sess_status от ${1}" >&2
        echo "Body: $(head -c 200 "$sess_tmp")" >&2
        return 1 ;;
    esac
  }

  keys_titles=$(session_get "${API_BASE}/conferenceshistory?top=50&includeUnfinished=true") || {
    rc=$?; rm -f "$sess_tmp"; return "$rc"
  }
  keys_titles=$(printf '%s' "$keys_titles" \
    | jq -r --arg day "$DAY" --arg re "$TITLE_RE" '
        .conferences[]
        | select(.title != null)
        | select(.startTime | startswith($day))
        | select(.title | test($re; "i"))
        | [.key, .startTime, .title] | @tsv')

  if [[ -z "$keys_titles" ]]; then
    rm -f "$sess_tmp"
    echo "No meetings matching /${TITLE_RE}/i on ${DAY} (${TENANT_HOST})" >&2
    return 3
  fi

  while IFS=$'\t' read -r key start title; do
    while IFS=$'\t' read -r rec_id rec_dur; do
      [[ -n "$rec_id" ]] || continue
      printf '%s\t%s\thttps://%s/recordings/%s\t%ss\n' "$start" "$title" "$TENANT_HOST" "$rec_id" "${rec_dur:-0}"
      found=1
    done < <(session_get "${API_BASE}/conferenceshistory/v2/${key}" \
               | jq -r '.artifacts.recordings[]? | [.id, ((.duration // 0) | tostring)] | @tsv')
  done <<< "$keys_titles"

  rm -f "$sess_tmp"

  if [[ "$found" -eq 0 ]]; then
    echo "Meetings matched on ${DAY}, but none has a recording yet (запись могла не завершиться или ещё обрабатывается)" >&2
    return 3
  fi
  return 0
}

not_found_msg() {
  echo "No recordings on ${DAY} matching filters (title=/${TITLE_RE}/i room=${ROOM:-any} email=${EMAIL:-any}, ${TENANT_HOST})" >&2
  echo "Запись могла не завершиться или ещё обрабатывается. NB: в режиме ключа title — название записи (комнаты), а не тема конференции." >&2
}

# --- Выбор режима: ключ API → при отказе cookie-сессия ---
case "$KTALK_MODES" in
  *key*)
    rc=0; find_via_domain || rc=$?
    case "$rc" in
      0) exit 0 ;;
      3) not_found_msg; exit 3 ;;
      4)
        case "$KTALK_MODES" in
          *session*)
            echo "Warning: ключ API не принят на /api/domain/recordings — переключаюсь на cookie-сессию" >&2
            rc=0; find_via_session || rc=$?
            exit "$rc" ;;
          *)
            echo "Error: ключ API не принят на /api/domain/recordings (401/403), cookie-сессии нет." >&2
            echo "Проверь срок действия и права ключа либо задай KTALK_SESSION_TOKEN." >&2
            exit 1 ;;
        esac ;;
      *) exit "$rc" ;;
    esac ;;
esac

rc=0; find_via_session || rc=$?
exit "$rc"
