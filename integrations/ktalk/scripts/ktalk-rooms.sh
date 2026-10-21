#!/usr/bin/env bash
# ktalk-rooms.sh — комнаты Контур.Толк
# Usage: ./ktalk-rooms.sh <command> [args...]
#
# Commands:
#   create <title> [--slug s] [--description d] [--lobby] [--anonymous-until YYYY-MM-DD]
#          [--audio|--video|--screen-share none|muted|disabled] [--force]
#                                     — создать комнату; занятый slug без --force не трогает
#                                       (PUT /rooms/{slug} — create-or-overwrite)
set -euo pipefail

# shellcheck source=ktalk-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ktalk-lib.sh"

cmd_create() {
    local title="" slug="" desc="" lobby=false anon="" audio=none video=none screen=none force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slug)            need_val "$@"; slug=$2; shift 2 ;;
            --description)     need_val "$@"; desc=$2; shift 2 ;;
            --lobby)           lobby=true; shift ;;
            --anonymous-until) need_val "$@"; anon=$2; shift 2 ;;
            --audio)           need_val "$@"; audio=$2; shift 2 ;;
            --video)           need_val "$@"; video=$2; shift 2 ;;
            --screen-share)    need_val "$@"; screen=$2; shift 2 ;;
            --force)           force=1; shift ;;
            -*)                die "create: неизвестный флаг $1" ;;
            *)                 title=$1; shift ;;
        esac
    done
    [[ -n "$title" ]] || die "create: нужен <title>"
    local p
    for p in "$audio" "$video" "$screen"; do
        [[ "$p" =~ ^(none|muted|disabled)$ ]] || die "политика '$p': ожидается none|muted|disabled"
    done
    if [[ -n "$anon" ]]; then
        [[ "$anon" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--anonymous-until: ожидается YYYY-MM-DD"
        anon="${anon}T23:59:59.000Z"
    fi
    if [[ -n "$slug" ]]; then
        slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
        [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || die "--slug: только a-z, 0-9 и дефис, до 64 символов"
    else
        slug=$(uuidgen | tr '[:upper:]' '[:lower:]')
    fi

    # PUT /rooms/{slug} — create-or-overwrite: занятый slug молча теряет свои настройки.
    if [[ "$force" -eq 0 ]]; then
        local tmp; tmp=$(mktemp)
        fetch GET "$API/rooms/$slug" "$tmp" -H 'Accept: application/json'
        # Толк отвечает 200 и на свободный slug — «виртуальной» комнатой с title: null.
        # Занята та, у которой есть название: PUT без title не бывает.
        local taken=""
        [[ "$CODE" != 2?? ]] || taken=$(jq -r '.title // empty' "$tmp" 2>/dev/null) || true
        rm -f "$tmp"
        case "$CODE" in
            404) ;;
            2??) [[ -z "$taken" ]] || die "комната '$slug' уже существует («$taken») — перезапись затрёт её настройки. Если это твоя комната, повтори с --force" ;;
            *)   die "не удалось проверить, свободен ли slug '$slug' (HTTP $CODE). Повтори или --force" ;;
        esac
    fi

    local body data
    body=$(jq -n --arg t "$title" --arg d "$desc" --arg anon "$anon" --argjson lobby "$lobby" \
        --arg a "$audio" --arg v "$video" --arg s "$screen" '
        {title: $t, enableLobby: $lobby, enableSessionHalls: false,
         audioPolicy: $a, videoPolicy: $v, screenSharePolicy: $s, maxVideoQuality: 0}
        + (if $d != "" then {description: $d} else {} end)
        + (if $anon != "" then {anonymousAccessExpirationDate: $anon} else {} end)')
    data=$(api PUT "/rooms/$slug" -H 'Content-Type: application/json' --data-binary "$body")
    [[ -n "$data" ]] || data='{}'
    jq --arg url "https://$TENANT/$slug" --arg slug "$slug" --arg t "$title" \
        '{url: $url, room_name: $slug, conference_id: (.conferenceId // .id), title: (.title // $t), room: .}' <<<"$data"
}

CMD="${1:-help}"
shift || true
case "$CMD" in
    create) cmd_create "$@" ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 1 ;;
esac
