#!/usr/bin/env bash
# ktalk-auth.sh — общая авторизация для kontur-talk-*.sh. Не запускается сам, только `source`.
#
# Каскад: сначала ключ API, при его отказе (HTTP 401/403) — cookie-сессия.
#   1. $KTALK_TOKEN         — ключ API Толка (Администрирование → Ключи API),
#                             заголовок `X-Auth-Token`. Живёт до даты, заданной при выпуске,
#                             поэтому это основной способ для автоматизации.
#   2. $KTALK_SESSION_TOKEN — cookie `sessionToken` из браузера, заголовок
#                             `Authorization: Session`. Короткоживущая, только фоллбек.
#
# Если ни одного токена нет в окружении, .env ищется общим `hub_load_env`
# (integrations/hub-meta/scripts/load-env.sh). Значения из окружения приоритетнее:
# cookie обычно достают ad-hoc (chrome-devtools MCP) и передают через `export`.
#
# API:
#   ktalk_init_auth              — загрузить .env при необходимости, собрать $KTALK_MODES
#   ktalk_have_auth              — 0, если есть хоть один режим
#   ktalk_auth_help <tenant>     — печатает в stderr, как получить токен
#   ktalk_fetch <url> <out> [curl-args…]
#                                — GET с каскадом. Печатает в stdout «<HTTP-код> <режим>»
#                                  (например «200 key»). Разбирай так:
#                                    read -r status mode <<<"$(ktalk_fetch "$url" "$out")"
#                                  Через переменную режим не вернуть: вызов идёт в subshell.

KTALK_MODES=""      # "key", "session" или "key session" (bash 3.2: строка, не массив)

ktalk_init_auth() {
    if [ -z "${KTALK_TOKEN:-}" ] && [ -z "${KTALK_SESSION_TOKEN:-}" ]; then
        local script_dir _hub_load_env_sh
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        # Тот же бутстрап, что в остальных интеграциях: marketplace-раскладка
        # (<root>/integrations/<plugin>/scripts/) либо кэш плагинов Claude Code
        # (<cache>/<marketplace>/<plugin>/<version>/scripts/ — версия hub-meta
        # ищется глобом рядом, $CLAUDE_PLUGIN_ROOT остаётся крайним фолбэком).
        _hub_load_env_sh="$script_dir/../../hub-meta/scripts/load-env.sh"
        # shellcheck disable=SC2012  # тот же однострочник, что в остальных интеграциях (kusto.sh)
        [ -f "$_hub_load_env_sh" ] || _hub_load_env_sh=$(ls "$script_dir"/../../../hub-meta/*/scripts/load-env.sh 2>/dev/null | head -1)
        # shellcheck disable=SC2012
        [ -f "$_hub_load_env_sh" ] || _hub_load_env_sh=$(ls "${CLAUDE_PLUGIN_ROOT:-/dev/null}"/../../hub-meta/*/scripts/load-env.sh 2>/dev/null | head -1)
        if [ -f "$_hub_load_env_sh" ]; then
            # shellcheck source=../../hub-meta/scripts/load-env.sh
            . "$_hub_load_env_sh"
            hub_load_env "$script_dir" || true
        fi
    fi

    KTALK_MODES=""
    [ -n "${KTALK_TOKEN:-}" ]         && KTALK_MODES="key"
    [ -n "${KTALK_SESSION_TOKEN:-}" ] && KTALK_MODES="${KTALK_MODES:+$KTALK_MODES }session"
    # ВАЖНО: явный `return 0`. Иначе статусом функции станет статус последней проверки
    # `[ -n … ]`, и `set -e` в вызывающем скрипте убьёт его, когда одного из токенов нет.
    return 0
}

ktalk_have_auth() {
    [ -n "$KTALK_MODES" ]
}

ktalk_auth_help() {
    local tenant="${1:-<tenant>.ktalk.ru}"
    cat >&2 <<EOF
Error: ни KTALK_TOKEN, ни KTALK_SESSION_TOKEN не заданы (и не нашлись в .env).

Вариант 1 (основной) — ключ API Толка, не истекает до заданной при выпуске даты:
  ${tenant} → Администрирование → Ключи API → создать и скопировать
  (после выпуска ключ виден один час), затем в .env: KTALK_TOKEN=<ключ>

Вариант 2 (фоллбек) — cookie сессии, живёт недолго:
  1. Залогинься в браузере на ${tenant}
  2. DevTools → Application → Cookies → ${tenant} → cookie 'sessionToken'
  3. export KTALK_SESSION_TOKEN="<значение>"

Для агентов в Claude Code cookie забирается через chrome-devtools MCP:
  mcp__chrome-devtools__navigate_page → URL записи (SSO пропустит автоматом)
  mcp__chrome-devtools__evaluate_script → 'document.cookie' → распарсить sessionToken
EOF
}

# ktalk_fetch <url> <outfile> [доп. аргументы curl…]
ktalk_fetch() {
    local url="$1" out="$2"
    shift 2

    local mode status h1 h2 last_status="000"
    for mode in $KTALK_MODES; do
        h1=""; h2=""
        case "$mode" in
            key)     h1="X-Auth-Token: ${KTALK_TOKEN}" ;;
            session) h1="Authorization: Session ${KTALK_SESSION_TOKEN}"
                     h2="Cookie: sessionToken=${KTALK_SESSION_TOKEN}" ;;
        esac

        # `x-platform: web` — заголовок веб-клиента, он нужен только сессионной авторизации.
        # Ключу API его не отправляем: интеграционные эндпоинты обходятся без него.
        if [ -n "$h2" ]; then
            status=$(curl -sS -o "$out" -w '%{http_code}' -H "$h1" -H "$h2" -H 'x-platform: web' "$@" "$url" || echo "000")
        else
            status=$(curl -sS -o "$out" -w '%{http_code}' -H "$h1" "$@" "$url" || echo "000")
        fi

        last_status="$status"

        case "$status" in
            401|403)
                # Токен не принят или не хватает прав — пробуем следующий режим, если он есть.
                case "$KTALK_MODES" in
                    *session*)
                        if [ "$mode" = "key" ]; then
                            echo "Warning: ключ API вернул HTTP $status на ${url##*/} — переключаюсь на cookie-сессию" >&2
                            continue
                        fi ;;
                esac
                echo "$status $mode"; return 0 ;;
            *)
                echo "$status $mode"; return 0 ;;
        esac
    done

    echo "$last_status ${mode:-none}"
}
