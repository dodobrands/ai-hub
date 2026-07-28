#!/usr/bin/env bats
# Юниты каскада авторизации Контур.Толк (ktalk-auth.sh). Сети нет: curl подменяется
# стабом в PATH, который отвечает по заголовку авторизации.

setup() {
    AUTH_SH="${BATS_TEST_DIRNAME}/../scripts/ktalk-auth.sh"
    STUB_DIR="$(mktemp -d)"
    OUT_FILE="$(mktemp)"

    # Стаб curl: печатает HTTP-код (как `-w %{http_code}`) и пишет тело в файл из `-o`.
    # Код выбирается по заголовку: ключ API → $STUB_KEY_CODE, cookie → $STUB_SESSION_CODE.
    cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
out=""; mode="none"
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    case "$a" in
        X-Auth-Token:*)          mode="key" ;;
        "Authorization: Session"*) mode="session" ;;
    esac
    prev="$a"
done
case "$mode" in
    key)     code="${STUB_KEY_CODE:-200}" ;;
    session) code="${STUB_SESSION_CODE:-200}" ;;
    *)       code="000" ;;
esac
[ -n "$out" ] && printf '{"stub":"%s"}' "$mode" > "$out"
printf '%s' "$code"
STUB
    chmod +x "$STUB_DIR/curl"
    PATH="$STUB_DIR:$PATH"
    export PATH
}

teardown() {
    rm -rf "$STUB_DIR" "$OUT_FILE"
}

@test "ktalk_init_auth: только ключ API → режим key" {
    run bash -c "set -euo pipefail
        unset KTALK_SESSION_TOKEN
        export KTALK_TOKEN=k
        . '$AUTH_SH'
        ktalk_init_auth
        echo \"\$KTALK_MODES\""
    [ "$status" -eq 0 ]
    [ "$output" = "key" ]
}

@test "ktalk_init_auth: только cookie → режим session" {
    run bash -c "set -euo pipefail
        unset KTALK_TOKEN
        export KTALK_SESSION_TOKEN=s
        . '$AUTH_SH'
        ktalk_init_auth
        echo \"\$KTALK_MODES\""
    [ "$status" -eq 0 ]
    [ "$output" = "session" ]
}

@test "ktalk_init_auth: оба токена → приоритет у ключа API" {
    run bash -c "set -euo pipefail
        export KTALK_TOKEN=k KTALK_SESSION_TOKEN=s
        . '$AUTH_SH'
        ktalk_init_auth
        echo \"\$KTALK_MODES\""
    [ "$status" -eq 0 ]
    [ "$output" = "key session" ]
}

# Регрессия: раньше функция заканчивалась ложной проверкой `[ -n "$KTALK_SESSION_TOKEN" ]`,
# её статус становился статусом функции и `set -e` молча убивал вызывающий скрипт.
@test "ktalk_init_auth: не роняет вызывающий скрипт под set -e, когда cookie нет" {
    run bash -c "set -euo pipefail
        unset KTALK_SESSION_TOKEN
        export KTALK_TOKEN=k
        . '$AUTH_SH'
        ktalk_init_auth
        echo alive"
    [ "$status" -eq 0 ]
    [ "$output" = "alive" ]
}

@test "ktalk_fetch: ключ API работает — cookie не трогаем" {
    run bash -c "set -euo pipefail
        export STUB_KEY_CODE=200 STUB_SESSION_CODE=200
        export KTALK_TOKEN=k KTALK_SESSION_TOKEN=s
        . '$AUTH_SH'
        ktalk_init_auth
        ktalk_fetch https://example.invalid/api/x '$OUT_FILE'"
    [ "$status" -eq 0 ]
    [ "$output" = "200 key" ]
    grep -q '"stub":"key"' "$OUT_FILE"
}

@test "ktalk_fetch: 401 по ключу → фоллбек на cookie" {
    run bash -c "set -euo pipefail
        export STUB_KEY_CODE=401 STUB_SESSION_CODE=200
        export KTALK_TOKEN=k KTALK_SESSION_TOKEN=s
        . '$AUTH_SH'
        ktalk_init_auth
        ktalk_fetch https://example.invalid/api/x '$OUT_FILE' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "200 session" ]
    grep -q '"stub":"session"' "$OUT_FILE"
}

@test "ktalk_fetch: 403 по ключу → фоллбек и предупреждение в stderr" {
    run bash -c "set -euo pipefail
        export STUB_KEY_CODE=403 STUB_SESSION_CODE=200
        export KTALK_TOKEN=k KTALK_SESSION_TOKEN=s
        . '$AUTH_SH'
        ktalk_init_auth
        ktalk_fetch https://example.invalid/api/x '$OUT_FILE' 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ключ API вернул HTTP 403"* ]]
}

@test "ktalk_fetch: cookie нет — 401 по ключу возвращается как есть" {
    run bash -c "set -euo pipefail
        unset KTALK_SESSION_TOKEN
        export STUB_KEY_CODE=401
        export KTALK_TOKEN=k
        . '$AUTH_SH'
        ktalk_init_auth
        ktalk_fetch https://example.invalid/api/x '$OUT_FILE' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "401 key" ]
}

@test "ktalk_fetch: оба токена отвергнуты — статус последнего режима" {
    run bash -c "set -euo pipefail
        export STUB_KEY_CODE=403 STUB_SESSION_CODE=401
        export KTALK_TOKEN=k KTALK_SESSION_TOKEN=s
        . '$AUTH_SH'
        ktalk_init_auth
        ktalk_fetch https://example.invalid/api/x '$OUT_FILE' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "401 session" ]
}

@test "ktalk_have_auth: без токенов возвращает ошибку" {
    run bash -c "set -uo pipefail
        . '$AUTH_SH'
        KTALK_MODES=''
        ktalk_have_auth"
    [ "$status" -ne 0 ]
}
