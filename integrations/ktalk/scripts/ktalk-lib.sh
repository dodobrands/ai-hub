# ktalk-lib.sh — общее для ktalk-*.sh: .env, HTTP с ключом API, разбор аргументов.
# Не запускается сам, только `source` из ktalk-*.sh (они же ставят set -euo pipefail).
#
# .env (общий hub_load_env): KTALK_TOKEN — персональный ключ API (Толк → Настройки → API ключи).
# Значение ключа скрипты не печатают.
#
# Exit скриптов: 0 — ок, 1 — ошибка, 2 — нет ключа или Толк его не принял.

KTALK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# load-env.sh из marketplace-раскладки или кэша плагинов (как в time-login.sh);
# не нашёлся — работаем на переменных окружения.
_le="$KTALK_LIB_DIR/../../hub-meta/scripts/load-env.sh"
# shellcheck disable=SC2012
[[ -f "$_le" ]] || _le=$(ls "$KTALK_LIB_DIR"/../../../hub-meta/*/scripts/load-env.sh 2>/dev/null | sort -V | tail -1) || true
# shellcheck disable=SC2012
[[ -f "$_le" ]] || _le=$(ls "${CLAUDE_PLUGIN_ROOT:-/dev/null}"/../../hub-meta/*/scripts/load-env.sh 2>/dev/null | sort -V | tail -1) || true
if [[ -f "$_le" ]]; then
    # shellcheck source=../../hub-meta/scripts/load-env.sh
    . "$_le"
    hub_load_env "$KTALK_LIB_DIR" || true
fi
unset _le

# Пространство Толка зашито: плагин делается под одно пространство.
TENANT="dodobrands.ktalk.ru"
API="https://$TENANT/api"

die() { echo "Error: $*" >&2; exit 1; }

# Справка — шапка комментария вызвавшего скрипта.
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

command -v jq >/dev/null 2>&1 || die "jq не установлен: brew install jq"

no_auth() {
    echo "Error: KTALK_TOKEN не задан. Ключ: Толк → Настройки → API ключи, затем" >&2
    echo "  integrations/hub-meta/scripts/env-manager.sh set KTALK_TOKEN <ключ>" >&2
    exit 2
}

CODE=000 LOCATION=""

# .part-файл download — чистится на выходе при любом исходе.
PART=""
trap 'rm -f ${PART:+"$PART"}' EXIT

# curl_w <url> <out> [curl args…] — выставляет CODE и LOCATION (без перехода по редиректу).
curl_w() {
    local url=$1 out=$2 w; shift 2
    w=$(curl -sS --proto '=https' --connect-timeout 30 -o "$out" \
        -w '%{http_code} %{redirect_url}' "$@" "$url") || true
    CODE=${w%% *}; CODE=${CODE:-000}
    LOCATION=${w#* }; [[ "$LOCATION" != "$w" ]] || LOCATION=""
}

# fetch <METHOD> <url> <out> [curl args…] — запрос с ключом API. Ключ уходит в curl через
# файл заголовков (-H @…), а не через argv: так его не видно в списке процессов.
fetch() {
    local method=$1 url=$2 out=$3; shift 3
    [[ -n "${KTALK_TOKEN:-}" ]] || no_auth
    curl_w "$url" "$out" -X "$method" -H @<(printf 'X-Auth-Token: %s\n' "$KTALK_TOKEN") "$@"
}

# api <METHOD> <path> [curl args…] — JSON-ответ в stdout.
api() {
    local method=$1 path=$2 tmp; shift 2
    tmp=$(mktemp)
    fetch "$method" "$API$path" "$tmp" -H 'Accept: application/json' "$@"
    case "$CODE" in
        2??) cat "$tmp"; rm -f "$tmp" ;;
        401) rm -f "$tmp"
             echo "Error: ключ не принят (HTTP 401) на $path — ключ отозван или истёк: выпусти новый (Толк → Настройки → API ключи)" >&2; exit 2 ;;
        *)   echo "Error: HTTP $CODE на $method $path: $(head -c 300 "$tmp")" >&2
             rm -f "$tmp"; exit 1 ;;
    esac
}

# id из аргумента или ссылки https://<tenant>/recordings/<id>; только [A-Za-z0-9_-].
arg_id() {
    local v=${1:-}
    if [[ "$v" == https://* ]]; then
        v=${v%%[?#]*}; v=${v%/}; v=${v##*/}
    fi
    [[ "$v" =~ ^[A-Za-z0-9_-]+$ ]] || die "некорректный id '${1:-}': ожидается [A-Za-z0-9_-]+ или ссылка на запись"
    echo "$v"
}

need_val() { [[ $# -ge 2 && -n "$2" ]] || die "$1 требует значение"; }
