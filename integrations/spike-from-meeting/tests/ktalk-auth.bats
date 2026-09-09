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

@test "ktalk_init_auth: API key only yields key mode" {
    run bash -c "set -euo pipefail
        unset KTALK_SESSION_TOKEN
        export KTALK_TOKEN=k
        . '$AUTH_SH'
        ktalk_init_auth
        echo \"\$KTALK_MODES\""
    [ "$status" -eq 0 ]
    [ "$output" = "key" ]
}

@test "ktalk_init_auth: cookie only yields session mode" {
    run bash -c "set -euo pipefail
        unset KTALK_TOKEN
        export KTALK_SESSION_TOKEN=s
        . '$AUTH_SH'
        ktalk_init_auth
        echo \"\$KTALK_MODES\""
    [ "$status" -eq 0 ]
    [ "$output" = "session" ]
}

@test "ktalk_init_auth: with both tokens the API key wins" {
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
@test "ktalk_init_auth: does not kill the caller under set -e when there is no cookie" {
    run bash -c "set -euo pipefail
        unset KTALK_SESSION_TOKEN
        export KTALK_TOKEN=k
        . '$AUTH_SH'
        ktalk_init_auth
        echo alive"
    [ "$status" -eq 0 ]
    [ "$output" = "alive" ]
}

@test "ktalk_fetch: the API key works, the cookie is left alone" {
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

@test "ktalk_fetch: 401 on the key falls back to the cookie" {
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

@test "ktalk_fetch: 403 on the key falls back and warns on stderr" {
    run bash -c "set -euo pipefail
        export STUB_KEY_CODE=403 STUB_SESSION_CODE=200
        export KTALK_TOKEN=k KTALK_SESSION_TOKEN=s
        . '$AUTH_SH'
        ktalk_init_auth
        ktalk_fetch https://example.invalid/api/x '$OUT_FILE' 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ключ API вернул HTTP 403"* ]]
}

@test "ktalk_fetch: with no cookie the key's 401 is returned as-is" {
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

@test "ktalk_fetch: both tokens rejected yields the last mode's status" {
    run bash -c "set -euo pipefail
        export STUB_KEY_CODE=403 STUB_SESSION_CODE=401
        export KTALK_TOKEN=k KTALK_SESSION_TOKEN=s
        . '$AUTH_SH'
        ktalk_init_auth
        ktalk_fetch https://example.invalid/api/x '$OUT_FILE' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "401 session" ]
}

@test "ktalk_have_auth: returns an error with no tokens" {
    run bash -c "set -uo pipefail
        . '$AUTH_SH'
        KTALK_MODES=''
        ktalk_have_auth"
    [ "$status" -ne 0 ]
}
