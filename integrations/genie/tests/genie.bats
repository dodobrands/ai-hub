#!/usr/bin/env bats
# genie.sh ходит в Genie через databricks CLI (OAuth), а не curl с PAT. Сети нет: databricks
# подменяется стабом, который пишет аргументы и DATABRICKS_HOST в журналы и отвечает реальным
# (обезличенным) выводом `databricks genie start-conversation -o json` из fixtures/ — так
# форматтер проверяется на настоящем формате CLI, а не на рукописном. Ошибку CLI стаб
# изображает текстом из файла cli-error: тексты взяты из реального CLI v1.13.0.
# curl — стаб, который только отмечает, что его позвали.
#
# Скрипты лежат в песочнице как subtree внутри overlay-репо: .env — в корне overlay, выше
# каталога ai-hub. Так проверяется, что конфиг находится и в overlay, а не только в standalone.
#
# `|| false` после `[[ ]]`: в bash 3.2 (на маке bats идёт под ним) упавшее `[[ ]]` в середине
# теста тест не роняет.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
    SANDBOX="$(mktemp -d)"
    HUB="$SANDBOX/overlay/integrations/ai-hub"

    mkdir -p "$HUB/integrations/genie/scripts" "$HUB/integrations/hub-meta/scripts"
    cp "$REPO_ROOT/integrations/genie/scripts/genie.sh" "$REPO_ROOT/integrations/genie/scripts/genie-config.sh" \
        "$HUB/integrations/genie/scripts/"
    cp "$REPO_ROOT/integrations/hub-meta/scripts/load-env.sh" "$HUB/integrations/hub-meta/scripts/"

    cat > "$SANDBOX/overlay/.env" <<'ENV'
GENIE_HOST=https://example.invalid
GENIE_PROFILE=team
GENIE_SPACE_ID=space-1
ENV

    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/databricks" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$SANDBOX/databricks.log"
printf -- '---\n' >> "$SANDBOX/databricks.log"
printf '%s\n' "\${DATABRICKS_HOST-<unset>}" >> "$SANDBOX/databricks-host.log"
if [[ -f "$SANDBOX/cli-error" ]]; then
    cat "$SANDBOX/cli-error" >&2
    exit 1
fi
cat "$BATS_TEST_DIRNAME/fixtures/start-conversation.json"
STUB
    cat > "$SANDBOX/bin/curl" <<STUB
#!/usr/bin/env bash
touch "$SANDBOX/curl-called"
exit 22
STUB
    chmod +x "$SANDBOX/bin/databricks" "$SANDBOX/bin/curl"
    PATH="$SANDBOX/bin:$PATH"
    export PATH
    # Конфиг, профиль и хост из окружения разработчика не должны просочиться в тест.
    unset GENIE_HOST GENIE_PROFILE GENIE_SPACE_ID GENIE_TOKEN DATABRICKS_CONFIG_PROFILE DATABRICKS_HOST

    GENIE="$HUB/integrations/genie/scripts/genie.sh"
}

teardown() {
    rm -rf "$SANDBOX"
}

cli_fails() {
    printf 'Error: %s\n' "$1" > "$SANDBOX/cli-error"
}

drop_env() {
    sed -i.bak "/^$1=/d" "$SANDBOX/overlay/.env"
}

@test "asks the space through databricks CLI with the overlay profile, never curl" {
    run bash "$GENIE" "how many orders yesterday?"
    [ "$status" -eq 0 ]
    [ ! -f "$SANDBOX/curl-called" ]
    log="$(cat "$SANDBOX/databricks.log")"
    [[ "$log" == genie$'\n'start-conversation$'\n'* ]] || false
    [[ "$log" == *$'\n'--profile$'\n'team$'\n'* ]] || false
    [[ "$log" == *$'\n'space-1$'\n'"how many orders yesterday?"$'\n'---* ]] || false
    # Профиль задан — хост берётся из него, GENIE_HOST его не перебивает.
    [ "$(cat "$SANDBOX/databricks-host.log")" = "<unset>" ]
    [[ "$output" == *"1,234,567 rows"* ]] || false
    [[ "$output" == *"main.sales.orders"* ]] || false
    # Реальный CLI отдаёт пустой suggested_questions ({}), заголовок без вопросов не печатаем.
    [[ "$output" != *"Suggested questions"* ]] || false
}

@test "a question starting with a dash goes as content, not as a CLI flag" {
    run bash "$GENIE" "-5% orders?"
    [ "$status" -eq 0 ]
    [[ "$(cat "$SANDBOX/databricks.log")" == *$'\n'--$'\n'space-1$'\n'"-5% orders?"$'\n'* ]] || false
}

@test "without GENIE_PROFILE the workspace is picked by GENIE_HOST" {
    drop_env GENIE_PROFILE
    run bash "$GENIE" "q"
    [ "$status" -eq 0 ]
    ! grep -qx -- "--profile" "$SANDBOX/databricks.log"
    [ "$(cat "$SANDBOX/databricks-host.log")" = "https://example.invalid" ]
}

@test "without GENIE_PROFILE and GENIE_HOST the CLI default profile is used" {
    drop_env GENIE_PROFILE
    drop_env GENIE_HOST
    run bash "$GENIE" "q"
    [ "$status" -eq 0 ]
    ! grep -qx -- "--profile" "$SANDBOX/databricks.log"
    [ "$(cat "$SANDBOX/databricks-host.log")" = "<unset>" ]
}

@test "works without .env when the config comes from the environment" {
    rm "$SANDBOX/overlay/.env"
    # Пустой HOME: иначе сработает фолбэк hub_load_env на ~/.config/ai-hub/.env разработчика.
    mkdir -p "$SANDBOX/home"
    HOME="$SANDBOX/home" XDG_CONFIG_HOME="$SANDBOX/home/.config" GENIE_SPACE_ID=space-1 GENIE_PROFILE=team \
        run bash "$GENIE" "q"
    [ "$status" -eq 0 ]
    grep -qx "space-1" "$SANDBOX/databricks.log"
}

@test "--raw prints the whole message JSON" {
    run bash "$GENIE" --raw "q"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.conversation_id' <<< "$output")" = "00000000000000000000000000000002" ]
}

@test "--no-sql hides the SQL block" {
    run bash "$GENIE" --no-sql "q"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1,234,567 rows"* ]] || false
    [[ "$output" != *"SELECT"* ]] || false
}

@test "auth failure: exit 2, login command for the profile, the user has to run it" {
    cli_fails "default auth: cannot configure default credentials, please check https://docs.databricks.com/en/dev-tools/auth.html"
    run bash "$GENIE" "q"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot configure default credentials"* ]] || false
    [[ "$output" == *"databricks auth login --host https://example.invalid --profile team"* ]] || false
    [[ "$output" == *"user"* ]] || false
}

@test "a profile missing from databrickscfg is an auth failure too" {
    cli_fails "resolve: /home/u/.databrickscfg has no team profile configured. Config: profile=team"
    run bash "$GENIE" "q"
    [ "$status" -eq 2 ]
    [[ "$output" == *"databricks auth login --host https://example.invalid --profile team"* ]] || false
}

@test "auth failure without GENIE_PROFILE: login by GENIE_HOST is enough" {
    drop_env GENIE_PROFILE
    cli_fails "default auth: cannot configure default credentials. Config: host=https://example.invalid. Env: DATABRICKS_HOST"
    run bash "$GENIE" "q"
    [ "$status" -eq 2 ]
    [[ "$output" == *"databricks auth login --host https://example.invalid"* ]] || false
    [[ "$output" != *"--profile <profile>"* ]] || false
}

@test "auth failure without GENIE_PROFILE and GENIE_HOST asks to set GENIE_PROFILE" {
    drop_env GENIE_PROFILE
    drop_env GENIE_HOST
    cli_fails "default auth: cannot configure default credentials"
    run bash "$GENIE" "q"
    [ "$status" -eq 2 ]
    [[ "$output" == *"databricks auth login --host <workspace-url> --profile <profile>"* ]] || false
    [[ "$output" == *"GENIE_PROFILE=<profile>"* ]] || false
}

@test "a failed Genie message is reported without the login hint" {
    cli_fails "failed to reach COMPLETED, got FAILED: Message processing failed"
    run bash "$GENIE" "q"
    [ "$status" -eq 1 ]
    [[ "$output" == *"got FAILED"* ]] || false
    [[ "$output" != *"auth login"* ]] || false
}

@test "no access to the workspace is not reported as a login problem" {
    cli_fails "Unauthorized access to Org: 1234567890 [ReqId: 00000000-0000-0000-0000-000000000000]"
    run bash "$GENIE" "q"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unauthorized access to Org"* ]] || false
    [[ "$output" != *"auth login"* ]] || false
}

@test "an outdated databricks CLI asks for an update, not a login" {
    cli_fails 'unknown command "start-conversation" for "databricks genie"'
    run bash "$GENIE" "q"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Update databricks CLI"* ]] || false
    [[ "$output" != *"auth login"* ]] || false
}

@test "a leftover GENIE_TOKEN in .env is reported" {
    echo "GENIE_TOKEN=old-pat" >> "$SANDBOX/overlay/.env"
    run bash "$GENIE" "q"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GENIE_TOKEN is no longer used"* ]] || false
    [[ "$output" != *"old-pat"* ]] || false
}

@test "missing GENIE_SPACE_ID fails before calling Genie and shows how to list spaces" {
    drop_env GENIE_SPACE_ID
    run bash "$GENIE" "q"
    [ "$status" -ne 0 ]
    [[ "$output" == *"databricks genie list-spaces --profile team"* ]] || false
    [ ! -f "$SANDBOX/databricks.log" ]
}

@test "--help works without any configuration" {
    rm "$SANDBOX/overlay/.env"
    run bash "$GENIE" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || false
}
