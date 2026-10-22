#!/usr/bin/env bash
# ktalk-meetings.sh — встречи Контур.Толк: планирование
# Usage: ./ktalk-meetings.sh <command> [args...]
#
# Commands:
#   create --subject s --start ISO --end ISO [--room name] [--timezone GMT+3]
#          [--attendee <SID>]... [--sip] [--pin 1234] [--auto-record] [--recurring] [--description d]
#                                     — запланировать встречу; рассылает приглашения
#
# Читать архив встреч, участников и транскрипты — через официальный MCP Толка (см. README).
set -euo pipefail

# shellcheck source=ktalk-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ktalk-lib.sh"

cmd_create() {
    local subject="" start="" end="" room="" tz="GMT+3" sip=false pin="" auto=false recurring=false desc=""
    local attendees=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --subject)     need_val "$@"; subject=$2; shift 2 ;;
            --start)       need_val "$@"; start=$2; shift 2 ;;
            --end)         need_val "$@"; end=$2; shift 2 ;;
            --room)        need_val "$@"; room=$2; shift 2 ;;
            --timezone)    need_val "$@"; tz=$2; shift 2 ;;
            --attendee)    need_val "$@"; attendees+=("$2"); shift 2 ;;
            --sip)         sip=true; shift ;;
            --pin)         need_val "$@"; pin=$2; shift 2 ;;
            --auto-record) auto=true; shift ;;
            --recurring)   recurring=true; shift ;;
            --description) need_val "$@"; desc=$2; shift 2 ;;
            *)             die "create: неизвестный аргумент $1" ;;
        esac
    done
    [[ -n "$subject" && -n "$start" && -n "$end" ]] || die "create: нужны --subject, --start, --end"
    [[ -z "$pin" || "$pin" =~ ^[0-9]{4,6}$ ]] || die "--pin: 4–6 цифр"

    local att body data
    att=$(printf '%s\n' ${attendees[@]+"${attendees[@]}"} | jq -R 'select(. != "")' | jq -s 'map({type: "user", key: .})')
    body=$(jq -n --arg s "$subject" --arg st "$start" --arg en "$end" --arg tz "$tz" --arg room "$room" \
        --arg pin "$pin" --arg d "$desc" --argjson sip "$sip" --argjson auto "$auto" \
        --argjson rec "$recurring" --argjson att "$att" '
        {subject: $s, start: $st, end: $en, timezone: $tz, enableSip: $sip,
         enableAutoRecording: $auto, isRecurring: $rec, requiredAttendees: $att}
        + (if $room != "" then {roomName: $room} else {} end)
        + (if $pin != "" then {pinCode: $pin} else {} end)
        + (if $d != "" then {description: $d} else {} end)')
    data=$(api POST /calendar -H 'Content-Type: application/json' --data-binary "$body")
    [[ -n "$data" ]] || data='{}'
    jq --arg host "$TENANT" --arg room "$room" \
        '{url: ((.roomName // (if $room != "" then $room else null end)) as $r
                | if $r then "https://\($host)/\($r)" else .url end), event: .}' <<<"$data"
}

CMD="${1:-help}"
shift || true
case "$CMD" in
    create)         cmd_create "$@" ;;
    help|-h|--help) usage ;;
    *)              usage >&2; exit 1 ;;
esac
