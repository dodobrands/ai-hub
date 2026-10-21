#!/usr/bin/env bash
# ktalk-recordings.sh — записи Контур.Толк: скачивание видео
# Usage: ./ktalk-recordings.sh <command> [args...]
#   id записи — значение или ссылка https://dodobrands.ktalk.ru/recordings/<id>
#
# Commands:
#   download <recording_id> <dir|file> [--quality 900p] [--force]
#                                     — видеофайл записи; существующий файл без --force не перезаписывает
set -euo pipefail

# shellcheck source=ktalk-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ktalk-lib.sh"

# download_to <url> <file> — авторизация только для хоста пространства; редирект на чужой
# хост (хранилище по подписанной ссылке) идёт без токенов.
download_to() {
    local url=$1 out=$2 host hops=0
    while :; do
        host=${url#https://}; host=${host%%[/:?#]*}
        if [[ "$url" == https://* && "$host" == "$TENANT" ]]; then
            fetch GET "$url" "$out"
        else
            curl_w "$url" "$out"
        fi
        case "$CODE" in
            2??) return 0 ;;
            301|302|303|307|308)
                [[ -n "$LOCATION" && "$hops" -lt 5 ]] || die "редирект без Location или слишком длинная цепочка"
                url=$LOCATION; hops=$((hops + 1)) ;;
            401) echo "Error: ключ не принят (HTTP 401) при скачивании — ключ отозван или истёк: выпусти новый (Толк → Настройки → API ключи)" >&2; exit 2 ;;
            *)   die "HTTP $CODE при скачивании ${url%%\?*}" ;;
        esac
    done
}

cmd_download() {
    local id="" dest="" quality="" force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quality) need_val "$@"; quality=$2; shift 2 ;;
            --force)   force=1; shift ;;
            -*)        die "download: неизвестный флаг $1" ;;
            *)         if [[ -z "$id" ]]; then id=$(arg_id "$1"); else dest=$1; fi; shift ;;
        esac
    done
    [[ -n "$id" && -n "$dest" ]] || die "download: нужны <recording_id> и <dir|file>"
    [[ -z "$quality" || "$quality" =~ ^[A-Za-z0-9]+$ ]] || die "--quality: например 900p"

    local url
    if [[ -n "$quality" ]]; then
        url="/recording-blob/$id/$quality"
    else
        # Лучшее качество: максимум по высоте кадра, иначе последнее в списке.
        url=$(api GET "/recordings/$id" | jq -r '((.qualities // []) | map(select(.fileUrl // .url))
            | sort_by((.height // .width // .quality // 0) | tonumber? // 0) | last | (.fileUrl // .url)?)
            // .fileUrl // .downloadUrl // empty')
        [[ -n "$url" ]] || die "в записи $id нет qualities[].fileUrl"
    fi
    case "$url" in
        https://*) ;;
        /*)        url="https://$TENANT$url" ;;
        *)         die "неожиданный fileUrl: $url" ;;
    esac

    if [[ -d "$dest" || "$dest" == */ ]]; then
        dest="${dest%/}/$id.mp4"
    fi
    [[ ! -e "$dest" || "$force" -eq 1 ]] || die "файл $dest уже есть — перезапись только с --force"
    mkdir -p "$(dirname "$dest")"
    PART="$dest.part"
    download_to "$url" "$PART"
    [[ -s "$PART" ]] || die "скачался пустой файл"
    mv -f "$PART" "$dest"
    jq -n --arg p "$dest" --argjson b "$(wc -c < "$dest" | tr -d ' ')" --arg s "${url%%\?*}" \
        '{ok: true, path: $p, bytes: $b, source: $s}'
}

CMD="${1:-help}"
shift || true
case "$CMD" in
    download)       cmd_download "$@" ;;
    help|-h|--help) usage ;;
    *)              usage >&2; exit 1 ;;
esac
