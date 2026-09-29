#!/usr/bin/env bats
# Загрузка файла в kaiten.sh: `--file <path>` вместо JSON-тела. Kaiten принимает файлы только
# multipart-запросом, и заголовок JSON сломал бы границу multipart. Сети нет: curl подменяется
# стабом, который печатает свои аргументы по одному на строку.

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
    [[ "$output" == *"file=@\"$SANDBOX/report.html\""* ]]
    [[ "$output" != *"Content-Type: application/json"* ]]
    [[ "$output" == *"https://example.invalid/api/latest/cards/abc/files"* ]]
}

@test "a path with a comma and a semicolon is quoted for curl" {
    printf 'x' > "$SANDBOX/a,b;c.html"
    run bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/a,b;c.html"
    [ "$status" -eq 0 ]
    [[ "$output" == *"file=@\"$SANDBOX/a,b;c.html\""* ]]
}

@test "a missing file fails before any request" {
    run bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/nope.html"
    [ "$status" -eq 1 ]
    [[ "$output" == *"file not found"* ]]
    [ ! -e "$SANDBOX/curl-called" ]
}

@test "file upload needs write access" {
    run env KAITEN_ACCESS_LEVEL=read bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/report.html"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Write access denied"* ]]
    [ ! -e "$SANDBOX/curl-called" ]
}

@test "a JSON body still goes as JSON" {
    run bash "$KAITEN" POST /cards '{"title":"x"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Content-Type: application/json"* ]]
    [[ "$output" == *'{"title":"x"}'* ]]
}
