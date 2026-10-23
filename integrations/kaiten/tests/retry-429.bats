#!/usr/bin/env bats
# Повтор ответа 429 в kaiten.sh. Бакет лимита Kaiten общий на токен, поэтому 429 ловит и
# последовательный скрипт, когда тем же токеном работает сосед. Сети нет: curl подменяется стабом,
# который отвечает кодами из файла по очереди, а sleep — стабом, который записывает паузы.
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
    # Значения из окружения разработчика подменили бы умолчания.
    unset KAITEN_RETRIES KAITEN_RATE

    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
# N-й вызов отвечает кодом из N-й строки файла codes (нет строки — 200). Код вида curl:28 —
# сбой самого curl без ответа. HTTP-код идёт последней строкой: kaiten.sh забирает его оттуда.
dir="$(dirname "$0")/.."
n=$(( $(cat "$dir/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$dir/calls"
code="$(sed -n "${n}p" "$dir/codes" 2>/dev/null)"
code="${code:-200}"
case "$code" in
    curl:*) echo "curl: (${code#curl:}) Operation timed out" >&2; exit "${code#curl:}" ;;
esac
printf '{"call": %s}\n' "$n"
printf '%s' "$code"
STUB
    cat > "$SANDBOX/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/../sleeps"
STUB
    chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin/sleep"
    PATH="$SANDBOX/bin:$PATH"
    export PATH

    KAITEN="$SANDBOX/integrations/kaiten/scripts/kaiten.sh"
}

teardown() {
    rm -rf "$SANDBOX"
}

codes() {
    printf '%s\n' "$@" > "$SANDBOX/codes"
}

@test "429 is retried and the answer of the retry is returned" {
    codes 429 429 200
    run bash "$KAITEN" GET /cards/1
    [ "$status" -eq 0 ]
    [ "$(cat "$SANDBOX/calls")" -eq 3 ]
    [ "$(cat "$SANDBOX/sleeps")" = $'1\n2' ]
    [[ "$output" == *'"call": 3'* ]] || false
}

@test "429 every time gives up after KAITEN_RETRIES retries" {
    codes 429 429 429 429 429 429
    run bash "$KAITEN" GET /cards/1
    [ "$status" -eq 1 ]
    [ "$(cat "$SANDBOX/calls")" -eq 4 ]
    [ "$(cat "$SANDBOX/sleeps")" = $'1\n2\n3' ]
    [[ "$output" == *"Error: HTTP 429"* ]] || false
}

@test "KAITEN_RETRIES=0 turns the retry off" {
    codes 429
    run env KAITEN_RETRIES=0 bash "$KAITEN" GET /cards/1
    [ "$status" -eq 1 ]
    [ "$(cat "$SANDBOX/calls")" -eq 1 ]
    [ ! -e "$SANDBOX/sleeps" ]
}

@test "a write is retried on 429 too: Kaiten did not run it" {
    codes 429 200
    run bash "$KAITEN" POST /cards '{"title": "x"}'
    [ "$status" -eq 0 ]
    [ "$(cat "$SANDBOX/calls")" -eq 2 ]
}

@test "an upload is retried on 429 with the same file" {
    printf 'x' > "$SANDBOX/report.html"
    codes 429 200
    run bash "$KAITEN" POST /cards/abc/files --file "$SANDBOX/report.html"
    [ "$status" -eq 0 ]
    [ "$(cat "$SANDBOX/calls")" -eq 2 ]
}

@test "5xx is not retried: a write may have gone through" {
    codes 500 200
    run bash "$KAITEN" POST /cards '{"title": "x"}'
    [ "$status" -eq 1 ]
    [ "$(cat "$SANDBOX/calls")" -eq 1 ]
    [[ "$output" == *"Error: HTTP 500"* ]] || false
}

@test "a curl failure is not retried" {
    codes curl:28 200
    run bash "$KAITEN" GET /cards/1
    [ "$status" -eq 1 ]
    [ "$(cat "$SANDBOX/calls")" -eq 1 ]
    [[ "$output" == *"exit 28"* ]] || false
}

@test "a KAITEN_RETRIES that is not a number fails before any request" {
    run env KAITEN_RETRIES=three bash "$KAITEN" GET /cards/1
    [ "$status" -eq 1 ]
    [[ "$output" == *"KAITEN_RETRIES must be a non-negative integer"* ]] || false
    [ ! -e "$SANDBOX/calls" ]
}
