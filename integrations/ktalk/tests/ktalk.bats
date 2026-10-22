#!/usr/bin/env bats
# Юниты ktalk-*.sh без сети. curl подменён стабом: отвечает по таблице $STUB_ROUTES
# («<METHOD|*> <url-glob> <key|none|*> <code> <location|-> <body-file|->», первая
# подходящая строка) и пишет каждый вызов в $STUB_LOG: «<METHOD> <url> <режим> leak=<0|1>»,
# где leak=1 — значение токена попало в argv curl.

setup() {
    T="$(mktemp -d)"
    # Копия скриптов вне репо: hub_load_env не найдёт настоящий .env с живыми токенами.
    mkdir -p "$T/bin" "$T/stub"
    cp "${BATS_TEST_DIRNAME}"/../scripts/ktalk-*.sh "$T/bin/"
    KT="$T/bin"
    export STUB_LOG="$T/log" STUB_ROUTES="$T/routes"
    : > "$STUB_LOG"; : > "$STUB_ROUTES"
    export KTALK_TOKEN=KEYSECRET0001

    cat > "$T/stub/curl" <<'STUB'
#!/usr/bin/env bash
out="" method=GET url="" mode=none leak=0 hdrs="" get=0 params=""
for a in "$@"; do
    case "$a" in *"$KTALK_TOKEN"*) leak=1 ;; esac
done
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        -X) method=$2; shift 2 ;;
        -H) case "$2" in @*) hdrs="$hdrs$(cat "${2#@}")" ;; *) hdrs="$hdrs$2" ;; esac; shift 2 ;;
        --data-urlencode) params="$params${params:+&}$2"; shift 2 ;;
        -G) get=1; shift ;;
        -w|--data-binary|--proto|--connect-timeout) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
[ "$get" = 1 ] && [ -n "$params" ] && url="$url?$params"
case "$hdrs" in *"X-Auth-Token: $KTALK_TOKEN"*) mode=key ;; esac
echo "$method $url $mode leak=$leak" >> "$STUB_LOG"
code=404 loc="" body=""
while read -r rmethod pat m c l b; do
    [ -n "$pat" ] || continue
    [ "$rmethod" = "*" ] || [ "$rmethod" = "$method" ] || continue
    # shellcheck disable=SC2053  # pat — glob
    [[ "$url" == $pat ]] || continue
    [ "$m" = "*" ] || [ "$m" = "$mode" ] || continue
    code=$c; [ "$l" = "-" ] || loc=$l; [ "$b" = "-" ] || body=$b
    break
done < "$STUB_ROUTES"
if [ -n "$out" ]; then if [ -n "$body" ]; then cat "$body" > "$out"; else : > "$out"; fi; fi
printf '%s %s' "$code" "$loc"
STUB
    chmod +x "$T/stub/curl"
    export PATH="$T/stub:$PATH"
}

teardown() {
    rm -rf "$T"
}

route() { echo "$*" >> "$STUB_ROUTES"; }
body()  { local f; f=$(mktemp "$T/body.XXXXXX"); cat > "$f"; echo "$f"; }

@test "id с ../ отвергается до любого запроса" {
    run "$KT/ktalk-recordings.sh" download '../user/personal-access-tokens' "$T/out/"
    [ "$status" -eq 1 ]
    [[ "$output" == *"некорректный id"* ]] || false
    [ ! -s "$STUB_LOG" ]
}

@test "download: ссылка на запись → id, лучшее качество из детали записи" {
    route GET 'https://dodobrands.ktalk.ru/api/recordings/abc_123' key 200 - "$(echo '{"id":"abc_123","qualities":[{"height":240,"fileUrl":"/recording-blob/abc_123/240p"},{"height":900,"fileUrl":"/recording-blob/abc_123/900p"}]}' | body)"
    route GET 'https://dodobrands.ktalk.ru/recording-blob/abc_123/900p' key 200 - "$(echo VIDEO | body)"
    out=$("$KT/ktalk-recordings.sh" download 'https://dodobrands.ktalk.ru/recordings/abc_123?t=5' "$T/out/")
    [ "$(jq -r .path <<<"$out")" = "$T/out/abc_123.mp4" ]
    [ "$(cat "$T/out/abc_123.mp4")" = VIDEO ]
}

@test "ключ уходит заголовком, но не через argv curl" {
    route GET 'https://dodobrands.ktalk.ru/recording-blob/r1/900p' key 200 - "$(echo VIDEO | body)"
    "$KT/ktalk-recordings.sh" download r1 "$T/out/" --quality 900p
    [ "$(cut -d' ' -f3 "$STUB_LOG")" = key ]
    ! grep -q 'leak=1' "$STUB_LOG"
}

@test "без ключа — exit 2 и ни одного запроса" {
    run env -u KTALK_TOKEN "$KT/ktalk-recordings.sh" download r1 "$T/out/" --quality 900p
    [ "$status" -eq 2 ]
    [ ! -s "$STUB_LOG" ]
}

@test "ключ отклонён — exit 2" {
    route GET 'https://dodobrands.ktalk.ru/api/recordings/r1' key 401 - -
    run "$KT/ktalk-recordings.sh" download r1 "$T/out/"
    [ "$status" -eq 2 ]
}

@test "recordings download: на редирект на чужой хост токены не уходят" {
    route GET 'https://dodobrands.ktalk.ru/recording-blob/r1/900p' key 302 'https://storage.example.net/blob?sig=x' -
    route GET 'https://storage.example.net/blob?sig=x' none 200 - "$(echo VIDEO | body)"
    "$KT/ktalk-recordings.sh" download r1 "$T/out/" --quality 900p
    [ "$(cat "$T/out/r1.mp4")" = VIDEO ]
    [ "$(sed -n 2p "$STUB_LOG" | cut -d' ' -f2,3)" = "https://storage.example.net/blob?sig=x none" ]
    [ ! -e "$T/out/r1.mp4.part" ]
}

@test "recordings download не перезаписывает существующий файл без --force" {
    echo old > "$T/r1.mp4"
    run "$KT/ktalk-recordings.sh" download r1 "$T/r1.mp4" --quality 900p
    [ "$status" -eq 1 ]
    [[ "$output" == *"--force"* ]] || false
    [ "$(cat "$T/r1.mp4")" = old ]
    [ ! -s "$STUB_LOG" ]
}

@test "rooms create не перетирает существующую комнату" {
    route GET 'https://dodobrands.ktalk.ru/api/rooms/team-sync' key 200 - "$(echo '{"roomName":"team-sync","title":"Sync"}' | body)"
    run "$KT/ktalk-rooms.sh" create Sync --slug team-sync
    [ "$status" -eq 1 ]
    [[ "$output" == *"уже существует"* ]] || false
    ! grep -q '^PUT' "$STUB_LOG"
}

@test "rooms create: свободный slug (200 с title: null) → PUT и ссылка на комнату" {
    route GET 'https://dodobrands.ktalk.ru/api/rooms/team-sync' key 200 - "$(echo '{"roomName":"team-sync","title":null}' | body)"
    route PUT 'https://dodobrands.ktalk.ru/api/rooms/team-sync' key 200 - "$(echo '{"conferenceId":"cf1","title":"Sync"}' | body)"
    out=$("$KT/ktalk-rooms.sh" create Sync --slug Team-Sync)
    [ "$(jq -r .url <<<"$out")" = https://dodobrands.ktalk.ru/team-sync ]
    [ "$(jq -r .conference_id <<<"$out")" = cf1 ]
}

@test "meetings create: тело запроса и ссылка на комнату" {
    route POST 'https://dodobrands.ktalk.ru/api/calendar' key 200 - "$(echo '{"roomName":"team-retro","id":"ev1"}' | body)"
    out=$("$KT/ktalk-meetings.sh" create --subject Ретро --start 2026-07-21T15:00:00 --end 2026-07-21T16:00:00 --attendee SID1)
    [ "$(jq -r .url <<<"$out")" = https://dodobrands.ktalk.ru/team-retro ]
    [ "$(cut -d' ' -f1,3 "$STUB_LOG")" = "POST key" ]
}
