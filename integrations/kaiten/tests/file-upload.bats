#!/usr/bin/env bats
# Загрузка файла в kaiten.sh: `--file <path>` вместо JSON-тела. Kaiten принимает файлы только
# multipart-запросом, и заголовок JSON сломал бы границу multipart. Сети нет: curl подменяется
# стабом, который печатает свои аргументы по одному на строку.
#
# `|| false` после `[[ ]]`: в bash 3.2 (на маке bats идёт под ним) упавшее `[[ ]]` в середине
# теста тест не роняет.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
    SANDBOX="$(mktemp -d)"

    # Раскладка, которую ждёт kaiten.sh: <root>/integrations/{kaiten,hub-meta}/scripts/
    mkdir -p "$SANDBOX/integrations/kaiten/scripts" "$SANDBOX/integrations/hub-meta/scripts"
    cp "$REPO_ROOT/integrations/kaiten/scripts/kaiten.sh" "$SANDBOX/integrations/kaiten/scripts/"
    cp "$REPO_ROOT/integrations/hub-meta/scripts/load-env.sh" "$SANDBOX/integrations/hub-meta/scripts/"

    # hub_load_env вычищает секреты из окружения и берёт их только из .env,
    # поэтому токен кладём в .env песочницы, а не в export.
    cat > "$SANDBOX/.env" <<'ENV'
KAITEN_TOKEN=test-token
KAITEN_DOMAIN=example.invalid
ENV

    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Отметка о вызове — чтобы проверить, что до сети дело не дошло. HTTP-код идёт последней
# строкой: kaiten.sh забирает его оттуда, а остальное считает телом ответа.
touch "$(dirname "$0")/../curl-called"
printf '%s\n' "$@"
printf '200'
STUB
    chmod +x "$SANDBOX/bin/curl"
    PATH="$SANDBOX/bin:$PATH"
    export PATH

    KAITEN="$SANDBOX/integrations/kaiten/scripts/kaiten.sh"
    printf '<html>report</html>' > "$SANDBOX/report.html"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "file upload goes as multipart with the file field" {
    run bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/report.html"
    [ "$status" -eq 0 ]
    [[ "$output" == *"file=@\"$SANDBOX/report.html\""* ]] || false
    [[ "$output" != *"Content-Type: application/json"* ]] || false
    [[ "$output" == *$'--max-time\n300\n'* ]] || false
    [[ "$output" == *"https://example.invalid/api/latest/cards/abc/files"* ]] || false
}

@test "a path with a comma and a semicolon is quoted for curl" {
    printf 'x' > "$SANDBOX/a,b;c.html"
    run bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/a,b;c.html"
    [ "$status" -eq 0 ]
    [[ "$output" == *"file=@\"$SANDBOX/a,b;c.html\""* ]] || false
}

@test "a path with a double quote and a backslash is escaped for curl" {
    printf 'x' > "$SANDBOX/a\"b\\c.html"
    run bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/a\"b\\c.html"
    [ "$status" -eq 0 ]
    [[ "$output" == *"file=@\"$SANDBOX/a\\\"b\\\\c.html\""* ]] || false
}

@test "a missing file fails before any request" {
    run bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/nope.html"
    [ "$status" -eq 1 ]
    [[ "$output" == *"file not found"* ]] || false
    [ ! -e "$SANDBOX/curl-called" ]
}

@test "an unreadable file fails before any request, not as a network error" {
    if [ "$(id -u)" -eq 0 ]; then
        skip "root reads any file"
    fi
    chmod 000 "$SANDBOX/report.html"
    run bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/report.html"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not readable"* ]] || false
    [ ! -e "$SANDBOX/curl-called" ]
}

@test "upload by numeric card id is refused before any request" {
    run bash "$KAITEN" POST /cards/123/files --file "$SANDBOX/report.html"
    [ "$status" -eq 1 ]
    [[ "$output" == *"numeric card id"* ]] || false
    [ ! -e "$SANDBOX/curl-called" ]
}

@test "numeric card id without a leading slash is refused too" {
    run bash "$KAITEN" POST cards/123/files --file "$SANDBOX/report.html"
    [ "$status" -eq 1 ]
    [[ "$output" == *"numeric card id"* ]] || false
    [ ! -e "$SANDBOX/curl-called" ]
}

@test "file upload is POST only" {
    run bash "$KAITEN" GET /cards/abc/files --file "$SANDBOX/report.html"
    [ "$status" -eq 1 ]
    [[ "$output" == *"only with POST"* ]] || false
    [ ! -e "$SANDBOX/curl-called" ]
}

@test "a second file is refused instead of being dropped" {
    printf 'y' > "$SANDBOX/other.html"
    run bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/report.html" --file "$SANDBOX/other.html"
    [ "$status" -eq 1 ]
    [[ "$output" == *"one file per call"* ]] || false
    [ ! -e "$SANDBOX/curl-called" ]
}

@test "the .env with tokens is never uploaded" {
    run bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/.env"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to upload"* ]] || false
    [ ! -e "$SANDBOX/curl-called" ]
}

@test "file upload needs write access" {
    run env KAITEN_ACCESS_LEVEL=read bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/report.html"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Write access denied"* ]] || false
    [ ! -e "$SANDBOX/curl-called" ]
}

@test "a JSON body still goes as JSON" {
    run bash "$KAITEN" POST /cards '{"title":"x"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Content-Type: application/json"* ]] || false
    [[ "$output" == *$'--max-time\n30\n'* ]] || false
    [[ "$output" == *'{"title":"x"}'* ]] || false
}
