#!/usr/bin/env bats
# genie.sh ходит в Genie через databricks CLI (OAuth), а не curl с PAT. Сети нет: databricks
# подменяется стабом, который пишет аргументы в журнал и отвечает готовым сообщением Genie;
# curl — стабом, который только отмечает, что его позвали.
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
if [[ -f "$SANDBOX/auth-fails" ]]; then
    echo "Error: default auth: cannot configure default credentials" >&2
    exit 1
fi
cat <<'JSON'
{"id":"m-1","conversation_id":"c-1","status":"COMPLETED","content":"q","attachments":[
  {"text":{"content":"Yesterday there were **42 orders**."}},
  {"query":{"query":"SELECT COUNT(*) FROM \`main\`.\`gold\`.\`orders\`","description":"count"}},
  {"suggested_questions":{"questions":["What was the revenue yesterday?"]}}]}
JSON
STUB
    cat > "$SANDBOX/bin/curl" <<STUB
#!/usr/bin/env bash
touch "$SANDBOX/curl-called"
exit 22
STUB
    chmod +x "$SANDBOX/bin/databricks" "$SANDBOX/bin/curl"
    PATH="$SANDBOX/bin:$PATH"
    export PATH
    # Секреты и профиль из окружения разработчика не должны просочиться в тест.
    unset GENIE_TOKEN GENIE_HOST GENIE_PROFILE GENIE_SPACE_ID DATABRICKS_CONFIG_PROFILE

    GENIE="$HUB/integrations/genie/scripts/genie.sh"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "asks the space through databricks CLI with the overlay profile, never curl" {
    run bash "$GENIE" "how many orders yesterday?"
    [ "$status" -eq 0 ]
    [ ! -f "$SANDBOX/curl-called" ]
    log="$(cat "$SANDBOX/databricks.log")"
    [[ "$log" == genie$'\n'start-conversation$'\n'* ]] || false
    [[ "$log" == *$'\n'--profile$'\n'team$'\n'* ]] || false
    [[ "$log" == *$'\n'space-1$'\n'"how many orders yesterday?"$'\n'---* ]] || false
    [[ "$output" == *"42 orders"* ]] || false
    [[ "$output" == *"main.gold.orders"* ]] || false
    [[ "$output" == *"What was the revenue yesterday?"* ]] || false
}

@test "a question starting with a dash goes as content, not as a CLI flag" {
    run bash "$GENIE" "-5% orders?"
    [ "$status" -eq 0 ]
    [[ "$(cat "$SANDBOX/databricks.log")" == *$'\n'--$'\n'space-1$'\n'"-5% orders?"$'\n'* ]] || false
}

@test "without GENIE_PROFILE the CLI default profile is used" {
    sed -i.bak '/^GENIE_PROFILE=/d' "$SANDBOX/overlay/.env"
    run bash "$GENIE" "q"
    [ "$status" -eq 0 ]
    ! grep -qx -- "--profile" "$SANDBOX/databricks.log"
}

@test "--raw prints the whole message JSON" {
    run bash "$GENIE" --raw "q"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.conversation_id' <<< "$output")" = "c-1" ]
}

@test "--no-sql hides the SQL block" {
    run bash "$GENIE" --no-sql "q"
    [ "$status" -eq 0 ]
    [[ "$output" == *"42 orders"* ]] || false
    [[ "$output" != *"SELECT"* ]] || false
}

@test "auth failure shows the login command for the configured host and profile" {
    touch "$SANDBOX/auth-fails"
    run bash "$GENIE" "q"
    [ "$status" -ne 0 ]
    [[ "$output" == *"databricks auth login --host https://example.invalid --profile team"* ]] || false
}

@test "missing GENIE_SPACE_ID fails before calling Genie" {
    sed -i.bak '/^GENIE_SPACE_ID=/d' "$SANDBOX/overlay/.env"
    run bash "$GENIE" "q"
    [ "$status" -ne 0 ]
    [[ "$output" == *"GENIE_SPACE_ID"* ]] || false
    [ ! -f "$SANDBOX/databricks.log" ]
}

@test "--help works without any configuration" {
    rm "$SANDBOX/overlay/.env"
    run bash "$GENIE" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]] || false
}
