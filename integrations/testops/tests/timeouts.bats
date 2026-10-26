#!/usr/bin/env bats
# Потолки времени в testops.sh: без них вызов висел бесконечно, когда TCP соединяется, а
# TLS-рукопожатие нет (так выглядит TestOps без VPN). Сети нет: curl подменяется стабом, который
# печатает свои аргументы по одному на строку.
#
# `|| false` после `[[ ]]`: в bash 3.2 (на маке bats идёт под ним) упавшее `[[ ]]` в середине
# теста тест не роняет.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
    SANDBOX="$(mktemp -d)"

    mkdir -p "$SANDBOX/integrations/testops/scripts"
    cp "$REPO_ROOT/integrations/testops/scripts/testops.sh" "$SANDBOX/integrations/testops/scripts/"

    cat > "$SANDBOX/.env" <<'ENV'
TESTOPS_TOKEN=test-token
TESTOPS_URL=https://example.invalid
ENV
    export HUB_ENV_FILE="$SANDBOX/.env"
    # Потолки из окружения разработчика подменили бы значения по умолчанию.
    unset TESTOPS_CONNECT_TIMEOUT TESTOPS_MAX_TIME

    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
# HTTP-код идёт последней строкой, как от `-w "\n%{http_code}"`: testops.sh забирает его оттуда.
# STUB_CURL_EXIT — сбой curl без ответа, STUB_HTTP_CODE — код ответа сервера. Отметка о вызове —
# чтобы проверить, что до сети дело не дошло.
touch "$(dirname "$0")/../curl-called"
if [[ -n "${STUB_CURL_EXIT:-}" ]]; then
    echo "curl: (${STUB_CURL_EXIT}) Operation timed out after 15001 milliseconds" >&2
    exit "$STUB_CURL_EXIT"
fi
printf '%s\n' "$@"
printf '%s' "${STUB_HTTP_CODE:-200}"
STUB
    chmod +x "$SANDBOX/bin/curl"
    PATH="$SANDBOX/bin:$PATH"
    export PATH

    TESTOPS="$SANDBOX/integrations/testops/scripts/testops.sh"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "a request has a connect timeout and a total ceiling by default" {
    run bash "$TESTOPS" GET /project
    [ "$status" -eq 0 ]
    [[ "$output" == *$'--connect-timeout\n15\n'* ]] || false
    [[ "$output" == *$'--max-time\n120\n'* ]] || false
    [[ "$output" == *$'-sS\n'* ]] || false
}

@test "the ceilings are taken from the environment" {
    run env TESTOPS_CONNECT_TIMEOUT=3 TESTOPS_MAX_TIME=7 bash "$TESTOPS" GET /project
    [ "$status" -eq 0 ]
    [[ "$output" == *$'--connect-timeout\n3\n'* ]] || false
    [[ "$output" == *$'--max-time\n7\n'* ]] || false
}

@test "no answer fails with the request and the reason from curl" {
    run env STUB_CURL_EXIT=28 bash "$TESTOPS" GET /project
    [ "$status" -eq 1 ]
    [[ "$output" == *"no response from TestOps for GET /project (curl exit 28"* ]] || false
    [[ "$output" == *"Operation timed out"* ]] || false
}

@test "an HTTP error still reports its status" {
    run env STUB_HTTP_CODE=404 bash "$TESTOPS" GET /project/0
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: HTTP 404"* ]] || false
}

@test "a write without an answer warns that it may have been applied" {
    run env STUB_CURL_EXIT=28 bash "$TESTOPS" POST /rs/testcase '{"name": "x"}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"a write may have been applied"* ]] || false
}

@test "a read without an answer does not warn about a write" {
    run env STUB_CURL_EXIT=28 bash "$TESTOPS" GET /project
    [ "$status" -eq 1 ]
    [[ "$output" != *"write may have been applied"* ]] || false
}

@test "a total ceiling that is not a number fails before any request" {
    run env TESTOPS_MAX_TIME=2m bash "$TESTOPS" GET /project
    [ "$status" -eq 1 ]
    [[ "$output" == *"TESTOPS_MAX_TIME must be a number of seconds"* ]] || false
    [ ! -e "$SANDBOX/curl-called" ]
}

@test "a connect ceiling that is not a number fails before any request" {
    run env TESTOPS_CONNECT_TIMEOUT=abc bash "$TESTOPS" GET /project
    [ "$status" -eq 1 ]
    [[ "$output" == *"TESTOPS_CONNECT_TIMEOUT must be a number of seconds"* ]] || false
    [ ! -e "$SANDBOX/curl-called" ]
}
